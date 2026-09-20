import XCTest
@testable import MicType

/// 识别结果往哪儿送：直接写进引导窗「试一下」那个框，还是照常走剪贴板 + ⌘V。
///
/// 为什么值得单测：走错这一条的代价是**用户一个字都看不到**，而且是静默的——
/// 悬浮窗一路正常（录音、处理、绿勾），只有输入框是空的。4.0.1 就是这么丢字的：
/// 那一页靠 ⌘V 落字，⌘V 打向"此刻的键盘焦点"，翻页之后焦点不在框里，字就落到别处了。
///
/// 两层判据都在这里钉死：先是 `deliveryRoute`（打算走哪条），再是 `deliveryOutcome`
/// （问过输入框之后真正落在哪儿）。后者护的是"说接得住却没接住"那半秒——
/// 那一步过去只活在私有的 deliver() 里，写成 return 把字丢掉也没有一个测试会红。
final class DeliveryRouteTests: XCTestCase {

    private func route(sinkReady: Bool, sinkRegistered: Bool,
                       targetIsSelf: Bool) -> DictationController.DeliveryRoute {
        DictationController.deliveryRoute(sinkReady: sinkReady, sinkRegistered: sinkRegistered,
                                          targetIsSelf: targetIsSelf)
    }

    override func tearDown() {
        // 这是全 App 唯一的一份状态，测完必须摘干净，否则污染同批的其它用例
        TranscriptSink.unregister()
        super.tearDown()
    }

    // MARK: - 判据本身

    /// 引导窗停在「试一下」那一页、而且人就在这扇窗里开的录 → 直接落字
    func testSinkOnlyWhenOnboardingSitsOnTheTryItPage() {
        XCTAssertEqual(route(sinkReady: true, sinkRegistered: true, targetIsSelf: true), .sink)
        XCTAssertEqual(route(sinkReady: false, sinkRegistered: false, targetIsSelf: true), .inserter)
    }

    /// **开录时人在别的应用里 → 字必须落回那个应用**，哪怕引导正好开着、正好停在「试一下」。
    /// 那扇窗此刻在别人后面（isVisible 对压在后面的窗口同样是真），用户要的是备忘录里的光标，
    /// 不是他看不见的那个框——而且这条路连剪贴板都不写，字只存在于那个框里，退无可退。
    func testTargetInAnotherAppNeverFeedsTheGuide() {
        XCTAssertEqual(route(sinkReady: true, sinkRegistered: true, targetIsSelf: false), .inserter)
        XCTAssertEqual(route(sinkReady: false, sinkRegistered: true, targetIsSelf: false), .inserter)
    }

    /// 引导开着、但停在**别的页**，而开录时人就在这扇窗里：只写剪贴板。
    /// ⌘V 会打进引导自己的控件（「怎么用」那一屏的 Key 输入框首当其冲——
    /// 一段识别结果被当成 API Key 拿去验证，验证失败那行红字还留着它）。
    func testGuideOnAnotherPageKeepsTheTextOnTheClipboard() {
        XCTAssertEqual(route(sinkReady: false, sinkRegistered: true, targetIsSelf: true), .clipboard)
    }

    /// 认不出前台应用（targetBundleID 是空的）时行为与从前一致：该落字的照样落字
    func testUnknownTargetKeepsTheOldBehaviour() {
        XCTAssertEqual(route(sinkReady: true, sinkRegistered: true, targetIsSelf: true), .sink)
    }

    /// 路由名会进日志（排障时"到底走了哪条"全靠它），别随手改
    func testRouteNamesAreStableForLogs() {
        XCTAssertEqual(DictationController.DeliveryRoute.sink.rawValue, "sink")
        XCTAssertEqual(DictationController.DeliveryRoute.clipboard.rawValue, "clipboard")
        XCTAssertEqual(DictationController.DeliveryRoute.inserter.rawValue, "inserter")
    }

    // MARK: - 问过输入框之后，字真正落在哪儿

    private func outcome(_ route: DictationController.DeliveryRoute,
                         accepted: Bool) -> DictationController.DeliveryOutcome {
        DictationController.deliveryOutcome(route: route, sinkAccepted: accepted)
    }

    /// 挑中「直接落字」而框也真接住了：就落在框里，不碰剪贴板、不发 ⌘V
    func testAcceptedSinkKeepsTheTextInTheBox() {
        XCTAssertEqual(outcome(.sink, accepted: true), .sink)
    }

