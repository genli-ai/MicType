import XCTest
@testable import MicType

/// 设置状态卡右半边那三格：本周（周一起）的分钟 / 字数 / 约多少美元。
///
/// 这一层错了不会崩，但会在用户每次打开设置时说一个错的数——「本周」算成了最近 7 天、
/// 上周日晚上的那几句被算进这周、费用把指令漏了——而这是他打开设置最想看的那三件事。
final class UsageStoreTests: XCTestCase {

    private var savedLanguage: AppLanguage = .zh
    private let utc = TimeZone(identifier: "UTC")!

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    /// 2026-09-30 是周三（UTC）
    private func date(_ text: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = utc
        return f.date(from: text)!
    }

    private func entry(_ text: String, seconds: Double = 10, chars: Int = 30,
                       command: Bool = false) -> UsageEntry {
        UsageEntry(date: date(text), seconds: seconds, chars: chars, command: command)
    }

    // MARK: - 本周从哪天算起

    /// 本周 = 周一 00:00 起（ISO 周），不是"最近 7 天"
    func testWeekStartsOnMonday() {
        let wednesday = date("2026-09-30T15:00:00Z")
        XCTAssertEqual(UsageStore.weekStart(for: wednesday, timeZone: utc), date("2026-09-28T00:00:00Z"))
        // 周日还属于上周一起的那一周
        let sunday = date("2026-10-04T23:59:00Z")
        XCTAssertEqual(UsageStore.weekStart(for: sunday, timeZone: utc), date("2026-09-28T00:00:00Z"))
        // 周一零点本身就是新的一周
        let monday = date("2026-10-05T00:00:00Z")
        XCTAssertEqual(UsageStore.weekStart(for: monday, timeZone: utc), monday)
    }

    // MARK: - 聚合

    /// 本周的几句加起来：秒数、字数、句数
    func testSummarizesThisWeek() {
        let now = date("2026-09-30T15:00:00Z")
        let week = UsageStore.summarize([
            entry("2026-09-28T09:00:00Z", seconds: 30, chars: 100),
            entry("2026-09-29T12:00:00Z", seconds: 90, chars: 250, command: true),
            entry("2026-09-30T14:59:00Z", seconds: 60, chars: 150),
        ], now: now, timeZone: utc)
        XCTAssertEqual(week.seconds, 180, accuracy: 0.001)
        XCTAssertEqual(week.chars, 500)
        XCTAssertEqual(week.sentences, 3)
        XCTAssertFalse(week.isEmpty)
    }

    /// 跨周：上周日深夜那一句不算进这周；未来时间（时钟被调过）也不算
    func testIgnoresLastWeekAndTheFuture() {
        let now = date("2026-09-30T15:00:00Z")
        let week = UsageStore.summarize([
            entry("2026-09-27T23:59:59Z", seconds: 600, chars: 9_999),
            entry("2026-09-28T00:00:00Z", seconds: 10, chars: 20),
            entry("2026-10-01T08:00:00Z", seconds: 600, chars: 9_999),
        ], now: now, timeZone: utc)
        XCTAssertEqual(week.sentences, 1)
        XCTAssertEqual(week.chars, 20)
        XCTAssertEqual(week.seconds, 10, accuracy: 0.001)
    }

