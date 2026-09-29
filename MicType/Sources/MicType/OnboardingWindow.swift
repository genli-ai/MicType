import SwiftUI
import AppKit
import AVFoundation
import Combine
// 第三屏那一行「登录时自动启动 · 已开启」（默认开，不做开关）
import ServiceManagement

// MARK: - 首次启动引导

/// **三屏**（5.3.0，UX 方案 §3 B，用户 2026-09-29 拍板，推翻 09-22「5 屏」）：
///   ① 按住右 Option (⌥) 说话 —— 一颗发光的键 + 两项权限；
///   ② 贴上你的 OpenAI Key —— 一个大框 + 三步小字，剪贴板里有 Key 就自动填入并验证；
///   ③ 试一下 —— 一个大框，真落一次字才出现「开始使用」。
///
/// 去掉的：「这是什么」屏（并进 ①：标题就是那个手势，副标题一行说清轻点 / 按住）、
/// 「它在哪」屏（并进 ③ 那一行「它在菜单栏和 Dock 里」）、登录自启开关（默认开，③ 一行小字）。
/// 目标是 30 秒内完成第一次成功——5 屏的时候用户"学到了怎么用"，却没"体验到多爽"。
///
/// 仍然成立的四条硬要求（都是过去踩过的坑）：
///   • 权限授予后自己变勾、自己往下走，绝不要求重启或"请再按一次"；
///   • Key 粘贴即验证，通过才进钥匙串（KeyVerifier）；
///   • 结尾必须能就地试一次——引导窗口自己是前台 App，识别结果直接写进框里（TranscriptSink），
///     不依赖 ⌘V（焦点不可靠，4.0.1 踩过）；
///   • **「走完引导」= 真做过一次听写**（UX 方案 §2，学 Wispr Flow）：③ 没落过字，
///     那颗按钮就只是「先跳过」。
///
/// **三件必办的事**（用户 2026-09-20 拍板，见 FirstRunEssentials）：两项权限 + 一把 Key。
/// 唯一的出口是写明代价的「先跳过」；每屏右上角的「稍后」= 关窗，不算走完，下次启动接着来。
enum OnboardingPage: Int, CaseIterable {
    /// ① 按住右 Option (⌥) 说话 + 两项权限
    case hold
    /// ② 贴上你的 OpenAI Key
    case key
    /// ③ 试一下 + 开始使用
    case tryIt
}

/// 页码 + 权限状态：窗口控制器与各页共享的唯一状态源
final class OnboardingModel: ObservableObject {
    @Published var page: OnboardingPage = .hold
    @Published var micOK = Permissions.microphoneGranted
    @Published var axOK = Permissions.isAccessibilityTrusted
    /// 用户点过那条「先跳过」（跳过后「继续」放行，但那一行警告一直留着）。
    /// 三屏共用这一位：跳的是同一件事——带着缺口走出引导。
    @Published var skippedEssentials = false
    /// 权限齐了自动往下翻，但**只翻一次**：翻回来再看一眼的人不该被又推走
    @Published var autoAdvanced = false
    /// AI 现在真的跑得起来吗（不是"点过没点过"）
    @Published var aiStatus: LLMCatalog.AIStatus = .off
    /// 「试一下」那一页输入框里的字。放在模型里而不是页面的 @State 里，只为一件事：
    /// 识别结果由窗口控制器**直接**写进来（TranscriptSink），视图外面够不着 @State。
    @Published var tryItText = ""
    /// 最近一次"字落进来了"的时刻。③ 那一行「就是这样…」和「开始使用」都看它：
    /// 没有这道确认，用户分不清"没识别到"和"字落到别处去了"——4.0.1 那次正是后者。
    @Published var tryItReceivedAt: Date?
    /// ③ 那一行「登录时自动启动」这一轮已经替他打开过了。
    /// 存在模型里而不是页面的 @State 里：那一页翻出去再翻回来会重建，
    /// 而"默认开"只该发生一次
    @Published var launchAtLoginArmed = false

    /// ③ 真落过一次字了吗（acceptTranscript 成功过）。「开始使用」只认这一位
    var tryItLanded: Bool { tryItReceivedAt != nil }

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

    var aiReady: Bool { aiStatus == .ready }

    /// 钥匙串里有没有那把 Key。**存着**而不是每次读界面时现算：它要读钥匙串，
    /// 而 essentials() 一次 body 就被读好几次——Security 框架的调用不许坐在这种路径上
    /// （Settings.swift 里那条规矩）。刷新点只有真会改变它的那几处：打开引导、两个 1 秒轮询、
    /// Key 验证有了结论。
    @Published private(set) var keyReady = RecognitionEngineReadiness.current().hasKey

    func refreshKeyReady() {
        let ready = RecognitionEngineReadiness.current().hasKey
        if ready != keyReady { keyReady = ready }
    }

    /// 三件必办的事此刻办到哪一步（界面上看到什么，判据就是什么）。判断本身全在 FirstRunEssentials 里。
    func essentials() -> FirstRunEssentials {
        FirstRunEssentials(microphone: micOK, accessibility: axOK, keyReady: keyReady)
    }

