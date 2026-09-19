import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MARK: - 设置窗口

/// 设置窗口的四个标签。有名字才能从别处深链过去（菜单栏「配置 AI…」、悬浮窗的「去配置」、
/// 模型升级横幅）——把人丢进设置窗口第一页再让他自己找，等于没给路。
///
/// 4.0.2 按**一条轴**重新命名（用户 2026-09-19 实测后拍板）：「在我的 Mac 上跑、免费」
/// 对「用我的 Key、要花钱」。4.0.1 那组名字（「听写」/「AI」）是按功能切的，而用户脑子里
/// 分的是钱和隐私——于是"云端识别的开关为什么在 AI 页"这种问题根本没法回答。
enum SettingsTab: String, Hashable, CaseIterable {
    case general
    /// 原「听写」：麦克风、识别语言、词汇表、本机模型
    case localRecognition
    /// 原「AI」：服务商、Key、模型、（阿里云的）云端识别开关
    case cloudAI
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
            // 「本地识别」：在这台 Mac 上跑、免费、不联网的那一半
            RecognitionTab()
                .tabItem { Label(tr("本地识别", "On-device recognition"), systemImage: "waveform") }
                .tag(SettingsTab.localRecognition)
            // 「云端 AI」：用你自己的 Key、按用量付费的那一半（润色、语音指令、可选的云端识别）
            AITab()
                .tabItem { Label(tr("云端 AI", "Cloud AI"), systemImage: "wand.and.stars") }
                .tag(SettingsTab.cloudAI)
            AboutTab()
                .tabItem { Label(tr("关于", "About"), systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 560, height: 500)
    }
}

