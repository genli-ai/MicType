import SwiftUI
import AppKit
import Combine

// MARK: - 设置窗口

/// 设置窗口现在只有**一个首页加四个编辑页**（Plan C，用户 2026-09-20 拍板）。
///
/// 4.0.2 早些时候那四个标签页（通用 / 本地识别 / 云端 AI / 关于）解决了"分法不对"的问题，
/// 却没解决"打开设置看不出现在是什么状态"——每一页都是一屏控件加一屏解释，用户要把四页
/// 逐个点开、逐行读，才能回答「我现在用的是哪个模型？云端开着吗？」这种一句话的问题。
///
/// 于是：**概览先回答状态，点「更改」才进控件**。路由名字就是卡片名字，深链（菜单栏
/// 「配置 AI…」、悬浮窗的「去配置」、模型升级横幅）照旧直接落到对应的编辑页。
enum SettingsRoute: String, Hashable, CaseIterable {
    /// 三张状态卡 + 权限横幅 + 脚注三个链接
    case overview
    /// 原「通用」：快捷键、悬浮窗、录音、行为、语言与备份
    case input
    /// 麦克风、识别语言、词汇表、本机模型
    case recognition
    /// 服务商、Key、模型、（阿里云的）云端识别开关
    case cloud
    /// 版本 / 更新 / 诊断 / 作者 + 隐私与费用（PrivacyCopy 在设置里**只**出现在这里）
    case about

    /// 编辑页顶栏的标题。概览没有顶栏（它就是首页，没有"返回"可言）
    var editorTitle: String? {
        switch self {
        case .overview: return nil
        case .input: return tr("输入", "Input")
        case .recognition: return tr("本地识别", "On-device recognition")
        case .cloud: return tr("云端 AI", "Cloud AI")
        case .about: return tr("关于 MicType", "About MicType")
        }
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

    private override init() { super.init() }

    /// - tab: 深链要停在哪一页；nil = 回概览。
    ///   为什么 nil 不再是"保持上次的位置"：概览就是这个窗口的首页，打开设置的人第一眼
    ///   该看到的是"现在是什么状态"，而不是上次退出时停在的某个编辑页。
    func show(tab: SettingsRoute? = nil) {
        SettingsNavigator.shared.go(to: tab ?? .overview)
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            // 关窗要有人知道：里面那一页不会跟着消失，得由这里告诉它停手
            w.delegate = self
            w.setContentSize(NSSize(width: 560, height: 520))
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
        .frame(width: 560, height: 520)
        // 滑动时别把半页画到窗口外面
        .clipped()
    }

    @ViewBuilder
    private var page: some View {
        Group {
            switch nav.route {
            case .overview: SettingsOverview()
            case .input: InputEditor()
            case .recognition: RecognitionEditor()
            case .cloud: CloudEditor()
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

    @State private var showingInfo = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let info = info {
                Button {
                    showingInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help(tr("详细说明", "Details"))
                .accessibilityLabel(tr("详细说明", "Details"))
                .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
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
