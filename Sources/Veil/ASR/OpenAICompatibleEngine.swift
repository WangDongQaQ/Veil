import AVFoundation

/// Streams microphone audio to any server that speaks `POST …/audio/transcriptions`
/// (OpenAI, Groq, SiliconFlow, faster-whisper-server, whisper.cpp server, LocalAI, mlx-whisper servers…).
///
/// Those APIs are request/response, not streaming, so this engine does the streaming itself:
/// a small energy-based VAD cuts the microphone into utterances, partial transcripts are
/// requested while someone is still talking, and the final transcript is requested at the pause.
final class OpenAICompatibleEngine: TranscriptionEngine, @unchecked Sendable {

    struct Config: Sendable {
        var baseURL: String
        var apiKey: String
        var model: String
        var language: String?          // ISO 639-1, nil = let the server detect
        var prompt: String
        var endSilence: Double         // seconds of quiet that end an utterance
        var sensitivity: Double        // 0…1, higher picks up quieter speech
        var livePreview: Bool          // request partial transcripts while speaking
    }

    // MARK: HTTP client

    struct Client: Sendable {
        let config: Config

        struct HTTPError: LocalizedError {
            let status: Int
            let message: String
            var errorDescription: String? { "接口返回 \(status)：\(message)" }
        }

        static func endpoint(from base: String) -> URL? {
            var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            guard !s.isEmpty else { return nil }
            let lower = s.lowercased()
            if !(lower.hasSuffix("/transcriptions") || lower.hasSuffix("/inference")) {
                s += "/audio/transcriptions"
            }
            return URL(string: s)
        }

        func transcribe(samples: [Float]) async throws -> String {
            guard let url = Self.endpoint(from: config.baseURL) else {
                throw EngineError.badConfiguration("接口地址无效，请在设置里检查。")
            }
            let boundary = "veil-\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            field("model", config.model)
            field("response_format", "json")
            field("temperature", "0")
            if let language = config.language, !language.isEmpty { field("language", language) }
            if !config.prompt.isEmpty { field("prompt", config.prompt) }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(OpenAICompatibleEngine.wav(from: samples))
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))

            var request = URLRequest(url: url, timeoutInterval: 25)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            if !config.apiKey.isEmpty {
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw HTTPError(status: status, message: Self.errorMessage(from: data))
            }
            return Self.text(from: data)
        }

        static func text(from data: Data) -> String {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func errorMessage(from data: Data) -> String {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
                if let error = json["error"] as? String { return error }
                if let message = json["message"] as? String { return message }
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            return raw.isEmpty ? "（无内容）" : String(raw.prefix(160))
        }
    }

    /// Used by the "测试连接" button: sends one second of silence and reports whether the server accepted it.
    static func testConnection(_ config: Config) async -> Result<Void, Error> {
        do {
            _ = try await Client(config: config).transcribe(samples: [Float](repeating: 0, count: 16_000))
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: Engine

    private let config: Config
    private let client: Client
    private let queue = DispatchQueue(label: "veil.asr.openai", qos: .userInitiated)
    private let converter = PCMConverter(target: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                              sampleRate: 16_000, channels: 1, interleaved: false)!)
    private var handler: EngineHandler?

    // Everything below is confined to `queue`.
    private let gate: VoiceGate
    private let partialInterval = 1.5
    private var utterance: [Float] = []
    private var sincePartial = 0.0
    private var utteranceID = 0
    private var partialInFlight = false
    private var finalChain: Task<Void, Never>?
    private var lastWarning = Date.distantPast

    init(config: Config) {
        self.config = config
        self.client = Client(config: config)
        self.gate = VoiceGate(sensitivity: config.sensitivity, endSilence: config.endSilence)
    }

    func start(handler: @escaping EngineHandler) async throws {
        guard Client.endpoint(from: config.baseURL) != nil else {
            throw EngineError.badConfiguration("还没有填写接口地址。请到设置 › 识别 里配置。")
        }
        guard !config.model.isEmpty else {
            throw EngineError.badConfiguration("还没有填写模型名称。请到设置 › 识别 里配置。")
        }
        self.handler = handler
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer),
              let channel = converted.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        queue.async { [self] in process(samples) }
    }

    func updateVoiceGate(sensitivity: Double, endSilence: Double) {
        queue.async { [self] in gate.update(sensitivity: sensitivity, endSilence: endSilence) }
    }

    func stop() async {
        queue.sync {
            for case .ended(let voiced) in gate.flush() { finishUtterance(voiced: voiced) }
        }
    }

    // MARK: Segmentation

    private func process(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        let duration = Double(chunk.count) / gate.sampleRate
        for event in gate.process(chunk) {
            switch event {
            case .started(let preroll): utterance = preroll; sincePartial = 0
            case .chunk(let audio, _): utterance.append(contentsOf: audio); sincePartial += duration
            case .ended(let voiced): finishUtterance(voiced: voiced)
            }
        }
        if gate.isSpeaking, config.livePreview, sincePartial >= partialInterval,
           !partialInFlight, gate.voicedSeconds >= 0.4 {
            requestPartial()
        }
    }

    private func requestPartial() {
        partialInFlight = true
        sincePartial = 0
        let samples = utterance
        let id = utteranceID
        Task { [weak self] in
            guard let self else { return }
            let text: String?
            do { text = try await client.transcribe(samples: samples) }
            catch { warn(error); text = nil }
            queue.async { [self] in
                self.partialInFlight = false
                guard let text, !text.isEmpty, self.gate.isSpeaking, self.utteranceID == id else { return }
                self.handler?(.transcript(TranscriptEvent(kind: .partial, text: text, utterance: id)))
            }
        }
    }

    private func finishUtterance(voiced: Double) {
        let samples = utterance
        let id = utteranceID
        utterance = []
        sincePartial = 0
        utteranceID += 1
        guard voiced >= 0.25 else { return }

        let previous = finalChain
        finalChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let text = try await client.transcribe(samples: samples)
                handler?(.transcript(TranscriptEvent(kind: .final, text: text, utterance: id)))
            } catch {
                warn(error)
                // Make sure a dangling partial doesn't stay on screen forever.
                handler?(.transcript(TranscriptEvent(kind: .final, text: "", utterance: id)))
            }
        }
    }

    private func warn(_ error: Error) {
        queue.async { [self] in
            guard Date().timeIntervalSince(lastWarning) > 8 else { return }
            lastWarning = Date()
            handler?(.warning(error.localizedDescription))
        }
    }

    // MARK: WAV

    static func wav(from samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(Data("RIFF".utf8)); u32(36 + byteCount); data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(byteCount)
        for s in samples {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * Float(Int16.max))))
        }
        return data
    }
}
