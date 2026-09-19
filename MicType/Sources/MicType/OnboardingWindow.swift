import SwiftUI
import AppKit
import AVFoundation
import Combine

// MARK: - 首次启动引导

/// 六屏引导：两种手势 → 逐项权限 → 下模型 → 现场试一次 → 配 AI（可跳过）→ 完成。
///
/// 为什么值得单独做一个窗口而不是塞进设置页：第一次打开的人不知道"轻点/按住"是两回事，
/// 也不知道要先下 860MB 模型；设置页是给已经会用的人改参数的，不是教人上手的。
/// 四条硬要求（都是过去踩过的坑）：
///   • 权限授予后自己变绿继续，绝不要求重启或"请再按一次"；
///   • 模型下载不阻塞界面，可取消、可跳过；
///   • 结尾必须能就地试一次——引导窗口自己是前台 App，正常插入链路原样可用；
///   • AI 那一屏**必须能整屏跳过**：轻点听写不需要 Key，把它做成一道关卡等于骗人。
///     v3.3 之前这一步压根不存在，只在「试一次」角落写一句"AI 需要 Key"再把人丢进
///     14 个控件的设置页——那一句已经在这一版删掉，换成这一屏。
enum OnboardingPage: Int, CaseIterable {
    case welcome
    case permissions
    case model
    case tryIt
    case aiSetup
    case done
}

/// 第 5 屏（aiSetup）的选择：某一档服务商，或者"明确跳过"。
/// 为什么把跳过做成选择器里的一档而不是只留底部一个按钮：不配 AI 是一个**正当的最终选择**
/// （纯本机听写完整可用），摆在同一排才不像"你还没做完"。
enum AISetupChoice: Hashable {
    case provider(LLMProvider)
    case skip
}

/// 页码 + 权限状态：窗口控制器与各页共享的唯一状态源
final class OnboardingModel: ObservableObject {
    @Published var page: OnboardingPage = .welcome
    @Published var micOK = Permissions.microphoneGranted
    @Published var axOK = Permissions.isAccessibilityTrusted
    /// 权限页被用户明确跳过（跳过后 Continue 放行，但警告一直留着）
    @Published var skippedPermissions = false
    /// 第 5 屏选的那一档。放在共享 model 里是为了"返回可继续"：翻回上一页再回来不该丢选择。
    @Published var aiChoice: AISetupChoice = .provider(Settings.shared.llmProvider)
    /// AI 现在真的跑得起来吗（不是"点过没点过"）。第 6 屏的两种收尾、底部那个「暂时跳过」
    /// 是否出现，都读这一个值。
    @Published var aiReady = false

    /// 重算 aiReady。凭据的判断一律走 LLMClient.credential（本机模型没有 Key 才是正常状态）。
    func refreshAIReady() {
        aiReady = LLMCatalog.aiReady(hasCredential: LLMClient.isConfigured,
                                     baseURL: Settings.shared.currentBaseURL,
                                     polishModel: Settings.shared.currentPolishModel)
    }
}

/// 引导里那几句"要按状态二选一"的话，抽成纯函数只为一件事：单测钉得住
/// ——英文侧不许出现中文字符或全角标点，而且有 Key / 没 Key 两种收尾不能串台。
enum OnboardingCopy {
    static var aiHeadline: String {
        tr("让 AI 帮你收拾这段话（可选）", "Let AI clean up what you said (optional)")
    }

    /// 两句话说清一把 Key 到底买到什么。写清边界比写得漂亮重要：
    /// 不写清的结果是用户以为不填 Key 就用不了听写（听写从头到尾在本机跑）。
    static var aiExplanation: String {
        tr("轻点听写永远在这台 Mac 上跑，不填 Key 也能一直用。填 Key 只多两件事：自动润色、按住说指令。",
           "Tap-to-dictate always runs on this Mac and works without a key. A key adds exactly two things: automatic polish, and hold-to-command.")
    }

    static var aiSkipReassurance: String {
        tr("跳过也没关系：轻点听写完整可用，以后随时能在 设置 → AI 里补一把 Key。",
           "Skipping is fine - tap-to-dictate is fully usable, and you can add a key later under Settings → AI.")
    }

    /// 质量档下面那一句：这不是一次性的、不可回头的决定
    static var aiQualityHint: String {
        tr("以后在 设置 → AI 里随时能改。", "Change it any time in Settings → AI.")
    }

