import AppKit
import SwiftUI

// MARK: - 悬浮窗状态

/// 5.2.0 起悬浮窗**不再用文字说状态**（UX 方案 §3 C，用户 2026-09-29 定）：
/// 「正在听… / 润色中… / 已输入」这些字全删了，状态由形态说——
///   听 = 呼吸红点 + 渐变波形（+ 实时字数）；想 = 一条流动的渐变光带；
///   落 = 一枚渐变勾（5.4.1 起不带字；指令模式带一行回执）；错 = 红边 + 一句话 + 一颗按钮；
///   指令 = 听的形态下面多一行「说出你要改的」。
final class OverlayState: ObservableObject {
    enum Phase: Equatable {
        /// 录音中（纯听写）
        case listening
        /// 录音中，按住满 0.6 s 升级成了指令模式
        case command
        /// 松手 → 交付之前（识别 / 润色 / 指令在飞）
        case thinking
        /// 交付完成的那一下确认
        case done(OverlayDone)
        /// 出错（挡住了、一个字没插进去、要用户动手：缺 Key / 401 / 网络失败）：
        /// 红边 + 一颗按钮，不自动消失，Esc 或点按钮才关
        case error(String)
        /// 告知（已经发生了、没什么可点：没听到内容、润色失败已给原文、设备被拔、到时长上限、
        /// 分段丢了尾巴…）：黄调小字，无红边无按钮，2.5 s 自己走（用户 2026-09-29 定）
        case warning(String)
        /// 中性提示（「已取消」这类用户主动动作）：既不是成功也不是错误
        case notice(String)
        /// 告知（「已更新到 x.y.z」）：办成了的事，但不值得道喜
        case info(String)
    }

    // 占位初值，显示前必然会被 showRecording / showThinking 覆盖
    @Published var phase: Phase = .listening
    /// 最新一格麦克风电平（0–1）。波形每帧从它平滑出 14 根条的高度（见 WaveformModel）
    @Published var level: Float = 0
    /// 实时识别 partial 文本的字数。nil = 这一轮没有实时（整段上传那条路）→ 不显示计数
    @Published var charCount: Int?
    /// 2 分钟起右端的「已录 / 上限」计时；nil = 不显示
    @Published var clock: String?
    /// 最后 30 s：计时变红并加一句「即将自动收尾」
    @Published var clockWarning = false
    /// 「想」形态下的附注。**只在不寻常的时候有**（分段进度、自动重试、Esc 之后在收尾），
    /// 平常的识别 / 润色 / 指令一个字都不写
    @Published var caption: String?
    /// 错误形态那颗按钮的字（「打开设置」/「关闭」）
    @Published var buttonLabel: String?
    /// 入场/退场：true = 已就位（不透明）。由 OverlayController 用动画翻转
    @Published var presented = false
    /// 入场位移（上移 6 pt）是否已经走完。和 presented 分开：退场只淡出，不往下掉
    @Published var settled = false
    /// 胶囊贴面板顶边（顶部居中）还是底边
    @Published var topAligned = false

    /// 分段识别到一半按 Esc 是"收尾并输入"还是"丢弃"（判据在 DictationController.escFinishesEarly）。
    /// 5.4.1 起 esc 键帽的读屏旁白按它换句话，所以是 published
    @Published var cancelFinishes = false

    /// 按钮 / 「落」那颗胶囊在面板坐标系（SwiftUI，原点左上）里的位置，由视图量出来回填。
    /// 故意**不是** @Published：只给 AppKit 的命中判定读，设成 published 会让布局回填再触发重绘，绕成死循环。
    var buttonHitRect: CGRect = .zero
    var doneHitRect: CGRect = .zero

    /// 波形的帧间平滑状态（不是 published：TimelineView 每帧自己来取）
    let waveform = WaveformModel()

    /// 这一刻错误按钮能不能点
    var isActionable: Bool {
        guard case .error = phase else { return false }
        return buttonLabel != nil
    }

    /// 这一刻「落」那颗胶囊能不能点（= 换回识别原文）
    var isDoneTappable: Bool {
        guard case .done(let done) = phase else { return false }
        return done.revertible
    }

    func pushLevel(_ level: Float) {
        self.level = max(0, min(1, level))
    }

    func resetLevels() {
        level = 0
        waveform.reset()
    }
}

/// 「落」形态的内容
struct OverlayDone: Equatable {
    enum Body: Equatable {
        /// 纯听写交付：只有一枚渐变勾，**一个字都不写**（5.4.1，用户 2026-09-29 试用 5.4.0 后定：
        /// 5.2–5.4 的「原文 → 润色」那一行和「成稿前 16 字」都删了）
        case check
        /// 一行回执：指令模式（「已改写 · ⌘Z 撤销」「已输入 · ⌘Z 撤销」）和几句一次性的确认
        /// （「已换回识别原文」「麦克风已授权」）
        case text(String)
    }

    let body: Body
    /// 点胶囊 = 换回识别原文（只有"纯听写 + 润色改了字 + 确实粘进去了"那一次）
    var revertible: Bool = false
}

// MARK: - 错误按钮是哪一颗（调用处点名）

