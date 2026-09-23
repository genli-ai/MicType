import SwiftUI
import AppKit
import Combine

// MARK: - 设置窗口

/// **设置就是一页**（用户 2026-09-22 拍板，5.0.0）：服务商、API Key、（阿里云的）接入地址。
///
/// 为什么能砍到这个程度：识别、润色、语音指令三件事现在共用一把 Key、一个写死的型号、
/// 一条自己试出来的地址——4.x 那些开关（使用方式 / 识别引擎 / 识别语言 / 模型 / 润色档位 /
/// 云端识别 / 联网搜索 / 麦克风 / 本机模型）全都没有第二个答案了。而 4.1 那套
/// 「概览卡片 + 点进编辑页」是为"有四页设置"这个前提做的：只剩一页之后，
/// 那一层卡片就纯粹是多一次点击。
///
/// 剩下两页都是**从底部那排小字点开的**，不是首页的一部分：
///   • 专有词汇表（词汇表 + 自定义规则）——改得不勤，但改的是用户自己的文字；
///   • 关于（版本 / 更新 / 诊断 / 备份 / 隐私六句）。
enum SettingsRoute: String, Hashable, CaseIterable {
    /// **这一页就是设置**：服务商 + Key +（阿里云的）接入地址 + 权限横幅 + 脚注四个链接
    case overview
    /// 专有词汇表 + 自定义规则（5.0.2 之前这一页叫「写作偏好」）
    case writing
    /// 版本 / 更新 / 诊断 / 作者 + 隐私与费用（PrivacyCopy 在设置里**只**出现在这里）
    case about

    // `.input`（输入页）与 `.cloud`（云端 AI 页）5.0.0 合并进 `.overview`：
    // 设置只剩一页之后，它们各自剩下的那点内容要么是这一页本身，要么进了「专有词汇表」。

    /// 子页顶栏的标题。设置正页没有顶栏（它就是首页，没有"返回"可言）
    var editorTitle: String? {
        switch self {
        case .overview: return nil
        // 页名只写一处（脚注那条链接念的是同一串）
        case .writing: return SettingsCopy.vocabularyPageTitle
        case .about: return tr("关于 MicType", "About MicType")
        }
    }
}

// MARK: - 窗口尺寸的算术（纯函数）

/// 设置窗口高度**跟着当前这一页的内容走**（用户 2026-09-21 拍板：窗口比里面的东西大太多）。
///
/// 4.1.5 之前这扇窗硬写着 560 × 520：概览只有三张卡加一行脚注，下面空着小半屏；
/// 短一点的编辑页同样空一大块。而 520 又不够高——「云端 AI」页照样要滚。
/// 一个既太大又不够大的数字，是因为它跟内容毫无关系。
///
/// 算术收在这里、写成纯函数，是因为它有三条互相打架的约束（最小、最大、不许伸出屏幕），
/// 而"改一次高度顺手把某一条挪没了"这种事在视图代码里看不出来。
enum SettingsWindowSizing {
    /// 宽度不变。整套文案与控件的换行都是按这个宽度调出来的
    static let width: CGFloat = 560

    /// 下限。5.0.0 从 300 降到 220：设置正页只剩三行控件加一行脚注，实测自然高度约
    /// 230——钉在 300 的话，窗口底下会空出一整块，正好是这一版要消掉的那种"比内容大"。
    /// 再低就不给了：一扇比一张卡还矮的窗口，点进点出时像在抽搐。
    static let minContentHeight: CGFloat = 220

    /// 上限：再高也不该占满整块屏。超过就让这一页自己滚。
    /// 760 这个数留着不动：现在最高的是「关于」页（隐私六句 + 两排按钮），
    /// 13 寸 MacBook Air 的可见高度 868 − 余量 120 = 748，仍然装得下它。
    static let maxContentHeight: CGFloat = 760

    /// 离屏幕可见区域上下各留出来的余量：窗口顶到菜单栏、底到程序坞边上，既难拖也难看
    static let screenMargin: CGFloat = 120

    /// 这一页的自然高度 → 窗口的内容高度。
    /// - natural: 页面内容量出来的高度（0 = 还没量到，按下限给）
    /// - visibleScreenHeight: 这块屏幕的 visibleFrame 高度（已经扣掉菜单栏与程序坞）
    static func contentHeight(natural: CGFloat, visibleScreenHeight: CGFloat) -> CGFloat {
        // 屏幕很矮（外接小屏、分屏）时，上限跟着屏幕降——但绝不降到下限以下：
        // 那样窗口会矮到连三张卡都摆不开，而下面那条"不许伸出屏幕"还会把它往上推
        let ceiling = max(minContentHeight, min(maxContentHeight, visibleScreenHeight - screenMargin))
        guard natural.isFinite, natural > 0 else { return minContentHeight }
        return min(max(natural.rounded(.up), minContentHeight), ceiling)
    }

