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

    /// 地址按档取（5.1.0 起只剩 OpenAI 一档，调用方仍然点名"发给哪一档"）
    func testBaseURLIsResolvedPerProvider() {
        let s = Settings.shared
        XCTAssertEqual(s.baseURL(for: .openai), s.openaiBaseURL)
        XCTAssertEqual(s.currentBaseURL, s.baseURL(for: s.llmProvider))
    }

    /// 5.1.0：只剩 OpenAI 一档（阿里云整档删除）。有人把它加回来之前，先要过这一条
    func testOpenAIIsTheOnlyProvider() {
        XCTAssertEqual(LLMProvider.allCases, [.openai])
        XCTAssertEqual(CloudASRProvider.allCases, [.openai])
        XCTAssertEqual(RecognitionEngineChoice.allCases, [.cloudOpenAI])
        // 存量里的 qwen 读不出一档来——它归 RetiredProviderCleanup 改写
        XCTAssertNil(LLMProvider(rawValue: "qwen"))
        XCTAssertEqual(RecognitionEngineChoice.parse("cloudAlibaba"), .cloudOpenAI)
    }

    /// 英文界面里不许出现汉字、CJK 标点或全角标点（见 docs 的 C2）
    private func containsCJKOrFullWidth(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)      // CJK 标点（「」、。）
                || (0x4E00...0x9FFF).contains(scalar.value)   // 汉字
                || (0xFF00...0xFFEF).contains(scalar.value)   // 全角字符（：（））
        }
    }

    // 「模型选单」整段 5.0.0 删掉（型号写死平衡档，界面上没有下拉了）：
    // 默认值本身由 LLMCatalogTests.testDefaultsAreTheBalancedFastTier 钉着。

    // MARK: - 设置窗口的路由（概览 + 三个编辑页 + 关于）

    /// 三条路由（5.0.0：设置就是一页，另外两页从底部那排小字点开）。
    /// 写死在测试里是为了：这几个名字是 AppDelegate 的菜单项、悬浮窗的「去配置」胶囊
    /// 共同的落点，改名字之前得先过一遍这条注释。
    func testSettingsRoutesAreOnePageAndTwoSubpages() {
        XCTAssertEqual(SettingsRoute.allCases, [.overview, .writing, .about])
        // 悬浮窗的「去配置」、菜单栏的「配置 AI…」、缺 Key 那个胶囊都落在设置正页——
        // 那一页第二行就是 API Key 输入框
        XCTAssertEqual(SettingsRoute.overview.rawValue, "overview")
        // 菜单栏的「写作偏好…」直接落到这一条
        XCTAssertEqual(SettingsRoute.writing.rawValue, "writing")
    }

    /// 概览是首页，没有返回；其余四页都必须有自己的标题——顶栏上那颗「‹ 设置」旁边
    /// 空着一块，等于告诉用户"你现在不知道自己在哪"
    func testOnlyTheOverviewHasNoEditorTitle() {
        XCTAssertNil(SettingsRoute.overview.editorTitle)
        for route in SettingsRoute.allCases where route != .overview {
            XCTAssertFalse(route.editorTitle?.isEmpty ?? true, route.rawValue)
        }
    }

    // 选单标签与「型号存在哪两个键上」整段 5.0.0 删掉：没有选单、也没有型号键了。

    // 「使用方式」整段（localOnlyWrites / mode / polishAfterEnablingAI / 云端识别开关的
    // supportsCloudRecognition / engine / cloudRecognitionMove / 那两条 stranded 提示）
    // 5.0.0 全部删掉：识别永远云端、润色永远开着，这些判断都没有第二个答案了。

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

    /// 地址是空串（被改坏的导入设置）——那不是"就绪"，是根本拼不出地址
    func testAIReadyIsFalseWhenTheEndpointCannotBeDerived() {
        XCTAssertFalse(LLMCatalog.aiReady(hasCredential: true, baseURL: "",
                                          polishModel: "gpt-5.6-terra"))
    }

    /// 型号名是空的不算就绪（空型号发出去是 400）。5.0.0 起型号写死，这一条因此恒真——
    /// 留着是因为它是 aiReady 的一部分判据，下一次真让用户填型号名时它要先红
    func testAIReadyIsFalseWithoutAPolishModel() {
        XCTAssertFalse(LLMCatalog.aiReady(hasCredential: true,
                                          baseURL: "https://api.openai.com/v1",
                                          polishModel: "   "))
        XCTAssertTrue(LLMCatalog.aiReady(hasCredential: true,
                                         baseURL: "https://api.openai.com/v1",
                                         polishModel: "gpt-5.6-luna"))
    }

    // MARK: - 去申请 Key

    /// 「去申请 Key ↗」直达 OpenAI 的 API Key 页
    func testAPIKeyConsoleLinkIsTheOpenAIKeyPage() {
        XCTAssertEqual(LLMCatalog.apiKeyConsoleURL(for: .openai), "https://platform.openai.com/api-keys")
    }

    /// 申请页一律 https：设置页会把它直接交给 NSWorkspace 打开
    func testAPIKeyConsoleLinksAreHTTPS() {
        for provider in LLMProvider.allCases {
            XCTAssertTrue(LLMCatalog.apiKeyConsoleURL(for: provider).hasPrefix("https://"))
        }
    }

    // MARK: - Key 验证三态

    func testVerifierStatusTextCoversTheThreeStates() {
        L10n.shared.language = .zh
        XCTAssertNil(KeyVerifier.statusText(.idle))
        XCTAssertEqual(KeyVerifier.statusText(.verifying), "正在验证…")
        XCTAssertEqual(KeyVerifier.statusText(.connected(provider: "OpenAI", model: "gpt-5.6-luna")),
                       "已连通 ✓ OpenAI · gpt-5.6-luna")
        // 5.3.0：原因本身就是一句结论（UserMessage），前面不再垫「连不上：」
        let failed = KeyVerifier.statusText(.failed(reason: UserMessage.keyRejected, keptPrevious: false))
        XCTAssertEqual(failed, "Key 无效或已撤销 (401)")
        XCTAssertEqual(KeyVerifier.statusText(.cleared), UserMessage.keyRemoved)
    }

    /// 失败时不动钥匙串：屏幕上必须说清"还在用上一把"，否则输入框里的字和真正生效的 Key 对不上
    func testFailedStatusSaysWhenThePreviousKeyIsStillInUse() {
        L10n.shared.language = .zh
        let text = KeyVerifier.statusText(.failed(reason: "404", keptPrevious: true)) ?? ""
        XCTAssertTrue(text.contains(UserMessage.previousKeyKept), text)
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
        for copy in [LLMCatalog.keyStorageNote, LLMCatalog.billingNote] {
            XCTAssertFalse(containsCJKOrFullWidth(copy), copy)
        }
    }

    // MARK: - 服务商短名

    /// 每一档都要有名字（验证状态行念的就是它），而且英文界面下不含中文
    func testSegmentNamesAreDistinctAndCleanInEnglish() {
        L10n.shared.language = .en
        let names = LLMProvider.allCases.map(\.segmentName)
        XCTAssertEqual(Set(names).count, names.count, names.joined(separator: ","))
        for name in names {
            XCTAssertFalse(name.isEmpty)
            XCTAssertFalse(containsCJKOrFullWidth(name), name)
        }
    }

    // 「识别停在旧档」的两条提示、cloudRecognitionMove 的三条分支、那份"这一家验过了"的
    // 内存记忆、以及"意愿由引擎推出来"的迁移，5.0.0 一起删掉：识别引擎跟着生效服务商走，
    // 这几种说不通的状态都不再可能出现。

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
        // 这个纯函数 5.0.0 起没有调用点了（联网搜索永远开、没有开关），但它记着
        // 「明确选过的人一个字都不动」这条规矩——下一次再加按次计费的开关时照抄它
        XCTAssertTrue(AISetup.webSearchAfterDefaultChange(stored: nil))
        XCTAssertFalse(AISetup.webSearchAfterDefaultChange(stored: false))
        XCTAssertTrue(AISetup.webSearchAfterDefaultChange(stored: true))
    }

    /// 支持的服务商默认开、不支持的连开关都不摆：价格与"有没有这个功能"必须同源，
    /// 否则会出现"这家没有搜索"和"每次 $0.01"并排
    func testWebSearchPriceNoteExistsExactlyWhereSearchDoes() {
        for style in [LLMCatalog.WebSearchStyle.openaiResponsesTool, .openrouterPlugin] {
            XCTAssertNotNil(LLMCatalog.webSearchPriceNote(style: style), "\(style)")
        }
        XCTAssertNil(LLMCatalog.webSearchPriceNote(style: .unsupported))
        XCTAssertEqual(LLMCatalog.webSearchPriceNote(style: .openaiResponsesTool),
                       LLMCatalog.webSearchPriceNote)
    }

    // 「验证通过才采纳」那两条（adoptsProvider）5.1.0 随服务商选择器一起删掉：只剩一家。
}
