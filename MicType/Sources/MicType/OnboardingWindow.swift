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

    // MARK: 第一屏（5.0.1 重做）

    /// 这一屏只回答三件事：按哪颗键、轻点做什么、按住做什么。
    /// 5.0.1 拿掉了键盘示意图（画出来的那一排键帽和用户手底下的键盘未必一样，
    /// 而"右 Option"这四个字配上 ⌥ 符号已经够认）、隐私那一句（它在「关于 → 隐私」里，
    /// 那是唯一出处）和「两种手势泾渭分明」（那是我们的设计原则，不是他此刻要学的动作）。

    /// 快捷键那一行。键名走 HotkeyChoice（只有右 Option 一颗），绝不在这里手写
    static var hotkeyLine: String {
        tr("快捷键：\(HotkeyChoice.rightOption.displayName)",
           "Hotkey: \(HotkeyChoice.rightOption.displayName)")
    }

    /// 轻点那张卡的正文
    static var dictateCardDetail: String {
        tr("轻点开始，说话，再轻点结束；文字落在光标处。",
           "Tap to start, speak, tap again to stop; the text lands at your cursor.")
    }

    /// 按住那张卡的两条。**分两条写**是因为它们的结果真的不一样，而这正是 5.0.1
    /// 把投递改成确定性规则之后，用户必须提前知道的那件事（见 DictationController.selectionDelivery）
    static var commandCardNoSelection: String {
        tr("没选中文字：说你要什么，结果落在光标处。",
           "Nothing selected: say what you want, the result lands at the cursor.")
    }

    static var commandCardSelection: String {
        tr("选中了文字：在输入框里 → 原地改写；在别处 → 复制到剪贴板",
           "Text selected: in a text field → rewritten in place; elsewhere → copied to the clipboard")
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

    /// 第四屏的两步。**编号写出来**（5.0.1）：这一屏要他真的动手做两件事，
    /// 而第二件（选中刚打出来的字、按住说指令）是这个产品最不直觉、也最值钱的一步——
    /// 4.3.6 之前它只是底下一条 tip，几乎没人会照着做。
    static func tryItStepDictate(hotkey: String) -> String {
        tr("轻点 \(hotkey)，说一句话，再轻点 → 文字出现在上面",
           "Tap \(hotkey), say something, tap again → the text appears above")
    }

    static func tryItStepCommand(hotkey: String) -> String {
        tr("选中上面的文字，按住 \(hotkey) 说「翻译成英文」，松手 → 原地改写",
           "Select the text above, hold \(hotkey) and say \"translate to English\", release → rewritten in place")
    }

    /// 「试一下」那一页：Key 还没配好，现在轻点是说不出字的（5.0.0 起识别也要那把 Key）
    static var keyMissingForTryIt: String {
        tr("还没填 API Key，现在轻点是说不出字的——回上一屏粘一把。",
           "No API key yet, so tapping now will not produce any text - go back a screen and paste one.")
    }

    // escCancels / holdToCommandTip / vocabularyTip / reopenGuide / keyboardHint
    // 5.0.1 一并删掉。它们都是"顺便再说一句"堆出来的：
    //   • Esc 取消、按住说指令、词汇表怎么填 —— ④ 只留那两条编号步骤，其余进不了那一屏；
    //   • 「重看引导」那句写在最后一屏，而那一屏现在只剩三样东西；
    //   • 键盘示意图连同它下面那行说明一起没了（画出来的键帽和用户手底下的键盘未必一样）。

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

    // menuBarHolds（「菜单栏图标里有…」）与 rarelyNeeded（「平时不用找它…」）5.0.1 删掉：
    // 前者念的那几项 5.0.1 已经不在菜单里了（那份菜单只剩三项），后者说的事前四屏都教过。
    // 这一屏只剩：那枚图标 + 「它在 Dock 和菜单栏里」 + 开机自启 + 「完成」。

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
        [hotkeyLine, dictateCardDetail, commandCardNoSelection, commandCardSelection,
         permissionsIntro, microphonePurpose, accessibilityPurpose, permissionsStuckHint,
         providerNotAdoptedYet(current: "OpenAI"), pasteKeyHere,
         tryItStepDictate(hotkey: "⌥"), tryItStepCommand(hotkey: "⌥"), keyMissingForTryIt,
         menuBarHome, launchAtLoginWhy]
    }

    /// 第三屏的标题。这一屏就是设置页那一页的首配版本，名字必须和那里一致。
    /// 5.0.0 起它**不再写「可选」**：识别、润色、指令三件事全在云端，没有 Key 一件都做不了。
    static var usageHeadline: String {
        tr("选你的 AI", "Choose your AI")
    }

    // usageExplanation（「听写、润色、语音指令都用这一把 Key…」）5.0.1 删掉：
    // 那一屏开头再摆一整段说明，用户要往下翻才看得见真正要做的事（选一家、贴一把 Key），
    // 而两张卡片和那三步申请说明本来就把这件事说全了。费用与隐私在「关于 → 隐私」。
    //
    // doneAIStatus（最后一屏那句 AI 收尾）同样删掉：最后一屏只回答"它在哪"。
    // 没配 Key 的人在 ③ 已经被那条「先跳过」明确告知过代价了。
}