    /// 新的窗口 frame。**顶边不动**（origin.y 跟着高度差走）：AppKit 的坐标原点在左下角，
    /// 直接改 size 的话窗口是往下长的，标题栏会在每次翻页时跳一下——那是这次改动里
    /// 最容易被忽略、也最显眼的一个毛病。
    /// - frameHeight: 含标题栏的整窗高度（内容高度由 frameRect(forContentRect:) 换算）
    /// - visible: 这块屏幕的 visibleFrame
    static func frame(current: CGRect, frameHeight: CGFloat, visible: CGRect) -> CGRect {
        var next = current
        next.size.width = width
        next.size.height = frameHeight
        next.origin.y = current.maxY - frameHeight
        // 长高之后不许伸到可见区域下面去（底边被程序坞压住 = 那几行永远读不到）
        if next.minY < visible.minY { next.origin.y = visible.minY }
        // 上面那一推可能把顶边顶出屏幕（窗口比可见区域还高时）：再压回来。
        // 顺序不能反——伸出屏幕底部是"内容看不见"，伸出顶部是"标题栏抓不到"，后者更糟
        if next.maxY > visible.maxY { next.origin.y = visible.maxY - frameHeight }
        return next
    }
}

/// 这一页有多高。**带着路由一起报**：滑动期间新旧两页同时活在 ZStack 里，各报各的高度，
/// 而窗口要按**目的页**定尺寸——只按"最大的那个"来的话，从长页退回概览时窗口会卡在长页的高度上。
struct SettingsPageHeightKey: PreferenceKey {
    static var defaultValue: [SettingsRoute: CGFloat] = [:]

    static func reduce(value: inout [SettingsRoute: CGFloat],
                       nextValue: () -> [SettingsRoute: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// 顶栏（返回 + 页名 + 分隔线）有多高。概览没有顶栏，所以它是一条单独的量
struct SettingsChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// 把这块内容的自然高度报给窗口
    func measuresSettingsPage(_ route: SettingsRoute) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: SettingsPageHeightKey.self,
                                   value: [route: geo.size.height])
        })
    }
}

/// 编辑页的外壳：**一个**滚动容器 + 一次高度测量。
///
/// 为什么不能直接量 Form：`Form(.grouped)` 自己带着一层滚动，而滚动容器永远把给它的高度
/// 占满——问它"你多高"，答案恒等于窗口那么高，量了等于没量。所以先把它 `fixedSize` 成
/// 内容高度（它那层滚动从此没有东西可滚），再套一个我们自己的滚动容器。
/// 整页真会滚的仍然只有一个。
struct MeasuredFormPage<Content: View>: View {
    let route: SettingsRoute
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .frame(width: SettingsWindowSizing.width)
                .fixedSize(horizontal: false, vertical: true)
                .measuresSettingsPage(route)
        }
        // 内容装得下时不要橡皮筋：一扇刚好合身的窗口还能上下拽动，看着就是没做好
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// 现在停在哪一页。窗口是复用的（isReleasedWhenClosed = false），深链又来自 AppKit 那一侧
/// （菜单栏 / 悬浮窗，拿不到 SwiftUI 的 @State），所以当前路由必须是外部可写的共享状态——
/// 否则第二次 show(tab:) 就翻不动页。
final class SettingsNavigator: ObservableObject {
    static let shared = SettingsNavigator()

    /// 「关于」页是从脚注哪个链接进来的：三个链接落在同一页，但要的东西不一样。
    enum AboutIntent: Equatable {
        case none
        /// 「隐私」：滚到隐私那一段
        case privacy
        /// 「检查更新」：进去就开始查（他点的就是这个动作，不该再让他找一次按钮）
        case checkUpdate
    }

    @Published private(set) var route: SettingsRoute = .overview
    /// 这一跳是往里走还是往回走——决定新页从右边还是左边滑进来
    @Published private(set) var goingForward = true
    /// 每次跳转都换一个号：关于页据此判断"这是一次新的进入"，哪怕路由没变（已经在关于页时
    /// 又点了脚注的「隐私」）。用计数而不是把 intent 清空，是因为清空要由消费方写回
    /// @Published，会在同一次渲染里再触发一轮更新。
    @Published private(set) var visitCount = 0
    private(set) var aboutIntent: AboutIntent = .none

    private init() {}

    /// 系统的「减弱动态效果」。滑动是这套导航唯一的装饰，开了就干脆不滑
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func go(to next: SettingsRoute, intent: AboutIntent = .none) {
        aboutIntent = intent
        move(to: next, forward: next != .overview)
    }

    /// 顶栏的「‹ 设置」与 Esc 都走这里
    func back() {
        aboutIntent = .none
        move(to: .overview, forward: false)
    }

