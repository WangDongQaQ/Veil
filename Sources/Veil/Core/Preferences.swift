import SwiftUI
import Combine

// MARK: - Choices

enum ASRBackend: String, Codable, CaseIterable, Identifiable {
    case apple, doubao, openAICompatible
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "Apple 本机识别"
        case .doubao: "豆包语音识别（流式）"
        case .openAICompatible: "OpenAI 兼容接口"
        }
    }
}

enum RevealMode: String, Codable, CaseIterable, Identifiable {
    case block, spotlight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .block: "整段展开"
        case .spotlight: "跟随光标"
        }
    }
}

enum CaptionBackground: String, Codable, CaseIterable, Identifiable {
    case none, dim, glass
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "无（只有文字）"
        case .dim: "柔和暗色"
        case .glass: "玻璃"
        }
    }
}

enum WindowLevelChoice: String, Codable, CaseIterable, Identifiable {
    case floating, normal, desktop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .floating: "始终在最前"
        case .normal: "与普通窗口一致"
        case .desktop: "桌面层（像桌面小组件）"
        }
    }
}

enum FontDesignChoice: String, Codable, CaseIterable, Identifiable {
    case system, rounded, serif, monospaced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "系统"
        case .rounded: "圆体"
        case .serif: "衬线"
        case .monospaced: "等宽"
        }
    }
    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

enum FontWeightChoice: String, Codable, CaseIterable, Identifiable {
    case regular, medium, semibold, bold
    var id: String { rawValue }
    var title: String {
        switch self {
        case .regular: "常规"
        case .medium: "中等"
        case .semibold: "半粗"
        case .bold: "粗体"
        }
    }
    var weight: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

enum TextAlignChoice: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .leading: "靠左"
        case .center: "居中"
        case .trailing: "靠右"
        }
    }
    var alignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

enum TextAnchorChoice: String, Codable, CaseIterable, Identifiable {
    case top, bottom
    var id: String { rawValue }
    var title: String { self == .top ? "贴着左上角（从上往下排）" : "贴着底部（新字在下方）" }
}

enum TextTone: String, Codable, CaseIterable, Identifiable {
    case universal, light, dark, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .universal: "通用（白字深色描边，任何背景都清晰）"
        case .light: "浅色字（适合深色背景）"
        case .dark: "深色字（适合浅色背景）"
        case .custom: "自定义颜色"
        }
    }
}

struct RGBAColor: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double
    static let white = RGBAColor(r: 1, g: 1, b: 1, a: 1)

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// Rough perceived brightness, 0 (black) … 1 (white).
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                  b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