    /// 重算 aiStatus。5.0.0 起只有两档（配好了 / 没配），因为润色不再有开关。
    func refreshAIReady() {
        aiStatus = LLMCatalog.aiStatus(hasCredential: LLMClient.isConfigured,
                                       baseURL: Settings.shared.currentBaseURL,
                                       polishModel: Settings.shared.currentPolishModel)
    }
}

// MARK: - 剪贴板里那把 Key（纯函数）

/// 引导 ② 出现的那一刻看一眼剪贴板：像一把 OpenAI Key 就替他填进去、当场验证。
///
/// 为什么值得做（UX 方案 §3 B）：② 这一屏上用户要做的唯一一件事，是把刚在控制台复制的那串字
/// 贴进来——而 4.3.4 之前自家窗口里 ⌘V 是坏的，「粘不进去」一直是首配最常卡住的一步。
///
/// 判据故意很窄，宁可认不出也不许认错（认错 = 把用户剪贴板里的别的东西发给 OpenAI 去验）：
///   • 去掉首尾空白之后以 `sk-` 开头；
///   • 至少 20 个字符（OpenAI 的 Key 远长于此；`sk-` 加几个字的笔记不算）、至多 512 个；
///   • 只含字母、数字、`-`、`_`——中间夹一个空格或换行，就是一段话而不是一把 Key。
/// 只在这一屏出现时读一次，**不轮询**（剪贴板是用户的东西，不该被一直盯着）；
/// 填进去之前不写钥匙串，验证通过才存（KeyVerifier 的老规矩）。
enum ClipboardKey {
    static let prefix = "sk-"
    static let minimumLength = 20
    static let maximumLength = 512

    static func candidate(from clipboard: String?) -> String? {
        guard let raw = clipboard else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix),
              text.count >= minimumLength, text.count <= maximumLength else { return nil }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }
}

// MARK: - 文案

/// 引导里的每一句话（唯一出处，由 OnboardingCopyTests / SettingsCopyBudgetTests 量）。
/// 5.3.0 按 Apple 系统提示的口吻重写（UX 方案 §3 H）：没有「请」、没有感叹号、没有长破折号。
enum OnboardingCopy {

    // MARK: 每一屏都有的

    /// 右上角那条小字 = 关窗（不算走完，下次启动接着来）
    static var later: String { tr("稍后", "Later") }
    static var continueLabel: String { tr("继续", "Continue") }
    static var backLabel: String { tr("上一步", "Back") }

    /// 唯一的出口（用户 2026-09-20 拍板）。做成一条链接而不是按钮（①②）：它不是「继续」的
    /// 同级选项，而是"我知道会怎样，先这样"。③ 那一处是一颗安静的按钮（用户 2026-09-29 拍板）。
    static var skipForNow: String { tr("先跳过", "Skip for now") }

    /// 点过「先跳过」之后露出来的那一行。只说事实，不劝也不吓唬
    static var dictationUnavailable: String {
        tr("听写暂不可用", "Dictation will not work yet")
    }

    /// ③ 那颗按钮点不动（权限还缺）时，下面那一行说的是**为什么**
    static var permissionsStillMissing: String {
        tr("还差两项系统权限", "Two system permissions are still missing")
    }

    /// 「开始使用」为什么点不动。nil = 点得动，或者卡的是 Key（那一件在 ③ 有自己的一行）
    static func finishBlockedReason(_ essentials: FirstRunEssentials) -> String? {
        if !essentials.permissionsGranted { return permissionsStillMissing }
        return nil
    }

    // MARK: ① 按住右 Option (⌥) 说话

    /// 标题就是那个手势。键名走 HotkeyChoice（只有右 Option 一颗），绝不在这里手写
    static var holdTitle: String {
        let key = HotkeyChoice.rightOption.displayName
        return tr("按住\(key) 说话", "Hold \(key) and speak")
    }

    /// 两种手势一行说完（「这是什么」那一屏 5.3.0 并进这里）
    static var gestureLine: String {
        tr("轻点 = 听写 · 按住 = 指令", "Tap = dictate · Hold = command")
    }

    static var allowMicrophone: String { tr("允许麦克风", "Allow the microphone") }
    static var enableAccessibility: String { tr("开启辅助功能", "Turn on Accessibility") }
    static var openLabel: String { tr("打开", "Open") }

    /// 辅助功能那一行的 ⓘ：勾了还不变的那种情况怎么办（细节进 ⓘ，不占屏幕）
    static var permissionsStuckHint: String {
        tr("在系统设置里勾上 MicType；已经勾了还没变勾，就把它删掉再加回来。",
           "Tick MicType in System Settings. If it is ticked and nothing changes here, remove it from the list and add it back.")
    }

    // MARK: ② 贴上你的 OpenAI Key

