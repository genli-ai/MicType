import XCTest
@testable import MicType

/// 词汇提议（5.4.0）：润色替识别改同一个词改了 3 次 → 在设置里提议一次，点了才写进词汇表。
///
/// 这一层错了有两种坏结果：提了不该提的（「他们 → 它们」「use → utilize」天天被提，
/// 用户只会学会无视这一行）；或者提了一条"加进去"的东西其实把他的词汇表写坏了。
final class VocabularySuggestionsTests: XCTestCase {

    private var savedLanguage: AppLanguage = .zh

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    private func pairs(_ raw: String, _ polished: String, vocabulary: String = "") -> [String] {
        VocabularySuggestions.candidates(raw: raw, polished: polished, vocabulary: vocabulary)
            .map { VocabularySuggestions.key(wrong: $0.wrong, right: $0.right) }
    }

    // MARK: - 中文

    /// 同音替换（逐字拼音相同）命中
    func testChineseHomophoneSwapIsACandidate() {
        XCTAssertEqual(pairs("帮我把嘉士奇打开", "帮我把加湿器打开。"), ["嘉士奇\u{2192}加湿器"])
    }

    /// 只错两个字、中间夹一个没动的字：并成一个词看
    func testChineseSwapAroundAnUnchangedCharacter() {
        XCTAssertEqual(pairs("帮我把嘉士奇打开", "帮我把加士器打开"), ["嘉士奇\u{2192}加士器"])
    }

    /// 非同音的改动不算（那是润色改了措辞，不是识别听错了）
    func testChineseNonHomophoneIsIgnored() {
        XCTAssertEqual(pairs("这个东西很好用", "这个工具很好用"), [])
        // 单字替换（的 → 得）不到 2 字
        XCTAssertEqual(pairs("跑的很快", "跑得很快"), [])
    }

    /// 代词助词、繁转简不算
    func testChinesePronounsAndTraditionalAreIgnored() {
        XCTAssertEqual(pairs("他们都来了", "它们都来了"), [])
        XCTAssertEqual(pairs("機器學習很有趣", "机器学习很有趣"), [])
    }

    /// 已经在词汇表里（错写在、或正写已是词条）就不再提
    func testAlreadyInVocabularyIsIgnored() {
        XCTAssertEqual(pairs("帮我把嘉士奇打开", "帮我把加湿器打开", vocabulary: "嘉士奇=加湿器"), [])
        XCTAssertEqual(pairs("帮我把嘉士奇打开", "帮我把加湿器打开", vocabulary: "Power BI, 加湿器"), [])
        XCTAssertEqual(pairs("I use pyton daily", "I use Python daily", vocabulary: "python"), [])
    }

    // MARK: - 拉丁

    /// 只差大小写不算（那是润色在排版，识别没听错）
    func testLatinCaseOnlyIsIgnored() {
        XCTAssertEqual(pairs("i write python every day", "I write Python every day."), [])
    }

    /// 真替换命中；换词（use → utilize）、短词、多词改写不算
    func testLatinMisspellingIsACandidate() {
        XCTAssertEqual(pairs("I write pyton every day", "I write Python every day."), ["pyton\u{2192}Python"])
        XCTAssertEqual(pairs("我用 pyton 写代码", "我用 Python 写代码。"), ["pyton\u{2192}Python"])
        XCTAssertEqual(pairs("we use this tool", "we utilize this tool"), [], "换词是文风，不是识别错了")
        XCTAssertEqual(pairs("cats an dogs", "cats and dogs"), [], "少于 3 个字母的一侧不算")
        XCTAssertEqual(pairs("it is gona be fine", "it is going to be fine"), [], "一词对两词不算")
    }

    /// 阿语不做
    func testArabicReturnsNothing() {
        XCTAssertEqual(pairs("مرحبا pyton", "مرحبا Python"), [])
    }

    // MARK: - 计数

    /// 同一对 ≥ 3 次才成为「待提议」；同一句里出现两次只算一次
    func testThresholdIsThree() {
        var ledger = VocabularySuggestionLedger()
        let pair = (wrong: "嘉士奇", right: "加湿器")
        ledger.observe([pair, pair])
        ledger.observe([pair])
        XCTAssertNil(ledger.pending(vocabulary: ""), "两次还不提")
        ledger.observe([pair])
        XCTAssertEqual(ledger.pending(vocabulary: "")?.right, "加湿器")
        XCTAssertNotNil(ledger.suggestedAt[VocabularySuggestions.key(wrong: "嘉士奇", right: "加湿器")])
        // 用户自己手动加进词汇表之后，不再提
        XCTAssertNil(ledger.pending(vocabulary: "加湿器"))
    }

    /// 一次只一条：计数最高的先提
    func testPendingPicksTheHighestCount() {
        var ledger = VocabularySuggestionLedger()
        for _ in 0..<3 { ledger.observe([(wrong: "嘉士奇", right: "加湿器")]) }
        for _ in 0..<5 { ledger.observe([(wrong: "pyton", right: "Python")]) }
        XCTAssertEqual(ledger.pending(vocabulary: "")?.right, "Python")
    }

