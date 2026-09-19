import XCTest
@testable import MicType

/// 引导「怎么用」/「试一下」两屏的文案与"配好了没有"的判断。
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

    /// 四屏，顺序写死（用户 2026-09-19 拍板：引导不许超过四屏）。
    /// 「怎么用」必须在权限之后、「试一下」之前：先把权限和模型这两件必须的事办了，
    /// 再问要不要加 AI；最后一屏是"就地试一次 + 收尾"。
    func testOnboardingIsFourPagesInOrder() {
        XCTAssertEqual(OnboardingPage.allCases.count, 4)
        XCTAssertEqual(OnboardingPage.welcome.rawValue, 0)
        XCTAssertEqual(OnboardingPage.permissions.rawValue + 1, OnboardingPage.howYouUse.rawValue)
        XCTAssertEqual(OnboardingPage.howYouUse.rawValue + 1, OnboardingPage.tryIt.rawValue)
        XCTAssertEqual(OnboardingPage(rawValue: 3), .tryIt)
    }

    // MARK: - 最后一屏两种收尾

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

    // MARK: - 「怎么用」那一屏的文案

    /// 那句解释必须把边界说清：听写在本机、不需要 Key；Key 只多润色与按住说指令
    func testUsageExplanationStatesWhatAKeyBuys() {
        L10n.shared.language = .zh
        let zh = OnboardingCopy.usageExplanation
        XCTAssertTrue(zh.contains("本机") || zh.contains("这台 Mac"), zh)
        XCTAssertTrue(zh.contains("润色") && zh.contains("指令"), zh)

        L10n.shared.language = .en
        let en = OnboardingCopy.usageExplanation
        XCTAssertTrue(en.contains("without a key"), en)
        XCTAssertTrue(en.lowercased().contains("polish"), en)
        XCTAssertTrue(en.lowercased().contains("hold-to-command"), en)
    }

    /// 标题要写明这一步是可选的——不写就是把一道可跳过的屏做成了关卡
    func testUsageHeadlineSaysItIsOptional() {
        L10n.shared.language = .zh
        XCTAssertTrue(OnboardingCopy.usageHeadline.contains("可选"), OnboardingCopy.usageHeadline)
        L10n.shared.language = .en
        XCTAssertTrue(OnboardingCopy.usageHeadline.lowercased().contains("optional"),
                      OnboardingCopy.usageHeadline)
    }

    /// 模型那一句要说清两件事：默认已经替他选好了，而且这不是不可回头的决定
    func testModelHintSaysItIsChangeableLater() {
        L10n.shared.language = .zh
        XCTAssertTrue(OnboardingCopy.modelHint.contains("设置"), OnboardingCopy.modelHint)
        L10n.shared.language = .en
        XCTAssertTrue(OnboardingCopy.modelHint.contains("Settings"), OnboardingCopy.modelHint)
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
        let all = [OnboardingCopy.usageHeadline, OnboardingCopy.usageExplanation,
                   OnboardingCopy.aiSkipReassurance, OnboardingCopy.modelHint,
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
        let zh = [OnboardingCopy.usageHeadline, OnboardingCopy.usageExplanation,
                  OnboardingCopy.aiSkipReassurance, OnboardingCopy.modelHint]
        L10n.shared.language = .en
        let en = [OnboardingCopy.usageHeadline, OnboardingCopy.usageExplanation,
                  OnboardingCopy.aiSkipReassurance, OnboardingCopy.modelHint]
        for (a, b) in zip(zh, en) { XCTAssertNotEqual(a, b, a) }
    }
}