    /// 5.0.0 起它**不再写「可选」**：识别、润色、指令三件事全在云端，没有 Key 一件都做不了
    static var keyTitle: String { tr("贴上你的 OpenAI Key", "Paste your OpenAI key") }

    static var keySubtitle: String {
        tr("剪贴板里有 Key 会自动填入", "A key on your clipboard fills in by itself")
    }

    // MARK: ③ 试一下

    static var tryTitle: String { tr("试一下", "Try it") }

    /// 给一句能照着念的话：第一次开口的人最怕的是"说什么"
    static var trySubtitle: String {
        let key = HotkeyChoice.rightOption.displayName
        return tr("轻点\(key)，说：明天下午三点开会", "Tap \(key) and say: meeting tomorrow at 3 pm")
    }

    /// 字落进来之后那一行（「它在哪」那一屏 5.3.0 并进这里）。4.3.5 起 MicType 常驻
    /// Dock + 菜单栏，两处都要点名
    static var thatsIt: String {
        tr("就是这样。它在菜单栏和 Dock 里，随时可用。",
           "That's it. It lives in the menu bar and the Dock, ready any time.")
    }

    static var startUsing: String { tr("开始使用", "Get started") }

    /// 登录自启那一行（默认开，不做开关）。照实写系统里的状态：写着"已开启"而系统里没有，
    /// 是这一行最不该出的错（受管的 Mac 上注册可能被挡）
    static func launchAtLogin(on: Bool) -> String {
        on ? tr("登录时自动启动 · 已开启", "Opens at login · On")
           : tr("登录时自动启动 · 未开启", "Opens at login · Off")
    }

    /// Key 还没配好：现在轻点是说不出字的（5.0.0 起识别也要那把 Key）
    static var keyMissingForTryIt: String {
        tr("还没有 Key，回上一屏贴一把", "No key yet. Go back and paste one.")
    }

    // MARK: 预算表

    /// 挂在控件下面、走设置页那条 16 字线的几行（SettingsCopy.allCaptions 把它们并进同一张表）
    static var captions: [String] {
        [dictationUnavailable, permissionsStillMissing, keyMissingForTryIt]
    }

    /// 引导里那些**整句**（标题、副标题、收尾那一行）。另算一条线
    /// （中文 ≤ 60 字、英文 ≤ 200 字符，由 OnboardingCopyTests 量）。
    static var paragraphs: [String] {
        [holdTitle, gestureLine, allowMicrophone, enableAccessibility, permissionsStuckHint,
         keyTitle, keySubtitle,
         tryTitle, trySubtitle, thatsIt, launchAtLogin(on: true), launchAtLogin(on: false)]
    }
}

// MARK: - 窗口高度跟着这一屏的内容走（5.0.1 起；5.0.2 改成直接量）

/// 引导窗口的尺寸算术。**和设置窗口分开**（5.0.2）：设置那套有一条 760 的硬上限，
/// 引导的上限只有一条：**可见屏高 − 120**。
enum OnboardingWindowSizing {
    /// 宽度 640（5.3.0 设计稿 640 × 480）：大字标题与那颗 120 pt 的键帽要留得出呼吸
    static let width: CGFloat = 640
    /// 下限 480（设计稿的高度）。矮于内容的那一屏照常长高（这是地板不是天花板），
    /// 多出来的高度留在内容下面，底部那排导航仍然钉在卡片底（见 OnboardingView 的 VStack）。
    /// 5.0.3 的教训仍然成立：「刚好装下」和「像回事」是两件事，这扇窗是这个产品的门面。
    static let minContentHeight: CGFloat = 480
    /// 离屏幕可见区域上下各留的余量：窗口顶到菜单栏、底到程序坞边上，既难拖也难看
    static let screenMargin: CGFloat = 120

    /// 这一屏该给多高。**纯函数**（单测钉住"够放下 + 不出屏"这两条）。
    static func contentHeight(natural: CGFloat, visibleScreenHeight: CGFloat) -> CGFloat {
        let ceiling = max(minContentHeight, visibleScreenHeight - screenMargin)
        guard natural.isFinite, natural > 0 else { return minContentHeight }
        return min(max(natural.rounded(.up), minContentHeight), ceiling)
    }
}

/// "这一屏的内容变了"的信号（5.0.2 起只当信号用，窗口高度由控制器直接问 NSHostingView 要）
struct OnboardingPageHeightKey: PreferenceKey {
    static var defaultValue: [OnboardingPage: CGFloat] = [:]

    static func reduce(value: inout [OnboardingPage: CGFloat],
                       nextValue: () -> [OnboardingPage: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// 量这一屏的自然高度。内容一变就推一次信号：权限变勾、Key 状态冒出来、语言切换……
    func measuresOnboardingPage(_ page: OnboardingPage) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: OnboardingPageHeightKey.self,
                                   value: [page: geo.size.height])
        })
    }
}

// MARK: - 窗口控制器

