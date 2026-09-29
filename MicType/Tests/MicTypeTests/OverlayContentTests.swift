import XCTest
@testable import MicType

/// 悬浮窗形态里的纯函数：「落」那一行写什么、错误给哪颗按钮、字数怎么数、波形怎么动。
/// 这些都是用户每次听写都看得见的东西，判错了不会崩，只会悄悄说错话——所以钉死。
final class OverlayContentTests: XCTestCase {

    private var savedLanguage: AppLanguage = .zh

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: - 「落」

    /// 5.4.1：纯听写的「落」只是一枚勾——没有字可读，停得比带回执的短
    func testCheckOnlyDoneLingersShorterThanReceipt() {
        XCTAssertEqual(OverlayController.checkDoneDuration, 0.8, accuracy: 0.0001)
        XCTAssertLessThan(OverlayController.checkDoneDuration, OverlayController.doneDuration)
    }

    /// 只有带着 revertible 的「落」才能点（换回原文）；回执那一行永远不能点
    func testOnlyRevertibleCheckIsTappable() {
        let state = OverlayState()
        state.phase = .done(OverlayDone(body: .check, revertible: true))
        XCTAssertTrue(state.isDoneTappable)
        state.phase = .done(OverlayDone(body: .check))
        XCTAssertFalse(state.isDoneTappable)
        state.phase = .done(OverlayDone(body: .text("已改写 · ⌘Z 撤销")))
        XCTAssertFalse(state.isDoneTappable)
    }

    /// 旁白双语、且 Esc 收尾时照实说（分段识别到一半 Esc 是「收尾并输入」不是丢弃）
    func testAccessibilityHints() {
        L10n.shared.language = .en
        XCTAssertEqual(OverlayCopy.revertHint, "Click to restore the raw text")
        XCTAssertEqual(OverlayCopy.escHint(finishes: false), "Press Esc to cancel")
        XCTAssertEqual(OverlayCopy.escHint(finishes: true), "Press Esc to finish and insert")
        L10n.shared.language = .zh
        XCTAssertEqual(OverlayCopy.revertHint, "点一下换回原文")
        XCTAssertEqual(OverlayCopy.escHint(finishes: true), "按 Esc 收尾并输入")
    }

    // MARK: - 错误按钮

    /// 5.3.0 起按钮由**产生错误的地方**点名（不再按文案关键词猜）：
    /// 缺 Key / Key 被拒 →「打开设置」，余额不足 →「去充值」
    func testErrorButtonForKeyProblems() {
        XCTAssertEqual(RecognitionEngineReadiness.cloudKeyMissing(.openai).overlayAction, .openSettings)
        XCTAssertEqual(LLMCatalog.describeHTTPError(status: 401, provider: .openai,
                                                    code: nil, message: nil).action, .openSettings)
        XCTAssertEqual(CloudASRFailure.action(status: 401, code: "invalid_api_key"), .openSettings)
        XCTAssertEqual(OpenAITranscribeClient.failure(status: 401, code: nil, message: nil).error.action,
                       .openSettings)
        XCTAssertEqual(CloudStreamingSession.action(for: .unauthorized(code: nil)), .openSettings)
        XCTAssertEqual(CloudASRFailure.action(status: 429, code: "insufficient_quota"), .addCredit)
    }

    /// 文案改短之后按钮不许悄悄退成「关闭」——这正是 5.2.0 那套关键词判断会踩的坑：
    /// 新文案里已经没有「API Key」这几个字了
    func testShortCopyKeepsItsButton() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            let missing = MTError(UserMessage.keyMissing, action: .openSettings)
            XCTAssertEqual(missing.action, .openSettings)
            XCTAssertEqual(OpenAITranscribeClient.failure(status: 401, code: nil, message: nil).message,
                           UserMessage.keyRejected)
        }
    }

    /// 网络 / 超时 / 没听到：设置里修不了，给「关闭」（本版没有重试入口）
    func testErrorButtonForEverythingElseIsClose() {
        L10n.shared.language = .zh
        XCTAssertEqual(LLMCatalog.timeoutCopy().action, .dismiss)
        XCTAssertEqual(RecognitionEngineReadiness.offline.overlayAction, .dismiss)
        XCTAssertEqual(MTError(UserMessage.nothingHeard).action, .dismiss)
        XCTAssertEqual(CloudASRFailure.action(status: 503, code: nil), .dismiss)
        XCTAssertEqual(CloudStreamingSession.action(for: .transport("reset")), .dismiss)
        XCTAssertEqual(OverlayErrorAction.dismiss.label, "关闭")
        XCTAssertEqual(OverlayErrorAction.openSettings.label, "打开设置")
        L10n.shared.language = .en
        XCTAssertEqual(OverlayErrorAction.dismiss.label, "Close")
        XCTAssertEqual(OverlayErrorAction.openSettings.label, "Open Settings")
    }

    // MARK: - 字数

    func testCharacterCountIgnoresWhitespace() {
        XCTAssertEqual(OverlayCopy.countCharacters("明天 下午\n三点"), 6)
        XCTAssertEqual(OverlayCopy.countCharacters("see you"), 6)
        L10n.shared.language = .zh
        XCTAssertEqual(OverlayCopy.charCount(42), "42 字")
        L10n.shared.language = .en
        XCTAssertEqual(OverlayCopy.charCount(42), "42 chars")
    }

    // MARK: - 波形

    /// 没声音就伏下去；声音越大条越高；永远在 0–1 之内
    func testWaveformTargetsFollowLevel() {
        let phases = [0.0, 1.0, 2.0]
        let speeds = [5.0, 6.0, 7.0]
        XCTAssertEqual(WaveformModel.targets(level: 0, time: 3, phases: phases, speeds: speeds), [0, 0, 0])
        let quiet = WaveformModel.targets(level: 0.2, time: 3, phases: phases, speeds: speeds)
        let loud = WaveformModel.targets(level: 0.8, time: 3, phases: phases, speeds: speeds)
        for (q, l) in zip(quiet, loud) {
            XCTAssertLessThan(q, l)
            XCTAssertLessThanOrEqual(l, 1)
        }
        // 每根条相位不同：不会整排齐刷刷一样高
        XCTAssertGreaterThan(Set(loud).count, 1)
    }

    /// 上升快、回落慢
    func testWaveformSmoothingRisesFasterThanItFalls() {
        let up = WaveformModel.smooth(previous: 0, target: 1)
        let down = 1 - WaveformModel.smooth(previous: 1, target: 0)
        XCTAssertGreaterThan(up, down)
    }
}
