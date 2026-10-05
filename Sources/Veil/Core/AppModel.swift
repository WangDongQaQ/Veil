import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox

/// Level meter lives in its own object so 20+ updates a second don't re-render the menu.
final class LevelMeter: ObservableObject, @unchecked Sendable {
    @Published var value: Float = 0
    /// Only the Settings window flips this on, so the audio thread does no extra work otherwise.
    var isObserved = false
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum ListeningState: Equatable {
        case idle
        case starting(String)
        case listening
        case failed(String)
    }

    let settings = AppSettings()
    let store = CaptionStore()
    let meter = LevelMeter()

    @Published private(set) var state: ListeningState = .idle
    /// Latest engine progress or warning ("正在下载语言模型 42%", network trouble…).
    @Published private(set) var detail: String = ""
    @Published private(set) var microphoneDenied = false
    /// True while Doubao is selected but the daily cap pushed us onto on-device recognition.
    @Published private(set) var usingFallback = false
    @Published var captionsVisible = true {
        didSet { windowController?.setVisible(captionsVisible) }
    }

    private let capture = AudioCapture()
    private var engine: TranscriptionEngine?
    private var startTask: Task<Void, Never>?
    private var windowController: CaptionWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var bootstrapped = false

    var captionController: CaptionWindowController? { windowController }

    var isListening: Bool { state == .listening }
    var isBusy: Bool { if case .starting = state { true } else { false } }
    var isEditing: Bool { store.editMode }

    // MARK: Lifecycle

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        windowController = CaptionWindowController(store: store, settings: settings) { [weak self] in
            self?.setEditing(false)
        }
        windowController?.setVisible(true)

        applyRetention()
        settings.$p
            .map { [$0.retentionSeconds, Double($0.maxCharacters)] }
            .removeDuplicates()
            .sink { [weak self] _ in self?.applyRetention() }
            .store(in: &cancellables)