    /// 第 6 屏按「AI 到底配好了没有」给两种收尾。ready 由 LLMCatalog.aiReady 判——
    /// 用"点过跳过没有"来判会在用户中途去设置页配好 Key 时说反话。
    static func doneAIStatus(ready: Bool, hotkey: String) -> String {
        if ready {
            return tr("AI 润色和语音指令都就绪了：按住 \(hotkey) 说「把这段写正式一点」。",
                      "AI polish and voice commands are ready. Hold \(hotkey) and say \"make this more formal\".")
        }
        return tr("你现在是纯本机听写，完整可用。想要润色和语音指令，去 设置 → AI 填一把 Key。",
                  "You're on pure on-device dictation. Add a key under Settings → AI.")
    }
}

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var langObserver: AnyCancellable?
    private let model = OnboardingModel()

    /// 打开引导。startAt 用于"模型缺失"这类定点跳转（直接落到下载页）。
    func show(startAt page: OnboardingPage = .welcome) {
        model.page = page
        model.micOK = Permissions.microphoneGranted
        model.axOK = Permissions.isAccessibilityTrusted
        // AI 那一屏按"现在设置里是什么"复位：重新打开引导的人可能早就在设置页配好了
        model.aiChoice = .provider(Settings.shared.llmProvider)
        model.refreshAIReady()
        Log.info("Onboarding show page=\(page.rawValue) aiReady=\(model.aiReady)")

        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(model: model))
            let w = NSWindow(contentViewController: hosting)
            // 无边框标题：内容自己撑满，只留一个关闭按钮
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            // 高度从 420 抬到 470：AI 那一屏（服务商 + Key + 状态 + 质量 + 成本声明）最挤，
            // 其余各页靠 Spacer 自然留白，看不出变化
            w.setContentSize(NSSize(width: 560, height: 470))
            w.center()
            w.delegate = self
            window = w
            langObserver = L10n.shared.$language.sink { [weak self] lang in
                self?.window?.title = lang == .zh ? "欢迎使用 MicType" : "Welcome to MicType"
            }
        }
        window?.title = tr("欢迎使用 MicType", "Welcome to MicType")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func finish() {
        Settings.shared.onboardingCompleted = true
        Log.info("Onboarding finished")
        window?.close()
    }

    /// 中途点红叉也算"看过了"：不纠缠用户，设置页里随时能重新打开。
    func windowWillClose(_ notification: Notification) {
        if !Settings.shared.onboardingCompleted {
            Settings.shared.onboardingCompleted = true
            Log.info("Onboarding dismissed at page=\(model.page.rawValue)")
        }
    }
}

