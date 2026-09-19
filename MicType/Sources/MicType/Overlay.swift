import AppKit
import SwiftUI

// MARK: - 悬浮窗状态

final class OverlayState: ObservableObject {
    enum Mode: Equatable {
        case recording(String)
        case processing(String)
        case success(String)
        case error(String)
        /// 中性提示（取消等用户主动动作）：既不是成功也不是错误，别用绿勾/黄三角误导
        case notice(String)
    }

    // 占位初值，显示前必然会被 showRecording/showProcessing 覆盖
    @Published var mode: Mode = .recording("")
    @Published var levels: [Float] = Array(repeating: 0.05, count: 13)
    /// 录音中的灰色草稿（伪流式预览）。只是"看得见"，永远不会被插入到任何地方；
    /// 空字符串时胶囊保持原来的紧凑形状。
    @Published var draftText: String = ""
    /// 入场/退场动画的开关：true = 已就位（不透明、原尺寸）。由 OverlayController
    /// 用 withAnimation 翻转，视图只负责把它翻译成 opacity/scale。
    @Published var presented: Bool = false
    /// 胶囊贴面板顶边（顶部居中）还是底边（底部居中 / 跟随指针）。
    /// 贴哪边决定了草稿把胶囊撑高时它往哪个方向长。
    @Published var topAligned: Bool = false

    /// 「⎋ 取消」小按钮在面板坐标系（SwiftUI 坐标，原点左上）里的位置，由视图量出来回填。
    /// 故意**不是** @Published：它只被 AppKit 的命中测试读，设成 published 会让
    /// 布局回填再触发一次重绘，绕成死循环。
    var cancelHitRect: CGRect = .zero

    /// 当前状态是否"可取消"——只有录音中和处理中才有取消这回事，
    /// 一闪而过的成功/错误提示绝不能接鼠标（否则会吃掉用户投向目标应用的那一下点击）。
    var isCancellable: Bool {
        switch mode {
        case .recording, .processing: return true
        case .success, .error, .notice: return false
        }
    }

    func pushLevel(_ level: Float) {
        var l = levels
        l.removeFirst()
        l.append(max(0.05, min(1.0, level)))
        levels = l
    }

    func resetLevels() {
        levels = Array(repeating: 0.05, count: 13)
    }
}

// MARK: - 悬浮窗位置的几何常量（视图与控制器共用）

enum OverlayMetrics {
    /// 胶囊在面板里的外边距（OverlayView 最外层的 .padding）
    static let contentInset: CGFloat = 16
    /// 面板尺寸：足够装下两行灰字草稿；胶囊在容器里贴边，所以没草稿时位置与以前一模一样
    static let panelSize = CGSize(width: 520, height: 160)
}

// MARK: - 原生材质背板

/// HUD 材质 + behindWindow 混合 = 系统自己那层悬浮窗质感（纯黑块在深色壁纸上像个补丁）。
/// 外观强制深色：材质跟随系统的话，浅色模式下背板会变亮，胶囊里的白字直接糊掉。
private struct OverlayBackdrop: NSViewRepresentable {
    enum CornerStyle {
        case capsule
        case rounded(CGFloat)
    }

    let corner: CornerStyle

    func makeNSView(context: Context) -> MaskedVisualEffectView {
        let view = MaskedVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: .darkAqua)
        view.corner = corner
        return view
    }

    func updateNSView(_ view: MaskedVisualEffectView, context: Context) {
        view.corner = corner
    }
}

/// 被裁成胶囊/圆角矩形的材质视图。
/// 用 maskImage 而不是 layer.mask：behindWindow 混合走的是系统背板层，
/// maskImage 是官方支持的那个裁剪口子（layer 掩码在这条路径上时灵时不灵）。
private final class MaskedVisualEffectView: NSVisualEffectView {
    var corner: OverlayBackdrop.CornerStyle = .capsule {
        didSet { needsLayout = true }
    }

    private var appliedRadius: CGFloat = -1
    private var appliedSize: NSSize = .zero

    override func layout() {
        super.layout()
        let radius: CGFloat
        switch corner {
        case .capsule:
            radius = bounds.height / 2
        case .rounded(let r):
            radius = min(r, min(bounds.width, bounds.height) / 2)
        }
        // 尺寸和圆角都没变就别重画掩码：录音时每秒几十次布局，白画就是白烧 CPU
        guard bounds.size != appliedSize || radius != appliedRadius else { return }
        appliedSize = bounds.size
        appliedRadius = radius
        maskImage = MaskedVisualEffectView.mask(radius: radius)
    }