    /// 没有数据：三格都是「—」，而不是「0 分钟 / 0 字 / $0」
    func testEmptyWeekShowsDashes() {
        let week = UsageStore.summarize([], now: date("2026-09-30T15:00:00Z"), timeZone: utc)
        XCTAssertTrue(week.isEmpty)
        XCTAssertEqual(week, .empty)
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertEqual(UsageFormat.minutes(week), "—")
            XCTAssertEqual(UsageFormat.chars(week), "—")
            XCTAssertEqual(UsageFormat.cost(week), "—")
        }
    }

    // MARK: - 费用估算

    /// 识别按秒（实时 + 整段两段价）+ 每句一次润色，单价全部来自 LLMCatalog
    func testCostEstimateUsesTheCatalogPrices() {
        // 一小时、360 句 = LLMCatalog.hourlyUSD（识别 + 润色一小时的估算）
        XCTAssertEqual(UsageStore.estimatedCostUSD(seconds: 3600, sentences: Int(LLMCatalog.sentencesPerHour)),
                       LLMCatalog.hourlyUSD(provider: .openai), accuracy: 0.0001)
        // 只有识别：(0.017 + 0.0045) / 分钟
        XCTAssertEqual(UsageStore.estimatedCostUSD(seconds: 60, sentences: 0), 0.0215, accuracy: 0.00001)
        // 什么都没有就是 0，负数被夹成 0
        XCTAssertEqual(UsageStore.estimatedCostUSD(seconds: 0, sentences: 0), 0)
        XCTAssertEqual(UsageStore.estimatedCostUSD(seconds: -5, sentences: -1), 0)
    }

    /// 三格的写法：分钟四舍五入但说过话就至少 1；千分位；费用永远带「约」，不到一美分写 < $0.01
    func testFormatting() {
        let week = UsageWeek(seconds: 43 * 60 + 10, chars: 6_200, sentences: 120, costUSD: 0.1234)
        L10n.shared.language = .zh
        XCTAssertEqual(UsageFormat.minutes(week), "43 分钟")
        XCTAssertEqual(UsageFormat.chars(week), "6,200 字")
        XCTAssertEqual(UsageFormat.cost(week), "约 $0.12")
        L10n.shared.language = .en
        XCTAssertEqual(UsageFormat.minutes(week), "43 min")
        XCTAssertEqual(UsageFormat.chars(week), "6,200 chars")
        XCTAssertEqual(UsageFormat.cost(week), "~$0.12")

        let tiny = UsageWeek(seconds: 5, chars: 3, sentences: 1, costUSD: 0.002)
        XCTAssertEqual(UsageFormat.minutes(tiny), "1 min", "说过话就不许显示 0 分钟")
        XCTAssertEqual(UsageFormat.cost(tiny), "< $0.01")
    }

    // MARK: - 落盘

    /// 一行一句、能读回来；坏行跳过；只读最近 15 天
    func testRoundTripsThroughTheFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("usage.jsonl")
        let store = UsageStore(fileURL: url)
        XCTAssertTrue(store.recent.isEmpty)
        store.record(seconds: 12.5, chars: 40, command: false, date: Date())
        store.record(seconds: 3, chars: 8, command: true, date: Date())
        store.waitForPendingWrites()

        // 手动塞一行坏的、一行很久以前的
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let old = UsageStore.encode(UsageEntry(date: Date().addingTimeInterval(-30 * 24 * 3600),
                                               seconds: 999, chars: 999, command: false))!
        try handle.write(contentsOf: Data(("{broken\n" + old + "\n").utf8))
        try handle.close()

        let reloaded = UsageStore(fileURL: url)
        XCTAssertEqual(reloaded.recent.count, 2)
        XCTAssertEqual(reloaded.recent.first?.chars, 40)
        XCTAssertEqual(reloaded.recent.last?.command, true)
    }

    /// 账本里只有四样数字，一个字的内容都没有（和 Metrics 同一条纪律）
    func testEncodedLineCarriesNoText() throws {
        let line = try XCTUnwrap(UsageStore.encode(UsageEntry(date: Date(), seconds: 1, chars: 2,
                                                              command: false)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["date", "seconds", "chars", "command"])
    }

    // MARK: - 5.4.0：换回原文、上周

    /// 「换回原文」那一行只进 reverts，不进分钟 / 字数 / 句数 / 费用
    func testRevertsAreCountedApart() {
        let now = date("2026-09-30T15:00:00Z")
        let week = UsageStore.summarize([
            entry("2026-09-28T09:00:00Z", seconds: 30, chars: 100),
            UsageEntry(date: date("2026-09-28T09:00:05Z"), seconds: 0, chars: 0, command: false, revert: true),
            UsageEntry(date: date("2026-09-20T09:00:05Z"), seconds: 0, chars: 0, command: false, revert: true),
        ], now: now, timeZone: utc)
        XCTAssertEqual(week.sentences, 1)
        XCTAssertEqual(week.chars, 100)
        XCTAssertEqual(week.reverts, 1, "上周那次不算")
        XCTAssertEqual(week.costUSD, UsageStore.estimatedCostUSD(seconds: 30, sentences: 1), accuracy: 0.000001)
    }

    /// 旧账本（没有 revert 字段）按 false 读；revert 行写出来带 revert 键、读得回来
    func testRevertFieldIsOptionalOnDisk() throws {
        let old = #"{"chars":2,"command":false,"date":"2026-09-28T09:00:00Z","seconds":1}"#
        XCTAssertEqual(UsageStore.decode(old)?.revert, false)
        let line = try XCTUnwrap(UsageStore.encode(UsageEntry(date: Date(), seconds: 0, chars: 0,
                                                              command: false, revert: true)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(json["revert"] as? Bool, true)
        XCTAssertEqual(UsageStore.decode(line)?.revert, true)
    }

    /// 上周 = 上周一 00:00 到本周一 00:00（不含）
    func testPreviousWeekSummary() {
        let now = date("2026-10-04T23:00:00Z")   // 周日
        let entries = [
            entry("2026-09-20T23:59:59Z", seconds: 999, chars: 999),   // 上上周日
            entry("2026-09-21T00:00:00Z", seconds: 60, chars: 100),    // 上周一零点
            entry("2026-09-27T23:59:59Z", seconds: 120, chars: 200),   // 上周日
            entry("2026-09-28T00:00:00Z", seconds: 5, chars: 5),       // 本周一
        ]
        let previous = UsageStore.summarize(entries, now: now, week: .previous, timeZone: utc)
        XCTAssertEqual(previous.sentences, 2)
        XCTAssertEqual(previous.chars, 300)
        XCTAssertEqual(previous.seconds, 180, accuracy: 0.001)
        // 周日晚上启动也读得到上周一：启动只装 15 天
        XCTAssertLessThanOrEqual(UsageStore.loadCutoff(now: now), date("2026-09-21T00:00:00Z"))
    }

    func testWritingPreferencesLineMentionsRevertsOnlyWhenAny() {
        L10n.shared.language = .zh
        XCTAssertEqual(WritingPreferencesSummary.line(vocabulary: "a", rules: "", reverts: 0), "词汇表 1 条 · 规则 0 条")
        XCTAssertEqual(WritingPreferencesSummary.line(vocabulary: "a", rules: "", reverts: 3),
                       "词汇表 1 条 · 规则 0 条 · 本周换回原文 3 次")
        L10n.shared.language = .en
        XCTAssertEqual(WritingPreferencesSummary.line(vocabulary: "a", rules: "", reverts: 3),
                       "1 term · 0 rules · reverted 3× this week")
    }

    // MARK: - 状态卡左半边

    /// Key 尾号：末 4 位；短得离谱的不显示（露 4 位等于没藏）
    func testKeyTail() {
        XCTAssertEqual(SettingsStatusCard.keyTail("sk-proj-abcdefgh7f3a"), "7f3a")
        XCTAssertEqual(SettingsStatusCard.keyTail("  sk-proj-abcdefgh7f3a\n"), "7f3a")
        XCTAssertNil(SettingsStatusCard.keyTail(nil))
        XCTAssertNil(SettingsStatusCard.keyTail("sk-12345"))
    }

    /// 「写作偏好」那一行的两个数
    func testWritingPreferencesCounts() {
        XCTAssertEqual(WritingPreferencesSummary.vocabularyCount("Power BI, Rappel，云术法\n杰文|捷纹=捷文"), 4)
        XCTAssertEqual(WritingPreferencesSummary.vocabularyCount(""), 0)
        XCTAssertEqual(WritingPreferencesSummary.ruleCount("署名用 Gen；邮件偏正式。\n英文术语保留原文"), 3)
        XCTAssertEqual(WritingPreferencesSummary.ruleCount("   "), 0)
        L10n.shared.language = .zh
        XCTAssertEqual(WritingPreferencesSummary.line(vocabulary: "a, b", rules: "x"), "词汇表 2 条 · 规则 1 条")
        L10n.shared.language = .en
        XCTAssertEqual(WritingPreferencesSummary.line(vocabulary: "a, b", rules: "x"), "2 terms · 1 rule")
    }
}