/// 错误形态那颗按钮。**5.3.0 起由调用处点名**，不再按文案里的关键词去猜：
/// 5.2.0 的 classify 看文案里有没有「API Key」「401」——文案一改短（UX 方案 §3 H），
/// 那几个字就不在了，按钮会悄悄从「打开设置」退成「关闭」，而且没有任何测试会红。
/// 现在每条错误在**产生它的地方**就带着自己的按钮（MTError.action / LLMUsage.failureAction /
/// RecognitionEngineReadiness.overlayAction），悬浮窗只照着画。
enum OverlayErrorAction: Equatable {
    /// Key 没填 / 被拒（401）：唯一能修的地方就是设置里的 Key 那一栏
    case openSettings
    /// 余额不足（429 insufficient_quota）：去 OpenAI 的充值页。
    /// 5.2.0 之前这条链接是拼在错误句尾的一整串 URL（ErrorCopy.fullText）——
    /// 16 字一句话装不下它，而它恰恰是这类错误唯一的下一步，所以给它一颗按钮
    case addCredit
    /// 其余（网络、超时、限流、没听到…）：设置里没有任何一个开关能修，给一颗「关闭」
    case dismiss

    var label: String {
        switch self {
        case .openSettings: return OverlayCopy.openSettings
        case .addCredit: return tr("去充值", "Add credit")
        case .dismiss: return tr("关闭", "Close")
        }
    }
}

/// 悬浮窗上的固定文案（其余一律来自调用方）
enum OverlayCopy {
    static var openSettings: String { tr("打开设置", "Open Settings") }

    /// 指令模式那一行
    static var commandHint: String { tr("说出你要改的", "Say what to change") }

    /// 实时字数
    static func charCount(_ n: Int) -> String { tr("\(n) 字", "\(n) chars") }

    /// Esc 键帽的旁白（键帽上印的是键名 `esc`，与界面语言无关，读屏读这一句）。
    /// 分段识别到一半时 Esc 是「收尾并输入」不是丢弃，旁白照实说
    static func escHint(finishes: Bool) -> String {
        finishes ? tr("按 Esc 收尾并输入", "Press Esc to finish and insert")
                 : tr("按 Esc 取消", "Press Esc to cancel")
    }

    /// 「落」那枚勾可点时的旁白（换回识别原文）。面板不接鼠标，悬停提示出不来，只剩读屏这一处
    static var revertHint: String { tr("点一下换回原文", "Click to restore the raw text") }

    /// 最后 30 s 跟在计时后面的那句（与 5.1 的「即将自动收尾」同一句话）
    static var wrappingUpSoon: String { tr("即将自动收尾", "wrapping up soon") }

    /// 字数怎么数：不算空白（英文里的空格不是"说了的字"）
    static func countCharacters(_ text: String) -> Int {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }
}

// MARK: - 波形

/// 14 根条的高度。电平约每 85 ms 来一格，画面要 ≥ 30 fps：所以每根条都在"当前电平"上
/// 乘一个自己的慢正弦（随机相位、略不同的速度），再对上一帧做指数平滑——
/// 声音大条就高、没声音就伏下去，但不会整排齐刷刷一起跳（那看起来像电平表，不像声音）。
final class WaveformModel {
    static let barCount = 14

    private var smoothed = [CGFloat](repeating: 0, count: WaveformModel.barCount)
    private let phases: [Double]
    private let speeds: [Double]

    init(seed: UInt64 = 0x4D69_6354_7970_65) {
        var rng = SplitMix(seed: seed)
        phases = (0..<Self.barCount).map { _ in rng.nextUnit() * 2 * .pi }
        speeds = (0..<Self.barCount).map { _ in 5.0 + rng.nextUnit() * 4.0 }
    }

    func reset() {
        smoothed = [CGFloat](repeating: 0, count: Self.barCount)
    }

    /// 这一帧的 14 个高度（0–1）。有副作用：推进平滑状态，所以每帧只调一次
    func frame(level: Float, time: TimeInterval) -> [CGFloat] {
        let targets = Self.targets(level: level, time: time, phases: phases, speeds: speeds)
        for i in 0..<Self.barCount {
            smoothed[i] = Self.smooth(previous: smoothed[i], target: targets[i])
        }
        return smoothed
    }

    /// 纯函数：电平 × 每根条自己的相位 → 目标高度（0–1）。电平 0 时全部伏在 0
    static func targets(level: Float, time: TimeInterval,
                        phases: [Double], speeds: [Double]) -> [CGFloat] {
        let l = Double(max(0, min(1, level)))
        return zip(phases, speeds).map { phase, speed in
            // 起伏幅度 0.3–1：设计稿里同一时刻的 14 根条从 8 pt 到 34 pt 都有，太齐就像电平表
            let wobble = 0.3 + 0.7 * (0.5 + 0.5 * sin(time * speed + phase))
            return CGFloat(min(1, l * wobble * 1.25))
        }
    }

    /// 纯函数：上升快、回落慢（像 VU 表），读起来"跟得上嘴"又不抖
    static func smooth(previous: CGFloat, target: CGFloat) -> CGFloat {
        let factor: CGFloat = target > previous ? 0.45 : 0.18
        return previous + (target - previous) * factor
    }

    /// 可复现的伪随机（每次启动同一副相位：快照测试才拍得出同一张图）
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func nextUnit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }
}

// MARK: - 悬浮窗位置的几何常量（视图与控制器共用）