// MARK: - 窗口高度跟着这一屏的内容走（5.0.1 起；5.0.2 改成直接量）

/// 引导窗口的尺寸算术。**和设置窗口分开**（5.0.2）：设置那套有一条 760 的硬上限，
/// 而引导 ③ 在英文界面下比 760 还高——夹在 760 上的结果正是用户 2026-09-23 报的那个
/// "第 ②③④⑤ 屏都显示不全"。这里的上限只有一条：**可见屏高 − 120**。
enum OnboardingWindowSizing {
    /// 宽度不变（整套文案的换行都是按它调的）
    static let width: CGFloat = 560
    /// 下限。**5.0.3 从 220 提到 420**（用户 2026-09-23 实机反馈"重看引导打开的窗口太小"）：
    /// 五屏的自然高度是 258–342，按内容给的话，第一次打开 MicType 的人看到的是一扇
    /// 比设置窗口还矮的小框——"刚好装下"和"像回事"是两件事，而这扇窗是这个产品的门面。
    /// 矮于内容的那一屏照常长高（这是地板不是天花板），多出来的高度留在内容下面，
    /// 底部那排按钮仍然钉在窗底（见 OnboardingView 的 VStack）。
    static let minContentHeight: CGFloat = 420
    /// 离屏幕可见区域上下各留的余量：窗口顶到菜单栏、底到程序坞边上，既难拖也难看
    static let screenMargin: CGFloat = 120

    /// 这一屏该给多高。**纯函数**（单测钉住"够放下 + 不出屏"这两条）。
    /// natural 是整个 OnboardingView 的自然高度（含上下留白与底部导航）。
    static func contentHeight(natural: CGFloat, visibleScreenHeight: CGFloat) -> CGFloat {
        let ceiling = max(minContentHeight, visibleScreenHeight - screenMargin)
        guard natural.isFinite, natural > 0 else { return minContentHeight }
        return min(max(natural.rounded(.up), minContentHeight), ceiling)
    }
}

/// "这一屏的内容变了"的信号。
///
/// **5.0.2 起只当信号用，不再用它报上来的数字**：那条路上的高度要先经过 @State、
/// 再在同一个闭包里被读出来（SwiftUI 不保证读到的是刚写进去的值），于是窗口会按
/// **上一屏**的高度去开——用户看到的就是"②③④⑤ 都被裁掉一截"。
/// 现在窗口高度由控制器直接问 NSHostingView 要（fittingSize），这里只负责说一句"该重量了"。
struct OnboardingPageHeightKey: PreferenceKey {
    static var defaultValue: [OnboardingPage: CGFloat] = [:]

