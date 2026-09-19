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
}