enum OverlayMetrics {
    /// 胶囊在面板里的外边距（OverlayContainer 最外层的 .padding）
    static let contentInset: CGFloat = 16
    /// 胶囊最宽 520（「落」那一行按内容撑开，到这里为止）
    static let capsuleMaxWidth: CGFloat = 520
    /// 面板尺寸：装得下最宽的胶囊 + 两侧外边距，高度装得下指令形态（84）和两行错误
    static let panelSize = CGSize(width: capsuleMaxWidth + 2 * contentInset + 8, height: 160)
    /// 设计稿尺寸
    static let capsuleHeight: CGFloat = 56
    static let commandHeight: CGFloat = 84
    static let thinkingWidth: CGFloat = 236
}

// MARK: - 悬浮窗视图

struct OverlayView: View {
    @ObservedObject var state: OverlayState

    private var reduceMotion: Bool { Theme.reduceMotion }

    var body: some View {
        capsule
            .animation(Theme.springOrNone, value: state.phase)
            .opacity(state.presented ? 1 : 0)
            // 出现 = 淡入 + 上移 6 pt；「减弱动态效果」开着就不位移
            .offset(y: state.settled || reduceMotion ? 0 : 6)
    }

    @ViewBuilder
    private var capsule: some View {
        switch state.phase {
        case .listening:
            MTCapsule {
                ListeningRow(state: state)
                    .padding(.horizontal, 22)
            }
            // 给右端「计时 · 字数 · esc」一个宽度上限：装不下时 ListeningRow 先省字数
            .frame(maxWidth: OverlayMetrics.capsuleMaxWidth)
        case .command:
            MTCapsule(height: OverlayMetrics.commandHeight, radius: 22) {
                VStack(spacing: 0) {
                    ListeningRow(state: state)
                        .frame(height: 40)
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                    Text(OverlayCopy.commandHint)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        .padding(.top, 8)
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        case .thinking:
            MTCapsule {
                HStack(spacing: 14) {
                    ThinkingBand()
                        .frame(width: OverlayMetrics.thinkingWidth * 0.7, height: 3)
                    if let caption = state.caption {
                        Text(caption)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.muted)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    EscKeycap(finishes: state.cancelFinishes)
                }
                // 右端有了 esc 键帽，右边距收成与听形态一样的 22；左边照旧
                .padding(.leading, state.caption == nil ? OverlayMetrics.thinkingWidth * 0.15 : 26)
                .padding(.trailing, 22)
            }
        case .done(let done):
            switch done.body {
            case .check:
                // 只有一枚勾：左右 16 的内边距让 56 高的胶囊正好收成一个圆。
                // 整颗胶囊就是可点区（换回原文），量出来给 AppKit 的命中判定
                MTCapsule {
                    CheckBadge()
                        .padding(.horizontal, 16)
                }
                .background(
                    GeometryReader { geo -> Color in
                        state.doneHitRect = geo.frame(in: .named(OverlayContainer.space))
                        return Color.clear
                    }
                )
                .accessibilityElement(children: .ignore)
                // 读屏：能换回时说怎么换，不能换时只说"已输入"（与 deliver 的回执同一句）
                .accessibilityLabel(done.revertible ? OverlayCopy.revertHint : tr("已输入", "Inserted"))
            case .text(let text):
                MTCapsule {
                    HStack(spacing: 14) {
                        CheckBadge()
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 22)
                }
                .frame(maxWidth: OverlayMetrics.capsuleMaxWidth)
            }
        case .error(let message):
            // 半径 28 = 单行时恰好是胶囊；错误话长到两行时自然变成圆角矩形，不被弧边啃字
            MTCapsule(radius: 28, danger: true) {
                HStack(spacing: 16) {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let label = state.buttonLabel {
                        MTButton(title: label, style: .quiet)
                            .background(
                                GeometryReader { geo -> Color in
                                    state.buttonHitRect = geo.frame(in: .named(OverlayContainer.space))
                                    return Color.clear
                                }
                            )
                    }
                }
                .padding(.leading, 24)
                .padding(.trailing, state.buttonLabel == nil ? 24 : 10)
                .padding(.vertical, 11)
            }
            .frame(maxWidth: OverlayMetrics.capsuleMaxWidth)
        case .warning(let message):
            MTCapsule(radius: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(Theme.warning)
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.warning.opacity(0.9))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
            }
            .frame(maxWidth: OverlayMetrics.capsuleMaxWidth)
        case .notice(let message):
            plain(message, symbol: "xmark.circle.fill")
        case .info(let message):
            plain(message, symbol: "info.circle.fill")
        }
    }

    /// 中性 / 告知：一枚单色图标 + 一句话（不用强调色：它们不是"正在发生"的东西）
    private func plain(_ message: String, symbol: String) -> some View {
        MTCapsule(radius: 28) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundColor(Theme.muted)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
        }
        .frame(maxWidth: OverlayMetrics.capsuleMaxWidth)
    }
}