    private func move(to next: SettingsRoute, forward: Bool) {
        goingForward = forward
        visitCount &+= 1
        guard next != route else { return }
        if Self.reduceMotion {
            route = next
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { route = next }
        }
    }
}

/// 窗口是复用的，所以"它这会儿开着没有"是**这一层唯一知道**的事实：关窗不会销毁里面那一页。
/// 概览的权限轮询据此停下——否则它会一路轮到退出为止（4.0.2 就是这样）。
final class SettingsWindowController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = SettingsWindowController()

    /// 这扇窗开着没有。概览订阅它来开关权限轮询
    @Published private(set) var isOpen = false

    private var window: NSWindow?
    private var langObserver: AnyCancellable?
    /// 最近一次量到的内容高度（顶栏 + 当前页）。nil = 还没量到过
    private var pendingContentHeight: CGFloat?
    /// 防抖：一次翻页会连着报好几个高度（旧页退场、新页登场、状态行冒出来），
    /// 每一条都跑一次动画的话，窗口会在半秒里抖三下
    private var resizeWork: DispatchWorkItem?
    /// 这扇窗还没按内容摆过位置：第一次量到高度时居中一次，之后一律保住顶边
    private var needsInitialPlacement = true

    private override init() { super.init() }

    // MARK: 高度跟着内容走

    /// 当前这一页量出来的高度。视图层每次变化都会叫这里，具体改不改窗口由防抖那一跳决定。
    func fitContentHeight(_ natural: CGFloat) {
        guard natural > 0 else { return }
        pendingContentHeight = natural
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyPendingHeight() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// 真正改窗口的那一下。**顶边不动**（算术在 SettingsWindowSizing.frame 里，单测钉死）。
    private func applyPendingHeight() {
        guard let window = window, let natural = pendingContentHeight else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let content = SettingsWindowSizing.contentHeight(natural: natural,
                                                         visibleScreenHeight: visible.height)
        // 内容高度 → 整窗高度：标题栏的厚度由 AppKit 说了算，别在代码里猜一个数字
        let frameHeight = window.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: SettingsWindowSizing.width, height: content)).height
        guard needsInitialPlacement == false else {
            // 头一回：先定尺寸再居中——按 520 居中完再长高，窗口会明显偏上
            window.setContentSize(NSSize(width: SettingsWindowSizing.width, height: content))
            window.center()
            needsInitialPlacement = false
            return
        }
        let target = SettingsWindowSizing.frame(current: window.frame, frameHeight: frameHeight,
                                                visible: visible)
        // 半个点的差别不值一次动画（浮点测量每帧都会抖一点点）
        guard abs(target.height - window.frame.height) > 0.5
                || abs(target.origin.y - window.frame.origin.y) > 0.5 else { return }
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

    /// - tab: 深链要停在哪一页；nil = 回概览。
    ///   为什么 nil 不再是"保持上次的位置"：概览就是这个窗口的首页，打开设置的人第一眼
    ///   该看到的是"现在是什么状态"，而不是上次退出时停在的某个编辑页。
    /// - intent: 落到「关于」页时顺带要做的事（进去就开始查更新）
    func show(tab: SettingsRoute? = nil, intent: SettingsNavigator.AboutIntent = .none) {
        SettingsNavigator.shared.go(to: tab ?? .overview, intent: intent)
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            // 高度由我们自己按内容算（见 fitContentHeight）。放着不管的话，
            // NSHostingController 会用 preferredContentSize 自己去改窗口大小——
            // 那条路是**从左下角**长的，标题栏每翻一页跳一次
            hosting.sizingOptions = []
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            // 关窗要有人知道：里面那一页不会跟着消失，得由这里告诉它停手
            w.delegate = self
            // 先按下限开着，量到真实高度立刻跟上（第一次测量会顺手居中一次）
            w.setContentSize(NSSize(width: SettingsWindowSizing.width,
                                    height: SettingsWindowSizing.minContentHeight))
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
        isOpen = true
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        isOpen = false
    }
}

// MARK: - 设置界面（概览 ←→ 编辑页）

