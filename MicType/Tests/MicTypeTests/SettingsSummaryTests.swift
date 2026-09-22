import XCTest
@testable import MicType

/// 概览页三张卡上的那一句话。
///
/// 为什么值得一整个测试文件：这三句是用户判断"要不要点进去改"的**唯一**依据。
/// 说错一个词（把云端识别说成关着、把没下载的模型说成已就绪），用户就会照着一句假话
/// 做决定——而这正是纯函数最该被钉死的地方：视图里现拼的字符串谁也测不到。
final class SettingsSummaryTests: XCTestCase {

    private var savedLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    /// 英文界面里不许出现汉字、CJK 标点或全角标点
    private func containsCJKOrFullWidth(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }

    // MARK: - 输入

    func testInputSummaryLeadsWithTheHotkeyFullName() {
        L10n.shared.language = .zh
        let line = SettingsSummary.inputSummary(launchAtLogin: false,
                                                vocabCount: 0,
                                                hasCustomRules: false)
        // 键名一律全名（R⌥ 这种缩写没人看得懂），而且排在最前面
        XCTAssertTrue(line.hasPrefix("右 Option"), line)
        // 开机自启关着就不占一格：那是出厂默认，说出来等于用一格讲一件没发生的事
        XCTAssertFalse(line.contains("自启"), line)
        // 写作偏好空着同理：一个"0 条词汇表"帮不了任何人
        XCTAssertFalse(line.contains("词汇表"), line)
        XCTAssertFalse(line.contains("自定义规则"), line)
        // 4.3.3：悬浮窗位置与提示音那两个开关已经从「输入」页撤了，卡片上也不许再念——
        // 卡片上有、页里改不到，那一格就成了死胡同
        XCTAssertFalse(line.contains("悬浮窗"), line)
        XCTAssertFalse(line.contains("提示音"), line)
    }

    func testInputSummaryMentionsLaunchAtLoginOnlyWhenOn() {
        L10n.shared.language = .zh
        let on = SettingsSummary.inputSummary(launchAtLogin: true,
                                              vocabCount: 0,
                                              hasCustomRules: false)
        XCTAssertTrue(on.contains("开机自启"), on)
    }

    /// 4.1.6：词汇表与自定义规则搬到了「输入」页，这张卡要把它们报出来——
    /// 而且**紧跟在键名后面**，和页内的段序一致（点进去才不用再找一遍）
    func testInputSummaryCarriesWritingPreferencesRightAfterTheHotkey() {
        L10n.shared.language = .zh
        let line = SettingsSummary.inputSummary(launchAtLogin: false,
                                                vocabCount: 11,
                                                hasCustomRules: true)
        XCTAssertTrue(line.contains("词汇表 11 条"), line)
        XCTAssertTrue(line.contains("有自定义规则"), line)
        let parts = line.components(separatedBy: " · ")
        // 4.3.3 起最多三格：键名 · 词汇表 · 有自定义规则（+ 开着时的开机自启）
        XCTAssertEqual(parts.count, 3, line)
        XCTAssertEqual(parts[1], "词汇表 11 条", line)
        XCTAssertEqual(parts[2], "有自定义规则", line)
        // 规则的**内容**永不上卡片：概览只说"有没有"
        XCTAssertFalse(line.contains("署名"), line)
    }

    /// 两项各自独立：只填了词汇表的人不该在卡上读到"有自定义规则"
    func testInputSummaryReportsEachWritingPreferenceOnItsOwn() {
        L10n.shared.language = .zh
        let vocabOnly = SettingsSummary.inputSummary(launchAtLogin: false,
                                                     vocabCount: 3, hasCustomRules: false)
        XCTAssertTrue(vocabOnly.contains("词汇表 3 条"), vocabOnly)
        XCTAssertFalse(vocabOnly.contains("自定义规则"), vocabOnly)

        let rulesOnly = SettingsSummary.inputSummary(launchAtLogin: false,
                                                     vocabCount: 0, hasCustomRules: true)
        XCTAssertFalse(rulesOnly.contains("词汇表"), rulesOnly)
        XCTAssertTrue(rulesOnly.contains("有自定义规则"), rulesOnly)
    }

