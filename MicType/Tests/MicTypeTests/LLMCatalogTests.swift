import XCTest
@testable import MicType

/// 型号目录的纯函数单测：默认值、温度能力、迁移矩阵、错误话术。
/// 这一层错了不会崩，但会**悄悄花用户的钱**（旗舰跑在每句话上）、**悄悄把他手选的型号改掉**，
/// 或者在真正失败时给一句看不出该干什么的提示——所以每条规则都钉死在这里。
final class LLMCatalogTests: XCTestCase {

    private var savedLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: - 预设与默认

    /// 默认型号必须落在快选列表里，否则设置页下拉框里看不到"当前用的那个"
    func testDefaultsAreInsideThePresetLists() {
        XCTAssertTrue(LLMCatalog.openaiPresets.contains(LLMCatalog.openaiPolishDefault))
        XCTAssertTrue(LLMCatalog.openaiPresets.contains(LLMCatalog.openaiCommandDefault))
        XCTAssertTrue(LLMCatalog.deepseekPresets.contains(LLMCatalog.deepseekPolishDefault))
        XCTAssertTrue(LLMCatalog.deepseekPresets.contains(LLMCatalog.deepseekCommandDefault))
    }

    /// 润色（每句话都跑）必须比指令（低频）便宜：luna / terra 这条搭配是整个成本模型的前提
    func testDefaultsPutTheCheapModelOnThePolishPath() {
        XCTAssertEqual(LLMCatalog.polishDefault(for: .openai), "gpt-5.6-luna")
        XCTAssertEqual(LLMCatalog.commandDefault(for: .openai), "gpt-5.6-terra")
        XCTAssertEqual(LLMCatalog.polishDefault(for: .deepseek), "deepseek-flash")
        XCTAssertEqual(LLMCatalog.commandDefault(for: .deepseek), "deepseek-v4-pro")
    }

    // MARK: - 温度能力