    private static func mask(radius: CGFloat) -> NSImage? {
        guard radius > 0 else { return nil }
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        // 只拉伸中间那一像素，四角圆弧原样保留
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 胶囊的全部外观：投影 + 材质 + 压暗层 + 发丝边
private struct CapsuleChrome<S: InsettableShape>: View {
    let shape: S
    let corner: OverlayBackdrop.CornerStyle

    var body: some View {
        ZStack {
            // 投影得由一层同形状的实心图形来投：材质是被 maskImage 裁出来的 NSView，
            // SwiftUI 量不到它的真实形状，直接给它加 .shadow 会投出一个方框。
            // 这层实心图形本身会被材质盖住，只有溢出到外面的投影看得见。
            shape.fill(Color.black.opacity(0.9))
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
            OverlayBackdrop(corner: corner)
            // 压暗：材质在浅色壁纸上会偏亮，补一层暗色保证白字的对比度永远够
            shape.fill(Color.black.opacity(0.3))
            shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

// MARK: - 悬浮窗视图

struct OverlayView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        // 系统「减弱动态效果」：不缩放（下面的 scaleEffect 直接给 1）
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        VStack(spacing: 6) {
            row
            if !state.draftText.isEmpty {
                // 灰字草稿：识别还在跑，随时会变，所以比正文暗一档；
                // 只留两行，掐头不掐尾（用户关心的是刚说的那几个字）
                Text(state.draftText)
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 340, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: state.draftText)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minWidth: 160, minHeight: 44)
        .background(capsuleBackground)
        .padding(OverlayMetrics.contentInset)
        .opacity(state.presented ? 1 : 0)
        .scaleEffect(state.presented || reduceMotion ? 1 : 0.94,
                     anchor: state.topAligned ? .top : .bottom)
    }

    /// 没草稿时保持原来的胶囊；有草稿时换成圆角矩形——两行文字装进胶囊里
    /// 左右会被弧边啃掉，读起来别扭。
    /// 圆角一律用 .circular：材质那层的掩码是 NSBezierPath 画的圆弧，
    /// 这边改成 .continuous 会跟背板边缘错开一线。
    @ViewBuilder private var capsuleBackground: some View {
        if state.draftText.isEmpty {
            CapsuleChrome(shape: Capsule(style: .circular), corner: .capsule)
        } else {
            CapsuleChrome(shape: RoundedRectangle(cornerRadius: 18, style: .circular),
                          corner: .rounded(18))
        }
    }

    private var row: some View {
        HStack(spacing: 10) {
            switch state.mode {
            case .recording(let label):
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<state.levels.count, id: \.self) { i in
                        Capsule()
                            .fill(Color.white.opacity(0.95))
                            .frame(width: 3, height: 5 + 23 * CGFloat(state.levels[i]))
                    }
                }
                .animation(.linear(duration: 0.1), value: state.levels)
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundColor(.white.opacity(0.85))
                CancelChip(state: state)
            case .processing(let label):
                ProgressView()
                    .controlSize(.small)
                    .colorInvert()
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundColor(.white.opacity(0.9))
                // 处理中唯一的出口就是取消——一直摆在眼前，别让用户以为自己被锁住了
                CancelChip(state: state)
            case .notice(let label):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.75))
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundColor(.white.opacity(0.9))
            case .success(let label):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundColor(.white.opacity(0.9))
            case .error(let label):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(2)
            }
        }
    }
}

/// 胶囊右端的「⎋ 取消」：既是"出口在这里"的说明，也是真能点的按钮。
/// 点击不走 SwiftUI 手势——悬浮窗所在的 app 没被激活时，SwiftUI 收到的第一下会被
/// 系统当成"激活窗口"吞掉；命中测试与点击统一交给 OverlayHitView（见那里的注释）。
/// 这里只负责长相，外加把自己的位置量出来回填给命中测试用。
private struct CancelChip: View {
    let state: OverlayState

    var body: some View {
        Text(tr("⎋ 取消", "⎋ Cancel"))
            .font(.subheadline.weight(.medium))
            .foregroundColor(.white.opacity(0.72))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .background(
                GeometryReader { geo -> Color in
                    // 直接写进 state（非 published，不会触发重绘）——
                    // onPreferenceChange 的闭包在新 SDK 上要求 @Sendable，捕获 state 会报警告
                    state.cancelHitRect = geo.frame(in: .named(OverlayContainer.space))
                    return Color.clear
                }
            )
    }
}

