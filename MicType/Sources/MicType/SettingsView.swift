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
            Section {
                Picker(tr("界面语言 / Language:", "Language / 界面语言:"), selection: $l10n.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
            }

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
                // 硬上限此前在界面上无处可查，用户第一次知道它存在就是被自动收尾那一刻。
                // 分段也写在这里：长段口述的识别是一段一段出来的，用户会在悬浮窗上看见「第 2/5 段」
                Text(tr("单次录音最长 10 分钟。录到 2 分钟起悬浮窗显示「8:30 / 10:00」的计时，最后 30 秒提示即将收尾；到点自动收尾＝照常识别并把全部内容插入。长段口述按 60 秒左右分段转写，每转完一段就显示一段。",
                        "A single take runs up to 10 minutes. From 2 minutes the overlay shows a running \"8:30 / 10:00\" clock and warns 30 seconds before the end; at the limit MicType wraps the take up, transcribes it and inserts everything. Long takes are transcribed in roughly 60-second parts, each shown as soon as it is ready."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

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

            Section(tr("备份", "Backup")) {
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

            // 两项权限各自一行、各自一个按钮（与引导页同构）：以前并排两个徽章却只有一个
            // 「打开系统设置」按钮，而且固定跳辅助功能面板——麦克风是红叉的用户点几次都到同一页。
            Section(tr("权限", "Permissions")) {
                HStack {
                    PermissionBadge(name: tr("麦克风", "Microphone"), ok: micOK)
                    Spacer()
                    Button(tr("打开麦克风设置", "Open Microphone Settings")) {
                        Permissions.openMicrophoneSettings()
                    }
                }
                .onReceive(permTimer) { _ in
                    micOK = Permissions.microphoneGranted
                    axOK = Permissions.isAccessibilityTrusted
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
        .formStyle(.grouped)
        .padding(.top, 4)
        // 已生成的状态文字是快照，切换语言后清掉，避免残留旧语言
        .onChange(of: l10n.language) { _, _ in
            backupStatus = ""
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

// MARK: - 麦克风自检

/// 麦克风自检此刻在不在跑。为什么要有这么一个全局：自检和主录音是各自独立的 AVAudioEngine，
/// 抢的是同一只麦克风。自检这边一直知道要避让主流程（AppDelegate.isDictationBusy），
/// 反过来主流程却完全看不见自检——用户在设置里点完「测试麦克风」顺手按了热键，两路 tap
/// 同时开着：电平条量的是他正在听写的那句话，3 秒到点还会给出一句与本次自检无关的结论。
/// 只在主线程读写（自检的起止、主流程的起录都在主线程）。
enum MicTest {

    private(set) static var isRunning = false
    /// 自检登记的收手闭包。主流程起录时用它把自检掐掉——用户正要说的那句话比一次自检重要得多
    private static var stopHandler: (() -> Void)?

    static func began(stop: @escaping () -> Void) {
        isRunning = true
        stopHandler = stop
    }

    static func ended() {
        isRunning = false
        stopHandler = nil
    }

    /// 正在自检就让位给听写。返回是否真的让了位（只给日志用）
    @discardableResult
    static func yieldToDictation() -> Bool {
        guard isRunning, let stop = stopHandler else { return false }
        stop()
        return true
    }
}

/// 麦克风自检（路线图 P12）：借 AudioRecorder 跑一段 3 秒录音，只读电平——
/// 采样收上来立刻丢掉，不送识别、不落盘、不进历史。
/// 为什么值得做：选错麦克风这件事，用户通常是在真的要说话的时候才发现的（说完一段，什么都没出来）。
/// 给一条电平条 + 峰值读数，选完当场就能确认"这只真的在收声"。
private final class MicTestSession: ObservableObject {

    @Published private(set) var isRunning = false
    /// 0~1，画电平条（AudioRecorder 送来的归一化 RMS）
    @Published private(set) var level: Float = 0
    /// 本次自检收到的最大峰值（线性幅度 0~1）
    @Published private(set) var peak: Float = 0
    @Published private(set) var message = ""

    private static let seconds: Double = 3

    private let recorder = AudioRecorder()
    /// 自检代数：连点两次「测试」时，旧的那一次定时收尾不能把新的一次关掉
    private var run = 0

    /// 峰值读数。dBFS 是音频里通用的刻度（0 = 满刻度，越负越小），比 0~1 更好对照
    var peakLabel: String {
        guard peak > 0 else { return "— dBFS" }
        return String(format: "%.0f dBFS", 20 * log10(peak))
    }

    func start() {
        guard !isRunning else { return }
        // 主流程正在录音/出结果时不抢麦克风：用户正说着的话比一次自检重要得多
        guard !AppDelegate.isDictationBusy else {
            message = busyMessage
            return
        }
        message = tr("请用平常的音量说一句话…", "Say something at your normal volume…")
        Permissions.ensureMicrophone { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.message = tr("没有麦克风权限：系统设置 › 隐私与安全性 › 麦克风 里勾上 MicType",
                                  "Microphone permission denied — enable MicType in System Settings › Privacy & Security › Microphone")
                return
            }
            // 上面那次判定是在权限回调之前做的。首次授权的系统弹窗能挂好几秒，这期间用户
            // 完全来得及按热键开始听写，所以真正起录前必须再查一次。
            guard !AppDelegate.isDictationBusy else {
                self.message = self.busyMessage
                return
            }
            self.begin()
        }
    }

    private var busyMessage: String {
        tr("正在录音或处理中，稍后再测", "Busy recording — try again in a moment")
    }

    /// 结论文字是一次性生成的快照，切语言不会自己刷新 → 切换时清掉（3.1.1 的老坑）
    func clearMessage() { message = "" }

    /// 关窗 / 切走标签页时收手，别让一路录音在看不见的地方继续开着
    func cancel() {
        guard isRunning else { return }
        finish(note: "")
    }

    private func begin() {
        // 回调必须在 start() 之前设好：AudioRecorder 装 tap 那一刻就把它们快照给音频线程了
        recorder.onLevel = { [weak self] value in
            // 和 onPeak 一样要查 isRunning：tap 回调在音频线程，async 回主线程时 finish()
            // 可能已经把电平条归零了，在途的那一两块会把它写回非零——测试早结束了，
            // 条子却停在半格上，看着像麦克风还在收音
            DispatchQueue.main.async {
                guard let self = self, self.isRunning else { return }
                self.level = value
            }
        }
        recorder.onPeak = { [weak self] value in
            DispatchQueue.main.async {
                guard let self = self, self.isRunning else { return }
                self.peak = max(self.peak, value)
            }
        }
        recorder.onError = { [weak self] error in
            self?.finish(note: error.message)
        }
        peak = 0
        level = 0
        do {
            try recorder.start()
        } catch {
            message = (error as? MTError)?.message ?? error.localizedDescription
            Log.warn("Mic test start failed: \(message)")
            return
        }
        isRunning = true
        MicTest.began { [weak self] in
            self?.finish(note: tr("已让位给这次听写，稍后再测",
                                  "Stopped — dictation is using the microphone"))
        }
        run += 1
        let token = run
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds) { [weak self] in
            guard let self = self, self.run == token else { return }
            self.finish(note: nil)
        }
    }

    /// note: nil = 正常到点收尾（给结论）；非 nil = 被打断（原样显示，空串表示什么都不说）
    private func finish(note: String?) {
        guard isRunning else { return }
        _ = recorder.stop()
        isRunning = false
        MicTest.ended()
        level = 0
        run += 1     // 让还没到点的那个定时收尾作废
        if let note = note {
            message = note
            return
        }
        Log.info("Mic test done peak=\(String(format: "%.4f", peak)) uid=\(Settings.shared.inputDeviceUID)")
        // 结论直接对齐识别链路的静音闸门（SilenceGate），别让自检说"没问题"而真录音被判静音
        if peak < SilenceGate.silentPeak {
            message = tr("几乎没有收到声音：换一只麦克风，或检查系统设置里的输入音量",
                         "Almost nothing came through — try another microphone, or check the input volume in System Settings")
        } else if peak < SilenceGate.faintPeak {
            message = tr("收到了，但很小：靠近麦克风会明显更准",
                         "Picked you up, but very quietly — moving closer will noticeably help accuracy")
        } else {
            message = tr("麦克风工作正常", "Microphone works")
        }
    }
}

// MARK: - 识别（Qwen3-ASR）

private struct RecognitionTab: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.inputDeviceUID) private var inputDeviceUID = ""
    @AppStorage(SettingsKeys.qwenModelRepo) private var qwenRepo = QwenModels.defaultRepo
    @AppStorage(SettingsKeys.recognitionLanguage) private var recognitionLanguage = RecognitionLanguages.autoCode
    @AppStorage(SettingsKeys.customVocabulary) private var vocabulary = ""
    @AppStorage(SettingsKeys.fillerWords) private var fillerWords = ""
    @ObservedObject private var downloader = QwenModelDownloader.shared
    @ObservedObject private var upgrader = ModelUpgrader.shared
    /// 模型目录到货时下拉框要立刻跟上（首启动时目录还在路上）
    @ObservedObject private var catalogStore = ModelCatalogStore.shared
    @ObservedObject private var metrics = Metrics.shared
    @StateObject private var micTest = MicTestSession()
    @State private var inputDevices: [InputDevice] = []
    /// 插拔 AirPods / 接上声卡时下拉框要立刻跟上（否则得关掉设置窗口再打开才看得见）
    @State private var deviceObserver: InputDevices.DeviceChangeObserver?
    @State private var refreshTick = 0
    @State private var updateMessage = ""
    @State private var checkingUpdate = false

    private var modelExists: Bool {
        _ = refreshTick
        let dir = QwenModels.localDirectory(for: qwenRepo)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }

    /// 「系统默认」当前实际指向谁——写在选项里，用户不用去系统设置里对照
    private var systemDefaultLabel: String {
        let base = tr("系统默认", "System default")
        guard let uid = InputDevices.defaultUID,
              let device = inputDevices.first(where: { $0.uid == uid }) else { return base }
        return base + "（\(device.name)）"
    }

    /// 选了阿语却还在小模型上：出一条推荐行（只推荐，不自动换——1.1 GB 的下载由用户点）
    private var showsArabicModelHint: Bool {
        QwenModels.recommendsLargeModel(languageCode: recognitionLanguage, currentRepo: qwenRepo)
    }

    /// 1.7B 这一档的体量（字节）。目录里没有这一档（被下架）就给 0 → 按钮上不显示体量
    private var largeModelSizeBytes: Int64 {
        catalogStore.catalog.model(repo: QwenModels.largeRepo)?.sizeBytes ?? 0
    }

    /// 1.7B 是否已经下载过（决定推荐行的按钮是「切换并下载」还是「切换到」）
    private var largeModelExists: Bool {
        _ = refreshTick
        let dir = QwenModels.localDirectory(for: QwenModels.largeRepo)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
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
        if FileManager.default.fileExists(
            atPath: QwenModels.localDirectory(for: repo)
                .appendingPathComponent("model.safetensors").path) {
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

    /// 存着的麦克风此刻不在（没插上 / 换了台机器）。**不自动改设置**：插回来还要照旧用，
    /// 只是在列表里如实标出来，并让 Picker 有一个能选中的选项（否则 SwiftUI 显示空白）
    private var savedDeviceMissing: Bool {
        !inputDeviceUID.isEmpty && !inputDevices.contains { $0.uid == inputDeviceUID }
    }

    var body: some View {
        Form {
            Section {
                Picker(tr("麦克风：", "Microphone:"), selection: $inputDeviceUID) {
                    Text(systemDefaultLabel).tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if savedDeviceMissing {
                        Text(tr("已选的麦克风（当前未连接）", "Selected microphone (not connected)"))
                            .tag(inputDeviceUID)
                    }
                }
                HStack(spacing: 10) {
                    Button(micTest.isRunning ? tr("测试中…", "Testing…")
                                             : tr("测试麦克风", "Test microphone")) {
                        micTest.start()
                    }
                    .disabled(micTest.isRunning)
                    ProgressView(value: Double(min(max(micTest.level, 0), 1)))
                        .progressViewStyle(.linear)
                        .frame(width: 150)
                    Text(micTest.peakLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                if !micTest.message.isEmpty {
                    Text(micTest.message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(tr("测试会录 3 秒，只看音量：录到的声音当场丢弃，不识别、不保存。\n选定的麦克风在开始录音时没插上，会自动退回系统默认（这次录音照常进行），设置本身不改动。",
                        "The test records for 3 seconds and only meters the level — the audio is discarded, never transcribed or saved.\nIf the selected microphone is not connected when recording starts, MicType falls back to the system default for that session and leaves your choice untouched."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
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
                if showsArabicModelHint {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "lightbulb")
                                .foregroundColor(.orange)
                            Text(tr("阿拉伯语建议换 1.7B 模型", "Arabic works noticeably better on the 1.7B model"))
                                .fontWeight(.medium)
                        }
                        Text(tr("阿语上 1.7B 比 0.6B 准得多（Fleurs 词错率 25.5% → 17.0%，Common Voice 46.0% → 38.0%）。\n能用的是现代标准阿语和朗读级内容；海湾、埃及等方言**不承诺**能用——那是模型的已知短板，不是设置问题。",
                                "On Arabic the 1.7B model is far more accurate than the 0.6B one (Fleurs WER 25.5% to 17.0%, Common Voice 46.0% to 38.0%).\nModern Standard Arabic and read-aloud speech are usable. Gulf, Egyptian and other dialects are NOT promised - that is a known weakness of the model, not a setting you can fix."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // 体量从模型目录取，不写死：模型换版、量化改了，这句话不该还是旧数字
                        Button(largeModelExists
                                ? tr("切换到 1.7B 模型", "Switch to the 1.7B model")
                                : tr("切换并下载 1.7B 模型（\(QwenModels.sizeNote(bytes: largeModelSizeBytes))）",
                                     "Switch and download the 1.7B model (\(QwenModels.sizeNote(bytes: largeModelSizeBytes)))")) {
                            updateMessage = ""
                            QwenEngine.shared.unloadModel()
                            qwenRepo = QwenModels.largeRepo
                            if !largeModelExists {
                                downloader.download(repo: QwenModels.largeRepo, force: false)
                            }
                            refreshTick += 1
                        }
                        .disabled(downloader.isDownloading)
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
        .onAppear {
            let devices = $inputDevices
            devices.wrappedValue = InputDevices.list()
            deviceObserver = InputDevices.DeviceChangeObserver {
                devices.wrappedValue = InputDevices.list()
            }
        }
        .onDisappear {
            deviceObserver = nil      // 释放即注销 CoreAudio 监听
            micTest.cancel()
        }
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
            micTest.clearMessage()
            if !downloader.isDownloading { downloader.statusText = "" }
            if !upgrader.isBusy { upgrader.clearStatus() }
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
            VStack(spacing: 4) {
                Text(tr("隐私：录音和语音识别完全在本机进行。",
                        "Privacy: recording and speech recognition stay entirely on this Mac."))
                Text(tr("只有开启 AI 润色时，识别出的文本会发送给你配置的大模型接口。",
                        "Only with AI polish enabled is the transcribed text sent to the model endpoint you configure."))
                Text(tr("听写历史以明文保存在本机 Application Support 目录，最多 200 条：可在 设置 → 通用 关掉记录，或在菜单栏「最近记录」里清空、逐条删除。",
                        "Transcripts are kept in plain text on this Mac (up to 200): turn recording off in Settings → General, or clear and delete them from Recent Transcripts in the menu bar."))
                Text(tr("「复制诊断信息」只包含版本、系统、芯片、设置摘要、最近的耗时数字和今天的日志尾巴（日志里的路径和账户名已脱敏）——不含 API Key，也不含任何听写内容，可以放心贴给别人。",
                        "“Copy diagnostics” includes only the version, system, chip, a settings summary, recent timings and today's log tail (paths and your account name in it are redacted) — never your API key and never any transcribed text, so it is safe to paste to someone."))
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