/// 听：呼吸红点 + 14 根渐变波形条 + 右端单色字数（+ 2 分钟起的计时）
private struct ListeningRow: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        HStack(spacing: 18) {
            if Theme.reduceMotion {
                RecordingDot(glow: 1)
                // 减弱动态效果：只有一根横条随电平变长，不跳、不插值
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accentA, Theme.accentB],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 12 + 82 * CGFloat(state.level), height: 3)
                    .frame(width: 94, alignment: .leading)
            } else {
                // 30 fps 足够"跟得上嘴"，再高只是白烧 CPU（悬浮窗常驻在别人的工作区上方）
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 18) {
                        // 1.2 s 一呼一吸
                        RecordingDot(glow: 0.5 + 0.5 * cos(2 * .pi * t / 1.2))
                        WaveformBars(heights: state.waveform.frame(level: state.level, time: t))
                    }
                }
            }
            // 右端顺序：计时 · 字数 · esc。宽度不够（最后 30 s 计时后面还跟着一句）时
            // 先省字数，esc 永远在——它是这一刻唯一的退路
            ViewThatFits(in: .horizontal) {
                trailing(showCount: true)
                trailing(showCount: false)
            }
        }
    }

    private func trailing(showCount: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 18) {
                if let clock = state.clock {
                    Text(state.clockWarning ? clock + " · " + OverlayCopy.wrappingUpSoon : clock)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundColor(state.clockWarning ? Theme.danger : Theme.muted)
                        .fixedSize()
                }
                if showCount, let count = state.charCount {
                    Text(OverlayCopy.charCount(count))
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(Theme.muted)
                        .frame(minWidth: 34, alignment: .trailing)
                        .fixedSize()
                }
            }
            EscKeycap(finishes: state.cancelFinishes)
        }
    }
}

/// 听 / 指令 / 想三种形态右端的小键帽：告诉用户这一刻按 Esc 能退出（用户 2026-09-29 试用 5.4.0 后要求）。
/// 纯提示、不可点（面板 ignoresMouseEvents，照旧）。落 / 错 / 告知不显示：错误本来就是 Esc 关
private struct EscKeycap: View {
    /// 这一刻 Esc 是「收尾并输入」（分段识别到一半）还是取消：只影响读屏旁白
    var finishes = false

    var body: some View {
        // 印的是键帽上的字，不是一句话：中英界面都是 esc，所以不走 tr()；读屏走 escHint
        Text(verbatim: "esc")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Color.white.opacity(0.6))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OverlayCopy.escHint(finishes: finishes))
    }
}

private struct RecordingDot: View {
    /// 0–1：呼吸到哪儿了
    let glow: Double

    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: 10, height: 10)
            .opacity(0.7 + 0.3 * glow)
            .background(
                Circle()
                    .fill(Theme.danger.opacity(0.18 * glow))
                    .frame(width: 18, height: 18))
            .shadow(color: Theme.danger.opacity(0.6 * glow), radius: 5)
    }
}

private struct WaveformBars: View {
    let heights: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<heights.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accentGradientVertical)
                    .frame(width: 3, height: 4 + 30 * heights[i])
            }
        }
        .frame(height: 36)
    }
}

/// 想：一条 3 pt 的渐变光带，一道亮处从左流到右（1.2 s 一趟）。减弱动态效果时是静止的渐变
private struct ThinkingBand: View {
    private static let stops: [Gradient.Stop] = [
        .init(color: Theme.accentA.opacity(0), location: 0),
        .init(color: Theme.accentA, location: 0.3),
        .init(color: Color(hex: 0xB3A8FF), location: 0.5),
        .init(color: Theme.accentB, location: 0.7),
        .init(color: Theme.accentB.opacity(0), location: 1),
    ]

    var body: some View {
        if Theme.reduceMotion {
            band(center: 0.5, width: 1)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let progress = t.truncatingRemainder(dividingBy: 1.2) / 1.2
                // 亮处从左外侧 -0.3 走到右外侧 1.3：进场和离场都是从边上"流"进来的
                band(center: -0.3 + 1.6 * progress, width: 0.6)
            }
        }
    }

    private func band(center: Double, width: Double) -> some View {
        ZStack {
            // 底：整条淡淡的品牌色，亮处走开之后光带也不会消失
            Capsule().fill(LinearGradient(colors: [Theme.accentA.opacity(0.25), Theme.accentB.opacity(0.25)],
                                          startPoint: .leading, endPoint: .trailing))
            Capsule().fill(LinearGradient(stops: Self.stops,
                                          startPoint: UnitPoint(x: center - width / 2, y: 0.5),
                                          endPoint: UnitPoint(x: center + width / 2, y: 0.5)))
        }
        .shadow(color: Theme.accentText.opacity(0.55), radius: 5)
    }
}

/// 落：24 pt 渐变圆 + 白勾，勾用 0.25 s 描绘一次
private struct CheckBadge: View {
    @State private var drawn: CGFloat = Theme.reduceMotion ? 1 : 0

    var body: some View {
        ZStack {
            Circle().fill(Theme.accentGradient)
            CheckShape()
                .trim(from: 0, to: drawn)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 13)
        }
        .frame(width: 24, height: 24)
        .onAppear {
            guard drawn < 1 else { return }
            withAnimation(.easeOut(duration: 0.25)) { drawn = 1 }
        }
    }
}

/// 设计稿里那枚勾（16 × 16 画布里的 M3.5 8.5 l3 3 6-7），按实际尺寸缩放
private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 3.5 * s, y: rect.minY + 8.5 * s))
        p.addLine(to: CGPoint(x: rect.minX + 6.5 * s, y: rect.minY + 11.5 * s))
        p.addLine(to: CGPoint(x: rect.minX + 12.5 * s, y: rect.minY + 4.5 * s))
        return p
    }
}

