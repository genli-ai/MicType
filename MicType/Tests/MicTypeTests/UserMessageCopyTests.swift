import XCTest
@testable import MicType

/// 错误与告知文案的长度守卫（UX 方案 §3 H，用户 2026-09-29 定）：**这条测试就是那条规矩本身**。
///   • 一句话：中文 ≤ 16 字、英文 ≤ 8 个词；
///   • 不写「请」「抱歉」、长破折号「——」、感叹号；
///   • 英文一侧一个汉字都没有，两种语言不是同一串。
/// 红了就去改文案，不要放宽数字。
final class UserMessageCopyTests: XCTestCase {

    private var savedLanguage: AppLanguage = .zh

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    func testChineseLinesFitSixteenCharacters() {
        L10n.shared.language = .zh
        for line in UserMessage.all {
            XCTAssertFalse(line.isEmpty)
            XCTAssertLessThanOrEqual(line.count, 16, "中文错误文案超过 16 字（\(line.count)）：\(line)")
            XCTAssertFalse(line.contains("\n"), line)
        }
    }

    func testEnglishLinesFitEightWords() {
        L10n.shared.language = .en
        for line in UserMessage.all {
            let words = line.split(whereSeparator: { $0 == " " }).count
            XCTAssertLessThanOrEqual(words, 8, "English message is over 8 words (\(words)): \(line)")
            XCTAssertFalse(line.contains("\n"), line)
            XCTAssertFalse(line.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value)
                || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }, line)
        }
    }

    func testNoPleaseNoSorryNoDashNoExclamation() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            for line in UserMessage.all {
                // 「请求」是名词（request），不是客套的「请」
                let scrubbed = line.replacingOccurrences(of: "请求", with: "")
                for banned in ["请", "抱歉", "——", "—", "！", "!", "please", "Please", "sorry", "Sorry"] {
                    XCTAssertFalse(scrubbed.contains(banned), "「\(banned)」出现在：\(line)")
                }
            }
        }
    }

    /// 豁免长度的那几句（5.4.0 每周一句）：长度不量，其余规矩照量
    func testExemptLinesFollowTheOtherRules() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            for line in UserMessage.exemptFromLength {
                XCTAssertFalse(line.isEmpty)
                XCTAssertFalse(line.contains("\n"), line)
                for banned in ["请", "抱歉", "——", "！", "!", "please", "Please", "sorry", "Sorry"] {
                    XCTAssertFalse(line.contains(banned), "「\(banned)」出现在：\(line)")
                }
                if language == .en {
                    XCTAssertFalse(line.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value)
                        || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }, line)
                }
            }
        }
        L10n.shared.language = .zh
        let zh = UserMessage.exemptFromLength
        L10n.shared.language = .en
        XCTAssertNotEqual(zh, UserMessage.exemptFromLength)
    }

    func testBothLanguagesAreWritten() {
        L10n.shared.language = .zh
        let zh = UserMessage.all
        L10n.shared.language = .en
        let en = UserMessage.all
        XCTAssertEqual(zh.count, en.count)
        for (a, b) in zip(zh, en) { XCTAssertNotEqual(a, b, "这一句没走 tr()：\(a)") }
    }

    /// 流经悬浮窗的那几类出口，确实拿的是集中表里的话（不是就地又写了一句长的）
    func testOverlaySourcesUseTheTable() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            let all = Set(UserMessage.all)
            XCTAssertTrue(all.contains(RecognitionEngineReadiness.cloudKeyMissing(.openai).message))
            XCTAssertTrue(all.contains(RecognitionEngineReadiness.offline.message))
            XCTAssertTrue(all.contains(CloudFallbackDecision.retryExhausted))
            XCTAssertTrue(all.contains(CloudStreamingSession.message(for: .finalTimeout)))
            XCTAssertTrue(all.contains(CloudStreamingSession.message(for: .transport("x"))))
            XCTAssertTrue(all.contains(OpenAITranscribeClient.failure(status: 401, code: nil, message: "long server text").message))
            XCTAssertTrue(all.contains(LLMClient.truncatedOutputCopy))
            XCTAssertTrue(all.contains(DictationController.selectionCopiedNote))
        }
    }
}