    /// **说接得住却没接住**（窗口刚被关掉、刚翻页的那半秒）：退到剪贴板。
    /// 这一条是这个文件真正要钉死的东西——写成"接不住就 return"，
    /// 用户一个字都看不到，而且悬浮窗一路正常（4.0.1 丢字就是这个形状）。
    func testDeclinedSinkFallsBackToTheClipboardInsteadOfDroppingTheText() {
        XCTAssertEqual(outcome(.sink, accepted: false), .clipboard)
        // 尤其不能退成 ⌘V：这条路的前提是开录时人在 MicType 自己的窗口里
        XCTAssertNotEqual(outcome(.sink, accepted: false), .inserter)
    }

    /// 另外两条路上根本没问过输入框，accepted 是什么都不该改变落点
    func testTheOtherTwoRoutesIgnoreWhatTheSinkWouldHaveSaid() {
        for accepted in [true, false] {
            XCTAssertEqual(outcome(.clipboard, accepted: accepted), .clipboard)
            XCTAssertEqual(outcome(.inserter, accepted: accepted), .inserter)
        }
    }

    /// 前台是别的应用时，无论引导窗说什么，字都必须走常规粘贴回那个应用
    func testTargetInAnotherAppAlwaysEndsUpPasted() {
        let chosen = route(sinkReady: true, sinkRegistered: true, targetIsSelf: false)
        XCTAssertEqual(outcome(chosen, accepted: false), .inserter)
    }

    /// 落点名同样会进日志（`path=` 那一段），别随手改
    func testOutcomeNamesAreStableForLogs() {
        XCTAssertEqual(DictationController.DeliveryOutcome.sink.rawValue, "sink")
        XCTAssertEqual(DictationController.DeliveryOutcome.clipboard.rawValue, "clipboard")
        XCTAssertEqual(DictationController.DeliveryOutcome.inserter.rawValue, "inserter")
    }

    // MARK: - 通道的默认态

    /// 没人注册时必须**完全隐形**：isReady 恒 false、accept 恒 false，
    /// 于是交付路径和 4.0.1 之前逐字一致（这是这条新链路唯一可接受的默认行为）
    func testUnregisteredSinkIsInert() {
        TranscriptSink.unregister()
        XCTAssertFalse(TranscriptSink.isReady())
        XCTAssertFalse(TranscriptSink.isRegistered)
        XCTAssertFalse(TranscriptSink.accept("hello"))
        XCTAssertEqual(route(sinkReady: TranscriptSink.isReady(),
                             sinkRegistered: TranscriptSink.isRegistered,
                             targetIsSelf: true), .inserter)
    }

    /// 注册之后：问得到"接不接得住"，也真的把文字交过去
    func testRegisteredSinkReceivesTheText() {
        var received: [String] = []
        var ready = true
        TranscriptSink.register(isReady: { ready }, accept: { received.append($0); return true })

        XCTAssertTrue(TranscriptSink.isRegistered)
        XCTAssertEqual(route(sinkReady: TranscriptSink.isReady(),
                             sinkRegistered: TranscriptSink.isRegistered,
                             targetIsSelf: true), .sink)
        XCTAssertTrue(TranscriptSink.accept("你好世界"))
        XCTAssertEqual(received, ["你好世界"])

        // 翻到别的页：窗口还开着、人还在这扇窗里 → 不落字，也绝不 ⌘V，留在剪贴板
        ready = false
        XCTAssertEqual(route(sinkReady: TranscriptSink.isReady(),
                             sinkRegistered: TranscriptSink.isRegistered,
                             targetIsSelf: true), .clipboard)
    }

    /// 说"接得住"却没接住（窗口刚被关掉的那半秒）：accept 返回 false，
    /// 调用方据此退到剪贴板——绝不能让这段文字掉在地上
    func testSinkCanDeclineSoTheTextIsNeverDropped() {
        TranscriptSink.register(isReady: { true }, accept: { _ in false })
        let chosen = route(sinkReady: TranscriptSink.isReady(),
                           sinkRegistered: TranscriptSink.isRegistered,
                           targetIsSelf: true)
        XCTAssertEqual(chosen, .sink)
        let accepted = TranscriptSink.accept("something")
        XCTAssertFalse(accepted)
        // 整条链走完：挑了 .sink、框没接住 → 字留在剪贴板上，一个字都没丢
        XCTAssertEqual(outcome(chosen, accepted: accepted), .clipboard)
    }

    /// 注销之后不许还留着上一个闭包（引导窗关了，字必须回到光标处）
    func testUnregisterClearsTheHandlers() {
        TranscriptSink.register(isReady: { true }, accept: { _ in true })
        TranscriptSink.unregister()
        XCTAssertFalse(TranscriptSink.isReady())
        XCTAssertFalse(TranscriptSink.isRegistered)
        XCTAssertFalse(TranscriptSink.accept("x"))
    }
}