        // Pause length and sensitivity only tune the voice gate: apply them live, never restart the microphone.
        settings.$p
            .map { GateTuning(sensitivity: $0.apiSensitivity, endSilence: $0.apiEndSilence) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] tuning in
                self?.engine?.updateVoiceGate(sensitivity: tuning.sensitivity, endSilence: tuning.endSilence)
            }
            .store(in: &cancellables)

        // Restart the engine when anything that affects recognition changes (debounced while typing).
        settings.$p
            .map(RecognitionKey.init)
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(0.8), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.restartIfListening() }
            .store(in: &cancellables)

        capture.onRouteChange = { [weak self] in
            MainActor.assumeIsolated { self?.audioRouteChanged() }
        }

        registerHotKeys()
        DebugSnapshot.runIfRequested(model: self)

        if !settings.p.hasCompletedFirstRun {
            settings.p.hasCompletedFirstRun = true
            setEditing(true)          // first launch: show the widget so it can be placed right away
        } else if settings.p.autoStartListening {
            startListening()
        }
    }

    func shutdown() {
        startTask?.cancel()
        capture.stop()
        let engine = engine
        Task { await engine?.stop() }
        HotKeys.shared.unregisterAll()
    }

    private func registerHotKeys() {
        let mods = HotKeys.control | HotKeys.option | HotKeys.command
        HotKeys.shared.register(keyCode: kVK_ANSI_L, modifiers: mods) { [weak self] in self?.toggleListening() }
        HotKeys.shared.register(keyCode: kVK_ANSI_H, modifiers: mods) { [weak self] in self?.captionsVisible.toggle() }
        HotKeys.shared.register(keyCode: kVK_ANSI_E, modifiers: mods) { [weak self] in self?.toggleEditing() }
    }

    private func applyRetention() {
        store.retention = settings.p.retentionSeconds
        store.maxCharacters = settings.p.maxCharacters
        store.retentionChanged()
    }

    // MARK: Actions

    func toggleListening() {
        switch state {
        case .listening, .starting: stopListening()
        case .idle, .failed: startListening()
        }
    }

    func toggleEditing() { setEditing(!store.editMode) }

    func setEditing(_ editing: Bool) {
        if editing { captionsVisible = true }
        store.editMode = editing
    }

    func clearCaptions() { store.clear() }
    func resetWindowPosition() { windowController?.resetPosition() }

    func startListening() {
        guard startTask == nil, state != .listening else { return }
        state = .starting("正在启动…")
        detail = ""
        microphoneDenied = false

        startTask = Task { [weak self] in
            guard let self else { return }
            defer { startTask = nil }
            do {
                guard await AudioCapture.requestAccess() else { throw CaptureError.denied }
                let engine = try makeEngine()
                try await engine.start { [weak self] event in
                    Task { @MainActor in self?.handle(event) }
                }
                try Task.checkCancellation()

                let meter = self.meter
                capture.onBuffer = { engine.feed($0) }
                capture.onLevel = { level in
                    guard meter.isObserved else { return }
                    DispatchQueue.main.async { meter.value = level }
                }
                try capture.start(deviceUID: settings.p.inputDeviceUID)
                self.engine = engine
                state = .listening
                detail = ""
            } catch is CancellationError {
                // stopListening() already reset everything.
            } catch {
                if case CaptureError.denied = error { microphoneDenied = true }
                state = .failed(error.localizedDescription)
                capture.stop()
                let failed = engine
                engine = nil
                await failed?.stop()
            }
        }
    }

    func stopListening() {
        startTask?.cancel()
        startTask = nil
        capture.stop()
        meter.value = 0
        let stopping = engine
        engine = nil
        state = .idle
        detail = ""
        Task { await stopping?.stop() }
    }

    private func restartIfListening() {
        guard isListening || isBusy else { return }
        stopListening()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            startListening()
        }
    }

    private var routeChangeTimes: [Date] = []

    private func audioRouteChanged() {
        guard isListening else { return }
        // Safety net: if the route keeps changing, stop instead of flickering the microphone on and off.
        let now = Date()
        routeChangeTimes = routeChangeTimes.filter { now.timeIntervalSince($0) < 10 } + [now]
        if routeChangeTimes.count > 3 {
            stopListening()
            state = .failed("麦克风配置在反复变化，已自动暂停。请检查输入设备后重新开始听写。")
            return
        }
        do { try capture.start(deviceUID: settings.p.inputDeviceUID) }
        catch { state = .failed(error.localizedDescription) }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .transcript(let transcript):
            guard state == .listening || isBusy else { return }
            if !transcript.text.isEmpty { detail = "" }
            store.apply(transcript)
        case .status(let text):
            if isBusy { state = .starting(text) }
            detail = text
        case .warning(let text):
            detail = text
        case .limitReached(let text):
            if settings.p.doubaoFallbackToApple {
                detail = text + "已自动改用本机识别。"
                restartIfListening()
            } else {
                detail = text + "不会再发送音频，可在设置里调高上限。"
            }
        }
    }

    // MARK: Engine factory — add new backends here.

    func makeEngine() throws -> TranscriptionEngine {
        let p = settings.p
        usingFallback = false
        switch p.backend {
        case .apple:
            return AppleSpeechEngine(localeID: p.languageID)
        case .doubao:
            if p.doubaoFallbackToApple, UsageTracker.shared.isOverLimit(minutes: p.doubaoDailyLimitMinutes) {
                usingFallback = true
                return AppleSpeechEngine(localeID: p.languageID)
            }
            return DoubaoStreamingEngine(config: doubaoConfig())
        case .openAICompatible:
            return OpenAICompatibleEngine(config: apiConfig())
        }
    }

    func doubaoConfig() -> DoubaoStreamingEngine.Config {
        let p = settings.p
        return .init(apiKey: Keychain.get(Keychain.doubaoAPIKeyAccount) ?? "",
                     resourceID: p.doubaoResourceID,
                     twoPass: p.doubaoTwoPass,
                     sensitivity: p.apiSensitivity,
                     endSilence: p.apiEndSilence,
                     dailyLimitMinutes: p.doubaoDailyLimitMinutes)
    }

    func apiConfig() -> OpenAICompatibleEngine.Config {
        let p = settings.p
        let language = p.apiAutoLanguage ? nil : p.languageID.split(separator: "-").first.map(String.init)
        return .init(baseURL: p.apiBaseURL,
                     apiKey: Keychain.get(Keychain.asrAPIKeyAccount) ?? "",
                     model: p.apiModel,
                     language: language,
                     prompt: p.apiPrompt,
                     endSilence: p.apiEndSilence,
                     sensitivity: p.apiSensitivity,
                     livePreview: p.apiLivePreview)
    }

    // MARK: Status text

    var statusLine: String {
        switch state {
        case .idle: "已暂停"
        case .starting(let text): text
        case .listening:
            if !detail.isEmpty { detail }
            else if usingFallback { "正在聆听 · Apple 本机识别（豆包今日已达上限）" }
            else { "正在聆听 · \(settings.p.backend.title)" }
        case .failed(let message): message
        }
    }
}

/// The subset of preferences that requires restarting the recognizer when changed.
private struct RecognitionKey: Equatable {
    var backend: ASRBackend
    var languageID: String
    var baseURL: String
    var model: String
    var prompt: String
    var autoLanguage: Bool
    var livePreview: Bool
    var keyRevision: Int
    var device: String?
    var doubaoResource: String
    var doubaoTwoPass: Bool
    var doubaoLimit: Int
    var doubaoFallback: Bool

    init(_ p: Preferences) {
        backend = p.backend
        languageID = p.languageID
        baseURL = p.apiBaseURL
        model = p.apiModel
        prompt = p.apiPrompt
        autoLanguage = p.apiAutoLanguage
        livePreview = p.apiLivePreview
        keyRevision = p.apiKeyRevision
        device = p.inputDeviceUID
        doubaoResource = p.doubaoResourceID
        doubaoTwoPass = p.doubaoTwoPass
        doubaoLimit = p.doubaoDailyLimitMinutes
        doubaoFallback = p.doubaoFallbackToApple
    }
}

private struct GateTuning: Equatable {
    var sensitivity: Double
    var endSilence: Double
}
