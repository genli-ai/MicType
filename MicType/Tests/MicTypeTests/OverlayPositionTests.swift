import XCTest
@testable import MicType

/// 悬浮窗落点的纯几何单测。这一层唯一的职责是"永远落在屏幕里"——
/// 算错了的后果不是难看，是用户按下热键之后**什么都看不见**（悬浮窗跑到屏幕外），
/// 而那正是他最需要反馈的一刻。
final class OverlayPositionTests: XCTestCase {

    /// 一块普通的外接屏（原点非零，专门用来抓"忘了加 visibleFrame.origin"那类错）
    private let screen = CGRect(x: 1920, y: 100, width: 1440, height: 800)
    private let panel = CGSize(width: 520, height: 160)

    // MARK: - 底部居中（默认，必须与 3.2.19 像素级一致）

    func testBottomCenterKeepsLegacyCoordinates() {
        let origin = OverlayController.panelOrigin(position: .bottomCenter,
                                                   panelSize: panel,
                                                   visibleFrame: screen,
                                                   mouse: CGPoint(x: 2000, y: 500))
        XCTAssertEqual(origin.x, screen.midX - panel.width / 2, accuracy: 0.0001)
        XCTAssertEqual(origin.y, screen.minY + 35, accuracy: 0.0001)
    }

    /// 底部/顶部居中与鼠标位置无关：鼠标在哪儿都落同一处
    func testCenteredPositionsIgnoreMouse() {
        for position in [OverlayPosition.bottomCenter, .topCenter] {
            let a = OverlayController.panelOrigin(position: position, panelSize: panel,
                                                  visibleFrame: screen,
                                                  mouse: CGPoint(x: 1930, y: 110))
            let b = OverlayController.panelOrigin(position: position, panelSize: panel,
                                                  visibleFrame: screen,
                                                  mouse: CGPoint(x: 3300, y: 880))
            XCTAssertEqual(a.x, b.x, accuracy: 0.0001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.0001)
        }
    }

    // MARK: - 顶部居中

    /// 顶边对齐 visibleFrame 顶边：内容贴面板顶边，所以面板顶边就是胶囊所在那一头
    func testTopCenterAlignsPanelTopToVisibleTop() {
        let origin = OverlayController.panelOrigin(position: .topCenter,
                                                   panelSize: panel,
                                                   visibleFrame: screen,
                                                   mouse: CGPoint(x: 2000, y: 500))
        XCTAssertEqual(origin.y + panel.height, screen.maxY, accuracy: 0.0001)
        XCTAssertEqual(origin.x, screen.midX - panel.width / 2, accuracy: 0.0001)
    }

    // MARK: - 跟随指针

    /// 屏幕中央：胶囊横向居中对准指针，底边浮在指针上方（面板贴底，胶囊比面板底边高 16）
    func testNearCursorCentersOnPointer() {
        let mouse = CGPoint(x: 2500, y: 500)
        let origin = OverlayController.panelOrigin(position: .nearCursor,
                                                   panelSize: panel,
                                                   visibleFrame: screen,
                                                   mouse: mouse)
        XCTAssertEqual(origin.x + panel.width / 2, mouse.x, accuracy: 0.0001)
        // 胶囊底边 = 面板底边 + contentInset，应当正好在指针上方 18pt
        XCTAssertEqual(origin.y + OverlayMetrics.contentInset, mouse.y + 18, accuracy: 0.0001)
    }

    /// 指针贴着屏幕四边：胶囊那一头永远还在屏幕里
    func testNearCursorStaysOnScreenAtEveryCorner() {
        let corners = [
            CGPoint(x: screen.minX, y: screen.minY),
            CGPoint(x: screen.maxX, y: screen.minY),
            CGPoint(x: screen.minX, y: screen.maxY),
            CGPoint(x: screen.maxX, y: screen.maxY),
        ]
        for mouse in corners {
            let origin = OverlayController.panelOrigin(position: .nearCursor,
                                                       panelSize: panel,
                                                       visibleFrame: screen,
                                                       mouse: mouse)
            XCTAssertGreaterThanOrEqual(origin.x, screen.minX)
            XCTAssertLessThanOrEqual(origin.x + panel.width, screen.maxX)
            // 胶囊纵向占 [底边+16, 底边+16+预留高度]，两头都必须在屏内
            let capsuleBottom = origin.y + OverlayMetrics.contentInset
            XCTAssertGreaterThanOrEqual(capsuleBottom, screen.minY)
            XCTAssertLessThanOrEqual(capsuleBottom + 108, screen.maxY)
        }
    }

    /// 指针在屏幕外（多屏之间的空隙、屏幕热插拔的瞬间）也照样钳回屏内，绝不放它出去
    func testNearCursorClampsPointerOutsideScreen() {
        let origin = OverlayController.panelOrigin(position: .nearCursor,
                                                   panelSize: panel,
                                                   visibleFrame: screen,
                                                   mouse: CGPoint(x: -5000, y: 9000))
        XCTAssertEqual(origin.x, screen.minX, accuracy: 0.0001)
        let capsuleBottom = origin.y + OverlayMetrics.contentInset
        XCTAssertGreaterThanOrEqual(capsuleBottom, screen.minY)
        XCTAssertLessThanOrEqual(capsuleBottom + 108, screen.maxY)
    }

