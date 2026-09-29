import AppKit
import SwiftUI

// MARK: - 设计语言（5.2.0 起的唯一出处）

/// MicType 的设计 tokens：颜色、动效、材质。**任何界面要用品牌色 / 弹簧 / 黑玻璃，都从这里拿**，
/// 不许在视图里再写一个 #4A4AE8——那正是"App 里感受不到图标那种靛紫"的来路（UX 方案 §1）。
///
/// 三条规矩（UX 方案 §0，用户 2026-09-29 定）：
///   • 一种强调色：品牌渐变 #4A4AE8 → #8C33D9，**只用于"正在发生"的东西**（波形、进度、一次性的确认）；
///   • 黑玻璃材质 + 1 px 8% 白描边；
///   • 动效统一 `spring(response: 0.25, dampingFraction: 0.85)`，出现 = 淡入 + 上移 6 pt，
///     「减少动态效果」开着就不位移。
enum Theme {

    // MARK: 颜色（深色，悬浮窗永远用这一套）

    static let bg = Color(hex: 0x0E0F12)
    static let surface = Color(hex: 0x16181D)
    static let text = Color(hex: 0xECEDEF)
    static let muted = Color(hex: 0x8A8F98)
    static let accentA = Color(hex: 0x4A4AE8)
    static let accentB = Color(hex: 0x8C33D9)
    /// 深底上的强调色文字（箭头、链接）：渐变本身在小字上读不清，取一个提亮的单色
    static let accentText = Color(hex: 0x8F80FF)
    static let danger = Color(hex: 0xFF3B30)
    /// 告知形态（"已经发生了、没什么可点"：没听到、润色失败已给原文、设备被拔…）的字色。
    /// 不是强调色、也不是红：黄调的次色，一眼看出"留意一下"而不是"出事了"
    static let warning = Color(hex: 0xE6B450)

    /// 品牌渐变，135°（左上 → 右下，与 App 图标同向）
    static let accentGradient = LinearGradient(colors: [accentA, accentB],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)

    /// 竖直方向的品牌渐变（波形条用：每根条自上而下由靛到紫，与设计稿 180° 一致）
    static let accentGradientVertical = LinearGradient(colors: [accentA, accentB],
                                                       startPoint: .top, endPoint: .bottom)

    /// 浅色模式的映射。5.3.0 起设置与引导窗口跟系统外观走（`palette(_:)`），
    /// **悬浮窗不用它**——胶囊永远是黑玻璃（白字压在任意壁纸上都要读得清）。
    /// 不是简单反色：强调色两套一样，底/面/字/次各自重取。
    enum Light {
        static let bg = Color(hex: 0xF5F5F7)
        static let surface = Color(hex: 0xFFFFFF)
        static let text = Color(hex: 0x1D1D1F)
        static let muted = Color(hex: 0x6E6E73)
    }

    /// 按外观取底 / 面 / 字 / 次四色（强调色不分外观）
    struct Palette: Equatable {
        let bg: Color
        let surface: Color
        let text: Color
        let muted: Color
    }

    static func palette(_ scheme: ColorScheme) -> Palette {
        scheme == .dark
            ? Palette(bg: bg, surface: surface, text: text, muted: muted)
            : Palette(bg: Light.bg, surface: Light.surface, text: Light.text, muted: Light.muted)
    }

    // MARK: 动效

    /// 全 App 唯一的弹簧。150–250 ms 带一点弹性：够看出"它动了"，又不会拖泥带水
    static let spring = Animation.spring(response: 0.25, dampingFraction: 0.85)

    /// 出现 = 淡入 + 上移 6 pt；消失 = 淡出
    static let appear: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .offset(y: 6)),
        removal: .opacity)

    /// 系统「减弱动态效果」。每次读都是实时值：用户在系统设置里一拨，下一帧就生效
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 减弱动态效果时不插值（nil），否则走统一弹簧
    static var springOrNone: Animation? {
        reduceMotion ? nil : spring
    }

    // MARK: 材质

    /// 黑玻璃的描边：1 px、8% 白
    static let hairline = Color.white.opacity(0.08)
}