/// 悬浮窗永远不当 key / main 窗口：点按钮也不该把目标应用里的光标和焦点抢走
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 悬浮窗控制器

final class OverlayController {

    let state = OverlayState()
    /// 点「落」那颗胶囊（= 换回识别原文）。DictationController 接到 revertToRaw()
    var onRevertTapped: (() -> Void)?
    /// 错误形态「打开设置」那颗按钮（AppDelegate 接到设置窗口）
    var onOpenSettings: (() -> Void)?
    /// 错误形态上屏 / 下屏（5.4.0：菜单栏图标的红点跟着它亮灭，AppDelegate 接）
    var onErrorVisibilityChange: ((Bool) -> Void)?
    /// 屏幕上此刻是不是挂着一条错误。进错误形态时置真；**任何**别的形态或 hide() 都会先走
    /// clearAction()，在那里置假——所以不会有"错误早就被顶掉了、红点还亮着"的时候
    private(set) var errorShowing = false {
        didSet {
            guard errorShowing != oldValue else { return }
            onErrorVisibilityChange?(errorShowing)
        }
    }
    /// 当前这条错误上那颗按钮要干的事。每条提示自带一个，提示消失就清掉——
    /// 绝不让上一条的动作挂到下一条上。
    private var pendingAction: (() -> Void)?

    private var panel: NSPanel?
    private var hideGeneration = 0
    /// 这一轮「想」是不是已经开始了（附注只在想的时候有意义）
    private var thinking = false

    /// 退场 0.12 s：够看出"它走了"，又不挡在用户前面
    private static let dismissDuration: Double = 0.12
    /// 底部居中的老坐标：容器贴底后胶囊底边比面板底边高 contentInset，+35 补回
    /// 原先居中布局的 7pt，屏幕上的位置与 3.2.19 完全一致
    private static let bottomMargin: CGFloat = 35
    /// 跟随指针时胶囊底边距指针的高度（像 tooltip 那样浮在指针上方一点）
    private static let cursorGap: CGFloat = 18
    /// 跟随指针时给胶囊预留的最大高度：指针贴着屏幕顶边时按这个高度往下让
    private static let cursorCapsuleReserve: CGFloat = 108
    /// 带一行回执的「落」停留多久（设计稿 1.2 s：要读一行字）
    static let doneDuration: Double = 1.2
    /// 只有一枚勾的「落」停 0.8 s（用户 2026-09-29 定，5.4.1）：没有字要读。
    /// 指针正停在胶囊上时顺延（见 scheduleDoneHide），想点它换回原文不会扑空
    static let checkDoneDuration: Double = 0.8
    /// 告知形态停多久
    static let warningDuration: Double = 2.5

