import XCTest
@testable import MicType

/// 设置窗口的尺寸算术（4.1.6：窗口高度跟着内容走，用户 2026-09-21 拍板）。
///
/// 为什么值一个测试文件：这段算术有三条互相打架的约束——不比首页矮、不占满整块屏、
/// 不许伸出可见区域——而它们在视图代码里全是隐形的。最容易坏的那一条是**顶边不动**：
/// AppKit 的原点在左下角，随手改一下 size 的结果是窗口往下长、标题栏每翻一页跳一次。
final class SettingsWindowSizingTests: XCTestCase {

    /// 常见的 27" 屏：visibleFrame 高度 1400 上下
    private let roomyScreen: CGFloat = 1400

    // MARK: - 高度

    func testContentHeightFollowsTheContentBetweenTheTwoLimits() {
        let mid = SettingsWindowSizing.contentHeight(natural: 480, visibleScreenHeight: roomyScreen)
        XCTAssertEqual(mid, 480)
    }

    /// 短编辑页不许比首页还矮：一扇会缩成半张卡高的窗口，点进点出时像在抽搐
    func testShortPagesStillFitTheOverview() {
        XCTAssertEqual(SettingsWindowSizing.contentHeight(natural: 120,
                                                          visibleScreenHeight: roomyScreen),
                       SettingsWindowSizing.minContentHeight)
        // 还没量到（0 / NaN）时给下限，绝不给 0：一扇零高度的窗口是个白点
        XCTAssertEqual(SettingsWindowSizing.contentHeight(natural: 0,
                                                          visibleScreenHeight: roomyScreen),
                       SettingsWindowSizing.minContentHeight)
        XCTAssertEqual(SettingsWindowSizing.contentHeight(natural: .nan,
                                                          visibleScreenHeight: roomyScreen),
                       SettingsWindowSizing.minContentHeight)
    }

    /// 超过上限就让这一页自己滚，窗口不再长
    func testLongPagesStopAtTheCeilingAndScroll() {
        XCTAssertEqual(SettingsWindowSizing.contentHeight(natural: 2000,
                                                          visibleScreenHeight: roomyScreen),
                       SettingsWindowSizing.maxContentHeight)
    }

    /// 屏幕矮（外接小屏、分屏）时上限跟着屏幕降，并且上下各留出余量
    func testCeilingFollowsASmallScreen() {
        let small: CGFloat = 700
        let height = SettingsWindowSizing.contentHeight(natural: 2000, visibleScreenHeight: small)
        XCTAssertEqual(height, small - SettingsWindowSizing.screenMargin)
        XCTAssertLessThan(height, SettingsWindowSizing.maxContentHeight)
    }

    /// 屏幕矮到连下限都装不下时，下限仍然赢——否则窗口会矮到三张卡都摆不开，
    /// 而"不许伸出屏幕"那一条还会把它往上推，结果是一扇既看不全又挪不动的窗
    func testTheMinimumWinsOnAVeryShortScreen() {
        XCTAssertEqual(SettingsWindowSizing.contentHeight(natural: 900, visibleScreenHeight: 320),
                       SettingsWindowSizing.minContentHeight)
    }

    // MARK: - 位置（顶边不动）

    private let screen = CGRect(x: 0, y: 0, width: 2000, height: 1200)

    func testTopEdgeStaysPutWhenTheWindowGrows() {
        let current = CGRect(x: 300, y: 500, width: 560, height: 400)
        let next = SettingsWindowSizing.frame(current: current, frameHeight: 600, visible: screen)
        XCTAssertEqual(next.maxY, current.maxY)
        XCTAssertEqual(next.height, 600)
        XCTAssertEqual(next.origin.x, current.origin.x)
        XCTAssertEqual(next.width, SettingsWindowSizing.width)
    }

    func testTopEdgeStaysPutWhenTheWindowShrinks() {
        let current = CGRect(x: 300, y: 500, width: 560, height: 700)
        let next = SettingsWindowSizing.frame(current: current, frameHeight: 350, visible: screen)
        XCTAssertEqual(next.maxY, current.maxY)
        XCTAssertEqual(next.height, 350)
    }

    /// 长高之后不许伸到可见区域下面去（底边被程序坞压住 = 最后那几行永远读不到）
    func testGrowingNearTheBottomPushesTheWindowUp() {
        let current = CGRect(x: 0, y: 20, width: 560, height: 200)
        let next = SettingsWindowSizing.frame(current: current, frameHeight: 600, visible: screen)
        XCTAssertEqual(next.minY, screen.minY)
        XCTAssertLessThanOrEqual(next.maxY, screen.maxY)
    }

    /// 上面那一推可能把顶边顶出屏幕（窗口比可见区域还高）：顶边优先保住——
    /// 伸出底部是"内容看不见"，伸出顶部是"标题栏抓不到"，后者更糟
    func testAWindowTallerThanTheScreenKeepsItsTitleBarReachable() {
        let tallScreen = CGRect(x: 0, y: 0, width: 2000, height: 500)
        let current = CGRect(x: 0, y: 100, width: 560, height: 300)
        let next = SettingsWindowSizing.frame(current: current, frameHeight: 700, visible: tallScreen)
        XCTAssertEqual(next.maxY, tallScreen.maxY)
    }

    /// 屏幕原点不在 (0,0) 时也要对（副屏在主屏左边/下边是常态）
    func testWorksOnASecondaryScreenWithANonZeroOrigin() {
        let secondary = CGRect(x: -1800, y: -400, width: 1800, height: 1000)
        let current = CGRect(x: -1500, y: -380, width: 560, height: 300)
        let next = SettingsWindowSizing.frame(current: current, frameHeight: 700, visible: secondary)
        XCTAssertGreaterThanOrEqual(next.minY, secondary.minY)
        XCTAssertLessThanOrEqual(next.maxY, secondary.maxY)
        XCTAssertEqual(next.origin.x, current.origin.x)
    }

    /// 宽度永远是 560：整套文案与控件的换行都是按这个宽度调出来的
    func testWidthNeverChanges() {
        let odd = CGRect(x: 0, y: 200, width: 900, height: 300)
        XCTAssertEqual(SettingsWindowSizing.frame(current: odd, frameHeight: 400, visible: screen).width,
                       SettingsWindowSizing.width)
    }
}
