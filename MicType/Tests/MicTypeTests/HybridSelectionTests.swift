import XCTest
@testable import MicType

/// 混合转写「这一句用哪条通道的字」（HybridSelection，5.1.0）。
/// 用例移植自 iOS `CloudRecognitionTests` 里 L39 的那几条（规则 2–4），删掉了 Mac 没有的
/// 规则 1（积压）与 iOS 的「文字系统打架 → 无提示重试」那一套；加上 Mac 自己的规则 0
/// （两条都能用、文字系统不同 → 整段）与阿语那几条。
final class HybridSelectionTests: XCTestCase {

    private typealias H = HybridSelection

    // MARK: - 窗口

    /// 0.8 秒 + 每秒录音 0.025 秒，最多 2 秒（与 iOS RealtimeTuning 逐项相同）
    func testWindowScalesWithLengthAndCapsAtTwoSeconds() {
        XCTAssertEqual(H.window(audioSeconds: 0), 0.8, accuracy: 1e-9)
        XCTAssertEqual(H.window(audioSeconds: 4), 0.9, accuracy: 1e-9)
        XCTAssertEqual(H.window(audioSeconds: 20), 1.3, accuracy: 1e-9)
        XCTAssertEqual(H.window(audioSeconds: 48), 2.0, accuracy: 1e-9, "48 秒到顶")
        XCTAssertEqual(H.window(audioSeconds: 180), 2.0, accuracy: 1e-9)
        XCTAssertEqual(H.window(audioSeconds: -1), 0.8, accuracy: 1e-9)
        // 20 秒的句子：整段在实时终稿之后 1.2 秒到仍然算准时
        XCTAssertEqual(H.next(realtime: .usable, batch: .usable, sinceRealtimeFinal: 1.2, audioSeconds: 20),
                       .useBatch)
        XCTAssertEqual(H.next(realtime: .usable, batch: .pending, sinceRealtimeFinal: 1.3, audioSeconds: 20),
                       .useRealtime)
        guard case .waitForBatch(let rest?) = H.next(realtime: .usable, batch: .pending,
                                                     sinceRealtimeFinal: 0.3, audioSeconds: 20) else {
            return XCTFail("规则 2 要等窗口剩下的那一截")
        }
        XCTAssertEqual(rest, 1.0, accuracy: 1e-9)
    }

    func testSixtySecondCeilingIsTheOwnerDecision() {
        XCTAssertEqual(H.maxAudioSeconds, 60)
    }

    // MARK: - 规则 2：实时终稿到了 → 再给整段一个窗口

    func testRule2BatchInTheWindowWinsLateBatchLoses() {
        func step(_ realtime: H.Lane, _ batch: H.Lane, since: TimeInterval?) -> H.Step {
            H.next(realtime: realtime, batch: batch, sinceRealtimeFinal: since, audioSeconds: 0)
        }
        XCTAssertEqual(step(.pending, .pending, since: nil), .waitForEither)
        // 整段先到或同时到 → 整段
        XCTAssertEqual(step(.usable, .usable, since: 0), .useBatch)
        XCTAssertEqual(step(.pending, .usable, since: nil), .useBatch)
        // 实时到了、整段没到 → 等窗口剩下的那一截
        guard case .waitForBatch(let rest?) = step(.usable, .pending, since: 0.3) else {
            return XCTFail("规则 2 必须有界地等整段")
        }
        XCTAssertEqual(rest, 0.5, accuracy: 1e-9)
        // 窗口内到 → 整段；窗口先过了 → 实时（整段迟到），哪怕再看时它已经到了
        XCTAssertEqual(step(.usable, .usable, since: 0.79), .useBatch)
        XCTAssertEqual(step(.usable, .pending, since: 0.8), .useRealtime)
        XCTAssertEqual(step(.usable, .usable, since: 1.2), .useRealtime)
        // 整段在窗口内回来但没用 → 立刻用实时
        XCTAssertEqual(step(.usable, .failed, since: 0.1), .useRealtime)
        XCTAssertEqual(step(.usable, .empty, since: 0.1), .useRealtime)
    }

    // MARK: - 规则 3：实时不行 → 等整段到底

