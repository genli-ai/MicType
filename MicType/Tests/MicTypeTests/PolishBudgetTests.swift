import XCTest
@testable import MicType

/// 润色的等待预算。v4.0 把单次录音提到 600 s、输出预算按输入放大到 32768，
/// 而润色是**非流式**请求（生成期间一个字节都不回），超时因此等于"整篇生成的总时长上限"——
/// 这两个数一旦对不上，长段口述就永远只能拿到识别原文。钉死在这里。
final class PolishBudgetTests: XCTestCase {

    /// 短输入维持原来的 15 s：一两句话等过这个数就该退回原文
    func testShortInputKeepsTheOldBudget() {
        XCTAssertEqual(PolishService.timeout(inputCharacters: 0), 15)
        XCTAssertEqual(PolishService.timeout(inputCharacters: 60), 16)
    }

    /// 长输入按字数放宽：6 分钟口述（约 2000 字）要的是几十秒，不是 15 s
    func testLongInputGetsMoreTime() {
        XCTAssertEqual(PolishService.timeout(inputCharacters: 600), 25)
        XCTAssertEqual(PolishService.timeout(inputCharacters: 2000), 15 + 2000.0 / 60, accuracy: 0.001)
        XCTAssertGreaterThan(PolishService.timeout(inputCharacters: 2000), 45)
    }

    /// 封顶 90 s：再长就该先把识别原文给用户
    func testTimeoutIsCapped() {
        XCTAssertEqual(PolishService.timeout(inputCharacters: 100_000), 90)
        XCTAssertLessThanOrEqual(PolishService.timeout(inputCharacters: Int.max / 2), 90)
    }

    /// 负数 / 脏输入不该算出比基础值还短的预算
    func testNeverShorterThanTheBase() {
        XCTAssertEqual(PolishService.timeout(inputCharacters: -100), 15)
    }

    /// 长输入不重试：超时说明整篇没在预算内生成完，原样重发只是把等待翻倍
    func testLongInputDoesNotRetry() {
        XCTAssertEqual(PolishService.networkRetries(inputCharacters: 0), 1)
        XCTAssertEqual(PolishService.networkRetries(inputCharacters: 600), 1)
        XCTAssertEqual(PolishService.networkRetries(inputCharacters: 601), 0)
        XCTAssertEqual(PolishService.networkRetries(inputCharacters: 5000), 0)
    }
}
