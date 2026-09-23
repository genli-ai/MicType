import XCTest
@testable import MicType

/// 听写历史（5.0.5 起是按天追加的纯文本）。
/// 钉住的是**格式**：文件名按天、一条记录长什么样、成稿与原文相同时不写第二行。
/// 这三件事一旦漂移，用户攒下来的那些文件就不再是同一种格式了。
final class HistoryStoreTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current   // 文件名与时间戳都按本地时间写：用户读的是自己的钟
        return f.date(from: iso)!
    }

    // MARK: - 文件名

    func testFileNameIsOnePerDayAndMatchesTheLogNamingStyle() {
        XCTAssertEqual(HistoryStore.fileName(for: date("2026-09-23 00:00:01")),
                       "transcripts-20260923.txt")
        XCTAssertEqual(HistoryStore.fileName(for: date("2026-09-23 23:59:59")),
                       "transcripts-20260923.txt")
        XCTAssertEqual(HistoryStore.fileName(for: date("2026-09-24 00:00:00")),
                       "transcripts-20260924.txt")
    }

    // MARK: - 一条记录的样子

    func testEntryHasTimestampedRawAndFinalLines() {
        let entry = HistoryStore.entry(raw: "今天下午三点开会",
                                       final: "今天下午 3 点开会。",
                                       date: date("2026-09-23 14:05:09"))
        XCTAssertEqual(entry, """
        [14:05:09] raw:   今天下午三点开会
                   final: 今天下午 3 点开会。

        """)
    }

    /// 成稿与原文相同（没润色 / 润色被丢弃 / Esc 保底那一行）：第二行不带任何信息，不写
    func testEntryOmitsFinalLineWhenItMatchesTheRaw() {
        let entry = HistoryStore.entry(raw: "Hello there", final: "Hello there",
                                       date: date("2026-09-23 09:00:00"))
        XCTAssertEqual(entry, "[09:00:00] raw:   Hello there\n")
        // 只差首尾空白也算相同
        XCTAssertEqual(HistoryStore.entry(raw: " Hello there ", final: "Hello there\n",
                                          date: date("2026-09-23 09:00:00")),
                       entry)
    }

    /// 文本自带的换行会把"一条记录一段"的结构冲散：续行缩进到键名后面
    func testMultilineTextIsIndentedSoOneEntryStaysOneBlock() {
        let entry = HistoryStore.entry(raw: "第一行\n第二行", final: "第一行\n第二行",
                                       date: date("2026-09-23 08:07:06"))
        XCTAssertEqual(entry, """
        [08:07:06] raw:   第一行
                          第二行

        """)
    }

    /// 什么都没识别出来时不留一条只有时间戳的空记录
    func testEmptyTextWritesNothing() {
        XCTAssertNil(HistoryStore.entry(raw: "", final: "", date: Date()))
        XCTAssertNil(HistoryStore.entry(raw: "  \n ", final: "", date: Date()))
    }

    // MARK: - 落盘（临时目录，绝不碰用户真实的日志目录）

    func testRecordAppendsToTheDayFileWithoutOverwriting() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MicTypeTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let keepHistory = Settings.shared.keepHistory
        Settings.shared.keepHistory = true
        defer { Settings.shared.keepHistory = keepHistory }

        let day = date("2026-09-23 10:00:00")
        store.record(raw: "一", final: "一。", date: day)
        store.record(raw: "二", final: "二", date: date("2026-09-23 10:00:30"))
        // 写在后台队列上：等它排空再读（比 sleep 稳，也不拖测试时长）
        store.waitForPendingWrites()

        let file = dir.appendingPathComponent(HistoryStore.fileName(for: day))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, """
        [10:00:00] raw:   一
                   final: 一。
        [10:00:30] raw:   二

        """)
    }

    /// 关掉开关就一个字都不落盘（连文件都不建）
    func testRecordWritesNothingWhenHistoryIsOff() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MicTypeTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let keepHistory = Settings.shared.keepHistory
        Settings.shared.keepHistory = false
        defer { Settings.shared.keepHistory = keepHistory }

        store.record(raw: "秘密", final: "秘密", date: Date())
        store.waitForPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
