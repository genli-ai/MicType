import XCTest
@testable import MicType

/// 润色与指令的等待预算。两头都要钉死：
/// • 下限——v4.0 把单次录音提到 600 s、输出预算按输入放大到 32768，而润色是**非流式**请求
///   （生成期间一个字节都不回），超时因此等于"整篇生成的总时长上限"，太短则长段口述永远
///   只能拿到识别原文；
/// • 上限——用户 2026-09-20 的测试日志里，一句话的润色等了 **33 秒**才报超时
///   （15 s 超时 + 0.5 s 退避 + 15 s 重试）。一句话等三十多秒，人只会以为 App 卡死了。
///   4.1.1 因此把基础预算降到 12 s、并且**一次都不重试**。
final class PolishBudgetTests: XCTestCase {

    /// 短输入 12 s：一两句话等过这个数就该退回原文
    func testShortInputGetsTwelveSeconds() {
        XCTAssertEqual(PolishService.timeout(inputCharacters: 0), 12)
        XCTAssertEqual(PolishService.timeout(inputCharacters: 60), 13)
    }

    /// 长输入按字数放宽：6 分钟口述（约 2000 字）要的是几十秒，不是 12 s
    func testLongInputGetsMoreTime() {
        XCTAssertEqual(PolishService.timeout(inputCharacters: 600), 22)
        XCTAssertEqual(PolishService.timeout(inputCharacters: 2000), 12 + 2000.0 / 60, accuracy: 0.001)
        XCTAssertGreaterThan(PolishService.timeout(inputCharacters: 2000), 45)
    }

    /// 封顶 90 s：再长就该先把识别原文给用户
    func testTimeoutIsCapped() {
        XCTAssertEqual(PolishService.timeout(inputCharacters: 100_000), 90)
        XCTAssertLessThanOrEqual(PolishService.timeout(inputCharacters: Int.max / 2), 90)
    }

    /// 负数 / 脏输入不该算出比基础值还短的预算
    func testNeverShorterThanTheBase() {
        XCTAssertEqual(PolishService.timeout(inputCharacters: -100), 12)
    }

    /// **润色一次都不重试**（4.1.1）：失败重发一遍救不回什么，却把用户的等待翻倍。
    /// 这条一旦回退，那 33 秒就会原样回来——所以每个长度都点一遍名。
    func testPolishNeverRetries() {
        for characters in [0, 1, 60, 600, 601, 5000, 100_000] {
            XCTAssertEqual(PolishService.networkRetries(inputCharacters: characters), 0,
                           "润色只发一次，\(characters) 字也一样")
        }
    }

    /// 最坏情况的总等待 = 超时本身（只发一次，没有退避 + 重试那一段）
    func testShortInputWorstCaseWaitIsTheTimeoutItself() {
        let characters = 40
        let attempts = PolishService.networkRetries(inputCharacters: characters) + 1
        let worst = PolishService.timeout(inputCharacters: characters) * Double(attempts)
        XCTAssertEqual(attempts, 1)
        XCTAssertLessThan(worst, 13, "一句话的润色最多让人等十几秒，不是 33 秒")
    }

    /// 指令：25 s 一次，同样不重试。30 s ×（1 次重试）最坏能把人晾 60 秒
    func testCommandBudgetIsASingleAttempt() {
        XCTAssertEqual(AgentService.commandTimeout, 25)
        XCTAssertEqual(AgentService.commandNetworkRetries, 0)
    }

    /// 指令等得比润色久是有意的：按住说话低频、值钱，用户本来就在等结果
    func testCommandGetsMoreRoomThanShortPolish() {
        XCTAssertGreaterThan(AgentService.commandTimeout, PolishService.baseTimeout)
    }
}