extension Color {
    /// 0xRRGGBB → sRGB 颜色。tokens 全部按设计稿的十六进制写，免得换算出错
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - 黑玻璃

extension View {
    /// 黑玻璃材质。radius = nil 就是胶囊（半径 = 高度一半），否则是该半径的圆角矩形。
    ///
    /// macOS 26 用系统的 Liquid Glass（`.glassEffect`，染 60% 黑）；15–25 没有它，
    /// 退回 HUD 材质（behindWindow 模糊）+ 90% 黑 —— 与 5.1 的胶囊同一副底子，视觉上尽量一致。
    /// 两条路都叠一圈 1 px 8% 白的发丝边。
    func glass(radius: CGFloat? = nil) -> some View {
        modifier(GlassModifier(radius: radius))
    }
}

private struct GlassModifier: ViewModifier {
    let radius: CGFloat?

    private var shape: AnyShape {
        if let radius = radius {
            return AnyShape(RoundedRectangle(cornerRadius: radius, style: .circular))
        }
        return AnyShape(Capsule(style: .circular))
    }

    func body(content: Content) -> some View {
        content
            .background(backdrop)
            .overlay(shape.stroke(Theme.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var backdrop: some View {
        if #available(macOS 26.0, *), !GlassFallback.forced {
            ZStack {
                // 投影由一层同形状的实心图形来投：玻璃自己不投影，悬浮在任意底色上会"没有边"
                shape.fill(Color.black.opacity(0.3))
                    .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
                Color.clear
                    .glassEffect(.regular.tint(Color.black.opacity(0.6)), in: shape)
            }
        } else {
            ZStack {
                // 实心图形只为投影（材质视图是 NSView，SwiftUI 量不到它的形状，直接加 .shadow 会投成方框）
                shape.fill(Color.black.opacity(0.9))
                    .shadow(color: .black.opacity(0.45), radius: 16, x: 0, y: 8)
                GeometryReader { geo in
                    HUDMaterial(radius: radius ?? geo.size.height / 2)
                }
                // 压暗到设计稿的 90% 黑：材质在浅色壁纸上偏亮，白字对比度要永远够
                shape.fill(Color.black.opacity(0.9))
            }
        }
    }
}

/// 快照测试要一张"与真机一致、又能被 cacheDisplay 拍下来"的图：系统玻璃由窗口服务器合成，
/// 离屏位图里是空的。测试里把它拨到回退那条路（只影响本进程，App 里永远是 false）。
enum GlassFallback {
    static var forced = false
}

/// HUD 材质（behindWindow 混合），被裁成胶囊 / 圆角矩形。
/// 外观强制深色：跟随系统的话浅色模式下背板变亮，白字直接糊掉。
/// 裁剪用 maskImage 而不是 SwiftUI 的 clipShape / layer.mask：behindWindow 混合走的是系统背板层，
/// maskImage 是官方支持的那个裁剪口子（layer 掩码在这条路径上时灵时不灵，四角会漏出方形的模糊）。
private struct HUDMaterial: NSViewRepresentable {
    let radius: CGFloat

    func makeNSView(context: Context) -> MaskedVisualEffectView {
        let view = MaskedVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.appearance = NSAppearance(named: .darkAqua)
        view.cornerRadius = radius
        return view
    }

    func updateNSView(_ view: MaskedVisualEffectView, context: Context) {
        view.cornerRadius = radius
    }
}

private final class MaskedVisualEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    private var appliedRadius: CGFloat = -1
    private var appliedSize: NSSize = .zero

    override func layout() {
        super.layout()
        // 超过短边一半的半径钳到一半：再大也只是胶囊，画出来反而会错形
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
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

// MARK: - 三个组件

/// 悬浮窗的容器：黑玻璃胶囊。内容自己决定宽度；高度默认 56（设计稿），
/// radius = nil 时是胶囊，多行内容（指令模式、两行错误）传一个具体半径。
struct MTCapsule<Content: View>: View {
    var height: CGFloat? = 56
    var radius: CGFloat? = nil
    var danger: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(minHeight: height)
            .glass(radius: radius)
            .overlay(dangerRing)
    }

    /// 错误形态：一圈 1 px、70% 的红边（设计稿 Overlay-Error），外加一点点红色外发光
    @ViewBuilder
    private var dangerRing: some View {
        if danger {
            Group {
                if let radius = radius {
                    RoundedRectangle(cornerRadius: radius, style: .circular)
                        .stroke(Theme.danger.opacity(0.7), lineWidth: 1)
                } else {
                    Capsule(style: .circular)
                        .stroke(Theme.danger.opacity(0.7), lineWidth: 1)
                }
            }
            .shadow(color: Theme.danger.opacity(0.15), radius: 9)
        }
    }
}

/// 卡片：面色底 + 发丝边 + 14 pt 圆角。跟系统外观走（5.3.0 起设置状态页与权限横幅用它）
struct MTCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.palette(scheme).surface))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(scheme == .dark ? Theme.hairline : Color.black.opacity(0.08), lineWidth: 1))
    }
}

