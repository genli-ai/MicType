import XCTest
@testable import MicType

/// 识别结果三态（全转完 / 转了一部分 / 一个字都没有）的单测。
/// 这三态决定"要不要把文字插进用户的光标处"，判错一次就是丢字或者插入半篇。
final class TranscriptionOutcomeTests: XCTestCase {

    private func outcome(_ text: String, done: Int, total: Int,
                         failure: String? = nil, cancelled: Bool = false) -> TranscriptionOutcome {
        TranscriptionOutcome(text: text, completedSegments: done, totalSegments: total,
                             failure: failure.map { MTError($0) }, cancelled: cancelled)
    }

    func testAllSegmentsDoneIsComplete() {
        let result = outcome("第一段。第二段。", done: 2, total: 2)
        XCTAssertTrue(result.isComplete)
        XCTAssertFalse(result.isPartial)
    }

    /// 第 3 段炸了但前 2 段有字 → 部分交付（前 2 段照常插入）
    func testFailedTailWithTextIsPartial() {
        let result = outcome("第一段。第二段。", done: 2, total: 3, failure: "boom")
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.isPartial)
    }

    /// 用户按 Esc 叫停 → 同样是部分交付，不是整轮作废
    func testCancelledTailWithTextIsPartial() {
        let result = outcome("第一段。", done: 1, total: 4, cancelled: true)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.isPartial)
    }

    /// 一个字都没有：既不是完成也不是"部分交付"——没有可交付的东西，按失败走
    func testEmptyTextIsNeverPartial() {
        XCTAssertFalse(outcome("", done: 0, total: 0, failure: "boom").isPartial)
        XCTAssertFalse(outcome("", done: 1, total: 3, cancelled: true).isPartial)
    }
}
