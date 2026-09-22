import SwiftUI

// MARK: - 「按哪一颗键」的键盘示意图

/// 引导第一屏用。4.3.4 之前那一屏只有一行字："轻点 右 Option (⌥)"——
/// 2026-09-22 的新用户反馈里有一条就是"到底按哪个键"：很多键帽上印的是 `alt`，
/// 非 Apple 键盘的排布也未必一样，光给一个名字对不上他手底下那一排键。
///
/// 所以画出来：空格键那一排的最后几颗，右边那颗 option 高亮。
/// **键帽上的字不翻译**——键盘上印的就是 `option` / `command` / `fn` 这几个英文词，
/// 中文界面下把它译成"选项键"反而对不上他低头看到的东西。要解释的那一句
/// （"空格键右侧第二颗；有的键帽印着 alt"）走 tr()，住在 OnboardingCopy.keyboardHint。
struct KeyboardHintView: View {
    @ObservedObject private var l10n = L10n.shared

    /// 一排键帽：左边几颗只是参照物，最后那颗才是主角
    private let leftKeys = ["fn", "control", "option", "command"]
    private let rightKeys = ["command", "option"]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(leftKeys.enumerated()), id: \.offset) { _, name in
                    Keycap(label: name, highlighted: false)
                }
                // 空格：不写字，靠宽度就认得出
                Keycap(label: "", highlighted: false, width: nil)
                ForEach(Array(rightKeys.enumerated()), id: \.offset) { index, name in
                    // 右 Option：这一排上唯一被点亮的那颗
                    Keycap(label: name, highlighted: index == rightKeys.count - 1)
                }
            }
            Text(OnboardingCopy.keyboardHint)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        // 宽度封顶：引导窗口内容区宽 560 − 左右各 32 的边距，留一点余量
        .frame(maxWidth: 440)
    }
}

/// 一颗键帽。固定宽度那几颗排成一行，空格那颗把剩下的宽度撑满
private struct Keycap: View {
    let label: String
    let highlighted: Bool
    /// nil = 弹性宽度（空格键）
    var width: CGFloat? = 48

    private var background: Color {
        highlighted ? Color.accentColor : Color.secondary.opacity(0.10)
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: highlighted ? .semibold : .regular))
            // 英文界面下 command 这个词在 48pt 里放不下，缩一点也比截断好
            .minimumScaleFactor(0.7)
            .lineLimit(1)
            .foregroundColor(highlighted ? .white : .secondary)
            .frame(width: width, height: 28)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 5).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(highlighted ? Color.accentColor : Color.secondary.opacity(0.28),
                        lineWidth: 1))
    }
}