/// 按钮两种：primary = 品牌渐变（一屏至多一颗，"就是这一步"）；quiet = 14% 白（悬浮窗里的次要动作）。
/// 纯外观：点击由调用方决定怎么接（悬浮窗整块不接鼠标，靠全局监听判坐标，见 OverlayController）。
///
/// adaptive（5.3.0）：引导与设置窗口跟系统外观走，quiet 那一档在浅色底上要换成 6% 黑 + 深字
/// ——14% 白压在 #F5F5F7 上等于没有底、白字直接看不见。**默认 false**：悬浮窗永远是黑玻璃，
/// 它的按钮不许跟着系统外观变（那扇面板的外观不归我们设，跟系统走的话浅色模式下按钮就花了）。
struct MTButton: View {
    enum Style: Equatable {
        case primary
        case quiet
    }

    let title: String
    var style: Style = .quiet
    var adaptive: Bool = false
    var action: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if let action = action {
            Button(action: action) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }

    /// 这一刻按哪套颜色画：只有 adaptive 且系统是浅色时才换成浅色那套
    private var light: Bool { adaptive && scheme == .light }

    private var label: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(style == .primary ? .white : (light ? Theme.Light.text : Theme.text))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(background)
            .contentShape(Capsule())
            // 点不动的时候看得出来点不动（引导里「继续」在权限没齐时是灰的）
            .opacity(isEnabled ? 1 : 0.45)
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .primary:
            Capsule().fill(Theme.accentGradient)
                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
        case .quiet:
            Capsule().fill(light ? Color.black.opacity(0.06) : Color.white.opacity(0.14))
        }
    }
}

// MARK: - 两个状态小件（5.3.0，引导与设置共用）

/// 「办好了」的那枚圆：品牌渐变底 + 白勾，勾是 0.25 s 描出来的（减弱动态效果时直接画满）。
/// 渐变只用在"正在发生 / 一次性的确认"上（§0 规矩），这枚勾正是那一次确认。
struct MTCheckCircle: View {
    var size: CGFloat = 22
    @State private var drawn: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(Theme.accentGradient)
            CheckShape()
                .trim(from: 0, to: drawn)
                .stroke(Color.white, style: StrokeStyle(lineWidth: max(1.6, size * 0.1),
                                                        lineCap: .round, lineJoin: .round))
                .padding(size * 0.27)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !Theme.reduceMotion else { drawn = 1; return }
            withAnimation(.easeOut(duration: 0.25)) { drawn = 1 }
        }
        .accessibilityHidden(true)
    }

    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
            return path
        }
    }
}

/// 「还没办」的那枚圆：1.5 pt 灰圈，里面什么都没有
struct MTPendingCircle: View {
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .stroke(scheme == .dark ? Color(hex: 0x5A5F68) : Color(hex: 0xC7C7CC), lineWidth: 1.5)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 验证中的渐变进度环（一段 3/4 的弧在转）。减弱动态效果时不转，只画一段静止的弧
struct MTProgressRing: View {
    var size: CGFloat = 20
    @State private var spinning = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle().stroke(scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08),
                            lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !Theme.reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
        }
        .accessibilityLabel(tr("正在验证", "Checking"))
    }
}

#if DEBUG
struct ThemeComponents_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 20) {
            MTCapsule {
                HStack(spacing: 14) {
                    Circle().fill(Theme.accentGradient).frame(width: 24, height: 24)
                    Text("Preview").foregroundColor(Theme.text)
                }
                .padding(.horizontal, 22)
            }
            MTCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OpenAI").font(.headline).foregroundColor(Theme.text)
                    Text("Card body").foregroundColor(Theme.muted)
                }
            }
            HStack {
                MTButton(title: "Primary", style: .primary)
                MTButton(title: "Quiet", style: .quiet)
            }
        }
        .padding(32)
        .frame(width: 520)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}
#endif
