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
        XCTAssertTrue(LLMCatalog.openaiPresets.contains(LLMCatalog.defaultModel(for: .openai)))
        XCTAssertTrue(LLMCatalog.deepseekPresets.contains(LLMCatalog.defaultModel(for: .deepseek)))
        XCTAssertTrue(LLMCatalog.qwenPresets.contains(LLMCatalog.defaultModel(for: .qwen)))
    }

    /// 默认一律是这家最好的主流型号（用户 2026-09-19 拍板）。
    /// 4.0.0 是"润色用最便宜的、指令贵一档"——省下来的钱是真的，代价是默认体验由最弱的
    /// 那个模型代表，而绝大多数人从不改默认值。想省钱的人在「模型」下拉里选得到。
    func testDefaultsAreTheStrongestMainstreamModel() {
        XCTAssertEqual(LLMCatalog.polishDefault(for: .openai), "gpt-5.6-sol")
        XCTAssertEqual(LLMCatalog.commandDefault(for: .openai), "gpt-5.6-sol")
        XCTAssertEqual(LLMCatalog.polishDefault(for: .deepseek), "deepseek-v4-pro")
        XCTAssertEqual(LLMCatalog.commandDefault(for: .deepseek), "deepseek-v4-pro")
        XCTAssertEqual(LLMCatalog.polishDefault(for: .qwen), "qwen3.8-max")
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
                         dsPolish: String? = LLMCatalog.defaultModel(for: .deepseek),
                         dsCommand: String? = LLMCatalog.defaultModel(for: .deepseek)) -> [String: String] {
        LLMCatalog.migrationTo56(current: [
            SettingsKeys.chatModel: polish,
            SettingsKeys.openaiCommandModel: command,
            SettingsKeys.deepseekModel: dsPolish,
            SettingsKeys.deepseekCommandModel: dsCommand,
        ])
    }

    /// 历史上由 MicType 自己写进去的那几个润色默认值，全部搬到当前的默认型号
    func testAutomaticPolishDefaultsMoveToTheCurrentDefault() {
        for old in [nil, "gpt-4o-mini", "gpt-5.4-nano", "gpt-5.5"] {
            let writes = migrate(polish: old, command: "gpt-5.4-mini")
            XCTAssertEqual(writes[SettingsKeys.chatModel], "gpt-5.6-sol", old ?? "nil")
        }
    }

    /// 铁律：用户手选过的型号一个都不动——哪怕它更贵、更旧
    func testHandPickedModelsAreNeverTouched() {
        let writes = migrate(polish: "gpt-5.4", command: "gpt-5.5")
        XCTAssertNil(writes[SettingsKeys.chatModel])
        XCTAssertNil(writes[SettingsKeys.openaiCommandModel])
    }

    func testAutomaticCommandDefaultMovesToTheCurrentDefault() {
        XCTAssertEqual(migrate(polish: "gpt-5.5", command: nil)[SettingsKeys.openaiCommandModel],
                       "gpt-5.6-sol")
        XCTAssertEqual(migrate(polish: "gpt-5.5", command: "gpt-5.4-mini")[SettingsKeys.openaiCommandModel],
                       "gpt-5.6-sol")
    }

    /// DeepSeek 那三个型号已经不存在了：不改名的话每次调用都失败——所以无论是不是手选的都得改。
    /// 改成的是**最接近的活型号**（不是我们推荐的那个）：这一步只负责"别让它 404"。
    func testDeadDeepSeekModelsAreRenamed() {
        let writes = migrate(polish: "gpt-5.6-sol", command: "gpt-5.6-sol",
                             dsPolish: "deepseek-v4-flash", dsCommand: "deepseek-reasoner")
        XCTAssertEqual(writes[SettingsKeys.deepseekModel], "deepseek-flash")
        XCTAssertEqual(writes[SettingsKeys.deepseekCommandModel], "deepseek-v4-pro")

        let chat = migrate(polish: "gpt-5.6-sol", command: "gpt-5.6-sol",
                           dsPolish: "deepseek-chat", dsCommand: "deepseek-v4-pro")
        XCTAssertEqual(chat[SettingsKeys.deepseekModel], "deepseek-flash")
        XCTAssertNil(chat[SettingsKeys.deepseekCommandModel])
    }

    /// 没存过 DeepSeek 型号的人直接拿到新默认
    func testUnsetDeepSeekModelsGetTheNewDefaults() {
        let writes = migrate(polish: "gpt-5.6-sol", command: "gpt-5.6-sol",
                             dsPolish: nil, dsCommand: nil)
        XCTAssertEqual(writes[SettingsKeys.deepseekModel], "deepseek-v4-pro")
        XCTAssertEqual(writes[SettingsKeys.deepseekCommandModel], "deepseek-v4-pro")
    }

    /// 已经在新型号上 → 一个键都不写（迁移幂等，跑第二遍不该有任何动作）
    func testMigrationIsANoOpOnCurrentValues() {
        let writes = migrate(polish: "gpt-5.6-sol", command: "gpt-5.6-sol")
        XCTAssertTrue(writes.isEmpty, "\(writes)")
    }

    /// 空字符串等同于"没存过"（钥匙串/备份导入留下的空值不该被当成手选型号）
    func testEmptyStringCountsAsUnset() {
        XCTAssertEqual(migrate(polish: "   ", command: "")[SettingsKeys.chatModel], "gpt-5.6-sol")
        XCTAssertEqual(migrate(polish: "   ", command: "")[SettingsKeys.openaiCommandModel],
                       "gpt-5.6-sol")
    }

    // MARK: - 迁移到「默认用最好的型号」（4.0.1）

    /// 没点名的那几档一律喂"已经在新默认上"的值，好让断言只看被测的那一档：
    /// 迁移本身是三档一起判的（没存过 = 出厂默认 = 要搬），不这么喂就会收到别档的写入
    private func bestDefault(_ pairs: [LLMProvider: (String?, String?)]) -> [String: String] {
        var current: [String: String?] = [:]
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            let keys = LLMCatalog.modelKeys(for: provider)
            let settled = LLMCatalog.defaultModel(for: provider)
            let value = pairs[provider] ?? (settled, settled)
            current.updateValue(value.0, forKey: keys.polish)
            current.updateValue(value.1, forKey: keys.command)
        }
        return LLMCatalog.migrationToBestDefault(current: current)
    }

    /// 还停在 4.0.0 那几对自动默认上的用户（润色便宜一档 + 指令贵一档）整体抬到新默认
    func testFourZeroAutoPairsMoveToTheBestDefault() {
        let openai = bestDefault([.openai: ("gpt-5.6-luna", "gpt-5.6-terra")])
        XCTAssertEqual(openai[SettingsKeys.chatModel], "gpt-5.6-sol")
        XCTAssertEqual(openai[SettingsKeys.openaiCommandModel], "gpt-5.6-sol")

        let deepseek = bestDefault([.deepseek: ("deepseek-flash", "deepseek-v4-pro")])
        XCTAssertEqual(deepseek[SettingsKeys.deepseekModel], "deepseek-v4-pro")
        // 指令那一边本来就是 v4-pro：值没变就不该写（迁移只写真正要改的键）
        XCTAssertNil(deepseek[SettingsKeys.deepseekCommandModel])

        let qwen = bestDefault([.qwen: ("qwen3.8-flash", "qwen3.8-max")])
        XCTAssertEqual(qwen[SettingsKeys.qwenModel], "qwen3.8-max")
        XCTAssertNil(qwen[SettingsKeys.qwenCommandModel])
    }

    /// 没存过 = 出厂默认，和"停在自动默认上"是同一件事
    func testUnsetModelsAlsoMoveToTheBestDefault() {
        let writes = bestDefault([.openai: (nil, nil), .qwen: (nil, nil)])
        XCTAssertEqual(writes[SettingsKeys.chatModel], "gpt-5.6-sol")
        XCTAssertEqual(writes[SettingsKeys.openaiCommandModel], "gpt-5.6-sol")
        XCTAssertEqual(writes[SettingsKeys.qwenModel], "qwen3.8-max")
    }

    /// 铁律：手选过的一个都不动。**只要有一边对不上那对自动默认**，就说明用户动过手，
    /// 整档一个字节都不碰——哪怕另一边看着像我们写进去的
    func testHandPickedModelsAreNeverTouchedByTheBestDefaultMigration() {
        XCTAssertTrue(bestDefault([.openai: ("gpt-5.6-luna", "gpt-6-astra")]).isEmpty)
        XCTAssertTrue(bestDefault([.openai: ("gpt-4.1", "gpt-5.6-terra")]).isEmpty)
        XCTAssertTrue(bestDefault([.deepseek: ("deepseek-v4-pro", "deepseek-flash")]).isEmpty)
        XCTAssertTrue(bestDefault([.qwen: ("qwen-max", "qwen-max")]).isEmpty)
    }

    /// 已经在新默认上 → 一个键都不写（幂等，跑第二遍不该有任何动作）
    func testBestDefaultMigrationIsANoOpOnCurrentValues() {
        let writes = bestDefault([.openai: ("gpt-5.6-sol", "gpt-5.6-sol"),
                                  .deepseek: ("deepseek-v4-pro", "deepseek-v4-pro"),
                                  .qwen: ("qwen3.8-max", "qwen3.8-max")])
        XCTAssertTrue(writes.isEmpty, "\(writes)")
    }

    /// 两次迁移串起来跑：3.x 的老值先被 migrationTo56 搬到新默认，
    /// 第二步就该无事可做（否则会把刚写好的值再改一遍）
    func testTheTwoMigrationsComposeWithoutFighting() {
        let first = LLMCatalog.migrationTo56(current: [
            SettingsKeys.chatModel: "gpt-5.5",
            SettingsKeys.openaiCommandModel: "gpt-5.4-mini",
            SettingsKeys.deepseekModel: nil,
            SettingsKeys.deepseekCommandModel: nil,
        ])
        let second = bestDefault([.openai: (first[SettingsKeys.chatModel],
                                            first[SettingsKeys.openaiCommandModel]),
                                  .deepseek: (first[SettingsKeys.deepseekModel],
                                              first[SettingsKeys.deepseekCommandModel])])
        XCTAssertTrue(second.isEmpty, "\(second)")
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
        XCTAssertTrue(LLMCatalog.qwenPresets.contains(LLMCatalog.polishDefault(for: .qwen)))
        XCTAssertTrue(LLMCatalog.qwenPresets.contains(LLMCatalog.commandDefault(for: .qwen)))
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
        XCTAssertTrue(LLMCatalog.isLocalHost("http://[::1]:1234/v1"))
        XCTAssertFalse(LLMCatalog.isLocalHost("https://api.openai.com/v1"))
        XCTAssertFalse(LLMCatalog.isLocalHost(""))
        // `.local` 是 mDNS 名字，指向的是**局域网里别人的机器**，不是这台 Mac。
        // 当成"本机"的代价：校验不再提示明文，credential() 还会免掉 API Key 要求
        XCTAssertFalse(LLMCatalog.isLocalHost("http://studio.local:11434/v1"))
        XCTAssertFalse(LLMCatalog.isLocalHost("http://192.168.1.5:11434/v1"))
    }

    /// 明文发往非回环主机 = Key 和听写文本在局域网里裸奔。这道闸在 LLMClient 里真会拦请求，
    /// 不是设置页那行橙字（那行只是提示，拦不住已经存进设置里的地址）。
    func testCleartextToRemoteHostIsFlagged() {
        XCTAssertTrue(LLMCatalog.isCleartextToRemoteHost("http://studio.local:11434/v1"))
        XCTAssertTrue(LLMCatalog.isCleartextToRemoteHost("http://192.168.1.5:11434/v1"))
        XCTAssertTrue(LLMCatalog.isCleartextToRemoteHost("  http://api.example.com/v1  "))
        // 回环明文是唯一放行的情况（Ollama / LM Studio 就是这么跑的）
        XCTAssertFalse(LLMCatalog.isCleartextToRemoteHost("http://localhost:11434/v1"))
        XCTAssertFalse(LLMCatalog.isCleartextToRemoteHost("http://127.0.0.1:1234/v1"))
        // https 一律放行；空串/不是 URL 交给别的闸门报错，不在这里拦
        XCTAssertFalse(LLMCatalog.isCleartextToRemoteHost("https://api.openai.com/v1"))
        XCTAssertFalse(LLMCatalog.isCleartextToRemoteHost(""))
        // 两档本机运行时的预设地址必须过闸（否则本机模型整档不能用）
        for runtime in LLMCatalog.LocalRuntime.allCases {
            XCTAssertFalse(LLMCatalog.isCleartextToRemoteHost(runtime.baseURL), runtime.rawValue)
        }
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

    // MARK: - service_tier 回显

    /// 「上一次请求实际跑在：…」那一行的两条判据。
    /// 关键是别把真跑在优先档上的那一次染成橙色告警：OpenAI 回 "fast"，
    /// 其它兼容端点习惯叫 "priority"，两个都算数
    func testServedPriorityTierAcceptsBothSpellings() {
        XCTAssertTrue(LLMCatalog.servedPriorityTier("fast"))
        XCTAssertTrue(LLMCatalog.servedPriorityTier(" Priority "))
        XCTAssertFalse(LLMCatalog.servedPriorityTier("default"))
        XCTAssertFalse(LLMCatalog.servedPriorityTier(""))
    }

    /// 认得的档位翻成人话，不认得的**原样显示**（硬翻是在编）
    func testServiceTierNameTranslatesKnownTiersOnly() {
        L10n.shared.language = .en
        XCTAssertEqual(LLMCatalog.serviceTierName("default"), "the standard tier")
        XCTAssertEqual(LLMCatalog.serviceTierName("fast"), "the priority tier")
        XCTAssertEqual(LLMCatalog.serviceTierName("scale"), "scale")
        L10n.shared.language = .zh
        XCTAssertEqual(LLMCatalog.serviceTierName("default"), "普通档")
        XCTAssertEqual(LLMCatalog.serviceTierName("scale"), "scale")
    }

    // MARK: - 新增文案的双语纪律

    /// 英文界面下新加的这些文案同样不能混进中文或全角标点
    func testNewEnglishCopyHasNoCJKOrFullWidthPunctuation() {
        L10n.shared.language = .en
        var texts = [LLMCatalog.webSearchPriceNote, LLMCatalog.fastTierPriceNote,
                     LLMCatalog.webSearchNote(citationCount: 0),
                     LLMCatalog.webSearchNote(citationCount: 2),
                     LLMCatalog.serviceTierName("default"),
                     LLMCatalog.serviceTierName("fast"),
                     LLMCatalog.serviceTierName("flex")]
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
