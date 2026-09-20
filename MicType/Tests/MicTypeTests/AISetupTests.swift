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

    /// 粘贴即验证必须把候选 Key 发到**用户刚选中**的那一档去，所以地址得按档取。
    /// 以前整条链路只认"当前生效那档"：引导第 5 屏选了 DeepSeek、生效档还是 OpenAI 时，
    /// 粘进去的 DeepSeek Key 会被发到 api.openai.com，401 之后 Key 存不进钥匙串，
    /// 那一档就永远采纳不了——粘一次泄一次，还是个死循环。
    func testBaseURLIsResolvedPerProviderNotFromTheActiveOne() {
        let s = Settings.shared
        XCTAssertEqual(s.baseURL(for: .openai), s.openaiBaseURL)
        XCTAssertEqual(s.baseURL(for: .deepseek), s.deepseekBaseURL)
        XCTAssertEqual(s.baseURL(for: .qwen), s.qwenBaseURL)
        XCTAssertEqual(s.baseURL(for: .custom), s.customBaseURL)
        XCTAssertEqual(s.baseURL(for: .local), s.localRuntime.baseURL)
        // "当前档"只是"按档取"的一个特例，不再是唯一的取法
        XCTAssertEqual(s.currentBaseURL, s.baseURL(for: s.llmProvider))
    }

    /// 英文界面里不许出现汉字、CJK 标点或全角标点（见 docs 的 C2）
    private func containsCJKOrFullWidth(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)      // CJK 标点（「」、。）
                || (0x4E00...0x9FFF).contains(scalar.value)   // 汉字
                || (0xFF00...0xFFEF).contains(scalar.value)   // 全角字符（：（））
        }
    }

    // MARK: - 模型选单（4.0.1 起界面上唯一的型号决定）

    /// 每家的默认型号必须是**选单里的一项**，否则干净安装一打开设置页，
    /// 下拉就停在「自定义…」上——用户会以为自己动过什么
    func testDefaultModelIsInsideTheMenu() {
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            let menu = LLMCatalog.modelMenu(for: provider)
            XCTAssertTrue(menu.contains { $0.id == LLMCatalog.defaultModel(for: provider) },
                          provider.rawValue)
        }
    }

    /// 铁律（用户 2026-09-19 拍板）：默认永远是这家最好的主流型号，**绝不是便宜的那一档**。
    /// 这三个名字写死在这里——改默认值必须先改这条测试，也就必须先过一遍脑子。
    func testDefaultsAreTheStrongestMainstreamModels() {
        XCTAssertEqual(LLMCatalog.defaultModel(for: .openai), "gpt-5.6-sol")
        XCTAssertEqual(LLMCatalog.defaultModel(for: .deepseek), "deepseek-v4-pro")
        XCTAssertEqual(LLMCatalog.defaultModel(for: .qwen), "qwen3.8-max")
    }

    /// 润色与指令共用同一个默认值：4.0.0 的"润色便宜、指令贵"已经收掉了
    func testPolishAndCommandShareOneDefault() {
        for provider in LLMProvider.allCases {
            XCTAssertEqual(LLMCatalog.polishDefault(for: provider),
                           LLMCatalog.commandDefault(for: provider), provider.rawValue)
        }
    }

    /// 选单里的型号必须互不重复，而且每一项都能在「高级」的快选清单里找到
    /// （下拉里选中的那个，在高级区必须看得见）
    func testMenuModelsAreDistinctAndPresent() {
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            let ids = LLMCatalog.modelMenu(for: provider).map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, provider.rawValue)
            for id in ids {
                XCTAssertTrue(LLMCatalog.presets(for: provider).contains(id), id)
            }
        }
    }

    /// 其他兼容服务 / 本机模型没有内置型号：给不出选单就别硬给（界面据此把下拉藏掉，
    /// 改在「高级」里给一个型号名输入框）
    func testCustomAndLocalHaveNoModelMenu() {
        for provider in [LLMProvider.custom, .local] {
            XCTAssertTrue(LLMCatalog.modelMenu(for: provider).isEmpty, provider.rawValue)
            XCTAssertTrue(LLMCatalog.defaultModel(for: provider).isEmpty, provider.rawValue)
        }
    }

    /// 下拉每一行都要先写型号名（那才是真正发出去的东西），标签只是跟在后面的大白话
    func testMenuLabelLeadsWithTheModelID() {
        L10n.shared.language = .zh
        let flagship = LLMCatalog.modelMenu(for: .openai).first { $0.id == "gpt-5.6-sol" }
        XCTAssertNotNil(flagship)
        XCTAssertTrue(LLMCatalog.modelLabel(flagship!).hasPrefix("gpt-5.6-sol"),
                      LLMCatalog.modelLabel(flagship!))
        // 没有标签的那一项就只显示型号名，不留一个孤零零的分隔点
        XCTAssertEqual(LLMCatalog.modelLabel(LLMCatalog.ModelChoice(id: "qwen3.7-plus", note: "")),
                       "qwen3.7-plus")
    }

    /// 下拉下面那一行只说**这一个选择管到哪儿**（4.1.1：润色和指令永远同一个型号）。
    /// 两件事必须拦住：① 不许再指路"分开设在高级"——那条路已经没有了；
    /// ② 不许在这里重复型号名——下拉自己写着它，重复一遍就是同一个事实写两处。
    func testModelCaptionSaysItCoversPolishAndCommands() {
        L10n.shared.language = .zh
        let zh = SettingsCopy.modelUsedForBoth
        XCTAssertTrue(zh.contains("润色") && zh.contains("指令"), zh)
        XCTAssertFalse(zh.contains("高级"), zh)
        XCTAssertFalse(zh.contains("gpt"), zh)
        L10n.shared.language = .en
        let en = SettingsCopy.modelUsedForBoth.lowercased()
        XCTAssertTrue(en.contains("polish") && en.contains("commands"), en)
        XCTAssertFalse(en.contains("advanced"), en)
        XCTAssertFalse(containsCJKOrFullWidth(SettingsCopy.modelUsedForBoth),
                       SettingsCopy.modelUsedForBoth)
    }

    /// 4.1.1 的一次性迁移：把「指令型号」拉回「润色型号」。
    /// 界面上分开设的入口已经没有了，留着两个不一样的值就是一条**改不动的设置**——
    /// 下拉显示「自定义…」，而按住说指令跑的是另一个型号、按另一个价钱计费。
    func testUnifyModelWritesPullsTheCommandModelBackToThePolishOne() {
        let openai = LLMCatalog.modelKeys(for: .openai)
        let writes = LLMCatalog.unifyModelWrites(current: [
            openai.polish: "gpt-5.6-luna", openai.command: "gpt-6-astra",
        ])
        XCTAssertEqual(writes, [openai.command: "gpt-5.6-luna"])
    }

    /// 本来就一样、或者压根没存过润色型号：一个字节都不写
    func testUnifyModelWritesLeavesMatchingOrUnsetPairsAlone() {
        let qwen = LLMCatalog.modelKeys(for: .qwen)
        XCTAssertTrue(LLMCatalog.unifyModelWrites(current: [
            qwen.polish: "qwen3.8-max", qwen.command: "qwen3.8-max",
        ]).isEmpty)
        // 官方三档没存过润色型号 = 用的是注册默认值（一个非空型号），不是"空着"：
        // 拿指令型号去顶掉那个默认值才是替用户做主
        XCTAssertTrue(LLMCatalog.unifyModelWrites(current: [
            qwen.polish: nil, qwen.command: "qwen3.8-flash",
        ]).isEmpty)
    }

    /// 自定义端点 / 本机模型出厂就是空串：4.0.x 只在「高级」里填过**指令**型号的人，
    /// 迁移后会剩下一条看不见的设置——界面写着"型号名未填"、润色回落识别原文，
    /// 按住说指令却真的在跑另一个型号。反过来把润色型号补成它。
    func testUnifyModelWritesFillsAnEmptyPolishModelFromTheCommandOne() {
        for provider in [LLMProvider.local, .custom] {
            let keys = LLMCatalog.modelKeys(for: provider)
            XCTAssertEqual(LLMCatalog.unifyModelWrites(current: [
                keys.polish: "", keys.command: "llama3.1:8b",
            ]), [keys.polish: "llama3.1:8b"], provider.rawValue)
        }
        // 两个都空着：没有任何可搬的东西，一个字节都不写
        let local = LLMCatalog.modelKeys(for: .local)
        XCTAssertTrue(LLMCatalog.unifyModelWrites(current: [
            local.polish: "", local.command: "",
        ]).isEmpty)
    }

    // MARK: - 设置窗口的路由（概览 + 三个编辑页 + 关于）

    /// 五条路由，而且深链用的那三条必须还在。
    /// 写死在测试里是为了：这几个名字是 AppDelegate 的菜单项、悬浮窗的「去配置」胶囊、
    /// 模型升级横幅共同的落点，改名字之前得先过一遍这条注释。
    func testSettingsRoutesAreOverviewPlusThreeEditorsAndAbout() {
        XCTAssertEqual(SettingsRoute.allCases, [.overview, .input, .recognition, .cloud, .about])
        // 悬浮窗的「去配置」、菜单栏的「配置 AI…」、云端识别缺 Key 都落在这一条
        XCTAssertEqual(SettingsRoute.cloud.rawValue, "cloud")
        // 模型升级横幅落在这一条
        XCTAssertEqual(SettingsRoute.recognition.rawValue, "recognition")
    }

    /// 概览是首页，没有返回；其余四页都必须有自己的标题——顶栏上那颗「‹ 设置」旁边
    /// 空着一块，等于告诉用户"你现在不知道自己在哪"
    func testOnlyTheOverviewHasNoEditorTitle() {
        XCTAssertNil(SettingsRoute.overview.editorTitle)
        for route in SettingsRoute.allCases where route != .overview {
            XCTAssertFalse(route.editorTitle?.isEmpty ?? true, route.rawValue)
        }
    }

    /// 英文界面下选单里的标签同样不许夹中文或全角标点
    func testMenuNotesAreCleanInEnglish() {
        L10n.shared.language = .en
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            for choice in LLMCatalog.modelMenu(for: provider) {
                XCTAssertFalse(containsCJKOrFullWidth(LLMCatalog.modelLabel(choice)),
                               LLMCatalog.modelLabel(choice))
            }
        }
    }

    // MARK: - 型号存在哪两个键上 / 选一个型号写回什么

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

    /// 在下拉里选一个型号 = **同时**写润色和指令两个字段（用户只做一个决定）
    func testSelectingAModelWritesBothFields() {
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            for choice in LLMCatalog.modelMenu(for: provider) {
                let writes = LLMCatalog.modelWrites(provider: provider, model: choice.id)
                let keys = LLMCatalog.modelKeys(for: provider)
                XCTAssertEqual(writes.count, 2, provider.rawValue)
                XCTAssertEqual(writes[keys.polish], choice.id)
                XCTAssertEqual(writes[keys.command], choice.id)
            }
        }
    }

    /// 写回之后下拉必须落回同一项（否则界面会立刻显示「自定义…」，像刚点的那一下没生效）
    func testModelWritesRoundTripBackToTheSameMenuItem() {
        for provider in [LLMProvider.openai, .deepseek, .qwen] {
            for choice in LLMCatalog.modelMenu(for: provider) {
                let writes = LLMCatalog.modelWrites(provider: provider, model: choice.id)
                let keys = LLMCatalog.modelKeys(for: provider)
                XCTAssertEqual(LLMCatalog.selectedMenuModel(provider: provider,
                                                            polish: writes[keys.polish] ?? "",
                                                            command: writes[keys.command] ?? ""),
                               choice.id, provider.rawValue)
            }
        }
    }

    /// 空型号名一个字节都不写：写一个空值进去等于把这一档弄瘫（发出去就是 400）
    func testModelWritesNothingForAnEmptyName() {
        XCTAssertTrue(LLMCatalog.modelWrites(provider: .openai, model: "   ").isEmpty)
        XCTAssertTrue(LLMCatalog.modelWrites(provider: .local, model: "").isEmpty)
        // 其他兼容服务 / 本机模型没有内置选单，但用户自己填的型号名照样要写回两个字段
        let writes = LLMCatalog.modelWrites(provider: .local, model: " llama3.1:8b ")
        XCTAssertEqual(writes[LLMCatalog.modelKeys(for: .local).polish], "llama3.1:8b")
        XCTAssertEqual(writes[LLMCatalog.modelKeys(for: .local).command], "llama3.1:8b")
    }

    /// 在「高级」里把润色和指令分开设过 → 下拉必须如实显示「自定义…」（nil），
    /// 绝不把他钉回某一项（那等于下次点别处时悄悄把他的指令模型改掉）
    func testSplitOrUnknownModelsAreReportedAsCustom() {
        XCTAssertNil(LLMCatalog.selectedMenuModel(provider: .openai,
                                                  polish: "gpt-5.6-luna", command: "gpt-5.6-sol"))
        XCTAssertNil(LLMCatalog.selectedMenuModel(provider: .openai,
                                                  polish: "gpt-4.1", command: "gpt-4.1"))
        XCTAssertNil(LLMCatalog.selectedMenuModel(provider: .openai, polish: "", command: ""))
        XCTAssertNil(LLMCatalog.selectedMenuModel(provider: .local,
                                                  polish: "llama3.1:8b", command: "llama3.1:8b"))
    }

    /// 前后空白不该把用户从某一项踢成「自定义…」
    func testSelectedMenuModelIgnoresSurroundingWhitespace() {
        XCTAssertEqual(LLMCatalog.selectedMenuModel(provider: .qwen,
                                                    polish: "  qwen3.8-max ", command: "\nqwen3.8-max"),
                       "qwen3.8-max")
    }

    // MARK: - 使用方式：一个决定落到哪几条设置上

    /// 「只用本地」= 润色关掉 + 识别回本机。少写一条就是留下一条看不见的设置
    /// （润色关了、音频还在往云端传）
    func testLocalOnlyTurnsOffPolishAndCloudRecognition() {
        let writes = AISetup.localOnlyWrites()
        XCTAssertEqual(writes.polish, .off)
        XCTAssertEqual(writes.engine, .local)
        XCTAssertEqual(AISetup.mode(polishLevel: writes.polish, engine: writes.engine), .localOnly)
    }

    /// 两个条件都满足才算「只用本地」：只看润色的话，从菜单栏关掉润色、云端识别还开着的人
    /// 会看到一页"只用本地"，而音频照传不误
    func testCloudRecognitionAloneStillCountsAsUsingAI() {
        XCTAssertEqual(AISetup.mode(polishLevel: .off, engine: .cloudAlibaba), .withAI)
        XCTAssertEqual(AISetup.mode(polishLevel: .smart, engine: .local), .withAI)
        XCTAssertEqual(AISetup.mode(polishLevel: .off, engine: .local), .localOnly)
    }

    /// 打开 AI 时润色要回到自适应档；本来就开着的话一个字都别动
    func testEnablingAITurnsPolishBackOnWithoutOverridingIt() {
        XCTAssertEqual(AISetup.polishAfterEnablingAI(.off), .smart)
        XCTAssertEqual(AISetup.polishAfterEnablingAI(.smart), .smart)
    }

    /// 云端识别只有阿里云这一档，而且只有开关打开时才是云端
    func testCloudRecognitionOnlyExistsUnderAlibaba() {
        XCTAssertEqual(AISetup.engine(provider: .qwen, cloudRecognition: true), .cloudAlibaba)
        XCTAssertEqual(AISetup.engine(provider: .qwen, cloudRecognition: false), .local)
    }

    /// **换走服务商就必须回本机**：不然用户换到 OpenAI 之后，音频还在往阿里云传，
    /// 而界面上已经没有那个开关可以关了
    func testSwitchingProviderAwayFromAlibabaGoesBackToLocal() {
        for provider in [LLMProvider.openai, .deepseek, .custom, .local] {
            XCTAssertEqual(AISetup.engine(provider: provider, cloudRecognition: true), .local,
                           provider.rawValue)
        }
    }

    /// 4.0.0 的「云端 · OpenAI」识别：界面上没有这一档了，但设置里可能还存着 —— 必须当面说
    func testLegacyOpenAICloudRecognitionIsSurfaced() {
        XCTAssertTrue(AISetup.showsLegacyOpenAICloudNotice(engine: .cloudOpenAI))
        XCTAssertFalse(AISetup.showsLegacyOpenAICloudNotice(engine: .cloudAlibaba))
        XCTAssertFalse(AISetup.showsLegacyOpenAICloudNotice(engine: .local))
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

    /// 地址是空串（自定义端点还没填）——那不是"就绪"，是根本拼不出地址。
    /// Qwen 已经不会落到这一档了：它的接入地址由 MicType 自己试出来（见 AlibabaEndpoint），
    /// 但这条判据仍然守着自定义端点那一路。
    func testAIReadyIsFalseWhenTheEndpointCannotBeDerived() {
        XCTAssertFalse(LLMCatalog.aiReady(hasCredential: true, baseURL: "",
                                          polishModel: "qwen3.8-flash"))
        XCTAssertFalse(LLMCatalog.qwenBaseURL(region: .international, workspaceID: "").isEmpty,
                       "国际站共享主机永远拼得出来")
    }

    /// 接入地址一旦试通，润色与云端识别必须落在**同一台主机**上：
    /// 4.0.0 让用户在两页各选一次区域，选出两个不一致的值正是那时的坑
    func testResolvedHostDrivesThePolishEndpointToo() {
        let host = "ws-e9548i71rc13pul7.cn-beijing.maas.aliyuncs.com"
        XCTAssertEqual(AlibabaEndpoint.compatibleBaseURL(host: host),
                       "https://" + host + "/compatible-mode/v1")
        XCTAssertEqual(AlibabaEndpoint.asrURL(host: host)?.host, host)
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

    /// 识别停在阿里云、服务商却不是阿里云：AI 页上那个开关这时根本不渲染，
    /// 所以音频在传、界面上却没有关掉它的控件。和 cloudOpenAI 那条同样要当面说
    func testStrandedAlibabaCloudRecognitionIsSurfaced() {
        XCTAssertTrue(AISetup.showsStrandedAlibabaCloudNotice(engine: .cloudAlibaba, provider: .openai))
        XCTAssertTrue(AISetup.showsStrandedAlibabaCloudNotice(engine: .cloudAlibaba, provider: .local))
        // 服务商就是阿里云 = 那个开关就在下面，不必多话
        XCTAssertFalse(AISetup.showsStrandedAlibabaCloudNotice(engine: .cloudAlibaba, provider: .qwen))
        XCTAssertFalse(AISetup.showsStrandedAlibabaCloudNotice(engine: .local, provider: .openai))
        XCTAssertFalse(AISetup.showsStrandedAlibabaCloudNotice(engine: .cloudOpenAI, provider: .openai))
    }

    /// 换服务商时识别引擎跟不跟着回本机——设置页与引导页共用这一条，两处不许各写一份
    func testEngineAfterProviderChange() {
        XCTAssertEqual(AISetup.engineAfterProviderChange(current: .cloudAlibaba, next: .openai), .local)
        XCTAssertEqual(AISetup.engineAfterProviderChange(current: .cloudAlibaba, next: .local), .local)
        // 还在阿里云：那个开关照常在，不动它
        XCTAssertNil(AISetup.engineAfterProviderChange(current: .cloudAlibaba, next: .qwen))
        // 本来就没在用阿里云识别：换谁都与识别无关（cloudOpenAI 由那条 legacy 提示管）
        XCTAssertNil(AISetup.engineAfterProviderChange(current: .local, next: .openai))
        XCTAssertNil(AISetup.engineAfterProviderChange(current: .cloudOpenAI, next: .openai))
    }

    // MARK: - 4.1.1：「关于我」并进「自定义规则」

    /// 合并**会改用户亲手写的文字**，搬丢了他没有第二份——所以每一支都钉住。
    /// 「关于我」排在前面：它讲"我是谁"，规则讲"怎么写"，读起来本来就是这个顺序。
    func testAboutMeIsPrependedToTheRulesOnce() {
        XCTAssertEqual(AISetup.mergedRules(aboutMe: "署名用 Gen", rules: "数字用阿拉伯数字"),
                       "署名用 Gen\n数字用阿拉伯数字")
        // 规则是空的：那段「关于我」自己就是新规则
        XCTAssertEqual(AISetup.mergedRules(aboutMe: " 署名用 Gen ", rules: "   "), "署名用 Gen")
    }

    /// 已经逐字含着那段话（用户自己抄过去了、或者迁移跑过一次）：不许再并一遍。
    /// 并两遍的表现是提示词里同一句话出现两次——模型会把它当成被强调的要求。
    func testAboutMeIsNotMergedTwice() {
        XCTAssertNil(AISetup.mergedRules(aboutMe: "署名用 Gen",
                                         rules: "署名用 Gen\n数字用阿拉伯数字"))
        // 「关于我」本来就是空的：什么都不用做
        XCTAssertNil(AISetup.mergedRules(aboutMe: "   ", rules: "数字用阿拉伯数字"))
    }

    // MARK: - 4.1.1：联网搜索默认开

    /// 没存过 = 一直用着出厂默认，跟着新默认走；存过 = 他自己拨过那个开关，一个字都不动
    /// （拨开再拨回也算——那是一次明确的"我不要"，替他点开就是替他花钱）
    func testWebSearchDefaultMigrationKeepsAnExplicitChoice() {
        XCTAssertTrue(AISetup.webSearchAfterDefaultChange(stored: nil))
        XCTAssertFalse(AISetup.webSearchAfterDefaultChange(stored: false))
        XCTAssertTrue(AISetup.webSearchAfterDefaultChange(stored: true))
    }

    /// 支持的服务商默认开、不支持的连开关都不摆：价格与"有没有这个功能"必须同源，
    /// 否则会出现"这家没有搜索"和"每次 $0.01"并排
    func testWebSearchPriceNoteExistsExactlyWhereSearchDoes() {
        for style in [LLMCatalog.WebSearchStyle.openaiResponsesTool, .qwenEnableSearch, .openrouterPlugin] {
            XCTAssertNotNil(LLMCatalog.webSearchPriceNote(style: style), "\(style)")
        }
        XCTAssertNil(LLMCatalog.webSearchPriceNote(style: .unsupported))
        XCTAssertEqual(LLMCatalog.webSearchPriceNote(style: .openaiResponsesTool),
                       LLMCatalog.webSearchPriceNote)
    }

    // MARK: - 4.1.1：验证通过才采纳（设置页与引导页同一条）

    /// 没 Key 的那一档只是**预览**：点一下就把生效服务商换过去，表现是他下次按住说指令
    /// 直接失败，而完全不知道是刚才那一下点的
    func testProviderIsAdoptedOnlyOnceItsKeyIsThere() {
        XCTAssertTrue(AISetup.adoptsProvider(current: .openai, next: .deepseek,
                                             requiresKey: true, hasKey: true,
                                             polishModel: "deepseek-v4-pro"))
        XCTAssertFalse(AISetup.adoptsProvider(current: .openai, next: .deepseek,
                                              requiresKey: true, hasKey: false,
                                              polishModel: "deepseek-v4-pro"))
        // 已经就是这一档：不必再写一遍（也就不会白记一行日志）
        XCTAssertFalse(AISetup.adoptsProvider(current: .qwen, next: .qwen,
                                              requiresKey: true, hasKey: true,
                                              polishModel: "qwen3.8-max"))
    }

    /// 本机模型那一档没有 Key 可验，但型号名是空的照样跑不起来（发出去就是 400）——
    /// 同样不能拿它换掉一个正在好好用着的服务商
    func testLocalProviderStillNeedsAModelNameToBeAdopted() {
        XCTAssertFalse(AISetup.adoptsProvider(current: .openai, next: .local,
                                              requiresKey: false, hasKey: false,
                                              polishModel: "  "))
        XCTAssertTrue(AISetup.adoptsProvider(current: .openai, next: .local,
                                             requiresKey: false, hasKey: false,
                                             polishModel: "llama3.1:8b"))
    }

    /// 「优先处理」只有 OpenAI 有这个档位：**其余档整行不渲染**，不是灰着摆在那里
    func testPriorityToggleOnlyExistsUnderOpenAI() {
        XCTAssertTrue(AISetup.showsPriorityToggle(inUse: .openai))
        for provider in [LLMProvider.deepseek, .qwen, .custom, .local] {
            XCTAssertFalse(AISetup.showsPriorityToggle(inUse: provider), provider.rawValue)
        }
    }

    /// 「只用本地」只关润色、只把识别改回本机——**钥匙串里那把 Key 一个字节都不动**，
    /// 而按住说指令并不看档位，照样会调用云端、照样计费。所以这一档里有 Key 就必须当面说
    func testLocalOnlyStillWarnsAboutAStoredKey() {
        XCTAssertTrue(AISetup.showsStoredKeyNotice(mode: .localOnly, hasCredential: true))
        XCTAssertFalse(AISetup.showsStoredKeyNotice(mode: .localOnly, hasCredential: false))
        // 「本地 + AI」这一档本来就该有 Key，没什么可提醒的
        XCTAssertFalse(AISetup.showsStoredKeyNotice(mode: .withAI, hasCredential: true))
    }
}