/// 窗口是复用的（isReleasedWhenClosed = false），关窗并不会销毁里面那几页，所以
/// "这扇窗这会儿开着没有"是**只有这一层知道**的事实。① 和 ③ 各挂着一个 1 秒轮询，靠它停下来。
final class OnboardingWindowController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = OnboardingWindowController()

    /// 这扇窗开着没有。几页的轮询订阅它来开关；② 只在它为真时读剪贴板
    @Published private(set) var isOpen = false

    private var window: NSWindow?
    /// 装着 OnboardingView 的那个宿主。**窗口高度就是问它要的**（见 applyFittedHeight）
    private var hosting: NSHostingController<OnboardingView>?
    private var langObserver: AnyCancellable?
    private var pageObserver: AnyCancellable?
    private let model = OnboardingModel()
    /// 防抖：一次翻页会连着报好几次变化
    private var resizeWork: DispatchWorkItem?
    /// 这扇窗还没按内容摆过位置：第一次量到高度时居中一次，之后一律保住顶边
    private var needsInitialPlacement = true
    /// 上一次真正下发的内容高度（动画期间靠它判"还用不用再动"）
    private var lastAppliedContentHeight: CGFloat?

    // MARK: 高度跟着内容走

    /// "内容可能变了，该重新量一次了"。视图层每次变化、每次翻页都会叫它。
    func scheduleRemeasure() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyFittedHeight() }
        resizeWork = work
        // 一拍之后再量：翻页那一下 SwiftUI 还没把新页排完，当场量到的是旧页的高度
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// 真正改窗口的那一下。**顶边不动**（算术在 SettingsWindowSizing.frame 里，单测钉死）。
    /// - immediately: 窗口还没露面，当场量、当场定尺寸（不排队、不做动画）
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
        guard !immediately else {
            window.setFrame(target, display: false)
            return
        }
        guard !Theme.reduceMotion else {
            window.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
        }
    }

    /// 打开引导。startAt 用于定点跳转（缺权限 → ①，缺 Key → ②）。
    ///
    /// 两道护栏，护的都是"别把用户自己的状态弄丢"：
    ///   • **窗口已经开着就什么都不重置**，只把它带到前台（他多半正照着 ③ 的提示轻点了一下）；
    ///   • **落点不许跳过还没办完的那一屏**：跳过去的那一屏正是他此刻卡住的地方。
    func show(startAt requested: OnboardingPage = .hold) {
        if let window = window, window.isVisible {
            model.micOK = Permissions.microphoneGranted
            model.axOK = Permissions.isAccessibilityTrusted
            model.refreshKeyReady()
            model.refreshAIReady()
            Log.info("Onboarding already open page=\(model.page.rawValue) "
                     + "requested=\(requested.rawValue) - keeping page and text")
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 重开这扇窗：高度要按新的那一屏重新量（上一轮留下的数字对这一屏不算数）
        lastAppliedContentHeight = nil
        // 上一轮在 ③ 替他开过的登录项，这一轮要重新来一次（见 TryItPage.armLaunchAtLogin）
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
        // 上一遍试出来的那几句同样不留：重走一遍的人看到的应该是一个空框，
        // 而且「开始使用」要他这一遍**再**落一次字
        model.tryItText = ""
        model.tryItReceivedAt = nil
        // 「权限已经齐了就别再把他推走」挂在这里而不是 ① 的 onAppear 上：onAppear 只在页码
        // **变化**时才跑，上次就停在 ① 关掉的窗口再次打开时页码没变
        model.autoAdvanced = page == .hold && model.micOK && model.axOK
        model.refreshKeyReady()
        model.refreshAIReady()
        Log.info("Onboarding show page=\(page.rawValue) aiStatus=\(model.aiStatus) "
                 + model.essentials().logSummary)

        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(model: model))
            // 尺寸由我们自己按内容算（见 applyFittedHeight）。放着不管的话，
            // NSHostingController 会用 preferredContentSize 自己去改窗口大小——
            // 那条路是**从左下角**长的，每翻一页标题栏跳一次
            hosting.sizingOptions = []
            self.hosting = hosting
            let w = NSWindow(contentViewController: hosting)
            // 无边框标题：内容自己撑满，只留一个关闭按钮
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
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
            // 翻页就重量（订阅模型而不是等视图报数，见 5.0.2）
            pageObserver = model.$page.sink { [weak self] _ in self?.scheduleRemeasure() }
        }
        window?.title = tr("欢迎使用 MicType", "Welcome to MicType")
        // **先量再显示**（5.0.3）
        resizeWork?.cancel()
        applyFittedHeight(immediately: true)
        // ③ 的直接落字通道：窗口一开就挂上，关掉时摘下来
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
    /// 返回 false = 这一刻接不住，调用方必须退回别的路，绝不能让文字掉在地上。
    @discardableResult
    func acceptTranscript(_ text: String) -> Bool {
        guard Thread.isMainThread else {
            Log.warn("Try-it sink called off the main thread - falling back to paste")
            return false
        }
        guard isOnTryItPage else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        withAnimation(Theme.springOrNone) {
            model.appendTryItText(trimmed)
        }
        // 只记字数，绝不记内容：日志里永远看不到用户说了什么
        Log.info("Onboarding try-it received chars=\(trimmed.count)")
        return true
    }

    /// ③ 的「开始使用」。**只有这一下和「先跳过」会把 onboardingCompleted 写真**。
    func finish() {
        // 权限在这里**现问一次**，不读页面轮询留下的那两位（理由同 5.0.x：
        // 在 ③ 才补上权限的人，旧的那两位还写着 false）
        let essentials = FirstRunEssentials.current()
        model.micOK = essentials.microphone
        model.axOK = essentials.accessibility
        // 按钮只在"三件事齐了 + 真落过字"时才是「开始使用」；⌘⏎ 那个默认动作同样不许绕过它
        guard (essentials.canFinish && model.tryItLanded) || model.skippedEssentials else {
            Log.warn("Onboarding finish blocked \(essentials.logSummary) landed=\(model.tryItLanded)")
            return
        }
        Settings.shared.onboardingCompleted = true
        // 齐活之后收尾：把"带着缺口走的"那一位清掉
        if essentials.canFinish { Settings.shared.onboardingSkippedEssentials = false }
        Log.info("Onboarding finished \(essentials.logSummary) skipped=\(model.skippedEssentials)"
                 + " landed=\(model.tryItLanded)")
        window?.close()
    }

    /// 「先跳过」：走出引导的**唯一**出口（①② 那条链接）。
    ///
    /// 写两处状态：引导从此不再每次启动拦他（onboardingCompleted），以及"他是带着没办完的事走的"
    /// （onboardingSkippedEssentials）。不替他补任何东西，也不再劝一次。
    func skipEssentials() {
        model.skippedEssentials = true
        Settings.shared.onboardingSkippedEssentials = true
        Settings.shared.onboardingCompleted = true
        Log.warn("Onboarding essentials skipped at page=\(model.page.rawValue) "
                 + model.essentials().logSummary)
    }

    /// ③ 那颗安静的「先跳过」（没落过字的时候）：走同一条 skipEssentials，然后关窗。
    /// 三件必办的事其实都齐了的话（他只是没试），那个"带着缺口走"的标记当场清掉——
    /// 它会让以后 Key 真没了时不再把他接回引导，而他并没有缺什么
    func skipFromTryIt() {
        skipEssentials()
        let essentials = FirstRunEssentials.current()
        if essentials.canFinish { Settings.shared.onboardingSkippedEssentials = false }
        Log.info("Onboarding closed from try-it without a landed transcript "
                 + essentials.logSummary)
        window?.close()
    }

    /// 右上角「稍后」= 关窗。**不算走完**：下次启动接在没办完的那一屏
    func closeForLater() {
        Log.info("Onboarding later tapped at page=\(model.page.rawValue)")
        window?.close()
    }

    /// 中途关窗**不算走完**（用户 2026-09-20 拍板）
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        // 窗口没了就别再截留文字：摘干净，之后的听写照常粘到光标处
        TranscriptSink.unregister()
        isOpen = false
        Log.info("Onboarding closed at page=\(model.page.rawValue) "
                 + "completed=\(Settings.shared.onboardingCompleted)")
        // 引导一关，屏幕上就一扇窗都不剩了——这正是"它去哪了"的那一刻
        LaunchNotice.flash(.running, after: LaunchNotice.afterOnboardingDelay)
    }
}