// MARK: - 面板内容视图（命中测试）

/// 只有「⎋ 取消」那一小块接鼠标，其余一律 hitTest 返回 nil：
/// 胶囊本身不吃点击，用户投向目标应用的那一下永远打得到。
private final class OverlayHitView: NSView {
    /// 取消按钮在 SwiftUI 坐标系（原点左上）里的位置
    var cancelRect: () -> CGRect = { .zero }
    /// 当前是不是可取消状态（与 panel.ignoresMouseEvents 双保险）
    var isCancellable: () -> Bool = { false }
    var onCancel: (() -> Void)?

    /// SwiftUI 的 y 轴朝下、NSView 默认朝上，翻过来才是同一块地方；
    /// 小按钮再给 4pt 容错，别让用户点三次才中
    private var hitFrame: CGRect {
        let rect = cancelRect()
        guard !rect.isEmpty else { return .zero }
        return CGRect(x: rect.minX,
                      y: bounds.height - rect.maxY,
                      width: rect.width,
                      height: rect.height)
            .insetBy(dx: -4, dy: -4)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isCancellable() else { return nil }
        return hitFrame.contains(convert(point, from: nil)) ? self : nil
    }

    /// MicType 没被激活时点一下就要生效：默认 first mouse 只用来激活窗口，那一下会被吃掉
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 吞掉 mouseDown，保证 mouseUp 还送到这里（默认实现会把事件甩给响应链）
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        // 按下之后拖出去再松手不算点击，和系统按钮一个脾气
        guard hitFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        onCancel?()
    }
}

/// 悬浮窗永远不当 key / main 窗口：点「取消」也不该把目标应用里的光标和焦点抢走
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 悬浮窗控制器

final class OverlayController {

    let state = OverlayState()
    /// 点胶囊上的「⎋ 取消」时调用（DictationController 接到 cancel()，与 Esc 同一个出口）
    var onCancelTapped: (() -> Void)?

    private var panel: NSPanel?
    private var hideGeneration = 0
    /// 本轮「处理中」的起点与当前阶段标签：秒数从整轮处理开始算（用户关心的是"我等了多久"，
    /// 不是"这一段等了多久"），阶段标签换成「润色中…」时不重新计时
    private var processingStartedAt: Date?
    private var processingLabel = ""
    private var processingTimer: Timer?

    /// 入场 0.16s / 退场 0.12s：够看出"它来了/它走了"，又不至于挡在用户前面
    private static let presentDuration: Double = 0.16
    private static let dismissDuration: Double = 0.12
    /// 底部居中的老坐标：容器贴底后胶囊底边比面板底边高 contentInset，+35 补回
    /// 原先居中布局的 7pt，屏幕上的位置与 3.2.19 完全一致
    private static let bottomMargin: CGFloat = 35
    /// 跟随指针时胶囊底边距指针的高度（像 tooltip 那样浮在指针上方一点）
    private static let cursorGap: CGFloat = 18
    /// 跟随指针时给胶囊预留的最大高度（带两行草稿的圆角矩形）：
    /// 指针贴着屏幕顶边时按这个高度往下让，草稿把胶囊撑高也不会顶出屏幕
    private static let cursorCapsuleReserve: CGFloat = 108

    /// 系统「减弱动态效果」：开了就不缩放、不淡入淡出，直接现身/消失
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let p = OverlayPanel(contentRect: NSRect(origin: .zero, size: OverlayMetrics.panelSize),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // 默认不接鼠标；只有录音/处理中（有取消可点）才在 applyMousePolicy 里放开
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = OverlayHitView(frame: p.contentRect(forFrameRect: p.frame))
        container.autoresizingMask = [.width, .height]
        container.cancelRect = { [weak self] in self?.state.cancelHitRect ?? .zero }
        container.isCancellable = { [weak self] in self?.state.isCancellable ?? false }
        container.onCancel = { [weak self] in
            guard let self = self else { return }
            Log.info("Overlay cancel tapped")
            self.onCancelTapped?()
        }

        let hosting = NSHostingView(rootView: OverlayContainer(state: state))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        p.contentView = container
        panel = p
        return p
    }

    private func position(_ p: NSPanel) {
        // 多屏：跟随鼠标所在屏幕（用户正在操作的那块屏），固定主屏会让悬浮窗"消失"在别的屏上
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let choice = Settings.shared.overlayPosition
        // 顶部居中时胶囊贴面板顶边，草稿往下长；另外两个位置贴底，草稿往上长
        state.topAligned = (choice == .topCenter)
        p.setFrameOrigin(OverlayController.panelOrigin(position: choice,
                                                       panelSize: p.frame.size,
                                                       visibleFrame: frame,
                                                       mouse: mouse))
    }

