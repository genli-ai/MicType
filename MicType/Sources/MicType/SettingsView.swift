import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MARK: - 设置窗口

/// 设置窗口的四个标签。有名字才能从别处深链过去（菜单栏「配置 AI…」、悬浮窗的「去配置」、
/// 模型升级横幅）——把人丢进设置窗口第一页再让他自己找，等于没给路。
enum SettingsTab: String, Hashable, CaseIterable {
    case general
    case recognition
    case ai
    case about
}

/// 当前选中的标签。窗口是复用的（isReleasedWhenClosed = false），而深链又来自 AppKit 那一侧
/// （菜单栏 / 悬浮窗，拿不到 SwiftUI 的 @State），所以选中项必须是外部可写的共享状态——
/// 否则第二次 show(tab:) 就翻不动页。
final class SettingsTabRouter: ObservableObject {
    static let shared = SettingsTabRouter()
    @Published var tab: SettingsTab = .general
    private init() {}
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var langObserver: AnyCancellable?

    /// - tab: 指定要停在哪一页；nil = 保持上次的位置（用户自己点「设置…」时不该被拽走）
    func show(tab: SettingsTab? = nil) {
        if let tab = tab { SettingsTabRouter.shared.tab = tab }
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
    @ObservedObject private var router = SettingsTabRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            GeneralTab()
                .tabItem { Label(tr("通用", "General"), systemImage: "gearshape") }
                .tag(SettingsTab.general)
            RecognitionTab()
                .tabItem { Label(tr("识别", "Recognition"), systemImage: "waveform") }
                .tag(SettingsTab.recognition)
            // 标签名就叫「AI」：这一页也管语音指令，叫「AI 润色」名不副实
            AITab()
                .tabItem { Label("AI", systemImage: "wand.and.stars") }
                .tag(SettingsTab.ai)
            AboutTab()
                .tabItem { Label(tr("关于", "About"), systemImage: "info.circle") }
                .tag(SettingsTab.about)
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
            Text(tr("草稿只出现在悬浮窗里，永远不会输入到光标处；最终结果始终是识别管线自己转出来的那一版，与草稿无关。",
                    "The draft only appears in the floating window and never reaches your cursor; the final text always comes from the recognition pipeline itself, never from the draft."))
                .font(.caption)
                .foregroundColor(.secondary)
            // 时长上限此前在界面上无处可查，用户第一次知道它存在就是被自动收尾那一刻。
            // 这句话连同里面的数字都由识别链路自己给（DictationController.recordingLimitCopy
            // 读的是上限 / 预警提前量 / 分段长度这三个常量），界面这边一个数字都不写死。
            Text(DictationController.recordingLimitCopy)
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
    @AppStorage(SettingsKeys.recognitionLanguage) private var recognitionLanguage = RecognitionLanguages.autoCode
    @AppStorage(SettingsKeys.customVocabulary) private var vocabulary = ""
    @AppStorage(SettingsKeys.fillerWords) private var fillerWords = ""
    // 识别引擎（默认本地）与云端那一档的设置。区域 / WorkspaceId 与「AI」页共用同一条设置——
    // 同一个百炼账号、同一把 Key，分两处存只会存出两个不一致的值
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
    @AppStorage(SettingsKeys.cloudAlibabaModel) private var cloudAlibabaModel = AlibabaASRModel.qwenAudio30Flash.rawValue
    @AppStorage(SettingsKeys.qwenRegion) private var qwenRegion = LLMCatalog.QwenRegion.international.rawValue
    @AppStorage(SettingsKeys.qwenWorkspaceID) private var qwenWorkspace = ""
    @ObservedObject private var downloader = QwenModelDownloader.shared
    @ObservedObject private var upgrader = ModelUpgrader.shared
    /// 模型目录到货时下拉框要立刻跟上（首启动时目录还在路上）
    @ObservedObject private var catalogStore = ModelCatalogStore.shared
    @ObservedObject private var metrics = Metrics.shared
    @State private var refreshTick = 0
    @State private var updateMessage = ""
    @State private var checkingUpdate = false
    /// 「测试识别」那一行结论（快照，切语言 / 换引擎就清掉）
    @State private var cloudTestResult = ""
    @State private var cloudTestOK = false
    @State private var cloudTesting = false
    /// 这一行结论属于哪一次配置。探针要跑几秒到几分钟（阿里云超时 120s、OpenAI 300s），
    /// 期间用户完全可以换引擎/区域/模型/语言——回来的那条旧结论绝不能落在新档下面
    /// （KeyEntryView 早就有这道护栏，见 KeyEntryView.verify 的 generation）
    @State private var cloudTestGeneration = 0

    private var modelExists: Bool {
        _ = refreshTick
        // 下到一半的目录不算"已就绪"（QwenModels.isFullyDownloaded 认 .incomplete 标记）
        return QwenModels.isFullyDownloaded(repo: qwenRepo)
    }

    /// 选了阿语：给一条**词汇表**提示。
    ///
    /// 这里原本是「阿拉伯语建议换 1.7B 模型」那条推荐行，2026-09-19 的实测把它推翻了：
    /// 同一段阿英混说的素材，默认的 0.6B 无上下文 CER 12.5%，把英文专名加进词汇表（热词）
    /// 之后降到 4.0%；而 1.7B 基本不吃热词，反而是 16.8%。所以对用户最有用的动作不是
    /// 下 1.6 GB 换模型，而是把 Microsoft Excel、Power BI 这些词填进词汇表。
    /// 1.7B 仍然在模型下拉框里，想换的人随时能换——只是不再由我们劝他换。
    private var showsArabicVocabularyTip: Bool {
        recognitionLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ar"
    }

    /// 当前选中模型的语言能力说明（来自模型目录；没写就不占一行）
    private var selectedModelLanguagesNote: String {
        catalogStore.catalog.model(repo: qwenRepo)?.languagesNote.localized ?? ""
    }

    /// 选中的这一档还在目录里吗（换代下架后就不在了）
    private var selectedModelListed: Bool {
        QwenModels.all.contains { $0.repo == qwenRepo }
    }

    /// 模型升级横幅。非模态、可「以后再说」，按钮上写清这次要下多少——
    /// 一个会花掉几百 MB 流量的动作，绝不能让用户点下去才知道代价。
    @ViewBuilder
    private var upgradeBanner: some View {
        switch upgrader.decision {
        case .none:
            // 没什么可升级的时候横幅不占地方；但刚跑完（成功或失败）那句结论要留在屏幕上
            if !upgrader.statusText.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: upgrader.phase == .failed
                          ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundColor(upgrader.phase == .failed ? .orange : .green)
                    Text(upgrader.statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .upgrade(let repo):
            bannerBox(icon: "sparkles",
                      title: tr("有更合适的识别模型：", "A better speech model is available: ")
                          + upgrader.displayName(for: repo),
                      detail: upgrader.languagesNote(for: repo)) {
                Button(upgradeButtonTitle(repo: repo)) {
                    updateMessage = ""
                    upgrader.startUpgrade()
                }
                .disabled(upgrader.isBusy || downloader.isDownloading)
                Button(tr("以后再说", "Not now")) { upgrader.dismissCurrentOffer() }
                    .disabled(upgrader.isBusy)
            }
        case .refresh(let repo):
            bannerBox(icon: "arrow.triangle.2.circlepath",
                      title: tr("当前识别模型有新修订", "The current speech model has a newer revision"),
                      detail: tr("同一个模型的文件在仓库里更新过。重新下载后会校验一遍再启用；失败则保留现在这份。",
                                 "The same model's files changed upstream. The re-download is verified before it is used; if it fails, the current copy is kept.")) {
                Button(tr("重新下载并校验", "Re-download and verify")) {
                    updateMessage = ""
                    upgrader.startUpgrade()
                }
                .disabled(upgrader.isBusy || downloader.isDownloading)
                Text(upgrader.sizeNote(for: repo))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .needsAppUpdate(let repo, let minVersion):
            bannerBox(icon: "exclamationmark.triangle",
                      title: tr("需要更新 MicType", "MicType needs an update"),
                      detail: tr("新模型「\(upgrader.displayName(for: repo))」要求 MicType \(minVersion) 或更高版本，当前是 \(UpdateChecker.currentVersion)。先更新 App，再回来一键升级模型。",
                                 "The new model “\(upgrader.displayName(for: repo))” needs MicType \(minVersion) or newer; this copy is \(UpdateChecker.currentVersion). Update the app first, then upgrade the model here.")) {
                Button(tr("去检查 MicType 更新", "Check for MicType updates")) {
                    SettingsTabRouter.shared.tab = .about
                }
                Button(tr("以后再说", "Not now")) { upgrader.dismissCurrentOffer() }
            }
        }
    }

    /// 升级按钮的标题：把体量写在按钮上（已经下载过就不必再提体量）
    private func upgradeButtonTitle(repo: String) -> String {
        if QwenModels.isFullyDownloaded(repo: repo) {
            return tr("升级并切换", "Upgrade and switch")
        }
        let size = upgrader.sizeNote(for: repo)
        if size.isEmpty { return tr("下载并升级", "Download and upgrade") }
        return tr("下载并升级（\(size)）", "Download and upgrade (\(size))")
    }

    @ViewBuilder
    private func bannerBox<Actions: View>(icon: String, title: String, detail: String,
                                          @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon).foregroundColor(.orange)
                Text(title).fontWeight(.medium)
            }
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) { actions() }
            if upgrader.isBusy || !upgrader.statusText.isEmpty {
                Text(upgrader.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    /// 当前选中的识别引擎。脏值一律回落本地（RecognitionEngineChoice.parse）：
    /// 一条读不懂的设置绝不能把音频送上云端。
    private var engineChoice: RecognitionEngineChoice { RecognitionEngineChoice.parse(recognitionEngine) }

    /// 云端·阿里云这一档当前的区域配得出接入点吗（东京 / 香港没有识别主机）
    private var cloudRegionOK: Bool {
        CloudASRSettings.regionSupported(choice: engineChoice,
                                         region: LLMCatalog.QwenRegion(rawValue: qwenRegion) ?? .international)
    }

    var body: some View {
        Form {
            // 麦克风选择 + 电平自检：与引导第二屏共用同一个组件（MicCheck.swift）
            Section {
                MicCheckPanel()
            }

            // 引擎在最前：它决定下面那一段是"下模型"还是"填 Key"
            Section {
                engineSection
            }

            Section {
                languageSection
            }

            Section {
                switch engineChoice {
                case .local: localModelSection
                case .cloudAlibaba: cloudAlibabaSection
                case .cloudOpenAI: cloudOpenAISection
                }
            }

            Section {
                vocabularySection
            }

            Section {
                fillerSection
            }

            // 性能：只是照镜子，不提供任何"自动优化"开关——快慢的原因摆出来，怎么调由用户决定
            Section(tr("性能", "Performance")) {
                performanceSection
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
        // 换引擎 / 换区域 / 换云端模型 / 换识别语言之后，上一次的测试结论不再算数
        .onChange(of: recognitionEngine) { _, _ in invalidateCloudTest() }
        .onChange(of: qwenRegion) { _, _ in invalidateCloudTest() }
        .onChange(of: cloudAlibabaModel) { _, _ in invalidateCloudTest() }
        .onChange(of: recognitionLanguage) { _, _ in invalidateCloudTest() }
        // 已生成的状态文字是快照，切换语言后清掉，避免残留旧语言。
        // 下载状态不在其列：它现在存的是语言中性的 phase，文字由 tr() 现场渲染，下载中也跟着切
        .onChange(of: l10n.language) { _, _ in
            updateMessage = ""
            invalidateCloudTest()
            // 下载状态已经是语言中性的 phase，麦克风自检的文字归 MicCheckPanel 自己管；
            // 升级器那句结论仍是快照，照旧清掉
            if !upgrader.isBusy { upgrader.clearStatus() }
        }
    }

    // MARK: 引擎（本地 / 云端，永远是用户自己选）

    @ViewBuilder
    private var engineSection: some View {
        Picker(tr("识别引擎：", "Recognition engine:"), selection: $recognitionEngine) {
            ForEach(RecognitionEngineChoice.allCases, id: \.rawValue) { choice in
                Text(choice.segmentName).tag(choice.rawValue)
            }
        }
        .pickerStyle(.segmented)
        Text(tr("本地引擎不联网、不花钱，是默认档。云端引擎把每一段录音上传给服务商识别，按秒计费——机器慢、录音长、或者要识别本地模型不擅长的语言时才值得开。随时可以换回来。",
                "The on-device engine needs no network and costs nothing; it is the default. A cloud engine uploads every recording to that provider and is billed by the second - worth it when this Mac is slow, the takes are long, or you need a language the local model handles poorly. You can switch back any time."))
            .font(.caption)
            .foregroundColor(.secondary)
    }

    // MARK: 识别语言（本地与云端共用这一条设置）

    @ViewBuilder
    private var languageSection: some View {
        Picker(tr("识别语言：", "Recognition language:"), selection: $recognitionLanguage) {
            Text(tr("自动检测（默认）", "Detect automatically (default)"))
                .tag(RecognitionLanguages.autoCode)
            ForEach(RecognitionLanguages.pickerOrdered) { lang in
                Text(lang.displayName).tag(lang.code)
            }
        }
        Text(tr("自动检测对中英文很准，几乎不用动。说小语种（或中英夹杂被判错）时指定语言更稳；指定只影响识别，不改任何别的行为。",
                "Automatic detection is reliable for Chinese and English, so most people never touch this. Pick a language when you speak something else, or when mixed speech gets detected wrong. It only affects recognition."))
            .font(.caption)
            .foregroundColor(.secondary)
        if engineChoice.isCloud {
            // 云端的语言表比这张选单短：选了它不认识的码（荷兰语、波斯语、希腊语…）时，
            // 提示根本送不出去（送了只会被判 InvalidParameter），云端照常自动检测。
            // 那句"选了就送过去"对这几种语言是假的，必须当面换一句话——挑语言的人图的
            // 恰恰是"说小语种更稳"，不能让他以为提示已经生效了。
            if CloudASRSettings.cloudHintDelivered(recognitionLanguage: recognitionLanguage) {
                Text(tr("云端引擎同样读这一条：选了具体语言就作为语言提示送过去，「自动检测」则交给云端自己判。",
                        "Cloud engines read the same setting: a specific language is sent as a language hint, while Detect automatically leaves the decision to the provider."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(tr("云端引擎不接受这个语言的提示，这一段会交给它自己判断语言。要用这条设置，请改回本地引擎。",
                        "The cloud engine does not accept a hint for this language, so it will detect the language itself. Switch back to the on-device engine to use this setting."))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: 本地模型（下载 / 升级 / 体量）

    @ViewBuilder
    private var localModelSection: some View {
        if showsArabicVocabularyTip {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lightbulb")
                        .foregroundColor(.orange)
                    Text(tr("阿拉伯语：把英文专名加进词汇表",
                            "Arabic: put English product names in your vocabulary"))
                        .fontWeight(.medium)
                }
                Text(tr("阿语口述里夹的英文品牌 / 产品名会被写成阿语字母（Microsoft Excel → معرفة أكسيل）。把它们加进「设置 → AI → 词汇表」，识别时会作为热词直接送进模型：实测字错率从 12.5% 降到 4.0%，比换更大的模型有效得多。\n能用的是现代标准阿语和朗读级内容；海湾、埃及等方言不承诺能用——那是模型的已知短板，不是设置问题。",
                        "English brand and product names spoken inside Arabic come back transliterated into Arabic letters (Microsoft Excel becomes an Arabic spelling). Add them under Settings > AI > Vocabulary and they are fed to the model as hotwords: measured character error rate went from 12.5% down to 4.0%, far more than a bigger model buys you.\nModern Standard Arabic and read-aloud speech are usable. Gulf, Egyptian and other dialects are not promised - that is a known weakness of the model, not a setting you can fix."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        // 升级横幅：非模态、可忽略，永不自动换模型（换代要下几百 MB，这种事只由用户点）
        upgradeBanner
        Picker(tr("识别模型：", "Speech model:"), selection: $qwenRepo) {
            ForEach(QwenModels.all, id: \.repo) { m in
                Text(m.sizeNote.isEmpty ? m.title : "\(m.title) · \(m.sizeNote)").tag(m.repo)
            }
            // 目录里已经不列这一档了（换代下架），但用户正在用它：如实列出来，
            // 不自动替他换（Picker 少一个能选中的选项会显示空白，那才是真的看不懂）
            if !selectedModelListed {
                Text(tr("当前模型（目录里已不再列出）", "Current model (no longer listed)"))
                    .tag(qwenRepo)
            }
        }
        if !selectedModelLanguagesNote.isEmpty {
            Text(selectedModelLanguagesNote)
                .font(.caption)
                .foregroundColor(.secondary)
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
                // 一个按钮查两件事：模型目录里有没有更好的模型，以及当前仓库有没有新修订。
                // 结论落在下面那行文字里，横幅（如果有）负责给「一键升级」的按钮。
                Button(checkingUpdate ? tr("检查中…", "Checking…")
                                      : tr("检查模型更新", "Check for model updates")) {
                    checkingUpdate = true
                    updateMessage = ""
                    upgrader.checkNow { message in
                        checkingUpdate = false
                        updateMessage = message
                    }
                }
                .disabled(checkingUpdate || upgrader.isBusy)
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
                // 有事可做才用橙色：「已是最新」不该长得像警告
                .foregroundColor(upgrader.decision == .none ? .secondary : .orange)
        }
        Text(tr("Qwen3-ASR（2026）：约 30 种语言 + 22 种中文方言，自动检测语言，识别完全在本机进行。模型来自 HuggingFace（hf-mirror 加速）。",
                "Qwen3-ASR (2026): ~30 languages + 22 Chinese dialects, automatic language detection, fully on-device. Models from HuggingFace."))
            .font(.caption)
            .foregroundColor(.secondary)
    }

    // MARK: 云端 · 阿里云百炼

    @ViewBuilder
    private var cloudAlibabaSection: some View {
        // 区域与 WorkspaceId 与 AI 页共用同一条设置：同一个百炼账号、同一把 Key，
        // 让用户为润色和识别各选一次区域，只会选出两个不一致的值（见 CloudASRSettings.alibabaRegion）
        Picker(tr("接入区域：", "Region:"), selection: $qwenRegion) {
            ForEach(LLMCatalog.QwenRegion.allCases, id: \.rawValue) { region in
                Text(region.displayName).tag(region.rawValue)
            }
        }
        Text(tr("区域与 Key 都与「AI」页的 Qwen 档共用：粘一次，润色和云端识别都能用；在任何一处清空，两边都会没有。Key 是分区域的：国际站的 Key 打到中国站主机上一定 401。",
                "The region and the key are shared with the Qwen provider on the AI tab: paste it once and it serves both polish and cloud recognition, and clearing it in either place clears it for both. Keys are region-specific: an international key always fails with 401 against the China host."))
            .font(.caption)
            .foregroundColor(.secondary)
        if !cloudRegionOK {
            Text(tr("云端识别在这个区域没有接入点，请改选 国际站/新加坡、美国 或 中国·北京。",
                    "Cloud recognition has no endpoint in this region - switch to International/Singapore, United States or China (Beijing)."))
                .font(.caption)
                .foregroundColor(.orange)
        }
        TextField(tr("WorkspaceId（可选）", "Workspace ID (optional)"), text: $qwenWorkspace)
            .textFieldStyle(.roundedBorder)
        // 说实话比说狠话重要：美国区没有独立的共享主机，不填 WorkspaceId 时端点会落回
        // 国际站共享主机（见 AlibabaRegion.sharedHost）——不是"连不上"，而是"这次走的是
        // 国际站主机"。照旧写"必须填、不填连不上"的话，用户看到能连通只会以为文案在吓唬他。
        Text(tr("填了就走你自己的专属主机。美国区没有独立的共享主机：不填就落回国际站共享主机（同一个国际站账号、同一把 Key）。",
                "Fill it in to use your own workspace host. The United States region has no shared host of its own: leave it empty and the request falls back to the international shared host (same international account, same key)."))
            .font(.caption)
            .foregroundColor((LLMCatalog.QwenRegion(rawValue: qwenRegion) == .us
                              && qwenWorkspace.trimmingCharacters(in: .whitespaces).isEmpty)
                             ? .orange : .secondary)

        // Key 与 AI 页的 Qwen 档共用同一条钥匙串条目：粘一次，润色和识别都能用
        KeyEntryView(provider: .qwen,
                     model: cloudAlibabaModel,
                     probe: .cloudASR(.alibaba))
        Text(cloudKeyProbeNote)
            .font(.caption)
            .foregroundColor(.secondary)

        Picker(tr("云端识别模型：", "Cloud model:"), selection: $cloudAlibabaModel) {
            ForEach(AlibabaASRModel.allCases, id: \.rawValue) { model in
                Text(model.displayName).tag(model.rawValue)
            }
        }
        cloudTestRow
        cloudNotes(PrivacyCopy.cloudAlibabaLines)
    }

    // MARK: 云端 · OpenAI

    @ViewBuilder
    private var cloudOpenAISection: some View {
        // 与润色那一档共用同一把 OpenAI Key（同一个钥匙串条目，不重复让用户填）
        Text(tr("这把 Key 与「AI」页的 OpenAI 档是同一把：粘一次，润色和云端识别都能用；在任何一处清空，两边都会没有。",
                "This is the same key as the OpenAI provider on the AI tab: paste it once and it serves both polish and cloud recognition. Clearing it in either place clears it for both."))
            .font(.caption)
            .foregroundColor(.secondary)
        KeyEntryView(provider: .openai,
                     model: OpenAITranscribeClient.defaultModel,
                     probe: .cloudASR(.openai))
        Text(cloudKeyProbeNote)
            .font(.caption)
            .foregroundColor(.secondary)
        Text(tr("模型：\(OpenAITranscribeClient.defaultModel)（转写专用端点，不走润色那条链路）。",
                "Model: \(OpenAITranscribeClient.defaultModel) (the dedicated transcription endpoint, not the polish path)."))
            .font(.caption)
            .foregroundColor(.secondary)
        cloudTestRow
        cloudNotes(PrivacyCopy.cloudOpenAILines)
    }

    // MARK: 云端两档共用的零件

    /// 粘贴即验证到底做了什么——写清楚才不会显得"它偷偷发了什么东西"
    private var cloudKeyProbeNote: String {
        tr("粘贴 Key 会立刻发 1 秒合成音到识别端点验一次：区域、WorkspaceId、模型有没有开通都一起验到了，这一秒的费用可以忽略。",
           "Pasting a key immediately verifies it by sending one second of synthetic tone to the recognition endpoint - that also checks the region, the workspace ID and whether the model is enabled. The cost of that second is negligible.")
    }

    @ViewBuilder
    private var cloudTestRow: some View {
        HStack {
            Button(cloudTesting ? tr("测试中…", "Testing…") : tr("测试识别", "Test recognition")) {
                runCloudTest()
            }
            .disabled(cloudTesting)
            Spacer()
        }
        if !cloudTestResult.isEmpty {
            Text(cloudTestResult)
                .font(.caption)
                .foregroundColor(cloudTestOK ? .green : .orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cloudNotes(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 配置变了：上一次的结论作废，在飞的那一次也不要了。
    /// 「测试中…」的标志位一并复位——不然换了档之后按钮永远灰着，等一个再也不会落地的结果。
    private func invalidateCloudTest() {
        cloudTestGeneration &+= 1
        cloudTestResult = ""
        cloudTesting = false
    }

    /// 发一次 1 秒合成音，报往返毫秒数。失败时把云端的原话摆出来（它本来就带"下一步怎么办"）
    private func runCloudTest() {
        guard let config = CloudASRSettings.currentConfig() else {
            cloudTestOK = false
            cloudTestResult = tr("云端识别在当前接入区域没有接入点，请先改区域",
                                 "Cloud recognition has no endpoint in the selected region - change the region first")
            return
        }
        cloudTestGeneration &+= 1
        let generation = cloudTestGeneration
        cloudTesting = true
        cloudTestResult = ""
        CloudASRProbe.run(config: config) { result in
            // 这几秒里用户可能已经换了引擎/区域/模型：那条结论对应的是**旧**配置，
            // 落在新档下面就是一句"已连通 ✓"骗人（阿里云通了不代表 OpenAI 配好了）
            guard generation == cloudTestGeneration else { return }
            cloudTesting = false
            switch result {
            case .success(let outcome):
                cloudTestOK = true
                cloudTestResult = CloudASRProbe.successText(outcome)
            case .failure(let failure):
                cloudTestOK = false
                cloudTestResult = failure.message
            }
        }
    }

    // MARK: 词汇表 / 口水词 / 性能（与引擎无关，两档都生效）

    @ViewBuilder
    private var vocabularySection: some View {
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
            if engineChoice.isCloud {
                Text(tr("云端引擎也吃这张表：词条按权重 4 作为热词一起送过去（含「错写=正写」里的正写）。",
                        "Cloud engines use the same list: every term is sent as a hotword with weight 4, including the correct form of each replacement rule."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var fillerSection: some View {
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

    @ViewBuilder
    private var performanceSection: some View {
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
        if engineChoice.isCloud {
            // 上面那句"识别在本机完成"对云端档不成立，得当面更正，别让用户拿本机的账去读云端的数
            Text(tr("你现在用的是云端识别：「识别」那一段量的是到服务商的往返，不是这台 Mac 的快慢。",
                    "You are on a cloud engine: the recognition figure measures the round trip to the provider, not the speed of this Mac."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - AI（润色 + 语音指令）

/// AI 标签：四段——连接 / 行为 / 个性化 / 高级（默认折叠）。
/// 为什么这么排：3.3 的「AI 润色」一屏摆了 14 个决策点，首配的人得自己在里面找出
/// 「粘 Key → 测一下」。现在第一屏只剩"选服务商 + 粘 Key + 两三个行为开关"，
/// 型号名、Base URL、温度这些实现细节全进「高级」——想调的人永远调得到，不想调的人看不见。
private struct AITab: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var metrics = Metrics.shared
    @AppStorage(SettingsKeys.polishLevel) private var polishLevel = PolishLevel.smart.rawValue
    @AppStorage(SettingsKeys.llmProvider) private var provider = LLMProvider.openai.rawValue
    @AppStorage(SettingsKeys.openaiBaseURL) private var baseURL = "https://api.openai.com/v1"
    @AppStorage(SettingsKeys.chatModel) private var chatModel = LLMCatalog.openaiPolishDefault
    @AppStorage(SettingsKeys.openaiCommandModel) private var openaiCommandModel = LLMCatalog.openaiCommandDefault
    @AppStorage(SettingsKeys.deepseekBaseURL) private var dsBaseURL = LLMProvider.deepseek.defaultBaseURL
    @AppStorage(SettingsKeys.deepseekModel) private var dsModel = LLMCatalog.deepseekPolishDefault
    @AppStorage(SettingsKeys.deepseekCommandModel) private var dsCommandModel = LLMCatalog.deepseekCommandDefault
    @AppStorage(SettingsKeys.qwenRegion) private var qwenRegion = LLMCatalog.QwenRegion.international.rawValue
    @AppStorage(SettingsKeys.qwenWorkspaceID) private var qwenWorkspace = ""
    @AppStorage(SettingsKeys.qwenModel) private var qwenModel = LLMCatalog.qwenPolishDefault
    @AppStorage(SettingsKeys.qwenCommandModel) private var qwenCommandModel = LLMCatalog.qwenCommandDefault
    @AppStorage(SettingsKeys.customBaseURL) private var customBaseURL = ""
    @AppStorage(SettingsKeys.customModel) private var customModel = ""
    @AppStorage(SettingsKeys.customCommandModel) private var customCommandModel = ""
    @AppStorage(SettingsKeys.localRuntime) private var localRuntime = LLMCatalog.LocalRuntime.ollama.rawValue
    @AppStorage(SettingsKeys.localModel) private var localModel = ""
    @AppStorage(SettingsKeys.localCommandModel) private var localCommandModel = ""
    @AppStorage(SettingsKeys.fastTier) private var fastTier = false
    @AppStorage(SettingsKeys.webSearchEnabled) private var webSearch = false
    @AppStorage(SettingsKeys.polishTemperature) private var polishTemp = 0.5
    @AppStorage(SettingsKeys.commandTemperature) private var commandTemp = 1.0
    @AppStorage(SettingsKeys.aboutMe) private var aboutMe = ""
    @AppStorage(SettingsKeys.customPolishRules) private var customRules = ""
    @State private var testResult = ""
    @State private var testing = false
    /// 「刷新模型列表」从端点取回来的型号（只在内存里，切服务商就丢——上一个端点的清单
    /// 放到下一个端点上纯属误导）
    @State private var fetchedModels: [String] = []
    @State private var refreshing = false
    @State private var refreshStatus = ""
    /// 高级区默认折叠：型号名 / Base URL / 温度是实现细节，不该占首屏
    @State private var advancedExpanded = false

    private var selected: LLMProvider { LLMProvider(rawValue: provider) ?? .openai }

    /// 界面上这一刻生效的 Base URL。**从 @AppStorage 的值推**而不是读 Settings.currentBaseURL：
    /// 后者不是 @Published，改了区域/地址界面不会重算。
    private var effectiveBaseURL: String {
        switch selected {
        case .openai: return baseURL
        case .deepseek: return dsBaseURL
        case .qwen:
            return LLMCatalog.qwenBaseURL(
                region: LLMCatalog.QwenRegion(rawValue: qwenRegion) ?? .international,
                workspaceID: qwenWorkspace)
        case .custom: return customBaseURL
        case .local: return (LLMCatalog.LocalRuntime(rawValue: localRuntime) ?? .ollama).baseURL
        }
    }

    private var searchStyle: LLMCatalog.WebSearchStyle {
        LLMCatalog.searchStyle(provider: selected, baseURL: effectiveBaseURL)
    }

    /// 润色/指令模型的输入框都绑到这两个 Binding 上——五个服务商共用一套控件，
    /// 不必把「输入框 + 快选 + 刷新 + 测试」这一排抄五遍（抄五遍就一定会有一遍忘了跟着改）。
    private var polishModelBinding: Binding<String> {
        switch selected {
        case .openai: return $chatModel
        case .deepseek: return $dsModel
        case .qwen: return $qwenModel
        case .custom: return $customModel
        case .local: return $localModel
        }
    }
    private var commandModelBinding: Binding<String> {
        switch selected {
        case .openai: return $openaiCommandModel
        case .deepseek: return $dsCommandModel
        case .qwen: return $qwenCommandModel
        case .custom: return $customCommandModel
        case .local: return $localCommandModel
        }
    }

    /// 下拉里显示的型号：内置预设在前，端点刷新来的在后
    private var modelChoices: [String] {
        LLMCatalog.mergedModelList(presets: LLMCatalog.presets(for: selected), fetched: fetchedModels)
    }

    /// 选中的型号是不是推理系——是的话温度参数根本不会被发出去，滑杆必须看得见地置灰，
    /// 而不是让用户以为自己在调一个其实无效的旋钮（3.3 之前就是静默无效）。
    private var polishTempIgnored: Bool {
        LLMCatalog.rejectsCustomTemperature(polishModelBinding.wrappedValue)
    }
    private var commandTempIgnored: Bool {
        LLMCatalog.rejectsCustomTemperature(commandModelBinding.wrappedValue)
    }
    /// 置灰说明里点名的那些型号（纯型号名，中英通用）
    private var ignoredTempModels: String {
        var names: [String] = []
        if polishTempIgnored { names.append(polishModelBinding.wrappedValue) }
        if commandTempIgnored { names.append(commandModelBinding.wrappedValue) }
        return names.joined(separator: " / ")
    }

    var body: some View {
        Form {
            Section(tr("连接", "Connection")) { connectionSection }
            Section(tr("行为", "Behavior")) { behaviorSection }
            Section(tr("个性化", "Personal")) { personalSection }
            Section { advancedSection }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        // 测试结果与刷新结果都是快照，切换语言后清掉，避免残留旧语言
        .onChange(of: l10n.language) { _, _ in
            testResult = ""
            refreshStatus = ""
        }
    }

    // MARK: 段 1 连接：服务商 → 拿 Key → 粘贴即验证

    @ViewBuilder
    private var connectionSection: some View {
        Picker(tr("服务商：", "Provider:"), selection: $provider) {
            ForEach(LLMProvider.allCases, id: \.rawValue) { p in
                Text(p.segmentName).tag(p.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: provider) { _, _ in
            testResult = ""
            // 上一个端点报上来的型号清单对新端点毫无意义
            fetchedModels = []
            refreshStatus = ""
        }

        // Qwen 的地址由「区域 + WorkspaceId」推出来：这两项不填就连不上，所以留在连接段，
        // 不能塞进折叠的高级区（其余几档的地址一律没有输入框）。
        if selected == .qwen {
            Picker(tr("接入区域：", "Region:"), selection: $qwenRegion) {
                ForEach(LLMCatalog.QwenRegion.allCases, id: \.rawValue) { region in
                    Text(region.displayName).tag(region.rawValue)
                }
            }
            if (LLMCatalog.QwenRegion(rawValue: qwenRegion) ?? .international).requiresWorkspaceID {
                TextField("WorkspaceId", text: $qwenWorkspace)
                    .textFieldStyle(.roundedBorder)
            }
            if effectiveBaseURL.isEmpty {
                Text(tr("这个区域的地址里带 WorkspaceId，填上才能用（在模型服务控制台的工作空间详情里）。",
                        "This region puts your workspace ID in the URL - fill it in (you will find it in the Model Studio console)."))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }

        // 官方几档的地址被老版本改过时必须看得见：看不见的自定义地址是查不出来的故障。
        // 正常情况下这里什么都不显示（地址展示留在高级区）。
        if (selected == .openai || selected == .deepseek), effectiveBaseURL != selected.defaultBaseURL {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("这一档的接口地址被改过：", "This provider's endpoint was overridden: ") + effectiveBaseURL)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
                Button(tr("恢复官方地址", "Restore the official URL")) {
                    if selected == .openai { baseURL = selected.defaultBaseURL }
                    else { dsBaseURL = selected.defaultBaseURL }
                }
                .fixedSize()
            }
        }

        KeyEntryView(provider: selected, model: polishModelBinding.wrappedValue)
    }

    // MARK: 段 2 行为：润色档位 + 质量 + 两个花钱的开关

    @ViewBuilder
    private var behaviorSection: some View {
        Picker(tr("润色档位：", "Polish mode:"), selection: $polishLevel) {
            ForEach(PolishLevel.allCases, id: \.rawValue) { level in
                Text(level.displayName).tag(level.rawValue)
            }
        }
        .pickerStyle(.radioGroup)
        Text(tr("「仅识别」完全不联网；「AI 润色」自适应处理力度——短句只做轻清理（去语气词、修错字），长段混乱口述自动重构成可直接使用的成品文字。所有应用同一套规则，档位完全由你决定；菜单栏图标里可以快速切换。",
                "Transcribe-only never touches the network. AI polish adapts: short phrases get light cleanup (fillers, typos); long rambling speech gets restructured into ready-to-use text. Same rules in every app - the mode is entirely your choice. Switch quickly from the menu bar."))
            .font(.caption)
            .foregroundColor(.secondary)

        qualityPicker

        Toggle(tr("语音指令允许联网搜索", "Let voice commands search the web"), isOn: $webSearch)
            .disabled(searchStyle == .unsupported)
        Text(webSearchHelp)
            .font(.caption)
            .foregroundColor(.secondary)

        Toggle(tr("多花钱换低延迟（Fast 档）", "Pay more for lower latency (Fast tier)"), isOn: $fastTier)
            .disabled(selected != .openai)
        Text(LLMCatalog.fastTierPriceNote
             + (selected == .openai ? "" : tr("　只有 OpenAI 有这个档位。", " Only OpenAI offers this tier.")))
            .font(.caption)
            .foregroundColor(.secondary)
        if let tier = lastServiceTier {
            Text(tr("上一次请求实际跑在：", "Last request actually ran at: ") + tier)
                .font(.caption)
                .foregroundColor(tier == "fast" ? .secondary : .orange)
        }

        Text(tr("语音指令（按住快捷键）：选中文字后按住开口，AI 自动判断意图——要求加工这段文字（改写/翻译）→ 直接替换选区；要求回复对方（「回复他…」「跟他说…」）→ 草稿进剪贴板按 ⌘V；要求写新东西 → 结果输出到光标处。什么都没选就是自由指令（草拟邮件、翻译、提问）。",
                "Voice commands (hold the hotkey): with text selected, speak naturally and AI infers the intent - transform the text (rewrite/translate) to replace the selection; reply to the sender (\"reply to him…\", \"tell them…\") to get a draft on the clipboard for ⌘V; compose something new to type it at your cursor. With nothing selected it's a free-form command (draft an email, translate, ask anything)."))
            .font(.caption)
            .foregroundColor(.secondary)
    }

    /// 质量二选一。**一次性选择，不是运行时自动切换**：选一下写两个型号字段，
    /// 之后每一次调用都用这两个型号，MicType 绝不在背后替用户跳档。
    @ViewBuilder
    private var qualityPicker: some View {
        if let summary = LLMCatalog.qualitySummary(provider: selected) {
            Picker(tr("质量：", "Quality:"), selection: qualityBinding) {
                ForEach(LLMCatalog.QualityTier.allCases, id: \.rawValue) { tier in
                    Text(tier.displayName).tag(Optional(tier))
                }
                // 用户在高级区自己挑过型号 → 如实显示「自选」，绝不把他钉回我们的某一档
                if currentTier == nil {
                    Text(tr("自选", "Custom")).tag(LLMCatalog.QualityTier?.none)
                }
            }
            .pickerStyle(.segmented)
            Text(summary)
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text(tr("这一档没有内置型号：请在下面的「高级」里填润色模型和指令模型。",
                    "No built-in models for this provider: set the polish and command models under Advanced below."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var currentTier: LLMCatalog.QualityTier? {
        LLMCatalog.tier(provider: selected,
                        polish: polishModelBinding.wrappedValue,
                        command: commandModelBinding.wrappedValue)
    }

    /// 质量档 ←→ 两个型号字段。读是"当前落在哪一档"，写是"把两个字段一起改掉"。
    private var qualityBinding: Binding<LLMCatalog.QualityTier?> {
        Binding(get: { currentTier },
                set: { newValue in
                    guard let tier = newValue,
                          let pair = LLMCatalog.models(provider: selected, tier: tier) else { return }
                    polishModelBinding.wrappedValue = pair.polish
                    commandModelBinding.wrappedValue = pair.command
                    Log.info("Quality tier set to \(tier.rawValue) provider=\(selected.rawValue)")
                })
    }

    /// 最近一轮拿到过 service_tier 的记录。勾了 Fast 却写着 default = 被服务商降级了，
    /// 这件事必须看得见——不然用户以为多付的钱买到了低延迟。
    private var lastServiceTier: String? {
        metrics.items.compactMap(\.serviceTier).first
    }

    private var webSearchHelp: String {
        switch searchStyle {
        case .unsupported:
            return tr("此服务商不支持。", "This provider does not support it.")
        case .qwenEnableSearch:
            return LLMCatalog.webSearchPriceNote
                + tr("　只作用于按住说出的指令，润色永不联网。Qwen 的兼容端点不回传来源链接，所以历史里不会有来源。",
                     " It applies only to held-down commands - polish never goes online. This Qwen endpoint returns no source links, so history will not show sources.")
        case .openaiResponsesTool, .openrouterPlugin:
            return LLMCatalog.webSearchPriceNote
                + tr("　只作用于按住说出的指令，润色永不联网；模型给的来源会显示在悬浮窗和历史里。",
                     " It applies only to held-down commands - polish never goes online. Sources come back with the answer and show up in the overlay and in History.")
        }
    }

    // MARK: 段 3 个性化

    @ViewBuilder
    private var personalSection: some View {
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
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("自定义规则（可选，润色和指令都生效）：", "Custom rules (optional - applies to polish and commands):"))
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

    // MARK: 段 4 高级（默认折叠）

    @ViewBuilder
    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                endpointFields
                modelFields
                temperatureSliders
            }
            .padding(.top, 6)
        } label: {
            Text(tr("高级（接口地址、型号、温度）", "Advanced (endpoint, models, temperature)"))
        }
    }

    // MARK: 接口地址（只有自定义档有输入框）

    @ViewBuilder
    private var endpointFields: some View {
        switch selected {
        case .openai, .deepseek:
            // 官方档的地址由 MicType 自己拼，不给输入框（填错一个字符的表现是"找不到模型"）。
            // 被改过时的警告在「连接」段，这里只是如实报一下当前打到哪儿。
            Text(tr("接口地址：", "Endpoint: ") + effectiveBaseURL)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            if effectiveBaseURL != selected.defaultBaseURL {
                Text(tr("要长期用自建网关，请改用「自定义端点」那一档。",
                        "To keep using a gateway, switch to the Custom endpoint provider."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .qwen:
            Text(effectiveBaseURL.isEmpty
                 ? tr("接口地址还拼不出来：上面的 WorkspaceId 还没填。",
                      "The endpoint cannot be derived yet: the workspace ID above is still empty.")
                 : tr("接口地址（自动拼好）：", "Endpoint (derived): ") + effectiveBaseURL)
                .font(.caption)
                .foregroundColor(effectiveBaseURL.isEmpty ? .orange : .secondary)
                .textSelection(.enabled)
        case .custom:
            TextField(tr("Base URL（要带版本段，如 https://api.moonshot.ai/v1）",
                         "Base URL (include the version segment, e.g. https://api.moonshot.ai/v1)"),
                      text: $customBaseURL)
                .textFieldStyle(.roundedBorder)
            if let problem = LLMCatalog.validateCustomBaseURL(customBaseURL) {
                Text(problem.message)
                    .font(.caption)
                    .foregroundColor(problem == .empty ? .secondary : .orange)
            }
            Text(tr("任何 OpenAI 兼容端点都能填：Kimi、Gemini 兼容层、z.ai、OpenRouter、自建网关。只接受 https（localhost 除外）。",
                    "Any OpenAI-compatible endpoint works here: Kimi, the Gemini compatibility layer, z.ai, OpenRouter, your own gateway. https only (localhost excepted)."))
                .font(.caption)
                .foregroundColor(.secondary)
        case .local:
            Picker(tr("本机运行时：", "Local runtime:"), selection: $localRuntime) {
                ForEach(LLMCatalog.LocalRuntime.allCases, id: \.rawValue) { runtime in
                    Text(runtime.displayName).tag(runtime.rawValue)
                }
            }
            Text(tr("接口地址：", "Endpoint: ") + effectiveBaseURL
                 + tr("。先在本机把它跑起来，再点「刷新模型列表」把已下载的模型取过来。",
                      ". Start it on this Mac first, then hit Refresh model list to pull in the models you have."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: 模型

    @ViewBuilder
    private var modelFields: some View {
        ModelField(label: tr("润色模型", "Polish model"),
                   text: polishModelBinding, presets: modelChoices,
                   testing: testing, refreshing: refreshing,
                   onTest: { runModelTest(tr("润色模型", "Polish model"), polishModelBinding.wrappedValue) },
                   onRefresh: refreshModelList)
        ModelField(label: tr("指令模型", "Command model"),
                   text: commandModelBinding, presets: modelChoices,
                   testing: testing, refreshing: refreshing,
                   onTest: { runModelTest(tr("指令模型", "Command model"), commandModelBinding.wrappedValue) },
                   onRefresh: refreshModelList)
        Text(modelHelp)
            .font(.caption)
            .foregroundColor(.secondary)
        if !refreshStatus.isEmpty {
            Text(refreshStatus)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        if !testResult.isEmpty {
            Text(testResult)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    /// 每档的型号说明。只写"贵不贵、快不快"这类会影响选择的事实，不吹参数。
    private var modelHelp: String {
        let shared = tr("上面的「质量」二选一就是在改这两个框。润色每句话都要跑，求快求省；指令低频，求质量。右侧下拉是内置快选，「刷新」按钮会问端点它当前有哪些型号；也可以手填任意型号名。",
                        "The Quality switch above writes these two fields. Polish runs on every sentence, so it wants speed and low cost; commands are rare and want quality. The drop-down holds the built-in picks, Refresh asks the endpoint what it serves today, and you can always type any model name.")
        switch selected {
        case .openai:
            return shared + tr("（luna 最便宜，terra 平衡，sol 旗舰，astra 最强也最贵。）",
                               " (luna is the cheapest, terra is balanced, sol is the flagship, astra is the strongest and the priciest.)")
        case .deepseek:
            return shared + tr("（deepseek-flash 快且便宜，润色时 MicType 会替你关掉思考模式；deepseek-v4-pro 更强。）",
                               " (deepseek-flash is fast and cheap - MicType turns thinking mode off for polish; deepseek-v4-pro is stronger.)")
        case .qwen:
            return shared + tr("（qwen3.8-flash / qwen3.8-max 是当前代；qwen-flash / qwen-plus / qwen-max 是稳定别名，换代时自动指向新模型。）",
                               " (qwen3.8-flash / qwen3.8-max are the current generation; qwen-flash / qwen-plus / qwen-max are stable aliases that follow each new generation.)")
        case .custom:
            return shared + tr("（这一档没有内置清单：型号名照服务商文档填，或点「刷新」。）",
                               " (No built-in list here: type the model id from your provider's docs, or hit Refresh.)")
        case .local:
            return shared + tr("（填你本机已经拉下来的模型名，例如 Ollama 里的 llama3.1:8b。）",
                               " (Use the model you have pulled locally, such as llama3.1:8b in Ollama.)")
        }
    }

    // MARK: 温度

    @ViewBuilder
    private var temperatureSliders: some View {
        HStack {
            Text(tr("润色温度：", "Polish temperature:"))
                .foregroundColor(polishTempIgnored ? .secondary : .primary)
            Slider(value: $polishTemp, in: 0...1.5)
                .disabled(polishTempIgnored)
            Text(String(format: "%.2f", polishTemp))
                .monospacedDigit()
                .foregroundColor(polishTempIgnored ? .secondary : .primary)
                .frame(width: 38, alignment: .trailing)
        }
        HStack {
            Text(tr("指令温度：", "Command temperature:"))
                .foregroundColor(commandTempIgnored ? .secondary : .primary)
            Slider(value: $commandTemp, in: 0...1.5)
                .disabled(commandTempIgnored)
            Text(String(format: "%.2f", commandTemp))
                .monospacedDigit()
                .foregroundColor(commandTempIgnored ? .secondary : .primary)
                .frame(width: 38, alignment: .trailing)
        }
        Text(tr("低 = 稳定保真，高 = 自然多样。默认：润色 0.5 / 指令 1.00（即模型默认值）。",
                "Lower = faithful and stable; higher = natural and varied. Defaults: polish 0.5 / commands 1.00 (the model default)."))
            .font(.caption)
            .foregroundColor(.secondary)
        if polishTempIgnored || commandTempIgnored {
            Text(tr("置灰的滑杆对应推理系模型（\(ignoredTempModels)）：这类模型只接受默认温度，MicType 干脆不发这个参数。换一个非推理型号就能再调。",
                    "The greyed-out slider belongs to a reasoning model (\(ignoredTempModels)): those only accept their default temperature, so MicType does not send the parameter at all. Pick a non-reasoning model to re-enable it."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: 动作

    /// 单个模型的连通性/速度测试。**不再顺手保存 Key**：Key 只由「连接」段验证通过后写钥匙串。
    private func runModelTest(_ name: String, _ model: String) {
        testing = true
        testResult = ""
        LLMClient.testModel(model) { ok, message in
            testing = false
            testResult = name + tr("（", " (") + model + tr("）", ")") + tr("：", ": ")
                + (ok ? "✓ " : "✗ ") + message
        }
    }

    /// 问端点「你现在有哪些型号」。失败就保持内置清单不动——刷新是锦上添花，
    /// 不该因为一次拉取失败在用户脸上弹个框。
    private func refreshModelList() {
        refreshing = true
        refreshStatus = ""
        LLMClient.fetchModelIDs { ids in
            refreshing = false
            guard let ids = ids, !ids.isEmpty else {
                refreshStatus = tr("端点没有返回模型列表，下拉里仍是内置清单",
                                   "The endpoint returned no model list - the built-in picks are unchanged")
                return
            }
            fetchedModels = ids
            refreshStatus = tr("已从端点取到 \(ids.count) 个可用型号", "Pulled \(ids.count) usable models from the endpoint")
        }
    }
}

/// 模型名输入框 + 预设快选下拉（仍可手填任意兼容模型名）+ 单独的测试按钮
private struct ModelField: View {
    let label: String
    @Binding var text: String
    let presets: [String]
    var testing: Bool = false
    var refreshing: Bool = false
    var onTest: (() -> Void)? = nil
    /// 「刷新模型列表」：问端点它现在有哪些型号。写死的清单一定会过时，端点自己不会。
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
            // 自定义端点与本机模型没有内置清单，空菜单不显示（一个点不开的箭头比没有箭头更糟）
            if !presets.isEmpty {
                Menu {
                    ForEach(presets, id: \.self) { name in
                        Button(name) { text = name }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let onRefresh = onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(refreshing)
                .help(tr("刷新模型列表", "Refresh model list"))
                .fixedSize()
            }
            if let onTest = onTest {
                Button(testing ? tr("测试中…", "Testing…") : tr("测试", "Test"), action: onTest)
                    .disabled(testing)
                    .fixedSize()
            }
        }
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