/// Where the speech-to-text endpoint lives. Anything that implements
/// `POST {base}/audio/transcriptions` (OpenAI, Groq, SiliconFlow, local whisper servers…) works.
struct APIPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let model: String
    let needsKey: Bool

    static let all: [APIPreset] = [
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini-transcribe", needsKey: true),
        .init(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo", needsKey: true),
        .init(id: "siliconflow", name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/SenseVoiceSmall", needsKey: true),
        .init(id: "local", name: "本机服务（localhost:8080）", baseURL: "http://127.0.0.1:8080/v1", model: "whisper-1", needsKey: false),
        .init(id: "custom", name: "自定义", baseURL: "", model: "", needsKey: true),
    ]
}

// MARK: - Preferences

struct Preferences: Codable, Equatable {
    // 通用
    var autoStartListening = false
    var inputDeviceUID: String? = nil          // nil = 系统默认

    // 识别
    var backend: ASRBackend = .apple
    var languageID: String = Preferences.defaultLanguageID()
    var apiPresetID: String = "openai"
    var apiBaseURL: String = "https://api.openai.com/v1"
    var apiModel: String = "gpt-4o-mini-transcribe"
    var apiPrompt: String = ""
    var apiAutoLanguage: Bool = false
    var apiLivePreview: Bool = true            // 说话过程中就请求中间结果（请求次数更多）
    var apiEndSilence: Double = 0.8            // 秒：多久不说话算一句结束
    var apiSensitivity: Double = 0.5           // 0…1
    var apiKeyRevision: Int = 0                // Keychain 里的 key 变了就 +1，用来触发重启

    // 豆包
    var doubaoResourceID: String = "volc.seedasr.sauc.duration"
    var doubaoTwoPass: Bool = true             // 二遍识别：先快出字，再用更准的结果定稿
    var doubaoDailyLimitMinutes: Int = 60      // 每日上限（分钟），0 = 不限
    var doubaoFallbackToApple: Bool = true     // 超过上限后自动改用本机识别

    // 字幕外观
    var fontDesign: FontDesignChoice = .rounded
    var fontWeight: FontWeightChoice = .medium
    var fontSize: Double = 26
    var tone: TextTone = .universal
    var textColor: RGBAColor = .white          // only used when tone == .custom
    var textAlign: TextAlignChoice = .leading
    var textAnchor: TextAnchorChoice = .top
    var allowScrollBack: Bool = true           // 文字超出显示区域时，悬停可上下翻阅
    var textShadow: Bool = true
    var background: CaptionBackground = .none
    var retentionSeconds: Double = 14          // 0 = 不自动清除
    var maxCharacters: Int = 240

    // 遮罩
    var spoilerEnabled: Bool = true
    var revealMode: RevealMode = .block
    var spotlightRadius: Double = 90
    var hideDelay: Double = 0.5
    var dustDensity: Double = 0.55             // 0…1
    var dustSpeed: Double = 0.5                // 0…1
    var dustIntensity: Double = 0.4            // 0…1 浓淡：颗粒、描边、底雾的整体强度
    var dustUsesTextColor: Bool = true
    var dustColor: RGBAColor = .white

    // 窗口
    var windowLevel: WindowLevelChoice = .floating
    var showOnAllSpaces: Bool = true
    var overallOpacity: Double = 1.0

    // 引导
    var hasCompletedFirstRun: Bool = false
    /// Bumped when a default changes in a way existing users should also get.
    ///  2: captions start at the top-left instead of the bottom.
    var schemaVersion: Int = 2

    static func defaultLanguageID() -> String {
        let preferred = Locale.preferredLanguages
        // Veil's own UI is Chinese, so any Chinese in the language list wins.
        if preferred.contains(where: { $0.hasPrefix("zh") }) { return "zh-CN" }
        let first = preferred.first ?? "en-US"
        if first.hasPrefix("ja") { return "ja-JP" }
        if first.hasPrefix("ko") { return "ko-KR" }
        if first.hasPrefix("fr") { return "fr-FR" }
        if first.hasPrefix("de") { return "de-DE" }
        if first.hasPrefix("es") { return "es-ES" }
        return "en-US"
    }

    var apiPreset: APIPreset { APIPreset.all.first { $0.id == apiPresetID } ?? APIPreset.all[0] }
}

/// Colors for the text and its dust. Every color carries an opposite-tone halo, so text and dust stay
/// visible whether the desktop behind the widget is white, black or a busy wallpaper.
struct CaptionPalette {
    var text: Color
    var halo: Color
    var dust: Color
    var dustHalo: Color
    /// Faint constant wash under the dust that gives the glyph silhouettes a body.
    var dustWash: Color
    /// Outline-style halo (universal tone) instead of a soft drop shadow.
    var strongOutline: Bool
}

extension Preferences {
    var palette: CaptionPalette {
        let ink = RGBAColor(r: 0.07, g: 0.08, b: 0.11, a: 1)
        let text: RGBAColor
        switch tone {
        case .universal, .light: text = .white
        case .dark: text = ink
        case .custom: text = textColor
        }
        let dust = dustUsesTextColor ? text : dustColor
        func halo(for c: RGBAColor) -> Color { c.luminance > 0.5 ? .black : .white }
        // Universal tone has to work on light pages too, so its wash is the dark halo; light/dark tones
        // use the dust's own color (dark text → dark wash on a light page, and vice versa).
        let wash = tone == .universal ? halo(for: dust) : dust.color
        return CaptionPalette(text: text.color, halo: halo(for: text),
                              dust: dust.color, dustHalo: halo(for: dust), dustWash: wash,
                              strongOutline: tone == .universal)
    }
}

extension Preferences {
    /// Forward-compatible load: every stored key is validated on its own, so a renamed/invalid value
    /// (or a newly added setting) never resets the rest of the user's configuration.
    static func load(from data: Data) -> Preferences {
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(Preferences()),
              var merged = try? JSONSerialization.jsonObject(with: defaultData) as? [String: Any]
        else { return Preferences() }

        for (key, value) in stored {
            var trial = merged
            trial[key] = value
            if let d = try? JSONSerialization.data(withJSONObject: trial),
               (try? JSONDecoder().decode(Preferences.self, from: d)) != nil {
                merged = trial
            }
        }
        // One-time migrations.
        let storedVersion = stored["schemaVersion"] as? Int ?? 1
        if storedVersion < 2 { merged["textAnchor"] = TextAnchorChoice.top.rawValue }
        merged["schemaVersion"] = Preferences().schemaVersion

        guard let d = try? JSONSerialization.data(withJSONObject: merged),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: d) else { return Preferences() }
        return prefs
    }
}

// MARK: - Store

@MainActor
final class AppSettings: ObservableObject {
    private static let key = "preferences.v1"
    private let defaults: UserDefaults

    @Published var p: Preferences {
        didSet { persist() }
    }

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            p = Preferences.load(from: data)
        } else {
            p = Preferences()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(p) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func resetAll() { p = Preferences() }
}
