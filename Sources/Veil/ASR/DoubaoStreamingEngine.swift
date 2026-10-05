import AVFoundation
import Compression

/// Doubao (Volcengine) streaming ASR over its binary WebSocket protocol.
///
/// Built to spend as little audio as possible, because the service bills by audio duration:
///  • a real streaming connection — every sample is sent exactly once (no re-uploading growing sentences);
///  • a local voice gate — silence is never sent;
///  • a session is opened only after ~0.25 s of confirmed speech, so keyboard clicks and coughs cost nothing;
///  • one short session per utterance, closed right after the final result;
///  • a daily cap, after which the app falls back to on-device recognition.
final class DoubaoStreamingEngine: TranscriptionEngine, @unchecked Sendable {

    struct Config: Sendable {
        var apiKey: String
        var resourceID: String
        var twoPass: Bool              // fast interim text, then a more accurate final pass
        var sensitivity: Double
        var endSilence: Double
        var dailyLimitMinutes: Int     // 0 = unlimited
    }

    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    /// Continuous voiced time required before a (billed) session is opened.
    static let confirmSeconds = 0.25

    private let config: Config
    private let queue = DispatchQueue(label: "veil.asr.doubao", qos: .userInitiated)
    private let converter = PCMConverter(target: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                              sampleRate: 16_000, channels: 1, interleaved: false)!)
    private let gate: VoiceGate
    private var handler: EngineHandler?

    // Confined to `queue`.
    private var pending: [Float] = []        // speech heard, session not opened yet
    private var heldQuiet: [Float] = []      // quiet audio inside the end window: sent only if speech resumes
    private var session: DoubaoSession?
    private var confirmed = false
    private var utteranceID = 0
    private var limitReported = false

    init(config: Config) {
        self.config = config
        self.gate = VoiceGate(sensitivity: config.sensitivity, endSilence: config.endSilence)
    }

    func start(handler: @escaping EngineHandler) async throws {
        guard !config.apiKey.isEmpty else {
            throw EngineError.badConfiguration("还没有填写豆包 API Key。请到设置 › 识别 里填写。")
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
            for event in gate.flush() { if case .ended = event { endUtterance() } }
        }
    }

    // MARK: Gate → session

    private func process(_ chunk: [Float]) {
        for event in gate.process(chunk) {
            switch event {
            case .started(let preroll):
                pending = preroll
                heldQuiet = []
                confirmed = false
                utteranceID += 1
            case .chunk(let audio, let voiced):
                guard session != nil else { pending.append(contentsOf: audio); continue }
                if voiced {
                    // Speech resumed: the held pause was part of the sentence, so send it after all.
                    session?.append(Self.pcm(heldQuiet + audio))
                    heldQuiet = []
                } else {
                    heldQuiet.append(contentsOf: audio)
                }
            case .ended:
                endUtterance()
            }
        }
        if gate.isSpeaking, session == nil, !confirmed, gate.voicedRunSeconds >= Self.confirmSeconds {
            confirmed = true
            openSession()
        }
    }

    private func openSession() {
        if UsageTracker.shared.isOverLimit(minutes: config.dailyLimitMinutes) {
            pending = []
            if !limitReported {
                limitReported = true
                handler?(.limitReached("今日豆包用量已达 \(config.dailyLimitMinutes) 分钟上限。"))
            }
            return
        }
        guard let handler else { return }
        let session = DoubaoSession(config: config, utterance: utteranceID, handler: handler)
        self.session = session
        session.start(initial: Self.pcm(pending))
        pending = []
    }

    private func endUtterance() {
        if let session {
            // The trailing quiet is not billed audio: keep only a short natural tail.
            session.append(Self.pcm(Array(heldQuiet.prefix(Self.tailSamples))))
            session.finish()
            self.session = nil
        }
        heldQuiet = []
        pending = []        // never confirmed as speech → nothing was sent, nothing is billed
        confirmed = false
    }

    private static let tailSamples = 3_200      // 0.2 s

    static func pcm(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                out[i] = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
            }
        }
        return data
    }

    // MARK: Connection test

    /// Opens a session, sends 0.2 s of silence and reports whether the service accepted the key.
    static func testConnection(_ config: Config) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            let waiter = OneShot(continuation)
            let session = DoubaoSession(config: config, utterance: 0) { event in
                switch event {
                case .warning(let message): waiter.resume(.failure(EngineError.unavailable(message)))
                case .transcript(let t) where t.kind == .final: waiter.resume(.success(()))
                default: break
                }
            }
            session.start(initial: Data(count: 6_400))
            session.finish()
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                waiter.resume(.failure(EngineError.unavailable("连接超时。请检查网络。")))
            }
        }
    }

    private final class OneShot: @unchecked Sendable {
        private var continuation: CheckedContinuation<Result<Void, Error>, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<Result<Void, Error>, Never>) { self.continuation = continuation }
        func resume(_ result: Result<Void, Error>) {
            lock.lock(); defer { lock.unlock() }
            continuation?.resume(returning: result)
            continuation = nil
        }
    }
}

