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
        let line = SettingsSummary.inputSummary(hotkey: .rightOption,
                                                overlayPosition: .bottomCenter,
                                                sounds: true,
                                                launchAtLogin: false)
        // 键名一律全名（R⌥ 这种缩写没人看得懂），而且排在最前面
        XCTAssertTrue(line.hasPrefix("右 Option"), line)
        XCTAssertTrue(line.contains("底部"), line)
        XCTAssertTrue(line.contains("提示音开"), line)
        // 开机自启关着就不占一格：那是出厂默认，说出来等于用一格讲一件没发生的事
        XCTAssertFalse(line.contains("自启"), line)
    }

    func testInputSummaryMentionsLaunchAtLoginOnlyWhenOn() {
        L10n.shared.language = .zh
        let on = SettingsSummary.inputSummary(hotkey: .rightControl,
                                              overlayPosition: .nearCursor,
                                              sounds: false,
                                              launchAtLogin: true)
        XCTAssertTrue(on.contains("开机自启"), on)
        XCTAssertTrue(on.contains("提示音关"), on)
        XCTAssertTrue(on.contains("跟随鼠标"), on)
    }

    func testInputSummaryIsCleanInEnglish() {
        L10n.shared.language = .en
        for position in OverlayPosition.allCases {
            let line = SettingsSummary.inputSummary(hotkey: .rightCommand,
                                                    overlayPosition: position,
                                                    sounds: true,
                                                    launchAtLogin: true)
            XCTAssertFalse(containsCJKOrFullWidth(line), line)
            XCTAssertTrue(line.contains("Right Command"), line)
        }
    }

    // MARK: - 本地识别

    func testRecognitionSummaryReadsLikeTheExample() {
        L10n.shared.language = .zh
        let card = SettingsSummary.recognitionSummary(language: RecognitionLanguages.autoCode,
                                                      vocabCount: 12,
                                                      modelState: .ready(name: "0.6B"),
                                                      micName: "")
        XCTAssertEqual(card.sentence, "自动检测语言 · 词汇表 12 条 · 模型 0.6B 已就绪")
        // 没事可做就没有徽章：常驻的橙色标记两天之内就会被眼睛滤掉
        XCTAssertNil(card.badge)
    }

    func testRecognitionSummaryDropsEmptyVocabularyAndDefaultMicrophone() {
        L10n.shared.language = .zh
        let card = SettingsSummary.recognitionSummary(language: "zh",
                                                      vocabCount: 0,
                                                      modelState: .ready(name: "0.6B"),
                                                      micName: "  ")
        XCTAssertFalse(card.sentence.contains("词汇表"), card.sentence)
        XCTAssertFalse(card.sentence.contains("麦克风"), card.sentence)
        XCTAssertTrue(card.sentence.contains("识别 中文"), card.sentence)
    }

    func testRecognitionSummaryNamesTheChosenMicrophone() {
        L10n.shared.language = .zh
        let card = SettingsSummary.recognitionSummary(language: "ar",
                                                      vocabCount: 3,
                                                      modelState: .ready(name: "0.6B"),
                                                      micName: "AirPods Pro")
        XCTAssertTrue(card.sentence.contains("麦克风 AirPods Pro"), card.sentence)
    }

    /// 读不懂的语言码一律当「自动」——和 RecognitionLanguages.modelLanguage 同一条纪律：
    /// 一条坏设置不能让这句话报出一个用户根本没选过的语言
    func testUnknownLanguageCodeFallsBackToAutomatic() {
        L10n.shared.language = .zh
        let card = SettingsSummary.recognitionSummary(language: "klingon",
                                                      vocabCount: 0,
                                                      modelState: .ready(name: "0.6B"),
                                                      micName: "")
        XCTAssertTrue(card.sentence.hasPrefix("自动检测语言"), card.sentence)
    }

    func testModelBadgeOnlyAppearsWhenThereIsSomethingToDo() {
        L10n.shared.language = .zh
        func badge(_ state: SettingsSummary.ModelState) -> String? {
            SettingsSummary.recognitionSummary(language: RecognitionLanguages.autoCode,
                                               vocabCount: 0,
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
                                                      vocabCount: 0,
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
                                                          vocabCount: 5,
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
        let card = SettingsSummary.cloudSummary(mode: .localOnly,
                                                provider: .openai,
                                                model: "gpt-5.6-sol",
                                                keyState: .missing,
                                                cloudRecognition: false)
        XCTAssertEqual(card.sentence, "未启用 · 只用本地")
        XCTAssertFalse(card.sentence.contains("OpenAI"), card.sentence)
        // 没启用 AI 的人不该看到一枚「还没填 Key」的徽章：他根本没打算填
        XCTAssertNil(card.badge)
    }

    func testConnectedCloudCardNamesProviderAndModel() {
        L10n.shared.language = .zh
        let card = SettingsSummary.cloudSummary(mode: .withAI,
                                                provider: .openai,
                                                model: " gpt-5.6-sol ",
                                                keyState: .ready,
                                                cloudRecognition: false)
        XCTAssertEqual(card.sentence, "OpenAI · gpt-5.6-sol · 已连通 ✓")
        XCTAssertNil(card.badge)
    }

    /// 云端识别开着 = 每段录音都在上传、按秒计费，这是这一刻最该看见的一条事实
    func testCloudRecognitionTakesTheLastSlot() {
        L10n.shared.language = .zh
        let card = SettingsSummary.cloudSummary(mode: .withAI,
                                                provider: .qwen,
                                                model: "qwen3.8-max",
                                                keyState: .ready,
                                                cloudRecognition: true)
        XCTAssertEqual(card.sentence, "阿里云 · qwen3.8-max · 云端识别开")
    }

    func testCloudBadgeReportsWhatIsMissing() {
        L10n.shared.language = .zh
        func badge(_ state: SettingsSummary.KeyState) -> String? {
            SettingsSummary.cloudSummary(mode: .withAI, provider: .deepseek,
                                         model: "deepseek-v4-pro",
                                         keyState: state, cloudRecognition: false).badge
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
                for cloud in [true, false] {
                    let card = SettingsSummary.cloudSummary(mode: .withAI, provider: provider,
                                                            model: "model-x",
                                                            keyState: state,
                                                            cloudRecognition: cloud)
                    XCTAssertFalse(containsCJKOrFullWidth(card.sentence), card.sentence)
                    XCTAssertFalse(containsCJKOrFullWidth(card.badge ?? ""), card.badge ?? "")
                }
            }
        }
        let off = SettingsSummary.cloudSummary(mode: .localOnly, provider: .openai, model: "",
                                               keyState: .missing, cloudRecognition: false)
        XCTAssertFalse(containsCJKOrFullWidth(off.sentence), off.sentence)
    }

    /// 型号名空着（自定义端点没填）时不留一个孤零零的分隔点
    func testEmptyModelLeavesNoDanglingSeparator() {
        L10n.shared.language = .zh
        let card = SettingsSummary.cloudSummary(mode: .withAI, provider: .local, model: "   ",
                                                keyState: .incomplete, cloudRecognition: false)
        XCTAssertFalse(card.sentence.contains("·  ·"), card.sentence)
        XCTAssertEqual(card.sentence.components(separatedBy: "·").count, 2, card.sentence)
    }
}
