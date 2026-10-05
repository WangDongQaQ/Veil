import Foundation

/// Energy-based voice activity gate with an adaptive noise floor. It cuts a continuous microphone
/// stream into utterances, so cloud engines only ever receive (and are billed for) speech.
/// Input is 16 kHz mono Float32. Not thread-safe: drive it from one queue.
final class VoiceGate {
    enum Event {
        /// The voice crossed the threshold. `preroll` holds ~0.3 s of audio before it plus the triggering chunk.
        case started(preroll: [Float])
        /// More audio belonging to the running utterance. `voiced` is false for the quiet stretch
        /// inside the end-of-utterance window, which cost-sensitive engines may hold back.
        case chunk([Float], voiced: Bool)
        /// The utterance is over (silence long enough, or maximum length reached).
        case ended(voiced: Double)
    }

    let sampleRate = 16_000.0
    private var minThreshold: Float
    private var endSilence: Double
    private let maxUtterance: Double
    private let prerollSamples = 4_800

    private var noiseFloor: Float = 0.002
    private var preroll: [Float] = []
    private(set) var isSpeaking = false
    private(set) var voicedSeconds = 0.0
    /// Length of the current stretch of voice, tolerating gaps up to 0.15 s (the pauses between syllables).
    /// Sporadic clicks — typing, a cough — never build a long run, speech does within the first words.
    private(set) var voicedRunSeconds = 0.0
    private var gapSeconds = 0.0
    private var silenceSeconds = 0.0
    private var lengthSeconds = 0.0

    /// - Parameters:
    ///   - sensitivity: 0…1, higher picks up quieter speech.
    ///   - endSilence: seconds of quiet that end an utterance.
    init(sensitivity: Double, endSilence: Double, maxUtterance: Double = 22) {
        minThreshold = Float(0.002 + (1 - min(max(sensitivity, 0), 1)) * 0.016)
        self.endSilence = endSilence
        self.maxUtterance = maxUtterance
    }

    /// Decisions are made on 20 ms frames regardless of how large the incoming buffers are
    /// (a Bluetooth headset hands over 128 ms at a time; one click would otherwise look like speech).
    /// Applies new tuning immediately, without disturbing an utterance in progress.
    func update(sensitivity: Double, endSilence: Double) {
        minThreshold = Float(0.002 + (1 - min(max(sensitivity, 0), 1)) * 0.016)
        self.endSilence = endSilence
    }

    func process(_ chunk: [Float]) -> [Event] {
        carry.append(contentsOf: chunk)
        var events: [Event] = []
        while carry.count >= Self.frameSamples {
            let frame = Array(carry.prefix(Self.frameSamples))
            carry.removeFirst(Self.frameSamples)
            events += processFrame(frame)
        }
        return events
    }

    private static let frameSamples = 320            // 20 ms
    private var carry: [Float] = []

    private func processFrame(_ chunk: [Float]) -> [Event] {
        let duration = Double(chunk.count) / sampleRate
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = (sum / Float(chunk.count)).squareRoot()
        let threshold = max(minThreshold, noiseFloor * 3)

        if !isSpeaking {
            noiseFloor = noiseFloor * 0.988 + min(rms, 0.05) * 0.012
            preroll.append(contentsOf: chunk)
            if preroll.count > prerollSamples { preroll.removeFirst(preroll.count - prerollSamples) }
            guard rms > threshold else { return [] }

            isSpeaking = true
            voicedSeconds = duration
            voicedRunSeconds = duration
            gapSeconds = 0
            silenceSeconds = 0
            lengthSeconds = Double(preroll.count) / sampleRate
            let lead = preroll
            preroll = []
            return [.started(preroll: lead)]
        }

        lengthSeconds += duration
        let voiced = rms > threshold
        if voiced {
            voicedSeconds += duration
            silenceSeconds = 0
            voicedRunSeconds += duration
            gapSeconds = 0
        } else {
            silenceSeconds += duration
            gapSeconds += duration
            if gapSeconds > 0.15 { voicedRunSeconds = 0 }
        }
        var events: [Event] = [.chunk(chunk, voiced: voiced)]

        if silenceSeconds >= endSilence || lengthSeconds >= maxUtterance {
            events.append(.ended(voiced: voicedSeconds))
            reset()
        }
        return events
    }

    /// Ends a running utterance right now (user paused listening).
    func flush() -> [Event] {
        guard isSpeaking else { return [] }
        let event = Event.ended(voiced: voicedSeconds)
        reset()
        return [event]
    }

    private func reset() {
        isSpeaking = false
        voicedSeconds = 0
        voicedRunSeconds = 0
        gapSeconds = 0
        silenceSeconds = 0
        lengthSeconds = 0
    }
}
