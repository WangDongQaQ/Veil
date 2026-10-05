import SwiftUI

struct RecognitionSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    @State private var appleLocales: [Locale] = []
    @State private var installedIDs: Set<String> = []
    @State private var downloadProgress: Double?
    @State private var downloadError: String?

    @State private var apiKey = Keychain.get(Keychain.asrAPIKeyAccount) ?? ""
    @State private var doubaoKey = Keychain.get(Keychain.doubaoAPIKeyAccount) ?? ""
    @State private var testState: TestState = .idle

    enum TestState: Equatable { case idle, running, ok, failed(String) }

    var body: some View {
        Form {
            Section {
                Picker("识别引擎", selection: $settings.p.backend) {
                    ForEach(ASRBackend.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("状态") {
                    Text(model.statusLine)
                        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                switch settings.p.backend {
                case .apple: Text("完全在本机运行，音频不会离开你的 Mac。")
                case .doubao: Text("只有检测到人声的音频会发送到火山引擎，静音不会上传。")
                case .openAICompatible: Text("音频会发送到你填写的接口地址。选择本机服务时不会离开你的 Mac。")
                }
            }

            switch settings.p.backend {
            case .apple: appleSection
            case .doubao: doubaoSections
            case .openAICompatible: apiSections
            }
        }
        .settingsPane(maxHeight: settings.p.backend == .apple ? nil : 600)
        .task { await loadAppleLocales() }
        .onChange(of: settings.p.apiPresetID) { _, id in applyPreset(id) }
    }

    private var statusIsError: Bool {
        if case .failed = model.state { return true }
        return false
    }

    // MARK: Apple on-device

    @ViewBuilder
    private var appleSection: some View {
        Section {
            Picker("语言", selection: $settings.p.languageID) {
                ForEach(languageChoices, id: \.id) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
            LabeledContent("语言模型") {
                if let progress = downloadProgress {
                    HStack(spacing: 8) {
                        ProgressView(value: progress).frame(width: 110)
                        Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                } else if installedIDs.contains(settings.p.languageID) {
                    Label("已安装", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("下载…") { download(settings.p.languageID) }
                }
            }
            if let downloadError {
                Text(downloadError).font(.callout).foregroundStyle(.red)
            }
        } footer: {
            Text("首次使用某种语言时，系统会下载一次对应的语言模型（也会在开始听写时自动下载）。")
        }
    }

    private struct LanguageChoice { let id: String; let name: String }

    private var languageChoices: [LanguageChoice] {
        var choices = appleLocales.map { locale -> LanguageChoice in
            let id = locale.identifier(.bcp47)
            return LanguageChoice(id: id, name: Locale.current.localizedString(forIdentifier: id) ?? id)
        }
        if !choices.contains(where: { $0.id == settings.p.languageID }) {
            let id = settings.p.languageID
            choices.append(LanguageChoice(id: id, name: Locale.current.localizedString(forIdentifier: id) ?? id))
        }
        return choices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func loadAppleLocales() async {
        appleLocales = await AppleSpeechEngine.supportedLocales()
        installedIDs = await AppleSpeechEngine.installedLocaleIDs()
    }

    private func download(_ id: String) {
        downloadError = nil
        downloadProgress = 0
        Task {
            do {
                try await AppleSpeechEngine.install(localeID: id) { value in
                    Task { @MainActor in downloadProgress = value }
                }
                installedIDs = await AppleSpeechEngine.installedLocaleIDs()
            } catch {
                downloadError = error.localizedDescription
            }
            downloadProgress = nil
        }
    }

    // MARK: Doubao

    private static let limitChoices: [Int] = [15, 30, 60, 120, 240, 0]

    @ViewBuilder
    private var doubaoSections: some View {
        Section {
            SecureField("API Key", text: $doubaoKey, prompt: Text("粘贴火山引擎控制台里的 API Key"))
                .onChange(of: doubaoKey) { _, value in
                    Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), account: Keychain.doubaoAPIKeyAccount)
                    settings.p.apiKeyRevision += 1
                }
            Picker("识别模型", selection: $settings.p.doubaoResourceID) {
                Text("豆包流式识别 2.0（推荐）").tag("volc.seedasr.sauc.duration")
                Text("豆包流式识别 1.0").tag("volc.bigasr.sauc.duration")
            }
            Toggle("二遍识别（先快速出字，再用更准的结果定稿）", isOn: $settings.p.doubaoTwoPass)
            HStack {
                Button("测试连接") { runDoubaoTest() }
                    .disabled(testState == .running || doubaoKey.isEmpty)
                testResultView
                Spacer()
            }
        } header: {
            Text("接口")
        } footer: {
            Text("在火山引擎控制台的「豆包语音」里创建 API Key 并开通流式语音识别。Key 保存在钥匙串里。语言由模型自动判断（普通话、英语和多种方言）。")
        }

        Section {
            LabeledContent("今日已发送") {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let usage = UsageTracker.shared
                    Text("\(UsageTracker.format(seconds: usage.todaySeconds)) · 约 ¥\(usage.todayCostYuan, specifier: "%.2f")")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Picker("每日上限", selection: $settings.p.doubaoDailyLimitMinutes) {
                ForEach(Self.limitChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? "不限" : "\(minutes) 分钟").tag(minutes)
                }
            }
            Toggle("超过上限后自动改用本机识别", isOn: $settings.p.doubaoFallbackToApple)
        } header: {
            Text("用量与费用")
        } footer: {
            Text("豆包按音频时长计费（后付费约 ¥1 / 小时），不按 token。Veil 只发送检测到人声的片段：静音和键盘声不会上传，说话满 0.25 秒才会建立连接，每句话一个短连接、说完即关。费用为估算，以火山引擎账单为准。")
        }

        segmentationSection(showLivePreview: false)
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .ok: Label("连接正常", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Text(message).font(.callout).foregroundStyle(.red).lineLimit(3)
        }
    }

    private func runDoubaoTest() {
        testState = .running
        let config = model.doubaoConfig()
        Task {
            switch await DoubaoStreamingEngine.testConnection(config) {
            case .success: testState = .ok
            case .failure(let error): testState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: OpenAI-compatible

    private static let commonLanguages: [(id: String, name: String)] = [
        ("zh-CN", "中文（普通话）"), ("en-US", "English"), ("ja-JP", "日本語"), ("ko-KR", "한국어"),
        ("fr-FR", "Français"), ("de-DE", "Deutsch"), ("es-ES", "Español"), ("ru-RU", "Русский"),
        ("pt-BR", "Português"), ("it-IT", "Italiano"),
    ]

    @ViewBuilder
    private var apiSections: some View {
        Section {
            Picker("服务", selection: $settings.p.apiPresetID) {
                ForEach(APIPreset.all) { Text($0.name).tag($0.id) }
            }
            TextField("接口地址", text: $settings.p.apiBaseURL, prompt: Text("https://…/v1"))
                .autocorrectionDisabled()
            TextField("模型", text: $settings.p.apiModel, prompt: Text("whisper-1"))
                .autocorrectionDisabled()
            SecureField("API Key", text: $apiKey, prompt: Text(settings.p.apiPreset.needsKey ? "必填" : "本机服务通常不需要"))
                .onChange(of: apiKey) { _, value in
                    Keychain.set(value, account: Keychain.asrAPIKeyAccount)
                    settings.p.apiKeyRevision += 1
                }
            HStack {
                Button("测试连接") { runTest() }
                    .disabled(testState == .running)
                switch testState {
                case .idle: EmptyView()
                case .running: ProgressView().controlSize(.small)
                case .ok: Label("连接正常", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    Text(message).font(.callout).foregroundStyle(.red).lineLimit(3)
                }
                Spacer()
            }
        } header: {
            Text("接口")
        } footer: {
            Text("任何兼容 OpenAI「/audio/transcriptions」的服务都可以，例如 OpenAI、Groq、硅基流动，或本机运行的 whisper.cpp / faster-whisper-server / mlx-whisper 服务。API Key 保存在钥匙串里。")
        }

        Section("语言") {
            Toggle("自动检测语言", isOn: $settings.p.apiAutoLanguage)
            if !settings.p.apiAutoLanguage {
                Picker("语言", selection: $settings.p.languageID) {
                    ForEach(Self.commonLanguages, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            TextField("提示词（可选）", text: $settings.p.apiPrompt, axis: .vertical)
                .lineLimit(1...3)
        }

        segmentationSection(showLivePreview: true)
    }

    @ViewBuilder
    private func segmentationSection(showLivePreview: Bool) -> some View {
        Section {
            LabeledContent("停顿多久算一句结束") {
                HStack {
                    Slider(value: $settings.p.apiEndSilence, in: 0.4...2.0, step: 0.1)
                        .frame(width: 180)
                    Text("\(settings.p.apiEndSilence, specifier: "%.1f") 秒")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }
            LabeledContent("拾音灵敏度") {
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $settings.p.apiSensitivity, in: 0...1).frame(width: 160)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
            }
            if showLivePreview {
                Toggle("说话时实时预览", isOn: $settings.p.apiLivePreview)
            }
        } header: {
            Text("分句")
        } footer: {
            Text(showLivePreview
                 ? "接口不是流式的，所以 Veil 会按停顿切句再发送。开启实时预览后，一句话说到一半就会请求一次中间结果，字幕更快出现，但请求次数更多。灵敏度越高，越容易收到远处或小声的说话。"
                 : "灵敏度越高，越容易收到远处或小声的说话，但也更容易被杂音触发（会多发一点音频）。停顿时间越短，字幕分句越碎。")
        }
    }

    private func applyPreset(_ id: String) {
        guard let preset = APIPreset.all.first(where: { $0.id == id }), id != "custom" else { return }
        settings.p.apiBaseURL = preset.baseURL
        settings.p.apiModel = preset.model
    }

    private func runTest() {
        testState = .running
        let config = model.apiConfig()
        Task {
            switch await OpenAICompatibleEngine.testConnection(config) {
            case .success: testState = .ok
            case .failure(let error): testState = .failed(error.localizedDescription)
            }
        }
    }
}
