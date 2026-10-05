import AppKit
import AVFoundation
import SwiftUI

/// Developer aid: `VEIL_SNAPSHOT_DIR=/some/dir open Veil.app` renders the widget (hidden, revealed, edit mode)
/// and the settings window into PNGs and quits. It only draws Veil's own windows, so it needs no
/// screen-recording permission.
@MainActor
enum DebugSnapshot {
    /// `VEIL_FEED_FILE=speech.aiff` pushes an audio file through the selected recognition engine
    /// (microphone bypassed) and logs what comes back. `VEIL_FEED_BACKEND=api` + `VEIL_FEED_URL=…` tests the HTTP engine.
    static func feedFileIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["VEIL_FEED_FILE"] else { return }
        Task { @MainActor in
            if env["VEIL_FEED_BACKEND"] == "doubao" {
                model.settings.p.backend = .doubao
            } else if env["VEIL_FEED_BACKEND"] == "api" {
                model.settings.p.backend = .openAICompatible
                model.settings.p.apiBaseURL = env["VEIL_FEED_URL"] ?? "http://127.0.0.1:8099/v1"
                model.settings.p.apiModel = "whisper-1"
                model.settings.p.apiPresetID = "custom"
            } else {
                model.settings.p.backend = .apple
            }
            if let lang = env["VEIL_FEED_LANG"] { model.settings.p.languageID = lang }

            do {
                let engine: TranscriptionEngine
                if env["VEIL_FEED_BACKEND"] == "doubao" {
                    // The key comes from the environment for this one run — it is never stored or logged.
                    engine = DoubaoStreamingEngine(config: .init(
                        apiKey: env["VEIL_DOUBAO_KEY"] ?? "",
                        resourceID: env["VEIL_DOUBAO_RESOURCE"] ?? "volc.seedasr.sauc.duration",
                        twoPass: env["VEIL_DOUBAO_TWOPASS"] != "0",
                        sensitivity: 0.5, endSilence: 0.8, dailyLimitMinutes: 0))
                } else {
                    engine = try model.makeEngine()
                }
                try await engine.start { event in
                    switch event {
                    case .transcript(let t): NSLog("Veil feed: [\(t.kind == .final ? "final" : "partial")#\(t.utterance)] \(t.text)")
                    case .status(let s): NSLog("Veil feed: status \(s)")
                    case .warning(let w): NSLog("Veil feed: warning \(w)")
                    case .limitReached(let m): NSLog("Veil feed: limit \(m)")
                    }
                }
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                NSLog("Veil feed: file \(file.processingFormat) frames=\(file.length)")
                let frames: AVAudioFrameCount = 2048
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
                    try file.read(into: buffer, frameCount: frames)
                    engine.feed(buffer)
                    try? await Task.sleep(for: .milliseconds(Int(Double(frames) / file.processingFormat.sampleRate * 1000 / (Double(env["VEIL_FEED_SPEED"] ?? "4") ?? 4))))
                }
                // trailing silence so the VAD / recognizer closes the utterance
                if let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) {
                    silence.frameLength = frames
                    for _ in 0..<Int(2.0 * file.processingFormat.sampleRate / Double(frames)) {
                        engine.feed(silence)
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                try? await Task.sleep(for: .seconds(2))
                await engine.stop()
                try? await Task.sleep(for: .seconds(5))
                NSLog("Veil feed: audio sent today = \(UsageTracker.shared.todaySeconds)s")
            } catch {
                NSLog("Veil feed: ERROR \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class ProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private let start = Date()
        private let path: String
        private var lines: [String] = []
        init(path: String) { self.path = path }
        func write(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append(String(format: "%6.2fs  ", Date().timeIntervalSince(start)) + text)
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        var elapsed: Double { Date().timeIntervalSince(start) }
    }

    /// `VEIL_MIC_PROBE=20 VEIL_MIC_PROBE_DEVICE=BuiltInMicrophoneDevice VEIL_PROBE_LOG=/tmp/x.log`:
    /// runs the real capture for N seconds, mirroring AppModel's restart-on-route-change handling, and logs how
    /// often the audio engine reports a configuration change. Counts buffers only — no audio is kept.
    /// Returns true when it took over launch (the UI should not start).
    static func micProbeIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let seconds = env["VEIL_MIC_PROBE"].flatMap(Double.init) else { return false }
        let log = ProbeLog(path: env["VEIL_PROBE_LOG"] ?? "/tmp/veil-probe.log")
        let device = env["VEIL_MIC_PROBE_DEVICE"].flatMap { $0.isEmpty ? nil : $0 }
        let restartOnChange = env["VEIL_PROBE_NO_RESTART"] == nil

        Task.detached {
            guard await AudioCapture.requestAccess() else {
                log.write("microphone access denied")
                await MainActor.run { NSApp.terminate(nil) }
                return
            }
            let capture = AudioCapture()
            let buffers = Counter()
            let changes = Counter()
            capture.onBuffer = { _ in buffers.increment() }
            capture.onRouteChange = {
                changes.increment()
                log.write("AVAudioEngineConfigurationChange #\(changes.count)")
                if restartOnChange {
                    do { try capture.start(deviceUID: device); log.write("  restarted capture") }
                    catch { log.write("  restart failed: \(error.localizedDescription)") }
                }
            }
            do { try capture.start(deviceUID: device); log.write("capture started (device: \(device ?? "system default"))") }
            catch {
                log.write("start failed: \(error.localizedDescription)")
                await MainActor.run { NSApp.terminate(nil) }
                return
            }
            var tick = 0
            while log.elapsed < seconds {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                if tick % 5 == 0 { log.write("buffers=\(buffers.count) configChanges=\(changes.count)") }
            }
            capture.stop()
            log.write("DONE buffers=\(buffers.count) configChanges=\(changes.count)")
            await MainActor.run { NSApp.terminate(nil) }
        }
        return true
    }

    static func runIfRequested(model: AppModel) {
        feedFileIfRequested(model: model)
        guard let dir = ProcessInfo.processInfo.environment["VEIL_SNAPSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard let controller = model.captionController else { return }
            if ProcessInfo.processInfo.environment["VEIL_SETTINGS_BACKEND"] == "doubao" { model.settings.p.backend = .doubao }
            if let v = ProcessInfo.processInfo.environment["VEIL_SNAPSHOT_INTENSITY"], let k = Double(v) {
                model.settings.p.dustIntensity = k
            }
            if let tone = ProcessInfo.processInfo.environment["VEIL_SNAPSHOT_TONE"], let t = TextTone(rawValue: tone) {
                model.settings.p.tone = t
            }
            let panel = controller.panel
            controller.debugPointer = CGPoint(x: -2000, y: -2000)     // keep the real mouse out of the test
            model.store.editMode = false
            model.store.retention = 0

            model.store.apply(TranscriptEvent(kind: .final, text: "你好，下午的会议改到三点了，你方便吗？"))
            model.store.apply(TranscriptEvent(kind: .final, text: "另外上次提到的那个方案，我已经发给你了。"))
            model.store.apply(TranscriptEvent(kind: .partial, text: "你看一下有没有问题"))
            try? await Task.sleep(for: .seconds(0.8))

            save(panel, to: "\(dir)/1-hidden.png")
            // Steadiness check: a few more frames at different times.
            for i in 1...4 {
                try? await Task.sleep(for: .milliseconds(420))
                save(panel, to: "\(dir)/1-hidden-t\(i).png")
            }

            controller.debugPointer = CGPoint(x: 140, y: panel.frame.height - 40)
            try? await Task.sleep(for: .seconds(0.25))
            save(panel, to: "\(dir)/2-revealing.png")
            try? await Task.sleep(for: .seconds(1.0))
            save(panel, to: "\(dir)/3-revealed.png")

            controller.debugPointer = nil
            model.store.pointer = nil
            model.store.editMode = true
            try? await Task.sleep(for: .seconds(0.8))
            save(panel, to: "\(dir)/4-edit.png")
            model.store.editMode = false

            // Background styles, revealed so the shape is visible.
            for (name, style) in [("glass", CaptionBackground.glass), ("dim", .dim)] {
                model.settings.p.background = style
                controller.debugPointer = CGPoint(x: 140, y: panel.frame.height - 40)
                try? await Task.sleep(for: .seconds(1.2))
                save(panel, to: "\(dir)/6-bg-\(name).png")
            }
            model.settings.p.background = .none

            if ProcessInfo.processInfo.environment["VEIL_SNAPSHOT_SETTINGS"] != nil {
                NSApp.activate()
                let opener = NSHostingView(rootView: SettingsOpener())
                let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                                    backing: .buffered, defer: false)
                host.contentView = opener
                host.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(2))
                host.orderOut(nil)
                let candidates = NSApp.windows.filter { $0 !== panel && $0.isVisible && $0.frame.width > 300 }
                NSLog("Veil snapshot: windows = \(candidates.map { "\(type(of: $0)) \($0.title) \($0.frame)" })")
                if let window = candidates.first(where: { $0.frame.width > 300 }) {
                    save(window, to: "\(dir)/5-settings-\(ProcessInfo.processInfo.environment["VEIL_SETTINGS_TAB"] ?? "general").png", opaque: true)
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// Asks the window server for this window's real pixels (masks, Canvas, glass included).
    /// `CGWindowListCreateImage` is hidden in recent SDKs, so it is looked up at runtime.
    private struct SettingsOpener: View {
        @Environment(\.openSettings) private var openSettings
        var body: some View { Color.clear.onAppear { openSettings() } }
    }

    private static func windowImage(_ window: NSWindow) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Fn.self)
        let optionIncludingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        return create(.null, optionIncludingWindow, UInt32(window.windowNumber), boundsIgnoreFraming)?.takeRetainedValue()
    }

    private static func save(_ window: NSWindow, to path: String, opaque: Bool = false) {
        guard let cg = windowImage(window) else { NSLog("Veil snapshot: window capture unavailable"); return }
        let size = NSSize(width: cg.width, height: cg.height)
        let image = NSImage(size: size)
        image.lockFocus()
        let backdrop = ProcessInfo.processInfo.environment["VEIL_SNAPSHOT_BG"]
        if !opaque, backdrop == "white" {
            NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        } else if !opaque, backdrop == "black" {
            NSColor.black.setFill(); NSRect(origin: .zero, size: size).fill()
        } else if !opaque {
            NSGradient(colors: [NSColor(calibratedRed: 0.22, green: 0.32, blue: 0.52, alpha: 1),
                                NSColor(calibratedRed: 0.52, green: 0.38, blue: 0.48, alpha: 1)])?
                .draw(in: NSRect(origin: .zero, size: size), angle: 20)
        }
        NSImage(cgImage: cg, size: size).draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
