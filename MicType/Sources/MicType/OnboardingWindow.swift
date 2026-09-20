import SwiftUI
import AppKit
import AVFoundation
import Combine

// MARK: - 首次启动引导

/// **四屏**：两种手势 → 权限（模型在这里后台开始下） → 怎么用（本地 / 本地 + AI） → 试一下。
///
/// 为什么值得单独做一个窗口而不是塞进设置页：第一次打开的人不知道"轻点/按住"是两回事，
/// 也不知道要先下一个几百 MB 的模型；设置页是给已经会用的人改参数的，不是教人上手的。
///
/// 为什么从六屏砍到四屏（用户 2026-09-19 实测后拍板）：下模型和配 AI 各占一整屏，
/// 可这两件事都不需要用户盯着——模型可以后台下，AI 只是"要不要 + 哪一家 + 一把 Key"。
/// 四条硬要求（都是过去踩过的坑）：
///   • 权限授予后自己变绿、自己往下走，绝不要求重启或"请再按一次"；
///   • 模型下载不阻塞界面，可取消；进度条一直挂在底部，走到哪一屏都看得见；
///   • 结尾必须能就地试一次——引导窗口自己是前台 App，正常插入链路原样可用；
///   • AI 那一段**必须能整屏跳过**：轻点听写不需要 Key，把它做成一道关卡等于骗人。
///
/// **三件必办的事**（用户 2026-09-20 拍板，见 FirstRunEssentials）：快捷键确认过、
/// 两项权限都给了、识别模型下好了——办不完就走不完这份引导。4.0.1 四屏全都能一路
/// 「继续」点到底，于是"走完引导"和"能用"是两回事：用户回到自己的文档里轻点，什么都
/// 没发生，而他不会认为是权限没给，他会认为这个 App 坏了。唯一的出口是那条写明代价的
/// 「先跳过」；中途关窗口不算走完，下次启动接在第一件没办完的事那一屏。AI 仍然可选。
enum OnboardingPage: Int, CaseIterable {
    case welcome
    case permissions
    case howYouUse
    case tryIt
}

/// 页码 + 权限状态：窗口控制器与各页共享的唯一状态源
final class OnboardingModel: ObservableObject {
    @Published var page: OnboardingPage = .welcome
    @Published var micOK = Permissions.microphoneGranted
    @Published var axOK = Permissions.isAccessibilityTrusted
    /// 用户点过那条「先跳过」（跳过后「继续」/「完成」放行，但那一行警告一直留着）。
    /// 权限页和「试一下」那一页共用这一位：两处跳的是同一件事——带着缺口走出引导。
    @Published var skippedEssentials = false
    /// 权限齐了自动往下翻，但**只翻一次**：翻回来再看一眼的人不该被又推走
    @Published var autoAdvanced = false
    /// AI 现在真的跑得起来吗（不是"点过没点过"）。最后一屏的三种收尾读这一个值。
    @Published var aiStatus: LLMCatalog.AIStatus = .off
    /// 「试一下」那一页输入框里的字。放在模型里而不是页面的 @State 里，只为一件事：
    /// 识别结果由窗口控制器**直接**写进来（TranscriptSink），视图外面够不着 @State。
    @Published var tryItText = ""
    /// 最近一次"字落进来了"的时刻，页面据此闪一下「已收到 ✓」。
    /// 没有这道确认，用户分不清"没识别到"和"字落到别处去了"——4.0.1 那次正是后者。
    @Published var tryItReceivedAt: Date?

    /// 追加一段识别结果（只在主线程调）。追加而不是覆盖：这一页本来就该让人多试几次。
    func appendTryItText(_ text: String) {
        if tryItText.isEmpty {
            tryItText = text
        } else if tryItText.hasSuffix("\n") || tryItText.hasSuffix(" ") {
            tryItText += text
        } else {
            tryItText += " " + text
        }
        tryItReceivedAt = Date()
    }

    /// 「配好了而且润色开着」。footer 里那颗「跳过（只用本地）」按钮按它决定露不露面。
    var aiReady: Bool { aiStatus == .ready }

    /// 当前这一档识别引擎能不能开工。**存着**而不是每次读界面时现算：
    /// RecognitionEngineReadiness.current() 对本地档要 stat 一串模型文件、对云端档要读钥匙串，
    /// 而 essentials() 一次 body 就被读两次（「继续」和那条「先跳过」各读一次），
    /// 下载期间进度每跳一格整个引导都重算一遍——Security 框架的调用不许坐在这种路径上
    /// （Settings.swift 里那条规矩）。刷新点只有真会改变它的那几处：打开引导、两个 1 秒轮询、
    /// 改识别档、Key 验证有了结论。
    @Published private(set) var engineReady = RecognitionEngineReadiness.current().isReady

    func refreshEngineReady() {
        let ready = RecognitionEngineReadiness.current().isReady
        if ready != engineReady { engineReady = ready }
    }

    /// 三件必办的事此刻办到哪一步。权限和模型读的都是这里存着的那几位（界面上看到什么，
    /// 判据就是什么）。判断本身全在 FirstRunEssentials 里。
    func essentials() -> FirstRunEssentials {
        FirstRunEssentials(microphone: micOK,
                           accessibility: axOK,
                           modelReady: engineReady)
    }

    /// 重算 aiStatus。凭据的判断一律走 LLMClient.credential（本机模型没有 Key 才是正常状态）；
    /// **润色档位也要看**——选了「只用本地」的人钥匙串里那把 Key 还在，只看凭据的话
    /// 最后一屏会写「AI 润色…就绪了」，而此刻轻点听写一个字都不润色。
    func refreshAIReady() {
        aiStatus = LLMCatalog.aiStatus(hasCredential: LLMClient.isConfigured,
                                       baseURL: Settings.shared.currentBaseURL,
                                       polishModel: Settings.shared.currentPolishModel,
                                       polishEnabled: Settings.shared.polishLevel != .off)
    }

    /// 模型下载：本地识别这一档缺模型就在后台开始下。
    ///
    /// 为什么挂在这里而不是权限页里：用户在第三屏把识别从云端改回本地之后也要能触发，
    /// 而那一页早就不在屏幕上了（4.0.1 里这个函数只在权限页的 onAppear / 按钮上，
    /// 于是改完档的人一路走到最后一屏都不会被告知模型没下）。
    /// 三种情况不下——已经有了、正在下、或者他明确选了云端识别（那一档不需要这 860MB）。
    /// - force: 用户自己点的那颗按钮。自动那一次只在"还没试过"时发生（取消过就不再自动开始）。
    static func startModelDownloadIfNeeded(force: Bool) {
        guard !Settings.shared.recognitionEngine.isCloud else { return }
        let repo = Settings.shared.qwenModelRepo
        let downloader = QwenModelDownloader.shared
        guard !QwenModels.isFullyDownloaded(repo: repo), !downloader.isDownloading else { return }
        guard force || downloader.statusText.isEmpty else { return }
        Log.info("Onboarding starts model download repo=\(repo) force=\(force)")
        QwenEngine.shared.unloadModel()
        downloader.download(repo: repo)
    }
}

/// 引导里那几句"要按状态二选一"的话，抽成纯函数只为一件事：单测钉得住
/// ——英文侧不许出现中文字符或全角标点，而且有 Key / 没 Key 两种收尾不能串台。
enum OnboardingCopy {

    /// 唯一的出口（用户 2026-09-20 拍板）。做成一条链接而不是按钮：它不是「继续」的同级选项，
    /// 而是"我知道会怎样，先这样"——按钮会让人以为这是两条一样正当的路。
    static var skipForNow: String { tr("先跳过", "Skip for now") }

