import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection = ProcessInfo.processInfo.environment["VEIL_SETTINGS_TAB"] ?? "general"

    var body: some View {
        TabView(selection: $selection) {
            Tab("通用", systemImage: "gearshape", value: "general") {
                GeneralSettings(model: model, settings: model.settings)
            }
            Tab("识别", systemImage: "waveform", value: "recognition") {
                RecognitionSettings(model: model, settings: model.settings)
            }
            Tab("字幕", systemImage: "captions.bubble", value: "appearance") {
                AppearanceSettings(model: model, settings: model.settings)
            }
            Tab("遮罩", systemImage: "sparkles", value: "spoiler") {
                SpoilerSettings(model: model, settings: model.settings)
            }
            Tab("窗口", systemImage: "macwindow", value: "window") {
                WindowSettings(model: model, settings: model.settings)
            }
        }
        .frame(width: 540)
    }
}

// MARK: - Shared bits

extension View {
    /// Settings panes in a grouped form, sized to their content like System Settings does.
    /// Very long panes pass `maxHeight` instead and scroll, so they still fit on a small display.
    @ViewBuilder
    func settingsPane(maxHeight: CGFloat? = nil) -> some View {
        if let maxHeight {
            self.formStyle(.grouped).frame(height: maxHeight)
        } else {
            self.formStyle(.grouped).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ColorBinding {
    static func make(_ binding: Binding<RGBAColor>) -> Binding<Color> {
        Binding(get: { binding.wrappedValue.color }, set: { binding.wrappedValue = RGBAColor($0) })
    }
}

// MARK: - 通用

struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var meter: LevelMeter

    @StateObject private var deviceList = AudioDeviceList()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        self.meter = model.meter
    }

    var body: some View {
        Form {
            Section {
                Picker("输入设备", selection: $settings.p.inputDeviceUID) {
                    Text("系统默认\(AudioDevices.defaultInputName().map { "（\($0)）" } ?? "")").tag(String?.none)
                    Divider()
                    ForEach(deviceList.devices) { device in
                        Text(label(for: device)).tag(Optional(device.uid))
                    }
                }
                if model.isListening {
                    LabeledContent("输入电平") {
                        ProgressView(value: min(1, Double(meter.value) * 8))
                            .frame(width: 160)
                            .accessibilityLabel("输入电平")
                    }
                }
            } header: {
                Text("麦克风")
            } footer: {
                Text("戴着蓝牙降噪耳机（如 AirPods）时，建议选择「MacBook 内置麦克风」：这样耳机不会为了收音切换到通话模式，音质和降噪都不受影响。")
            }

            Section("启动") {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if loginItemNeedsApproval {
                    Button("在「登录项」里允许 Veil…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("启动后自动开始听写", isOn: $settings.p.autoStartListening)
            }

            Section("全局快捷键") {
                LabeledContent("开始 / 暂停听写") { Text("⌃⌥⌘L").foregroundStyle(.secondary) }
                LabeledContent("显示 / 隐藏字幕") { Text("⌃⌥⌘H").foregroundStyle(.secondary) }
                LabeledContent("调整位置与大小") { Text("⌃⌥⌘E").foregroundStyle(.secondary) }
            }
        }
        .settingsPane()
        .onAppear {
            deviceList.refresh()
            model.meter.isObserved = true
            refreshLoginState()
        }
        .onDisappear { model.meter.isObserved = false }
    }

    private func label(for device: AudioInputDevice) -> String {
        if device.isBluetooth { return "\(device.name)（蓝牙）" }
        return device.name
    }

    private func refreshLoginState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Veil: login item change failed: \(error)")
        }
        refreshLoginState()
    }
}

/// Live list of microphones; registers its Core Audio listener exactly once.
@MainActor
final class AudioDeviceList: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = AudioDevices.inputDevices()
    private var observer: Any?

    init() {
        observer = AudioDevices.observeChanges { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() { devices = AudioDevices.inputDevices() }
}