// MARK: - One session = one utterance

final class DoubaoSession: @unchecked Sendable {
    private enum Outgoing { case audio(Data), last(Data) }

    private let config: DoubaoStreamingEngine.Config
    private let utterance: Int
    private let handler: EngineHandler
    private let task: URLSessionWebSocketTask
    private let outbox: AsyncStream<Outgoing>
    private let outboxContinuation: AsyncStream<Outgoing>.Continuation

    private let lock = NSLock()
    private var packet = Data()          // PCM waiting to fill a 200 ms packet
    private var lastText = ""
    private var delivered = false
    private var closed = false
    private var failed = false

    private static let packetBytes = 6_400          // 200 ms of 16 kHz / 16-bit / mono

    init(config: DoubaoStreamingEngine.Config, utterance: Int, handler: @escaping EngineHandler) {
        self.config = config
        self.utterance = utterance
        self.handler = handler

        var request = URLRequest(url: DoubaoStreamingEngine.endpoint)
        request.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(config.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        task = URLSession.shared.webSocketTask(with: request)
        (outbox, outboxContinuation) = AsyncStream.makeStream(of: Outgoing.self)
    }

    func start(initial: Data) {
        task.resume()
        append(initial)
        Task { await sendLoop() }
        Task { await receiveLoop() }
    }

    /// Buffers PCM and ships complete 200 ms packets.
    func append(_ pcm: Data) {
        lock.lock()
        packet.append(pcm)
        var ready: [Data] = []
        while packet.count >= Self.packetBytes {
            ready.append(packet.prefix(Self.packetBytes))
            packet.removeFirst(Self.packetBytes)
        }
        lock.unlock()
        for data in ready { outboxContinuation.yield(.audio(data)) }
    }

    /// Sends what is left plus the end-of-stream marker, then waits (briefly) for the final result.
    func finish() {
        lock.lock()
        var rest = packet
        packet = Data()
        lock.unlock()
        if rest.isEmpty { rest = Data(count: 640) }      // the last packet must carry audio: 20 ms of silence
        outboxContinuation.yield(.last(rest))
        outboxContinuation.finish()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.deliverFinal(fallback: true)
            self?.close()
        }
    }

    // MARK: Sending