    /// 点过「先跳过」之后露出来的那一行。只说事实，不劝也不吓唬——
    /// 他已经做了决定，这一行是为了让他以后看到"轻点没反应"时知道是怎么回事。
    static var dictationUnavailable: String {
        tr("听写暂不可用", "Dictation will not work yet")
    }

    /// 下载失败或被取消之后那颗按钮。对刚看着进度条掉下来的人，
    /// 「下载模型」像是什么都没发生过，「重试下载」才对得上他看见的事。
    static var retryDownload: String { tr("重试下载", "Retry download") }

    /// 最后一屏「完成」点不动时，下面那一行说的是**为什么**。
    /// 灰着可以，灰着还不说为什么不行——按钮亮着、点下去只在日志里留一行，
    /// 界面上一个字都不解释，是 4.1.0 踩过的坑。
    /// 卡在权限上的那一种（点过「先跳过」的人才可能带着这个缺口走到最后一屏）
    static var permissionsStillMissing: String {
        tr("还差两项系统权限", "Two system permissions are still missing")
    }

    /// 「完成」为什么点不动。nil = 点得动，或者卡的是模型——模型那一件在这一页
    /// 早有自己的一行（带「下载模型」按钮），不必再说第二遍。
    static func finishBlockedReason(_ essentials: FirstRunEssentials) -> String? {
        if !essentials.permissionsGranted { return permissionsStillMissing }
        return nil
    }

    // MARK: 四屏上那些 caption 字号的句子
    //
    // 为什么非收进来不可：它们原来是散在视图里的 Text(tr(...))，一个都没被量过，
    // 而窗口高度写死 470——每加一句话都在往 ScrollView 里塞，谁也看不出这一屏一共说了多少字。
    // 收进来之后由 `paragraphs` 逐条量（见 SettingsCopyBudgetTests）。

    /// 欢迎屏两张手势卡的正文。
    /// 「识别在本机」**不在这里说**：这一屏底下那句 PrivacyCopy.audioStaysLocal 已经把它说全了，
    /// 而且说得比这里准（它写清了"选了云端引擎才会上传"这条边界）。
    static var dictateCardDetail: String {
        tr("说什么，打什么。", "Exactly what you said, typed out.")
    }

    static var commandCardDetail: String {
        tr("改写选中的文字、帮你起草回复、或直接下一条指令；松手执行。",
           "Rewrite the selection, draft a reply, or just give an instruction; release to run.")
    }

    static var twoGesturesNeverGuessed: String {
        tr("两种手势泾渭分明——MicType 从不猜你想要哪一种。",
           "Two gestures, no guessing — MicType never infers which one you meant.")
    }

    /// 权限页两条权限各自的用途
    static var microphonePurpose: String {
        tr("录下你说的话，用于本机识别。", "Records your voice for on-device recognition.")
    }

    static var accessibilityPurpose: String {
        tr("监听快捷键，并把文字粘贴到光标处。", "Listens for the hotkey and pastes text at your cursor.")
    }

    static var micCheckHint: String {
        tr("说一句话，看电平条动起来——顺手也能在这里换麦克风。",
           "Say something and watch the meter move — you can switch microphones here too.")
    }

    /// 模型已经在本机躺好了。
    /// **只说"就绪"，不说"识别过程不联网"**：这一页可以从第三屏点「上一步」回来，
    /// 而第三屏正摆着「识别也用云端」那个开关——开着它的时候，"不联网"是一句假话。
    /// 默认档那条承诺由第一屏的 PrivacyCopy.audioStaysLocal 负责，而且它写清了边界。
    static var modelReadyHere: String {
        tr("识别模型已就绪 ✓", "Speech model ready ✓")
    }

    static var modelNotDownloadedHere: String {
        tr("识别模型还没下载。", "The speech model is not downloaded yet.")
    }

    static var permissionsStuckHint: String {
        tr("在系统设置里勾上 MicType；已经勾了还是红叉，就把它删掉再加回来。",
           "Tick MicType in System Settings; if it is ticked but still red, remove it from the list and add it back.")
    }

    /// 第三屏：选择器换了一档，但还没验证通过 —— 生效的仍然是原来那一档
    static func providerNotAdoptedYet(current: String) -> String {
        tr("验证通过才会换过去，在此之前仍用 \(current)",
           "MicType switches over only once a key is verified, and keeps using \(current)")
    }

    /// 第三屏：这一档没有内置型号，不填型号名就是"看着配好了、每次调用都是空型号"
    static var modelNameNeeded: String {
        tr("这一档还要在 设置 → 云端 AI → 高级 填一个型号名",
           "This provider needs a model name under Settings → Cloud AI → Advanced")
    }

    /// 第四屏：怎么试一次
    static func tryItInstruction(hotkey: String) -> String {
        tr("光标已经在下面的框里。轻点 \(hotkey)，说一句话，再轻点一次结束。",
           "The cursor is already in the box below. Tap \(hotkey), speak, then tap again to finish.")
    }

    static var modelWarmingUp: String {
        tr("识别模型正在载入，第一句可能要多等几秒。",
           "The speech model is still loading — your first sentence may take a few extra seconds.")
    }

    static var modelMissingForTryIt: String {
        tr("识别模型还没下载好，现在轻点是说不出字的。",
           "The speech model is not downloaded yet, so tapping now will not produce any text.")
    }

    static var modelStillDownloading: String {
        tr("识别模型还在下载，下完就能说话了。",
           "The speech model is still downloading — you can speak as soon as it lands.")
    }

    static var escCancels: String {
        tr("录音中按 Esc 可以取消。", "Press Esc while recording to cancel.")
    }

    static func holdToCommandTip(hotkey: String) -> String {
        tr("按住 \(hotkey) 说指令，松手执行。",
           "Hold \(hotkey) to speak a command, release to run it.")
    }

    static var menuBarTip: String {
        tr("菜单栏的麦克风图标里有历史记录、润色档位和设置。",
           "The menu-bar mic icon holds your history, polish mode and settings.")
    }

    static var vocabularyTip: String {
        tr("人名、术语老是听错？在 设置 → 本地识别 的词汇表里填「错写=正写」，一次搞定。",
           "Names or jargon misheard? Add \"wrong=right\" to the vocabulary in Settings → On-device recognition.")
    }

    static var reopenGuide: String {
        tr("随时可以在 设置 底部的「重看引导」打开这份引导。",
           "You can reopen this guide any time from \"Review the guide\" at the bottom of Settings.")
    }

    /// 权限页开头那两句。第二句**只在模型真的在下**的时候才说：
    /// 选了云端识别的人压根不下这 860MB，取消过 / 失败过的人下面那一行正写着「已取消」，
    /// 而这句话还在说"已经在后台下载"——当面说假话比少说一句糟得多。
    static func permissionsIntro(modelDownloading: Bool) -> String {
        let base = tr("授权后这一页会自己变绿并继续，不用重启 MicType。",
                      "The badges turn green on their own once granted and the guide moves on — no restart needed.")
        guard modelDownloading else { return base }
        return base + tr("识别模型正在后台下载。",
                         " The speech model is downloading in the background.")
    }

    /// 挂在控件下面、走设置页那条 16 字线的几行（SettingsCopy.allCaptions 把它们并进同一张表
    /// 逐条量：第一次打开 MicType 的人最没耐心读字，凭什么反而不受那条线约束）。
    static var captions: [String] {
        [dictationUnavailable, permissionsStillMissing]
    }