    func testInputSummaryIsCleanInEnglish() {
        L10n.shared.language = .en
        let line = SettingsSummary.inputSummary(launchAtLogin: true,
                                                vocabCount: 4,
                                                hasCustomRules: true)
        XCTAssertFalse(containsCJKOrFullWidth(line), line)
        XCTAssertTrue(line.contains("Right Option"), line)
        XCTAssertTrue(line.contains("4 vocabulary terms"), line)
        XCTAssertTrue(line.contains("Custom rules set"), line)
    }

    // MARK: - 本地识别

    func testRecognitionSummaryReadsLikeTheExample() {
        L10n.shared.language = .zh
        let card = SettingsSummary.recognitionSummary(language: RecognitionLanguages.autoCode,
                                                      modelState: .ready(name: "0.6B"),
                                                      micName: "")
        // 4.1.6 起这张卡不再提词汇表（那个框搬去了「输入 → 写作偏好」）
        XCTAssertEqual(card.sentence, "自动检测语言 · 模型 0.6B 已就绪")
        // 没事可做就没有徽章：常驻的橙色标记两天之内就会被眼睛滤掉
        XCTAssertNil(card.badge)
    }

    func testRecognitionSummaryDropsTheDefaultMicrophoneAndNeverMentionsVocabulary() {
        L10n.shared.language = .zh
        let card = SettingsSummary.recognitionSummary(language: "zh",
                                                      modelState: .ready(name: "0.6B"),
                                                      micName: "  ")
        XCTAssertFalse(card.sentence.contains("词汇表"), card.sentence)
        XCTAssertFalse(card.sentence.contains("麦克风"), card.sentence)
        XCTAssertTrue(card.sentence.contains("识别 中文"), card.sentence)
    }

    func testRecognitionSummaryNamesTheChosenMicrophone() {
        L10n.shared.language = .zh
        let card = SettingsSummary.recognitionSummary(language: "ar",
                                                      modelState: .ready(name: "0.6B"),
                                                      micName: "AirPods Pro")
        XCTAssertTrue(card.sentence.contains("麦克风 AirPods Pro"), card.sentence)
    }

    /// 读不懂的语言码一律当「自动」——和 RecognitionLanguages.modelLanguage 同一条纪律：
    /// 一条坏设置不能让这句话报出一个用户根本没选过的语言
    func testUnknownLanguageCodeFallsBackToAutomatic() {
        L10n.shared.language = .zh
        let card = SettingsSummary.recognitionSummary(language: "klingon",
                                                      modelState: .ready(name: "0.6B"),
                                                      micName: "")
        XCTAssertTrue(card.sentence.hasPrefix("自动检测语言"), card.sentence)
    }

    func testModelBadgeOnlyAppearsWhenThereIsSomethingToDo() {
        L10n.shared.language = .zh
        func badge(_ state: SettingsSummary.ModelState) -> String? {
            SettingsSummary.recognitionSummary(language: RecognitionLanguages.autoCode,
                                               modelState: state,
                                               micName: "").badge
        }
        XCTAssertNil(badge(.ready(name: "0.6B")))
        XCTAssertEqual(badge(.missing(name: "0.6B")), "模型未下载")
        XCTAssertEqual(badge(.downloading(percent: 42)), "正在下载 42%")
        XCTAssertEqual(badge(.upgradeAvailable(name: "1.7B")), "有更合适的模型")
    }

    /// 有得升级 ≠ 现在坏了：句子照说"已就绪"，只多一枚徽章
    func testUpgradeAvailableStillReadsAsReady() {
        L10n.shared.language = .zh
        let card = SettingsSummary.recognitionSummary(language: RecognitionLanguages.autoCode,
                                                      modelState: .upgradeAvailable(name: "0.6B"),
                                                      micName: "")
        XCTAssertTrue(card.sentence.contains("已就绪"), card.sentence)
        XCTAssertNotNil(card.badge)
    }