/// 每一页顶上那一句话：这一页管的是什么、要不要花钱。
///
/// 为什么值得占一行：标签名只有三四个字，而这四页的分法是"跑在哪、谁付钱"——
/// 不把这句话写出来，用户仍然要靠点进去猜（4.0.1 的实测反馈正是"分不清两页的区别"）。
private struct TabIntro: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 10)
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
        VStack(spacing: 0) {
            // 英文写 behavior（美式）：同一页下面那一段的标题就是 "Behavior"，
            // 一个 behaviour 一个 behavior 只会显得是拼错了
            TabIntro(text: tr("快捷键、悬浮窗和行为", "Hotkey, overlay and behavior"))
            Form {
                ForEach(GeneralSectionOrder.allCases, id: \.self) { section in
                    sectionView(section)
                }
            }
            .formStyle(.grouped)
        }
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
            // 只摆右侧三颗（用户 2026-09-19 拍板）：Fn 要先去系统设置里让系统放手，
            // 左侧几颗天天参与 ⌘C / ⌥← ——两类都得先上一课，摆出来等于把坑一起摆出来。
            // 名字一律写全（「右 Option (⌥)」），不再用 R⌥ 这种只有作者认得的缩写。
            Picker(tr("听写快捷键：", "Dictation hotkey:"), selection: $hotkey) {
                ForEach(HotkeyChoice.offered, id: \.rawValue) { choice in
                    Text(choice.displayName).tag(choice.rawValue)
                }
                // 老设置里存着的那一颗（左侧键 / Fn）照常工作，就得照常列出来：
                // 选择器里没有一项对得上时，控件是空白的，看着像设置被我们弄丢了
                if !HotkeyChoice.offered.contains(selectedHotkey) {
                    Text(selectedHotkey.displayName).tag(selectedHotkey.rawValue)
                }
            }
            Text(tr("轻点：开始 / 结束听写 · 按住说话、松手：执行语音指令 · 录音中按 Esc 取消（一个字都不会输入）。",
                    "Tap: start / stop dictation · Hold to speak a command, release to run · Esc cancels while recording (nothing is inserted)."))
                .font(.caption)
                .foregroundColor(.secondary)
            // 处理中的 Esc 与录音中的不是一回事，而这件事从前只能靠用户自己撞出来：
            // 长录音已经转出前几段时，第一次 Esc 是"停掉后面、把手上的字插入"（悬浮窗那颗
            // 胶囊这时也会改写成「收尾并输入」），再按一次才是彻底丢弃
            Text(tr("长录音识别到一半时按 Esc 是「收尾并输入」：停掉还没转的部分，把已经转好的照常插入（悬浮窗上的胶囊会跟着改字）。再按一次才是彻底丢弃。",
                    "While a long take is still being transcribed, Esc means finish and insert: later parts are dropped and what is already transcribed goes in as usual (the overlay chip says so). Press it again to discard everything."))
                .font(.caption)
                .foregroundColor(.secondary)
            // Fn / 🌐 不在可选那三档里了，但老设置和导入的设置文件仍然能把它存进来——
            // 存着它的人**必须**先去系统设置里让系统放手，否则每次轻点都被系统抢去切输入法。
            // 4.0.1 把这段说明连同那颗按钮一起删了（Support.openKeyboardSettings 从此没有调用方），
            // 于是唯一还需要这一课的人反而读不到它。
            if selectedHotkey == .fn {
                HStack(alignment: .firstTextBaseline) {
                    Text(tr("用 Fn / 🌐 当热键要先去 系统设置 → 键盘，把「按下🌐键」改成「不执行任何操作」，否则这一颗键会被系统拿去切输入法或弹表情面板。",
                            "To use Fn / 🌐 as the hotkey, open System Settings → Keyboard and set “Press 🌐 key to” to “Do Nothing”; otherwise the system takes that key for input switching or the emoji panel."))
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(tr("打开键盘设置", "Open Keyboard Settings")) {
                        Permissions.openKeyboardSettings()
                    }
                    .fixedSize()
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
            // 草稿是本机模型转的（云端档不会为了看草稿把每一秒都上传一遍）。只用云端、
            // 从没下过本机模型的人打开这个开关什么也不会发生——与其让他录一遍再来报 bug，
            // 不如当面说清这个开关这会儿没有用武之地。
            if !QwenEngine.shared.isModelAvailable {
                Text(tr("草稿由本机模型转写。这台 Mac 上还没有本机模型（云端识别不需要它），所以这个开关现在不起作用。",
                        "The draft is produced by the on-device model. There is no on-device model on this Mac yet (a cloud engine does not need one), so this switch does nothing for now."))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
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
            Text(tr("多屏时悬浮窗永远出现在鼠标所在的那块屏幕，这里只决定它落在这块屏的哪个位置。录音中和处理中可以直接点胶囊右端那颗小按钮，和按 Esc 完全一样（它这一刻写着什么就是什么：「⎋ 取消」或「⎋ 收尾并输入」）；点它不会切走当前应用的输入焦点。",
                    "On multiple displays the overlay always appears on the screen holding the pointer; this only picks where it sits on that screen. While recording or processing you can click the small button at the right end of the capsule — it does exactly what it says at that moment (⎋ Cancel, or ⎋ Finish & insert), same as pressing Esc, and it never takes focus away from the app you are typing into."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: ④ 行为

    private var behaviourSection: some View {
        // 英文拼写统一用美式："AI" 页的同名段落写的是 "Behavior"，同一个窗口里
        // 一个 Behaviour 一个 Behavior 只会显得是拼错了
        Section(tr("行为", "Behavior")) {
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
            // 清单要跟着 SettingsBackup.Key.all 走：v4.0 往文件里加了识别块（引擎 / 识别语言 /
            // 接入地址 / 本机模型仓库），这段说明还停在 3.x 就等于没说。
            // 「导入可能把识别改成云端」也写在这里——导入后那张模态摘要确实会讲，
            // 但**决定要不要信这个文件**是在点「导入设置…」之前发生的。
            Text(tr("导出一个 JSON 文件：词汇表、口水词、关于我、自定义规则、润色档位与各服务商的型号、识别引擎与识别语言、阿里云接入地址、本机识别模型、热键与界面语言。导入是合并——词表取并集（老词条一条不少），其余只覆盖文件里出现的项。\n别人给的文件可能把识别引擎改成云端（导入后会明确提示一次，云端要自己填 Key 才跑得起来）。\nAPI Key 从不导出、也从不导入：Key 只在系统钥匙串里，写进文件就等于把它交给了拿到文件的人。文件格式 Mac 与 Windows 通用。",
                    "Exports one JSON file: vocabulary, filler words, about-me, custom rules, polish mode and each provider's model names, recognition engine and recognition language, the Alibaba API host, on-device speech model, hotkey and interface language. Import merges — vocabulary lists are unioned (nothing you already have is lost) and other settings are overwritten only where the file has them.\nA file from someone else can switch recognition to a cloud engine (the import summary says so, and a cloud engine still needs a key of your own before it runs).\nAPI keys are never exported or imported: they live in the Keychain, and a file containing one gives it away to whoever receives the file. The format is shared with the Windows build."))
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

// MARK: - 本地识别（麦克风 / 语言 / 词汇表 / 本机模型）

/// 「本地识别」页只管一件事：说出来的话怎么在**这台 Mac 上**变成字。
/// 识别引擎、云端的 Key / 接入地址 / 「测试识别」全部在「云端 AI」页——
/// 那几件事都是"要不要用 AI、用哪家"的一部分，分在两页等于让用户在两处各选一次
/// （4.0.0 正是这样选出了两个对不上的值）。这里只留云端开着时要更正的那几句话。
private struct RecognitionTab: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.qwenModelRepo) private var qwenRepo = QwenModels.defaultRepo
    @AppStorage(SettingsKeys.recognitionLanguage) private var recognitionLanguage = RecognitionLanguages.autoCode
    @AppStorage(SettingsKeys.customVocabulary) private var vocabulary = ""
    /// 只读：云端识别的开关在「云端 AI」页。这里读它只为把几句话说对（语言提示送不送得到、
    /// 「识别在本机完成」那句对云端不成立、本机模型这会儿只用于草稿与回落）
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
    @ObservedObject private var downloader = QwenModelDownloader.shared
    @ObservedObject private var upgrader = ModelUpgrader.shared
    /// 模型目录到货时下拉框要立刻跟上（首启动时目录还在路上）
    @ObservedObject private var catalogStore = ModelCatalogStore.shared
    @ObservedObject private var metrics = Metrics.shared
    @State private var refreshTick = 0
    @State private var updateMessage = ""
    @State private var checkingUpdate = false

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
                // 这一条是三种提示里最该能拒绝的：重下几百 MB 换来的是同一个模型。
                // 「以后再说」压住的是**这一份文件**，上游真出下一版时提示照样回来。
                Button(tr("以后再说", "Not now")) { upgrader.dismissCurrentOffer() }
                    .disabled(upgrader.isBusy)
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

    var body: some View {
        VStack(spacing: 0) {
            TabIntro(text: tr("在你的 Mac 上运行，免费，不联网",
                              "Runs on your Mac. Free, no network."))
            Form {
                // 麦克风选择 + 电平自检：与引导第二屏共用同一个组件（MicCheck.swift）
                Section {
                    MicCheckPanel()
                }

                Section {
                    languageSection
                }

                Section {
                    localModelSection
                }

                Section {
                    vocabularySection
                }

                // 性能：只是照镜子，不提供任何"自动优化"开关——快慢的原因摆出来，怎么调由用户决定
                Section(tr("性能", "Performance")) {
                    performanceSection
                }
            }
            .formStyle(.grouped)
        }
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
            // 下载状态已经是语言中性的 phase，麦克风自检的文字归 MicCheckPanel 自己管；
            // 升级器那句结论仍是快照，照旧清掉
            if !upgrader.isBusy { upgrader.clearStatus() }
        }
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
        // 云端识别开着的时候，本机模型并没有变成多余的东西——两件事都要说清，
        // 否则用户会把它删掉，然后发现草稿没了、云端一出错就整段丢了
        if engineChoice.isCloud {
            Text(tr("云端识别开着（在「云端 AI」页里打开的）：日常听写走云端。\n本机模型仍然有用——录音时那行实时草稿由它转，云端出错时也由它把这一段接住。",
                    "Cloud recognition is on (you turned it on under Cloud AI), so everyday dictation goes to the cloud.\nThe on-device model still matters: it produces the live draft while you record, and it catches the take if the cloud call fails."))
                .font(.caption)
                .foregroundColor(.secondary)
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

    // MARK: 词汇表 / 口水词 / 性能（与引擎无关，两档都生效）

    @ViewBuilder
    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 这条提示就摆在词汇表上面：它要用户做的动作是"往下面这个框里填词"，
            // 以前写成「设置 → 云端 AI → 词汇表」指向了一个不存在的界面（AI 页没有词汇表），
            // 而且当时挂在本机模型那一段里，选了云端的阿语用户根本看不到——
            // 词汇表对云端同样作为热词生效，这条提示与引擎无关。
            if showsArabicVocabularyTip {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "lightbulb")
                            .foregroundColor(.orange)
                        Text(tr("阿拉伯语：把英文专名加进词汇表",
                                "Arabic: put English product names in your vocabulary"))
                            .fontWeight(.medium)
                    }
                    Text(tr("阿语口述里夹的英文品牌 / 产品名会被写成阿语字母（Microsoft Excel → معرفة أكسيل）。把它们填进下面的词汇表，识别时会作为热词直接送进模型：实测字错率从 12.5% 降到 4.0%，比换更大的模型有效得多。\n能用的是现代标准阿语和朗读级内容；海湾、埃及等方言不承诺能用——那是模型的已知短板，不是设置问题。",
                            "English brand and product names spoken inside Arabic come back transliterated into Arabic letters (Microsoft Excel becomes an Arabic spelling). Put them in the vocabulary box below and they are fed to the model as hotwords: measured character error rate went from 12.5% down to 4.0%, far more than a bigger model buys you.\nModern Standard Arabic and read-aloud speech are usable. Gulf, Egyptian and other dialects are not promised - that is a known weakness of the model, not a setting you can fix."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 4)
            }
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
            // 4.0.2 拿掉了「口水词过滤」输入框：内置中 / 英 / 阿三套保守词表自动生效，
            // 没有人应该为了不打出「嗯」而去维护一张表（见 TextPostProcessor.builtInFillerWords）
            Text(tr("口水词（嗯、呃、um、uh、يعني…）默认就在本机删掉，不用自己列表；只删独立成分，「那个人」这种词里的字一个都不动。",
                    "Filler words (um, uh and their Chinese and Arabic equivalents) are dropped on this Mac automatically - there is no list to fill in, and only standalone fillers are removed."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

// MARK: - 云端 AI（润色 + 语音指令 + 可选的云端识别）

/// 「云端 AI」页的形状：**整页只有一个决定**开路。
/// ① 使用方式：只用本地 / 本地 + AI；② 选了 AI 再选一个服务商、贴一把 Key；
/// ③ 一个「模型」下拉（默认就是这家最好的那个）；④ 只有阿里云多一个「识别也用云端」开关；
/// ⑤ 关于我 / 自定义规则；剩下的（分开设型号、联网搜索、优先处理）收在「高级」里。
///
/// 4.0.2 又拿掉了两样东西（用户 2026-09-19 实测后拍板）：
///   • **温度滑杆**——推理系型号根本不接受自定义温度（那两根滑杆常年灰着），而这是绝大多数人
///     不该碰的旋钮。设置键与内部默认值原样留着（Settings.polishTemperature / commandTemperature），
///     只是界面上不再摆它。
///   • **「其他 OpenAI 兼容服务 / 本机模型」的地址与型号输入框**——那是给 Ollama、公司网关
///     准备的高级动作，用「导入设置…」配置即可。LLMProvider.custom / .local 仍在代码里，
///     已经在用的人一切照旧，只是这一页多一句说明和一颗「改用官方三档」的按钮。
private struct AITab: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var metrics = Metrics.shared
    @AppStorage(SettingsKeys.polishLevel) private var polishLevel = PolishLevel.smart.rawValue
    @AppStorage(SettingsKeys.llmProvider) private var provider = LLMProvider.openai.rawValue
    @AppStorage(SettingsKeys.openaiBaseURL) private var baseURL = "https://api.openai.com/v1"
    @AppStorage(SettingsKeys.chatModel) private var chatModel = LLMCatalog.defaultModel(for: .openai)
    @AppStorage(SettingsKeys.openaiCommandModel) private var openaiCommandModel = LLMCatalog.defaultModel(for: .openai)
    @AppStorage(SettingsKeys.deepseekBaseURL) private var dsBaseURL = LLMProvider.deepseek.defaultBaseURL
    @AppStorage(SettingsKeys.deepseekModel) private var dsModel = LLMCatalog.defaultModel(for: .deepseek)
    @AppStorage(SettingsKeys.deepseekCommandModel) private var dsCommandModel = LLMCatalog.defaultModel(for: .deepseek)
    @AppStorage(SettingsKeys.qwenAPIHost) private var qwenAPIHost = ""
    @AppStorage(SettingsKeys.qwenResolvedHost) private var qwenResolvedHost = ""
    @AppStorage(SettingsKeys.qwenModel) private var qwenModel = LLMCatalog.defaultModel(for: .qwen)
    @AppStorage(SettingsKeys.qwenCommandModel) private var qwenCommandModel = LLMCatalog.defaultModel(for: .qwen)
    @AppStorage(SettingsKeys.customBaseURL) private var customBaseURL = ""
    @AppStorage(SettingsKeys.customModel) private var customModel = ""
    @AppStorage(SettingsKeys.customCommandModel) private var customCommandModel = ""
    @AppStorage(SettingsKeys.localRuntime) private var localRuntime = LLMCatalog.LocalRuntime.ollama.rawValue
    @AppStorage(SettingsKeys.localModel) private var localModel = ""
    @AppStorage(SettingsKeys.localCommandModel) private var localCommandModel = ""
    @AppStorage(SettingsKeys.fastTier) private var fastTier = false
    @AppStorage(SettingsKeys.webSearchEnabled) private var webSearch = false
    @AppStorage(SettingsKeys.aboutMe) private var aboutMe = ""
    @AppStorage(SettingsKeys.customPolishRules) private var customRules = ""
    /// 识别引擎：云端识别的开关就在这一页（阿里云那一档下面），「本地识别」页只读它。
    /// 同一个账号、同一把 Key、同一台主机只在这里选一次。
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
    /// 4.0.1 的默认型号迁移改掉了什么（"旧>新"，见 LLMCatalog.encodeModelChanges）。
    /// 点过「知道了」就清空——一次性提示，不留在页面上碍事。
    @AppStorage(SettingsKeys.modelMigrationNotice) private var modelMigrationNotice = ""
    @State private var testResult = ""
    /// 钥匙串不是 @AppStorage，删掉一把 Key 之后这一页不会自己重算。
    /// 这个计数器就是那一下"手动推一把"（只影响显示，不落盘）。
    @State private var keychainTick = 0
    @State private var testing = false
    /// 「刷新模型列表」从端点取回来的型号（只在内存里，切服务商就丢——上一个端点的清单
    /// 放到下一个端点上纯属误导）
    @State private var fetchedModels: [String] = []
    @State private var refreshing = false
    @State private var refreshStatus = ""
    /// 高级区默认折叠：分开设型号、联网搜索、优先处理都是少数人才动的东西，不该占首屏
    @State private var advancedExpanded = false
    /// 「模型」下拉停在「自定义…」那一项上。只影响这一页怎么显示，不落盘。
    @State private var customModelChosen = false

    private var selected: LLMProvider { LLMProvider(rawValue: provider) ?? .openai }
    private var currentPolishLevel: PolishLevel { PolishLevel(rawValue: polishLevel) ?? .smart }
    private var engineChoice: RecognitionEngineChoice { RecognitionEngineChoice.parse(recognitionEngine) }
    /// 当前这一档的钥匙串里有没有一把 Key。判的是"按住说指令会不会真的发出去"，
    /// 所以看的是这一档自己的那把，而不是 LLMClient.isConfigured（本机模型那一档没 Key 也算配好）
    private var hasStoredKey: Bool {
        _ = keychainTick
        return KeychainHelper.loadAPIKey(account: selected.keychainAccount) != nil
    }
    private var usageMode: AIUsageMode {
        AISetup.mode(polishLevel: currentPolishLevel, engine: engineChoice)
    }

    /// 界面上这一刻生效的 Base URL。**从 @AppStorage 的值推**而不是读 Settings.currentBaseURL：
    /// 后者不是 @Published，改了接入地址界面不会重算。
    private var effectiveBaseURL: String {
        switch selected {
        case .openai: return baseURL
        case .deepseek: return dsBaseURL
        case .qwen:
            // 接入地址是试出来的：粘了就用粘的，否则用试通的那台（两者都空时 Settings
            // 会退回老设置推出来的地址）。见 AlibabaEndpoint。
            let host = AlibabaEndpoint.normalizeHost(qwenAPIHost)
                ?? AlibabaEndpoint.normalizeHost(qwenResolvedHost)
            return host.map { AlibabaEndpoint.compatibleBaseURL(host: $0) } ?? Settings.shared.qwenBaseURL
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

    /// 「高级」里那两个输入框右边的快选清单：内置预设在前，端点刷新来的在后
    private var modelChoices: [String] {
        LLMCatalog.mergedModelList(presets: LLMCatalog.presets(for: selected), fetched: fetchedModels)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabIntro(text: tr("用你自己的 Key，按用量付费；可选",
                              "Uses your own key, pay per use. Optional."))
            Form {
                Section(tr("使用方式", "How you use MicType")) { usageSection }
                // 「只用本地」时下面一个控件都不摆：那一档的全部事实就是"不联网、不花钱"，
                // 再摆一排 AI 设置只会让人以为自己还有什么没配完
                if usageMode == .withAI {
                    Section(tr("服务商", "Provider")) { providerSection }
                    Section("API Key") { keySection }
                    Section(tr("模型", "Model")) { modelSection }
                    if selected == .qwen {
                        // 开关 + 说明 + 接入地址 + 「测试识别」：与引导第三屏共用同一个组件
                        Section(tr("云端识别（可选）", "Cloud recognition (optional)")) {
                            CloudRecognitionFields()
                        }
                    }
                    Section(tr("关于我与自定义规则", "About me and rules")) { personalFields }
                    Section { advancedSection }
                }
            }
            .formStyle(.grouped)
        }
        .padding(.top, 4)
        // 测试结果与刷新结果都是快照，切换语言后清掉，避免残留旧语言
        .onChange(of: l10n.language) { _, _ in
            testResult = ""
            refreshStatus = ""
        }
    }

    // MARK: 段 1 使用方式（整页唯一的决定）

    @ViewBuilder
    private var usageSection: some View {
        Picker(tr("使用方式：", "How you use MicType:"), selection: usageModeBinding) {
            ForEach(AIUsageMode.allCases, id: \.rawValue) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        Text(usageMode == .localOnly
             ? tr("识别和输入全在这台 Mac 上：不联网、不花钱，也不需要填 Key。\n按住快捷键说指令需要 AI，选「本地 + AI」才有。",
                  "Recognition and typing all happen on this Mac: no network, no cost, and no key to fill in.\nHold-to-command needs AI - pick Local + AI to get it.")
             : tr("轻点听写照旧在本机识别，识别完的文字交给你选的服务商润色；按住说指令也走这家。\n费用由服务商直接结给你，MicType 不经手。",
                  "Tap-to-dictate still recognizes on this Mac; the text is then polished by the provider you pick, and hold-to-command uses the same one.\nYou pay that provider directly - MicType never takes a cut."))
            .font(.caption)
            .foregroundColor(.secondary)
        // 「只用本地」只写回"润色关掉 + 识别回本机"两条，**钥匙串里那把 Key 不动**
        // （删 Key 是破坏性动作，只能由用户自己点）。可指令路径不看档位：按住说指令照样
        // 会把选区和这句话发给服务商、照样计费。这一段又把服务商/Key/模型整段藏起来，
        // 所以这句话不说，他既看不到那把 Key，也不知道它还在花钱。
        if usageMode == .localOnly,
           AISetup.showsStoredKeyNotice(mode: usageMode, hasCredential: hasStoredKey) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("注意：钥匙串里还存着 \(selected.segmentName) 的 Key。按住快捷键说指令仍然会用它调用云端并计费（轻点听写不会）。",
                        "Note: a \(selected.segmentName) key is still in your Keychain. Hold-to-command keeps using it, and keeps billing you (tap-to-dictate does not)."))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("删掉这把 Key", "Remove that key")) {
                    KeychainHelper.deleteAPIKey(account: selected.keychainAccount)
                    Log.info("API key removed provider=\(selected.rawValue) reason=local only")
                    // 删完这一页要立刻不再显示上面那句：@AppStorage 管不着钥匙串，自己推一下
                    keychainTick &+= 1
                }
                .fixedSize()
            }
        }
        // 4.0.1 的默认型号迁移可能悄悄把型号换贵了（4.0.0 的「快」档和出厂默认一字不差，
        // 分不出"停在默认"和"明确选过便宜档"）。分不出就当面说，并给一颗「知道了」。
        if let notice = LLMCatalog.modelChangeNotice(modelMigrationNotice) {
            VStack(alignment: .leading, spacing: 6) {
                Text(notice)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("知道了", "Got it")) { modelMigrationNotice = "" }
                    .fixedSize()
            }
        }
        // 从菜单栏把润色关掉、云端识别却还开着：这一页会显示「本地 + AI」，
        // 而轻点听写其实不润色。说出来，并给一颗打开的按钮——不替他改
        if usageMode == .withAI, currentPolishLevel == .off {
            HStack(alignment: .firstTextBaseline) {
                Text(tr("轻点听写现在不润色（润色档位在菜单栏里关着），只输出识别原文。",
                        "Tap-to-dictate is not polishing right now: polish mode is switched off in the menu bar, so you get the raw transcript."))
                    .font(.caption)
                    .foregroundColor(.orange)
                Spacer()
                Button(tr("打开润色", "Turn polish on")) {
                    polishLevel = PolishLevel.smart.rawValue
                }
                .fixedSize()
            }
        }
        // 4.0.0 的「云端 · OpenAI」识别：界面上已经没有这一档了，但设置里可能还存着。
        // 绝不替他改（音频出不出这台 Mac 只由用户点），但必须当面说，并给一颗回本机的按钮。
        if AISetup.showsLegacyOpenAICloudNotice(engine: engineChoice) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("这台 Mac 还在用 OpenAI 云端识别（每段录音都会上传）。4.0.1 起不再提供这一档，但你现在这份设置照常工作。",
                        "This Mac still uses OpenAI cloud recognition, so every take is uploaded. That option is no longer offered in 4.0.1, but your current setting keeps working."))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("改回本机识别", "Switch back to on-device recognition")) {
                    recognitionEngine = RecognitionEngineChoice.local.rawValue
                    Log.info("Legacy cloudOpenAI recognition switched back to local")
                }
                .fixedSize()
            }
        }
        // 云端识别停在阿里云、服务商却不是阿里云：下面那个开关只在阿里云档渲染，于是音频
        // 一直在上传、界面上却没有关掉它的控件（4.0.0 的识别页有独立引擎选择器，设置导入
        // 也能写出这种组合）。和上面那条同样处理：当面说 + 一颗按钮，绝不替他改。
        if AISetup.showsStrandedAlibabaCloudNotice(engine: engineChoice, provider: selected) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("这台 Mac 的识别还走着阿里云（每段录音都会上传、按秒计费），但 AI 服务商已经不是阿里云了——所以下面没有那个开关。",
                        "Speech recognition on this Mac still goes to Alibaba (every take is uploaded and billed per second), but your AI provider is no longer Alibaba, so the switch for it is not shown below."))
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("改回本机识别", "Switch back to on-device recognition")) {
                    recognitionEngine = RecognitionEngineChoice.local.rawValue
                    Log.info("Stranded cloudAlibaba recognition switched back to local")
                }
                .fixedSize()
            }
        }
    }

    /// 「使用方式」这一下到底改了什么，全在 AISetup 那几个纯函数里（单测钉死）。
    /// 这里只负责把结果写进设置，并记一行日志——用户看得见的每一次状态变化都要能在日志里找到。
    private var usageModeBinding: Binding<AIUsageMode> {
        Binding(get: { usageMode },
                set: { newMode in
                    switch newMode {
                    case .localOnly:
                        let writes = AISetup.localOnlyWrites()
                        polishLevel = writes.polish.rawValue
                        recognitionEngine = writes.engine.rawValue
                    case .withAI:
                        polishLevel = AISetup.polishAfterEnablingAI(currentPolishLevel).rawValue
                    }
                    Log.info("AI usage mode=\(newMode.rawValue)")
                })
    }

    // MARK: 段 2 服务商：选一家（选择器与引导第三屏共用同一个组件）

    @ViewBuilder
    private var providerSection: some View {
        ProviderPickerField(selection: providerBinding, offered: offeredProviders)

        // 官方几档的地址被老版本改过时必须看得见：看不见的自定义地址是查不出来的故障。
        // 正常情况下这里什么都不显示。
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

        if selected == .custom || selected == .local {
            legacyProviderNotice
        }
    }

    /// 换服务商要做的事全在这个 setter 里（引导页那一处语义不同：看着的那一档要验证通过才采纳，
    /// 所以两处各自写 setter，共用的只有选择器本身）。
    private var providerBinding: Binding<LLMProvider> {
        Binding(get: { selected },
                set: { next in
                    guard next != selected else { return }
                    // 换走之后音频不能还在往阿里云传——而且界面上已经没有那个开关可以关了。
                    // 判据是纯函数，引导页换服务商走的是同一条（两处各写一份就一定会走散）
                    if let engine = AISetup.engineAfterProviderChange(current: engineChoice, next: next) {
                        recognitionEngine = engine.rawValue
                        Log.info("Cloud recognition off: provider=\(next.rawValue)")
                    }
                    provider = next.rawValue
                    testResult = ""
                    // 上一个端点报上来的型号清单对新端点毫无意义
                    fetchedModels = []
                    refreshStatus = ""
                    customModelChosen = false
                    Log.info("AI provider=\(next.rawValue)")
                })
    }

    /// 选择器里摆哪几档：三家云服务商。
    /// 「其他 OpenAI 兼容服务」与「本机模型」4.0.2 起没有入口了（只能靠导入设置文件），
    /// 但**他正在用的那一档必须摆出来**，否则选择器上没有一项对得上，看着像被我们悄悄改掉了。
    private var offeredProviders: [LLMProvider] {
        var list: [LLMProvider] = [.openai, .deepseek, .qwen]
        if !list.contains(selected) { list.append(selected) }
        return list
    }

    /// 还在用自定义端点 / 本机模型的人看到的那一行：说清界面上为什么没有那些输入框了，
    /// 并给一颗回到官方三档的按钮。**绝不替他改**——那一档可能正好好用着。
    @ViewBuilder
    private var legacyProviderNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("「\(selected.displayName)」的接口地址 4.0.2 起不在设置界面上：那是给 Ollama、公司网关这类用户的高级动作，改由「导入设置…」配置。你现在这份配置照常工作，型号名仍然在下面的「高级」里改。",
                    "The endpoint for \(selected.displayName) is no longer shown here: that is an advanced setup for Ollama or a company gateway, configured through Import Settings. Your current setup keeps working, and the model name is still editable under Advanced."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Menu(tr("改用 OpenAI / DeepSeek / 阿里云", "Switch to OpenAI / DeepSeek / Alibaba Cloud")) {
                ForEach([LLMProvider.openai, .deepseek, .qwen], id: \.rawValue) { target in
                    Button(target.displayName) { providerBinding.wrappedValue = target }
                }
            }
            .fixedSize()
        }
    }

    // MARK: 段 3 Key（粘贴即验证）

    @ViewBuilder
    private var keySection: some View {
        // 全 App **唯一**的 Key 输入框：粘上即验证，验证通过才写钥匙串（见 KeyEntryView）
        KeyEntryView(provider: selected, model: polishModelBinding.wrappedValue, probe: keyProbe)
        if keyProbe != .llm {
            Text(tr("开着云端识别，所以这把 Key 直接拿识别端点验：先找出你的接入地址（只查型号清单，不花钱），再发 1 秒合成音，连模型有没有在控制台开通一起验到，这一秒的费用可以忽略。",
                    "With cloud recognition on, the key is verified against the recognition endpoint: first your API host is found (a free model-list request), then one second of synthetic tone is sent, which also proves the model is enabled. The cost of that second is negligible."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 这把 Key 用哪条链路验。开了云端识别的阿里云档直接打识别端点——
    /// 「模型有没有在百炼控制台开通」只有真调一次识别才验得到（/models 那一趟验不出来），
    /// 而那恰恰是 4.0.0 最常见的那个 403。其余一律走润色那条链路。
    private var keyProbe: KeyVerifier.Probe {
        (selected == .qwen && engineChoice == .cloudAlibaba) ? .cloudASR(.alibaba) : .llm
    }

    // MARK: 段 4 模型（一个下拉，默认就是这家最好的那个；与引导第三屏共用）

    @ViewBuilder
    private var modelSection: some View {
        ModelPickerField(provider: selected,
                         polishModel: polishModelBinding,
                         commandModel: commandModelBinding,
                         customChosen: $customModelChosen)
    }

    // MARK: 段 6 关于我 / 自定义规则

    @ViewBuilder
    private var personalFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("关于我（可选）：", "About me (optional):"))
            TextEditor(text: $aboutMe)
                .font(.system(size: 12))
                .frame(height: 50)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
            Text(tr("例如：「署名用 Gen」「邮件偏正式、聊天随意」。按住说指令、草拟邮件时会代入这些信息。",
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

    // MARK: 段 7 高级（默认折叠）

    @ViewBuilder
    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                modelFields
                Divider()
                costlySwitches
            }
            .padding(.top, 6)
        } label: {
            Text(tr("高级（分开设型号、联网搜索、优先处理）",
                    "Advanced (split models, web search, priority processing)"))
        }
    }

    // MARK: 高级 · 分开设型号

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
        let shared = tr("上面的「模型」下拉一次改这两个框；在这里可以把它们分开：润色每句话都要跑，求快求省；指令低频，求质量。右侧下拉是内置快选，「刷新」按钮会问端点它当前有哪些型号；也可以手填任意型号名。",
                        "The Model drop-down above writes both of these fields at once; here you can split them: polish runs on every sentence, so it wants speed and low cost, while commands are rare and want quality. The drop-down holds the built-in picks, Refresh asks the endpoint what it serves today, and you can always type any model name.")
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

    // MARK: 高级 · 两个花钱的开关（默认都关）

    @ViewBuilder
    private var costlySwitches: some View {
        Toggle(tr("语音指令允许联网搜索", "Let voice commands search the web"), isOn: $webSearch)
            .disabled(searchStyle == .unsupported)
        Text(webSearchHelp)
            .font(.caption)
            .foregroundColor(.secondary)

        Toggle(tr("优先处理（token 单价 2 倍）", "Priority processing (2x token price)"), isOn: $fastTier)
            .disabled(selected != .openai)
        Text(LLMCatalog.fastTierPriceNote
             + (selected == .openai ? "" : tr("　只有 OpenAI 有这个档位。", " Only OpenAI offers this tier.")))
            .font(.caption)
            .foregroundColor(.secondary)
        // 这一行的用途是揭发"勾了优先处理却被服务商降回普通档"。开关关着的时候它无事可揭：
        // OpenAI 对普通请求照样回传 service_tier: "default"，照旧渲染就成了一条常驻橙字，
        // 说的还是用户自己选的状态——读起来像出了错。所以只在开关开着时出现。
        if fastTier, let tier = lastServiceTier {
            let ranFast = LLMCatalog.servedPriorityTier(tier)
            Text(tr("上一次请求实际跑在：", "Last request actually ran at: ")
                 + LLMCatalog.serviceTierName(tier))
                .font(.caption)
                .foregroundColor(ranFast ? .secondary : .orange)
        }
    }

    /// 最近一轮拿到过 service_tier 的记录。勾了优先处理却写着 default = 被服务商降级了，
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
                + tr("　只作用于按住说出的指令，润色永不联网。阿里云的兼容端点不回传来源链接，所以历史里不会有来源。",
                     " It applies only to held-down commands - polish never goes online. The Alibaba compatible endpoint returns no source links, so history will not show sources.")
        case .openaiResponsesTool, .openrouterPlugin:
            return LLMCatalog.webSearchPriceNote
                + tr("　只作用于按住说出的指令，润色永不联网；模型给的来源会显示在悬浮窗和历史里。",
                     " It applies only to held-down commands - polish never goes online. Sources come back with the answer and show up in the overlay and in History.")
        }
    }

    // MARK: 动作

    /// 单个模型的连通性/速度测试。**不再顺手保存 Key**：Key 只由「服务商」段验证通过后写钥匙串。
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
            // 这两行别写死服务商：v4.0 起润色/指令有五档（OpenAI / DeepSeek / Qwen /
            // 自定义端点 / 本机模型），识别也多了可选的云端引擎。写成 "GPT / DeepSeek"，
            // 选了别的档的人读到的就是错的——而且正下方的隐私说明已经在讲云端上传了
            Text(tr("版本 \(UpdateChecker.currentVersion) · 语音识别 + 语音指令",
                    "Version \(UpdateChecker.currentVersion) · speech recognition + voice commands"))
                .foregroundColor(.secondary)
            Text(tr("默认本地 Qwen3-ASR 语音识别（也可选云端引擎）+ 由你选择的服务商做润色与语音指令\n轻点快捷键语音输入；按住快捷键说指令——改写、回复、草拟、翻译。",
                    "On-device Qwen3-ASR speech recognition by default (cloud engines optional), with polish and voice commands through the provider you choose.\nTap the hotkey to dictate; hold it to speak commands — rewrite, reply, draft, translate."))
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