    /// 引导里那些**整句的说明**。它们说的是"这一步要做什么、现在是什么状态"，装不进 16 字，
    /// 所以另算一条线（中文 ≤ 60 字、英文 ≤ 200 字符，由 OnboardingCopyTests 量）。
    ///
    /// 这张表存在的理由和设置页那三张一样：窗口高度写死 470，一句一句加下去谁也不觉得自己是
    /// "那一句"，而加到装不下只会变成默默多出一段滚动，没有任何测试会红。
    static var paragraphs: [String] {
        [usageExplanation, aiSkipReassurance,
         dictateCardDetail, commandCardDetail, twoGesturesNeverGuessed,
         permissionsIntro(modelDownloading: false), permissionsIntro(modelDownloading: true),
         microphonePurpose, accessibilityPurpose, micCheckHint,
         modelReadyHere, modelNotDownloadedHere, permissionsStuckHint,
         providerNotAdoptedYet(current: "OpenAI"), modelNameNeeded,
         tryItInstruction(hotkey: "⌥"), modelWarmingUp, modelMissingForTryIt,
         modelStillDownloading, escCancels,
         holdToCommandTip(hotkey: "⌥"), menuBarTip, vocabularyTip, reopenGuide,
         doneAIStatus(status: .ready, hotkey: "⌥"),
         doneAIStatus(status: .commandsOnly, hotkey: "⌥"),
         doneAIStatus(status: .off, hotkey: "⌥")]
    }

    /// 第三屏的标题。这一屏就是设置页那一个决定的首配版本，名字必须和那里一致。
    static var usageHeadline: String {
        tr("使用方式（可选，随时能改）", "How you use MicType (optional — change it any time)")
    }

    /// 两句话说清一把 Key 到底买到什么。写清边界比写得漂亮重要：
    /// 不写清的结果是用户以为不填 Key 就用不了听写（听写从头到尾在本机跑）。
    static var usageExplanation: String {
        tr("轻点听写永远在这台 Mac 上跑，不填 Key 也能一直用。填 Key 只多两件事：自动润色、按住说指令。",
           "Tap-to-dictate always runs on this Mac and works without a key. A key adds exactly two things: automatic polish, and hold-to-command.")
    }

    static var aiSkipReassurance: String {
        tr("跳过也没关系：轻点听写完整可用，以后随时能在 设置 → 云端 AI 里补一把 Key。",
           "Skipping is fine — tap-to-dictate is fully usable, and you can add a key later under Settings → Cloud AI.")
    }


    /// 最后一屏按「AI 到底配到哪一步」给**三种**收尾（LLMCatalog.aiStatus 判，纯函数）。
    /// 用"点过跳过没有"来判会在用户中途去设置页配好 Key 时说反话；
    /// 只看凭据不看润色档位，则会对选了「只用本地」的人宣告"润色就绪"——他手上那把 Key 还在，
    /// 但轻点听写此刻一个字都不润色，他会白等一个不会发生的润色。
    static func doneAIStatus(status: LLMCatalog.AIStatus, hotkey: String) -> String {
        switch status {
        case .ready:
            return tr("AI 润色和语音指令都就绪了：按住 \(hotkey) 说「把这段写正式一点」。",
                      "AI polish and voice commands are ready. Hold \(hotkey) and say \"make this more formal\".")
        case .commandsOnly:
            return tr("你选了只用本地：轻点听写不润色。钥匙串里那把 Key 还在，按住 \(hotkey) 说指令仍然会用它（按次计费）。",
                      "You picked on-device only, so tap-to-dictate does not polish. Your stored key is still there: holding \(hotkey) to command still uses it, and is still billed.")
        case .off:
            return tr("你现在是纯本机听写，完整可用。想要润色和语音指令，去 设置 → 云端 AI 填一把 Key。",
                      "You're on pure on-device dictation. Add a key under Settings → Cloud AI.")
        }
    }
}

