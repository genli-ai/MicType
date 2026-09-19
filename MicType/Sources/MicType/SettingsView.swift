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

/// 通用页的段序（v4.0 调研 §4.4）。以前第一个控件是「界面语言」——一辈子点一次的东西占了
/// 最贵的位置，而每天都要看的快捷键和录音要往下滚。重排成"用得最多的在最前"：
/// 快捷键 → 录音 → 悬浮窗 → 行为 → 权限 → 语言与备份。
///
/// 为什么写成一张有序表而不是把顺序埋在 body 里：顺序本身是这次改动的产出，得能被单测钉住，
/// 否则下一次顺手在中间插一段就悄悄退回原样了。
enum GeneralSectionOrder: Int, CaseIterable {
    case hotkey
    case recording
    case overlay
    case behaviour
    case permissions
    case languageAndBackup
}

private struct GeneralTab: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.hotkey) private var hotkey = HotkeyChoice.rightOption.rawValue
    @AppStorage(SettingsKeys.playSounds) private var playSounds = true
    @AppStorage(SettingsKeys.restoreClipboard) private var restoreClipboard = true
    @AppStorage(SettingsKeys.autoStopSilenceSeconds) private var autoStopSilence = 0.0
    @AppStorage(SettingsKeys.livePreview) private var livePreview = true
    @AppStorage(SettingsKeys.overlayPosition) private var overlayPosition = OverlayPosition.bottomCenter.rawValue
    @AppStorage(SettingsKeys.keepHistory) private var keepHistory = true
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var micOK = Permissions.microphoneGranted
    @State private var axOK = Permissions.isAccessibilityTrusted
    private let permTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    // 导入导出的结果文字是一次性快照，切语言时要清掉（见 CLAUDE.md「i18n 快照字符串」）
    @State private var backupStatus = ""

    private var selectedHotkey: HotkeyChoice { HotkeyChoice(rawValue: hotkey) ?? .rightOption }

    /// 秒数 0 = 关；打开时给一个保守的默认 2 秒（够停顿想词，又不至于等太久）
    private var autoStopEnabled: Binding<Bool> {
        Binding(get: { autoStopSilence > 0 },
                set: { autoStopSilence = $0 ? 2 : 0 })
    }

    var body: some View {
        Form {
            ForEach(GeneralSectionOrder.allCases, id: \.self) { section in
                sectionView(section)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        // 权限轮询挂在整页上而不是权限段里：两项都绿时那一段折叠成一行，轮询不能跟着一起消失
        .onReceive(permTimer) { _ in
            micOK = Permissions.microphoneGranted
            axOK = Permissions.isAccessibilityTrusted
        }
        // 已生成的状态文字是快照，切换语言后清掉，避免残留旧语言
        .onChange(of: l10n.language) { _, _ in
            backupStatus = ""
        }
    }

    @ViewBuilder
    private func sectionView(_ section: GeneralSectionOrder) -> some View {
        switch section {
        case .hotkey: hotkeySection
        case .recording: recordingSection
        case .overlay: overlaySection
        case .behaviour: behaviourSection
        case .permissions: permissionsSection
        case .languageAndBackup: languageAndBackupSection
        }
    }

    // MARK: ① 快捷键

    private var hotkeySection: some View {
        Section(tr("快捷键", "Hotkey")) {
            Picker(tr("听写快捷键：", "Dictation hotkey:"), selection: $hotkey) {
                ForEach(HotkeyChoice.allCases, id: \.rawValue) { choice in
                    Text(choice.displayName).tag(choice.rawValue)
                }
            }
            Text(tr("轻点：开始 / 结束听写 · 按住说话、松手：执行语音指令 · 录音中按 Esc 取消。",
                    "Tap: start / stop dictation · Hold to speak a command, release to run · Esc cancels."))
                .font(.caption)
                .foregroundColor(.secondary)
            if selectedHotkey == .fn {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("用 Fn / 🌐 前必须先让系统放手：系统设置 → 键盘 → 「按下🌐键」选「不执行任何操作」。否则每次轻点都会被系统抢去切换输入法或弹表情面板。",
                            "Before using Fn / 🌐, tell macOS to let go: System Settings → Keyboard → \"Press 🌐 key to\" → \"Do Nothing\". Otherwise every tap gets swallowed by the emoji or input-source picker."))
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button(tr("打开键盘设置", "Open Keyboard Settings")) {
                        Permissions.openKeyboardSettings()
                    }
                }
            }
            if selectedHotkey.isLeftSideModifier {
                Text(tr("左侧修饰键天天参与组合键（⌘C、⌥←…）。单独轻点才会触发，按住它敲别的键不会——但误触概率仍比右侧高，建议先试用几天。",
                        "Left-side modifiers are used in everyday shortcuts (⌘C, ⌥←…). Only a clean tap triggers MicType — holding it while pressing another key never does — but mistaps are still likelier than on the right side."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack {
                Text(tr("上手引导：", "Welcome guide:"))
                Spacer()
                Button(tr("重新打开引导", "Show Welcome Guide")) {
                    OnboardingWindowController.shared.show()
                }
            }
        }
    }

    // MARK: ② 录音

    private var recordingSection: some View {
        Section(tr("录音", "Recording")) {
            Toggle(tr("静音自动停止录音", "Stop recording after silence"), isOn: autoStopEnabled)
            if autoStopSilence > 0 {
                Stepper(value: $autoStopSilence, in: 1...5, step: 1) {
                    Text(tr("静音 \(Int(autoStopSilence)) 秒后自动结束",
                            "Stop after \(Int(autoStopSilence))s of silence"))
                }
            }
            Text(tr("自动结束＝正常收尾这一段（照常识别并输入），不是丢弃。默认关闭：什么时候说完由你决定。",
                    "Auto-stop finishes the take normally (it is still transcribed and inserted) — nothing is discarded. Off by default: you decide when you are done."))
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle(tr("录音时显示实时识别草稿", "Show live transcript while recording"), isOn: $livePreview)
            Text(tr("草稿只出现在悬浮窗里，永远不会输入到光标处；最终结果仍是松手后整段重新识别的那一版。",
                    "The draft only appears in the floating window and never reaches your cursor; the final text is still the full re-transcription made when you finish."))
                .font(.caption)
                .foregroundColor(.secondary)
            // 时长上限此前在界面上无处可查，用户第一次知道它存在就是被自动收尾那一刻。
            // 具体秒数故意不写死在这段文案里：上限归识别链路（DictationController）管，
            // 数字改了而这里忘了改，比不写数字更糟。
            Text(tr("单次录音有时长上限：接近上限时悬浮窗会显示已录时长与上限。长段口述按分段转写；到上限时 MicType 会收尾，把你已经说的内容全部识别、全部插入。",
                    "A single take has a length limit; as you get close, the overlay shows how long you have been recording against it. Long dictation is transcribed in segments, and at the limit MicType finishes up and inserts everything you have said."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: ③ 悬浮窗

    private var overlaySection: some View {
        Section(tr("悬浮窗", "Overlay")) {
            Picker(tr("悬浮窗位置：", "Overlay position:"), selection: $overlayPosition) {
                ForEach(OverlayPosition.allCases, id: \.rawValue) { position in
                    Text(position.displayName).tag(position.rawValue)
                }
            }
            Text(tr("多屏时悬浮窗永远出现在鼠标所在的那块屏幕，这里只决定它落在这块屏的哪个位置。录音中和处理中可以直接点悬浮窗右端的「⎋ 取消」，和按 Esc 一样；点它不会切走当前应用的输入焦点。",
                    "On multiple displays the overlay always appears on the screen holding the pointer; this only picks where it sits on that screen. While recording or processing you can click ⎋ Cancel at the right end of the capsule — same as pressing Esc, and it never takes focus away from the app you are typing into."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: ④ 行为

    private var behaviourSection: some View {
        Section(tr("行为", "Behaviour")) {
            Toggle(tr("开始 / 完成时播放提示音", "Play sounds on start / finish"), isOn: $playSounds)
            Toggle(tr("输入后恢复原剪贴板内容", "Restore clipboard after inserting"), isOn: $restoreClipboard)
            Toggle(tr("保存听写历史", "Keep transcript history"), isOn: $keepHistory)
            Text(tr("历史保存在本机 ~/Library/Application Support/MicType/history.json，最多 200 条，从不上传。关掉后立即停止记录；已有的记录不会自动删除，可在菜单栏「最近记录 → 清空记录」清空，或在历史记录窗口（⌘Y）里逐条删。",
                    "Transcripts are kept on this Mac in ~/Library/Application Support/MicType/history.json (up to 200) and are never uploaded. Turning this off stops recording immediately; existing entries are left alone — clear them from the menu bar (Recent Transcripts → Clear History) or delete them one by one in the History window (⌘Y)."))
                .font(.caption)
                .foregroundColor(.secondary)
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
    }

    // MARK: ⑤ 权限

    /// 两项都绿就折叠成一行。为什么：这一段是给"还没弄好"的人看的教学文字，齐了以后每天
    /// 打开设置都顶着两行按钮 + 四段说明，纯属噪音；缺项才展开，缺什么说什么（v4.0 §4.4）。
    /// 两项权限各自一行、各自一个按钮（与引导页同构）：以前并排两个徽章却只有一个
    /// 「打开系统设置」按钮，而且固定跳辅助功能面板——麦克风是红叉的用户点几次都到同一页。
    private var permissionsSection: some View {
        Section(tr("权限", "Permissions")) {
            if micOK && axOK {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(tr("权限齐全", "All permissions granted"))
                    Spacer()
                }
                .font(.caption)
            } else {
                HStack {
                    PermissionBadge(name: tr("麦克风", "Microphone"), ok: micOK)
                    Spacer()
                    Button(tr("打开麦克风设置", "Open Microphone Settings")) {
                        Permissions.openMicrophoneSettings()
                    }
                }
                HStack {
                    PermissionBadge(name: tr("辅助功能", "Accessibility"), ok: axOK)
                    Spacer()
                    Button(tr("打开辅助功能设置", "Open Accessibility Settings")) {
                        Permissions.openAccessibilitySettings()
                    }
                }
                Text(tr("「麦克风」用于录下你说的话（识别全程在本机）；「辅助功能」用于监听快捷键和把文字粘贴到光标处，两项都必须开启。勾上即时生效，不用重启 MicType。",
                        "Microphone records your voice (recognition stays on this Mac); Accessibility is required for the global hotkey and for pasting text at the cursor. Both are required, and ticking them takes effect immediately — no restart needed."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !micOK {
                    Text(tr("麦克风还没授权：在 系统设置 → 隐私与安全性 → 麦克风 里勾上 MicType，否则录不到任何声音。",
                            "Microphone is not granted yet: tick MicType under System Settings → Privacy & Security → Microphone, otherwise nothing is recorded."))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if !axOK {
                    Text(tr("如果系统设置里显示已开启但这里仍是 ✗：是旧版授权失效了。请在 辅助功能 列表中选中 MicType，点「−」删除，再点「+」重新添加。",
                            "If System Settings shows it enabled but this still shows ✗, the old grant is stale: remove MicType from the Accessibility list (−), then add it back (+)."))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    // MARK: ⑥ 语言与备份

    private var languageAndBackupSection: some View {
        Section(tr("语言与备份", "Language & Backup")) {
            // 故意双语（CJKUIStringGuardTests 里唯一的按行白名单）：语言选择器是切回
            // 母语的唯一入口，界面已经是看不懂的那一种语言时，它必须还认得出来
            Picker(tr("界面语言 / Language:", "Language / 界面语言:"), selection: $l10n.language) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Button(tr("导出设置…", "Export Settings…")) {
                    backupStatus = SettingsBackup.runExport()
                }
                Button(tr("导入设置…", "Import Settings…")) {
                    backupStatus = SettingsBackup.runImport()
                }
                Spacer()
            }
            if !backupStatus.isEmpty {
                Text(backupStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            Text(tr("导出一个 JSON 文件：词汇表、口水词、关于我、自定义规则、档位与模型偏好、热键与语言。导入是合并——词表取并集（老词条一条不少），其余只覆盖文件里出现的项。\nAPI Key 从不导出、也从不导入：Key 只在系统钥匙串里，写进文件就等于把它交给了拿到文件的人。文件格式 Mac 与 Windows 通用。",
                    "Exports one JSON file: vocabulary, filler words, about-me, custom rules, polish mode and model preferences, hotkey and language. Import merges — vocabulary lists are unioned (nothing you already have is lost) and other settings are overwritten only where the file has them.\nAPI keys are never exported or imported: they live in the Keychain, and a file containing one gives it away to whoever receives the file. The format is shared with the Windows build."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
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
    @AppStorage(SettingsKeys.fillerWords) private var fillerWords = ""
    @ObservedObject private var downloader = QwenModelDownloader.shared
    @ObservedObject private var metrics = Metrics.shared
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
            // 麦克风选择 + 电平自检：与引导第二屏共用同一个组件（MicCheck.swift）
            Section {
                MicCheckPanel()
            }

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
                    Text(tr("这些词会作为热词直接送入识别模型，并参与 AI 润色纠错——专有名词识别准确率的第一杠杆，强烈建议填写。\n支持硬替换：填「杰文=捷文」表示识别出的「杰文」一律改成「捷文」——确定性替换、零耗时，对完全同音的人名最有效。\n一个正写可挂多个错写：「杰文|捷纹|结文=捷文」。西文词条大小写不敏感、按整词匹配。",
                            "These terms are fed to the speech model as hotwords and used by AI polish — the #1 lever for proper-noun accuracy.\nHard replacement supported: an entry like \"Jevin=Jaywen\" deterministically rewrites every occurrence — zero latency, ideal for exact-homophone names.\nOne correct form can take several wrong spellings: \"Jevin|Jevan|Javin=Jaywen\". Latin entries match whole words, case-insensitively."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("口水词过滤（用逗号或换行分隔，默认空 = 不过滤）：",
                            "Filler words to drop (comma or newline separated; empty = off):"))
                    TextEditor(text: $fillerWords)
                        .font(.system(size: 12))
                        .frame(height: 56)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                    Text(tr("在本机删掉，不联网、不花润色额度——「仅识别」档也生效。\n分寸是保守的：西文词按整词删（填 um 不会动 umbrella）；中文词只在前后都是标点或空白时删（填「那个」不会动「那个人」）。",
                            "Removed on-device — no network, no polish tokens; works even in transcribe-only mode.\nDeliberately conservative: Latin entries are dropped as whole words only (\"um\" never touches \"umbrella\"); other entries are dropped only when standing alone between punctuation or spaces."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // 性能：只是照镜子，不提供任何"自动优化"开关——快慢的原因摆出来，怎么调由用户决定
            Section(tr("性能", "Performance")) {
                if let digest = Metrics.digest(metrics.items) {
                    Text(Metrics.summaryLine(digest))
                        .monospacedDigit()
                } else {
                    Text(tr("还没有可统计的记录——正常用几次就会出现。",
                            "No sessions recorded yet — dictate a few times and this will fill in."))
                        .foregroundColor(.secondary)
                }
                Text(tr("识别与插入都在本机完成；「模型」那一段是到大模型接口的网络往返（轻点是润色，按住是指令），和这台 Mac 快慢无关，后面括号里是它实际统计了几轮。\n只统计数字，不保存任何听写内容。",
                        "Recognition and insertion run on this Mac; the “Model” figure is the network round trip to your model endpoint (polish when you tap, the command model when you hold) — not bound by this machine. The number in brackets is how many rounds actually went through it.\nOnly timings are stored — never any transcribed text."))
                    .font(.caption)
                    .foregroundColor(.secondary)
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
        // 已生成的状态文字是快照，切换语言后清掉，避免残留旧语言。
        // 下载状态不在其列：它现在存的是语言中性的 phase，文字由 tr() 现场渲染，下载中也跟着切
        .onChange(of: l10n.language) { _, _ in
            updateMessage = ""
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
            testResult = name + tr("（\(model)）", " (\(model))") + tr("：", ": ") + message
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

/// 已下载、等着用户点「立即安装并重启」的那个包
private struct PendingUpdate {
    let version: String
    let file: URL
}

private struct AboutTab: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var updateStatus = ""
    @State private var checkingUpdate = false
    @State private var pendingUpdate: PendingUpdate?
    @State private var installing = false
    /// 刚复制过诊断信息：按钮就地变成「已复制」两秒。就地确认不额外占一行高度——
    /// 关于页是个固定高度的 VStack，多一行就可能把底下的隐私说明挤出窗口。
    @State private var diagnosticsCopied = false

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
                Button(diagnosticsCopied ? tr("已复制", "Copied")
                                         : tr("复制诊断信息", "Copy diagnostics")) {
                    Diagnostics.copyToPasteboard()
                    diagnosticsCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        diagnosticsCopied = false
                    }
                }
            }
            if let pending = pendingUpdate {
                HStack(spacing: 8) {
                    Button(installing ? tr("安装中…", "Installing…")
                                      : tr("立即安装并重启", "Install and Relaunch")) {
                        runInstall(pending)
                    }
                    .disabled(installing)
                    // 老流程留作兜底：验签不过、目录不可写，或者用户就是想自己拖一次
                    Button(tr("在 Finder 中显示", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([pending.file])
                    }
                    .disabled(installing)
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
            // 隐私与费用这几句取自 PrivacyCopy——引导页用的是同一批句子，改一处三处同步。
            // 外面套 ScrollView：关于页是固定高度的 VStack，文案一长就会把底下的内容顶出窗口，
            // 宁可让它能滚，也不要有一句是用户看不见的。
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(PrivacyCopy.allLines, id: \.self) { line in
                        Text(line)
                    }
                    Text(tr("听写历史以明文保存在本机 Application Support 目录，最多 200 条：可在 设置 → 通用 关掉记录，或在菜单栏「最近记录」里清空、逐条删除。",
                            "Transcripts are kept in plain text on this Mac (up to 200): turn recording off in Settings → General, or clear and delete them from Recent Transcripts in the menu bar."))
                    Text(tr("「复制诊断信息」只包含版本、系统、芯片、设置摘要、最近的耗时数字和今天的日志尾巴（日志里的路径和账户名已脱敏）——不含 API Key，也不含任何听写内容，可以放心贴给别人。",
                            "“Copy diagnostics” includes only the version, system, chip, a settings summary, recent timings and today's log tail (paths and your account name in it are redacted) — never your API key and never any transcribed text, so it is safe to paste to someone."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption)
                .foregroundColor(.secondary)
            }
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
                pendingUpdate = nil
                updateStatus = tr("已是最新版本（\(v)）", "You're up to date (\(v))")
            case .downloaded(let v, let file):
                pendingUpdate = PendingUpdate(version: v, file: file)
                updateStatus = tr("新版本 \(v) 已下载到「下载」文件夹——点「立即安装并重启」一步完成（会校验签名后替换当前这份并自动重开），也可以自己拖进「应用程序」替换",
                                  "Version \(v) downloaded to your Downloads folder — click “Install and Relaunch” to finish in one step (the signature is verified before this copy is replaced), or replace it manually")
            case .failed(let message):
                pendingUpdate = nil
                updateStatus = tr("检查失败：\(message)。可点「发布页」手动下载",
                                  "Check failed: \(message). Use the Releases button to download manually")
            }
        }
    }

    private func runInstall(_ pending: PendingUpdate) {
        installing = true
        updateStatus = tr("正在准备安装 \(pending.version)…", "Preparing to install \(pending.version)…")
        UpdateChecker.installAndRelaunch(archive: pending.file, version: pending.version, progress: { message in
            updateStatus = message
        }, failure: { message in
            installing = false
            // 失败不动现有这份 app：把原因摆出来，指回手动替换那条路
            updateStatus = tr("安装失败：\(message)。当前版本未改动，可点「在 Finder 中显示」手动替换",
                              "Install failed: \(message). This copy was left untouched — use “Show in Finder” to replace it manually")
        })
    }
}