    func testRecognitionSummaryIsCleanInEnglish() {
        L10n.shared.language = .en
        let states: [SettingsSummary.ModelState] = [.ready(name: "0.6B"), .missing(name: "0.6B"),
                                                    .downloading(percent: 7),
                                                    .upgradeAvailable(name: "1.7B")]
        for state in states {
            let card = SettingsSummary.recognitionSummary(language: "ar",
                                                          modelState: state,
                                                          micName: "MacBook Pro Microphone")
            XCTAssertFalse(containsCJKOrFullWidth(card.sentence), card.sentence)
            XCTAssertFalse(containsCJKOrFullWidth(card.badge ?? ""), card.badge ?? "")
        }
    }

    // MARK: - 云端 AI

    /// 「只用本地」这一档整句就是结论，连服务商名字都不该出现——那一档不联网、不花钱
    func testLocalOnlyCloudCardSaysSoAndNothingElse() {
        L10n.shared.language = .zh
        let card = SettingsSummary.cloudSummary(provider: .openai,
                                                model: "gpt-5.6-sol",
                                                keyState: .missing,
                                                polishLevel: .off,
                                                engine: .local)
        XCTAssertEqual(card.sentence, "未启用 · 只用本地")
        XCTAssertFalse(card.sentence.contains("OpenAI"), card.sentence)
        // 没启用 AI 的人不该看到一枚「还没填 Key」的徽章：他根本没打算填
        XCTAssertNil(card.badge)
    }

    func testConnectedCloudCardNamesProviderAndModel() {
        L10n.shared.language = .zh
        let card = SettingsSummary.cloudSummary(provider: .openai,
                                                model: " gpt-5.6-sol ",
                                                keyState: .ready,
                                                polishLevel: .smart,
                                                engine: .local)
        XCTAssertEqual(card.sentence, "OpenAI · gpt-5.6-sol · 已连通 ✓")
        XCTAssertNil(card.badge)
    }

    /// 云端识别开着 = 每段录音都在上传、按秒计费，这是这一刻最该看见的一条事实
    func testCloudRecognitionTakesTheLastSlot() {
        L10n.shared.language = .zh
        let card = SettingsSummary.cloudSummary(provider: .qwen,
                                                model: "qwen3.8-max",
                                                keyState: .ready,
                                                polishLevel: .smart,
                                                engine: .cloudAlibaba)
        XCTAssertEqual(card.sentence, "阿里云 · qwen3.8-max · 云端识别开")
        // 这一档是用户自己在「云端 AI」页上打开的，没有要他动手的事
        XCTAssertNil(card.badge)
    }

    /// `cloudOpenAI` 4.2.2 起是一档**正常配置**（OpenAI 的实时转写端点），不再是 4.0.0 的遗留。
    /// 服务商就是 OpenAI 时卡上不该有任何"出事了"的徽章——那是用户自己刚打开的开关；
    /// 只有服务商换走之后它才变成"停在旧档"（那时候界面上已经没有关掉它的控件）。
    func testOpenAICloudRecognitionIsNormalUntilTheProviderMovesOn() {
        L10n.shared.language = .zh
        let normal = SettingsSummary.cloudSummary(provider: .openai,
                                                  model: "gpt-5.6-luna",
                                                  keyState: .ready,
                                                  polishLevel: .smart,
                                                  engine: .cloudOpenAI)
        XCTAssertTrue(normal.sentence.contains("云端识别开"), normal.sentence)
        XCTAssertNil(normal.badge, "用户自己打开的开关，卡上不该有徽章")

        // 服务商换成别家：音频还在往 OpenAI 传，而那个开关已经不渲染了
        let stranded = SettingsSummary.cloudSummary(provider: .deepseek,
                                                    model: "deepseek-flash",
                                                    keyState: .ready,
                                                    polishLevel: .smart,
                                                    engine: .cloudOpenAI)
        XCTAssertTrue(stranded.sentence.contains("录音上传给OpenAI"), stranded.sentence)
        XCTAssertFalse(stranded.sentence.contains("已连通"), stranded.sentence)
        XCTAssertEqual(stranded.badge, "云端识别停在旧档")
    }