/// 窗口是复用的（isReleasedWhenClosed = false），关窗并不会销毁里面那几页，所以
/// "这扇窗这会儿开着没有"是**只有这一层知道**的事实。权限页和「试一下」那一页各挂着
/// 一个 1 秒轮询，靠它停下来——否则窗口开过一次之后，这两个 Timer 一路跑到退出为止，
/// 而且权限页那个还会在一扇关着的窗里把页码推到第三屏。
final class OnboardingWindowController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = OnboardingWindowController()

    /// 这扇窗开着没有。两页的轮询订阅它来开关
    @Published private(set) var isOpen = false

    private var window: NSWindow?
    private var langObserver: AnyCancellable?
    private let model = OnboardingModel()

    /// 打开引导。startAt 用于"模型缺失"这类定点跳转（落到权限那一屏，模型在那里开始下）。
    ///
    /// 两道护栏，护的都是"别把用户自己的状态弄丢"：
    ///   • **窗口已经开着就什么都不重置**，只把它带到前台。这类定点跳转多半正是用户
    ///     在引导里照着提示轻点了一下（模型还没下完），把他从「试一下」弹回第二屏、
    ///     顺手清掉他刚试出来的那几句字和「先跳过」那一位，是在惩罚他照做；
    ///   • **落点不许跳过还没办完的那一屏**：跳过去的那一屏正是他此刻卡住的地方，
    ///     最后那颗「完成」读的是同一把尺子（FirstRunEssentials），跳了也点不动。
    func show(startAt requested: OnboardingPage = .welcome) {
        if let window = window, window.isVisible {
            model.micOK = Permissions.microphoneGranted
            model.axOK = Permissions.isAccessibilityTrusted
            OnboardingModel.startModelDownloadIfNeeded(force: false)
            model.refreshEngineReady()
            model.refreshAIReady()
            Log.info("Onboarding already open page=\(model.page.rawValue) "
                     + "requested=\(requested.rawValue) - keeping page and text")
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        var page = requested
        if let first = FirstRunEssentials.current().firstIncompletePage,
           first.rawValue < requested.rawValue {
            page = first
            Log.info("Onboarding start clamped to page=\(first.rawValue) "
                     + "requested=\(requested.rawValue)")
        }
        model.page = page
        model.micOK = Permissions.microphoneGranted
        model.axOK = Permissions.isAccessibilityTrusted
        // 上一轮点过「先跳过」的标记不能跨次留着：回头重走一遍引导的人，多半正是因为
        // 上次跳过导致热键不工作——第二遍不拦他，他很容易又一路点过去
        model.skippedEssentials = false
        // 上一遍试出来的那几句同样不留：重走一遍引导的人看到的应该是一个空框，
        // 而不是上次（很可能是没配好时）留下的半句话
        model.tryItText = ""
        model.tryItReceivedAt = nil
        // 「权限已经齐了就别再把他推走」和「开始下模型」原先都挂在权限页的 onAppear 上，
        // 而 onAppear 只在页码**变化**时才跑：上次就停在权限页关掉的窗口，再次
        // show(startAt: .permissions) 时页码没变，两件事一件都不做——模型不下，
        // 还会被留在视图里的那个 1 秒 Timer 在 1.8 秒后推到第三屏去。所以挪到这里。
        model.autoAdvanced = page == .permissions && model.micOK && model.axOK
        // 「试一下」也要触发：上次没走完、这次从最后一屏接着走的人（模型没下好正是他被接回来的
        // 原因），不该还得自己去点一次「下载模型」
        if page == .permissions || page == .tryIt {
            OnboardingModel.startModelDownloadIfNeeded(force: false)
        }
        model.refreshEngineReady()
        model.refreshAIReady()
        Log.info("Onboarding show page=\(page.rawValue) aiStatus=\(model.aiStatus) "
                 + model.essentials().logSummary)

        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(model: model))
            let w = NSWindow(contentViewController: hosting)
            // 无边框标题：内容自己撑满，只留一个关闭按钮
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            // 高度 470：第三屏（使用方式 + 服务商 + Key + 模型 + 成本声明）最挤，
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
        // 「试一下」那一页的直接落字通道：窗口一开就挂上，关掉时摘下来。
        // 挂着期间 DictationController 交付前会先问一句 isOnTryItPage，
        // 所以停在别的页、或窗口没显示时行为和从前完全一样。
        registerTranscriptSink()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        isOpen = true
    }

    /// 引导窗开着、并且正停在「试一下」那一页吗——直接落字的唯一判据
    var isOnTryItPage: Bool {
        guard let window = window, window.isVisible else { return false }
        return model.page == .tryIt
    }

    private func registerTranscriptSink() {
        TranscriptSink.register(
            isReady: { [weak self] in self?.isOnTryItPage ?? false },
            accept: { [weak self] text in self?.acceptTranscript(text) ?? false })
    }

    /// 「试一下」那一页的落字入口（DictationController 在交付时调）。
    /// 返回 false = 这一刻接不住，调用方必须退回粘贴那条路，绝不能让文字掉在地上。
    @discardableResult
    func acceptTranscript(_ text: String) -> Bool {
        guard Thread.isMainThread else {
            // 交付一律在主线程。万一不是，宁可退回粘贴，也不在别的线程上动 @Published
            Log.warn("Try-it sink called off the main thread - falling back to paste")
            return false
        }
        guard isOnTryItPage else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        model.appendTryItText(trimmed)
        // 只记字数，绝不记内容：日志里永远看不到用户说了什么
        Log.info("Onboarding try-it received chars=\(trimmed.count)")
        return true
    }

    /// 最后一屏的「完成」。**只有这一下和「先跳过」会把 onboardingCompleted 写真**
    /// （用户 2026-09-20 拍板）。
    func finish() {
        // 权限在这里**现问一次**，不读页面轮询留下的那两位：那个 1 秒的 Timer 只活在权限页里，
        // 翻到后面几屏就停了。点过「先跳过」、然后在「试一下」这一页才把权限补上的人
        // （热键那一下会弹系统麦克风框），用旧的那两位判就是"还缺权限"——
        // 于是 onboardingSkippedEssentials 永远清不掉，以后模型真没了也不会再把他接回引导
        // （AppDelegate 启动那条路读的正是这一位），日志里还写着 mic=false ax=false。
        let essentials = FirstRunEssentials.current()
        model.micOK = essentials.microphone
        model.axOK = essentials.accessibility
        // 按钮在三件事齐活之前是灰的，走到这里只可能是齐了、或者他点过「先跳过」。
        // 仍然守一道：⌘⏎ 那个默认动作不该绕过这条规则
        guard essentials.canFinish || model.skippedEssentials else {
            Log.warn("Onboarding finish blocked \(essentials.logSummary)")
            return
        }
        Settings.shared.onboardingCompleted = true
        // 齐活之后收尾：把"带着缺口走的"那一位清掉，概览上那几个徽章也就该跟着消失
        if essentials.canFinish { Settings.shared.onboardingSkippedEssentials = false }
        Log.info("Onboarding finished \(essentials.logSummary) skipped=\(model.skippedEssentials)")
        window?.close()
    }

    /// 「先跳过」：走出引导的**唯一**出口。
    ///
    /// 写两处状态：引导从此不再每次启动拦他（onboardingCompleted），以及"他是带着没办完的事走的"
    /// （onboardingSkippedEssentials）——后者不催他，只让设置概览上那几个徽章继续挂着。
    /// 不替他补任何东西，也不再劝一次：他已经在那一行字下面做了决定。
    func skipEssentials() {
        model.skippedEssentials = true
        Settings.shared.onboardingSkippedEssentials = true
        Settings.shared.onboardingCompleted = true
        Log.warn("Onboarding essentials skipped at page=\(model.page.rawValue) "
                 + model.essentials().logSummary)
    }

    /// 中途点红叉**不算走完**（用户 2026-09-20 拍板）：关掉窗口的人多半正卡在某一步上，
    /// 下次启动会把他接回没走完的那一屏。4.0.1 这里顺手把 onboardingCompleted 写真，
    /// 于是"关掉引导"成了一条悄悄绕过权限和模型的路，而他自己并不知道绕过了什么。
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        // 窗口没了就别再截留文字：摘干净，之后的听写照常粘到光标处
        TranscriptSink.unregister()
        // 里面那几页不会跟着消失，得由这里告诉它们停手
        isOpen = false
        Log.info("Onboarding closed at page=\(model.page.rawValue) "
                 + "completed=\(Settings.shared.onboardingCompleted)")
    }
}