// MARK: - 主界面

/// 外面一圈底色、里面一张卡片（设计稿 640 × 480：卡片四周 24 pt）。
/// 跟系统外观走（Theme.palette）：浅色模式下是 #F5F5F7 底 + 白卡片，不是简单反色。
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Theme.palette(scheme)
        VStack(spacing: 0) {
            topBar
            Group {
                switch model.page {
                case .hold: HoldPage(model: model)
                case .key: KeyPage(model: model)
                case .tryIt: TryItPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .transition(Theme.appear)
            .id(model.page)
            Spacer(minLength: 20)
            footer
        }
        .padding(.horizontal, 40)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(palette.surface)
                .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.12), radius: 24, x: 0, y: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(scheme == .dark ? Theme.hairline : Color.black.opacity(0.06), lineWidth: 1))
        .padding(24)
        .frame(width: OnboardingWindowSizing.width)
        .background(palette.bg)
        .foregroundColor(palette.text)
        // 高度**不写死**：窗口按这一屏的自然高度伸缩（控制器直接量 NSHostingView）
        .onPreferenceChange(OnboardingPageHeightKey.self) { _ in
            OnboardingWindowController.shared.scheduleRemeasure()
        }
    }

    // MARK: 顶上那一行：语言（只在 ①）+「稍后」

    private var topBar: some View {
        HStack {
            // 界面语言跟系统走，跟错了的话这个人从第一屏起就在读他看不懂的字——
            // 而设置窗口里的那个入口他还没见过。只在 ① 摆（之后他已经选过了）
            if model.page == .hold { languagePicker }
            Spacer()
            Button(OnboardingCopy.later) {
                OnboardingWindowController.shared.closeForLater()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(Theme.palette(scheme).muted)
        }
        .frame(height: 22)
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
        .controlSize(.small)
        .fixedSize()
    }

    // MARK: 底部：上一步 · 页码点 ·（先跳过）继续

    private var footer: some View {
        ZStack {
            dots
            HStack(spacing: 12) {
                if model.page != .hold {
                    Button(OnboardingCopy.backLabel) { step(-1) }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.palette(scheme).muted)
                }
                Spacer()
                // 唯一的出口：一条小链接，不是一颗和「继续」平起平坐的按钮
                if showsSkipLink {
                    Button(OnboardingCopy.skipForNow) {
                        OnboardingWindowController.shared.skipEssentials()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.palette(scheme).muted)
                }
                // ③ 没有「继续」：那一屏的按钮在内容里（「开始使用」/「先跳过」）
                if model.page != .tryIt {
                    MTButton(title: OnboardingCopy.continueLabel,
                             style: continueReady ? .primary : .quiet,
                             adaptive: true) { step(1) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(continueDisabled)
                }
            }
        }
        .frame(height: 34)
    }

    /// 三个点：当前那一个是 18 × 6 的渐变胶囊（设计稿），其余是 6 pt 的淡点
    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingPage.allCases, id: \.rawValue) { page in
                if page == model.page {
                    Capsule().fill(Theme.accentGradient).frame(width: 18, height: 6)
                } else {
                    Capsule()
                        .fill(scheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.14))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("第 \(model.page.rawValue + 1) 步，共 \(OnboardingPage.allCases.count) 步",
                               "Step \(model.page.rawValue + 1) of \(OnboardingPage.allCases.count)"))
    }

    private var essentials: FirstRunEssentials { model.essentials() }

    /// 这一屏要办的事办好了：「继续」变成主按钮（渐变）
    private var continueReady: Bool {
        switch model.page {
        case .hold: return essentials.permissionsGranted
        case .key: return essentials.keyReady
        case .tryIt: return false
        }
    }

    /// 拦人的判据：这一屏要办的事没办好、又没点过「先跳过」
    private var continueDisabled: Bool {
        guard !model.skippedEssentials else { return false }
        return !continueReady
    }

    /// 出口只在"确实卡住了"的那两屏露面（与「继续」同一条判据）
    private var showsSkipLink: Bool {
        guard !model.skippedEssentials, model.page != .tryIt else { return false }
        return !continueReady
    }

    private func step(_ delta: Int) {
        let next = max(0, min(OnboardingPage.allCases.count - 1, model.page.rawValue + delta))
        guard let page = OnboardingPage(rawValue: next) else { return }
        withAnimation(Theme.springOrNone) { model.page = page }
    }
}

