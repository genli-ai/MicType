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

    /// 新加的偏好要跟着备份走：导出表里必须有它，键名也必须在已知表里（否则导入端会忽略）
    func testExportIncludesKeepHistoryPreference() {
        let settings = SettingsBackup.makeDocument()["settings"] as? [String: Any]
        XCTAssertNotNil(settings?[SettingsBackup.Key.keepHistory] as? Bool)
        XCTAssertTrue(SettingsBackup.Key.all.contains(SettingsBackup.Key.keepHistory))
    }

    // MARK: 接口地址白名单（导入的 base URL 决定 API Key 发给谁）

    func testAcceptsHttpsEndpoints() {
        XCTAssertTrue(SettingsBackup.isAcceptableBaseURL("https://api.openai.com/v1"))
        XCTAssertTrue(SettingsBackup.isAcceptableBaseURL("  https://api.deepseek.com/v1  "))
    }

    /// 明文 http 一律不收：ATS 本来就会拦掉，存进去只是一个用不了的地址
    func testRejectsPlainHttpEndpoint() {
        XCTAssertFalse(SettingsBackup.isAcceptableBaseURL("http://relay.attacker.tld/v1"))
    }

    /// 没有主机名 / 不是 URL / 空串：一个都不能进设置
    func testRejectsMalformedEndpoints() {
        XCTAssertFalse(SettingsBackup.isAcceptableBaseURL(""))
        XCTAssertFalse(SettingsBackup.isAcceptableBaseURL("   "))
        XCTAssertFalse(SettingsBackup.isAcceptableBaseURL("https:///v1"))
        XCTAssertFalse(SettingsBackup.isAcceptableBaseURL("api.openai.com/v1"))
        XCTAssertFalse(SettingsBackup.isAcceptableBaseURL("file:///etc/passwd"))
        XCTAssertFalse(SettingsBackup.isAcceptableBaseURL("HTTP://api.openai.com/v1"))
    }

    /// 自己导出的地址必须能被自己导回来（白名单不能把正常配置也挡掉）
    func testExportedEndpointsSurviveTheImportCheck() {
        let settings = SettingsBackup.makeDocument()["settings"] as? [String: Any]
        for key in [SettingsBackup.Key.openaiBaseURL, SettingsBackup.Key.deepseekBaseURL] {
            let value = settings?[key] as? String ?? ""
            XCTAssertTrue(SettingsBackup.isAcceptableBaseURL(value), "exported \(key) rejected: \(value)")
        }
    }

    // MARK: 失败文案（系统错误不能把界面语言带跑偏）

    /// describe() 里系统错误走的是 localizedDescription——那跟的是 macOS 的语言，
    /// 不是 MicType 的界面语言。所以前面必须先给一句本语言的说明，系统原文只当细节。
    func testFailureDetailLeadsWithInterfaceLanguage() {
        let saved = L10n.shared.language
        defer { L10n.shared.language = saved }

        L10n.shared.language = .en
        let english = SettingsBackup.failureDetail(systemMessage: "No such file or directory")
        XCTAssertEqual(english, "The system reported an error (No such file or directory)")

        L10n.shared.language = .zh
        let chinese = SettingsBackup.failureDetail(systemMessage: "No such file or directory")
        XCTAssertEqual(chinese, "系统报错（No such file or directory）")
    }

    func testFailureDetailWithoutSystemMessage() {
        let saved = L10n.shared.language
        defer { L10n.shared.language = saved }

        L10n.shared.language = .en
        XCTAssertEqual(SettingsBackup.failureDetail(systemMessage: "   "),
                       "The system reported an error without a reason")
        L10n.shared.language = .zh
        XCTAssertEqual(SettingsBackup.failureDetail(systemMessage: ""),
                       "系统报错，但没有给出原因")
    }

    func testDescribeKeepsOwnErrorMessageAsIs() {
        // MTError 的文字本来就是 tr() 出来的，不该再被包一层
        XCTAssertEqual(SettingsBackup.describe(MTError("文件内容不是 JSON 对象")),
                       "文件内容不是 JSON 对象")
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