    /// 屏幕比面板还窄（极端的小副屏）：横向上界低于下界，这时取下界贴左边，
    /// 绝不给出个把悬浮窗甩到屏幕左外的坐标
    func testNearCursorOnScreenNarrowerThanPanel() {
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 300)
        let origin = OverlayController.panelOrigin(position: .nearCursor,
                                                   panelSize: panel,
                                                   visibleFrame: tiny,
                                                   mouse: CGPoint(x: 350, y: 280))
        XCTAssertEqual(origin.x, tiny.minX, accuracy: 0.0001)
        // 纵向照常钳制：指针贴着顶边，胶囊往下让到预留高度装得下为止
        XCTAssertEqual(origin.y, tiny.maxY - OverlayMetrics.contentInset - 108, accuracy: 0.0001)
    }

    // MARK: - 选屏 + 落点（5.4.1：撤销「跟随前台窗口」，默认固定在屏幕底部居中）

    /// 主屏（原点 0,0，底下有 Dock）+ 右边那块外接屏（就是上面的 screen）
    private let primary = (frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                           visibleFrame: CGRect(x: 0, y: 70, width: 1920, height: 985))
    private var external: (frame: CGRect, visibleFrame: CGRect) {
        (frame: CGRect(x: 1920, y: 100, width: 1440, height: 830), visibleFrame: screen)
    }

    /// 默认档：鼠标在屏里任何地方（屏幕四角、正中）都落在同一处——屏幕底部居中，
    /// 与 5.1 / 3.2.19 的老坐标逐像素一致。前台窗口在哪已经不是输入了
    func testDefaultIsAlwaysScreenBottomCenter() {
        let mice = [CGPoint(x: 1925, y: 105), CGPoint(x: 3355, y: 925),
                    CGPoint(x: 2640, y: 500), CGPoint(x: 1925, y: 925)]
        for mouse in mice {
            let origin = OverlayController.anchoredOrigin(choice: .bottomCenter, panelSize: panel,
                                                          screens: [primary, external],
                                                          fallbackVisibleFrame: primary.visibleFrame,
                                                          mouse: mouse)
            XCTAssertEqual(origin?.x ?? .nan, screen.midX - panel.width / 2, accuracy: 0.0001)
            XCTAssertEqual(origin?.y ?? .nan, screen.minY + 35, accuracy: 0.0001)
        }
    }

    /// 多屏：鼠标在哪块屏就落在哪块屏的底部居中（用的是那块屏的 visibleFrame，Dock 让出来）
    func testPicksTheScreenUnderTheMouse() {
        let onPrimary = OverlayController.anchoredOrigin(choice: .bottomCenter, panelSize: panel,
                                                         screens: [primary, external],
                                                         fallbackVisibleFrame: nil,
                                                         mouse: CGPoint(x: 400, y: 600))
        XCTAssertEqual(onPrimary, CGPoint(x: primary.visibleFrame.midX - panel.width / 2,
                                          y: primary.visibleFrame.minY + 35))
        let onExternal = OverlayController.anchoredOrigin(choice: .bottomCenter, panelSize: panel,
                                                          screens: [primary, external],
                                                          fallbackVisibleFrame: nil,
                                                          mouse: CGPoint(x: 3000, y: 600))
        XCTAssertEqual(onExternal, CGPoint(x: screen.midX - panel.width / 2, y: screen.minY + 35))
    }

    /// 鼠标落在两块屏之间的缝里（或热插拔的瞬间）：用调用方给的主屏兜底；连兜底都没有就用第一块屏
    func testMouseBetweenScreensFallsBack() {
        let gap = CGPoint(x: 3000, y: 50)   // 外接屏底边以下、主屏右边以外
        let withFallback = OverlayController.anchoredOrigin(choice: .bottomCenter, panelSize: panel,
                                                            screens: [primary, external],
                                                            fallbackVisibleFrame: primary.visibleFrame,
                                                            mouse: gap)
        XCTAssertEqual(withFallback, CGPoint(x: primary.visibleFrame.midX - panel.width / 2,
                                             y: primary.visibleFrame.minY + 35))
        let noFallback = OverlayController.anchoredOrigin(choice: .bottomCenter, panelSize: panel,
                                                          screens: [external, primary],
                                                          fallbackVisibleFrame: nil,
                                                          mouse: gap)
        XCTAssertEqual(noFallback, CGPoint(x: screen.midX - panel.width / 2, y: screen.minY + 35))
        // 一块屏都没有（极端：屏幕全拔了）：不给坐标，调用方什么都不挪
        XCTAssertNil(OverlayController.anchoredOrigin(choice: .bottomCenter, panelSize: panel,
                                                      screens: [], fallbackVisibleFrame: nil,
                                                      mouse: gap))
    }

    /// 旧档位（顶部居中 / 跟随指针，旧版设置或导入的设置文件）照旧：在鼠标所在屏上按原规则落
    func testLegacyChoicesStillHonoured() {
        let mouse = CGPoint(x: 2500, y: 600)
        for choice in [OverlayPosition.topCenter, .nearCursor] {
            let origin = OverlayController.anchoredOrigin(choice: choice, panelSize: panel,
                                                          screens: [primary, external],
                                                          fallbackVisibleFrame: primary.visibleFrame,
                                                          mouse: mouse)
            XCTAssertEqual(origin, OverlayController.panelOrigin(position: choice, panelSize: panel,
                                                                 visibleFrame: screen, mouse: mouse))
        }
    }
}