    /// 忽略：永不再提，之后再出现也不再计数
    func testIgnoredIsNeverSuggestedAgain() {
        var ledger = VocabularySuggestionLedger()
        let pair = (wrong: "嘉士奇", right: "加湿器")
        for _ in 0..<3 { ledger.observe([pair]) }
        ledger.ignore(pair)
        XCTAssertNil(ledger.pending(vocabulary: ""))
        for _ in 0..<5 { ledger.observe([pair]) }
        XCTAssertNil(ledger.pending(vocabulary: ""))
        XCTAssertNil(ledger.counts[VocabularySuggestions.key(wrong: "嘉士奇", right: "加湿器")])
    }

    /// 换回原文：那一句投的票撤回，减 1 不低于 0，降到阈值以下就不再提
    func testRevertRetractsThatSentencesVotes() {
        var ledger = VocabularySuggestionLedger()
        let pair = (wrong: "嘉士奇", right: "加湿器")
        let key = VocabularySuggestions.key(wrong: "嘉士奇", right: "加湿器")
        for _ in 0..<3 { ledger.observe([pair]) }
        XCTAssertNotNil(ledger.pending(vocabulary: ""))
        ledger.retract([pair, pair])   // 同一句只撤一票
        XCTAssertEqual(ledger.counts[key], 2)
        XCTAssertNil(ledger.pending(vocabulary: ""))
        XCTAssertNil(ledger.suggestedAt[key])
        ledger.retract([pair]); ledger.retract([pair]); ledger.retract([pair])
        XCTAssertNil(ledger.counts[key], "不低于 0，归零就删掉")
        ledger.retract([(wrong: "pyton", right: "Python")])   // 没见过的词对：什么都不做
        XCTAssertTrue(ledger.counts.isEmpty)
    }

    /// 加入：词汇表末尾追加一行「错写=正写」（现有解析格式认得它），计数清掉
    func testAcceptAppendsAParseableLine() {
        XCTAssertEqual(VocabularySuggestions.appending((wrong: "嘉士奇", right: "加湿器"), to: ""), "嘉士奇=加湿器")
        let appended = VocabularySuggestions.appending((wrong: "嘉士奇", right: "加湿器"), to: "Power BI, Rappel")
        XCTAssertEqual(appended, "Power BI, Rappel\n嘉士奇=加湿器")
        XCTAssertEqual(VocabularySuggestions.appending((wrong: "a", right: "b"), to: "x\n"), "x\na=b")
        let parsed = Settings.parseVocabulary(appended)
        XCTAssertTrue(parsed.replacements.contains { $0.wrong == "嘉士奇" && $0.right == "加湿器" })

        var ledger = VocabularySuggestionLedger()
        let pair = (wrong: "嘉士奇", right: "加湿器")
        for _ in 0..<3 { ledger.observe([pair]) }
        ledger.accept(pair)
        XCTAssertTrue(ledger.counts.isEmpty)
        XCTAssertNil(ledger.pending(vocabulary: ""))
    }

    // MARK: - 落盘

    /// 往返：counts / ignored / suggestedAt 都读得回来；文件里只有词对，没有句子
    func testLedgerRoundTripsThroughTheFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabularySuggestionsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("suggestions.json")

        let store = VocabularySuggestionStore(fileURL: url)
        XCTAssertEqual(store.ledger, VocabularySuggestionLedger())
        let pair = (wrong: "嘉士奇", right: "加湿器")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for _ in 0..<3 { store.observeNow([pair], now: now) }
        store.observeNow([(wrong: "pyton", right: "Python")], now: now)
        store.ignore((wrong: "pyton", right: "Python"))
        store.waitForPendingWrites()

        let reloaded = VocabularySuggestionStore(fileURL: url)
        XCTAssertEqual(reloaded.ledger.counts, ["嘉士奇\u{2192}加湿器": 3])
        XCTAssertEqual(reloaded.ledger.ignored, ["pyton\u{2192}Python"])
        XCTAssertEqual(reloaded.ledger.suggestedAt["嘉士奇\u{2192}加湿器"], now)
        XCTAssertEqual(reloaded.pending(vocabulary: "")?.wrong, "嘉士奇")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["counts", "ignored", "suggestedAt"])

        // 坏文件当空表读
        try Data("{broken".utf8).write(to: url)
        XCTAssertEqual(VocabularySuggestionStore(fileURL: url).ledger, VocabularySuggestionLedger())
    }

    // MARK: - 文案

    func testQuestionIsBilingual() {
        L10n.shared.language = .zh
        XCTAssertEqual(VocabularySuggestionRow.question(right: "加湿器"), "把「加湿器」加进词汇表？")
        L10n.shared.language = .en
        XCTAssertEqual(VocabularySuggestionRow.question(right: "Python"),
                       "Add \u{201C}Python\u{201D} to your vocabulary?")
    }
}