// MARK: - 共用：大标题 + 副标题

private struct PageHeading: View {
    let title: String
    let subtitle: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundColor(Theme.palette(scheme).muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 一行橙色小字（「听写暂不可用」「还差两项系统权限」…）
private struct WarningLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.orange)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - ① 按住右 Option (⌥) 说话

private struct HoldPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    /// 1 秒一次的轮询：用户在系统设置里打开开关后，这里自己变勾，不需要重启、也不必再点一次。
    /// **只在窗口开着时轮**（窗口复用，关掉之后这一页并不会消失）
    @State private var poll: AnyCancellable?
    @ObservedObject private var windowState = OnboardingWindowController.shared

    var body: some View {
        VStack(spacing: 0) {
            OptionKeyCap()
                .padding(.top, 14)
            PageHeading(title: OnboardingCopy.holdTitle, subtitle: OnboardingCopy.gestureLine)
                .padding(.top, 28)
            VStack(spacing: 8) {
                PermissionRow(title: OnboardingCopy.allowMicrophone, ok: model.micOK) {
                    Permissions.ensureMicrophone { granted in
                        model.micOK = granted
                        // notDetermined 以外的状态系统不再弹窗，只能引导去设置里手动开
                        if !granted { Permissions.openMicrophoneSettings() }
                    }
                }
                PermissionRow(title: OnboardingCopy.enableAccessibility, ok: model.axOK,
                              info: OnboardingCopy.permissionsStuckHint) {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }
            .padding(.top, 26)
            // 点过「先跳过」之后露出来的那一行：一句话，没有第二句
            if model.skippedEssentials && !(model.micOK && model.axOK) {
                WarningLine(text: OnboardingCopy.dictationUnavailable)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .measuresOnboardingPage(.hold)
        .onAppear {
            // 进页时权限就已经齐了（点「上一步」回来看一眼）：别再把他自动推走
            if model.micOK, model.axOK { model.autoAdvanced = true }
            startPolling()
        }
        .onDisappear { stopPolling() }
        .onChange(of: windowState.isOpen) { _, open in
            if open { startPolling() } else { stopPolling() }
        }
    }

    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                let mic = Permissions.microphoneGranted
                let ax = Permissions.isAccessibilityTrusted
                withAnimation(Theme.springOrNone) {
                    if mic != model.micOK { model.micOK = mic }
                    if ax != model.axOK { model.axOK = ax }
                }
                model.refreshKeyReady()
                advanceIfPermissionsJustLanded()
            }
    }

    private func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    /// 权限刚刚齐活：0.6 s 后自己往下翻一页（UX 方案 §3 B）。**只翻一次**——
    /// 从下一屏点「上一步」回来的人是专程回来看的，再把他推走就成了跟用户较劲。
    private func advanceIfPermissionsJustLanded() {
        guard model.micOK, model.axOK, !model.autoAdvanced, model.page == .hold else { return }
        model.autoAdvanced = true
        Log.info("Onboarding permissions granted, advancing")
        // 慢半拍：让两枚勾先描完（0.25 s），用户才看得出"是它自己好了"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard model.page == .hold, windowState.isOpen else { return }
            withAnimation(Theme.springOrNone) { model.page = .key }
        }
    }
}

