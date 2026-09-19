import XCTest
@testable import MicType

/// 识别结果往哪儿送：直接写进引导窗「试一下」那个框，还是照常走剪贴板 + ⌘V。
///
/// 为什么值得单测：走错这一条的代价是**用户一个字都看不到**，而且是静默的——
/// 悬浮窗一路正常（录音、处理、绿勾），只有输入框是空的。4.0.1 就是这么丢字的：
/// 那一页靠 ⌘V 落字，⌘V 打向"此刻的键盘焦点"，翻页之后焦点不在框里，字就落到别处了。
final class DeliveryRouteTests: XCTestCase {

    override func tearDown() {
        // 这是全 App 唯一的一份状态，测完必须摘干净，否则污染同批的其它用例
        TranscriptSink.unregister()
        super.tearDown()
    }

    // MARK: - 判据本身

    /// 引导窗停在「试一下」那一页 → 直接落字；其余一切情况 → 照常粘贴
    func testSinkOnlyWhenOnboardingSitsOnTheTryItPage() {
        XCTAssertEqual(DictationController.deliveryRoute(onboardingVisibleOnTryIt: true), .sink)
        XCTAssertEqual(DictationController.deliveryRoute(onboardingVisibleOnTryIt: false), .inserter)
    }

    /// 路由名会进日志（排障时"到底走了哪条"全靠它），别随手改
    func testRouteNamesAreStableForLogs() {
        XCTAssertEqual(DictationController.DeliveryRoute.sink.rawValue, "sink")
        XCTAssertEqual(DictationController.DeliveryRoute.inserter.rawValue, "inserter")
    }

    // MARK: - 通道的默认态

    /// 没人注册时必须**完全隐形**：isReady 恒 false、accept 恒 false，
    /// 于是交付路径和 4.0.1 之前逐字一致（这是这条新链路唯一可接受的默认行为）
    func testUnregisteredSinkIsInert() {
        TranscriptSink.unregister()
        XCTAssertFalse(TranscriptSink.isReady())
        XCTAssertFalse(TranscriptSink.accept("hello"))
        XCTAssertEqual(DictationController.deliveryRoute(
            onboardingVisibleOnTryIt: TranscriptSink.isReady()), .inserter)
    }

    /// 注册之后：问得到"接不接得住"，也真的把文字交过去
    func testRegisteredSinkReceivesTheText() {
        var received: [String] = []
        var ready = true
        TranscriptSink.register(isReady: { ready }, accept: { received.append($0); return true })

        XCTAssertEqual(DictationController.deliveryRoute(
            onboardingVisibleOnTryIt: TranscriptSink.isReady()), .sink)
        XCTAssertTrue(TranscriptSink.accept("你好世界"))
        XCTAssertEqual(received, ["你好世界"])

        // 翻到别的页 / 窗口收起来 → 立刻退回粘贴那条路
        ready = false
        XCTAssertEqual(DictationController.deliveryRoute(
            onboardingVisibleOnTryIt: TranscriptSink.isReady()), .inserter)
    }

    /// 说"接得住"却没接住（窗口刚被关掉的那半秒）：accept 返回 false，
    /// 调用方据此退回粘贴——绝不能让这段文字掉在地上
    func testSinkCanDeclineSoTheTextIsNeverDropped() {
        TranscriptSink.register(isReady: { true }, accept: { _ in false })
        XCTAssertEqual(DictationController.deliveryRoute(
            onboardingVisibleOnTryIt: TranscriptSink.isReady()), .sink)
        XCTAssertFalse(TranscriptSink.accept("something"))
    }

    /// 注销之后不许还留着上一个闭包（引导窗关了，字必须回到光标处）
    func testUnregisterClearsTheHandlers() {
        TranscriptSink.register(isReady: { true }, accept: { _ in true })
        TranscriptSink.unregister()
        XCTAssertFalse(TranscriptSink.isReady())
        XCTAssertFalse(TranscriptSink.accept("x"))
    }
}
