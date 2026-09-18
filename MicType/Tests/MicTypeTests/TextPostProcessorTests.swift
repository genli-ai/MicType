import XCTest
@testable import MicType

/// 纯函数层单测：词表硬替换 / 伪影与口水词过滤 / 润色保真校验。
/// 三者都不碰 UserDefaults（一律走显式传参的重载），所以跑测试不会改到用户设置。
/// 与 Windows 端 MicTypeWindows/tests 的同名用例一一对应，双端行为必须一致。
final class TextPostProcessorTests: XCTestCase {

    // MARK: cleanTranscript

    func testCleanTranscriptStripsEngineTokens() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("<|zh|><|NEUTRAL|>今天下午三点开会", fillerWords: []),
                       "今天下午三点开会")
    }

    func testCleanTranscriptStripsAngleBracketTags() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("hello<br>world", fillerWords: []), "helloworld")
    }

    func testCleanTranscriptKeepsComparisonWithSpaces() {
        // 「a < b > c」是用户真说出口的内容，尖括号过滤不能碰
        XCTAssertEqual(TextPostProcessor.cleanTranscript("a < b > c", fillerWords: []), "a < b > c")
    }

    func testCleanTranscriptStillStripsBracketMarkers() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("[BLANK_AUDIO]你好", fillerWords: []), "你好")
    }

    // MARK: 口水词

    func testFillerWordsRemoveLatinWholeWordOnly() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("um I think umbrella is fine", fillerWords: ["um"]),
                       "I think umbrella is fine")
    }

    func testFillerWordsKeepChineseWordInsideOtherWords() {
        // 「那个」在「那个人」里是词的一部分，绝不能删；句首的「嗯」连同残留的逗号一起清掉
        XCTAssertEqual(TextPostProcessor.cleanTranscript("嗯，那个人已经到了。", fillerWords: ["嗯", "那个"]),
                       "那个人已经到了。")
    }

    func testFillerWordsCollapseLeftoverPunctuation() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("我觉得，嗯，可以。", fillerWords: ["嗯"]),
                       "我觉得，可以。")
    }

    func testFillerWordsEmptyListLeavesTextUntouched() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("嗯，那个，好的。", fillerWords: []), "嗯，那个，好的。")
    }

    // MARK: 词表硬替换

    func testVocabReplacementPrefersLongestWrongForm() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "文档助手很好用",
            replacements: [("文档", "文件"), ("文档助手", "助手")]), "助手很好用")
    }

    func testVocabReplacementIsCaseInsensitiveForLatinAndKeepsRightCasing() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "Ios 和 IOS 都要改", replacements: [("ios", "iOS")]), "iOS 和 iOS 都要改")
    }

    func testVocabReplacementRespectsLatinWordBoundary() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "ai 和 aiming 不一样", replacements: [("ai", "AI")]), "AI 和 aiming 不一样")
    }

    func testVocabReplacementHasNoBoundaryRequirementForCJK() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "杰文说杰文今天到。", replacements: [("杰文", "捷文")]), "捷文说捷文今天到。")
    }

    func testVocabReplacementDoesNotChain() {
        // 单趟扫描：a→b 产出的 b 不再被 b→c 吃掉
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "a b", replacements: [("a", "b"), ("b", "c")]), "b c")
    }

    func testVocabReplacementWithEmptyListReturnsOriginal() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements("hello", replacements: []), "hello")
    }

    // MARK: 润色保真校验

    func testDriftCheckAcceptsNumberFormattingDifference() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "预算是 1000 块，不能再多了",
                                                        polished: "预算是 1,000 块，不能再多了。"))
    }

    func testDriftCheckRejectsChangedDigits() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "预算是 1000 块", polished: "预算是 100 块"))
    }

    func testDriftCheckRejectsSwallowedNegations() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(
            raw: "我不去，他也不去，这件事不行，没人同意，无解。", polished: "大家都同意这件事。"))
    }

    func testDriftCheckToleratesOneNegationDifference() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "这个我不太确定", polished: "这个我不确定。"))
    }

    func testDriftCheckRejectsOverAggressiveShortening() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: String(repeating: "啊", count: 60),
                                                           polished: String(repeating: "啊", count: 5)))
    }

    func testDriftCheckSkipsLengthRuleForShortInput() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "嗯嗯嗯就是说那个好的", polished: "好的。"))
    }

    func testDriftCheckRejectsEmptyPolishedText() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "今天开会", polished: "   "))
    }
}
