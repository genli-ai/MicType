import AppKit

// MARK: - 菜单栏图标（MicType 自己的标志）

/// 4.3.4 之前菜单栏挂的是系统通用的 `mic` 符号。2026-09-22 的新用户反馈里有一条是
/// "打开之后什么都没出现、不知道它在哪"——纯菜单栏应用本来就只有那一枚图标能被认出来，
/// 而那枚图标和别的十几个录音类工具长得一模一样，刘海屏挤满时还会被藏掉。
///
/// 所以这里**在代码里把 AppIcon 上那枚白色剪影重画一遍**（胶囊话筒 + 下方半圆托架 +
/// 立柱 + 底座，左右各两道声波弧），而不是去缩放 `AppIcon.png`：
///   • 位图缩到 18pt 会糊，而且 1024px 的那张带着紫色渐变背景，抠不出模板图；
///   • 模板图（`isTemplate`）必须是纯黑 + alpha，系统才会在浅色 / 深色菜单栏、
///     以及被选中时自动反色——这是菜单栏图标唯一正确的做法；
///   • 同一个画法还要出一张 56pt 的大图给引导最后一屏和「关于」页指路用
///     （"菜单栏里认的就是这个"），一处画、两处用，永远不会对不上。
enum MenuBarIcon {

    /// 菜单栏三态。`processing` 仍用系统的 `waveform`：那一刻要表达的是"正在忙"，
    /// 一个会动的、和静止标志明显不同的符号比同一个剪影换个颜色更看得出来。
    enum State {
        case idle
        case recording
        case processing
    }

    /// 菜单栏那枚（AppKit 的惯例尺寸，NSStatusItem 会按这个大小摆）
    static let menuBarSize: CGFloat = 18
    /// 引导最后一屏 /「关于」页那张大的
    static let largeSize: CGFloat = 56

    /// 标志本身的宽高比（宽 ÷ 高）。声波弧比话筒本体伸得远，所以这枚标志天生是扁的；
    /// 画进一个正方形里时靠**宽度**定大小，上下自然留白。
    /// 这个数字必须和下面 Ratio 里的 waveOffset / waveOuter / waveStroke 对得上
    /// （= 2 × (offset + outer + stroke/2)），否则弧会被画到画布外面去。
    static let aspectRatio: CGFloat = 1.302

    /// 三张图都是缓存好的（画一次就够），但**旁白文字每次现取**：
    /// 缓存那一下发生在启动时，而界面语言是可以随时切的（i18n 快照字符串那条坑）
    static func image(_ state: State) -> NSImage {
        switch state {
        case .idle:
            return idleImage
        case .recording:
            recordingImage.accessibilityDescription = tr("录音中", "Recording")
            return recordingImage
        case .processing:
            let image = NSImage(systemSymbolName: "waveform",
                                accessibilityDescription: tr("处理中", "Processing"))
            return image ?? idleImage
        }
    }

    /// 空闲态：模板图。颜色交给系统（浅色菜单栏黑、深色菜单栏白、点开时自动反色）
    private static let idleImage: NSImage = {
        let image = mark(size: menuBarSize, color: .black)
        image.isTemplate = true
        image.accessibilityDescription = "MicType"
        return image
    }()

    /// 录音态：同一枚剪影，填红。**不是模板图**——模板图会被系统重新上色，红色就没了
    private static let recordingImage: NSImage = {
        let image = mark(size: menuBarSize, color: .systemRed)
        image.isTemplate = false
        return image
    }()

    /// 引导 /「关于」页那张大图。模板图 = 交给 SwiftUI 按 foregroundColor 上色，
    /// 浅色底、深色底各自都看得见（两处都用 accentColor）
    static func large(size: CGFloat = largeSize) -> NSImage {
        let image = mark(size: size, color: .black)
        image.isTemplate = true
        image.accessibilityDescription = "MicType"
        return image
    }

    /// 画一枚标志。正方形画布，标志按宽度撑满、垂直居中。
    static func mark(size: CGFloat, color: NSColor) -> NSImage {
        let canvas = NSSize(width: size, height: size)
        let image = NSImage(size: canvas, flipped: false) { rect in
            draw(in: rect, color: color)
            return true
        }
        return image
    }

    // MARK: - 几何（全部按标志高度 h 的比例，和 AppIcon.png 上的剪影同源）

