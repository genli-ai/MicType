import XCTest
@testable import MicType

/// 词表 / 口水词表解析的纯函数层单测。
/// 走 `Settings.parseVocabulary` / `Settings.parseList` 的静态重载，不碰 UserDefaults，
/// 与 Windows 端 MicTypeWindows/tests/.../VocabularyTests.cs 的同名用例一一对应——
/// 两端解析行为必须一致，否则同一份词表在 Mac 和 Windows 上会解析出不同结果。
final class VocabularyParseTests: XCTestCase {

    private func wrongs(_ parsed: (terms: [String], replacements: [(wrong: String, right: String)]))
        -> [String] {
        parsed.replacements.map { $0.wrong }
    }

    private func rights(_ parsed: (terms: [String], replacements: [(wrong: String, right: String)]))
        -> [String] {
        parsed.replacements.map { $0.right }
    }

    // MARK: 基本解析（对应 ParsesPlainTermsAndReplacements）

    func testParsesPlainTermsAndReplacements() {
        let parsed = Settings.parseVocabulary("Gen, 杰文=捷文，Qwen")
        XCTAssertEqual(parsed.terms, ["Gen", "捷文", "Qwen"])
        XCTAssertEqual(wrongs(parsed), ["杰文"])
        XCTAssertEqual(rights(parsed), ["捷文"])
    }

    // MARK: 非法条目（对应 ParsesFullWidthEqualsAndIgnoresInvalidEntries）

    func testIgnoresHalfEmptyEntriesLikeWindows() {
        // 「=空」「缺=」这类半空条目两端都必须整条丢弃。
        // 旧实现用 split(separator:"=") 切，空段被默默丢掉 → parts.count == 1 落进 else，
        // 把带等号的整串当成热词送进识别与润色提示词。
        let parsed = Settings.parseVocabulary("杰文＝捷文, =空, 缺=, 普通词")
        XCTAssertEqual(parsed.terms, ["捷文", "普通词"])
        XCTAssertEqual(wrongs(parsed), ["杰文"])
        XCTAssertEqual(rights(parsed), ["捷文"])
    }

    func testBareEqualsSignIsDropped() {
        // 单独一个 "=" 在旧实现里 split 出空数组，同样会被当成热词
        let parsed = Settings.parseVocabulary("=, Qwen")
        XCTAssertEqual(parsed.terms, ["Qwen"])
        XCTAssertTrue(parsed.replacements.isEmpty)
    }

    // MARK: 多错写（对应 ParsesMultipleWrongFormsForOneRightForm）

    func testParsesMultipleWrongFormsForOneRightForm() {
        let parsed = Settings.parseVocabulary("杰文|捷纹｜结文=捷文")
        XCTAssertEqual(parsed.terms, ["捷文"])
        XCTAssertEqual(wrongs(parsed), ["杰文", "捷纹", "结文"])
        XCTAssertEqual(rights(parsed), ["捷文", "捷文", "捷文"])
    }

    // MARK: CRLF（跨端搬运的核心回归）

    func testCrlfEntriesDoNotKeepTrailingCarriageReturn() {
        // Windows 多行文本框产出的是 CRLF。分隔符漏掉 \r 的话每个条目都会拖一个裸 CR：
        // 替换结果里会插进一个看不见的换行，热词上下文也被污染。
        let parsed = Settings.parseVocabulary("杰文=捷文\r\nQwen\r\n")
        XCTAssertEqual(parsed.terms, ["捷文", "Qwen"])
        XCTAssertEqual(wrongs(parsed), ["杰文"])
        XCTAssertEqual(rights(parsed), ["捷文"])
    }

    // MARK: 口水词表（对应 ParsesFillerWords）

    func testParsesFillerWords() {
        XCTAssertEqual(Settings.parseList("嗯，那个\num"), ["嗯", "那个", "um"])
    }

    func testParsesFillerWordsFromCrlfText() {
        // 带尾随 CR 的口水词经正则转义后永远匹配不到 → 过滤静默失效
        XCTAssertEqual(Settings.parseList("嗯\r\n那个\r\num"), ["嗯", "那个", "um"])
    }
}