/// 那颗发光的右 Option 键：120 × 88、品牌渐变、白色 ⌥、柔和光晕（设计稿 Onboarding-1）。
/// 光晕慢慢呼吸——"按这里"不用一个字；「减少动态效果」开着就静止。
private struct OptionKeyCap: View {
    @State private var breathing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Theme.accentGradient)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1))
            // 键帽的立体感：顶上一道亮边、底下一道暗边（设计稿的两层 inset 阴影）
            .overlay(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.3)).frame(height: 1).padding(.horizontal, 14)
                    .padding(.top, 1)
            }
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.22))
                    .frame(height: 3)
                    .mask(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .overlay(
                Text("⌥")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundColor(.white))
            .frame(width: 120, height: 88)
            .shadow(color: Theme.accentB.opacity(breathing ? 0.55 : 0.35), radius: 14)
            .shadow(color: Theme.accentA.opacity(breathing ? 0.3 : 0.18), radius: 28)
            .onAppear {
                guard !Theme.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
            .accessibilityLabel(HotkeyChoice.rightOption.displayName)
    }
}

/// 一项权限：状态圆（未办 = 灰圈；办好 = 渐变圆 + 描出来的白勾）+ 名字 + 「打开」
private struct PermissionRow: View {
    let title: String
    let ok: Bool
    var info: String? = nil
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if ok { MTCheckCircle(size: 22) } else { MTPendingCircle(size: 20) }
            }
            .frame(width: 22, height: 22)
            Text(title)
                .font(.system(size: 14))
            Spacer()
            if !ok {
                if let info = info { InfoButton(info) }
                MTButton(title: OnboardingCopy.openLabel, style: .quiet, adaptive: true, action: action)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06),
                        lineWidth: 1))
    }
}

// MARK: - ② 贴上你的 OpenAI Key

/// 一屏只做一个动作：把 Key 贴进来（或者照三步去拿一把）。
/// **控件与设置正页共用**（CloudSetupCore / KeyEntryView）：验证、存钥匙串、状态文案只写一处。
private struct KeyPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    /// 这一屏出现时从剪贴板认出来的那把 Key。**每次进这一屏只读一次**（页面按页码重建，
    /// @State 跟着重来），不轮询
    @State private var prefill: String?
    /// 剪贴板看过了没有。Key 框要等它看完才出现：KeyEntryView 在自己的 onAppear 里载入，
    /// 早于这里的话，那一刻 prefill 还是空的
    @State private var clipboardChecked = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeading(title: OnboardingCopy.keyTitle, subtitle: OnboardingCopy.keySubtitle)
                .padding(.top, 20)
            VStack(alignment: .leading, spacing: 0) {
                if clipboardChecked {
                    CloudSetupCore(style: .onboarding,
                                   onKeyStatus: { _ in
                                       model.refreshKeyReady()
                                       model.refreshAIReady()
                                   },
                                   prefill: prefill) {
                        EmptyView()
                    }
                } else {
                    Color.clear.frame(height: 44)
                }
            }
            .padding(.top, 28)
            if model.skippedEssentials && !model.keyReady {
                WarningLine(text: OnboardingCopy.dictationUnavailable)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .measuresOnboardingPage(.key)
        .onAppear {
            model.refreshKeyReady()
            model.refreshAIReady()
            // 只有真开着引导窗口时才读剪贴板：这一页还会被**离屏渲染**（快照 / 高度测试），
            // 那一刻绝不能把测试机剪贴板里的东西拿去发一次验证请求
            if OnboardingWindowController.shared.isOpen {
                prefill = ClipboardKey.candidate(from: NSPasteboard.general.string(forType: .string))
                if prefill != nil { Log.info("Onboarding found a key-shaped string on the clipboard") }
            }
            clipboardChecked = true
        }
    }
}

// MARK: - ③ 试一下