    func testRule3RealtimeOutWaitsForTheBatchWithoutAWindow() {
        for realtime: H.Lane in [.failed, .empty, .absent] {
            XCTAssertEqual(H.next(realtime: realtime, batch: .pending, sinceRealtimeFinal: 3, audioSeconds: 5),
                           .waitForBatch(window: nil), "\(realtime)")
            XCTAssertEqual(H.next(realtime: realtime, batch: .usable, sinceRealtimeFinal: 9, audioSeconds: 5),
                           .useBatch, "\(realtime)")
        }
        // 这一句没有整段那条 → 只剩实时（超过 60 秒的句子就是这样）
        XCTAssertEqual(H.next(realtime: .pending, batch: .absent, sinceRealtimeFinal: nil, audioSeconds: 5),
                       .waitForRealtime)
        XCTAssertEqual(H.next(realtime: .usable, batch: .absent, sinceRealtimeFinal: 0, audioSeconds: 5),
                       .useRealtime)
    }

    // MARK: - 规则 4：两条都不能用

    func testRule4NeitherUsable() {
        func verdict(_ realtime: H.Lane, _ batch: H.Lane) -> H.Step {
            H.next(realtime: realtime, batch: batch, sinceRealtimeFinal: 1, audioSeconds: 5)
        }
        XCTAssertEqual(verdict(.failed, .failed), .failure)
        XCTAssertEqual(verdict(.absent, .failed), .failure)
        // 服务商回了、没字 → 没听清，不是"这句丢了"
        XCTAssertEqual(verdict(.empty, .failed), .noSpeech)
        XCTAssertEqual(verdict(.failed, .empty), .noSpeech)
        XCTAssertEqual(verdict(.empty, .empty), .noSpeech)
        XCTAssertEqual(verdict(.absent, .empty), .noSpeech)
    }

    // MARK: - 规则 0（Mac）：两条都有字、文字系统不同 → 整段

    func testScriptDisagreementGoesToTheBatchEvenPastTheWindow() {
        XCTAssertEqual(H.next(realtime: .usable, batch: .usable, sinceRealtimeFinal: 5, audioSeconds: 1,
                              scriptsDiffer: true), .useBatch)
        // 只在两条都有字时才读这一位
        XCTAssertEqual(H.next(realtime: .usable, batch: .failed, sinceRealtimeFinal: 0.1, audioSeconds: 1,
                              scriptsDiffer: true), .useRealtime)
    }

    func testDominantScriptCountsLettersIncludingArabic() {
        XCTAssertEqual(H.dominantScript("明天下午三点我到，一起吃饭吧。"), .han)
        XCTAssertEqual(H.dominantScript("这个 feature 的 demo 我明天给大家看一下"), .han)
        XCTAssertEqual(H.dominantScript("See you tomorrow at three"), .latin)
        XCTAssertEqual(H.dominantScript("مرحباً، كيف حالك اليوم؟"), .arabic)
        XCTAssertEqual(H.dominantScript("Завтра в три часа дня я приеду."), .other)
        XCTAssertNil(H.dominantScript("好的吧"), "不足 4 个字母，太短不判")
        XCTAssertNil(H.dominantScript("12:30 !!"), "数字与标点不是字母")
        // 阿拉伯-印度数字不算字母
        XCTAssertNil(H.dominantScript("١٢٣٤٥"))
    }

    func testScriptsDiffer() {
        XCTAssertTrue(H.scriptsDiffer("مرحباً، كيف حالك اليوم؟", "Hello, how are you today?"))
        XCTAssertFalse(H.scriptsDiffer("مرحبا كيف حالك", "مرحباً، كيف حالك؟"))
        XCTAssertFalse(H.scriptsDiffer("好的", "OK then, see you"), "一边判不出就不算不同")
    }

    /// **阿拉伯语永远不算"不能用"**：阿语有字就是 .usable，规则照常走
    func testArabicIsJustAnotherUsableText() {
        XCTAssertEqual(H.next(realtime: .usable, batch: .usable, sinceRealtimeFinal: 0.1, audioSeconds: 3,
                              scriptsDiffer: H.scriptsDiffer("مرحبا كيف حالك", "مرحباً، كيف حالك؟")),
                       .useBatch)
        XCTAssertEqual(H.next(realtime: .usable, batch: .failed, sinceRealtimeFinal: 0.1, audioSeconds: 3),
                       .useRealtime)
    }
}
