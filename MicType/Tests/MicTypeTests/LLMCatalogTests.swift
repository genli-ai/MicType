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

    /// 默认一律是这家**均衡偏快**的那一档（用户 2026-09-20 拍板，推翻前一天那条"必须是旗舰"）。
    /// 润色是每句话都要跑一次的东西，它的全部价值是顺手：旗舰实测 4–12 秒、
    /// 还撞得上 12 秒的润色超时——那一次整句话就白说了（4.1.4 的日志）。
    /// 5.0.0 起这就是**唯一**的型号：界面上没有下拉（用户 2026-09-22 拍板）。
    /// 5.0.6 起 OpenAI 润色单独换 terra（iOS 144 次评测：严格保真 80% vs 64%、中位只慢 180 ms），
    /// 指令仍是 luna（terra 做指令不升质量、贵约 8 倍）。
    func testDefaultsAreTheBalancedFastTier() {
        XCTAssertEqual(LLMCatalog.polishDefault(for: .openai), "gpt-5.6-terra")
        XCTAssertEqual(LLMCatalog.commandDefault(for: .openai), "gpt-5.6-luna")
    }

    /// 每一档都有型号名：5.0.0 之前「自定义端点 / 本机模型」两档是空串（型号名只有用户
    /// 自己知道），而那正是整条链路上"看着配好了、每次调用都是空型号"的来源
    func testEveryProviderHasAModel() {
        for provider in LLMProvider.allCases {
            XCTAssertFalse(LLMCatalog.polishDefault(for: provider).isEmpty, provider.rawValue)
            XCTAssertFalse(LLMCatalog.commandDefault(for: provider).isEmpty, provider.rawValue)
        }
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

    /// 润色要最快的一档；gpt-6-astra 不支持 none，发了会 400 → 必须退到 low。
    /// 5.0.6 起只排除 astra：gpt-6-luna / gpt-6-sol 支持 none（官方文档 + iOS 实测）
    func testPolishUsesEffortNoneExceptOnAstra() {
        XCTAssertEqual(LLMCatalog.effort(purpose: .polish, model: "gpt-5.6-luna"), "none")
        XCTAssertEqual(LLMCatalog.effort(purpose: .polish, model: "gpt-5.6-terra"), "none")
        XCTAssertEqual(LLMCatalog.effort(purpose: .polish, model: "gpt-5.5"), "none")
        XCTAssertEqual(LLMCatalog.effort(purpose: .polish, model: "gpt-6-luna"), "none")
        XCTAssertEqual(LLMCatalog.effort(purpose: .polish, model: "gpt-6-sol"), "none")
        XCTAssertEqual(LLMCatalog.effort(purpose: .polish, model: "gpt-6-astra"), "low")
        XCTAssertEqual(LLMCatalog.effort(purpose: .polish, model: "GPT-6-Astra"), "low")
        XCTAssertTrue(LLMCatalog.supportsEffortNone("gpt-6-luna"))
        XCTAssertFalse(LLMCatalog.supportsEffortNone("gpt-6-astra"))
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

    // 4.x 的三组型号迁移测试（migrationTo56 / migrationToBestDefault / migrationToFastDefault）
    // 5.0.0 随那几个函数一起删掉：型号不再是一条设置，没有东西可迁。

    // MARK: - 错误话术（5.3.0：一句话 + 一颗按钮，细节进日志）

    func testInvalidKeyAndRegionAndModelErrors() {
        L10n.shared.language = .en
        let key = LLMCatalog.describeHTTPError(status: 401, provider: .openai, code: nil, message: nil)
        XCTAssertTrue(key.text.contains("401"))
        // Key 被拒只能去设置里换：按钮由这里点名，不再靠悬浮窗去文案里找「401」
        XCTAssertEqual(key.action, .openSettings)
        XCTAssertNil(key.actionURL)

        let region = LLMCatalog.describeHTTPError(status: 403, provider: .openai,
                                                 code: "unsupported_country_region_territory",
                                                 message: "Country, region, or territory not supported")
        XCTAssertTrue(region.text.contains("403"))
        XCTAssertTrue(region.text.lowercased().contains("region"), region.text)
        XCTAssertFalse(region.text.contains("Alibaba"), region.text)
        XCTAssertEqual(region.action, .dismiss)

        let model = LLMCatalog.describeHTTPError(status: 404, provider: .openai, code: nil,
                                                message: "The model `gpt-9` does not exist")
        XCTAssertTrue(model.text.contains("404"))
        // 服务商的原话**不上屏**（它进日志）：屏幕上只有一句结论
        XCTAssertFalse(model.text.contains("gpt-9"), model.text)
    }

    /// 403 不再建议"改用阿里云"（5.1.0 那一档删掉了）：指着一个不存在的选项比不说更糟
    func testForbiddenCopyDoesNotPointAtARemovedProvider() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            let openai = LLMCatalog.describeHTTPError(status: 403, provider: .openai,
                                                      code: nil, message: nil)
            XCTAssertTrue(openai.text.contains("403"))
            XCTAssertFalse(openai.text.contains("Alibaba") || openai.text.contains("阿里云"),
                           openai.text)
        }
    }

    /// 429 的两种含义必须分开说：一个该等几秒，一个该去充钱（后者带一颗「去充值」）
    func testRateLimitAndQuotaAreDifferentCopy() {
        L10n.shared.language = .en
        let limited = LLMCatalog.describeHTTPError(status: 429, provider: .openai,
                                                   code: "rate_limit_exceeded",
                                                   message: "Rate limit reached for gpt-5.6-luna")
        XCTAssertNil(limited.actionURL)
        XCTAssertEqual(limited.action, .dismiss)
        XCTAssertTrue(limited.text.lowercased().contains("rate limited"))

        let broke = LLMCatalog.describeHTTPError(status: 429, provider: .openai,
                                                 code: "insufficient_quota",
                                                 message: "You exceeded your current quota")
        XCTAssertEqual(broke.action, .addCredit)
        XCTAssertEqual(broke.actionURL, "https://platform.openai.com/settings/organization/billing")
        // 5.3.0 起充值页是一颗按钮，不再拼进句尾（16 字一句装不下一整串 URL）
        XCTAssertFalse(broke.text.contains("https://"), broke.text)
        XCTAssertEqual(OverlayErrorAction.addCredit.label, "Add credit")
    }

    /// 4.1.1 起润色与指令都只发一次（networkRetries = 0），超时那句就不许再写"已重试一次"
    func testTimeoutCopyOnlyClaimsARetryWhenOneHappened() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            let once = LLMCatalog.timeoutCopy().text.lowercased()
            XCTAssertFalse(once.contains("重试") || once.contains("retried"), once)
            let retried = LLMCatalog.timeoutCopy(retried: true).text.lowercased()
            XCTAssertTrue(retried.contains("重试") || retried.contains("retried"), retried)
        }
    }

    func testCapacityAndUnknownStatusCopy() {
        L10n.shared.language = .en
        XCTAssertTrue(LLMCatalog.describeHTTPError(status: 503, provider: .openai,
                                                   code: nil, message: nil).text.contains("503"))
        XCTAssertTrue(LLMCatalog.describeHTTPError(status: 500, provider: .openai,
                                                   code: nil, message: nil).text.contains("500"))
    }

    /// 英文界面下这几条话术里不能混进中文或全角标点（英文用户看到「：」就是 bug）
    func testEnglishCopyHasNoCJKOrFullWidthPunctuation() {
        L10n.shared.language = .en
        var texts = [LLMCatalog.timeoutCopy().text, LLMCatalog.timeoutCopy(retried: true).text]
        for status in [401, 403, 404, 429, 503, 500] {
            texts.append(LLMCatalog.describeHTTPError(status: status, provider: .openai,
                                                      code: "insufficient_quota",
                                                      message: "detail").text)
        }
        let forbidden = CharacterSet(charactersIn: "：，。；？！（）、「」").union(
            CharacterSet(charactersIn: UnicodeScalar(0x4E00)!...UnicodeScalar(0x9FFF)!))
        for text in texts {
            XCTAssertNil(text.rangeOfCharacter(from: forbidden), text)
        }
    }

    /// 中文界面下同样要是完整的中文句子
    func testChineseCopyIsChinese() {
        L10n.shared.language = .zh
        let broke = LLMCatalog.describeHTTPError(status: 429, provider: .openai,
                                                 code: "insufficient_balance", message: nil)
        XCTAssertEqual(broke.action, .addCredit)
        XCTAssertTrue(broke.text.contains("余额不足"))
        XCTAssertEqual(OverlayErrorAction.addCredit.label, "去充值")
    }

    /// 每一句都要走 UserMessage 那张集中表（它被 UserMessageCopyTests 逐条量长度）
    func testHTTPErrorsComeFromTheCentralTable() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            for status in [401, 403, 404, 429, 503, 500] {
                for code in ["insufficient_quota", "rate_limit_exceeded"] {
                    let text = LLMCatalog.describeHTTPError(status: status, provider: .openai,
                                                            code: code, message: "detail").text
                    XCTAssertTrue(UserMessage.all.contains(text) || text == UserMessage.rateLimited(status)
                                  || text == UserMessage.serverError(status)
                                  || text == UserMessage.outOfCredit(status),
                                  "不在集中表里：\(text)")
                }
            }
        }
    }

    // MARK: - 新服务商（B9）

    /// 每个服务商一条独立的钥匙串账户：撞名就会互相覆盖，用户的 Key 会莫名其妙消失
    func testKeychainAccountsAreUnique() {
        let accounts = LLMProvider.allCases.map(\.keychainAccount)
        XCTAssertEqual(Set(accounts).count, accounts.count)
    }

    /// 5.0.0 起每一档都要 Key（可以不填 Key 的「本机模型」那一档没有了）
    func testEveryProviderNeedsAnAPIKey() {
        for provider in LLMProvider.allCases {
            XCTAssertTrue(provider.requiresAPIKey, provider.rawValue)
        }
    }

    /// 5.1.0 起只剩 OpenAI 一家（用户 2026-09-28 拍板，与 iOS L36 一致）
    func testOnlyOneProvider() {
        XCTAssertEqual(LLMProvider.allCases, [.openai])
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
        // 回环地址仍然放行（导入的设置文件里可能带着一个自建网关的本机地址）
        XCTAssertFalse(LLMCatalog.isCleartextToRemoteHost("http://localhost:11434/v1"))
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

    /// 拉取失败（空数组）时清单保持原样
    func testMergedModelListFallsBackToPresets() {
        let presets = ["gpt-5.6-terra", "gpt-5.6-luna"]
        XCTAssertEqual(LLMCatalog.mergedModelList(presets: presets, fetched: []), presets)
    }

    // MARK: - 联网搜索写法（B11）

    func testSearchStylePerProvider() {
        XCTAssertEqual(LLMCatalog.searchStyle(provider: .openai, baseURL: "https://api.openai.com/v1"),
                       .openaiResponsesTool)
        // OpenAI 档指向第三方网关时只有 chat/completions，没有 web_search 工具
        XCTAssertEqual(LLMCatalog.searchStyle(provider: .openai, baseURL: "https://gw.example.com/v1"),
                       .unsupported)
        // OpenRouter 仍然认（把 OpenAI 档的 Base URL 指过去的人还在）
        XCTAssertEqual(LLMCatalog.searchStyle(provider: .openai,
                                              baseURL: "https://openrouter.ai/api/v1"),
                       .openrouterPlugin)
    }

    /// 来源数量那句话：0 条也要说"已联网"（有的端点不回传来源，但钱是真花了）
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
        texts += LLMProvider.allCases.map(\.displayName)
        for problem: LLMCatalog.BaseURLProblem in [.empty, .malformed, .insecure, .noVersionSegment] {
            texts.append(problem.message)
        }
        let forbidden = CharacterSet(charactersIn: "：，。；？！（）、「」").union(
            CharacterSet(charactersIn: UnicodeScalar(0x4E00)!...UnicodeScalar(0x9FFF)!))
        for text in texts {
            XCTAssertNil(text.rangeOfCharacter(from: forbidden), text)
        }
    }

    // 「迁移到默认用快的那一档」（4.1.4）与「默认型号被换掉了」那条提示的测试
    // 5.0.0 一起删掉：型号不再是设置，既没有可迁的值，也没有要向用户交代的改动。
}
