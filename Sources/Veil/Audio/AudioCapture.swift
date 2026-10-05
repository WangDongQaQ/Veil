import AVFoundation
import CoreAudio

enum CaptureError: LocalizedError {
    case noInput
    case denied
    var errorDescription: String? {
        switch self {
        case .noInput: "找不到可用的麦克风。"
        case .denied: "没有麦克风权限。请在「系统设置 › 隐私与安全性 › 麦克风」里允许 Veil。"
        }
    }
}

/// Thin wrapper over AVAudioEngine that taps one microphone and forwards raw buffers.
final class AudioCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var tapFormat: AVAudioFormat?
    private(set) var isRunning = false

    /// Audio thread.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Audio thread. RMS in 0…1.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Main queue. Fires when the route changed underneath us (headphones plugged, device removed…).
    var onRouteChange: (@Sendable () -> Void)?

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestAccess() async -> Bool {
        switch authorizationStatus() {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(deviceUID: String?) throws {
        stop()
        engine = AVAudioEngine()
        let input = engine.inputNode

        if let uid = deviceUID, var device = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &device,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        tapFormat = format

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer?(buffer)
            if let onLevel = self.onLevel { onLevel(Self.rms(buffer)) }
        }

        engine.prepare()
        try engine.start()
        isRunning = true

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.engineConfigurationChanged() }
    }

    /// AVAudioEngine also posts this when *we* just pointed its I/O unit at a specific microphone, and again
    /// after any restart. Rebuilding the engine on every one of those makes a self-sustaining loop (the microphone
    /// indicator flickers several times a second and no audio gets through), so only react to real changes:
    /// the engine stopped, or the input format is no longer the one the tap was installed with.
    private func engineConfigurationChanged() {
        guard isRunning else { return }
        if engine.isRunning, let tapFormat {
            let now = engine.inputNode.outputFormat(forBus: 0)
            if now.sampleRate == tapFormat.sampleRate, now.channelCount == tapFormat.channelCount { return }
        }
        onRouteChange?()
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += channel[i] * channel[i] }
        return (sum / Float(n)).squareRoot()
    }
}