    static func reduce(value: inout [OnboardingPage: CGFloat],
                       nextValue: () -> [OnboardingPage: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// 量这一屏的自然高度（贴在每一屏 ScrollView 里那个 VStack 上）。
    /// 内容一变就推一次信号：权限徽章变绿、Key 状态行冒出来、语言切换……都会走到这里
    func measuresOnboardingPage(_ page: OnboardingPage) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: OnboardingPageHeightKey.self,
                                   value: [page: geo.size.height])
        })
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
    /// 装着 OnboardingView 的那个宿主。**窗口高度就是问它要的**（见 remeasure）
    private var hosting: NSHostingController<OnboardingView>?
    private var langObserver: AnyCancellable?
    private var pageObserver: AnyCancellable?
    private let model = OnboardingModel()
    /// 防抖：一次翻页会连着报好几次变化（旧页退场、新页登场、状态行冒出来）
    private var resizeWork: DispatchWorkItem?
    /// 这扇窗还没按内容摆过位置：第一次量到高度时居中一次，之后一律保住顶边
    private var needsInitialPlacement = true
    /// 上一次真正下发的内容高度。**动画期间要靠它判"还用不用再动"**：
    /// 窗口在那 0.2 秒里每一帧都在变高，拿当前 frame 去比会把自己的动画打断
    private var lastAppliedContentHeight: CGFloat?

    // MARK: 高度跟着内容走（5.0.1 起；5.0.2 改成直接量）

    /// "内容可能变了，该重新量一次了"。视图层每次变化、每次翻页都会叫它。
    ///
    /// 5.0.1 是让视图把量到的高度**报上来**，结果那个数要先经过 @State、再在同一个闭包里
    /// 被读回去——SwiftUI 不保证读到的是刚写进去的值，于是窗口常常按**上一屏**的高度开，
    /// 短屏换长屏时内容就被裁掉一截（用户 2026-09-23 实机报的正是 ②③④⑤ 显示不全）。
    /// 现在不再相信任何传上来的数字：到点了自己去问 NSHostingView 这一刻多高。
    func scheduleRemeasure() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyFittedHeight() }
        resizeWork = work
        // 一拍之后再量：翻页那一下 SwiftUI 还没把新页排完，当场量到的是旧页的高度
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// 真正改窗口的那一下。**顶边不动**（算术在 SettingsWindowSizing.frame 里，单测钉死）。
    /// 高度取整个 OnboardingView 的自然高度（fittingSize 已经含了上下留白和底部那排按钮）。
    ///
    /// - immediately: 窗口还没露面，当场量、当场定尺寸（不排队、不做动画）。
    ///   「重看引导」那条路非它不可：那一刻 hosting 刚建好、或者停在上一轮那一屏的高度上，
    ///   等 0.05 秒那一跳的话，用户先看到的是一扇 420 的空窗然后才跳一下（5.0.2 的表现）。
    private func applyFittedHeight(immediately: Bool = false) {
        guard let window = window, let hosting = hosting else { return }
        // 先按目标宽度排一遍版：换行是按宽度算的，不排就量不准
        hosting.view.setFrameSize(NSSize(width: OnboardingWindowSizing.width,
                                         height: hosting.view.frame.height))
        hosting.view.layoutSubtreeIfNeeded()
        let natural = hosting.view.fittingSize.height
        guard natural > 0 else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let content = OnboardingWindowSizing.contentHeight(natural: natural,
                                                           visibleScreenHeight: visible.height)
        let frameHeight = window.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: OnboardingWindowSizing.width, height: content)).height
        guard needsInitialPlacement == false else {
            window.setContentSize(NSSize(width: OnboardingWindowSizing.width, height: content))
            window.center()
            needsInitialPlacement = false
            lastAppliedContentHeight = content
            return
        }
        guard abs((lastAppliedContentHeight ?? 0) - content) > 0.5 else { return }
        lastAppliedContentHeight = content
        let target = SettingsWindowSizing.frame(current: window.frame, frameHeight: frameHeight,
                                                visible: visible)
        // 还没露面：直接定好，别让用户看见窗口自己跳一下
        guard !immediately else {
            window.setFrame(target, display: false)
            return
        }
        guard !SettingsNavigator.reduceMotion else {
            window.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
        }
    }

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
        // 重开这扇窗：高度要按新的那一屏重新量（上一轮留下的数字对这一屏不算数）
        lastAppliedContentHeight = nil
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
            // 尺寸由我们自己按内容算（见 applyFittedHeight）。放着不管的话，
            // NSHostingController 会用 preferredContentSize 自己去改窗口大小——
            // 那条路是**从左下角**长的，每翻一页标题栏跳一次（设置窗口那边同一条）
            hosting.sizingOptions = []
            self.hosting = hosting
            let w = NSWindow(contentViewController: hosting)
            // 无边框标题：内容自己撑满，只留一个关闭按钮
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            // 先按下限开着，量到真实高度立刻跟上（第一次测量会顺手居中一次）。
            // 5.0.1 之前这里写死 470：短的那几屏底下空出小半扇窗
            w.setContentSize(NSSize(width: OnboardingWindowSizing.width,
                                    height: OnboardingWindowSizing.minContentHeight))
            w.center()
            w.delegate = self
            window = w
            langObserver = L10n.shared.$language.sink { [weak self] lang in
                self?.window?.title = lang == .zh ? "欢迎使用 MicType" : "Welcome to MicType"
                // 换一种语言等于换一整屏的字：行数会变，窗口得跟着重量一次
                self?.scheduleRemeasure()
            }
            // 翻页就重量。**订阅模型而不是等视图报数**：翻页是这扇窗里高度变化最大的一件事，
            // 而 5.0.1 正是在这条路上把上一屏的高度用在了新一屏上
            pageObserver = model.$page.sink { [weak self] _ in self?.scheduleRemeasure() }
        }
        window?.title = tr("欢迎使用 MicType", "Welcome to MicType")
        // **先量再显示**（5.0.3）：窗口这会儿还是上一轮（或刚建出来的下限）那个高度，
        // 而这一轮多半停在另一屏上。等那条 0.05 秒的防抖来改，用户会先看见一扇不对的窗。
        // 排一次版再量一次——这条路和防抖那条走的是同一个函数，只是不排队、不做动画。
        resizeWork?.cancel()
        applyFittedHeight(immediately: true)
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
        // 高度**不写死**（5.0.1 起）：窗口按这一屏的自然高度伸缩。
        // 5.0.2 起这个数不再从这里报上去——控制器到点直接量 NSHostingView（见 scheduleRemeasure），
        // 这里只在内容变了的时候推一声"该重量了"
        .frame(width: OnboardingWindowSizing.width)
        .onPreferenceChange(OnboardingPageHeightKey.self) { _ in
            OnboardingWindowController.shared.scheduleRemeasure()
        }
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