    private func requestJSON() -> Data {
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "show_utterances": true,
        ]
        if config.twoPass { request["enable_nonstream"] = true }
        let body: [String: Any] = [
            "user": ["uid": "veil"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16_000, "bits": 16, "channel": 1],
            "request": request,
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private func sendLoop() async {
        var sequence: Int32 = 1
        do {
            try await task.send(.data(DoubaoFrame.encode(type: .fullClientRequest, sequence: sequence,
                                                         payload: requestJSON(), json: true)))
            sequence += 1
            for await item in outbox {
                switch item {
                case .audio(let data):
                    try await task.send(.data(DoubaoFrame.encode(type: .audioOnly, sequence: sequence, payload: data)))
                    UsageTracker.shared.add(seconds: Double(data.count) / 32_000)
                    sequence += 1
                case .last(let data):
                    try await task.send(.data(DoubaoFrame.encode(type: .audioOnly, sequence: -sequence,
                                                                 payload: data, last: true)))
                    UsageTracker.shared.add(seconds: Double(data.count) / 32_000)
                }
            }
        } catch {
            fail(error)
        }
    }

    // MARK: Receiving

    private func receiveLoop() async {
        while true {
            do {
                let message = try await task.receive()
                guard case .data(let data) = message else { continue }
                switch try DoubaoFrame.parse(data) {
                case .response(let json, let isLast):
                    handleResponse(json, isLast: isLast)
                    if isLast { close(); return }
                case .error(let code, let text):
                    fail(DoubaoError.server(code: code, message: text, resource: config.resourceID))
                    return
                }
            } catch {
                if !isClosed { fail(error) }
                return
            }
        }
    }

    private func handleResponse(_ json: [String: Any], isLast: Bool) {
        let result = (json["result"] as? [String: Any]) ?? (json["result"] as? [[String: Any]])?.first ?? [:]
        let text = (result["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isLast {
            if !text.isEmpty { setLastText(text) }
            deliverFinal(fallback: true)
        } else if !text.isEmpty, text != currentLastText {
            setLastText(text)
            handler(.transcript(TranscriptEvent(kind: .partial, text: text, utterance: utterance)))
        }
    }

    private var currentLastText: String { lock.lock(); defer { lock.unlock() }; return lastText }
    private func setLastText(_ text: String) { lock.lock(); lastText = text; lock.unlock() }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    private func deliverFinal(fallback: Bool) {
        lock.lock()
        guard !delivered else { lock.unlock(); return }
        delivered = true
        let text = lastText
        lock.unlock()
        handler(.transcript(TranscriptEvent(kind: .final, text: text, utterance: utterance)))
    }

    private func fail(_ error: Error) {
        lock.lock()
        let already = failed
        failed = true
        lock.unlock()
        guard !already else { return }
        let message = DoubaoError.describe(error, response: task.response as? HTTPURLResponse, resource: config.resourceID)
        handler(.warning(message))
        deliverFinal(fallback: true)
        close()
    }

    private func close() {
        lock.lock()
        let already = closed
        closed = true
        lock.unlock()
        guard !already else { return }
        outboxContinuation.finish()
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - Errors

enum DoubaoError: LocalizedError {
    case server(code: UInt32, message: String, resource: String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .server(let code, let message, let resource): Self.describeServer(code: code, message: message, resource: resource)
        case .malformed: "豆包返回了无法解析的数据。"
        }
    }

    static func describeServer(code: UInt32, message: String, resource: String) -> String {
        switch code {
        case 45000001: "豆包：请求参数无效（\(message)）。"
        case 45000002: "豆包：没有收到有效音频。"
        case 45000081: "豆包：等待音频超时。"
        case 55000031: "豆包：服务繁忙，请稍后再试。"
        case 45000010, 45000030: "豆包：鉴权失败，请检查 API Key，以及它是否已开通「\(resource)」。"
        default: "豆包返回错误 \(code)：\(message)"
        }
    }

    static func describe(_ error: Error, response: HTTPURLResponse?, resource: String) -> String {
        if let doubao = error as? DoubaoError { return doubao.localizedDescription }
        if let status = response?.statusCode, status >= 400 {
            let logID = response?.value(forHTTPHeaderField: "X-Tt-Logid").map { "（logid \($0)）" } ?? ""
            switch status {
            case 401, 403:
                return "豆包鉴权失败（HTTP \(status)）：请检查 API Key，以及它是否已开通资源「\(resource)」。\(logID)"
            case 429:
                return "豆包请求过于频繁或并发已满（HTTP 429）。\(logID)"
            default:
                return "豆包连接失败（HTTP \(status)）。\(logID)"
            }
        }
        return "豆包连接出错：\(error.localizedDescription)"
    }
}

// MARK: - Wire format

/// Doubao's binary frame: 4-byte header, optional sequence number, payload size, payload.
enum DoubaoFrame {
    enum MessageType: UInt8 {
        case fullClientRequest = 0b0001
        case audioOnly = 0b0010
    }

    enum Parsed {
        case response(json: [String: Any], isLast: Bool)
        case error(code: UInt32, message: String)
    }

    static func encode(type: MessageType, sequence: Int32, payload: Data, json: Bool = false, last: Bool = false) -> Data {
        // flags: 0b0001 = positive sequence number, 0b0011 = negative sequence number (last packet)
        let flags: UInt8 = last ? 0b0011 : 0b0001
        var frame = Data([0x11,                                  // protocol v1, 4-byte header
                          type.rawValue << 4 | flags,
                          (json ? 0b0001 : 0b0000) << 4 | 0b0000, // serialization JSON/none, no compression
                          0x00])
        frame.append(bigEndian: UInt32(bitPattern: sequence))
        frame.append(bigEndian: UInt32(payload.count))
        frame.append(payload)
        return frame
    }

    static func parse(_ data: Data) throws -> Parsed {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw DoubaoError.malformed }
        let headerSize = Int(bytes[0] & 0x0F) * 4
        let type = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        let compression = bytes[2] & 0x0F
        var offset = headerSize

        func readUInt32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw DoubaoError.malformed }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }

        switch type {
        case 0b1001:                                             // full server response
            if flags & 0b0001 != 0 { _ = try readUInt32() }      // sequence
            if flags & 0b0100 != 0 { _ = try readUInt32() }      // event id (not used by this endpoint)
            let size = Int(try readUInt32())
            guard offset + size <= bytes.count else { throw DoubaoError.malformed }
            var payload = Data(bytes[offset..<offset + size])
            if compression == 0b0001 { payload = try gunzip(payload) }
            let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
            return .response(json: json, isLast: flags & 0b0010 != 0)
        case 0b1111:                                             // error
            let code = try readUInt32()
            let size = Int(try readUInt32())
            let end = min(bytes.count, offset + size)
            let message = String(decoding: bytes[offset..<end], as: UTF8.self)
            return .error(code: code, message: message)
        default:
            throw DoubaoError.malformed
        }
    }

    /// gzip = 10-byte header + raw deflate + 8-byte trailer; Compression's `.zlib` is raw deflate.
    private static func gunzip(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b else { throw DoubaoError.malformed }
        let flags = b[3]
        var offset = 10
        if flags & 0b0000_0100 != 0, offset + 2 <= b.count { offset += 2 + Int(b[offset]) | Int(b[offset + 1]) << 8 }
        if flags & 0b0000_1000 != 0 { while offset < b.count, b[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0b0001_0000 != 0 { while offset < b.count, b[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0b0000_0010 != 0 { offset += 2 }
        guard offset < b.count - 8 else { throw DoubaoError.malformed }
        let deflated = Data(b[offset..<b.count - 8]) as NSData
        return try deflated.decompressed(using: .zlib) as Data
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
