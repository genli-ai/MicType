import XCTest
@testable import MicType

/// 5.0.0 升级那一刻做的两件事：把本机模型从磁盘上删掉，以及把 4.x 的设置键认下来后忽略。
/// 两件都只有纯函数部分能单测——真删磁盘那一半绝不在测试里跑（它会删这台机器上的真目录）。
final class LocalModelCleanupTests: XCTestCase {

    // 「释放了多少」那条测试 5.0.1 随 gigabytesLabel 一起删掉：那句话不说了
    // （清理照做、只进日志），而一个没有读者的字符串不值得一条测试。

    /// 要删的东西**全部在 Application Support/MicType 下**——多拼一层用户目录就是一次
    /// 不可撤销的误删。这条测试盯的就是那个前缀。
    func testStaleDirectoriesStayInsideOurOwnFolder() {
        let urls = LocalModelCleanup.staleDirectories()
        XCTAssertFalse(urls.isEmpty)
        for url in urls {
            XCTAssertTrue(url.path.contains("/Application Support/MicType/"), url.path)
            XCTAssertFalse(url.path.contains(".."), url.path)
        }
        XCTAssertTrue(urls.contains { $0.lastPathComponent == "models" })
    }

    /// 不存在的路径量出来是 0，而且**绝不抛**：这个数只用来说一句"释放了多少"，
    /// 报少了顶多是那句话保守一点，绝不该为它冒任何风险
    func testDirectorySizeOfAMissingPathIsZero() {
        let missing = URL(fileURLWithPath: "/tmp/mictype-does-not-exist-\(UUID().uuidString)")
        XCTAssertEqual(LocalModelCleanup.directorySize(missing), 0)
        XCTAssertEqual(LocalModelCleanup.removeAll(at: [missing]), 0)
    }

    // MARK: - 4.x 的设置键：认下来，然后忽略

    /// 这张表只作忽略用。三条纪律里最要紧的一条是**不迁移**——那几件事在 5.0 里
    /// 没有对应的东西可写，硬迁只会把用户的设置搬进一个不存在的地方。
    func testLegacyKeysCoverEveryRemovedSetting() {
        for key in ["polishLevel", "recognitionEngine", "cloudRecognitionWanted",
                    "recognitionLanguage", "qwenModelRepo", "inputDeviceUID",
                    "chatModel", "qwenModel", "deepseekModel", "localModel",
                    "webSearchEnabled", "localRuntime"] {
            XCTAssertTrue(LegacyKeys.isLegacy(key), key)
        }
        // 按仓库存的那一条是前缀匹配（每个模型仓库一条）
        XCTAssertTrue(LegacyKeys.isLegacy("dismissedModelRefresh_mlx-community/Qwen3-ASR-0.6B-6bit"))
    }

    /// 5.0 还在用的键**一个都不许进这张表**：进了就会被当成遗留忽略掉
    func testStillLiveKeysAreNotLegacy() {
        for key in [SettingsKeys.hotkey, SettingsKeys.llmProvider, SettingsKeys.customVocabulary,
                    SettingsKeys.customPolishRules, SettingsKeys.qwenAPIHost,
                    SettingsKeys.cloudAlibabaModel, SettingsKeys.keepHistory,
                    SettingsKeys.onboardingCompleted] {
            XCTAssertFalse(LegacyKeys.isLegacy(key), key)
        }
    }
}