// MARK: - 1. 欢迎（5.0.1 重做）

/// 这一屏只回答三件事：**按哪颗键、轻点做什么、按住做什么**。
///
/// 5.0.1 拿掉的都是"顺便说一句"：键盘示意图（画出来的键帽排布和用户手底下那块键盘
/// 未必一样，而且它把两张卡挤到了第二屏）、「两种手势泾渭分明」（那是我们的设计原则，
/// 不是他此刻要学的动作）、以及底下那句隐私（唯一出处是「关于 → 隐私」）。
///
/// 右上角那对语言按钮是这一屏**唯一**的控件：界面语言跟系统走，跟错了的话
/// 这个人从第一屏起就在读他看不懂的字——而设置窗口里的那个入口他还没见过。
private struct WelcomePage: View {
    @ObservedObject private var l10n = L10n.shared

    /// 这一屏念出来的那颗键。只有一颗，不用问设置
    private var key: String { HotkeyChoice.rightOption.displayName }

    var body: some View {
        // ScrollView 是保险绳（与后面三屏同一个理由）：英文界面下两张手势卡更高，
        // 挤爆时宁可能滚，也不要把卡片底下那行裁掉
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    Spacer()
                    languagePicker
                }
                Text(tr("用一个键说话，文字直接落在光标处。",
                        "Press one key, speak, and the text lands at your cursor."))
                    .font(.system(size: 16, weight: .medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(OnboardingCopy.hotkeyLine)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                // 4.1.0 之前这里摆着一个三选一的热键选择器。拿掉它（用户 2026-09-20 拍板）：
                // 这是他打开 MicType 的第一分钟，还一次都没听写过，凭什么在这时候挑键？
                //
                // **两张卡等高等宽**：按住那张有两条、轻点那张只有一条，不对齐的话
                // 看着像其中一张更重要——而这两个手势是这个产品的全部
                HStack(alignment: .top, spacing: 14) {
                    GestureCard(gesture: tr("轻点", "Tap"),
                                title: tr("听写", "Dictate"),
                                lines: [OnboardingCopy.dictateCardDetail])
                    GestureCard(gesture: tr("按住", "Hold"),
                                title: tr("说指令，松手执行", "Speak a command, release to run"),
                                lines: [OnboardingCopy.commandCardNoSelection,
                                        OnboardingCopy.commandCardSelection])
                }
                // 两张卡的高度取这一行里最高的那张（fixedSize 先让每张按内容量高，
                // maxHeight: .infinity 再把矮的那张撑到同一高度）
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .measuresOnboardingPage(.welcome)
        }
    }

