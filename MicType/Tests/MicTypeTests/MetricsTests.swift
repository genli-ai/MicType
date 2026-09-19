import XCTest
@testable import MicType

/// 性能指标（P20）的纯函数单测：中位数与毫秒格式化。
/// 这一层错了不会崩，只会让设置页里那行数字悄悄骗人——而用户正是拿它判断"是不是我的网慢"，
/// 所以边界（空样本、偶数个、没润色的那些轮、999/1000ms 的分界）必须钉死。
final class MetricsTests: XCTestCase {

    private func metric(asr: Int, polish: Int?, insert: Int,
                        mode: SessionMetric.Mode = .dictation) -> SessionMetric {
        SessionMetric(date: Date(), mode: mode, asrMs: asr, polishMs: polish, insertMs: insert,
                      audioSeconds: 3, partialCount: 2, cold: false)
    }

    // MARK: - 中位数

    func testMedianOfOddCountIsMiddleValue() {
        XCTAssertEqual(Metrics.median([300, 100, 200]), 200)
        XCTAssertEqual(Metrics.median([42]), 42)
    }

    /// 偶数个取中间两个的整数平均（向下取整，毫秒级的舍入没人关心）
    func testMedianOfEvenCountAveragesMiddlePair() {
        XCTAssertEqual(Metrics.median([100, 200, 300, 400]), 250)
        XCTAssertEqual(Metrics.median([100, 101]), 100)
    }

    /// 一个样本都没有必须是 nil 而不是 0：界面靠这个区分"还没用过"和"快到 0 毫秒"
    func testMedianOfEmptyIsNil() {
        XCTAssertNil(Metrics.median([]))
    }

    /// 中位数的全部意义：一次冷启动（慢十几倍）不该污染"平常多快"
    func testMedianIgnoresColdStartOutlier() {
        XCTAssertEqual(Metrics.median([300, 320, 310, 330, 9000]), 320)
    }

    // MARK: - 毫秒格式化

    func testFormatMsUsesMillisecondsBelowOneSecond() {
        XCTAssertEqual(Metrics.formatMs(0), "0 ms")
        XCTAssertEqual(Metrics.formatMs(320), "320 ms")
        XCTAssertEqual(Metrics.formatMs(999), "999 ms")
    }

    func testFormatMsSwitchesToSecondsAtOneThousand() {
        XCTAssertEqual(Metrics.formatMs(1000), "1.0 s")
        XCTAssertEqual(Metrics.formatMs(1800), "1.8 s")
        XCTAssertEqual(Metrics.formatMs(12340), "12.3 s")
    }

    // MARK: - 摘要

    func testDigestTakesOnlyTheMostRecentSessions() {
        // 新的在前：前 2 条是最近两轮，第三条（很慢的那次）不该参与
        let items = [metric(asr: 100, polish: 1000, insert: 50),
                     metric(asr: 200, polish: 2000, insert: 90),
                     metric(asr: 9000, polish: 9000, insert: 9000)]
        let digest = Metrics.digest(items, count: 2)
        XCTAssertEqual(digest?.sampleCount, 2)
        XCTAssertEqual(digest?.asrMs, 150)
        XCTAssertEqual(digest?.polishMs, 1500)
        XCTAssertEqual(digest?.polishSampleCount, 2)
        XCTAssertEqual(digest?.insertMs, 70)
    }

    /// 不足 count 轮时如实报实际轮数——界面上写的是"最近 N 次"，N 必须是真的
    func testDigestReportsActualSampleCount() {
        let digest = Metrics.digest([metric(asr: 300, polish: nil, insert: 80)], count: 10)
        XCTAssertEqual(digest?.sampleCount, 1)
        XCTAssertEqual(digest?.asrMs, 300)
    }

    func testDigestOfEmptyIsNil() {
        XCTAssertNil(Metrics.digest([], count: 10))
    }

    /// 没走大模型的那些轮（档位关着 / 纯识别）不能当成 0 毫秒拉低中位数
    func testDigestSkipsSessionsWithoutPolish() {
        let items = [metric(asr: 300, polish: nil, insert: 80),
                     metric(asr: 300, polish: 2000, insert: 80),
                     metric(asr: 300, polish: nil, insert: 80)]
        let digest = Metrics.digest(items, count: 10)
        XCTAssertEqual(digest?.polishMs, 2000)
        // 三轮里只有一轮走过大模型：那一段的样本量就是 1，不能拿 sampleCount=3 替它背书
        XCTAssertEqual(digest?.polishSampleCount, 1)
        XCTAssertEqual(digest?.sampleCount, 3)
    }

    /// 摘要行里"模型"那一段必须带自己的次数：它和识别/插入不是一个样本量
    func testSummaryLineQualifiesPolishWithItsOwnCount() {
        let items = [metric(asr: 300, polish: nil, insert: 80),
                     metric(asr: 300, polish: 9000, insert: 80),
                     metric(asr: 300, polish: nil, insert: 80)]
        let line = Metrics.summaryLine(Metrics.digest(items, count: 10)!)
        XCTAssertTrue(line.contains("9.0 s"))
        XCTAssertTrue(line.contains("1"), line)
        XCTAssertTrue(line.contains("3"), line)
    }

    /// 一次润色都没有 → nil，摘要那一行里干脆不出现"润色"这一段
    func testDigestWithoutAnyPolishHasNilPolish() {
        let items = [metric(asr: 300, polish: nil, insert: 80),
                     metric(asr: 340, polish: nil, insert: 90)]
        let digest = Metrics.digest(items, count: 10)
        XCTAssertNotNil(digest)
        XCTAssertNil(digest?.polishMs)
    }

    /// 摘要行：有润色就三段，没润色就两段（两种语言下结构一致，这里只钉结构与数字）
    func testSummaryLineDropsPolishSegmentWhenAbsent() {
        let withPolish = Metrics.summaryLine(
            Metrics.Digest(sampleCount: 10, asrMs: 320, polishMs: 1800,
                           polishSampleCount: 10, insertMs: 90))
        XCTAssertEqual(withPolish.components(separatedBy: " · ").count, 3)
        XCTAssertTrue(withPolish.contains("320 ms"))
        XCTAssertTrue(withPolish.contains("1.8 s"))
        XCTAssertTrue(withPolish.contains("90 ms"))
        XCTAssertTrue(withPolish.contains("10"))

        let withoutPolish = Metrics.summaryLine(
            Metrics.Digest(sampleCount: 3, asrMs: 320, polishMs: nil,
                           polishSampleCount: 0, insertMs: 90))
        XCTAssertEqual(withoutPolish.components(separatedBy: " · ").count, 2)
    }

    // MARK: - 诊断行

    /// 诊断行固定英文、固定字段：贴给别人看的东西不跟界面语言走。
    /// 没走大模型的那一轮写 "-" 而不是 0——"没发生"和"零毫秒"必须一眼能分开。
    /// 字段名跟着手势走：轻点是 polish，按住是 model。
    func testDiagnosticRowMarksMissingPolishWithDash() {
        let row = metric(asr: 320, polish: nil, insert: 90, mode: .command).diagnosticRow
        XCTAssertTrue(row.contains("command"))
        XCTAssertTrue(row.contains("asr=320ms"))
        XCTAssertTrue(row.contains("model=-"))
        XCTAssertTrue(row.contains("insert=90ms"))
        XCTAssertTrue(row.contains("cold=false"))

        let tap = metric(asr: 320, polish: 1800, insert: 90).diagnosticRow
        XCTAssertTrue(tap.contains("dictation"))
        XCTAssertTrue(tap.contains("polish=1800ms"))
    }
}