    func testReasoningModelsRejectCustomTemperature() {
        for model in ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-6-astra",
                      "gpt-5.5", "o3-mini", "o1", "gpt-5.4-pro", "deepseek-v4-pro"] {
            XCTAssertTrue(LLMCatalog.rejectsCustomTemperature(model), model)
        }
    }

    func testOrdinaryModelsStillAcceptTemperature() {
        for model in ["gpt-4o-mini", "gpt-5.4-mini", "gpt-5.4-nano", "deepseek-flash",
                      "qwen-flash", "glm-4.7-flash"] {
            XCTAssertFalse(LLMCatalog.rejectsCustomTemperature(model), model)
        }
    }

    // MARK: - reasoning.effort

    /// 润色要最快的一档；gpt-6-astra 不支持 none，发了会 400 → 必须退到 low
    func testPolishUsesEffortNoneExceptOnAstra() {
        XCTAssertEqual(LLMCatalog.effort(purpose: .polish, model: "gpt-5.6-luna"), "none")
        XCTAssertEqual(LLMCatalog.effort(purpose: .polish, model: "gpt-5.5"), "none")
        XCTAssertEqual(LLMCatalog.effort(purpose: .polish, model: "gpt-6-astra"), "low")
    }

    func testCommandsAlwaysUseLowEffort() {
        XCTAssertEqual(LLMCatalog.effort(purpose: .command, model: "gpt-5.6-terra"), "low")
        XCTAssertEqual(LLMCatalog.effort(purpose: .command, model: "gpt-6-astra"), "low")
    }

    // MARK: - 输出额度

    func testMaxOutputTokensNeverDropsBelowTheFloor() {
        XCTAssertEqual(LLMCatalog.maxOutputTokens(inputCharacters: 0, minimum: 2048), 2048)
        XCTAssertEqual(LLMCatalog.maxOutputTokens(inputCharacters: 10, minimum: 4096), 4096)
    }

    /// 长口述要跟着长：写死 2048 会让 10 分钟的稿子被静默截断成半句话
    func testMaxOutputTokensGrowsWithInputAndIsCapped() {
        XCTAssertEqual(LLMCatalog.maxOutputTokens(inputCharacters: 3000, minimum: 2048), 7024)
        XCTAssertEqual(LLMCatalog.maxOutputTokens(inputCharacters: 1_000_000, minimum: 2048), 32768)
    }

    // MARK: - 迁移矩阵

    private func migrate(polish: String?, command: String?,
                         dsPolish: String? = LLMCatalog.deepseekPolishDefault,
                         dsCommand: String? = LLMCatalog.deepseekCommandDefault) -> [String: String] {
        LLMCatalog.migrationTo56(current: [
            SettingsKeys.chatModel: polish,
            SettingsKeys.openaiCommandModel: command,
            SettingsKeys.deepseekModel: dsPolish,
            SettingsKeys.deepseekCommandModel: dsCommand,
        ])
    }

    /// 历史上由 MicType 自己写进去的那几个润色默认值，全部搬到 luna
    func testAutomaticPolishDefaultsMoveToLuna() {
        for old in [nil, "gpt-4o-mini", "gpt-5.4-nano", "gpt-5.5"] {
            let writes = migrate(polish: old, command: "gpt-5.4-mini")
            XCTAssertEqual(writes[SettingsKeys.chatModel], "gpt-5.6-luna", old ?? "nil")
        }
    }

    /// 铁律：用户手选过的型号一个都不动——哪怕它更贵、更旧
    func testHandPickedModelsAreNeverTouched() {
        let writes = migrate(polish: "gpt-5.4", command: "gpt-5.5")
        XCTAssertNil(writes[SettingsKeys.chatModel])
        XCTAssertNil(writes[SettingsKeys.openaiCommandModel])
    }

    func testAutomaticCommandDefaultMovesToTerra() {
        XCTAssertEqual(migrate(polish: "gpt-5.5", command: nil)[SettingsKeys.openaiCommandModel],
                       "gpt-5.6-terra")
        XCTAssertEqual(migrate(polish: "gpt-5.5", command: "gpt-5.4-mini")[SettingsKeys.openaiCommandModel],
                       "gpt-5.6-terra")
    }

    /// DeepSeek 那三个型号已经不存在了：不改名的话每次调用都失败——所以无论是不是手选的都得改
    func testDeadDeepSeekModelsAreRenamed() {
        let writes = migrate(polish: "gpt-5.6-luna", command: "gpt-5.6-terra",
                             dsPolish: "deepseek-v4-flash", dsCommand: "deepseek-reasoner")
        XCTAssertEqual(writes[SettingsKeys.deepseekModel], "deepseek-flash")
        XCTAssertEqual(writes[SettingsKeys.deepseekCommandModel], "deepseek-v4-pro")

        let chat = migrate(polish: "gpt-5.6-luna", command: "gpt-5.6-terra",
                           dsPolish: "deepseek-chat", dsCommand: "deepseek-v4-pro")
        XCTAssertEqual(chat[SettingsKeys.deepseekModel], "deepseek-flash")
        XCTAssertNil(chat[SettingsKeys.deepseekCommandModel])
    }

    /// 没存过 DeepSeek 型号的人直接拿到新默认
    func testUnsetDeepSeekModelsGetTheNewDefaults() {
        let writes = migrate(polish: "gpt-5.6-luna", command: "gpt-5.6-terra",
                             dsPolish: nil, dsCommand: nil)
        XCTAssertEqual(writes[SettingsKeys.deepseekModel], "deepseek-flash")
        XCTAssertEqual(writes[SettingsKeys.deepseekCommandModel], "deepseek-v4-pro")
    }

    /// 已经在新型号上 → 一个键都不写（迁移幂等，跑第二遍不该有任何动作）
    func testMigrationIsANoOpOnCurrentValues() {
        let writes = migrate(polish: "gpt-5.6-luna", command: "gpt-5.6-terra")
        XCTAssertTrue(writes.isEmpty, "\(writes)")
    }

    /// 空字符串等同于"没存过"（钥匙串/备份导入留下的空值不该被当成手选型号）
    func testEmptyStringCountsAsUnset() {
        XCTAssertEqual(migrate(polish: "   ", command: "")[SettingsKeys.chatModel], "gpt-5.6-luna")
        XCTAssertEqual(migrate(polish: "   ", command: "")[SettingsKeys.openaiCommandModel],
                       "gpt-5.6-terra")
    }

    // MARK: - 错误话术

    func testInvalidKeyAndRegionAndModelErrors() {
        L10n.shared.language = .en
        let key = LLMCatalog.describeHTTPError(status: 401, provider: .openai, code: nil, message: nil)
        XCTAssertTrue(key.text.contains("401"))
        XCTAssertNil(key.actionURL)

        let region = LLMCatalog.describeHTTPError(status: 403, provider: .openai,
                                                 code: "unsupported_country_region_territory",
                                                 message: "Country, region, or territory not supported")
        XCTAssertTrue(region.text.contains("403"))
        // 403 必须给出下一步：换 DeepSeek 或自定义端点（用户在 UAE，这条命中率不低）
        XCTAssertTrue(region.text.contains("DeepSeek"))

        let model = LLMCatalog.describeHTTPError(status: 404, provider: .openai, code: nil,
                                                message: "The model `gpt-9` does not exist")
        XCTAssertTrue(model.text.contains("404"))
        XCTAssertTrue(model.text.contains("gpt-9"))
    }

    /// 429 的两种含义必须分开说：一个该等几秒，一个该去充钱
    func testRateLimitAndQuotaAreDifferentCopy() {
        L10n.shared.language = .en
        let limited = LLMCatalog.describeHTTPError(status: 429, provider: .openai,
                                                   code: "rate_limit_exceeded",
                                                   message: "Rate limit reached for gpt-5.6-luna")
        XCTAssertNil(limited.actionURL)
        XCTAssertTrue(limited.text.lowercased().contains("rate limited"))

        let broke = LLMCatalog.describeHTTPError(status: 429, provider: .openai,
                                                 code: "insufficient_quota",
                                                 message: "You exceeded your current quota")
        XCTAssertEqual(broke.actionLabel, "Add credit")
        XCTAssertEqual(broke.actionURL, "https://platform.openai.com/settings/organization/billing")
        // 悬浮窗只能显示纯文本 → 链接要拼进句子里，用户才看得到该去哪儿
        XCTAssertTrue(broke.fullText.contains("https://platform.openai.com"))
        XCTAssertTrue(broke.fullText.contains("Add credit"))
    }

    func testCapacityAndUnknownStatusCopy() {
        L10n.shared.language = .en
        XCTAssertTrue(LLMCatalog.describeHTTPError(status: 503, provider: .deepseek,
                                                   code: nil, message: nil).text.contains("503"))
        XCTAssertTrue(LLMCatalog.describeHTTPError(status: 500, provider: .deepseek,
                                                   code: nil, message: nil).text.contains("500"))
    }

    /// 英文界面下这几条话术里不能混进中文或全角标点（英文用户看到「：」就是 bug）
    func testEnglishCopyHasNoCJKOrFullWidthPunctuation() {
        L10n.shared.language = .en
        var texts = [LLMCatalog.timeoutCopy().fullText]
        for status in [401, 403, 404, 429, 503, 500] {
            texts.append(LLMCatalog.describeHTTPError(status: status, provider: .openai,
                                                      code: "insufficient_quota",
                                                      message: "detail").fullText)
        }
        let forbidden = CharacterSet(charactersIn: "：，。；？！（）、「」").union(
            CharacterSet(charactersIn: UnicodeScalar(0x4E00)!...UnicodeScalar(0x9FFF)!))
        for text in texts {
            XCTAssertNil(text.rangeOfCharacter(from: forbidden), text)
        }
    }

    /// 中文界面下同样要是完整的中文句子（带「：」分隔，不是半截英文）
    func testChineseCopyIsChinese() {
        L10n.shared.language = .zh
        let broke = LLMCatalog.describeHTTPError(status: 429, provider: .deepseek,
                                                 code: "insufficient_balance", message: nil)
        XCTAssertEqual(broke.actionLabel, "去充值")
        XCTAssertTrue(broke.text.contains("余额不足"))
        XCTAssertTrue(broke.fullText.contains("https://platform.deepseek.com/top_up"))
    }
}
