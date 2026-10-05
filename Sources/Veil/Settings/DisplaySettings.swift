import SwiftUI

// MARK: - 字幕

struct AppearanceSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    private static let retentionChoices: [Double] = [6, 10, 14, 20, 30, 60, 0]

    var body: some View {
        Form {
            Section("文字") {
                Picker("字体", selection: $settings.p.fontDesign) {
                    ForEach(FontDesignChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("字重", selection: $settings.p.fontWeight) {
                    ForEach(FontWeightChoice.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("字号") {
                    HStack {
                        Slider(value: $settings.p.fontSize, in: 14...64, step: 1).frame(width: 190)
                        Text("\(Int(settings.p.fontSize)) pt")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                }
                Picker("配色", selection: $settings.p.tone) {
                    ForEach(TextTone.allCases) { Text($0.title).tag($0) }
                }
                if settings.p.tone == .custom {
                    ColorPicker("颜色", selection: ColorBinding.make($settings.p.textColor), supportsOpacity: true)
                }
                Picker("对齐", selection: $settings.p.textAlign) {
                    ForEach(TextAlignChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("文字描边（让文字在任何背景上都清晰）", isOn: $settings.p.textShadow)
            }

            Section("版面") {
                Picker("文字位置", selection: $settings.p.textAnchor) {
                    ForEach(TextAnchorChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("背景", selection: $settings.p.background) {
                    ForEach(CaptionBackground.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Picker("文字停留", selection: $settings.p.retentionSeconds) {
                    ForEach(Self.retentionChoices, id: \.self) { value in
                        Text(value == 0 ? "不自动清除" : "\(Int(value)) 秒").tag(value)
                    }
                }
                Stepper(value: $settings.p.maxCharacters, in: 60...1000, step: 20) {
                    LabeledContent("最多保留") { Text("\(settings.p.maxCharacters) 字").foregroundStyle(.secondary) }
                }
            } footer: {
                Text("说完一句后，文字会在停留时间结束时逐渐淡出。")
            }

            Section {
                Button("在桌面上预览与调整…") { model.setEditing(true) }
            }
        }
        .settingsPane()
    }
}

// MARK: - 遮罩

struct SpoilerSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("用遮罩隐藏字幕", isOn: $settings.p.spoilerEnabled)
            } footer: {
                Text("字幕出现时只会看到一团流动的尘雾，不会被旁边的人瞟到。光标移到文字上，遮罩才会散开。关闭后字幕直接显示。")
            }

            if settings.p.spoilerEnabled {
                Section("展开") {
                    Picker("方式", selection: $settings.p.revealMode) {
                        ForEach(RevealMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if settings.p.revealMode == .spotlight {
                        LabeledContent("聚光范围") {
                            HStack {
                                Slider(value: $settings.p.spotlightRadius, in: 40...220, step: 5).frame(width: 190)
                                Text("\(Int(settings.p.spotlightRadius)) pt")
                                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                            }
                        }
                    }
                    LabeledContent("光标离开后重新遮住") {
                        HStack {
                            Slider(value: $settings.p.hideDelay, in: 0...3, step: 0.1).frame(width: 150)
                            Text(settings.p.hideDelay == 0 ? "立即" : "\(settings.p.hideDelay, specifier: "%.1f") 秒")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                        }
                    }
                }

                Section {
                    SpoilerPreview(prefs: settings.p)
                    LabeledContent("浓淡") {
                        HStack(spacing: 6) {
                            Text("淡").foregroundStyle(.secondary)
                            Slider(value: $settings.p.dustIntensity, in: 0.1...1).frame(width: 170)
                            Text("浓").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("密度") {
                        Slider(value: $settings.p.dustDensity, in: 0...1).frame(width: 190)
                    }
                    LabeledContent("流动速度") {
                        Slider(value: $settings.p.dustSpeed, in: 0...1).frame(width: 190)
                    }
                    Toggle("颜色跟随文字", isOn: $settings.p.dustUsesTextColor)
                    if !settings.p.dustUsesTextColor {
                        ColorPicker("尘雾颜色", selection: ColorBinding.make($settings.p.dustColor), supportsOpacity: false)
                    }
                } header: {
                    Text("尘雾")
                } footer: {
                    Text("浓淡越低越不起眼，只提示「这里有字」。预览同时显示在浅色和深色背景上；文字配色可在「字幕」里选择。")
                }

                Section {
                    Button("在桌面上预览…") { model.setEditing(true) }
                } footer: {
                    Text("开启「减少动态效果」（系统设置 › 辅助功能 › 显示）后，尘雾会静止，展开也会变成快速淡入。")
                }
            }
        }
        .settingsPane()
    }
}

// MARK: - 窗口

struct WindowSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                Picker("层级", selection: $settings.p.windowLevel) {
                    ForEach(WindowLevelChoice.allCases) { Text($0.title).tag($0) }
                }
                Toggle("在所有桌面空间显示（包括全屏 App 上方）", isOn: $settings.p.showOnAllSpaces)
                LabeledContent("整体不透明度") {
                    HStack {
                        Slider(value: $settings.p.overallOpacity, in: 0.3...1).frame(width: 190)
                        Text("\(Int(settings.p.overallOpacity * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
            } footer: {
                Text("字幕窗口没有边框，也不会挡住下面的操作：鼠标点击会直接穿过它。「桌面层」会让它像桌面小组件一样被其他窗口盖住。")
            }

            Section {
                Button("调整位置与大小…") { model.setEditing(true) }
                Button("恢复默认位置") { model.resetWindowPosition() }
            } footer: {
                Text("进入调整模式后，拖动字幕框即可移动，拖拽四个角调整大小。")
            }

            Section {
                Button("还原所有设置…", role: .destructive) { confirmingReset = true }
            }
        }
        .settingsPane()
        .confirmationDialog("还原所有设置？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("还原", role: .destructive) { settings.resetAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("字幕外观、遮罩和识别设置都会恢复为默认值。API Key 不受影响。")
        }
    }
}


// MARK: - Live preview

/// The hidden-text dust as it currently looks, on a light and a dark backdrop side by side.
private struct SpoilerPreview: View {
    let prefs: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sample = "你好，下午的会议改到三点了，你方便吗？"

    var body: some View {
        HStack(spacing: 10) {
            swatch(background: .white, caption: "浅色背景", captionColor: .black.opacity(0.35))
            swatch(background: Color(white: 0.11), caption: "深色背景", captionColor: .white.opacity(0.4))
        }
        .accessibilityHidden(true)
    }

    private func swatch(background: Color, caption: String, captionColor: Color) -> some View {
        let palette = prefs.palette
        let radius = max(2.0, 17 * 0.09)
        let glyphs = Text(sample)
            .font(.system(size: 17, weight: prefs.fontWeight.weight, design: prefs.fontDesign.design))
            .foregroundStyle(.white)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(background)
            DustField(color: palette.dust, halo: palette.dustHalo, wash: palette.dustWash,
                      density: prefs.dustDensity, speed: prefs.dustSpeed, intensity: prefs.dustIntensity,
                      paused: reduceMotion)
                .mask(alignment: .topLeading) {
                    ZStack {
                        glyphs.blur(radius: radius)
                        glyphs.blur(radius: radius * 0.5)
                        glyphs
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(captionColor)
                .padding(7)
        }
        .frame(height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}