    /// 「中文 | English」。两个名字各写各的语言（译过来反而要用户先猜哪个是哪个）
    private var languagePicker: some View {
        Picker("", selection: Binding(get: { l10n.language },
                                      set: { next in
                                          guard next != l10n.language else { return }
                                          Log.info("UI language switched to=\(next.rawValue)")
                                          l10n.language = next
                                      })) {
            ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                Text(language.displayName).tag(language)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

private struct GestureCard: View {
    /// 「轻点」/「按住」——卡片的帽子，就是那个手势本身
    let gesture: String
    let title: String
    /// 正文，一条或两条（按住那张要分"有没有选中文字"两种结果说）
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(gesture)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        // maxHeight: .infinity = 和这一行里最高的那张卡同高（见调用处）
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
            .measuresOnboardingPage(.permissions)
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
                // 开头那整段说明 5.0.1 删掉：它把真正要做的事（选一家、贴一把 Key）压到了
                // 第二屏之外，而两张卡片和那三步申请说明本来就把这件事说全了

                // 上半：两张并排的卡片（点一张选中）。每张三行：一小时多少钱 / 一句优势 /
                // 怎么付钱——这一刻用户对这两个名字一无所知，一个只有两个词的分段选择器
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
            .measuresOnboardingPage(.howYouUse)
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
                TextEditor(text: $model.tryItText)
                    .font(.system(size: 13))
                    .focused($editorFocused)
                    .frame(height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.35)))

                // 两条编号步骤，一条都不多（5.0.1）。第二条是这个产品最不直觉、也最值钱的
                // 一步：选中刚打出来的字、按住说指令、它就地被改掉。4.3.6 之前它只是底下
                // 一条灰色 tip，几乎没人会照着做——而这一屏是他唯一会照着做的地方。
                VStack(alignment: .leading, spacing: 8) {
                    NumberedStep(index: 1, text: OnboardingCopy.tryItStepDictate(hotkey: key))
                    NumberedStep(index: 2, text: OnboardingCopy.tryItStepCommand(hotkey: key))
                }

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

                // 「完成」点不动的时候，这一行说为什么
                if !model.skippedEssentials,
                   let reason = OnboardingCopy.finishBlockedReason(model.essentials()) {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.tryItText.isEmpty {
                    HStack {
                        Spacer()
                        Button(tr("清空", "Clear")) {
                            model.tryItText = ""
                            editorFocused = true
                        }
                        .controlSize(.small)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .measuresOnboardingPage(.tryIt)
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

                // AI 收尾句与「重看引导」5.0.1 删掉：这一屏只回答"它在哪"。
                // 没配 Key 的人在 ③ 已经被那条「先跳过」明确告知过代价；
                // 「重看引导」在设置底部那排小字里，而他此刻还没见过设置窗口——
                // 这一刻记住一个以后才用得上的入口，只会把这一屏的三样东西冲淡
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .measuresOnboardingPage(.done)
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

/// 「试一下」那一屏的一条编号步骤。编号用文字而不是列表符号：它要和右边那句话
/// 在同一条基线上（同 ConsoleStepsView 的写法）
private struct NumberedStep: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index).")
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
