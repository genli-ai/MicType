import XCTest
@testable import MicType

/// AI 设置页那几条纯函数：质量二选一的映射表、申请 Key 的链接、Key 验证的三态文案。
/// 这一层错了不会崩，但会**偷偷把用户手选的型号改掉**（质量档误判）、
/// 把人送到一个 404 的申请页，或者在 Key 明明没通的时候显示一句像成功的话。
final class AISetupTests: XCTestCase {

    private var savedLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    /// 英文界面里不许出现汉字、CJK 标点或全角标点（见 docs 的 C2）
    private func containsCJKOrFullWidth(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)      // CJK 标点（「」、。）
                || (0x4E00...0x9FFF).contains(scalar.value)   // 汉字
                || (0xFF00...0xFFEF).contains(scalar.value)   // 全角字符（：（））
        }
    }

    // MARK: - 质量二选一

    /// 「快」这一档必须与出厂默认逐字相同——否则干净安装一打开设置页就显示「自选」，
    /// 用户会以为自己动过什么
    func testFastTierEqualsTheShippedDefaults() {
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            let pair = LLMCatalog.models(provider: provider, tier: .fast)
            XCTAssertEqual(pair?.polish, LLMCatalog.polishDefault(for: provider), provider.rawValue)
            XCTAssertEqual(pair?.command, LLMCatalog.commandDefault(for: provider), provider.rawValue)
        }
    }

    /// 两档必须真的不一样，而且「最好」的型号要在快选清单里（下拉框里看得见当前用的那个）
    func testBestTierDiffersAndStaysInsideThePresets() {
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            guard let fast = LLMCatalog.models(provider: provider, tier: .fast),
                  let best = LLMCatalog.models(provider: provider, tier: .best) else {
                return XCTFail("no tier table for \(provider.rawValue)")
            }
            XCTAssertNotEqual(fast, best, provider.rawValue)
            let presets = LLMCatalog.presets(for: provider)
            XCTAssertTrue(presets.contains(best.polish), best.polish)
            XCTAssertTrue(presets.contains(best.command), best.command)
        }
    }

    /// OpenAI 的两档按调研结论钉死：快 = luna/terra，最好 = terra/sol
    func testOpenAITierTableIsExactlyTheResearchedPairs() {
        XCTAssertEqual(LLMCatalog.models(provider: .openai, tier: .fast),
                       LLMCatalog.ModelPair(polish: "gpt-5.6-luna", command: "gpt-5.6-terra"))
        XCTAssertEqual(LLMCatalog.models(provider: .openai, tier: .best),
                       LLMCatalog.ModelPair(polish: "gpt-5.6-terra", command: "gpt-5.6-sol"))
    }

    /// 自定义端点 / 本机模型没有内置型号：给不出两档就别硬给（界面据此把选择器藏掉）
    func testCustomAndLocalHaveNoTierTable() {
        for provider in [LLMProvider.custom, .local] {
            XCTAssertNil(LLMCatalog.models(provider: provider, tier: .fast))
            XCTAssertNil(LLMCatalog.models(provider: provider, tier: .best))
            XCTAssertNil(LLMCatalog.qualitySummary(provider: provider))
        }
    }

    func testTierDetectionRoundTripsBothWays() {
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            for tier in LLMCatalog.QualityTier.allCases {
                guard let pair = LLMCatalog.models(provider: provider, tier: tier) else {
                    return XCTFail("no tier table for \(provider.rawValue)")
                }
                XCTAssertEqual(LLMCatalog.tier(provider: provider,
                                               polish: pair.polish, command: pair.command),
                               tier, "\(provider.rawValue)/\(tier.rawValue)")
            }
        }
    }

    /// 用户自己挑过型号 → 必须如实报 nil（界面显示「自选」）。
    /// 把他钉回某一档等于下次点别处时悄悄替他改型号——铁律不许。
    func testHandPickedModelsAreReportedAsCustom() {
        XCTAssertNil(LLMCatalog.tier(provider: .openai, polish: "gpt-5.4", command: "gpt-5.6-sol"))
        XCTAssertNil(LLMCatalog.tier(provider: .openai, polish: "gpt-5.6-luna", command: "gpt-6-astra"))
        XCTAssertNil(LLMCatalog.tier(provider: .custom, polish: "kimi-k2", command: "kimi-k2"))
    }

    /// 前后空白不该把用户从「快」踢成「自选」
    func testTierDetectionIgnoresSurroundingWhitespace() {
        XCTAssertEqual(LLMCatalog.tier(provider: .openai,
                                       polish: "  gpt-5.6-luna ", command: "\ngpt-5.6-terra"),
                       .fast)
    }

    /// 说明文字必须点名真实型号（藏起来反而让人不敢点）
    func testQualitySummaryNamesTheRealModels() {
        L10n.shared.language = .zh
        let zh = LLMCatalog.qualitySummary(provider: .openai) ?? ""
        XCTAssertTrue(zh.contains("gpt-5.6-luna") && zh.contains("gpt-5.6-sol"), zh)
        L10n.shared.language = .en
        let en = LLMCatalog.qualitySummary(provider: .openai) ?? ""
        XCTAssertTrue(en.contains("gpt-5.6-terra"), en)
        XCTAssertFalse(containsCJKOrFullWidth(en), en)
    }

    // MARK: - 型号存在哪两个键上 / 质量档写回什么

    /// 五档服务商各有独立的两个键，十个键必须互不相同：
    /// 撞一个的后果是换服务商时把另一档的型号改掉（用户完全看不出为什么突然 404）
    func testModelKeysAreDistinctAcrossEveryProvider() {
        var seen = Set<String>()
        for provider in LLMProvider.allCases {
            let keys = LLMCatalog.modelKeys(for: provider)
            XCTAssertFalse(keys.polish.isEmpty)
            XCTAssertFalse(keys.command.isEmpty)
            XCTAssertNotEqual(keys.polish, keys.command, provider.rawValue)
            XCTAssertTrue(seen.insert(keys.polish).inserted, keys.polish)
            XCTAssertTrue(seen.insert(keys.command).inserted, keys.command)
        }
        XCTAssertEqual(seen.count, LLMProvider.allCases.count * 2)
    }

    /// 键名要与老版本用的那几个逐字相同：改一个字就是把老用户的型号设置清空
    func testModelKeysMatchTheShippedSettingsKeys() {
        XCTAssertEqual(LLMCatalog.modelKeys(for: .openai).polish, SettingsKeys.chatModel)
        XCTAssertEqual(LLMCatalog.modelKeys(for: .openai).command, SettingsKeys.openaiCommandModel)
        XCTAssertEqual(LLMCatalog.modelKeys(for: .deepseek).polish, SettingsKeys.deepseekModel)
        XCTAssertEqual(LLMCatalog.modelKeys(for: .local).command, SettingsKeys.localCommandModel)
    }

    /// 选一档质量 = 同时写两个字段，值必须与那一档的型号表逐字相同
    func testQualityWritesBothModelFieldsForEveryTier() {
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            for tier in LLMCatalog.QualityTier.allCases {
                let writes = LLMCatalog.qualityWrites(provider: provider, tier: tier)
                guard let pair = LLMCatalog.models(provider: provider, tier: tier) else {
                    return XCTFail("no tier table for \(provider.rawValue)")
                }
                let keys = LLMCatalog.modelKeys(for: provider)
                XCTAssertEqual(writes.count, 2, provider.rawValue)
                XCTAssertEqual(writes[keys.polish], pair.polish)
                XCTAssertEqual(writes[keys.command], pair.command)
            }
        }
    }

    /// 写回之后必须落回同一档（否则界面会立刻显示「自选」，像刚点的那一下没生效）
    func testQualityWritesRoundTripBackToTheSameTier() {
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            for tier in LLMCatalog.QualityTier.allCases {
                let writes = LLMCatalog.qualityWrites(provider: provider, tier: tier)
                let keys = LLMCatalog.modelKeys(for: provider)
                XCTAssertEqual(LLMCatalog.tier(provider: provider,
                                               polish: writes[keys.polish] ?? "",
                                               command: writes[keys.command] ?? ""),
                               tier, "\(provider.rawValue)/\(tier.rawValue)")
            }
        }
    }

    /// 没有内置型号的两档一个字节都不写：写一个猜出来的型号名进去就是替用户做主
    func testQualityWritesNothingWithoutABuiltInTierTable() {
        for provider in [LLMProvider.custom, .local] {
            for tier in LLMCatalog.QualityTier.allCases {
                XCTAssertTrue(LLMCatalog.qualityWrites(provider: provider, tier: tier).isEmpty,
                              provider.rawValue)
            }
        }
    }

    // MARK: - AI 配齐了没有

    /// 三样齐了才算就绪（引导最后一屏据此二选一）
    func testAIReadyNeedsCredentialEndpointAndModel() {
        XCTAssertTrue(LLMCatalog.aiReady(hasCredential: true,
                                         baseURL: "https://api.openai.com/v1",
                                         polishModel: "gpt-5.6-luna"))
        XCTAssertFalse(LLMCatalog.aiReady(hasCredential: false,
                                          baseURL: "https://api.openai.com/v1",
                                          polishModel: "gpt-5.6-luna"))
    }

    /// Qwen 区域端点缺 WorkspaceId 时地址是空串——那不是"就绪"，是根本拼不出地址
    func testAIReadyIsFalseWhenTheEndpointCannotBeDerived() {
        XCTAssertFalse(LLMCatalog.aiReady(hasCredential: true,
                                          baseURL: LLMCatalog.qwenBaseURL(region: .beijing, workspaceID: ""),
                                          polishModel: "qwen3.8-flash"))
    }

    /// 自定义端点 / 本机模型没填型号名同样不算就绪（空型号发出去是 400）
    func testAIReadyIsFalseWithoutAPolishModel() {
        XCTAssertFalse(LLMCatalog.aiReady(hasCredential: true,
                                          baseURL: "http://localhost:11434/v1",
                                          polishModel: "   "))
        XCTAssertTrue(LLMCatalog.aiReady(hasCredential: true,
                                         baseURL: "http://localhost:11434/v1",
                                         polishModel: "llama3.1:8b"))
    }

    // MARK: - 去申请 Key

    /// 只给确定的地址；猜不出来的一律 nil（宁可不给按钮，也不塞一个点进去 404 的链接）
    func testAPIKeyConsoleLinksOnlyExistWhereWeAreSure() {
        XCTAssertEqual(LLMCatalog.apiKeyConsoleURL(for: .openai), "https://platform.openai.com/api-keys")
        XCTAssertEqual(LLMCatalog.apiKeyConsoleURL(for: .deepseek), "https://platform.deepseek.com")
        for provider in [LLMProvider.qwen, .custom, .local] {
            XCTAssertNil(LLMCatalog.apiKeyConsoleURL(for: provider), provider.rawValue)
        }
    }

    /// 申请页一律 https：设置页会把它直接交给 NSWorkspace 打开
    func testAPIKeyConsoleLinksAreHTTPS() {
        for provider in LLMProvider.allCases {
            guard let url = LLMCatalog.apiKeyConsoleURL(for: provider) else { continue }
            XCTAssertTrue(url.hasPrefix("https://"), url)
        }
    }

    // MARK: - Key 验证三态

    func testVerifierStatusTextCoversTheThreeStates() {
        L10n.shared.language = .zh
        XCTAssertNil(KeyVerifier.statusText(.idle))
        XCTAssertEqual(KeyVerifier.statusText(.verifying), "正在验证…")
        XCTAssertEqual(KeyVerifier.statusText(.connected(provider: "OpenAI", model: "gpt-5.6-luna")),
                       "已连通 ✓ OpenAI · gpt-5.6-luna")
        let failed = KeyVerifier.statusText(.failed(reason: "API Key 无效或已失效 (401)", keptPrevious: false))
        XCTAssertEqual(failed, "连不上：API Key 无效或已失效 (401)")
    }

    /// 失败时不动钥匙串：屏幕上必须说清"还在用上一把"，否则输入框里的字和真正生效的 Key 对不上
    func testFailedStatusSaysWhenThePreviousKeyIsStillInUse() {
        L10n.shared.language = .zh
        let text = KeyVerifier.statusText(.failed(reason: "404", keptPrevious: true)) ?? ""
        XCTAssertTrue(text.contains("没有被覆盖"), text)
    }

    func testVerifierStatusTextHasNoCJKOnTheEnglishSide() {
        L10n.shared.language = .en
        let states: [KeyVerifier.Status] = [
            .verifying,
            .connected(provider: "OpenAI", model: "gpt-5.6-luna"),
            .failed(reason: "Invalid or revoked API key (401)", keptPrevious: true),
            .failed(reason: "Invalid or revoked API key (401)", keptPrevious: false),
            .cleared,
        ]
        for state in states {
            let text = KeyVerifier.statusText(state) ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(containsCJKOrFullWidth(text), text)
        }
    }

    /// Key 与费用那两句在两处界面逐字复用，英文侧同样不许有中文标点
    func testFixedKeyAndBillingCopyIsCleanInEnglish() {
        L10n.shared.language = .en
        for copy in [LLMCatalog.keyStorageNote, LLMCatalog.billingNote, LLMCatalog.newAccountNote] {
            XCTAssertFalse(containsCJKOrFullWidth(copy), copy)
        }
    }

    // MARK: - 服务商分段名

    /// 分段选择器里每一档都要有名字，而且英文界面下不含中文
    func testSegmentNamesAreDistinctAndCleanInEnglish() {
        L10n.shared.language = .en
        let names = LLMProvider.allCases.map(\.segmentName)
        XCTAssertEqual(Set(names).count, names.count, names.joined(separator: ","))
        for name in names {
            XCTAssertFalse(name.isEmpty)
            XCTAssertFalse(containsCJKOrFullWidth(name), name)
        }
    }
}
