import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MARK: - 设置窗口

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var langObserver: AnyCancellable?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 500))
            w.center()
            window = w
            // 窗口开着时切换语言，标题也要跟着换
            langObserver = L10n.shared.$language.sink { [weak self] lang in
                self?.window?.title = lang == .zh ? "MicType 设置" : "MicType Settings"
            }
        }
        window?.title = tr("MicType 设置", "MicType Settings")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 设置界面

struct SettingsView: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label(tr("通用", "General"), systemImage: "gearshape") }
            RecognitionTab()
                .tabItem { Label(tr("识别", "Recognition"), systemImage: "waveform") }
            PolishTab()
                .tabItem { Label(tr("AI 润色", "AI Polish"), systemImage: "wand.and.stars") }
            AboutTab()
                .tabItem { Label(tr("关于", "About"), systemImage: "info.circle") }
        }
        .frame(width: 560, height: 500)
    }
}

// MARK: - 通用

private struct GeneralTab: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.hotkey) private var hotkey = HotkeyChoice.rightOption.rawValue
    @AppStorage(SettingsKeys.playSounds) private var playSounds = true
    @AppStorage(SettingsKeys.restoreClipboard) private var restoreClipboard = true
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var micOK = Permissions.microphoneGranted
    @State private var axOK = Permissions.isAccessibilityTrusted
    private let permTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Picker(tr("界面语言 / Language:", "Language / 界面语言:"), selection: $l10n.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Picker(tr("听写快捷键：", "Dictation hotkey:"), selection: $hotkey) {
                    ForEach(HotkeyChoice.allCases, id: \.rawValue) { choice in
                        Text(choice.displayName).tag(choice.rawValue)
                    }
                }
                Text(tr("轻点：开始 / 结束听写 · 按住说话、松手：执行语音指令 · 录音中按 Esc 取消。",
                        "Tap: start / stop dictation · Hold to speak a command, release to run · Esc cancels."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle(tr("开始 / 完成时播放提示音", "Play sounds on start / finish"), isOn: $playSounds)
                Toggle(tr("输入后恢复原剪贴板内容", "Restore clipboard after inserting"), isOn: $restoreClipboard)
                Toggle(tr("登录时自动启动", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = (SMAppService.mainApp.status == .enabled)
                        }
                    }
            }

            Section {
                HStack {
                    Text(tr("权限：", "Permissions:"))
                    PermissionBadge(name: tr("麦克风", "Microphone"), ok: micOK)
                    PermissionBadge(name: tr("辅助功能", "Accessibility"), ok: axOK)
                    Spacer()
                    Button(tr("打开系统设置", "Open System Settings")) {
                        Permissions.openAccessibilitySettings()
                    }
                }
                .onReceive(permTimer) { _ in
                    micOK = Permissions.microphoneGranted
                    axOK = Permissions.isAccessibilityTrusted
                }
                Text(tr("「辅助功能」权限用于监听快捷键和把文字粘贴到光标处，必须开启。",
                        "Accessibility is required for the global hotkey and for pasting text at the cursor."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !axOK {
                    Text(tr("如果系统设置里显示已开启但这里仍是 ✗：是旧版授权失效了。请在 辅助功能 列表中选中 MicType，点「−」删除，再点「+」重新添加。",
                            "If System Settings shows it enabled but this still shows ✗, the old grant is stale: remove MicType from the Accessibility list (−), then add it back (+)."))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}

private struct PermissionBadge: View {
    let name: String
    let ok: Bool
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? .green : .red)
            Text(name)
        }
        .font(.caption)
    }
}

// MARK: - 识别（Qwen3-ASR）

private struct RecognitionTab: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.qwenModelRepo) private var qwenRepo = QwenModels.defaultRepo
    @AppStorage(SettingsKeys.customVocabulary) private var vocabulary = ""
    @ObservedObject private var downloader = QwenModelDownloader.shared
    @State private var refreshTick = 0
    @State private var updateMessage = ""
    @State private var checkingUpdate = false

    private var modelExists: Bool {
        _ = refreshTick
        let dir = QwenModels.localDirectory(for: qwenRepo)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }

    var body: some View {
        Form {
            Section {
                Picker(tr("识别模型：", "Speech model:"), selection: $qwenRepo) {
                    ForEach(QwenModels.all, id: \.repo) { m in
                        Text("\(m.title) · \(m.sizeNote)").tag(m.repo)
                    }
                }
                HStack {
                    Image(systemName: modelExists ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundColor(modelExists ? .green : .orange)
                    Text(modelExists ? tr("模型已就绪", "Model ready")
                                     : tr("模型未下载", "Model not downloaded"))
                    Spacer()
                    if downloader.isDownloading {
                        Button(tr("取消", "Cancel")) { downloader.cancel() }
                    } else {
                        Button(modelExists ? tr("重新下载 / 更新", "Re-download / Update")
                                           : tr("下载模型", "Download Model")) {
                            updateMessage = ""
                            QwenEngine.shared.unloadModel()
                            downloader.download(repo: qwenRepo, force: modelExists)
                        }
                        Button(checkingUpdate ? tr("检查中…", "Checking…") : tr("检查更新", "Check Updates")) {
                            checkingUpdate = true
                            updateMessage = ""
                            QwenModelDownloader.checkForUpdate(repo: qwenRepo) { _, message in
                                checkingUpdate = false
                                updateMessage = message
                            }
                        }
                        .disabled(checkingUpdate)
                    }
                }
                if downloader.isDownloading {
                    ProgressView(value: downloader.progress)
                }
                if !downloader.statusText.isEmpty {
                    Text(downloader.statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !updateMessage.isEmpty {
                    Text(updateMessage)
                        .font(.caption)
                        .foregroundColor(updateMessage.contains(tr("发现新版本", "Update available")) ? .orange : .secondary)
                }
                Text(tr("Qwen3-ASR（2026）：约 30 种语言 + 22 种中文方言，自动检测语言，识别完全在本机进行。模型来自 HuggingFace（hf-mirror 加速）。",
                        "Qwen3-ASR (2026): ~30 languages + 22 Chinese dialects, automatic language detection, fully on-device. Models from HuggingFace."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("专有词汇表（人名、品牌、术语等，用逗号或换行分隔）：",
                            "Custom vocabulary (names, brands, jargon — comma or newline separated):"))
                    TextEditor(text: $vocabulary)
                        .font(.system(size: 12))
                        .frame(height: 80)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                    Text(tr("这些词会作为热词直接送入识别模型，并参与 AI 润色纠错——专有名词识别准确率的第一杠杆，强烈建议填写。\n支持硬替换：填「杰文=捷文」表示识别出的「杰文」一律改成「捷文」——确定性替换、零耗时，对完全同音的人名最有效。",
                            "These terms are fed to the speech model as hotwords and used by AI polish — the #1 lever for proper-noun accuracy.\nHard replacement supported: an entry like \"Jevin=Jaywen\" deterministically rewrites every occurrence — zero latency, ideal for exact-homophone names."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onReceive(downloader.$isDownloading) { _ in
            refreshTick += 1
        }
        .onChange(of: qwenRepo) { _, _ in
            updateMessage = ""
            QwenEngine.shared.unloadModel()
            refreshTick += 1
        }
        // 已生成的状态文字是快照，切换语言后清掉，避免残留旧语言
        .onChange(of: l10n.language) { _, _ in
            updateMessage = ""
            if !downloader.isDownloading { downloader.statusText = "" }
        }
    }
}

// MARK: - AI 润色

private struct PolishTab: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.polishLevel) private var polishLevel = PolishLevel.smart.rawValue
    @AppStorage(SettingsKeys.llmProvider) private var provider = LLMProvider.openai.rawValue
    @AppStorage(SettingsKeys.openaiBaseURL) private var baseURL = "https://api.openai.com/v1"
    @AppStorage(SettingsKeys.chatModel) private var chatModel = "gpt-5.5"
    @AppStorage(SettingsKeys.openaiCommandModel) private var openaiCommandModel = "gpt-5.4-mini"
    @AppStorage(SettingsKeys.deepseekBaseURL) private var dsBaseURL = LLMProvider.deepseek.defaultBaseURL
    @AppStorage(SettingsKeys.deepseekModel) private var dsModel = LLMProvider.deepseek.defaultModel
    @AppStorage(SettingsKeys.deepseekCommandModel) private var dsCommandModel = LLMProvider.deepseek.defaultModel
    @AppStorage(SettingsKeys.polishTemperature) private var polishTemp = 0.5
    @AppStorage(SettingsKeys.commandTemperature) private var commandTemp = 1.0
    @AppStorage(SettingsKeys.aboutMe) private var aboutMe = ""
    @State private var apiKey = KeychainHelper.loadAPIKey() ?? ""
    @State private var openaiSaved = (KeychainHelper.loadAPIKey(account: LLMProvider.openai.keychainAccount) != nil)
    @State private var dsSaved = (KeychainHelper.loadAPIKey(account: LLMProvider.deepseek.keychainAccount) != nil)
    @AppStorage(SettingsKeys.customPolishRules) private var customRules = ""
    @State private var testResult = ""
    @State private var testing = false

    // 快选预设（输入框仍可手填任意模型名）
    private static let openaiPresets = ["gpt-5.4-nano", "gpt-5.4-mini", "gpt-5.4", "gpt-5.5"]
    private static let deepseekPresets = ["deepseek-v4-flash", "deepseek-chat", "deepseek-v4-pro"]

    var body: some View {
        Form {
            Section {
                Picker(tr("润色档位：", "Polish mode:"), selection: $polishLevel) {
                    ForEach(PolishLevel.allCases, id: \.rawValue) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(tr("「仅识别」完全不联网；「AI 润色」自适应处理力度——短句只做轻清理（去语气词、修错字），长段混乱口述自动重构成可直接使用的成品文字。所有应用同一套规则，档位完全由你决定；菜单栏图标里可以快速切换。",
                        "Transcribe-only never touches the network. AI polish adapts: short phrases get light cleanup (fillers, typos); long rambling speech gets restructured into ready-to-use text. Same rules in every app — the mode is entirely your choice. Switch quickly from the menu bar."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Text(tr("语音指令（按住快捷键）：选中文字后按住开口，AI 自动判断意图——要求加工这段文字（改写/翻译）→ 直接替换选区；要求回复对方（「回复他…」「跟他说…」）→ 草稿进剪贴板按 ⌘V；要求写新东西 → 结果输出到光标处。什么都没选就是自由指令（草拟邮件、翻译、提问）。",
                        "Voice commands (hold the hotkey): with text selected, speak naturally and AI infers the intent — transform the text (rewrite/translate) → selection replaced; reply to the sender (\"reply to him…\", \"tell them…\") → draft lands on the clipboard, press ⌘V; compose something new → result typed at your cursor. With nothing selected it's a free-form command (draft an email, translate, ask anything)."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Picker(tr("当前使用：", "Active provider:"), selection: $provider) {
                    ForEach(LLMProvider.allCases, id: \.rawValue) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: provider) { _, newValue in
                    let account = LLMProvider(rawValue: newValue)?.keychainAccount
                    apiKey = KeychainHelper.loadAPIKey(account: account) ?? ""
                    testResult = ""
                }
                HStack(spacing: 14) {
                    Text(tr("润色和语音指令将使用上方选中的服务商", "Polish and voice commands use the provider selected above"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    KeyStatusBadge(name: "GPT", saved: openaiSaved)
                    KeyStatusBadge(name: "DeepSeek", saved: dsSaved)
                }
                SecureField(provider == LLMProvider.deepseek.rawValue
                            ? tr("DeepSeek API Key（sk-…）", "DeepSeek API key (sk-…)")
                            : tr("OpenAI API Key（sk-…）", "OpenAI API key (sk-…)"),
                            text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(tr("保存 Key", "Save Key")) {
                        KeychainHelper.saveAPIKey(apiKey)
                        refreshSavedStates()
                        testResult = (KeychainHelper.loadAPIKey() != nil)
                            ? tr("已保存 ✓", "Saved ✓") : tr("已清空", "Cleared")
                    }
                    Spacer()
                }
                Text(tr("Key 加密保存在 macOS 系统钥匙串里（可在「钥匙串访问」App 中查看），仅本机可读，不写入任何明文文件。两个服务商的 Key 都可以保存，互不覆盖。",
                        "Keys are encrypted in the macOS Keychain (visible in the Keychain Access app), readable only on this Mac, never written to plain files. Both providers' keys can be saved independently."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                if provider == LLMProvider.deepseek.rawValue {
                    TextField(tr("Base URL", "Base URL"), text: $dsBaseURL)
                        .textFieldStyle(.roundedBorder)
                    ModelField(label: tr("润色模型（求快）", "Polish model (fast)"),
                               text: $dsModel, presets: Self.deepseekPresets,
                               testing: testing,
                               onTest: { runModelTest(tr("润色模型", "Polish model"), dsModel) })
                    ModelField(label: tr("指令模型（求好）", "Command model (strong)"),
                               text: $dsCommandModel, presets: Self.deepseekPresets,
                               testing: testing,
                               onTest: { runModelTest(tr("指令模型", "Command model"), dsCommandModel) })
                    Text(tr("润色高频求快、指令低频求好，两个模型分开配。右侧下拉快选：flash 快且便宜，pro 更强，deepseek-chat 是 flash 非思考别名（响应慢时用）。也可手填任意模型名。Key 在 platform.deepseek.com 申请。",
                            "Polish runs often and wants speed; commands run rarely and want quality. Quick-pick on the right: flash is fast & cheap, pro is stronger, deepseek-chat is flash without thinking mode. Or type any model name. Get a key at platform.deepseek.com."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    TextField(tr("Base URL", "Base URL"), text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                    ModelField(label: tr("润色模型（求快）", "Polish model (fast)"),
                               text: $chatModel, presets: Self.openaiPresets,
                               testing: testing,
                               onTest: { runModelTest(tr("润色模型", "Polish model"), chatModel) })
                    ModelField(label: tr("指令模型（求好）", "Command model (strong)"),
                               text: $openaiCommandModel, presets: Self.openaiPresets,
                               testing: testing,
                               onTest: { runModelTest(tr("指令模型", "Command model"), openaiCommandModel) })
                    Text(tr("润色高频求快（默认 nano），指令低频求好（默认 mini）。右侧下拉可快选 OpenAI 当前在售型号——gpt-5.4 标准版质量高于 mini 价格半于 5.5，gpt-5.5 旗舰最强。也可手填任何 OpenAI 兼容服务的模型名。",
                            "Polish runs often and wants speed (default nano); commands run rarely and want quality (default mini). Quick-pick current OpenAI models on the right — gpt-5.4 beats mini at half the price of 5.5; gpt-5.5 is the flagship. Or type any OpenAI-compatible model name."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text(tr("润色温度：", "Polish temperature:"))
                    Slider(value: $polishTemp, in: 0...1.5)
                    Text(String(format: "%.2f", polishTemp))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                HStack {
                    Text(tr("指令温度：", "Command temperature:"))
                    Slider(value: $commandTemp, in: 0...1.5)
                    Text(String(format: "%.2f", commandTemp))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                Text(tr("低 = 稳定保真，高 = 自然多样。默认：润色 0.5 / 指令 1.00（即模型默认值）。推理系模型（gpt-5.5 等）只接受默认温度，其他值会被自动忽略。",
                        "Lower = faithful and stable; higher = natural and varied. Defaults: polish 0.5 / commands 1.00 (the model default). Reasoning models (gpt-5.5 etc.) only accept the default — other values are ignored automatically."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("关于我（可选）：", "About me (optional):"))
                    TextEditor(text: $aboutMe)
                        .font(.system(size: 12))
                        .frame(height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                    Text(tr("例如：「署名用 Gen」「邮件偏正式、聊天随意」「MBA 学生，常写商务邮件」。语音指令草拟邮件/回复时会代入这些信息。",
                            "E.g. \"sign as Gen\", \"formal in email, casual in chat\". Voice commands use this when drafting emails and replies."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("自定义规则（可选，润色和指令都生效）：", "Custom rules (optional — applies to polish and commands):"))
                    TextEditor(text: $customRules)
                        .font(.system(size: 12))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                    Text(tr("例如：「邮件场景用正式语气」「英文术语保留原文不翻译」「数字用阿拉伯数字」。",
                            "E.g. \"formal tone for emails\", \"keep English jargon untranslated\", \"use Arabic numerals\"."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        // 测试结果是快照，切换语言后清掉，避免残留旧语言
        .onChange(of: l10n.language) { _, _ in
            testResult = ""
        }
    }

    private func refreshSavedStates() {
        openaiSaved = (KeychainHelper.loadAPIKey(account: LLMProvider.openai.keychainAccount) != nil)
        dsSaved = (KeychainHelper.loadAPIKey(account: LLMProvider.deepseek.keychainAccount) != nil)
    }

    /// 单个模型的连通性/速度测试（先把输入框里的 Key 存进钥匙串再测）
    private func runModelTest(_ name: String, _ model: String) {
        testing = true
        testResult = ""
        KeychainHelper.saveAPIKey(apiKey)
        refreshSavedStates()
        LLMClient.testModel(model) { _, message in
            testing = false
            testResult = name + "（\(model)）" + tr("：", ": ") + message
        }
    }
}

/// 模型名输入框 + 预设快选下拉（仍可手填任意兼容模型名）+ 单独的测试按钮
private struct ModelField: View {
    let label: String
    @Binding var text: String
    let presets: [String]
    var testing: Bool = false
    var onTest: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(presets, id: \.self) { name in
                    Button(name) { text = name }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if let onTest = onTest {
                Button(testing ? tr("测试中…", "Testing…") : tr("测试", "Test"), action: onTest)
                    .disabled(testing)
                    .fixedSize()
            }
        }
    }
}

/// Key 保存状态小徽章
private struct KeyStatusBadge: View {
    let name: String
    let saved: Bool
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: saved ? "key.fill" : "key")
                .foregroundColor(saved ? .green : .secondary)
            Text(name + (saved ? " ✓" : tr(" 未填", " not set")))
        }
        .font(.caption)
        .foregroundColor(saved ? .primary : .secondary)
    }
}

// MARK: - 关于

private struct AboutTab: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var updateStatus = ""
    @State private var checkingUpdate = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)
            Text("MicType")
                .font(.title2.bold())
            Text(tr("版本 \(UpdateChecker.currentVersion) · Qwen3-ASR 引擎 + 语音指令",
                    "Version \(UpdateChecker.currentVersion) · Qwen3-ASR engine + voice commands"))
                .foregroundColor(.secondary)
            Text(tr("本地 Qwen3-ASR 语音识别 + GPT / DeepSeek 智能润色\n轻点快捷键语音输入；按住快捷键说指令——改写、回复、草拟、翻译。",
                    "On-device Qwen3-ASR speech recognition + GPT / DeepSeek polish.\nTap the hotkey to dictate; hold it to speak commands — rewrite, reply, draft, translate."))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .font(.callout)
            HStack(spacing: 8) {
                Button(checkingUpdate ? tr("检查中…", "Checking…") : tr("检查更新", "Check for Updates")) {
                    runUpdateCheck()
                }
                .disabled(checkingUpdate)
                Button(tr("发布页", "Releases")) {
                    NSWorkspace.shared.open(UpdateChecker.releasesPage)
                }
            }
            if !updateStatus.isEmpty {
                Text(updateStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Text(tr("作者：Gen", "Built by Gen"))
                Link("genli-ai.github.io/portfolio",
                     destination: URL(string: "https://genli-ai.github.io/portfolio/")!)
                Link("ligen.thu@gmail.com",
                     destination: URL(string: "mailto:ligen.thu@gmail.com")!)
            }
            .font(.caption)
            Divider().padding(.horizontal, 60)
            VStack(spacing: 4) {
                Text(tr("隐私：录音和语音识别完全在本机进行。",
                        "Privacy: recording and speech recognition stay entirely on this Mac."))
                Text(tr("只有开启 AI 润色时，识别出的文本会发送给你配置的大模型接口。",
                        "Only with AI polish enabled is the transcribed text sent to the model endpoint you configure."))
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onChange(of: l10n.language) { _, _ in
            updateStatus = ""  // 一次性状态文字是语言快照，切语言即清空
        }
    }

    private func runUpdateCheck() {
        checkingUpdate = true
        updateStatus = tr("正在检查 GitHub 上的最新版本…", "Checking the latest release on GitHub…")
        UpdateChecker.checkAndDownload { result in
            checkingUpdate = false
            switch result {
            case .upToDate(let v):
                updateStatus = tr("已是最新版本（\(v)）", "You're up to date (\(v))")
            case .downloaded(let v, let file):
                if file.pathExtension.lowercased() == "dmg" {
                    updateStatus = tr("新版本 \(v) 已下载到「下载」文件夹（已在 Finder 中选中）——双击打开 DMG，把 MicType.app 拖进「应用程序」替换，重新打开即完成升级",
                                      "Version \(v) downloaded to your Downloads folder (revealed in Finder) — open the DMG, drag MicType.app into Applications to replace, then relaunch")
                } else {
                    updateStatus = tr("新版本 \(v) 已下载到「下载」文件夹（已在 Finder 中选中）——解压后把 MicType.app 拖进「应用程序」替换，重新打开即完成升级",
                                      "Version \(v) downloaded to your Downloads folder (revealed in Finder) — unzip, drag MicType.app into Applications to replace, then relaunch")
                }
            case .failed(let message):
                updateStatus = tr("检查失败：\(message)。可点「发布页」手动下载",
                                  "Check failed: \(message). Use the Releases button to download manually")
            }
        }
    }
}