    /// 面板左下角坐标。纯函数（只吃几何量、不碰 AppKit 状态），位置策略与边界钳制靠单测守。
    /// 钳制按整个面板算而不是按胶囊算：胶囊在面板里居中，面板不出屏它就不出屏，
    /// 代价只是贴边时它停得比理论上早一点——比算错了半截露在屏幕外强。
    static func panelOrigin(position: OverlayPosition,
                            panelSize: CGSize,
                            visibleFrame: CGRect,
                            mouse: CGPoint) -> CGPoint {
        let centeredX = visibleFrame.midX - panelSize.width / 2
        switch position {
        case .bottomCenter:
            return CGPoint(x: centeredX, y: visibleFrame.minY + bottomMargin)
        case .topCenter:
            // 内容贴面板顶边，所以面板顶边对齐 visibleFrame 顶边（已在菜单栏之下）
            return CGPoint(x: centeredX, y: visibleFrame.maxY - panelSize.height)
        case .nearCursor:
            let x = clamp(mouse.x - panelSize.width / 2,
                          low: visibleFrame.minX,
                          high: visibleFrame.maxX - panelSize.width)
            // 内容贴底：胶囊底边 = 面板底边 + contentInset，所以反推面板底边
            let y = clamp(mouse.y + cursorGap - OverlayMetrics.contentInset,
                          low: visibleFrame.minY - OverlayMetrics.contentInset,
                          high: visibleFrame.maxY - OverlayMetrics.contentInset - cursorCapsuleReserve)
            return CGPoint(x: x, y: y)
        }
    }

