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

    /// 403 必须按服务商分流：建议换去的那一档不能是他正在用的那一档，
    /// 而 DashScope 的 403 根本不是地区封锁（是模型没在百炼控制台开通）
    func testForbiddenCopyIsProviderSpecific() {
        L10n.shared.language = .en
        let deepseek = LLMCatalog.describeHTTPError(status: 403, provider: .deepseek,
                                                    code: nil, message: nil)
        XCTAssertTrue(deepseek.text.contains("403"))
        XCTAssertFalse(deepseek.text.contains("DeepSeek"),
                       "别建议 DeepSeek 用户改用 DeepSeek: \(deepseek.text)")

        let qwen = LLMCatalog.describeHTTPError(status: 403, provider: .qwen, code: nil, message: nil)
        XCTAssertTrue(qwen.text.contains("Model Studio"))
        XCTAssertFalse(qwen.text.lowercased().contains("country"))

        let local = LLMCatalog.describeHTTPError(status: 403, provider: .local, code: nil, message: nil)
        XCTAssertTrue(local.text.contains("Ollama"))
        XCTAssertFalse(local.text.lowercased().contains("region"))

        let custom = LLMCatalog.describeHTTPError(status: 403, provider: .custom, code: nil, message: nil)
        XCTAssertTrue(custom.text.contains("403"))
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

    // MARK: - 新服务商（B9）

    /// 每个服务商一条独立的钥匙串账户：撞名就会互相覆盖，用户的 Key 会莫名其妙消失
    func testKeychainAccountsAreUnique() {
        let accounts = LLMProvider.allCases.map(\.keychainAccount)
        XCTAssertEqual(Set(accounts).count, accounts.count)
    }

    /// 只有本机模型那一档不需要 Key——这是"容忍空 Key"的唯一出口，别顺手放宽到别的服务商
    func testOnlyLocalProviderSkipsTheAPIKey() {
        XCTAssertFalse(LLMProvider.local.requiresAPIKey)
        for provider in LLMProvider.allCases where provider != .local {
            XCTAssertTrue(provider.requiresAPIKey, provider.rawValue)
        }
    }

    /// 自定义端点与本机模型没有内置型号清单（猜出来的清单只会误导人）
    func testCustomAndLocalHaveNoPresetsOrDefaults() {
        for provider in [LLMProvider.custom, .local] {
            XCTAssertTrue(LLMCatalog.presets(for: provider).isEmpty, provider.rawValue)
            XCTAssertTrue(LLMCatalog.polishDefault(for: provider).isEmpty, provider.rawValue)
            XCTAssertTrue(LLMCatalog.commandDefault(for: provider).isEmpty, provider.rawValue)
        }
    }

    /// Qwen 的默认型号同样要落在快选里
    func testQwenDefaultsAreInsideItsPresets() {
        XCTAssertTrue(LLMCatalog.qwenPresets.contains(LLMCatalog.qwenPolishDefault))
        XCTAssertTrue(LLMCatalog.qwenPresets.contains(LLMCatalog.qwenCommandDefault))
    }

    // MARK: - Qwen 区域 → Base URL

    /// 国际站不需要 WorkspaceId，直接给地址
    func testQwenGlobalRegionsNeedNoWorkspace() {
        XCTAssertEqual(LLMCatalog.qwenBaseURL(region: .international, workspaceID: ""),
                       "https://dashscope-intl.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(LLMCatalog.qwenBaseURL(region: .us, workspaceID: "ignored"),
                       "https://dashscope-us.aliyuncs.com/compatible-mode/v1")
        XCTAssertFalse(LLMCatalog.QwenRegion.international.requiresWorkspaceID)
    }

    /// 区域端点把 WorkspaceId 放在主机名第一段
    func testQwenRegionalEndpointEmbedsTheWorkspaceID() {
        XCTAssertEqual(LLMCatalog.qwenBaseURL(region: .beijing, workspaceID: " llm-abc123 "),
                       "https://llm-abc123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(LLMCatalog.qwenBaseURL(region: .singapore, workspaceID: "ws"),
                       "https://ws.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1")
    }

    /// **没填 WorkspaceId 时宁可给空地址**：偷偷退回国际站等于把 Key 和听写文本
    /// 发到用户没选的区域去
    func testQwenRegionalEndpointWithoutWorkspaceIsEmpty() {
        for region in LLMCatalog.QwenRegion.allCases where region.requiresWorkspaceID {
            XCTAssertEqual(LLMCatalog.qwenBaseURL(region: region, workspaceID: "   "), "",
                           region.rawValue)
        }
    }

    // MARK: - 自定义 Base URL 校验

    func testCustomBaseURLAcceptsHTTPSWithVersionSegment() {
        for url in ["https://api.moonshot.ai/v1",
                    "https://generativelanguage.googleapis.com/v1beta/openai/",
                    "https://api.z.ai/api/paas/v4/",
                    "https://openrouter.ai/api/v1"] {
            XCTAssertNil(LLMCatalog.validateCustomBaseURL(url), url)
        }
    }

    /// 本机地址是明文 http 的唯一例外
    func testCustomBaseURLAllowsPlainHTTPOnlyOnLocalhost() {
        XCTAssertNil(LLMCatalog.validateCustomBaseURL("http://localhost:11434/v1"))
        XCTAssertNil(LLMCatalog.validateCustomBaseURL("http://127.0.0.1:1234/v1"))
        XCTAssertEqual(LLMCatalog.validateCustomBaseURL("http://api.example.com/v1"), .insecure)
    }

    /// 少了版本段的地址每次调用都是 404，而报错写的是"找不到模型"——必须当面说清
    func testCustomBaseURLRequiresAVersionSegment() {
        XCTAssertEqual(LLMCatalog.validateCustomBaseURL("https://api.example.com"), .noVersionSegment)
        XCTAssertEqual(LLMCatalog.validateCustomBaseURL("https://api.example.com/openai"),
                       .noVersionSegment)
        XCTAssertEqual(LLMCatalog.validateCustomBaseURL("  "), .empty)
        XCTAssertEqual(LLMCatalog.validateCustomBaseURL("not a url"), .malformed)
    }

    func testLocalHostDetection() {
        XCTAssertTrue(LLMCatalog.isLocalHost("http://localhost:11434/v1"))
        XCTAssertTrue(LLMCatalog.isLocalHost("http://127.0.0.1:1234/v1"))
        XCTAssertFalse(LLMCatalog.isLocalHost("https://api.openai.com/v1"))
        XCTAssertFalse(LLMCatalog.isLocalHost(""))
    }

    /// 本机运行时的地址就是这两个软件的招牌端口，改了就不叫预设了
    func testLocalRuntimeBaseURLs() {
        XCTAssertEqual(LLMCatalog.LocalRuntime.ollama.baseURL, "http://localhost:11434/v1")
        XCTAssertEqual(LLMCatalog.LocalRuntime.lmstudio.baseURL, "http://localhost:1234/v1")
        for runtime in LLMCatalog.LocalRuntime.allCases {
            XCTAssertNil(LLMCatalog.validateCustomBaseURL(runtime.baseURL), runtime.rawValue)
        }
    }

    // MARK: - 模型列表（B10）

    /// 嵌入 / 图像 / 语音 / 审核类型号进了下拉框，用户选中就是一次必然失败的调用
    func testModelListDropsNonChatModels() {
        let ids = ["gpt-5.6-luna", "text-embedding-3-large", "gpt-4o-audio-preview",
                   "dall-e-3", "whisper-1", "omni-moderation-latest", "qwen-vl-vision",
                   "tts-1", "gpt-5.6-terra"]
        XCTAssertEqual(LLMCatalog.usableModelIDs(from: ids), ["gpt-5.6-luna", "gpt-5.6-terra"])
    }

    /// 去重 + 排序 + 丢掉空白项
    func testModelListIsDeduplicatedAndSorted() {
        XCTAssertEqual(LLMCatalog.usableModelIDs(from: ["b", " a ", "b", "  ", "c"]),
                       ["a", "b", "c"])
    }

    /// 手写预设永远在前：它们是我们选过、知道贵不贵的那几个
    func testMergedModelListKeepsPresetsFirst() {
        let merged = LLMCatalog.mergedModelList(presets: ["gpt-5.6-luna", "gpt-5.6-terra"],
                                                fetched: ["zeta", "gpt-5.6-luna", "alpha",
                                                          "text-embedding-3-small"])
        XCTAssertEqual(merged, ["gpt-5.6-luna", "gpt-5.6-terra", "alpha", "zeta"])
    }

    /// 拉取失败（空数组）时下拉框保持原样
    func testMergedModelListFallsBackToPresets() {
        XCTAssertEqual(LLMCatalog.mergedModelList(presets: LLMCatalog.deepseekPresets, fetched: []),
                       LLMCatalog.deepseekPresets)
    }

    // MARK: - 联网搜索写法（B11）

    func testSearchStylePerProvider() {
        XCTAssertEqual(LLMCatalog.searchStyle(provider: .openai, baseURL: "https://api.openai.com/v1"),
                       .openaiResponsesTool)
        // OpenAI 档指向第三方网关时只有 chat/completions，没有 web_search 工具
        XCTAssertEqual(LLMCatalog.searchStyle(provider: .openai, baseURL: "https://gw.example.com/v1"),
                       .unsupported)
        XCTAssertEqual(LLMCatalog.searchStyle(provider: .qwen,
                                              baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
                       .qwenEnableSearch)
        XCTAssertEqual(LLMCatalog.searchStyle(provider: .custom,
                                              baseURL: "https://openrouter.ai/api/v1"),
                       .openrouterPlugin)
        XCTAssertEqual(LLMCatalog.searchStyle(provider: .deepseek, baseURL: "https://api.deepseek.com"),
                       .unsupported)
        XCTAssertEqual(LLMCatalog.searchStyle(provider: .local, baseURL: "http://localhost:11434/v1"),
                       .unsupported)
    }

    /// 来源数量那句话：0 条也要说"已联网"（Qwen 那档不回传来源，但钱是真花了）
    func testWebSearchNote() {
        L10n.shared.language = .zh
        XCTAssertEqual(LLMCatalog.webSearchNote(citationCount: 0), "已联网")
        XCTAssertTrue(LLMCatalog.webSearchNote(citationCount: 3).contains("3"))
    }

    /// user_location 只报国家与时区——**不报城市**（时区里的城市名不等于用户所在的城市）
    func testApproximateUserLocationIsCountryAndTimeZoneOnly() {
        let location = LLMCatalog.approximateUserLocation(
            timeZone: TimeZone(identifier: "Asia/Dubai")!,
            locale: Locale(identifier: "en_AE"))
        XCTAssertEqual(location["type"], "approximate")
        XCTAssertEqual(location["timezone"], "Asia/Dubai")
        XCTAssertEqual(location["country"], "AE")
        XCTAssertNil(location["city"])
    }

    // MARK: - 新增文案的双语纪律

    /// 英文界面下新加的这些文案同样不能混进中文或全角标点
    func testNewEnglishCopyHasNoCJKOrFullWidthPunctuation() {
        L10n.shared.language = .en
        var texts = [LLMCatalog.webSearchPriceNote, LLMCatalog.fastTierPriceNote,
                     LLMCatalog.webSearchNote(citationCount: 0),
                     LLMCatalog.webSearchNote(citationCount: 2)]
        texts += LLMCatalog.QwenRegion.allCases.map(\.displayName)
        texts += LLMProvider.allCases.map(\.displayName)
        texts += LLMProvider.allCases.map(\.shortName)
        for problem: LLMCatalog.BaseURLProblem in [.empty, .malformed, .insecure, .noVersionSegment] {
            texts.append(problem.message)
        }
        let forbidden = CharacterSet(charactersIn: "：，。；？！（）、「」").union(
            CharacterSet(charactersIn: UnicodeScalar(0x4E00)!...UnicodeScalar(0x9FFF)!))
        for text in texts {
            XCTAssertNil(text.rangeOfCharacter(from: forbidden), text)
        }
    }
}