    private var reduceMotion: Bool { Theme.reduceMotion }

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
        // 永远不接鼠标。**别为了"能点按钮"把它放开**：ignoresMouseEvents 一旦为 false，
        // 窗口服务器就按这块面板画出来的像素把点击投给 MicType，下面的应用永远收不到——
        // 用户在聊天输入框里点一下定位光标、或者在胶囊上滚一下滚轮，全被这层悄悄吃掉
        // （5.2.0–5.4.0 胶囊跟着前台窗口走时正压在它的输入框上方，屏幕底部也一样可能盖着东西）。
        // 按钮与「落」那颗胶囊改由全局鼠标监听按屏幕坐标判（installMouseMonitors）。
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: p.contentRect(forFrameRect: p.frame))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: OverlayContainer(state: state))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        p.contentView = container
        panel = p
        #if DEBUG
        // 重建路径漏掉 close() 的话，旧面板会连着 NSHostingView 一直挂在 NSApp 的窗口表上
        assert(NSApp.windows.filter { $0 is OverlayPanel }.count <= 1,
               "悬浮窗面板泄漏：重建时必须 close() 旧的那个")
        #endif
        return p
    }

    /// 本轮锚定下来的面板左下角。一轮里 present() 会被调好几次（听 → 想 → 落），
    /// 要是每次都重新量鼠标所在屏 / 指针，这几次之间用户早就挪走了，胶囊会在屏幕上跳。
    /// 所以只在"这一轮第一次现身"时量一次，本轮后面一律复用。
    private var latchedOrigin: CGPoint?

    private func position(_ p: NSPanel, relocate: Bool) {
        let choice = Settings.shared.overlayPosition
        // 顶部居中时胶囊贴面板顶边，其余贴底边
        state.topAligned = (choice == .topCenter)
        if !relocate, let origin = latchedOrigin {
            p.setFrameOrigin(origin)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let fallback = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        guard let origin = OverlayController.anchoredOrigin(choice: choice,
                                                            panelSize: p.frame.size,
                                                            screens: screens,
                                                            fallbackVisibleFrame: fallback,
                                                            mouse: mouse) else { return }
        latchedOrigin = origin
        p.setFrameOrigin(origin)
    }

    /// 胶囊落在哪（面板左下角）。纯函数，选屏与落点靠单测守（OverlayPositionTests）。
    ///
    /// 5.4.1 撤销了 5.2.0 的「跟随前台窗口」（用户 2026-09-29 试用 5.4.0 后要求）：默认那一档
    /// 回到**固定在屏幕底部居中**，与 5.1 及更早逐像素一致，不再读 AX 焦点窗口。
    /// 多屏：鼠标在哪块屏就用哪块（用户正在操作的那块），鼠标落在屏幕之间的缝里就用主屏。
    /// 顶部居中 / 跟随指针（旧版设置或导入的设置文件）照旧。
    static func anchoredOrigin(choice: OverlayPosition,
                               panelSize: CGSize,
                               screens: [(frame: CGRect, visibleFrame: CGRect)],
                               fallbackVisibleFrame: CGRect?,
                               mouse: CGPoint) -> CGPoint? {
        guard let visibleFrame = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })?.visibleFrame
                ?? fallbackVisibleFrame ?? screens.first?.visibleFrame else { return nil }
        return panelOrigin(position: choice, panelSize: panelSize,
                           visibleFrame: visibleFrame, mouse: mouse)
    }

    /// 面板左下角坐标（屏幕固定位置那三档）。纯函数（只吃几何量、不碰 AppKit 状态）。
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

    // MARK: 听

    /// 开录：听（或指令）形态。计数、计时、附注一律清零——上一轮的数不能带进这一轮
    func showRecording(command: Bool = false) {
        hideGeneration += 1
        thinking = false
        clearAction()
        state.resetLevels()
        state.charCount = nil
        state.clock = nil
        state.clockWarning = false
        state.caption = nil
        state.cancelFinishes = false
        state.phase = command ? .command : .listening
        present(context: command ? "command" : "recording")
    }

    /// 按住满 0.6 s：就地升级成指令形态。录音不断、波形不重置、面板不闪
    func setCommandMode() {
        guard state.phase == .listening else { return }
        state.phase = .command
    }

    /// 2 分钟起的「已录 / 上限」计时（最后 30 s 带预警）。只在听 / 指令形态下生效
    func updateClock(_ clock: String?, warning: Bool) {
        guard state.phase == .listening || state.phase == .command else { return }
        if state.clock != clock { state.clock = clock }
        if state.clockWarning != warning { state.clockWarning = warning }
    }

    /// 实时识别的中间结果：5.2.0 起**只拿来数字数**，灰字草稿整段删了（UX 方案 §3 C：
    /// 字数证明它在听，又不会让人以为"字停了 = 录完了"）
    func showDraft(_ text: String) {
        guard state.phase == .listening || state.phase == .command else { return }
        let count = OverlayCopy.countCharacters(text)
        guard state.charCount != count else { return }
        state.charCount = count
    }

    /// 处理中那一刻按 Esc 是"收尾并输入"还是"丢弃"（见 OverlayState.cancelFinishes）
    func setCancelFinishes(_ flag: Bool) {
        state.cancelFinishes = flag
    }

    // MARK: 想

    /// 松手 → 交付之前：一条流动的光带。caption 只给不寻常的时刻（分段进度、自动重试、收尾中）
    func showThinking(caption: String? = nil) {
        hideGeneration += 1
        clearAction()
        state.caption = caption
        state.cancelFinishes = false
        thinking = true
        state.phase = .thinking
        present(context: "thinking")
    }

    /// 想到一半换附注（分段进度 / 收尾中）。不重新 present：每出一段闪一下没必要
    func updateThinking(caption: String?) {
        guard thinking else { return }
        state.caption = caption
    }

    /// 处理中被拒绝的手势（轻点/按住）：闪一句提示后回到「想」，绝不用这条提示把进度擦掉
    func flashOverProcessing(_ label: String, duration: Double = 1.6) {
        guard thinking else {
            flashWarning(label)
            return
        }
        hideGeneration += 1
        let generation = hideGeneration
        state.phase = .notice(label)
        present(context: "flash-busy")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.hideGeneration == generation, self.thinking else { return }
            self.state.phase = .thinking
        }
    }

    // MARK: 落

    /// 交付完成。停 duration 后淡出；可点（换回原文）的胶囊被指针压着时顺延
    func flashDone(_ done: OverlayDone, duration: Double = OverlayController.doneDuration) {
        hideGeneration += 1
        thinking = false
        clearAction()
        state.doneHitRect = .zero
        state.phase = .done(done)
        present(context: "done")
        scheduleDoneHide(after: duration, generation: hideGeneration)
    }

    /// 一句话的「落」（麦克风已授权、已换回原文、已复制到剪贴板…）
    func flashSuccess(_ label: String, duration: Double = OverlayController.doneDuration) {
        flashDone(OverlayDone(body: .text(label)), duration: duration)
    }

    /// 可点的那枚勾只停 0.8 s，而把指针挪过去就要差不多这么久：指针已经停在胶囊上的话
    /// 再给一轮（最多顺延到 6 s），挪开就照常淡出
    private func scheduleDoneHide(after delay: Double, generation: Int, extensions: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.hideGeneration == generation else { return }
            if extensions < 4, self.state.isDoneTappable,
               let rect = self.screenRect(self.state.doneHitRect),
               rect.contains(NSEvent.mouseLocation) {
                self.scheduleDoneHide(after: OverlayController.doneDuration, generation: generation,
                                      extensions: extensions + 1)
                return
            }
            self.hide()
        }
    }

    // MARK: 错

    /// 错误：红边 + 一句话 + 一颗按钮。**不自动消失**（UX 方案 §3 C），Esc 或点按钮才关。
    /// 按钮由调用处点名（5.3.0 起，见 OverlayErrorAction）：Key 没填 / 被拒 →「打开设置」，
    /// 余额不足 →「去充值」，其余 →「关闭」。
    func flashError(_ label: String, action: OverlayErrorAction) {
        logError(label, button: action.label)
        switch action {
        case .openSettings:
            showError(label, buttonLabel: action.label) { [weak self] in self?.onOpenSettings?() }
        case .addCredit:
            showError(label, buttonLabel: action.label) {
                guard let url = URL(string: LLMCatalog.billingURL) else { return }
                Log.info("Overlay error action: open billing page")
                NSWorkspace.shared.open(url)
            }
        case .dismiss:
            showError(label, buttonLabel: action.label, action: nil)
        }
    }

    /// 一条已经带着按钮的错误（MTError 自己知道该去哪）
    func flashError(_ error: MTError) {
        flashError(error.message, action: error.action)
    }

    /// 带指定动作的错误（调用方自己知道该去哪，如「打开设置」→ 设置窗口的 Key 那一栏）。
    /// duration 参数 5.2.0 起不再用（错误不自动消失），留着只为不改调用方的签名
    func flashError(_ label: String, actionLabel: String, duration: Double = 0,
                    action: @escaping () -> Void) {
        logError(label, button: actionLabel)
        showError(label, buttonLabel: actionLabel, action: action)
    }

    /// Esc（录音 / 处理都不在进行时）：关掉屏幕上那条错误。别的形态不归它管
    func dismissError() {
        guard case .error = state.phase, panel?.isVisible == true else { return }
        Log.info("Overlay error dismissed by Esc")
        hide()
    }

    private func showError(_ label: String, buttonLabel: String, action: (() -> Void)?) {
        hideGeneration += 1
        thinking = false
        clearAction()
        errorShowing = true
        pendingAction = action
        state.buttonLabel = buttonLabel
        state.phase = .error(label)
        present(context: "error")
    }

    /// 屏幕上闪过的每一句错误都要进日志（4.0.1 的硬规矩）。记的是**给用户看的那句文案**
    /// （它本来就只含状态码、服务商错误码和我们自己的话），绝不含 Key、音频或转写文本。
    private func logError(_ label: String, button: String?) {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Log.warn("Overlay error: " + String(text.prefix(240)) + (button.map { " [button: \($0)]" } ?? ""))
    }

    // MARK: 告知（黄调小字，2.5 s）

    /// 已经发生了、没什么可点的事。**由调用方决定**走这里还是 flashError（不按关键词猜）。
    /// 同样进日志：屏幕上的每一句"不顺利"都要能远程排查（4.0.1 的硬规矩）
    func flashWarning(_ label: String, duration: Double = OverlayController.warningDuration) {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { Log.warn("Overlay notice: " + String(text.prefix(240))) }
        flash(.warning(label), duration: duration)
    }

    // MARK: 中性 / 告知

    /// 用户主动动作的回执（「已取消」）
    func flashNotice(_ label: String, duration: Double = 1.0) {
        flash(.notice(label), duration: duration)
    }

    /// 办成了、但不值得道喜的一句（「已更新到 x.y.z」）
    func flashInfo(_ label: String, duration: Double = 1.0) {
        flash(.info(label), duration: duration)
    }

    private func flash(_ phase: OverlayState.Phase, duration: Double) {
        hideGeneration += 1
        thinking = false
        clearAction()
        let generation = hideGeneration
        state.phase = phase
        present(context: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.hideGeneration == generation else { return }
            self.hide()
        }
    }

    /// 按钮只属于当前这一条提示
    private func clearAction() {
        errorShowing = false
        pendingAction = nil
        state.buttonLabel = nil
        state.buttonHitRect = .zero
        pressedButtonRect = nil
        pressedDoneRect = nil
    }

    // MARK: 点按钮 / 点「落」那颗胶囊

    /// 按下那一刻量到的可点矩形（屏幕坐标）。按下与松手之间胶囊完全可能重排，
    /// 拿松手时的新几何去判"有没有拖出去"，这一下就被静默丢掉了
    private var pressedButtonRect: CGRect?
    private var pressedDoneRect: CGRect?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    /// 面板坐标（SwiftUI，y 轴朝下）→ 屏幕坐标（y 轴朝上）。小目标再给 4pt 容错，
    /// 别让用户点三次才中。
    private func screenRect(_ rect: CGRect) -> CGRect? {
        guard let p = panel, p.isVisible, !rect.isEmpty else { return nil }
        let frame = p.frame
        return CGRect(x: frame.minX + rect.minX,
                      y: frame.minY + (frame.height - rect.maxY),
                      width: rect.width,
                      height: rect.height)
            .insetBy(dx: -4, dy: -4)
    }

    /// 只在"有东西可点"时装监听，其余时候一个鼠标事件都不看
    private func updateMouseMonitors() {
        if state.isActionable || state.isDoneTappable, let p = panel, p.isVisible {
            installMouseMonitors()
        } else {
            removeMouseMonitors()
        }
    }

    /// 用全局 + 本地鼠标监听来接这一下，而不是把面板设成 ignoresMouseEvents = false：
    /// 后者会让整块面板截走点击和滚轮。监听只是"看一眼"，不消费事件——点按钮的同时也会在
    /// 目标应用里点一下（多半就是输入框，无害），换来的是胶囊其余部分彻底不挡路。
    /// 全局监听只收别的 App 的事件，MicType 自己在前台时靠本地那条。
    private func installMouseMonitors() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) {
            [weak self] event in
            self?.handleMouse(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) {
            [weak self] event in
            self?.handleMouse(event)
            return event      // 绝不吞：本地事件还要照常送给 MicType 自己的窗口
        }
    }

    private func removeMouseMonitors() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        pressedButtonRect = nil
        pressedDoneRect = nil
    }

    private func handleMouse(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            // 按下时把矩形定格：之后胶囊怎么重排都不影响这一下的判定
            pressedButtonRect = state.isActionable
                ? screenRect(state.buttonHitRect).flatMap { $0.contains(location) ? $0 : nil } : nil
            pressedDoneRect = state.isDoneTappable
                ? screenRect(state.doneHitRect).flatMap { $0.contains(location) ? $0 : nil } : nil
        case .leftMouseUp:
            let pressedButton = pressedButtonRect
            let pressedDone = pressedDoneRect
            pressedButtonRect = nil
            pressedDoneRect = nil
            // 按下之后拖出去再松手不算点击，和系统按钮一个脾气
            if let rect = pressedButton, rect.contains(location), state.isActionable {
                Log.info("Overlay error button tapped")
                let action = pendingAction
                hide()
                action?()
                return
            }
            if let rect = pressedDone, rect.contains(location), state.isDoneTappable {
                Log.info("Overlay done line tapped (revert to raw)")
                hide()
                onRevertTapped?()
            }
        default:
            break
        }
    }

    // MARK: 现身 / 下线

    /// 统一的显示入口：定位 → 置顶 → 回读真实状态 → 入场动画。
    /// 3.2.13：不只查 isVisible，还查 isOnActiveSpace——panel 的 Space 关联会偶发损坏
    /// （visible=true 但挂在别的桌面空间，用户看不见，2026-06-12 日志实锤）。
    /// 任一不健康就整个重建 panel：新建的 panel 必然落在当前活跃 Space。
    private func present(context: String) {
        var p = ensurePanel()
        // 入场动画只在"这一轮第一次现身"时放：听 → 想 → 落这种形态切换不该再闪一次；
        // 正在淡出（presented 已经是 false）的话算重新入场，把它拉回来。
        // 位置也跟着这个判断走：同一轮里不重新锚定（见 latchedOrigin）
        let entering = !p.isVisible || !state.presented
        position(p, relocate: entering)
        if entering && !reduceMotion {
            state.presented = false
            state.settled = false
        }
        p.orderFrontRegardless()
        if !p.isVisible || !p.isOnActiveSpace {
            Log.warn("Overlay \(context) unhealthy (visible=\(p.isVisible) onActiveSpace=\(p.isOnActiveSpace)) — rebuilding panel")
            // orderOut 只是下屏：窗口仍挂在 NSApp 的窗口表上，而 isReleasedWhenClosed = false
            // 意味着 panel 置 nil 之后也没人再放手——旧面板连着它的 NSHostingView 和那份
            // 订阅 OverlayState 的 SwiftUI 子树永远留着。close() 才是摘下来的那一下，
            // 先清 contentView 好让 hosting view 立刻断开订阅。
            p.contentView = nil
            p.close()
            panel = nil
            p = ensurePanel()
            position(p, relocate: false)
            p.orderFrontRegardless()
        }
        if entering {
            if reduceMotion {
                state.presented = true
                state.settled = true
            } else {
                // 隔一个 runloop 再点火：同一拍里 false→true 会被合并掉，动画就白设了。
                // 带上 hideGeneration，这中间要是已经 hide 了就当没发生过。
                let generation = hideGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.hideGeneration == generation else { return }
                    withAnimation(Theme.spring) {
                        self.state.presented = true
                        self.state.settled = true
                    }
                }
            }
        }
        updateMouseMonitors()
        Log.overlayShown(context: context, panel: p)
    }

    func hide() {
        hideGeneration += 1
        thinking = false
        state.caption = nil
        state.charCount = nil
        state.clock = nil
        state.doneHitRect = .zero
        clearAction()
        removeMouseMonitors()
        latchedOrigin = nil
        guard let p = panel, p.isVisible, !reduceMotion else {
            state.presented = false
            panel?.orderOut(nil)
            return
        }
        let generation = hideGeneration
        // 消失 = 只淡出（settled 不动，胶囊不往下掉）
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

/// 让胶囊在固定大小面板里水平居中（顶部居中时贴顶边，其余贴底边）。
/// 面板本身一轮里不挪（latchedOrigin），胶囊在听 → 指令 → 想 → 落之间变高 / 变宽时
/// 靠这里的布局：**底边钉在面板底边上、向上长，左右对称展开**，屏幕上看不到跳
struct OverlayContainer: View {
    /// 命中测试要的是"按钮在面板里的位置"，所以量尺子的坐标系锚在这一层
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
        .padding(OverlayMetrics.contentInset)
        .coordinateSpace(name: Self.space)
    }
}
