import SwiftUI

@main
struct VeilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model, store: model.store)
        } label: {
            MenuBarIcon(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)      // menu bar only; also set through LSUIElement
        if DebugSnapshot.micProbeIfRequested() { return }
        AppModel.shared.bootstrap()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

// MARK: - Menu bar

private struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.state {
        case .listening:
            Image(systemName: "captions.bubble.fill")
        case .failed:
            Image(systemName: "exclamationmark.bubble")
        default:
            Image(systemName: "captions.bubble")
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: CaptionStore
    @Environment(\.openSettings) private var openSettings

    private let hotKeyModifiers: EventModifiers = [.control, .option, .command]

    var body: some View {
        Button(model.isListening || model.isBusy ? "暂停听写" : "开始听写") {
            model.toggleListening()
        }
        .keyboardShortcut("l", modifiers: hotKeyModifiers)

        Text(model.statusLine)

        if model.microphoneDenied {
            Button("打开麦克风隐私设置…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        Divider()

        Toggle("显示字幕", isOn: $model.captionsVisible)
            .keyboardShortcut("h", modifiers: hotKeyModifiers)

        Button(store.editMode ? "完成位置调整" : "调整位置与大小…") {
            model.toggleEditing()
        }
        .keyboardShortcut("e", modifiers: hotKeyModifiers)

        Button("清除字幕") { model.clearCaptions() }
            .disabled(!store.hasContent)

        Menu("文字配色") {
            Picker("文字配色", selection: Binding(get: { model.settings.p.tone },
                                                set: { model.settings.p.tone = $0 })) {
                Text("通用（任何背景）").tag(TextTone.universal)
                Text("浅色字（深色背景）").tag(TextTone.light)
                Text("深色字（浅色背景）").tag(TextTone.dark)
                if model.settings.p.tone == .custom { Text("自定义").tag(TextTone.custom) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Divider()

        Button("设置…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("退出 Veil") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
