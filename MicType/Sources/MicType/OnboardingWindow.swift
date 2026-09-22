import SwiftUI
import AppKit
import AVFoundation
import Combine
// 最后一屏那颗「登录时自动启动」（与设置页「输入」那一段同一套写法）
import ServiceManagement

// MARK: - 首次启动引导

/// **五屏**：这是什么 + 按哪个键 → 权限（模型在这里后台开始下） → 怎么用（本地 / 本地 + AI）
/// → 试一下 → 它在哪。
///
/// 为什么值得单独做一个窗口而不是塞进设置页：第一次打开的人不知道"轻点/按住"是两回事，
/// 也不知道要先下一个几百 MB 的模型；设置页是给已经会用的人改参数的，不是教人上手的。
///
/// 为什么从六屏砍到四屏（用户 2026-09-19 实测后拍板）：下模型和配 AI 各占一整屏，
/// 可这两件事都不需要用户盯着——模型可以后台下，AI 只是"要不要 + 哪一家 + 一把 Key"。
///
/// **4.3.4 加回第五屏「它在哪」**（用户 2026-09-22 拍板，推翻 09-19「引导最多四屏」那条）：
/// 新用户的原话是"走完引导之后不知道它去哪了、也不知道接下来干什么"——当时是个纯菜单栏应用，
/// 关掉最后一扇窗之后屏幕上什么都不剩，而前四屏没有任何一屏回答过"它在哪"。
/// 这一屏把那枚图标画出来指给他看，并且把「登录时自动启动」摆在当面（默认开）——
/// 否则第二天开机 App 根本没在跑，"它在哪"会原样再来一遍。
/// （4.3.5 起 MicType 常驻 Dock，这一屏因此同时指 Dock 和菜单栏两处。）
///
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
    /// 「它在哪」：菜单栏图标 + 开机自启 + 那颗「完成」（4.3.4 起）
    case done
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
    /// 最后一屏那颗「登录时自动启动」这一轮已经替他打开过了。
    /// 存在模型里而不是页面的 @State 里：那一页翻出去再翻回来会重建，
    /// 而"默认开"只该发生一次——用户在这一屏关掉之后翻回去再进来，不许又被打开
    @Published var launchAtLoginArmed = false

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

    /// 重算 aiStatus。5.0.0 起只有两档（配好了 / 没配），因为润色不再有开关。
    func refreshAIReady() {
        aiStatus = LLMCatalog.aiStatus(hasCredential: LLMClient.isConfigured,
                                       baseURL: Settings.shared.currentBaseURL,
                                       polishModel: Settings.shared.currentPolishModel)
    }

    // startModelDownloadIfNeeded 5.0.0 删掉：没有本机模型可下了。
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
    /// 「识别在本机」**不在这里说**：这一屏底下那句 PrivacyCopy.audioGoesToProvider 已经把它说全了，
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
        tr("录下你说的话，边说边传给你选的服务商识别。",
           "Records your voice and streams it to the provider you picked.")
    }

    static var accessibilityPurpose: String {
        tr("监听快捷键，并把文字粘贴到光标处。", "Listens for the hotkey and pastes text at your cursor.")
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

    /// 第四屏：怎么试一次
    static func tryItInstruction(hotkey: String) -> String {
        tr("光标已经在下面的框里。轻点 \(hotkey)，说一句话，再轻点一次结束。",
           "The cursor is already in the box below. Tap \(hotkey), speak, then tap again to finish.")
    }

    /// 「试一下」那一页：Key 还没配好，现在轻点是说不出字的（5.0.0 起识别也要那把 Key）
    static var keyMissingForTryIt: String {
        tr("还没填 API Key，现在轻点是说不出字的——回上一屏粘一把。",
           "No API key yet, so tapping now will not produce any text - go back a screen and paste one.")
    }

    static var escCancels: String {
        tr("录音中按 Esc 可以取消。", "Press Esc while recording to cancel.")
    }

    static func holdToCommandTip(hotkey: String) -> String {
        tr("按住 \(hotkey) 说指令，松手执行。",
           "Hold \(hotkey) to speak a command, release to run it.")
    }

    // menuBarTip（「菜单栏的麦克风图标里有历史记录、润色档位和设置」）4.3.4 删掉了：
    // 最后一屏用同一句话配着那枚图标的真图说了一遍（menuBarHolds），
    // 而它原来挂在 ④ ——连着两屏说同一件事，还各说各的措辞。

    /// 5.0.0 起「写作偏好」是自己的一页，从设置底部那排小字或菜单栏直接点开，
    /// 指路也跟着改——指着一个已经不存在的「输入」页，用户会以为功能没了
    static var vocabularyTip: String {
        tr("人名、术语老是听错？在菜单栏「写作偏好…」的词汇表里填「错写=正写」，一次搞定。",
           "Names or jargon misheard? Add \"wrong=right\" to the vocabulary under Writing Preferences in the menu bar.")
    }

    static var reopenGuide: String {
        tr("随时可以在 设置 底部的「重看引导」打开这份引导。",
           "You can reopen this guide any time from \"Review the guide\" at the bottom of Settings.")
    }

    /// 第一屏键盘示意图下面那行：**说的是哪一颗键**，不是它叫什么。
    /// 很多键帽上印的是 alt 而不是 option（非 Apple 键盘、以及一部分地区的 Apple 键盘），
    /// 只写"右 Option"的人对不上自己手底下那颗键（2026-09-22 的反馈原话：「到底按哪个键」）
    static var keyboardHint: String {
        tr("空格键右侧第二颗；有的键帽印着 alt",
           "Second key to the right of the space bar; some keycaps say alt")
    }

    /// 第三屏 Key 输入框上面那一行。只在引导里出现——设置页那一处的用户早就贴过一次了。
    /// 4.3.4 之前 ⌘V 在自家窗口里是坏的（没有主菜单，见 AppMenu），用户只能右键粘贴，
    /// 于是"粘不进去"成了首配最常卡住的一步
    static var pasteKeyHere: String {
        tr("从服务商控制台复制 Key，⌘V 粘贴到这里",
           "Copy the key from your provider's console and paste it here with ⌘V")
    }

    // MARK: 第五屏「它在哪」

    /// 4.3.5 起 MicType 是普通应用：Dock 图标和菜单栏图标两个都一直在
    ///（用户 2026-09-22 拍板，和 Wispr Flow 一样），所以这一屏得把两个都指出来——
    /// 只说菜单栏的话，Dock 里那枚图标点下去会是个惊喜
    static var menuBarHome: String {
        tr("它在 Dock 和菜单栏里", "It lives in the Dock and the menu bar")
    }

    static var menuBarHolds: String {
        tr("点 Dock 图标打开设置；菜单栏图标里有最近记录、写作偏好和设置。",
           "Click the Dock icon to open Settings; the menu bar icon holds recent transcripts, writing preferences and settings.")
    }

    /// 这一屏真正要讲的那句：平时**不用**去找那枚图标
    static func rarelyNeeded(hotkey: String) -> String {
        tr("平时不用找它：在任何输入框里轻点 \(hotkey) 就能听写，按住 \(hotkey) 说指令。",
           "You will rarely need it: tap \(hotkey) in any text field to dictate, hold \(hotkey) to give a command.")
    }

    /// 开机自启这一行的说明。默认开（用户 2026-09-22 拍板）：不开的话第二天开机
    /// MicType 根本没在跑，而他只会觉得"昨天装的那个东西没了"
    static var launchAtLoginWhy: String {
        tr("开着机就在，不必每次自己打开。",
           "MicType is there when you log in, so you never have to launch it.")
    }

    /// 权限页开头那一句。5.0.0 起没有"模型正在后台下载"那半句了（没有本机模型）。
    static var permissionsIntro: String {
        tr("授权后这一页会自己变绿并继续，不用重启 MicType。",
           "The badges turn green on their own once granted and the guide moves on — no restart needed.")
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
        [usageExplanation,
         dictateCardDetail, commandCardDetail, twoGesturesNeverGuessed, keyboardHint,
         permissionsIntro, microphonePurpose, accessibilityPurpose, permissionsStuckHint,
         providerNotAdoptedYet(current: "OpenAI"), pasteKeyHere,
         tryItInstruction(hotkey: "⌥"), keyMissingForTryIt, escCancels,
         holdToCommandTip(hotkey: "⌥"), vocabularyTip, reopenGuide,
         menuBarHome, menuBarHolds, rarelyNeeded(hotkey: "⌥"), launchAtLoginWhy,
         doneAIStatus(status: .ready, hotkey: "⌥"),
         doneAIStatus(status: .off, hotkey: "⌥")]
    }

    /// 第三屏的标题。这一屏就是设置页那一页的首配版本，名字必须和那里一致。
    /// 5.0.0 起它**不再写「可选」**：识别、润色、指令三件事全在云端，没有 Key 一件都做不了。
    static var usageHeadline: String {
        tr("选你的 AI", "Choose your AI")
    }

    /// 一句话说清这把 Key 买到什么、以及为什么非填不可。
    /// 写清边界比写得漂亮重要：4.x 的这句话写的是"不填 Key 也能一直用"——
    /// 5.0.0 之后那是一句假话（本机识别没有了），照抄过来就是骗人。
    static var usageExplanation: String {
        tr("听写、润色、语音指令都用这一把 Key：录音边说边传给你选的服务商，费用直接结给他们。",
           "One key covers dictation, polish and voice commands: your voice streams to the provider you pick, and you pay them directly.")
    }


    /// 最后一屏按「AI 配好了没有」给**两种**收尾（LLMCatalog.aiStatus 判，纯函数）。
    /// 5.0.0 起没有第三种了：润色不再有开关，"配好了但润色关着"这一档不存在。
    static func doneAIStatus(status: LLMCatalog.AIStatus, hotkey: String) -> String {
        switch status {
        case .ready:
            return tr("都就绪了：轻点 \(hotkey) 听写，按住 \(hotkey) 说「把这段写正式一点」。",
                      "Everything is ready. Tap \(hotkey) to dictate, or hold \(hotkey) and say \"make this more formal\".")
        case .off:
            return tr("还差一把 API Key：听写、润色、语音指令都要用它。去「设置」补上。",
                      "One thing is missing: an API key. Dictation, polish and voice commands all need it - add one in Settings.")
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
            model.refreshEngineReady()
            model.refreshAIReady()
            Log.info("Onboarding already open page=\(model.page.rawValue) "
                     + "requested=\(requested.rawValue) - keeping page and text")
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 上一轮在最后一屏点开过的登录项开关，这一轮要重新来一次（见 DonePage.onAppear）
        model.launchAtLoginArmed = false
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
        // 「权限已经齐了就别再把他推走」原先挂在权限页的 onAppear 上，而 onAppear 只在
        // 页码**变化**时才跑：上次就停在权限页关掉的窗口，再次 show(startAt: .permissions)
        // 时页码没变，于是会被留在视图里的那个 1 秒 Timer 在 1.8 秒后推到第三屏去。所以挪到这里。
        model.autoAdvanced = page == .permissions && model.micOK && model.axOK
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
        // 引导一关，屏幕上就一扇窗都不剩了——这正是"它去哪了"的那一刻。
        // 启动时那句提示因为引导开着而没闪（LaunchNotice.decide），补在这里
        LaunchNotice.flash(.running, after: LaunchNotice.afterOnboardingDelay)
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
                case .howYouUse: HowYouUsePage(model: model)
                case .tryIt: TryItPage(model: model)
                case .done: DonePage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 8)

            // 模型下载条 5.0.0 删掉：没有本机模型可下了。
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
            // 唯一的出口：一条小链接，不是一颗和「继续」平起平坐的按钮。
            // 点下去当场露出「听写暂不可用」那一行，然后才放行（见 skipEssentials）
            if showsSkipLink {
                Button(OnboardingCopy.skipForNow) {
                    OnboardingWindowController.shared.skipEssentials()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            // 「跳过（只用本地）」那颗按钮 5.0.0 删掉：识别也在云端，没有 Key 这个产品
            // 一个功能都用不了——把它做成一条"正当的另一条路"就是骗人。
            // 走不下去的人仍然有出口：底下那条「先跳过」（它明写着代价）。
            Button(model.page == .done ? tr("完成", "Done")
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
        case .tryIt: return !essentials.canFinish
        // ③「选你的 AI」5.0.0 起**是一道真关卡**（识别也在云端，没有 Key 什么都做不了），
        // 但拦人的判据仍然只有一条：那把 Key 在不在（model.engineReady）。
        // 出口是底下那条写明代价的「先跳过」，别的一个都没有。
        case .howYouUse: return !essentials.modelReady
        case .welcome: return false
        // 最后一屏的「完成」无条件放行：**关卡在上一屏**（能走到这儿说明三件事已经齐了，
        // 或者他点过「先跳过」）。在这里再拦一次只会拦住一个已经被放行过的人
        case .done: return false
        }
    }

    /// 出口只在"确实卡住了"的那两屏露面。下载正在跑的时候不摆：进度条就在上面，
    /// 等一等比跳过好；他真不想等，进度条右边就有「取消」，取消完这条链接自然出现。
    private var showsSkipLink: Bool {
        guard !model.skippedEssentials else { return false }
        switch model.page {
        case .permissions: return !essentials.permissionsGranted
        // 与上面那颗按钮同一条判据：凡是「继续」点不动的时候，出口都必须在
        case .howYouUse: return !essentials.modelReady
        case .tryIt: return !essentials.canFinish
        case .welcome, .done: return false
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

                // 键盘示意图（4.3.4 加）：光写"右 Option (⌥)"对不上很多人手底下那颗印着
                // alt 的键——这一屏要回答的第一个问题就是"到底按哪个键"（用户 2026-09-22 反馈）
                KeyboardHintView()

                // 4.1.0 之前这里摆着一个三选一的热键选择器。拿掉它（用户 2026-09-20 拍板）：
                // 这是他打开 MicType 的第一分钟，还一次都没听写过，凭什么在这时候挑键？
                // 两张手势卡直接把键名写出来就够了——这一屏要教的本来就是"按哪儿"，不是"选哪颗"。
                HStack(alignment: .top, spacing: 14) {
                    GestureCard(symbol: "hand.tap",
                                gesture: tr("轻点 \(key)", "Tap \(key)"),
                                // 5.0.0 起识别在云端，「本地听写」那个标题是句假话
                                title: tr("语音输入", "Dictate"),
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

                // 引导里**唯一**一句隐私文案（那几句只在关于页逐句摆出来，这里只说
                // 第一次打开的人最该知道的那一条——5.0.0 起它变成了"录音会去服务商那边"，
                // 而那正是他按下第一次热键之前有权先知道的事）。fixedSize：句子换行时必须
                // 让它把高度撑开，否则窄窗口下后半句会被直接截掉。
                Text(PrivacyCopy.audioGoesToProvider)
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
    /// 1 秒一次的轮询：用户在系统设置里打开开关后，这里自己变绿，不需要重启、也不必再点一次。
    /// **只在窗口开着时轮**：窗口是复用的，关掉之后这一页并不会消失——4.1.0 之前这里是个
    /// autoconnect 的 Timer，于是关窗之后它照轮不误，还能在一扇关着的窗里把页码推到第三屏。
    @State private var poll: AnyCancellable?
    /// 这扇窗开着没有（关窗时要停轮询，再开时接着轮）
    @ObservedObject private var windowState = OnboardingWindowController.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("两项系统权限", "Two system permissions"))
                    .font(.system(size: 16, weight: .semibold))
                Text(OnboardingCopy.permissionsIntro)
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

                // 「测一下麦克风」那一段与模型下载那几行 5.0.0 一起删掉：
                // 麦克风永远跟随系统默认（没有可选的设备了），本机模型也没有了。
                // 这一屏因此只剩它本来该有的两件事：两项权限。

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
    /// 阿里云那一档的接入地址（可选；留空 = MicType 自己试出来）。
    /// 这里盯着它：地址一改，这一档发往哪台主机就变了，"能不能连得上"得跟着重算。
    @AppStorage(SettingsKeys.qwenAPIHost) private var qwenAPIHost = ""
    @State private var keyStatus: KeyVerifier.Status = .idle
    /// 选择器上**正在看**的那一档，不是生效的那一档。
    ///
    /// 点着看看的人很多，而原来那一档可能正配着一把好 Key——点一下就把生效服务商换掉，
    /// 表现是他下次按键直接失败，还找不到原因（判据见 AISetup.adoptsProvider）。
    @State private var pendingProvider: LLMProvider = Settings.shared.llmProvider
    /// 钥匙串里有没有**正在看**的这一档的 Key。存着而不是在 body 里读：
    /// SecItemCopyMatching 坐在每帧都跑的路径上是明令禁止的（Settings.swift 那条规矩）。
    @State private var selectedHasStoredKey = KeychainHelper
        .loadAPIKey(account: Settings.shared.llmProvider.keychainAccount) != nil
    /// 这一刻**真正生效**的那一档。Settings.llmProvider 不是 @Published，采纳之后这一屏不会
    /// 自己重算，而选择器旁边那枚「正在使用 ✓」正靠它——所以存一份，在同样那几个事件上刷新。
    @State private var inUseProvider: LLMProvider = Settings.shared.llmProvider

    private var selected: LLMProvider { pendingProvider }

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

                // 上半：两张并排的卡片（点一张选中）。每张三行：一小时多少钱 / 适合谁 /
                // 一句优势——这一刻用户对这两个名字一无所知，一个只有两个词的分段选择器
                // 给不了他任何做这个选择的依据（设置页那一处不同：他早就选过了）。
                ProviderChoiceCards(selection: providerBinding, inUse: inUseProvider)

                // 下半：选中那一家的申请步骤 → Key 框（+ 阿里云的接入地址框）→ 状态行。
                // 与设置正页**同一个视图**（CloudSetupCore），Key 框、那颗 ⓘ、接入地址
                // 全都只写一处。两处真正不同的只有语义：看着的那一档要验证通过才采纳。
                CloudSetupCore(style: .onboarding,
                               selected: selected,
                               inUse: inUseProvider,
                               provider: providerBinding,
                               showsNotSetUpHint: false,
                               onKeyStatus: { status in
                                   keyStatus = status
                                   adoptIfUsable(selected)
                                   refreshStoredKey()
                                   model.refreshEngineReady()
                                   model.refreshAIReady()
                               }) {
                    providerNotices
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // 回头再走一遍引导的人：选择器要停在他**正在用**的那一档上
            pendingProvider = Settings.shared.llmProvider
            refreshStoredKey()
            model.refreshEngineReady()
            model.refreshAIReady()
        }
        // 存着的接入地址被丢掉 / 被导入改掉，阿里云那一档的地址就变了，能不能连得上跟着变
        .onChange(of: qwenAPIHost) { _, _ in
            model.refreshEngineReady()
            model.refreshAIReady()
        }
    }

    /// 服务商选择器下面的边界状态：一行结论，动作就在下面那个 Key 输入框里，所以不另给按钮。
    @ViewBuilder
    private var providerNotices: some View {
        if Settings.shared.llmProvider != selected, !selectedHasStoredKey {
            Caption(OnboardingCopy.providerNotAdoptedYet(current: Settings.shared.llmProvider.segmentName))
        }
    }

    /// 选择器上换一档：只换"正在看"的那一档，真正生效要等 adoptIfUsable 认可。
    private var providerBinding: Binding<LLMProvider> {
        Binding(get: { pendingProvider },
                set: { next in
                    guard next != pendingProvider else { return }
                    pendingProvider = next
                    // 上一档的验证结论对这一档毫无意义（KeyEntryView 自己也会重载钥匙串里的 Key）
                    keyStatus = .idle
                    adoptIfUsable(next)
                    refreshStoredKey()
                    model.refreshEngineReady()
                    model.refreshAIReady()
                })
    }

    // MARK: 状态读写

    /// 重读一次"钥匙串里有没有正在看的这一档的 Key"。只在事件上调，绝不在 body 里调。
    private func refreshStoredKey() {
        selectedHasStoredKey = KeychainHelper.loadAPIKey(account: selected.keychainAccount) != nil
        inUseProvider = Settings.shared.llmProvider
    }

    /// 只有"这一档真的能用"才把它写成生效的服务商（判据是纯函数 AISetup.adoptsProvider，
    /// 设置页那一处走的是同一条）。换过去之后识别也跟着换家——那是 5.0.0 的推导，不是一条设置。
    private func adoptIfUsable(_ provider: LLMProvider) {
        let hasKey = KeychainHelper.loadAPIKey(account: provider.keychainAccount) != nil
        guard AISetup.adoptsProvider(current: Settings.shared.llmProvider, next: provider,
                                     requiresKey: provider.requiresAPIKey, hasKey: hasKey,
                                     polishModel: LLMCatalog.defaultModel(for: provider)) else { return }
        Settings.shared.llmProvider = provider
        inUseProvider = provider
        Log.info("Onboarding adopted provider=\(provider.rawValue) (recognition follows)")
    }
}

// MARK: - 4. 试一下 + 收尾

private struct TryItPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    @FocusState private var editorFocused: Bool
    /// 「已收到 ✓」那一下的开关（2.5 秒后自己熄）
    @State private var flashReceived = false
    /// 权限与 Key 的状态靠这个 1 秒轮询刷新（两者都可能在这一页上被补齐：
    /// 轻点会弹系统麦克风框，用户也可能翻回上一屏去粘 Key）。
    /// 同权限页：只在窗口开着时轮，关掉之后这一页还在视图树里，autoconnect 会一路轮到退出
    @State private var readinessPoll: AnyCancellable?
    /// 这扇窗开着没有（关窗时要停轮询，再开时接着轮）
    @ObservedObject private var windowState = OnboardingWindowController.shared

    /// 这一屏让他"轻点试一次"，那就得先说清这一次能不能成。
    /// 5.0.0 起唯一会挡住他的是**那把 Key**（识别也在云端）。
    private var keyMissing: Bool { !model.engineReady }

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
                refreshPermissions()
                // Key 可能是在这一页才补齐的（翻回上一屏粘完再回来）：「完成」那颗按钮读的就是它
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

                // Key 还没配好：现在轻点是说不出字的。上一屏就是配它的地方
                if keyMissing {
                    Text(OnboardingCopy.keyMissingForTryIt)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 点过「先跳过」：说清他带着什么走。这一行和权限页那一行是同一句——
                // 缺的是权限还是 Key，对用户来说结果完全一样：轻点没反应
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
                    Text(OnboardingCopy.escCancels)
                        .font(.caption)
                        .foregroundColor(.secondary)
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

                // 这一页只留两条 tip。4.3.4 之前这里还挂着 AI 收尾句、菜单栏那条、
                // 以及「重看引导」那一行——它们都是"最后一屏"该说的话，而最后一屏
                // 现在是 ⑤（那里说得更全，还配着一张真图）。连着两屏说同一句，
                // 用户只会以为自己漏看了什么新东西。
                VStack(alignment: .leading, spacing: 8) {
                    TipRow(symbol: "hand.tap.fill",
                           text: OnboardingCopy.holdToCommandTip(hotkey: key))
                    TipRow(symbol: "text.book.closed",
                           text: OnboardingCopy.vocabularyTip)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 上一屏可能刚粘好 Key，也可能用户中途去设置页配了——进这一屏现算一次
        .onAppear {
            model.refreshAIReady()
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

// MARK: - 5. 它在哪（4.3.4 起）

/// 引导的最后一屏，回答的是走完引导之后那个必然的问题：**"它去哪了？"**
///
/// 4.3.4 之前这份引导关掉之后，屏幕上一扇窗都不剩、Dock 里没有图标、菜单栏那枚图标
/// 和别的录音工具长得一样——用户（2026-09-22 的原话）"不知道它在哪，也不知道接下来干什么"。
///
/// 所以这一屏只做三件事：把那枚图标**画出来**给他看（4.3.5 起 Dock 和菜单栏各有一枚，
/// 两处都要指到）、说清平时压根不用去找它、以及当面把「登录时自动启动」打开
///（默认开，就在这一屏可以关掉）——不开的话第二天开机 MicType 根本没在跑，
/// 同一个问题会原样再来一遍。
private struct DonePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    /// 上一次开关登录项被系统拒了（受管的 Mac 上可能被 MDM 挡住）。
    /// 边界行的写法与设置页那一处完全一致：一行结论 + 一颗去处
    @State private var launchAtLoginRefused = false

    /// 这一页每一句话里念出来的那颗键（只有一颗，见 Settings.hotkey）
    private var key: String { HotkeyChoice.rightOption.plainName }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // 菜单栏里的那枚图标，原样画一张大的（同一个画法，见 MenuBarIcon）
                Image(nsImage: MenuBarIcon.large())
                    .renderingMode(.template)
                    .foregroundColor(.accentColor)
                Text(OnboardingCopy.menuBarHome)
                    .font(.system(size: 16, weight: .semibold))
                Text(OnboardingCopy.menuBarHolds)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(OnboardingCopy.rarelyNeeded(hotkey: key))
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(tr("登录时自动启动", "Launch at login"), isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            applyLaunchAtLogin(newValue)
                        }
                    Text(OnboardingCopy.launchAtLoginWhy)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if launchAtLoginRefused {
                        BoundaryRow(text: SettingsCopy.launchAtLoginFailed) {
                            Button(tr("打开登录项设置", "Open Login Items")) {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)

                // 三种收尾（按 AI 到底配到哪一步）：他离开引导时对"我现在有什么"的最后印象
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.aiReady ? "wand.and.stars" : "cpu")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                        .frame(width: 18)
                    Text(OnboardingCopy.doneAIStatus(status: model.aiStatus, hotkey: key))
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                // 「以后还想再看一遍」：4.3.4 起这句住在最后一屏（原来在 ④）。
                // 它说的是"这扇窗以后从哪儿再打开"，那正是他此刻要关掉它的这一刻该知道的事
                Text(OnboardingCopy.reopenGuide)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            // 上一屏可能刚把 Key 配好，也可能他中途去设置页改了档位
            model.refreshAIReady()
            armLaunchAtLogin()
        }
    }

    /// 「默认开」是怎么实现的：第一次走到这一屏时，**替他真的注册一次**登录项，
    /// 并把开关画成开着。不只是把开关画成开着——那样他看到的是"已开"、系统里却没有，
    /// 是这一屏最不该出的错。这一轮只做一次（model.launchAtLoginArmed）：
    /// 在这一屏关掉再翻回来的人，不许被又打开一次。
    private func armLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        launchAtLogin = enabled
        // 只有真的开着引导窗口时才去动系统登录项。这一页还会被**离屏渲染**
        //（引导页快照测试），那一刻绝不能顺手改掉这台机器上的登录项——
        // 读一下状态可以，写下去不行
        guard OnboardingWindowController.shared.isOpen else { return }
        guard !model.launchAtLoginArmed else { return }
        model.launchAtLoginArmed = true
        guard !enabled else { return }
        applyLaunchAtLogin(true)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    /// 与设置页「输入」那一段同一套写法：失败只记日志 + 一行边界，
    /// 系统给的原因不上屏（它可能是另一种语言，英文界面不能冒出中文）
    private func applyLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginRefused = false
            Log.info("Onboarding launch at login on=\(on)")
        } catch {
            Log.warn("Onboarding launch at login failed on=\(on) error=\(error)")
            launchAtLoginRefused = true
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
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
