import XCTest
@testable import MicType

/// 录音计时文案的单测。这行字（「8:30 / 10:00」）是用户判断"还能说多久"的唯一依据，
/// 所以分秒进位、上限封顶这些地方一个都不能错。
final class RecordingClockTests: XCTestCase {

    func testFormatsMinutesAndSeconds() {
        XCTAssertEqual(DictationController.recordingTimeLabel(elapsed: 510, limit: 600),
                       "8:30 / 10:00")
        XCTAssertEqual(DictationController.recordingTimeLabel(elapsed: 125, limit: 600),
                       "2:05 / 10:00")
    }

    /// 秒数永远两位：2:5 会被读成"两分五秒"还是"两分五十秒"，谁也说不准
    func testSecondsAreAlwaysTwoDigits() {
        XCTAssertEqual(DictationController.clockText(61), "1:01")
        XCTAssertEqual(DictationController.clockText(600), "10:00")
        XCTAssertEqual(DictationController.clockText(0), "0:00")
    }

    /// 不足一秒向下取整：显示 0:01 的时候必须是真的过了 1 秒
    func testTruncatesTowardsZero() {
        XCTAssertEqual(DictationController.clockText(0.9), "0:00")
        XCTAssertEqual(DictationController.clockText(59.9), "0:59")
    }

    /// 到点收尾和时钟刷新之间有几十毫秒的空隙，别让用户看见 10:01 / 10:00
    func testElapsedIsClampedToTheLimit() {
        XCTAssertEqual(DictationController.recordingTimeLabel(elapsed: 601, limit: 600),
                       "10:00 / 10:00")
        XCTAssertEqual(DictationController.recordingTimeLabel(elapsed: -1, limit: 600),
                       "0:00 / 10:00")
    }

    // MARK: 设置页那句说明里的数字

    /// 上限 600 s、预警提前 30 s：这两个常量是"录音会不会被突然掐断"的全部答案
    func testRecordingLimitsAreTheMeasuredOnes() {
        XCTAssertEqual(DictationController.maxRecordingSeconds, 600)
        XCTAssertEqual(DictationController.preFinishWarningSeconds, 30)
    }

    /// 设置 → 录音 那句说明里的数字**必须来自常量**（写死的数字迟早和代码对不上，
    /// 而这行字是用户唯一能查到上限的地方）
    func testRecordingCopyReadsTheConstants() {
        for language in AppLanguage.allCases {
            let saved = L10n.shared.language
            L10n.shared.language = language
            defer { L10n.shared.language = saved }
            let copy = DictationController.recordingLimitCopy
            XCTAssertTrue(copy.contains(DictationController.minutesLabel(
                DictationController.maxRecordingSeconds)), "\(language): \(copy)")
            XCTAssertTrue(copy.contains(DictationController.secondsLabel(
                DictationController.preFinishWarningSeconds)), "\(language): \(copy)")
            XCTAssertTrue(copy.contains(DictationController.secondsLabel(
                AudioSegmenter.targetSeconds)), "\(language): \(copy)")
        }
    }

    func testDurationLabels() {
        L10n.shared.language = .en
        XCTAssertEqual(DictationController.minutesLabel(600), "10 minutes")
        XCTAssertEqual(DictationController.secondsLabel(45), "45s")
        // 不是整分钟就按秒说（常量以后改成 90 s 也不会被读成 2 分钟）
        XCTAssertEqual(DictationController.minutesLabel(90), "90s")
        L10n.shared.language = .zh
        XCTAssertEqual(DictationController.minutesLabel(600), "10 分钟")
        XCTAssertEqual(DictationController.secondsLabel(45), "45 秒")
    }

    // MARK: 每段的 token 预算

    /// 秒数 × 8 + 64（实测峰值出字速率 3.5 字/秒，两倍余量）。
    /// 库的默认 4096 会让密集语音在约 3.4 分钟处**静默截断**，所以每段都必须显式传。
    func testSegmentTokenBudget() {
        XCTAssertEqual(QwenModels.segmentMaxTokens(seconds: 45), 424)
        XCTAssertEqual(QwenModels.segmentMaxTokens(seconds: 0), 64)
        XCTAssertEqual(QwenModels.segmentMaxTokens(seconds: -3), 64)
        // 比库内部那条上限（秒数 × 20 + 64）更紧：跑飞的那一段烧不了多久
        XCTAssertLessThan(QwenModels.segmentMaxTokens(seconds: 45), Int(ceil(45 * 20)) + 64)
    }
}
