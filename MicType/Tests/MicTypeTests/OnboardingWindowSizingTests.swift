import XCTest
import SwiftUI
import AppKit
@testable import MicType

/// 引导窗口有多高。
///
/// 为什么值一个自己的文件：5.0.1 让引导和设置共用 `SettingsWindowSizing`，而那一套带着
/// 一条 **760 的硬上限**——引导 ③（服务商卡片 + 三步申请 + 两个输入框）在英文界面下比它还高，
/// 于是窗口被夹在 760 上，底下那截内容直接看不见。用户 2026-09-23 实机报的
/// 「第 ②③④⑤ 屏都显示不全」就是这么来的。
///
/// 这里钉两件事：
///   • 算术本身——**够放下**（不夹、不裁），除非屏幕真的装不下（那时才用可见屏高 − 120）；
///   • 每一屏在一块正常大小的屏幕上都装得进那个高度（真渲染一遍量的）。
final class OnboardingWindowSizingTests: XCTestCase {

    private var savedLanguage: AppLanguage = .zh

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: - 算术

    /// 正常屏幕上：要多高给多高，**一个像素都不许夹**。
    /// 这是这组测试的全部理由——5.0.1 那条 760 的上限就是在这里没人拦着
    func testContentHeightNeverClipsOnANormalScreen() {
        for natural in [220.0, 300, 470, 640, 760, 800, 860] as [CGFloat] {
            let height = OnboardingWindowSizing.contentHeight(natural: natural,
                                                              visibleScreenHeight: 1_000)
            XCTAssertGreaterThanOrEqual(height, natural, "natural=\(natural) 被夹掉了")
        }
    }

    /// 屏幕真的装不下时才让步，而且让到"可见屏高 − 120"为止——再往上走，
    /// 窗口不是被程序坞压住就是标题栏顶出屏幕（那时抓都抓不到）
    func testCeilingIsTheVisibleScreenMinusTheMargin() {
        XCTAssertEqual(OnboardingWindowSizing.contentHeight(natural: 5_000,
                                                            visibleScreenHeight: 900),
                       900 - OnboardingWindowSizing.screenMargin)
        // 一块矮得离谱的屏幕上，下限仍然赢：比这更矮连底部那排按钮都摆不开
        XCTAssertEqual(OnboardingWindowSizing.contentHeight(natural: 5_000,
                                                            visibleScreenHeight: 200),
                       OnboardingWindowSizing.minContentHeight)
    }

    /// 量不出来（还没排版、或者算出了 NaN）时给下限，绝不给 0：
    /// 一扇 0 高的窗口在屏幕上就是一条线
    func testUnmeasuredContentFallsBackToTheMinimum() {
        for natural in [0.0, -10, .nan, .infinity] as [CGFloat] {
            XCTAssertEqual(OnboardingWindowSizing.contentHeight(natural: natural,
                                                                visibleScreenHeight: 1_000),
                           OnboardingWindowSizing.minContentHeight, "\(natural)")
        }
    }

    // MARK: - 五屏真渲染一遍：每一屏都装得进算出来的那个高度

    /// 把每一屏按真窗口的宽度排一遍版，量它的自然高度，再问一次"窗口会给多高"——
    /// **给的必须不小于要的**。这条测试跑在与 App 同一条代码路径上
    /// （`NSHostingView.fittingSize` 就是 OnboardingWindowController.applyFittedHeight 问的那个数）。
    @MainActor
    func testEveryPageFitsInTheHeightTheWindowWouldGiveIt() {
        // 13 寸 MacBook Air 的可见高度（868）——比这更小的屏幕上才轮得到"让步"那条路
        let visibleScreenHeight: CGFloat = 868
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            for page in OnboardingPage.allCases {
                let natural = naturalHeight(of: page)
                XCTAssertGreaterThan(natural, 0, "\(page) 量不出高度")
                let given = OnboardingWindowSizing.contentHeight(
                    natural: natural, visibleScreenHeight: visibleScreenHeight)
                XCTAssertGreaterThanOrEqual(given, natural,
                    "\(language.rawValue) 的第 \(page.rawValue + 1) 屏要 \(natural)，窗口只给 \(given)")
            }
        }
    }

    /// 和 OnboardingWindowController.applyFittedHeight 同一条路：按目标宽度排版，问 fittingSize
    @MainActor
    private func naturalHeight(of page: OnboardingPage) -> CGFloat {
        let model = OnboardingModel()
        model.page = page
        // 权限未授予是第一次打开的人看到的样子，也是这几屏最高的一种（多两行橙色提示）
        model.micOK = false
        model.axOK = false

        let host = NSHostingView(rootView: OnboardingView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: OnboardingWindowSizing.width,
                            height: OnboardingWindowSizing.minContentHeight)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