// MARK: - 主界面

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case .welcome: WelcomePage()
                case .permissions: PermissionsPage(model: model)
                case .model: ModelPage(model: model)
                case .tryIt: TryItPage()
                case .aiSetup: AISetupPage(model: model)
                case .done: DonePage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 8)

            Divider()
            footer
        }
        .frame(width: 560, height: 470)
    }

    // MARK: 底部导航

    private var footer: some View {
        HStack(spacing: 10) {
            if model.page != .welcome {
                Button(tr("上一步", "Back")) { step(-1) }
            }
            Spacer()
            dots
            Spacer()
            if model.page == .permissions && !bothGranted && !model.skippedPermissions {
                Button(tr("暂时跳过", "Skip for now")) {
                    model.skippedPermissions = true
                    Log.warn("Onboarding permissions skipped mic=\(model.micOK) ax=\(model.axOK)")
                }
            }
            // AI 屏的跳过是直接翻页（不配 AI 是正当选择，不留任何警告）。
            // 已经配通的人不需要这个按钮——那会让他怀疑自己刚配的东西是不是没生效。
            if model.page == .aiSetup && !model.aiReady {
                Button(tr("暂时跳过", "Skip for now")) {
                    Log.info("Onboarding AI setup skipped")
                    step(1)
                }
            }
            Button(model.page == .done ? tr("开始使用", "Start Using MicType")
                                       : tr("继续", "Continue")) {
                if model.page == .done {
                    OnboardingWindowController.shared.finish()
                } else {
                    step(1)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(continueDisabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingPage.allCases, id: \.rawValue) { page in
                Circle()
                    .fill(page.rawValue == model.page.rawValue
                          ? Color.accentColor
                          : Color.secondary.opacity(page.rawValue < model.page.rawValue ? 0.5 : 0.22))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var bothGranted: Bool { model.micOK && model.axOK }

    /// 只有权限页会拦人：两项权限没齐，后面的「试一次」必然失败，先拦住比让他白试一次好。
    private var continueDisabled: Bool {
        model.page == .permissions && !bothGranted && !model.skippedPermissions
    }

    private func step(_ delta: Int) {
        let next = max(0, min(OnboardingPage.allCases.count - 1, model.page.rawValue + delta))
        guard let page = OnboardingPage(rawValue: next) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { model.page = page }
    }
}

// MARK: - 1. 欢迎

private struct WelcomePage: View {
    @ObservedObject private var l10n = L10n.shared

    private var key: String { Settings.shared.hotkey.shortSymbol }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)
            Text(tr("用一个键说话，文字直接落在光标处。",
                    "Press one key, speak, and the text lands at your cursor."))
                .font(.system(size: 16, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 14) {
                GestureCard(symbol: "hand.tap",
                            gesture: tr("轻点 \(key)", "Tap \(key)"),
                            title: tr("本地听写", "Dictate"),
                            detail: tr("说什么，打什么。识别全在本机完成。",
                                       "Exactly what you said, typed out, recognized on this Mac."))
                GestureCard(symbol: "hand.tap.fill",
                            gesture: tr("按住 \(key) 说", "Hold \(key)"),
                            title: tr("语音指令", "Command"),
                            detail: tr("改写选中的文字、帮你起草回复、或直接下一条指令；松手执行。",
                                       "Rewrite the selection, draft a reply, or just give an instruction; release to run."))
            }

            Text(tr("两种手势泾渭分明——MicType 从不猜你想要哪一种。",
                    "Two gestures, no guessing — MicType never infers which one you meant."))
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // 数据流向先说清楚，再谈功能：句子取自 PrivacyCopy，和关于页、结束页逐字相同
            VStack(alignment: .leading, spacing: 3) {
                ForEach(PrivacyCopy.dataFlowLines, id: \.self) { line in
                    Text(line)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GestureCard: View {
    let symbol: String
    let gesture: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundColor(.accentColor)
                Text(gesture)
                    .font(.system(size: 13, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}

// MARK: - 2. 权限

private struct PermissionsPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    /// 1 秒一次的轮询：用户在系统设置里打开开关后，这里自己变绿，不需要重启、也不必再点一次
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("两项系统权限", "Two system permissions"))
                    .font(.system(size: 16, weight: .semibold))
                Text(tr("授权后这一页会自己变绿，不用重启 MicType。",
                        "The badges turn green on their own once granted — no restart needed."))
                    .font(.caption)
                    .foregroundColor(.secondary)

                PermissionRow(title: tr("麦克风", "Microphone"),
                              detail: tr("录下你说的话，用于本机识别。", "Records your voice for on-device recognition."),
                              ok: model.micOK) {
                    Permissions.ensureMicrophone { granted in
                        model.micOK = granted
                        // notDetermined 以外的状态系统不再弹窗，只能引导去设置里手动开
                        if !granted { Permissions.openMicrophoneSettings() }
                    }
                }

                PermissionRow(title: tr("辅助功能", "Accessibility"),
                              detail: tr("监听快捷键，并把文字粘贴到光标处。", "Listens for the hotkey and pastes text at your cursor."),
                              ok: model.axOK) {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }

                // 系统放行只说明"可以录"，不说明"收的是哪只麦、收得到不到声"——用户通常是在真的
                // 要说话的时候才发现选错了麦克风。所以拿到权限就在同一页给出电平条与设备选择
                // （复用设置 → 识别 的 MicCheckPanel，v4.0 调研 §4.5：Wispr Flow 也是这个顺序）。
                if model.micOK {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("说一句话，看电平条动起来——顺手也能在这里换麦克风。",
                                "Say something and watch the meter move — you can switch microphones here too."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        MicCheckPanel(showsFootnote: false)
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }

                if !(model.micOK && model.axOK) {
                    Text(tr("在系统设置的列表里勾选 MicType 即可。若列表里已勾选但这里仍是红叉，是旧授权失效了：选中 MicType 点「−」删掉，再点「+」加回来。",
                            "Tick MicType in the System Settings list. If it is already ticked but still shows red, the old grant is stale: select MicType, press “−”, then add it back with “+”."))
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.skippedPermissions && !(model.micOK && model.axOK) {
                    Text(tr("已跳过：在权限补齐之前，快捷键和文字插入都不会工作。",
                            "Skipped: the hotkey and text insertion will not work until both are granted."))
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(timer) { _ in
            model.micOK = Permissions.microphoneGranted
            model.axOK = Permissions.isAccessibilityTrusted
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let ok: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 17))
                .foregroundColor(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if ok {
                Text(tr("已授权", "Granted"))
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Button(tr("打开设置", "Open Settings"), action: action)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}

// MARK: - 3. 识别模型

private struct ModelPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var downloader = QwenModelDownloader.shared
    /// 模型清单来自 model-catalog.json（远端 → 缓存 → 内置）。目录在启动后才到货，
    /// 观察它才能让首启动这一页的下拉框跟着刷新，而不是永远显示内置那两档。
    @ObservedObject private var catalogStore = ModelCatalogStore.shared
    @AppStorage(SettingsKeys.qwenModelRepo) private var repo = QwenModels.defaultRepo
    @State private var refreshTick = 0
    /// 只有"这一页点下载"完成后才自动翻页；进页时模型就在的老用户留在原地，否则上一步就回不来了
    @State private var downloadStarted = false

    private var modelExists: Bool {
        _ = refreshTick
        return QwenModels.isFullyDownloaded(repo: repo)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("下载识别模型", "Download the speech model"))
                .font(.system(size: 16, weight: .semibold))
            Text(tr("Qwen3-ASR 在你的 Mac 上本地运行：约 30 种语言、22 种中文方言，识别过程不联网。只需下载一次。",
                    "Qwen3-ASR runs locally on your Mac: ~30 languages and 22 Chinese dialects, with no network during recognition. It downloads once."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(tr("模型：", "Model:"), selection: $repo) {
                ForEach(QwenModels.all, id: \.repo) { option in
                    Text("\(option.title) · \(option.sizeNote)").tag(option.repo)
                }
            }
            .disabled(downloader.isDownloading)

            HStack(spacing: 10) {
                Image(systemName: modelExists ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 17))
                    .foregroundColor(modelExists ? .green : .orange)
                Text(modelExists ? tr("模型已就绪 ✓", "Model ready ✓")
                                 : tr("模型未下载", "Model not downloaded"))
                    .font(.system(size: 13))
                Spacer()
                if downloader.isDownloading {
                    Button(tr("取消", "Cancel")) { downloader.cancel() }
                } else if !modelExists {
                    Button(tr("下载模型", "Download Model")) {
                        downloadStarted = true
                        QwenEngine.shared.unloadModel()
                        downloader.download(repo: repo)
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)

            if downloader.isDownloading {
                ProgressView(value: downloader.progress)
            }
            if !downloader.statusText.isEmpty {
                Text(downloader.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Text(tr("下载在后台进行，可以随时取消；中断后重新下载会接着没下完的文件继续。",
                    "The download runs in the background and can be cancelled; resuming picks up where it stopped."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 不想下这几百 MB 的人有第二条路，但**只给一行链接**：云端要填 Key、要花钱、
            // 音频要上传，把它做成引导里的一整屏等于在推销它。默认档仍然是本地模型。
            Button(tr("不想下载？可以改用云端识别（音频会上传，按秒计费）",
                      "Prefer not to download? Use cloud recognition instead (audio is uploaded, billed per second)")) {
                SettingsWindowController.shared.show(tab: .recognition)
            }
            .buttonStyle(.link)
            .font(.caption)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(downloader.$isDownloading) { downloading in
            refreshTick += 1
            guard !downloading, downloadStarted else { return }
            // 下完了才继续：顺手预热模型，下一页"现场试一次"就不用干等冷启动
            guard QwenModels.isFullyDownloaded(repo: repo) else { return }
            downloadStarted = false
            QwenEngine.shared.preload()
            Log.info("Onboarding model download complete, advancing")
            withAnimation(.easeInOut(duration: 0.15)) { model.page = .tryIt }
        }
        .onChange(of: repo) { _, _ in
            QwenEngine.shared.unloadModel()
            refreshTick += 1
        }
    }
}

// MARK: - 4. 现场试一次

private struct TryItPage: View {
    @ObservedObject private var l10n = L10n.shared
    @State private var text = ""
    @FocusState private var editorFocused: Bool

    private var key: String { Settings.shared.hotkey.shortSymbol }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("现在试一次", "Try it right now"))
                .font(.system(size: 16, weight: .semibold))
            Text(tr("光标已经在下面的框里。轻点 \(key)，说一句话，再轻点一次结束——文字会直接落进来。",
                    "The cursor is already in the box below. Tap \(key), say something, then tap again to finish — the text lands right here."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 13))
                .focused($editorFocused)
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.35)))

            HStack {
                Text(tr("录音中按 Esc 可以取消。", "Press Esc while recording to cancel."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if !text.isEmpty {
                    Button(tr("清空", "Clear")) {
                        text = ""
                        editorFocused = true
                    }
                    .controlSize(.small)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // 稍等一拍再抢焦点：窗口刚翻页时 TextEditor 还没进响应链，立刻 focus 会落空
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { editorFocused = true }
        }
    }
}

// MARK: - 5. AI 设置（可跳过）

/// 一屏走完：选服务商 → 去控制台拿 Key → 粘贴即验证 → 选质量。
///
/// 为什么整屏可跳过、而且跳过不留任何警告：轻点听写压根不需要 Key，把这一屏做成关卡
/// 就是骗人。反过来，配 AI 的人也不该被丢进设置页里 14 个控件中自己找——所以这一屏
/// 只摆首配真正要的那几个控件（型号名、Base URL、温度都留在设置页的「高级」里）。
private struct AISetupPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    /// Qwen 那一档的地址由「区域 + WorkspaceId」推出来，没有它连不上——所以这两项得在这一屏
    @AppStorage(SettingsKeys.qwenRegion) private var qwenRegion = LLMCatalog.QwenRegion.international.rawValue
    @AppStorage(SettingsKeys.qwenWorkspaceID) private var qwenWorkspace = ""
    @State private var keyStatus: KeyVerifier.Status = .idle
    /// 质量档（nil = 用户自己挑过型号，如实显示「自选」，绝不把他钉回我们的某一档）
    @State private var tier: LLMCatalog.QualityTier?

    /// 这一屏摆出来的几档：三家云服务商 + 本机模型，外加「跳过」。
    /// 故意**不摆「自定义端点」**——填 Base URL 是高级动作，第一次上手的人不该在这里
    /// 看到一个 URL 输入框（设置页的「高级」里有）。唯一例外是他此前就在用某个没列出来的档：
    /// 那一档必须显示出来，否则选择器上没有一项对应他当前的配置，看着像被我们悄悄改掉了。
    private var offered: [LLMProvider] {
        var list: [LLMProvider] = [.openai, .deepseek, .qwen, .local]
        let stored = Settings.shared.llmProvider
        if !list.contains(stored) { list.append(stored) }
        return list
    }

    private var chosen: LLMProvider? {
        guard case .provider(let provider) = model.aiChoice else { return nil }
        return provider
    }

    private var region: LLMCatalog.QwenRegion {
        LLMCatalog.QwenRegion(rawValue: qwenRegion) ?? .international
    }

    var body: some View {
        // ScrollView 是保险绳：验证失败那行可能三行，Qwen 还多两个控件——
        // 挤爆时宁可能滚，也不要把底部的成本声明裁掉。
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(OnboardingCopy.aiHeadline)
                    .font(.system(size: 16, weight: .semibold))
                Text(OnboardingCopy.aiExplanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker(tr("服务商：", "Service:"), selection: $model.aiChoice) {
                    ForEach(offered, id: \.rawValue) { provider in
                        Text(provider.segmentName).tag(AISetupChoice.provider(provider))
                    }
                    Text(tr("跳过", "Skip")).tag(AISetupChoice.skip)
                }
                .pickerStyle(.segmented)

                if let provider = chosen {
                    if provider == .qwen { qwenFields }
                    KeyEntryView(provider: provider,
                                 model: polishModel(for: provider),
                                 showsStorageNotes: false) { status in
                        keyStatus = status
                        adoptIfUsable(provider)
                        model.refreshAIReady()
                        refreshTier()
                    }
                    if showsQuality { qualityRow(for: provider) }
                    // 本机模型 / 自定义端点没有内置型号，型号名只有用户自己知道。
                    // 不说这一句的话，这一档看着像配好了，实际每次调用都是"型号名是空的"。
                    if LLMCatalog.qualitySummary(provider: provider) == nil,
                       storedPolishModel(for: provider).isEmpty {
                        Text(tr("这一档还要填一个模型名才跑得起来（填好之前 MicType 仍用原来的服务商）：去 设置 → AI → 高级 填上你本机已经下载好的那个，例如 llama3.1:8b。",
                                "This provider needs a model name before it works, and MicType keeps using the previous provider until then: name the one you have downloaded, such as llama3.1:8b, under Settings → AI → Advanced."))
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if provider.requiresAPIKey {
                        Text(LLMCatalog.keyStorageNote + " " + LLMCatalog.billingNote)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(OnboardingCopy.aiSkipReassurance)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            model.refreshAIReady()
            refreshTier()
        }
        .onChange(of: model.aiChoice) { _, choice in
            // 上一档的验证结论对这一档毫无意义（KeyEntryView 自己也会重载钥匙串里的 Key）
            keyStatus = .idle
            if case .provider(let provider) = choice { adoptIfUsable(provider) }
            model.refreshAIReady()
            refreshTier()
        }
        // 区域/WorkspaceId 一改，Qwen 的地址就变了，能不能连得上也跟着变
        .onChange(of: qwenRegion) { _, _ in model.refreshAIReady() }
        .onChange(of: qwenWorkspace) { _, _ in model.refreshAIReady() }
    }

    // MARK: Qwen 的区域与 WorkspaceId

    @ViewBuilder
    private var qwenFields: some View {
        Picker(tr("接入区域：", "Region:"), selection: $qwenRegion) {
            ForEach(LLMCatalog.QwenRegion.allCases, id: \.rawValue) { option in
                Text(option.displayName).tag(option.rawValue)
            }
        }
        if region.requiresWorkspaceID {
            TextField("WorkspaceId", text: $qwenWorkspace)
                .textFieldStyle(.roundedBorder)
        }
        if LLMCatalog.qwenBaseURL(region: region, workspaceID: qwenWorkspace).isEmpty {
            Text(tr("这个区域的地址里带 WorkspaceId，填上才能用（在模型服务控制台的工作空间详情里）。",
                    "This region puts your workspace ID in the URL - fill it in (you will find it in the Model Studio console)."))
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 质量二选一（验证通过后才出现）

    /// 质量选择器只在"这一档真的通了"之后出现：还没连上就先摆一个花钱的档位，
    /// 用户点下去也不知道点没点上——那正是 3.3 之前"看着像成功"的界面的来路。
    private var showsQuality: Bool {
        guard let provider = chosen, LLMCatalog.qualitySummary(provider: provider) != nil else { return false }
        if case .connected = keyStatus { return true }
        // 回头再走一遍引导的人：钥匙串里本来就有一把验证过的 Key，不该逼他重粘一次
        return provider.requiresAPIKey
            && KeychainHelper.loadAPIKey(account: provider.keychainAccount) != nil
    }

    @ViewBuilder
    private func qualityRow(for provider: LLMProvider) -> some View {
        Picker(tr("质量：", "Quality:"), selection: $tier) {
            ForEach(LLMCatalog.QualityTier.allCases, id: \.rawValue) { option in
                Text(option.displayName).tag(Optional(option))
            }
            if tier == nil {
                Text(tr("自选", "Custom")).tag(LLMCatalog.QualityTier?.none)
            }
        }
        .pickerStyle(.segmented)
        // 选中即写回两个型号字段（哪两个键由 LLMCatalog.modelKeys 说，界面不认识型号名）。
        // 「自选」那一档是 nil，点不到也不该写——guard 就是这个用处。
        .onChange(of: tier) { _, newValue in
            guard let newValue else { return }
            for (key, value) in LLMCatalog.qualityWrites(provider: provider, tier: newValue) {
                UserDefaults.standard.set(value, forKey: key)
            }
            Log.info("Onboarding quality tier=\(newValue.rawValue) provider=\(provider.rawValue)")
        }
        Text(OnboardingCopy.aiQualityHint)
            .font(.caption)
            .foregroundColor(.secondary)
    }

    // MARK: 状态读写

    /// 这一档存着的润色型号（可能是空的：自定义端点 / 本机模型出厂没有型号名）
    private func storedPolishModel(for provider: LLMProvider) -> String {
        UserDefaults.standard.string(forKey: LLMCatalog.modelKeys(for: provider).polish)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 拿来探活的型号：这一档存着的润色型号，没存过就用目录里的默认值
    private func polishModel(for provider: LLMProvider) -> String {
        let stored = storedPolishModel(for: provider)
        return stored.isEmpty ? LLMCatalog.polishDefault(for: provider) : stored
    }

    private func refreshTier() {
        guard let provider = chosen else { return }
        let keys = LLMCatalog.modelKeys(for: provider)
        let d = UserDefaults.standard
        tier = LLMCatalog.tier(provider: provider,
                              polish: d.string(forKey: keys.polish) ?? LLMCatalog.polishDefault(for: provider),
                              command: d.string(forKey: keys.command) ?? LLMCatalog.commandDefault(for: provider))
    }

    /// 只有"这一档真的能用"才把它写成生效的服务商。
    /// 为什么不是点一下就写：点着看看的人很多，而原来那一档可能正配着一把好 Key——
    /// 把生效服务商换成一个没 Key 的，表现是他下次按住说话直接失败，还找不到原因。
    private func adoptIfUsable(_ provider: LLMProvider) {
        let hasKey = KeychainHelper.loadAPIKey(account: provider.keychainAccount) != nil
        guard !provider.requiresAPIKey || hasKey else { return }
        // 本机模型那一档没有 Key 可验，但型号名是空的照样跑不起来（发出去就是 400）：
        // 同样不能拿它换掉一个正在好好用着的服务商。polishModel 对三家云服务商会落到
        // 目录里的默认型号，只有自定义端点 / 本机模型才可能真的是空的。
        guard !polishModel(for: provider).isEmpty else { return }
        guard Settings.shared.llmProvider != provider else { return }
        Settings.shared.llmProvider = provider
        Log.info("Onboarding adopted provider=\(provider.rawValue)")
    }
}

// MARK: - 6. 完成

private struct DonePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared

    private var key: String { Settings.shared.hotkey.shortSymbol }

    var body: some View {
        // 这一页现在还带着 Key 与费用四句：窗口是固定 470 高（见 show() 里的 setContentSize，
        // 为最挤的 AI 那一屏从 420 抬上来的），套上滚动才不会有一句是看不见的
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)
                Text(tr("可以开始用了", "You're ready"))
                    .font(.system(size: 16, weight: .semibold))

                VStack(alignment: .leading, spacing: 8) {
                    TipRow(symbol: "hand.tap",
                           text: tr("轻点 \(key) 听写，再轻点一次结束。",
                                    "Tap \(key) to dictate, tap again to finish."))
                    TipRow(symbol: "hand.tap.fill",
                           text: tr("按住 \(key) 说指令，松手执行。",
                                    "Hold \(key) to speak a command, release to run it."))
                    // 有 Key / 没 Key 两种收尾：这一行是用户离开引导时对"我现在有什么"的最后印象，
                    // 说反了他要么白等一个不会发生的润色，要么以为自己还没配好
                    TipRow(symbol: model.aiReady ? "wand.and.stars" : "cpu",
                           text: OnboardingCopy.doneAIStatus(ready: model.aiReady, hotkey: key))
                    TipRow(symbol: "menubar.arrow.up.rectangle",
                           text: tr("菜单栏的麦克风图标里有历史记录、润色档位和设置。",
                                    "The menu-bar mic icon holds your history, polish mode and settings."))
                    TipRow(symbol: "text.book.closed",
                           text: tr("人名、术语老是听错？在 设置 → 识别 的词汇表里填「错写=正写」，一次搞定。",
                                    "Names or jargon misheard? Add \"wrong=right\" to the vocabulary in Settings → Recognition."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Key 与费用：四句和关于页逐字相同（PrivacyCopy），免得用户在两处读到两种说法
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(PrivacyCopy.keyAndCostLines, id: \.self) { line in
                        Text(line)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(tr("随时可以在 设置 → 通用 里重新打开这份引导。",
                        "You can reopen this guide any time from Settings → General."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        // 上一屏可能刚粘好 Key，也可能用户中途去设置页配了——进这一屏现算一次
        .onAppear { model.refreshAIReady() }
    }
}

private struct TipRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
