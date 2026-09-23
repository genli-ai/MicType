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

    /// **五屏**，顺序写死（用户 2026-09-22 拍板，推翻 09-19「最多四屏」那条）：
    /// 这是什么 + 按哪个键 → 权限 → 加 AI（可选）→ 试一下 → 它在哪。
    /// 「怎么用」必须在权限之后、「试一下」之前：先把权限和模型这两件必须的事办了，
    /// 再问要不要加 AI；「试一下」就地试一次；最后一屏回答"走完之后它去哪了"。
    func testOnboardingIsFivePagesInOrder() {
        XCTAssertEqual(OnboardingPage.allCases.count, 5)
        XCTAssertEqual(OnboardingPage.welcome.rawValue, 0)
        XCTAssertEqual(OnboardingPage.permissions.rawValue + 1, OnboardingPage.howYouUse.rawValue)
        XCTAssertEqual(OnboardingPage.howYouUse.rawValue + 1, OnboardingPage.tryIt.rawValue)
        XCTAssertEqual(OnboardingPage.tryIt.rawValue + 1, OnboardingPage.done.rawValue)
        XCTAssertEqual(OnboardingPage(rawValue: 4), .done)
    }

    /// 「完成」那颗按钮住在最后一屏上：三件必办的事的关卡在它**前面**那一屏
    ///（FirstRunEssentials.firstIncompletePage 最远只指到 .tryIt），
    /// 所以任何人走到最后一屏时都已经被放行过一次了
    func testTheGateSitsBeforeTheLastPage() {
        for page in [FirstRunEssentials(microphone: false, accessibility: true, modelReady: true),
                     FirstRunEssentials(microphone: true, accessibility: true, modelReady: false)]
            .compactMap(\.firstIncompletePage) {
            XCTAssertNotEqual(page, .done, "关卡不许落在最后一屏上")
            XCTAssertLessThan(page.rawValue, OnboardingPage.done.rawValue)
        }
    }

    // 最后一屏那三条测试（有 Key / 没 Key / 两种不串台）5.0.1 随 doneAIStatus 一起删掉：
    // ⑤ 只回答"它在哪"，不再总结 AI 配到哪一步——没配 Key 的人在 ③ 已经被那条
    // 写明代价的「先跳过」告知过了，而那一屏才是他能当场解决它的地方。

    /// 判据本身：凭据 + 拼得出来的地址 + 非空型号，三样齐了才算配好
    func testAIStatusNeedsCredentialAndEndpoint() {
        XCTAssertEqual(LLMCatalog.aiStatus(hasCredential: true, baseURL: "https://api.openai.com/v1",
                                           polishModel: "gpt-5.6-luna"), .ready)
        XCTAssertEqual(LLMCatalog.aiStatus(hasCredential: false, baseURL: "https://api.openai.com/v1",
                                           polishModel: "gpt-5.6-luna"), .off)
        // 地址拼不出来（阿里云区域端点缺 WorkspaceId）同样不算配好
        XCTAssertEqual(LLMCatalog.aiStatus(hasCredential: true, baseURL: "",
                                           polishModel: "gpt-5.6-luna"), .off)
    }

    // MARK: - 「怎么用」那一屏的文案

    // usageExplanation（③ 开头那整段说明）5.0.1 删掉，这条测试跟着走：
    // 那一屏开头再摆一段字，用户要往下翻才看得见真正要做的事（选一家、贴一把 Key）。

    /// 标题**不再写「可选」**（5.0.0）：没有 Key 这个产品一件事都干不了。
    /// 名字还得和设置页那一页对得上：同一个决定在两处叫两个名字，
    /// 用户按引导指的路去设置页时认不出来。
    func testUsageHeadlineIsNoLongerOptional() {
        L10n.shared.language = .zh
        XCTAssertFalse(OnboardingCopy.usageHeadline.contains("可选"), OnboardingCopy.usageHeadline)
        XCTAssertTrue(OnboardingCopy.usageHeadline.contains("AI"), OnboardingCopy.usageHeadline)
        L10n.shared.language = .en
        XCTAssertFalse(OnboardingCopy.usageHeadline.lowercased().contains("optional"),
                       OnboardingCopy.usageHeadline)
        XCTAssertTrue(OnboardingCopy.usageHeadline.contains("AI"), OnboardingCopy.usageHeadline)
    }


    // 「跳过也没关系」那句（aiSkipReassurance）5.0.0 删掉：没有 Key 这个产品一个功能
    // 都用不了，说"没关系"就是骗人。走不下去的人仍然有那条写明代价的「先跳过」。

    // MARK: - 三件必办的事：出口那两句

    /// 「先跳过」与「听写暂不可用」是**一对**：出口和它的代价必须同时说出来。
    /// 少了后面那句，用户不知道自己刚刚跳过了什么；少了前面那句，他就被关在引导里了。
    func testSkipLinkAndItsConsequenceAreBothSpelledOut() {
        L10n.shared.language = .zh
        XCTAssertEqual(OnboardingCopy.skipForNow, "先跳过")
        XCTAssertEqual(OnboardingCopy.dictationUnavailable, "听写暂不可用")

        L10n.shared.language = .en
        XCTAssertEqual(OnboardingCopy.skipForNow, "Skip for now")
        XCTAssertEqual(OnboardingCopy.dictationUnavailable, "Dictation will not work yet")
    }

    /// 那一行只说事实，不许写成一段劝告——它出现的时刻用户已经做完决定了
    func testConsequenceLineIsOneShortLine() {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            XCTAssertFalse(OnboardingCopy.dictationUnavailable.contains("\n"))
            XCTAssertFalse(OnboardingCopy.dictationUnavailable.contains("。"))
            XCTAssertFalse(OnboardingCopy.dictationUnavailable.contains("."))
        }
    }

    // 「重看引导」那句（reopenGuide）与它的测试 5.0.1 一起删掉：⑤ 只剩三样东西，
    // 而那句话说的是一个他此刻还没见过的窗口里的入口。

    // 模型下载那两条测试（「重试下载」的措辞与它的状态判据）随下载器一起删掉（5.0.0）。

    /// 引导里现在有文字的每一处（按钮、链接、那几行说明）
    private var everyLine: [String] {
        [OnboardingCopy.usageHeadline,
         OnboardingCopy.skipForNow, OnboardingCopy.dictationUnavailable,
         OnboardingCopy.permissionsStillMissing, OnboardingCopy.permissionsIntro,
         OnboardingCopy.hotkeyLine, OnboardingCopy.dictateCardDetail,
         OnboardingCopy.commandCardNoSelection, OnboardingCopy.commandCardSelection,
         OnboardingCopy.pasteKeyHere, OnboardingCopy.keyMissingForTryIt,
         OnboardingCopy.tryItStepDictate(hotkey: "⌥"),
         OnboardingCopy.tryItStepCommand(hotkey: "⌥"),
         OnboardingCopy.menuBarHome, OnboardingCopy.launchAtLoginWhy]
    }

    // MARK: - 第一屏与第五屏（4.3.4）

    /// 第一屏的两张卡片：**轻点那张说"说什么打什么"，按住那张必须把两种结果都说出来**
    /// （有没有选中文字，结果落在完全不同的地方——见 DictationController.selectionDelivery）。
    /// 5.0.1 之前按住那张只有一句笼统的"改写选中的文字、帮你起草回复、或直接下一条指令"，
    /// 而用户真正会踩的坑是"我选中了网页上一段字，它怎么没改"。
    func testWelcomeCardsSpellOutBothCommandOutcomes() {
        L10n.shared.language = .zh
        XCTAssertTrue(OnboardingCopy.commandCardNoSelection.contains("没选中"),
                      OnboardingCopy.commandCardNoSelection)
        XCTAssertTrue(OnboardingCopy.commandCardSelection.contains("输入框"),
                      OnboardingCopy.commandCardSelection)
        XCTAssertTrue(OnboardingCopy.commandCardSelection.contains("剪贴板"),
                      OnboardingCopy.commandCardSelection)
        XCTAssertTrue(OnboardingCopy.hotkeyLine.contains("右 Option"), OnboardingCopy.hotkeyLine)

        L10n.shared.language = .en
        XCTAssertTrue(OnboardingCopy.commandCardNoSelection.lowercased().contains("nothing selected"),
                      OnboardingCopy.commandCardNoSelection)
        XCTAssertTrue(OnboardingCopy.commandCardSelection.lowercased().contains("clipboard"),
                      OnboardingCopy.commandCardSelection)
        XCTAssertTrue(OnboardingCopy.hotkeyLine.contains("Right Option"), OnboardingCopy.hotkeyLine)
    }

    /// 「试一下」那两步：第一步必须让他**轻点两次**，第二步必须教他按住 + 选区改写。
    /// 第二步是这个产品最不直觉的一步，而这一屏是他唯一会照着做的地方
    func testTryItStepsTeachBothGestures() {
        L10n.shared.language = .zh
        let one = OnboardingCopy.tryItStepDictate(hotkey: "右 Option")
        XCTAssertTrue(one.contains("轻点"), one)
        XCTAssertTrue(one.contains("右 Option"), one)
        let two = OnboardingCopy.tryItStepCommand(hotkey: "右 Option")
        XCTAssertTrue(two.contains("按住"), two)
        XCTAssertTrue(two.contains("选中"), two)

        L10n.shared.language = .en
        XCTAssertTrue(OnboardingCopy.tryItStepDictate(hotkey: "Right Option").lowercased()
            .contains("tap right option"))
        XCTAssertTrue(OnboardingCopy.tryItStepCommand(hotkey: "Right Option").lowercased()
            .contains("hold right option"))
    }

    /// Key 框上面那句要把动作说全：从哪儿复制 + 用 ⌘V 贴到这里
    func testPasteKeyHintNamesTheShortcut() {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            XCTAssertTrue(OnboardingCopy.pasteKeyHere.contains("⌘V"), OnboardingCopy.pasteKeyHere)
        }
    }

    /// 最后一屏只剩一句话：**它在哪两处**。4.3.5 起 Dock 和菜单栏各有一枚图标
    /// （用户 2026-09-22 拍板常驻 Dock），两处都得点名——只说其中一处，
    /// 另一处那枚点下去就成了惊喜。
    /// 「菜单栏图标里有…」那句 5.0.1 删掉：那份菜单只剩三项，它念的那几样都不在里面了。
    func testLastPageSaysWhereItLives() {
        L10n.shared.language = .zh
        XCTAssertTrue(OnboardingCopy.menuBarHome.contains("菜单栏"), OnboardingCopy.menuBarHome)
        XCTAssertTrue(OnboardingCopy.menuBarHome.contains("Dock"), OnboardingCopy.menuBarHome)

        L10n.shared.language = .en
        XCTAssertTrue(OnboardingCopy.menuBarHome.lowercased().contains("menu bar"),
                      OnboardingCopy.menuBarHome)
        XCTAssertTrue(OnboardingCopy.menuBarHome.contains("Dock"), OnboardingCopy.menuBarHome)
    }

    /// 这一屏的每一句在英文界面下都不许夹中文
    func testEveryOnboardingCopyIsCleanInEnglish() {
        L10n.shared.language = .en
        for copy in everyLine {
            XCTAssertFalse(copy.isEmpty)
            XCTAssertFalse(containsCJKOrFullWidth(copy), copy)
        }
    }

    /// 中英两侧不能是同一串（漏写一侧的典型表现）
    func testCopyActuallyDiffersBetweenLanguages() {
        L10n.shared.language = .zh
        let zh = everyLine
        L10n.shared.language = .en
        let en = everyLine
        for (a, b) in zip(zh, en) { XCTAssertNotEqual(a, b, a) }
    }

    // MARK: - 「完成」为什么点不动

    /// 三件事齐了就不该再有这一行（按钮这时是亮的）
    func testNoBlockedReasonWhenEverythingIsDone() {
        XCTAssertNil(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(microphone: true, accessibility: true, modelReady: true)))
    }

    /// 权限缺一项就说权限。模型那一件**不在这里说**：那一页早有自己的一行 + 一颗「下载模型」，
    /// 说第二遍只会让人以为是两件不同的事
    func testBlockedByPermissionsAndNeverByTheModel() {
        XCTAssertEqual(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(microphone: false, accessibility: true, modelReady: true)),
                       OnboardingCopy.permissionsStillMissing)
        XCTAssertEqual(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(microphone: true, accessibility: false, modelReady: true)),
                       OnboardingCopy.permissionsStillMissing)
        XCTAssertNil(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(microphone: true, accessibility: true, modelReady: false)))
    }

    /// 什么都没办的时候说的是权限——那是这条链上最靠前的一件
    /// （和 firstIncompletePage 同一条链；快捷键 4.1.0 起不在链上了）
    func testBlockedReasonFollowsTheGuideOrder() {
        XCTAssertEqual(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(microphone: false, accessibility: false, modelReady: false)),
                       OnboardingCopy.permissionsStillMissing)
    }

    // MARK: - 权限页开头那两句

    /// 权限页开头那一句里**不许再提下载**（5.0.0 没有本机模型了）
    func testPermissionsIntroNeverMentionsADownload() {
        L10n.shared.language = .zh
        XCTAssertFalse(OnboardingCopy.permissionsIntro.contains("下载"))
        L10n.shared.language = .en
        XCTAssertFalse(OnboardingCopy.permissionsIntro.lowercased().contains("download"))
    }

    /// 引导里那些整句的说明：装不进 16 字，但同样要有一条线。
    /// 窗口高度写死 470，一句一句加下去谁也不觉得自己是"那一句"——加到装不下只会
    /// 默默多出一段滚动，没有任何测试会红（4.1.0 之前这十几行一条都没被量过）。
    func testEveryParagraphStaysUnderItsOwnBudget() {
        L10n.shared.language = .zh
        for line in OnboardingCopy.paragraphs {
            XCTAssertFalse(line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(line.contains("\n"), "引导里的说明不写成多段：\(line)")
            XCTAssertLessThanOrEqual(line.count, 60, "引导说明超预算（中文 ≤ 60 字）：\(line)")
        }
        L10n.shared.language = .en
        for line in OnboardingCopy.paragraphs {
            XCTAssertFalse(line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertLessThanOrEqual(line.count, 200, "English paragraph is over budget: \(line)")
            XCTAssertFalse(containsCJKOrFullWidth(line), line)
        }
    }

    /// 漏写一侧的典型表现：两种语言拿到同一串
    func testEveryParagraphIsWrittenInBothLanguages() {
        L10n.shared.language = .zh
        let zh = OnboardingCopy.paragraphs
        L10n.shared.language = .en
        let en = OnboardingCopy.paragraphs
        XCTAssertEqual(zh.count, en.count)
        for (a, b) in zip(zh, en) { XCTAssertNotEqual(a, b, "这一句没走 tr()：\(a)") }
    }

    /// 计入预算的那两行确实被挂进了设置页那张总表——挂漏了，16 字那条线就量不到引导
    func testGuideCaptionsAreCountedByTheCopyBudget() {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            for caption in OnboardingCopy.captions {
                XCTAssertTrue(SettingsCopy.allCaptions.contains(caption), caption)
            }
        }
    }
}
