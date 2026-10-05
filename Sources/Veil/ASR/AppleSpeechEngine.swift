import AVFoundation
import Speech

/// On-device recognition through macOS 26's `SpeechAnalyzer` / `SpeechTranscriber`.
/// Nothing leaves the Mac; language models are downloaded once by the system.
final class AppleSpeechEngine: TranscriptionEngine, @unchecked Sendable {
    private let localeID: String

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: PCMConverter?
    private let lock = NSLock()

    init(localeID: String) { self.localeID = localeID }

    // MARK: Locale helpers (used by Settings too)

    static func supportedLocales() async -> [Locale] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales
    }

    static func installedLocaleIDs() async -> Set<String> {
        Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
    }

    /// Downloads the model for `localeID`; reports 0…1.
    static func install(localeID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw EngineError.unsupportedLocale("系统暂不支持这种语言的本机识别。")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            progress(1); return
        }
        let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
            progress(p.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
        progress(1)
    }

    // MARK: TranscriptionEngine

    func start(handler: @escaping EngineHandler) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw EngineError.unavailable("这台 Mac 不支持 Apple 本机语音转写。可以在设置里改用 OpenAI 兼容接口。")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw EngineError.unsupportedLocale("Apple 本机识别暂不支持「\(localeID)」。")
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [])

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            handler(.status("正在下载语言模型…"))
            let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                handler(.status("正在下载语言模型 \(Int(p.fractionCompleted * 100))%"))
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.unavailable("找不到可用的音频格式。")
        }
        lock.withLock { converter = PCMConverter(target: format) }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    handler(.transcript(TranscriptEvent(kind: result.isFinal ? .final : .partial, text: text)))
                }
            } catch {
                if !Task.isCancelled { handler(.warning("识别中断：\(error.localizedDescription)")) }
            }
        }

        try await analyzer.start(inputSequence: stream)
        lock.withLock {
            self.analyzer = analyzer
            self.inputContinuation = continuation
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let (converter, continuation) = lock.withLock { (self.converter, self.inputContinuation) }
        guard let converter, let continuation, let converted = converter.convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func stop() async {
        let (analyzer, continuation) = lock.withLock { () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?) in
            defer { self.analyzer = nil; self.inputContinuation = nil }
            return (self.analyzer, self.inputContinuation)
        }
        continuation?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        resultsTask?.cancel()
        resultsTask = nil
    }
}