private struct TryItPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var l10n = L10n.shared
    @FocusState private var editorFocused: Bool
    @Environment(\.colorScheme) private var scheme
    /// 权限与 Key 的状态靠这个 1 秒轮询刷新（两者都可能在这一页上被补齐）
    @State private var readinessPoll: AnyCancellable?
    @ObservedObject private var windowState = OnboardingWindowController.shared
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        let palette = Theme.palette(scheme)
        VStack(spacing: 0) {
            PageHeading(title: OnboardingCopy.tryTitle, subtitle: OnboardingCopy.trySubtitle)
                .padding(.top, 6)
            TextEditor(text: $model.tryItText)
                .font(.system(size: 17))
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 120)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.bg))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(model.tryItLanded ? Theme.accentText.opacity(0.45)
                                : (scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)),
                                lineWidth: 1))
                .padding(.top, 22)
                .accessibilityLabel(tr("试写区", "Try-it box"))

            // Key 还没配好：现在轻点是说不出字的
            if !model.keyReady {
                WarningLine(text: OnboardingCopy.keyMissingForTryIt)
                    .padding(.top, 10)
            }
            if model.skippedEssentials && !model.essentials().canFinish {
                WarningLine(text: OnboardingCopy.dictationUnavailable)
                    .padding(.top, 10)
            }
            if !model.skippedEssentials,
               let reason = OnboardingCopy.finishBlockedReason(model.essentials()) {
                WarningLine(text: reason)
                    .padding(.top, 10)
            }

            if canStart {
                Text(OnboardingCopy.thatsIt)
                    .font(.system(size: 13))
                    .foregroundColor(palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                    .transition(Theme.appear)
                MTButton(title: OnboardingCopy.startUsing, style: .primary, adaptive: true) {
                    OnboardingWindowController.shared.finish()
                }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 14)
                .transition(Theme.appear)
            } else {
                MTButton(title: OnboardingCopy.skipForNow, style: .quiet, adaptive: true) {
                    OnboardingWindowController.shared.skipFromTryIt()
                }
                .padding(.top, 18)
            }

            // 登录自启：默认开、不做开关（UX 方案 §3 B）。点它去系统的登录项——
            // 那是唯一能把它关掉的地方，而这一行不值一颗开关
            Button(OnboardingCopy.launchAtLogin(on: launchAtLogin)) {
                Log.info("Onboarding opened Login Items from the try-it page")
                SMAppService.openSystemSettingsLoginItems()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(palette.muted)
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.springOrNone, value: canStart)
        .measuresOnboardingPage(.tryIt)
        // 上一屏可能刚粘好 Key：进这一屏现算一次
        .onAppear {
            model.refreshAIReady()
            refreshPermissions()
            model.refreshKeyReady()
            armLaunchAtLogin()
            // 稍等一拍再抢焦点：窗口刚翻页时 TextEditor 还没进响应链，立刻 focus 会落空。
            // 焦点只影响用户自己打字——识别结果不靠它，走的是直接落字（TranscriptSink）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { editorFocused = true }
            startReadinessPolling()
        }
        .onDisappear { stopReadinessPolling() }
        .onChange(of: windowState.isOpen) { _, open in
            if open { startReadinessPolling() } else { stopReadinessPolling() }
        }
    }

    /// 「开始使用」出现的条件：三件必办的事齐了 **而且** 这一屏真落过一次字
    private var canStart: Bool {
        model.tryItLanded && model.essentials().canFinish
    }

    /// 权限那两位在这一页也要续着刷（在这一页才补上权限的人，旧的那两位还是 false）。
    /// 只在窗口真开着时刷：离屏渲染（快照）里摆好的状态不该被测试机的真实权限冲掉
    private func refreshPermissions() {
        guard windowState.isOpen else { return }
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
                model.refreshKeyReady()
            }
    }

    private func stopReadinessPolling() {
        readinessPoll?.cancel()
        readinessPoll = nil
    }

    /// 「默认开」是怎么实现的：第一次走到这一屏时，**替他真的注册一次**登录项。
    /// 不只是把那一行写成"已开启"——那样他看到的是"已开"、系统里却没有。
    /// 这一轮只做一次（model.launchAtLoginArmed）。
    private func armLaunchAtLogin() {
        let enabled = SMAppService.mainApp.status == .enabled
        launchAtLogin = enabled
        // 只有真的开着引导窗口时才去动系统登录项。这一页还会被**离屏渲染**（快照测试），
        // 那一刻绝不能顺手改掉这台机器上的登录项——读一下状态可以，写下去不行
        guard OnboardingWindowController.shared.isOpen else { return }
        guard !model.launchAtLoginArmed else { return }
        model.launchAtLoginArmed = true
        guard !enabled else { return }
        do {
            try SMAppService.mainApp.register()
            Log.info("Onboarding launch at login on=true")
        } catch {
            // 受管的 Mac 上可能被 MDM 挡住：原因只进日志（系统那句话可能是另一种语言），
            // 那一行照实写"未开启"
            Log.warn("Onboarding launch at login failed error=\(error)")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}
