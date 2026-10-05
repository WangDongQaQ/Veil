import AVFoundation

/// Everything an engine can tell the app while it runs.
enum EngineEvent: Sendable {
    case transcript(TranscriptEvent)
    /// Human readable progress, e.g. "正在下载语言模型 42%".
    case status(String)
    /// Non-fatal problem (network hiccup). The engine keeps running.
    case warning(String)
    /// A paid engine hit the user's daily cap and has stopped sending audio.
    case limitReached(String)
}

typealias EngineHandler = @Sendable (EngineEvent) -> Void

/// A speech-to-text backend. Add a new one by implementing this protocol and
/// returning it from `AppModel.makeEngine()`.
protocol TranscriptionEngine: AnyObject, Sendable {
    /// Prepare models / connections. Throws if the engine can't run at all.
    func start(handler: @escaping EngineHandler) async throws
    /// Called on the audio thread with raw microphone buffers, in the device's native format.
    func feed(_ buffer: AVAudioPCMBuffer)
    func stop() async
}

enum EngineError: LocalizedError {
    case unavailable(String)
    case unsupportedLocale(String)
    case badConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let s), .unsupportedLocale(let s), .badConfiguration(let s): s
        }
    }
}

/// Converts whatever the microphone delivers into the format an engine wants.
/// Not thread-safe: it is meant to be fed from the single audio tap thread.
final class PCMConverter: @unchecked Sendable {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(target: AVAudioFormat) { self.target = target }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter == nil || sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            sourceFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