    /// 识别停在阿里云、服务商却换走了：那个开关只在阿里云档渲染，界面上关不掉它。
    /// 句子必须报真正的收信人，不能写成「DeepSeek · … · 云端识别开」
    func testStrandedAlibabaRecognitionNamesTheRealUploadTarget() {
        L10n.shared.language = .zh
        let card = SettingsSummary.cloudSummary(provider: .deepseek,
                                                model: "deepseek-v4-pro",
                                                keyState: .ready,
                                                polishLevel: .smart,
                                                engine: .cloudAlibaba)
        XCTAssertTrue(card.sentence.hasPrefix("DeepSeek"), card.sentence)
        XCTAssertTrue(card.sentence.contains("录音上传给阿里云"), card.sentence)
        XCTAssertEqual(card.badge, "云端识别停在旧档")
    }

    /// 从菜单栏把润色关掉、云端识别还开着：那个润色型号一次都不会被用到，
    /// 报出来等于让人以为文字正在被润色
    func testPolishOffIsSaidInsteadOfNamingAnUnusedModel() {
        L10n.shared.language = .zh
        let card = SettingsSummary.cloudSummary(provider: .qwen,
                                                model: "qwen3.8-max",
                                                keyState: .ready,
                                                polishLevel: .off,
                                                engine: .cloudAlibaba)
        XCTAssertEqual(card.sentence, "阿里云 · 润色关着 · 云端识别开")
    }

    /// 润色关着 + 识别在本机 = 「只用本地」：这一档整句就是结论（判据与 AISetup.mode 同源）
    func testPolishOffWithLocalEngineFallsBackToLocalOnly() {
        L10n.shared.language = .zh
        let card = SettingsSummary.cloudSummary(provider: .qwen,
                                                model: "qwen3.8-max",
                                                keyState: .ready,
                                                polishLevel: .off,
                                                engine: .local)
        XCTAssertEqual(card.sentence, "未启用 · 只用本地")
        XCTAssertNil(card.badge)
    }

    func testCloudBadgeReportsWhatIsMissing() {
        L10n.shared.language = .zh
        func badge(_ state: SettingsSummary.KeyState) -> String? {
            SettingsSummary.cloudSummary(provider: .deepseek,
                                         model: "deepseek-v4-pro",
                                         keyState: state,
                                         polishLevel: .smart, engine: .local).badge
        }
        XCTAssertNil(badge(.ready))
        XCTAssertEqual(badge(.missing), "还没填 Key")
        // 填了 Key 却没填型号名 / 拼不出地址：按住说指令这会儿跑不起来，不能说成「已连通」
        XCTAssertEqual(badge(.incomplete), "配置没填完")
    }

    func testCloudSummaryIsCleanInEnglish() {
        L10n.shared.language = .en
        for provider in LLMProvider.allCases {
            for state in [SettingsSummary.KeyState.missing, .incomplete, .ready] {
                for engine in RecognitionEngineChoice.allCases {
                    for polish in PolishLevel.allCases {
                        let card = SettingsSummary.cloudSummary(provider: provider,
                                                                model: "model-x",
                                                                keyState: state,
                                                                polishLevel: polish,
                                                                engine: engine)
                        XCTAssertFalse(containsCJKOrFullWidth(card.sentence), card.sentence)
                        XCTAssertFalse(containsCJKOrFullWidth(card.badge ?? ""), card.badge ?? "")
                    }
                }
            }
        }
        let off = SettingsSummary.cloudSummary(provider: .openai, model: "",
                                               keyState: .missing,
                                               polishLevel: .off, engine: .local)
        XCTAssertFalse(containsCJKOrFullWidth(off.sentence), off.sentence)
    }

    /// 型号名空着（自定义端点没填）时不留一个孤零零的分隔点
    func testEmptyModelLeavesNoDanglingSeparator() {
        L10n.shared.language = .zh
        let card = SettingsSummary.cloudSummary(provider: .local, model: "   ",
                                                keyState: .incomplete,
                                                polishLevel: .smart, engine: .local)
        XCTAssertFalse(card.sentence.contains("·  ·"), card.sentence)
        XCTAssertEqual(card.sentence.components(separatedBy: "·").count, 2, card.sentence)
    }
}