    /// 上界比下界还低（屏幕窄过面板这种极端情况）时取下界：宁可右边溢出，也不让它跑到屏幕左外
    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard high > low else { return low }
        return Swift.min(Swift.max(value, low), high)
    }

    func showRecording(label: String = tr("正在听…", "Listening…")) {
        hideGeneration += 1
        endProcessing()
        state.resetLevels()
        state.draftText = ""
        state.mode = .recording(label)
        present(context: "recording")
    }

    /// 伪流式预览：把识别到一半的灰字草稿贴到波形下面。只在录音中生效——
    /// 松手之后显示的是"处理中"，草稿的使命到此为止（最终文字以完整重识别为准）。
    func showDraft(_ text: String) {
        guard case .recording = state.mode else { return }
        guard state.draftText != text else { return }
        state.draftText = text
    }

    /// 只换「正在听…」的文案，不重置波形、不重建面板——按住升级为指令模式（或到 2 分钟
    /// 软提示）时用户的话已经在录了，波形必须连续，面板也不该闪。
    func updateRecordingLabel(_ label: String) {
        guard case .recording = state.mode else { return }
        state.mode = .recording(label)
    }

    func showProcessing(_ label: String) {
        hideGeneration += 1
        state.draftText = ""
        processingLabel = label
        if processingStartedAt == nil { processingStartedAt = Date() }
        state.mode = .processing(processingText())
        startProcessingTimer()
        present(context: "processing")
    }

    /// 处理中被拒绝的手势（轻点/按住）：闪一句提示后回到「处理中」显示，
    /// 绝不用这条提示把进度显示擦掉
    func flashOverProcessing(_ label: String, duration: Double = 1.6) {
        guard processingStartedAt != nil else {
            flashError(label)
            return
        }
        hideGeneration += 1
        let generation = hideGeneration
        state.mode = .error(label)
        present(context: "flash-busy")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.hideGeneration == generation,
                  self.processingStartedAt != nil else { return }
            self.state.mode = .processing(self.processingText())
            // 回到处理中就又能点取消了（闪提示期间鼠标是放行的）
            if let p = self.panel { self.applyMousePolicy(p) }
        }
    }

    /// 已等待秒数：3 秒内不显示——短请求上闪一个数字只是噪音
    private func processingText() -> String {
        guard let start = processingStartedAt else { return processingLabel }
        let elapsed = Int(Date().timeIntervalSince(start))
        guard elapsed >= 3 else { return processingLabel }
        return processingLabel + " \(elapsed)s"
    }

    private func startProcessingTimer() {
        guard processingTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickProcessing()
        }
        // .common：菜单打开 / 窗口拖动期间 runloop 切模式，默认模式的 timer 会停走
        RunLoop.main.add(timer, forMode: .common)
        processingTimer = timer
    }

    private func tickProcessing() {
        guard processingStartedAt != nil else { return }
        // 正在闪别的提示（flashOverProcessing）时不要抢回显示
        guard case .processing = state.mode else { return }
        state.mode = .processing(processingText())
    }

    private func endProcessing() {
        processingTimer?.invalidate()
        processingTimer = nil
        processingStartedAt = nil
        processingLabel = ""
    }

    /// 只在"有取消可点"时接鼠标。一闪而过的成功/错误提示如果接鼠标，
    /// 用户正要点目标应用的那一下就会被悬浮窗吃掉。
    private func applyMousePolicy(_ p: NSPanel) {
        p.ignoresMouseEvents = !state.isCancellable
    }

    /// 统一的显示入口：定位 → 置顶 → 回读真实状态 → 入场动画。
    /// 3.2.13：不只查 isVisible，还查 isOnActiveSpace——panel 的 Space 关联会偶发损坏
    /// （visible=true 但挂在别的桌面空间，用户看不见，2026-06-12 日志实锤）。
    /// 任一不健康就整个重建 panel：新建的 panel 必然落在当前活跃 Space。
    private func present(context: String) {
        var p = ensurePanel()
        position(p)
        // 入场动画只在"这一轮第一次现身"时放：录音→处理中这种状态切换不该再闪一次；
        // 正在淡出（presented 已经是 false）的话算重新入场，把它拉回来
        let entering = !p.isVisible || !state.presented
        if entering && !reduceMotion { state.presented = false }
        p.orderFrontRegardless()
        if !p.isVisible || !p.isOnActiveSpace {
            Log.warn("Overlay \(context) unhealthy (visible=\(p.isVisible) onActiveSpace=\(p.isOnActiveSpace)) — rebuilding panel")
            p.orderOut(nil)
            panel = nil
            p = ensurePanel()
            position(p)
            p.orderFrontRegardless()
        }
        if entering {
            if reduceMotion {
                state.presented = true
            } else {
                // 隔一个 runloop 再点火：同一拍里 false→true 会被合并掉，动画就白设了。
                // 带上 hideGeneration，这中间要是已经 hide 了就当没发生过。
                let generation = hideGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.hideGeneration == generation else { return }
                    withAnimation(.easeOut(duration: OverlayController.presentDuration)) {
                        self.state.presented = true
                    }
                }
            }
        }
        applyMousePolicy(p)
        Log.overlayShown(context: context, panel: p)
    }

    func flashSuccess(_ label: String) {
        flash(.success(label), duration: 1.0)
    }

    func flashError(_ label: String) {
        flash(.error(label), duration: 2.5)
    }

    func flashNotice(_ label: String) {
        flash(.notice(label), duration: 1.0)
    }

    private func flash(_ mode: OverlayState.Mode, duration: Double) {
        hideGeneration += 1
        endProcessing()
        state.draftText = ""
        let generation = hideGeneration
        state.mode = mode
        present(context: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.hideGeneration == generation else { return }
            self.hide()
        }
    }

    func hide() {
        hideGeneration += 1
        endProcessing()
        state.draftText = ""
        state.cancelHitRect = .zero
        panel?.ignoresMouseEvents = true
        guard let p = panel, p.isVisible, !reduceMotion else {
            state.presented = false
            panel?.orderOut(nil)
            return
        }
        let generation = hideGeneration
        withAnimation(.easeIn(duration: OverlayController.dismissDuration)) {
            state.presented = false
        }
        // 淡出跑完才真正下线。这中间要是又有新一轮要显示，hideGeneration 已经变了，
        // 这里直接放手——否则刚亮起来的悬浮窗会被上一轮的退场动作关掉。
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayController.dismissDuration + 0.02) { [weak self] in
            guard let self = self, self.hideGeneration == generation else { return }
            self.panel?.orderOut(nil)
        }
    }
}

/// 让胶囊在固定大小面板里居中（顶部居中时贴顶边，其余贴底边）
private struct OverlayContainer: View {
    /// 命中测试要的是"取消按钮在面板里的位置"，所以量尺子的坐标系锚在这一层
    static let space = "MicTypeOverlayPanel"

    @ObservedObject var state: OverlayState

    var body: some View {
        VStack(spacing: 0) {
            if !state.topAligned { Spacer(minLength: 0) }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                OverlayView(state: state)
                Spacer(minLength: 0)
            }
            if state.topAligned { Spacer(minLength: 0) }
        }
        .coordinateSpace(name: Self.space)
    }
}
