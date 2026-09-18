import XCTest
@testable import MicType

/// 设置导入导出的纯函数层单测：只测列表合并（并集 + 判重），不碰 UserDefaults，
/// 所以跑测试不会改到用户的真实设置。`SettingsBackup.apply` 会写设置，故意不在这里测。
final class SettingsBackupTests: XCTestCase {

    func testMergeAppendsOnlyNewEntries() {
        let r = SettingsBackup.mergeList(existing: "捷文\nRappel", incoming: "Rappel\n云术法")
        XCTAssertEqual(r.merged, "捷文\nRappel\n云术法")
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.skipped, 1)
    }

    /// 老词条一条不能少：合并后原文前缀原样保留
    func testMergeKeepsExistingTextVerbatim() {
        let existing = "杰文|捷纹=捷文, MicType"
        let r = SettingsBackup.mergeList(existing: existing, incoming: "NYU")
        XCTAssertTrue(r.merged.hasPrefix(existing))
        XCTAssertTrue(r.merged.hasSuffix("NYU"))
        XCTAssertEqual(r.added, 1)
    }

    func testMergeWithNothingNewLeavesTextUntouched() {
        let existing = "嗯, 那个"
        let r = SettingsBackup.mergeList(existing: existing, incoming: "那个，嗯")
        XCTAssertEqual(r.merged, existing)
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(r.skipped, 2)
    }

    func testMergeIntoEmptySettingsProducesNewlineList() {
        let r = SettingsBackup.mergeList(existing: "", incoming: "嗯，那个、就是")
        XCTAssertEqual(r.merged, "嗯\n那个\n就是")
        XCTAssertEqual(r.added, 3)
    }

    /// 同一条在导入文件里重复出现，只进一次
    func testMergeDedupsWithinIncoming() {
        let r = SettingsBackup.mergeList(existing: "", incoming: "um, um, uh")
        XCTAssertEqual(r.merged, "um\nuh")
        XCTAssertEqual(r.added, 2)
        XCTAssertEqual(r.skipped, 1)
    }

    /// 西文大小写不同的写法可能是用户故意的，不当重复
    func testMergeIsCaseSensitive() {
        let r = SettingsBackup.mergeList(existing: "MicType", incoming: "mictype")
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.skipped, 0)
    }

    func testExportDocumentHasSchemaAndSettings() {
        let doc = SettingsBackup.makeDocument()
        XCTAssertEqual(doc["schemaVersion"] as? Int, SettingsBackup.schemaVersion)
        let settings = doc["settings"] as? [String: Any]
        XCTAssertNotNil(settings)
        // 导出的键必须全在已知表里，且绝不能出现任何形式的 Key
        for key in settings?.keys ?? [String: Any]().keys {
            XCTAssertTrue(SettingsBackup.Key.all.contains(key), "unexpected exported key: \(key)")
            XCTAssertFalse(key.lowercased().contains("apikey"))
        }
    }
}