    /// 各部件占标志高度的比例。数字来自 AppIcon.png 里那枚剪影的实测像素
    /// （glyph 高 432px：胶囊 155×292、托架半径 130 线宽 42、底座 185×38），
    /// 只有声波弧往里收了一点——原图上那两组弧离话筒很远，照搬会让 18pt 下的话筒小到看不清。
    private enum Ratio {
        /// 胶囊：宽、高（高从标志顶端算起）
        static let capsuleWidth: CGFloat = 0.359
        static let capsuleHeight: CGFloat = 0.676
        /// 托架半圆：圆心到标志顶端的距离、半径、线宽
        static let cradleCenter: CGFloat = 0.514
        static let cradleRadius: CGFloat = 0.301
        static let cradleStroke: CGFloat = 0.097
        /// 立柱：宽、从哪到哪（都从标志顶端算）
        static let stemWidth: CGFloat = 0.06
        static let stemTop: CGFloat = 0.722
        /// 底座：宽、高（底边就是标志底边）
        static let baseWidth: CGFloat = 0.428
        static let baseHeight: CGFloat = 0.088
        /// 声波弧：圆心离话筒中轴多远、外弧半径、内弧半径、线宽、圆心到标志顶端的距离
        static let waveOffset: CGFloat = 0.40
        static let waveOuter: CGFloat = 0.205
        static let waveInner: CGFloat = 0.082
        static let waveStroke: CGFloat = 0.092
        static let waveCenter: CGFloat = 0.30
        /// 两道弧各扫多少度（原图上外弧是个大括弧、内弧只是一小牙）
        static let waveSweep: CGFloat = 46
    }

    /// 这枚标志在给定画布里有多高（宽度撑满、留一点边距，装不下时由高度封顶）
    static func markHeight(in rect: NSRect) -> CGFloat {
        let usableWidth = rect.width * 0.98
        return min(rect.height * 0.98, usableWidth / aspectRatio)
    }

    private static func draw(in rect: NSRect, color: NSColor) {
        let h = markHeight(in: rect)
        guard h > 0 else { return }
        let cx = rect.midX
        // 标志顶端：垂直居中
        let top = rect.midY + h / 2

        color.setFill()
        color.setStroke()

        // 胶囊话筒
        let capsuleWidth = Ratio.capsuleWidth * h
        let capsuleHeight = Ratio.capsuleHeight * h
        let capsule = NSBezierPath(roundedRect:
            NSRect(x: cx - capsuleWidth / 2, y: top - capsuleHeight,
                   width: capsuleWidth, height: capsuleHeight),
            xRadius: capsuleWidth / 2, yRadius: capsuleWidth / 2)
        capsule.fill()

        // 托架：一道下半圆（180° → 360° 逆时针经过 270°，也就是正下方）
        let cradle = NSBezierPath()
        cradle.appendArc(withCenter: NSPoint(x: cx, y: top - Ratio.cradleCenter * h),
                         radius: Ratio.cradleRadius * h,
                         startAngle: 180, endAngle: 360, clockwise: false)
        cradle.lineWidth = Ratio.cradleStroke * h
        cradle.lineCapStyle = .butt
        cradle.stroke()

        // 立柱 + 底座
        let stemWidth = Ratio.stemWidth * h
        let baseHeight = Ratio.baseHeight * h
        let baseTop = rect.midY - h / 2 + baseHeight
        NSBezierPath(rect: NSRect(x: cx - stemWidth / 2, y: baseTop - 1,
                                  width: stemWidth,
                                  height: (top - Ratio.stemTop * h) - baseTop + 1)).fill()
        let baseWidth = Ratio.baseWidth * h
        NSBezierPath(roundedRect:
            NSRect(x: cx - baseWidth / 2, y: rect.midY - h / 2,
                   width: baseWidth, height: baseHeight),
            xRadius: baseHeight / 2, yRadius: baseHeight / 2).fill()

        // 左右各两道声波弧
        let waveY = top - Ratio.waveCenter * h
        for mirrored in [false, true] {
            let sign: CGFloat = mirrored ? 1 : -1
            let center = NSPoint(x: cx + sign * Ratio.waveOffset * h, y: waveY)
            for radius in [Ratio.waveOuter, Ratio.waveInner] {
                let arc = NSBezierPath()
                // 弧一律朝外鼓（凹面对着话筒），左右两组互为镜像
                let mid: CGFloat = mirrored ? 0 : 180
                arc.appendArc(withCenter: center, radius: radius * h,
                              startAngle: mid - Ratio.waveSweep,
                              endAngle: mid + Ratio.waveSweep,
                              clockwise: false)
                arc.lineWidth = Ratio.waveStroke * h
                arc.lineCapStyle = .butt
                arc.stroke()
            }
        }
    }
}
