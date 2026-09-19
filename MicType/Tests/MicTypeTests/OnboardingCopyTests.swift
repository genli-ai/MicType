import XCTest
@testable import MicType

/// 引导第 5 / 6 屏的文案与"配好了没有"的判断。
/// 这一层错了不会崩，但会正正好在最后一屏说反话：明明配好了却写「你现在是纯本机听写」，
/// 或者反过来让人白等一个永远不会发生的润色。
final class OnboardingCopyTests: XCTestCase {

    private var savedLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    /// 英文界面里不许出现汉字、CJK 标点或全角标点（与 AISetupTests 同一条尺子）
    private func containsCJKOrFullWidth(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)      // CJK 标点（「」、。）
                || (0x4E00...0x9FFF).contains(scalar.value)   // 汉字
                || (0xFF00...0xFFEF).contains(scalar.value)   // 全角字符（：（））
        }
    }

    // MARK: - 页序

    /// AI 那一屏必须夹在「现场试一次」与「完成」之间：先让人试出听写能用，
    /// 再问要不要加 AI——顺序反了就是"先交钱再看东西"
    func testAISetupSitsBetweenTryItAndDone() {
        XCTAssertEqual(OnboardingPage.allCases.count, 6)
        XCTAssertEqual(OnboardingPage.tryIt.rawValue + 1, OnboardingPage.aiSetup.rawValue)
        XCTAssertEqual(OnboardingPage.aiSetup.rawValue + 1, OnboardingPage.done.rawValue)
        XCTAssertEqual(OnboardingPage(rawValue: 4), .aiSetup)
    }

    // MARK: - 第 6 屏两种收尾

    /// 有 Key：点名「按住 + 快捷键 + 一句真能照着说的话」
    func testDoneStatusWithAKeyNamesTheHoldGesture() {
        L10n.shared.language = .zh
        let zh = OnboardingCopy.doneAIStatus(ready: true, hotkey: "⌥")
        XCTAssertTrue(zh.contains("按住"), zh)
        XCTAssertTrue(zh.contains("⌥"), zh)

        L10n.shared.language = .en
        let en = OnboardingCopy.doneAIStatus(ready: true, hotkey: "⌥")
        XCTAssertTrue(en.contains("Hold ⌥"), en)
        XCTAssertTrue(en.lowercased().contains("more formal"), en)
        XCTAssertFalse(containsCJKOrFullWidth(en), en)
    }

    /// 没 Key：必须说清"现在这样也完整可用"，并指路 设置 → AI
    func testDoneStatusWithoutAKeyPointsAtSettings() {
        L10n.shared.language = .zh
        let zh = OnboardingCopy.doneAIStatus(ready: false, hotkey: "⌥")
        XCTAssertTrue(zh.contains("设置"), zh)
        XCTAssertFalse(zh.contains("按住"), zh)

        L10n.shared.language = .en
        let en = OnboardingCopy.doneAIStatus(ready: false, hotkey: "⌥")
        XCTAssertTrue(en.contains("Settings"), en)
        XCTAssertTrue(en.contains("on-device"), en)
        XCTAssertFalse(containsCJKOrFullWidth(en), en)
    }

    /// 两种收尾不能串台（复制粘贴写错一处就会一模一样）
    func testDoneStatusVariantsDiffer() {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            XCTAssertNotEqual(OnboardingCopy.doneAIStatus(ready: true, hotkey: "⌥"),
                              OnboardingCopy.doneAIStatus(ready: false, hotkey: "⌥"))
        }
    }

    // MARK: - 第 5 屏文案

    /// 那句解释必须把边界说清：听写在本机、不需要 Key；Key 只多润色与按住说指令
    func testAIExplanationStatesWhatAKeyBuys() {
        L10n.shared.language = .zh
        let zh = OnboardingCopy.aiExplanation
        XCTAssertTrue(zh.contains("本机") || zh.contains("这台 Mac"), zh)
        XCTAssertTrue(zh.contains("润色") && zh.contains("指令"), zh)

        L10n.shared.language = .en
        let en = OnboardingCopy.aiExplanation
        XCTAssertTrue(en.contains("without a key"), en)
        XCTAssertTrue(en.lowercased().contains("polish"), en)
        XCTAssertTrue(en.lowercased().contains("hold-to-command"), en)
    }

    /// 标题要写明这一步是可选的——不写就是把一道可跳过的屏做成了关卡
    func testAIHeadlineSaysItIsOptional() {
        L10n.shared.language = .zh
        XCTAssertTrue(OnboardingCopy.aiHeadline.contains("可选"), OnboardingCopy.aiHeadline)
        L10n.shared.language = .en
        XCTAssertTrue(OnboardingCopy.aiHeadline.lowercased().contains("optional"),
                      OnboardingCopy.aiHeadline)
    }

    /// 跳过那句必须是"没关系"的口吻，不能留一句像警告的话
    func testSkipReassuranceIsReassuring() {
        L10n.shared.language = .en
        let en = OnboardingCopy.aiSkipReassurance
        XCTAssertTrue(en.contains("fine"), en)
        XCTAssertTrue(en.contains("Settings"), en)
    }

    /// 这一屏的每一句在英文界面下都不许夹中文
    func testEveryOnboardingCopyIsCleanInEnglish() {
        L10n.shared.language = .en
        let all = [OnboardingCopy.aiHeadline, OnboardingCopy.aiExplanation,
                   OnboardingCopy.aiSkipReassurance, OnboardingCopy.aiQualityHint,
                   OnboardingCopy.doneAIStatus(ready: true, hotkey: "⌥"),
                   OnboardingCopy.doneAIStatus(ready: false, hotkey: "⌥")]
        for copy in all {
            XCTAssertFalse(copy.isEmpty)
            XCTAssertFalse(containsCJKOrFullWidth(copy), copy)
        }
    }

    /// 中英两侧不能是同一串（漏写一侧的典型表现）
    func testCopyActuallyDiffersBetweenLanguages() {
        L10n.shared.language = .zh
        let zh = [OnboardingCopy.aiHeadline, OnboardingCopy.aiExplanation,
                  OnboardingCopy.aiSkipReassurance, OnboardingCopy.aiQualityHint]
        L10n.shared.language = .en
        let en = [OnboardingCopy.aiHeadline, OnboardingCopy.aiExplanation,
                  OnboardingCopy.aiSkipReassurance, OnboardingCopy.aiQualityHint]
        for (a, b) in zip(zh, en) { XCTAssertNotEqual(a, b, a) }
    }
}