// MARK: - 主界面

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var downloader = QwenModelDownloader.shared
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case .welcome: WelcomePage()
                case .permissions: PermissionsPage(model: model)
                case .howYouUse: HowYouUsePage(model: model)
                case .tryIt: TryItPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 8)

            // 模型下载条：从权限页开始一直挂在这里。细、不抢戏，但走到哪一屏都看得见——
            // 下载在后台跑，看不见进度的等待才是最难熬的那种
            if downloader.isDownloading {
                downloadBar
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 470)
        // 第三屏把使用方式改回「只用本地」= 识别从云端换回本机，这时才轮到那 860MB。
        // 权限页早就翻过去了，没有这一处的话，模型缺不缺要等到他真的轻点一次才发现
        .onChange(of: recognitionEngine) { _, _ in
            OnboardingModel.startModelDownloadIfNeeded(force: false)
            model.refreshEngineReady()
        }
    }

    private var downloadBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(downloader.statusText.isEmpty
                     ? tr("正在后台下载识别模型…", "Downloading the speech model in the background…")
                     : downloader.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(tr("取消", "Cancel")) { downloader.cancel() }
                    .controlSize(.small)
            }
            ProgressView(value: downloader.progress)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
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
            // 唯一的出口：一条小链接，不是一颗和「继续」平起平坐的按钮。
            // 点下去当场露出「听写暂不可用」那一行，然后才放行（见 skipEssentials）
            if showsSkipLink {
                Button(OnboardingCopy.skipForNow) {
                    OnboardingWindowController.shared.skipEssentials()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            // 「怎么用」那一屏的跳过 = 明确选「只用本地」（不配 AI 是正当选择，不留任何警告）。
            // 已经配通的人不需要这个按钮——那会让他怀疑自己刚配的东西是不是没生效。
            if model.page == .howYouUse && !model.aiReady {
                Button(tr("跳过（只用本地）", "Skip (local only)")) {
                    let writes = AISetup.localOnlyWrites()
                    Settings.shared.polishLevel = writes.polish
                    Settings.shared.recognitionEngine = writes.engine
                    Log.info("Onboarding AI setup skipped: local only")
                    step(1)
                }
            }
            Button(model.page == .tryIt ? tr("完成", "Done")
                                        : tr("继续", "Continue")) {
                if model.page == .tryIt {
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

    /// 三件必办的事此刻办到哪一步。这一层在观察 model（权限每秒轮询）和 downloader
    /// （下完时 isDownloading 翻面），所以该重算的时候界面自己会重算。
    private var essentials: FirstRunEssentials { model.essentials() }

    /// 两处拦人，拦的都是"点下去必然失败"的那一步（用户 2026-09-20 拍板：
    /// 引导办不完这三件事就不能算走完）：
    ///   • 权限没齐——热键和插入文字都不工作，后面的「试一下」必然是空的；
    ///   • 模型没就绪——「完成」点下去只换来一句"模型未下载"。
    /// 两处都由那条「先跳过」放行，别的出口一个都没有。
    private var continueDisabled: Bool {
        guard !model.skippedEssentials else { return false }
        switch model.page {
        case .permissions: return !essentials.permissionsGranted
        // 三件事齐了才放行——和 finish() 那道守卫**同一条判据**。
        // 只看模型的话，按钮会在还差别的事时亮起来，而点下去只在日志里留一行
        // 「Onboarding finish blocked」，用户什么都看不到（4.1.0 踩过）
        case .tryIt: return !essentials.canFinish
        // AI 那一屏永远不拦：轻点听写压根不需要 Key，把它做成关卡等于骗人
        case .welcome, .howYouUse: return false
        }
    }

    /// 出口只在"确实卡住了"的那两屏露面。下载正在跑的时候不摆：进度条就在上面，
    /// 等一等比跳过好；他真不想等，进度条右边就有「取消」，取消完这条链接自然出现。
    private var showsSkipLink: Bool {
        guard !model.skippedEssentials else { return false }
        switch model.page {
        case .permissions: return !essentials.permissionsGranted
        // 与上面那颗按钮同一条判据：凡是「完成」点不动的时候，出口都必须在
        case .tryIt: return !essentials.canFinish && !downloader.isDownloading
        case .welcome, .howYouUse: return false
        }
    }

    private func step(_ delta: Int) {
        let next = max(0, min(OnboardingPage.allCases.count - 1, model.page.rawValue + delta))
        guard let page = OnboardingPage(rawValue: next) else { return }
        // 系统的「减弱动态效果」：设置窗口和悬浮窗都听它的，引导是用户见到的第一扇窗，
        // 更没有理由例外
        withAnimation(SettingsNavigator.reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            model.page = page
        }
    }
}

// MARK: - 1. 欢迎

private struct WelcomePage: View {
    @ObservedObject private var l10n = L10n.shared

    /// 这一屏（以及后面每一句操作说明）念出来的那颗键。只有一颗，不用问设置
    private var key: String { HotkeyChoice.rightOption.displayName }

    var body: some View {
        // ScrollView 是保险绳（与后面三屏同一个理由）：英文界面下两张手势卡各要三行，
        // 窗口高度是写死的 470——挤爆时宁可能滚，也不要把底部那句隐私文案裁掉。
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                Text(tr("用一个键说话，文字直接落在光标处。",
                        "Press one key, speak, and the text lands at your cursor."))
                    .font(.system(size: 16, weight: .medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                // 4.1.0 之前这里摆着一个三选一的热键选择器。拿掉它（用户 2026-09-20 拍板）：
                // 这是他打开 MicType 的第一分钟，还一次都没听写过，凭什么在这时候挑键？
                // 两张手势卡直接把键名写出来就够了——这一屏要教的本来就是"按哪儿"，不是"选哪颗"。
                HStack(alignment: .top, spacing: 14) {
                    GestureCard(symbol: "hand.tap",
                                gesture: tr("轻点 \(key)", "Tap \(key)"),
                                title: tr("本地听写", "Dictate"),
                                detail: OnboardingCopy.dictateCardDetail)
                    GestureCard(symbol: "hand.tap.fill",
                                gesture: tr("按住 \(key) 说", "Hold \(key)"),
                                title: tr("语音指令", "Command"),
                                detail: OnboardingCopy.commandCardDetail)
                }

                Text(OnboardingCopy.twoGesturesNeverGuessed)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                // 引导里**唯一**一句隐私文案（Plan C：那六句只在关于页逐句摆出来，这里只说
                // 第一次打开的人最该知道的那一条——默认不上传）。fixedSize：句子换行时必须
                // 让它把高度撑开，否则窄窗口下后半句会被直接截掉。
                Text(PrivacyCopy.audioStaysLocal)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        }
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

// MARK: - 2. 权限（模型在这一屏后台开始下）

private struct PermissionsPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var downloader = QwenModelDownloader.shared
    @AppStorage(SettingsKeys.qwenModelRepo) private var repo = QwenModels.defaultRepo
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
    /// 1 秒一次的轮询：用户在系统设置里打开开关后，这里自己变绿，不需要重启、也不必再点一次。
    /// **只在窗口开着时轮**：窗口是复用的，关掉之后这一页并不会消失——4.1.0 之前这里是个
    /// autoconnect 的 Timer，于是关窗之后它照轮不误，还能在一扇关着的窗里把页码推到第三屏。
    @State private var poll: AnyCancellable?
    /// 这扇窗开着没有（关窗时要停轮询，再开时接着轮）
    @ObservedObject private var windowState = OnboardingWindowController.shared

    private var modelExists: Bool { QwenModels.isFullyDownloaded(repo: repo) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("两项系统权限", "Two system permissions"))
                    .font(.system(size: 16, weight: .semibold))
                Text(OnboardingCopy.permissionsIntro(modelDownloading: downloader.isDownloading))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PermissionRow(title: tr("麦克风", "Microphone"),
                              detail: OnboardingCopy.microphonePurpose,
                              ok: model.micOK) {
                    Permissions.ensureMicrophone { granted in
                        model.micOK = granted
                        // notDetermined 以外的状态系统不再弹窗，只能引导去设置里手动开
                        if !granted { Permissions.openMicrophoneSettings() }
                    }
                }

                PermissionRow(title: tr("辅助功能", "Accessibility"),
                              detail: OnboardingCopy.accessibilityPurpose,
                              ok: model.axOK) {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }

                // 系统放行只说明"可以录"，不说明"收的是哪只麦、收得到不到声"——用户通常是在真的
                // 要说话的时候才发现选错了麦克风。所以拿到权限就在同一页给出电平条与设备选择
                // （复用设置 → 本地识别 的 MicCheckPanel，v4.0 调研 §4.5：Wispr Flow 也是这个顺序）。
                if model.micOK {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(OnboardingCopy.micCheckHint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        MicCheckPanel()
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }

                if modelExists {
                    Text(OnboardingCopy.modelReadyHere)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !downloader.isDownloading {
                    // 下载没在跑又没下好：多半是刚被取消，或者一开始就失败了。
                    // 不自动重试（几百 MB 的事不背着用户反复开始），给一颗按钮。
                    HStack {
                        Text(downloader.statusText.isEmpty ? OnboardingCopy.modelNotDownloadedHere
                                                            : downloader.statusText)
                            .font(.caption)
                            .foregroundColor(.orange)
                        Spacer()
                        // 刚看着进度条掉下来的人，「下载模型」像是什么都没发生过
                        Button(downloader.phase.didNotFinish
                               ? OnboardingCopy.retryDownload
                               : tr("下载模型", "Download model")) {
                            startDownloadIfNeeded(force: true)
                        }
                        .controlSize(.small)
                    }
                }

                if !(model.micOK && model.axOK) {
                    Text(OnboardingCopy.permissionsStuckHint)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 点过「先跳过」之后露出来的那一行：一句话，没有第二句，也不再劝他回头
                if model.skippedEssentials && !(model.micOK && model.axOK) {
                    Text(OnboardingCopy.dictationUnavailable)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            startDownloadIfNeeded(force: false)
            // 进页时权限就已经齐了（老用户被模型缺失带过来、或者他点「上一步」回来看一眼）：
            // 这一页没什么可等的，别再把他自动推走——自动前进只属于"他刚刚授权成功"那一刻
            if model.micOK, model.axOK { model.autoAdvanced = true }
            startPolling()
        }
        .onDisappear { stopPolling() }
        // 关窗时这一页并不会被销毁（窗口复用），所以停轮询这件事只能由窗口来说
        .onChange(of: windowState.isOpen) { _, open in
            if open { startPolling() } else { stopPolling() }
        }
    }

    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                model.micOK = Permissions.microphoneGranted
                model.axOK = Permissions.isAccessibilityTrusted
                model.refreshEngineReady()
                advanceIfPermissionsJustLanded()
            }
    }

    private func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    /// 模型在这一屏后台开始下：用户接下来要点的是系统设置里的两个开关，那几十秒正好用来下载。
    /// 判据与触发都在 OnboardingModel 里——第三屏改档、以及"被模型缺失带回这一屏"也要触发同一件事。
    private func startDownloadIfNeeded(force: Bool) {
        OnboardingModel.startModelDownloadIfNeeded(force: force)
    }

    /// 权限刚刚齐活：自己往下翻一页。**只翻一次**——从下一屏点「上一步」回来的人
    /// 是专程回来看的，再把他推走就成了跟用户较劲。
    private func advanceIfPermissionsJustLanded() {
        guard model.micOK, model.axOK, !model.autoAdvanced, model.page == .permissions else { return }
        model.autoAdvanced = true
        Log.info("Onboarding permissions granted, advancing")
        // 慢半拍：让那两个徽章先变绿，用户才看得出"是它自己好了"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard model.page == .permissions else { return }
            withAnimation(SettingsNavigator.reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                model.page = .howYouUse
            }
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

// MARK: - 3. 怎么用（可跳过）

/// 一屏走完首配的那**一个**决定：只用本地 / 本地 + AI →（选了 AI）选一家 → 粘 Key → 看一眼模型。
///
/// 为什么整屏可跳过、而且跳过不留任何警告：轻点听写压根不需要 Key，把这一屏做成关卡
/// 就是骗人。反过来，配 AI 的人也不该被丢进设置页里自己找——所以这一屏只摆首配真正要的
/// 那几个控件（自定义规则、联网搜索、优先处理都留在设置页上）。
///
/// **控件与「云端 AI」页逐个共用**（ProviderPickerField / KeyEntryView / ModelPickerField /
/// CloudRecognitionFields）：4.0.1 这里是各抄一份，于是阿里云的「识别也用云端」开关只长在
/// 设置页上——在引导里选了阿里云的人根本不知道有这一档，也没人告诉他它要花钱。
private struct HowYouUsePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.polishLevel) private var polishLevel = PolishLevel.smart.rawValue
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
    /// 阿里云那一档的接入地址由 MicType 自己试出来（4.0.1 拿掉了区域选择器）。
    /// 这一屏只留一个**可选**输入框，给自动没试对的人——首配的人不该在这里做地理选择题。
    @AppStorage(SettingsKeys.qwenAPIHost) private var qwenAPIHost = ""
    /// 「模型」下拉写的是这两个键之一。必须是 @AppStorage 而不是裸 UserDefaults：
    /// 这一屏没有任何东西盯着型号键的话，选完 body 不重算，下拉框还停在旧的那一项，
    /// 用户会以为没点上（设置页那个同名控件走的就是 @AppStorage 投影，立刻重绘）。
    @AppStorage(SettingsKeys.chatModel) private var openaiModel = LLMCatalog.defaultModel(for: .openai)
    @AppStorage(SettingsKeys.openaiCommandModel) private var openaiCommandModel = LLMCatalog.defaultModel(for: .openai)
    @AppStorage(SettingsKeys.deepseekModel) private var deepseekModel = LLMCatalog.defaultModel(for: .deepseek)
    @AppStorage(SettingsKeys.deepseekCommandModel) private var deepseekCommandModel = LLMCatalog.defaultModel(for: .deepseek)
    @AppStorage(SettingsKeys.qwenModel) private var qwenModel = LLMCatalog.defaultModel(for: .qwen)
    @AppStorage(SettingsKeys.qwenCommandModel) private var qwenCommandModel = LLMCatalog.defaultModel(for: .qwen)
    @AppStorage(SettingsKeys.customModel) private var customModel = ""
    @AppStorage(SettingsKeys.customCommandModel) private var customCommandModel = ""
    @AppStorage(SettingsKeys.localModel) private var localModel = ""
    @AppStorage(SettingsKeys.localCommandModel) private var localCommandModel = ""
    @State private var keyStatus: KeyVerifier.Status = .idle
    /// 「模型」下拉停在「自定义…」那一项上（与设置页同一个组件，所以同样要这一位状态）
    @State private var customModelChosen = false
    /// 选择器上**正在看**的那一档，不是生效的那一档。
    ///
    /// 4.0.1 这里直接绑 @AppStorage(llmProvider)，于是点一下选择器就已经把生效服务商换掉了
    /// ——adoptIfUsable 那道"只有真能用才换过去"的护栏里，`Settings.shared.llmProvider != provider`
    /// 永远不成立，护栏是死代码。点着看看的人很多，而原来那一档可能正配着一把好 Key。
    @State private var pendingProvider: LLMProvider = Settings.shared.llmProvider
    /// 钥匙串里有没有**正在看**的这一档的 Key。存着而不是在 body 里读：
    /// SecItemCopyMatching 坐在每帧都跑的路径上是明令禁止的（Settings.swift 那条规矩），
    /// 而这一屏在模型下载期间会被进度条带着一秒重算十几次。
    /// 刷新点：进页、换服务商、Key 验证有了结论（存进去、验失败、清空都会走到那里）。
    @State private var selectedHasStoredKey = KeychainHelper
        .loadAPIKey(account: Settings.shared.llmProvider.keychainAccount) != nil
    /// 这一刻**真正生效**的那一档。Settings.llmProvider 不是 @Published，采纳之后这一屏不会
    /// 自己重算，而选择器旁边那枚「正在使用 ✓」正靠它——所以存一份，在同样那几个事件上刷新。
    @State private var inUseProvider: LLMProvider = Settings.shared.llmProvider

    private var selected: LLMProvider { pendingProvider }
    private var currentPolishLevel: PolishLevel { PolishLevel(rawValue: polishLevel) ?? .smart }
    private var engineChoice: RecognitionEngineChoice { RecognitionEngineChoice.parse(recognitionEngine) }
    private var usageMode: AIUsageMode {
        AISetup.mode(polishLevel: currentPolishLevel, engine: engineChoice)
    }

    /// 这一屏摆出来的三家。「其他 OpenAI 兼容服务」和「本机模型」不在这里：
    /// 填 Base URL、填本地型号名都是高级动作，第一次上手的人不该在这里看到一个 URL 输入框
    /// （设置页的「高级」里有）。唯一例外是他此前就在用某个没列出来的档——那一档必须显示出来，
    /// 否则选择器上没有一项对应他当前的配置，看着像被我们悄悄改掉了。
    /// **正在看的那一档和正在用的那一档都要摆**：两者可以不同（选中一档只是预览，
    /// 验证通过才采纳），只补 selected 的话，正在用本机模型的人点一下 OpenAI，
    /// 本机模型那一段就从选择器上消失，再也点不回去。
    private var offered: [LLMProvider] {
        var list: [LLMProvider] = [.openai, .deepseek, .qwen]
        for p in [selected, inUseProvider] where !list.contains(p) { list.append(p) }
        return list
    }

    var body: some View {
        // ScrollView 是保险绳：验证失败那行可能三行，阿里云还多一个接入地址框——
        // 挤爆时宁可能滚，也不要把底部的控件裁掉。
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(OnboardingCopy.usageHeadline)
                    .font(.system(size: 16, weight: .semibold))
                Text(OnboardingCopy.usageExplanation)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 使用方式 → 服务商 → Key → 模型 →（阿里云的）云端识别开关：与设置页
                // 「云端 AI」**同一个视图**（CloudSetupCore），顺序、标题、说明、那几颗 ⓘ
                // 全都只写一处。这一屏与那一页真正不同的只有语义：看着的那一档要验证通过
                // 才采纳（adoptIfUsable），所以两处各写自己的 Binding setter。
                CloudSetupCore(style: .onboarding,
                               selected: selected,
                               inUse: inUseProvider,
                               engine: engineChoice,
                               usageMode: usageModeBinding,
                               provider: providerBinding,
                               offered: offered,
                               polishModel: polishModelBinding,
                               commandModel: commandModelBinding,
                               customModelChosen: $customModelChosen,
                               keyProbe: keyProbe,
                               keyProbeModel: polishModel(for: selected),
                               showsModel: showsModel,
                               showsDiagnostics: false,
                               showsNotSetUpHint: false,
                               onKeyStatus: { status in
                                   keyStatus = status
                                   adoptIfUsable(selected)
                                   refreshStoredKey()
                                   model.refreshEngineReady()
                                   model.refreshAIReady()
                               },
                               onEngineChange: {
                                   model.refreshEngineReady()
                                   model.refreshAIReady()
                               }) {
                    EmptyView()
                } providerNotices: {
                    providerNotices
                }

                if usageMode == .localOnly {
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
            // 回头再走一遍引导的人：选择器要停在他**正在用**的那一档上
            pendingProvider = Settings.shared.llmProvider
            refreshStoredKey()
            model.refreshAIReady()
        }
        // 接入地址一改，阿里云的地址就变了，能不能连得上也跟着变
        .onChange(of: qwenAPIHost) { _, _ in model.refreshAIReady() }
    }

    /// 服务商选择器下面的边界状态。两条都是"你以为换过去了，其实还没有"——
    /// 一行结论，动作就在下面那个 Key 输入框里，所以不另给按钮。
    @ViewBuilder
    private var providerNotices: some View {
        if selected.requiresAPIKey, Settings.shared.llmProvider != selected,
           !selectedHasStoredKey {
            Caption(OnboardingCopy.providerNotAdoptedYet(current: Settings.shared.llmProvider.segmentName))
        }
        // 本机模型 / 其他兼容服务没有内置型号，型号名只有用户自己知道。不说这一句的话，
        // 这一档看着像配好了，实际每次调用都是"型号名是空的"。
        if LLMCatalog.modelMenu(for: selected).isEmpty,
           polishModelBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Caption(OnboardingCopy.modelNameNeeded, warning: true)
        }
    }

    /// 选择器上换一档：只换"正在看"的那一档，真正生效要等 adoptIfUsable 认可
    /// （设置页那一处是"选了就生效"，所以两处各写 setter，共用的只有选择器本身）。
    private var providerBinding: Binding<LLMProvider> {
        Binding(get: { pendingProvider },
                set: { next in
                    guard next != pendingProvider else { return }
                    pendingProvider = next
                    // 上一档的验证结论对这一档毫无意义（KeyEntryView 自己也会重载钥匙串里的 Key）
                    keyStatus = .idle
                    customModelChosen = false
                    adoptIfUsable(next)
                    refreshStoredKey()
                    model.refreshEngineReady()
                    model.refreshAIReady()
                })
    }

    /// 这把 Key 用哪条链路验——与设置页同一条判据：开着云端识别的阿里云档直接打识别端点，
    /// 「模型有没有在百炼控制台开通」只有真调一次识别才验得到。
    private var keyProbe: KeyVerifier.Probe {
        (selected == .qwen && engineChoice == .cloudAlibaba) ? .cloudASR(.alibaba) : .llm
    }

    /// 和设置页同一套映射（AISetup 那几个纯函数），两处不各写一份 switch
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
                    model.refreshAIReady()
                    Log.info("Onboarding usage mode=\(newMode.rawValue)")
                })
    }

    // MARK: 模型下拉的出现条件

    /// 模型下拉只在"这一档真的通了"之后出现：还没连上就先摆一个花钱的选择，
    /// 用户点下去也不知道点没点上——那正是 3.3 之前"看着像成功"的界面的来路。
    private var showsModel: Bool {
        guard !LLMCatalog.modelMenu(for: selected).isEmpty else { return false }
        if case .connected = keyStatus { return true }
        // 回头再走一遍引导的人：钥匙串里本来就有一把验证过的 Key，不该逼他重粘一次
        return selected.requiresAPIKey && selectedHasStoredKey
    }


    /// 这一档的两个型号字段（与设置页同一种写法：@AppStorage 投影出来的 Binding，
    /// 写下去界面立刻重绘）
    private var polishModelBinding: Binding<String> {
        switch selected {
        case .openai: return $openaiModel
        case .deepseek: return $deepseekModel
        case .qwen: return $qwenModel
        case .custom: return $customModel
        case .local: return $localModel
        }
    }
    private var commandModelBinding: Binding<String> {
        switch selected {
        case .openai: return $openaiCommandModel
        case .deepseek: return $deepseekCommandModel
        case .qwen: return $qwenCommandModel
        case .custom: return $customCommandModel
        case .local: return $localCommandModel
        }
    }

    // MARK: 状态读写

    /// 重读一次"钥匙串里有没有正在看的这一档的 Key"。只在事件上调，绝不在 body 里调。
    private func refreshStoredKey() {
        selectedHasStoredKey = KeychainHelper.loadAPIKey(account: selected.keychainAccount) != nil
        inUseProvider = Settings.shared.llmProvider
    }

    /// 这一档存着的润色型号（可能是空的：其他兼容服务 / 本机模型出厂没有型号名）
    private func storedPolishModel(for provider: LLMProvider) -> String {
        UserDefaults.standard.string(forKey: LLMCatalog.modelKeys(for: provider).polish)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 拿来探活的型号：这一档存着的润色型号，没存过就用目录里的默认值
    private func polishModel(for provider: LLMProvider) -> String {
        let stored = storedPolishModel(for: provider)
        return stored.isEmpty ? LLMCatalog.polishDefault(for: provider) : stored
    }

    /// 只有"这一档真的能用"才把它写成生效的服务商。
    /// 为什么不是点一下就写：点着看看的人很多，而原来那一档可能正配着一把好 Key——
    /// 把生效服务商换成一个没 Key 的，表现是他下次按住说话直接失败，还找不到原因。
    private func adoptIfUsable(_ provider: LLMProvider) {
        let hasKey = KeychainHelper.loadAPIKey(account: provider.keychainAccount) != nil
        // 判据是纯函数（AISetup.adoptsProvider），设置页那一处走的是同一条：
        // 本机模型那一档没有 Key 可验，但型号名是空的照样跑不起来（发出去就是 400），
        // 同样不能拿它换掉一个正在好好用着的服务商。
        guard AISetup.adoptsProvider(current: Settings.shared.llmProvider, next: provider,
                                     requiresKey: provider.requiresAPIKey, hasKey: hasKey,
                                     polishModel: polishModel(for: provider)) else { return }
        Settings.shared.llmProvider = provider
        inUseProvider = provider
        Log.info("Onboarding adopted provider=\(provider.rawValue)")
        // 换走之后音频不能还在往阿里云传，而 AI 页上那个开关这时已经不渲染了。
        // 判据与设置页那处换服务商同源（AISetup.engineAfterProviderChange），两处不各写一份
        if let engine = AISetup.engineAfterProviderChange(current: engineChoice, next: provider) {
            recognitionEngine = engine.rawValue
            Log.info("Onboarding cloud recognition off: provider=\(provider.rawValue)")
        }
    }
}

// MARK: - 4. 试一下 + 收尾

private struct TryItPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var downloader = QwenModelDownloader.shared
    @AppStorage(SettingsKeys.qwenModelRepo) private var repo = QwenModels.defaultRepo
    @AppStorage(SettingsKeys.recognitionEngine) private var recognitionEngine = RecognitionEngineChoice.local.rawValue
    @FocusState private var editorFocused: Bool
    /// 「已收到 ✓」那一下的开关（2.5 秒后自己熄）
    @State private var flashReceived = false
    /// 本机模型加载好了没有。QwenEngine 不是 ObservableObject，所以靠这个 1 秒的轮询刷新。
    /// 同权限页：只在窗口开着时轮，关掉之后这一页还在视图树里，autoconnect 会一路轮到退出
    @State private var modelReady = false
    @State private var readinessPoll: AnyCancellable?
    /// 这扇窗开着没有（关窗时要停轮询，再开时接着轮）
    @ObservedObject private var windowState = OnboardingWindowController.shared

    /// 这一屏让他"轻点试一次"，那就得先说清这一次能不能成。
    /// 4.0.1 只在"正在下"时提醒，于是在第二屏取消过下载、或者在第三屏把识别从云端
    /// 改回本机的人，这里什么都读不到——轻点下去才被悬浮窗告知模型没下，然后被弹回第二屏。
    private var localModelMissing: Bool {
        !RecognitionEngineChoice.parse(recognitionEngine).isCloud
            && !downloader.isDownloading
            && !QwenModels.isFullyDownloaded(repo: repo)
    }

    /// 模型下好了、但还没加载完（首次启动、刚换过模型、刚「释放模型内存」）：
    /// 这时候轻点是能用的，只是第一句要多等几秒。说一声，别让他以为卡死了。
    private var localModelWarmingUp: Bool {
        !RecognitionEngineChoice.parse(recognitionEngine).isCloud
            && !localModelMissing && !downloader.isDownloading && !modelReady
    }

    /// 这一页每一句话里念出来的那颗键（只有一颗，见 Settings.hotkey）
    private var key: String { HotkeyChoice.rightOption.plainName }

    /// 权限那两位在这一页也要续着刷。它们原本只由权限页里那个 1 秒的 Timer 更新，
    /// 而那个 Timer 随着页面一起被拆掉了：点过「先跳过」走到这一页、然后才补上权限的人
    /// （轻点会弹系统麦克风框，或者他自己去系统设置里勾了），「完成」和它下面那一行
    /// 读到的都还是一份过期的状态。
    private func refreshPermissions() {
        let mic = Permissions.microphoneGranted
        let ax = Permissions.isAccessibilityTrusted
        if mic != model.micOK { model.micOK = mic }
        if ax != model.axOK { model.axOK = ax }
    }

    private func startReadinessPolling() {
        guard readinessPoll == nil else { return }
        readinessPoll = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                let ready = QwenEngine.shared.isModelReady
                if ready != modelReady { modelReady = ready }
                refreshPermissions()
                // 模型正是在这一页下完的：「完成」那颗按钮读的就是它
                model.refreshEngineReady()
            }
    }

    private func stopReadinessPolling() {
        readinessPoll?.cancel()
        readinessPoll = nil
    }

    var body: some View {
        // 这一页把「试一次」和原来的收尾页合在一起，内容不短：套上滚动才不会有一句是看不见的
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(tr("试一下", "Try it"))
                        .font(.system(size: 16, weight: .semibold))
                    // 字落进框里的那一下给一句看得见的确认：框里多了一段字，
                    // 但用户的眼睛多半还在悬浮窗上，不点一下他不知道到底成没成
                    if flashReceived {
                        Text(tr("已收到 ✓", "Received ✓"))
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    Spacer()
                }
                Text(OnboardingCopy.tryItInstruction(hotkey: key))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $model.tryItText)
                    .font(.system(size: 13))
                    .focused($editorFocused)
                    .frame(height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.35)))

                // 模型在加载中：能试，只是第一句慢。和"没下载"分开说——
                // 两句话的意思完全不同（一个要等几秒，一个得先下 860MB）
                if localModelWarmingUp {
                    Text(OnboardingCopy.modelWarmingUp)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if localModelMissing {
                    HStack(alignment: .firstTextBaseline) {
                        Text(downloader.statusText.isEmpty ? OnboardingCopy.modelMissingForTryIt
                                                            : downloader.statusText)
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        // 取消过或失败过就写「重试下载」：这一屏的「完成」正等着它下好
                        Button(downloader.phase.didNotFinish
                               ? OnboardingCopy.retryDownload
                               : tr("下载模型", "Download model")) {
                            OnboardingModel.startModelDownloadIfNeeded(force: true)
                        }
                        .controlSize(.small)
                    }
                }

                // 点过「先跳过」：说清他带着什么走。这一行和权限页那一行是同一句——
                // 缺的是权限还是模型，对用户来说结果完全一样：轻点没反应
                if model.skippedEssentials && !model.essentials().modelReady {
                    Text(OnboardingCopy.dictationUnavailable)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                // 「完成」点不动的时候，这一行说为什么。模型那一件上面已经有自己的一行
                // （还带一颗「下载模型」），所以这里只管另外两件
                if !model.skippedEssentials,
                   let reason = OnboardingCopy.finishBlockedReason(model.essentials()) {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text(downloader.isDownloading ? OnboardingCopy.modelStillDownloading
                                                   : OnboardingCopy.escCancels)
                        .font(.caption)
                        .foregroundColor(downloader.isDownloading ? .orange : .secondary)
                    Spacer()
                    if !model.tryItText.isEmpty {
                        Button(tr("清空", "Clear")) {
                            model.tryItText = ""
                            editorFocused = true
                        }
                        .controlSize(.small)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    TipRow(symbol: "hand.tap.fill",
                           text: OnboardingCopy.holdToCommandTip(hotkey: key))
                    // 有 Key / 没 Key 两种收尾：这一行是用户离开引导时对"我现在有什么"的最后印象，
                    // 说反了他要么白等一个不会发生的润色，要么以为自己还没配好
                    TipRow(symbol: model.aiReady ? "wand.and.stars" : "cpu",
                           text: OnboardingCopy.doneAIStatus(status: model.aiStatus, hotkey: key))
                    TipRow(symbol: "menubar.arrow.up.rectangle",
                           text: OnboardingCopy.menuBarTip)
                    TipRow(symbol: "text.book.closed",
                           text: OnboardingCopy.vocabularyTip)
                }

                // 页名跟着设置窗口走：4.0.2 的 Plan C 把「通用」改成了「输入」，
                // 指路的句子指向一个不存在的页名比不指路更糟
                Text(OnboardingCopy.reopenGuide)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 上一屏可能刚粘好 Key，也可能用户中途去设置页配了——进这一屏现算一次
        .onAppear {
            model.refreshAIReady()
            modelReady = QwenEngine.shared.isModelReady
            refreshPermissions()
            model.refreshEngineReady()
            // 稍等一拍再抢焦点：窗口刚翻页时 TextEditor 还没进响应链，立刻 focus 会落空。
            // 焦点只影响用户自己打字——识别结果不靠它，走的是直接落字（TranscriptSink）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { editorFocused = true }
            startReadinessPolling()
        }
        .onDisappear { stopReadinessPolling() }
        // 关窗时这一页并不会被销毁（窗口复用），所以停轮询这件事只能由窗口来说
        .onChange(of: windowState.isOpen) { _, open in
            if open { startReadinessPolling() } else { stopReadinessPolling() }
        }
        // 字落进来了：闪 2.5 秒的「已收到 ✓」
        .onChange(of: model.tryItReceivedAt) { _, received in
            guard received != nil else { return }
            withAnimation(SettingsNavigator.reduceMotion ? nil : .easeIn(duration: 0.12)) {
                flashReceived = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                // 这 2.5 秒里又落了一段：让新的那一次自己计时，别被这一下提前熄掉
                guard model.tryItReceivedAt == received else { return }
                withAnimation(SettingsNavigator.reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    flashReceived = false
                }
            }
        }
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
