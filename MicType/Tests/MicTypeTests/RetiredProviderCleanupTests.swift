import XCTest
@testable import MicType

/// 5.1.0 删阿里云那一次启动清理（RetiredProviderCleanup）。
///
/// 为什么值得单测：这一步**会删用户钥匙串里的东西、会改他的服务商**，而且只跑一次——
/// 跑错了没有第二次机会。三件事钉死：
///   • qwen 用户被改回 openai，别的值一个字都不动；
///   • 阿里云的两条钥匙串条目被删，**OpenAI 那一条绝不被碰、也绝不被写**（不许把阿里云的 Key 搬过去）；
///   • 只跑一次。
/// UserDefaults 用一个一次性的 suite、钥匙串用一个记账的闭包——一个字节都不碰真实环境。
final class RetiredProviderCleanupTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "mictype.tests.retired-provider.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAlibabaUserIsResetToOpenAIAndHisAlibabaStateIsCleared() {
        defaults.set("qwen", forKey: SettingsKeys.llmProvider)
        defaults.set("dashscope-intl.aliyuncs.com", forKey: "qwenResolvedHost")
        defaults.set("ws-123.ap-southeast-1.maas.aliyuncs.com", forKey: "qwenAPIHost")
        defaults.set(true, forKey: "qwenHostVerified")
        defaults.set("qwen3-asr-flash", forKey: "cloudAlibabaModel")
        // 与阿里云无关的设置：一个字都不许动
        defaults.set("捷文=杰文", forKey: SettingsKeys.customVocabulary)

        var deleted: [String] = []
        let outcome = RetiredProviderCleanup.run(defaults: defaults) { deleted.append($0) }

        XCTAssertEqual(outcome, .init(providerReset: true, clearedDefaults: 4))
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.llmProvider), "openai")
        for key in LegacyKeys.retiredAlibaba {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.customVocabulary), "捷文=杰文")
        XCTAssertEqual(Set(deleted), ["qwen_api_key", "dashscope_api_key"])
        XCTAssertFalse(deleted.contains(LLMProvider.openai.keychainAccount),
                       "OpenAI 那一把绝不能被这一步碰到")
    }

    /// OpenAI 用户：服务商不动，但阿里云留下的钥匙串条目照样清掉（5.0.x 里他可能试过阿里云）
    func testOpenAIUserKeepsHisProvider() {
        defaults.set("openai", forKey: SettingsKeys.llmProvider)
        var deleted: [String] = []
        let outcome = RetiredProviderCleanup.run(defaults: defaults) { deleted.append($0) }
        XCTAssertEqual(outcome, .init(providerReset: false, clearedDefaults: 0))
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.llmProvider), "openai")
        XCTAssertEqual(Set(deleted), ["qwen_api_key", "dashscope_api_key"])
    }

    /// 只跑一次：第二次启动什么都不做（钥匙串一次都不碰）
    func testRunsOnlyOnce() {
        defaults.set("qwen", forKey: SettingsKeys.llmProvider)
        _ = RetiredProviderCleanup.run(defaults: defaults) { _ in }
        defaults.set("qwen", forKey: SettingsKeys.llmProvider)   // 假设有人又写回去了
        var deleted: [String] = []
        XCTAssertNil(RetiredProviderCleanup.run(defaults: defaults) { deleted.append($0) })
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.llmProvider), "qwen",
                       "第二次不该再改任何东西")
    }

    /// 迁移之后读出来的一定是 OpenAI（存量里残留的 qwen 也一样读成 OpenAI，不会崩）
    func testStoredQwenReadsAsOpenAI() {
        XCTAssertNil(LLMProvider(rawValue: "qwen"))
        XCTAssertEqual(RetiredProviderCleanup.retiredProviderRawValue, "qwen")
    }
}