struct SettingsView: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var nav = SettingsNavigator.shared

    /// 每一页最近报上来的自然高度。翻页时新旧两页都在报，所以按路由存
    @State private var pageHeights: [SettingsRoute: CGFloat] = [:]
    /// 顶栏 + 分隔线这一条的高度（概览没有顶栏，它是 0）
    @State private var chromeHeight: CGFloat = 0
    /// 这扇窗归不归我们管尺寸。快照测试直接把某一页塞进自己的 NSWindow 里渲染，
    /// 那时候没有设置窗口可改——**绝不能**让它去动一扇不属于这次渲染的窗口
    var resizesWindow: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if let title = nav.route.editorTitle {
                header(title: title)
                Divider()
            }
            // 滑动期间新旧两页同时存在：套一层 ZStack，免得它们在 VStack 里上下叠成两屏高
            ZStack {
                page
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 高度**不再写死**（4.1.5 之前是 520，和里面装了什么毫无关系）：
        // 窗口按当前这一页量出来的高度伸缩，见 SettingsWindowSizing
        .frame(width: SettingsWindowSizing.width)
        // 滑动时别把半页画到窗口外面
        .clipped()
        .onPreferenceChange(SettingsPageHeightKey.self) { heights in
            pageHeights = heights
            pushHeightToWindow()
        }
        .onPreferenceChange(SettingsChromeHeightKey.self) { height in
            chromeHeight = height
            pushHeightToWindow()
        }
        // 翻页这一下本身也要改窗口：目的页的高度可能早就量好了（它上一次来过）
        .onChange(of: nav.route) { _, _ in pushHeightToWindow() }
    }

    /// 窗口该有多高 = 顶栏 + **目的页**的自然高度。
    /// 按 nav.route 取而不是取最大值：滑动期间两页并存，取最大的话从长页退回概览时，
    /// 窗口会卡在长页那个高度上不下来。
    private func pushHeightToWindow() {
        guard resizesWindow, let page = pageHeights[nav.route], page > 0 else { return }
        SettingsWindowController.shared.fitContentHeight(chromeHeight + page)
    }

    @ViewBuilder
    private var page: some View {
        Group {
            switch nav.route {
            case .overview: MainSettingsPage()
            case .writing: WritingPreferencesEditor()
            case .about: AboutPanel()
            }
        }
        .id(nav.route)
        .transition(transition)
    }

    /// 往里走从右边进、往回走从左边进——这是这套导航里唯一的方向感来源。
    /// 系统开了「减弱动态效果」就一动不动（.identity）。
    private var transition: AnyTransition {
        guard !SettingsNavigator.reduceMotion else { return .identity }
        let forward = nav.goingForward
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading),
                           removal: .move(edge: forward ? .leading : .trailing))
    }

    /// 编辑页顶栏：一颗返回 + 页名。返回键同时挂在 Esc 上（.cancelAction）——
    /// 编辑页没有"取消"的概念（改动即时生效），Esc 的唯一含义就是"回上一层"。
    private func header(title: String) -> some View {
        HStack(spacing: 8) {
            Button {
                SettingsNavigator.shared.back()
            } label: {
                Text(tr("‹ 设置", "‹ Settings"))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            Text(title)
                .fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // 顶栏的高度进窗口那笔账：它不是常数（字号跟着系统走），猜一个数字迟早会差出一行
        .background(GeometryReader { geo in
            Color.clear.preference(key: SettingsChromeHeightKey.self,
                                   // +1：下面那条 Divider
                                   value: geo.size.height + 1)
        })
    }
}

// MARK: - 共用控件

/// 段头：标题 + 一颗 ⓘ。**长说明一律收进气泡里**。
///
/// 为什么值得一个组件：4.0.1 的设置页每个控件下面都挂着两三行解释，于是真正的控件被挤到
/// 第二屏、第三屏，而那些解释一天要被同一个人读一百遍。Plan C 的硬预算是"每个控件至多
/// 一行说明"，多出来的话全部搬到这颗 ⓘ 后面——要读的人点一下就有，不读的人不必每天绕开它。
struct SectionHeader: View {
    let title: String
    /// nil = 这一段没有需要展开的细则（不摆一颗点开是空的 ⓘ）
    var info: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let info = info { InfoButton(info) }
        }
    }
}

/// 那颗 ⓘ 本身。
///
/// 4.3.2 从 SectionHeader 里抽出来：「云端 AI」页不再有段标题了（段标题和栏名一直在
/// 说同一件事，用户 2026-09-22 的原话是"这个 settings 设计还是太冗余"），
/// 可那几条真正有信息量的细则还得有地方放——现在它们挂在**那一行控件自己**的右端。
struct InfoButton: View {
    let info: String

    @State private var showing = false

    init(_ info: String) { self.info = info }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .help(tr("详细说明", "Details"))
        .accessibilityLabel(tr("详细说明", "Details"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ScrollView {
                Text(info)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(width: 320)
            .frame(maxHeight: 420)
        }
    }
}

/// 一行说明。整个设置窗口里**每个控件至多一条**（Plan C 的文案预算）
struct Caption: View {
    let text: String
    var warning: Bool = false

    init(_ text: String, warning: Bool = false) {
        self.text = text
        self.warning = warning
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(warning ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 边界状态：一行结论 + 一颗按钮，永远不写成一段话。
/// （没有 Key 却开着云端识别、识别停在一家已经不用的服务商……这类状态只有两件事要说：
/// 现在是什么情况、点哪里能解决。）
struct BoundaryRow<Action: View>: View {
    let text: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action()
                .fixedSize()
        }
    }
}
