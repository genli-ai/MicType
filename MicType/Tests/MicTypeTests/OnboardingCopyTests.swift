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
        let zh = OnboardingCopy.doneAIStatus(status: .ready, hotkey: "⌥")
        XCTAssertTrue(zh.contains("按住"), zh)
        XCTAssertTrue(zh.contains("⌥"), zh)

        L10n.shared.language = .en
        let en = OnboardingCopy.doneAIStatus(status: .ready, hotkey: "⌥")
        XCTAssertTrue(en.contains("Hold ⌥"), en)
        XCTAssertTrue(en.lowercased().contains("more formal"), en)
        XCTAssertFalse(containsCJKOrFullWidth(en), en)
    }

    /// 没 Key：必须说清"现在这样也完整可用"，并指路 设置 → AI
    func testDoneStatusWithoutAKeyPointsAtSettings() {
        L10n.shared.language = .zh
        let zh = OnboardingCopy.doneAIStatus(status: .off, hotkey: "⌥")
        XCTAssertTrue(zh.contains("设置"), zh)
        XCTAssertFalse(zh.contains("按住"), zh)

        L10n.shared.language = .en
        let en = OnboardingCopy.doneAIStatus(status: .off, hotkey: "⌥")
        XCTAssertTrue(en.contains("Settings"), en)
        XCTAssertTrue(en.contains("on-device"), en)
        XCTAssertFalse(containsCJKOrFullWidth(en), en)
    }

    /// 三种收尾不能串台（复制粘贴写错一处就会一模一样）
    func testDoneStatusVariantsDiffer() {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            let all = [OnboardingCopy.doneAIStatus(status: .ready, hotkey: "⌥"),
                       OnboardingCopy.doneAIStatus(status: .commandsOnly, hotkey: "⌥"),
                       OnboardingCopy.doneAIStatus(status: .off, hotkey: "⌥")]
            XCTAssertEqual(Set(all).count, 3, "\(all)")
        }
    }

    /// 选了「只用本地」却还留着一把 Key：**不许**宣告"润色就绪"——此刻轻点听写
    /// 一个字都不润色，而按住说指令仍然会用那把 Key 计费。两件事都要说出来。
    func testDoneStatusForLocalOnlyWithAStoredKey() {
        L10n.shared.language = .zh
        let zh = OnboardingCopy.doneAIStatus(status: .commandsOnly, hotkey: "右 Option")
        XCTAssertTrue(zh.contains("不润色"), zh)
        XCTAssertTrue(zh.contains("Key"), zh)
        XCTAssertTrue(zh.contains("按住"), zh)

        L10n.shared.language = .en
        let en = OnboardingCopy.doneAIStatus(status: .commandsOnly, hotkey: "Right Option")
        XCTAssertTrue(en.contains("does not polish"), en)
        XCTAssertTrue(en.lowercased().contains("billed"), en)
        XCTAssertFalse(containsCJKOrFullWidth(en), en)
    }

    /// 判据本身：钥匙串里有 Key 但润色关着 → commandsOnly，不是 ready
    func testAIStatusNeedsPolishOnToCallItReady() {
        XCTAssertEqual(LLMCatalog.aiStatus(hasCredential: true, baseURL: "https://api.openai.com/v1",
                                           polishModel: "gpt-5.6-sol", polishEnabled: true), .ready)
        XCTAssertEqual(LLMCatalog.aiStatus(hasCredential: true, baseURL: "https://api.openai.com/v1",
                                           polishModel: "gpt-5.6-sol", polishEnabled: false), .commandsOnly)
        XCTAssertEqual(LLMCatalog.aiStatus(hasCredential: false, baseURL: "https://api.openai.com/v1",
                                           polishModel: "gpt-5.6-sol", polishEnabled: true), .off)
        // 型号名是空的（自定义端点 / 本机模型没填）同样不算配好
        XCTAssertEqual(LLMCatalog.aiStatus(hasCredential: true, baseURL: "http://localhost:11434/v1",
                                           polishModel: "  ", polishEnabled: true), .off)
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

    /// 标题要写明这一步是可选的——不写就是把一道可跳过的屏做成了关卡。
    /// 名字还得和设置页那一段（「使用方式」/ How you use MicType）对得上：
    /// 同一个决定在两处叫两个名字，用户按第四屏指的路去设置页时认不出来。
    func testUsageHeadlineSaysItIsOptionalAndMatchesSettings() {
        L10n.shared.language = .zh
        XCTAssertTrue(OnboardingCopy.usageHeadline.contains("可选"), OnboardingCopy.usageHeadline)
        XCTAssertTrue(OnboardingCopy.usageHeadline.hasPrefix("使用方式"), OnboardingCopy.usageHeadline)
        L10n.shared.language = .en
        XCTAssertTrue(OnboardingCopy.usageHeadline.lowercased().contains("optional"),
                      OnboardingCopy.usageHeadline)
        XCTAssertTrue(OnboardingCopy.usageHeadline.hasPrefix("How you use MicType"),
                      OnboardingCopy.usageHeadline)
    }


    /// 跳过那句必须是"没关系"的口吻，不能留一句像警告的话
    func testSkipReassuranceIsReassuring() {
        L10n.shared.language = .en
        let en = OnboardingCopy.aiSkipReassurance
        XCTAssertTrue(en.contains("fine"), en)
        XCTAssertTrue(en.contains("Settings"), en)
    }

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

    /// 第一屏那颗选择器下面**只有一行**，而且要说清"默认是哪颗、以后能不能改"
    func testHotkeyChoiceCaptionNamesTheDefaultAndSaysItIsChangeable() {
        L10n.shared.language = .zh
        let zh = OnboardingCopy.hotkeyChoice
        XCTAssertTrue(zh.contains(HotkeyChoice.rightOption.plainName), zh)
        XCTAssertTrue(zh.contains("改"), zh)
        XCTAssertFalse(zh.contains("\n"), zh)

        L10n.shared.language = .en
        let en = OnboardingCopy.hotkeyChoice
        XCTAssertTrue(en.contains(HotkeyChoice.rightOption.plainName), en)
        XCTAssertTrue(en.lowercased().contains("change"), en)
    }

    /// 下载掉下来之后那颗按钮写的是「重试」，不是「下载」：
    /// 对刚看着进度条归零的人，「下载模型」像是什么都没发生过
    func testRetryDownloadSaysRetry() {
        L10n.shared.language = .zh
        XCTAssertTrue(OnboardingCopy.retryDownload.contains("重试"), OnboardingCopy.retryDownload)
        L10n.shared.language = .en
        XCTAssertTrue(OnboardingCopy.retryDownload.lowercased().contains("retry"),
                      OnboardingCopy.retryDownload)
    }

    /// 按钮上那颗字的状态判据：取消过 / 失败过才叫「重试」
    func testRetryLabelFollowsTheDownloadPhase() {
        XCTAssertTrue(QwenDownloadPhase.cancelled.didNotFinish)
        XCTAssertTrue(QwenDownloadPhase.failed(.allMirrorsFailed).didNotFinish)
        XCTAssertFalse(QwenDownloadPhase.idle.didNotFinish)
        XCTAssertFalse(QwenDownloadPhase.fetchingList.didNotFinish)
        XCTAssertFalse(QwenDownloadPhase.completed(fileCount: 3).didNotFinish)
        XCTAssertFalse(QwenDownloadPhase.downloading(fileIndex: 0, fileCount: 3,
                                                     doneBytes: 1, totalBytes: 2).didNotFinish)
    }

    /// 引导里现在有文字的每一处（按钮、链接、那几行说明）
    private var everyLine: [String] {
        [OnboardingCopy.usageHeadline, OnboardingCopy.usageExplanation,
         OnboardingCopy.aiSkipReassurance, OnboardingCopy.hotkeyChoice,
         OnboardingCopy.skipForNow, OnboardingCopy.dictationUnavailable,
         OnboardingCopy.retryDownload,
         OnboardingCopy.confirmHotkeyFirst, OnboardingCopy.permissionsStillMissing,
         OnboardingCopy.permissionsIntro(modelDownloading: true),
         OnboardingCopy.permissionsIntro(modelDownloading: false),
         OnboardingCopy.doneAIStatus(status: .ready, hotkey: "⌥"),
         OnboardingCopy.doneAIStatus(status: .commandsOnly, hotkey: "⌥"),
         OnboardingCopy.doneAIStatus(status: .off, hotkey: "⌥")]
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
            FirstRunEssentials(hotkeyConfirmed: true, microphone: true,
                               accessibility: true, modelReady: true)))
    }

    /// 卡在快捷键上：这一行要把他指回第一屏——那一屏是他被直接送到第二屏时从没见过的。
    /// 没有这一行，「完成」点下去只在日志里留一行，界面上一个字都不解释（4.1.0 踩过）
    func testBlockedByTheHotkeyPointsBackAtTheFirstScreen() {
        let reason = OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(hotkeyConfirmed: false, microphone: true,
                               accessibility: true, modelReady: true))
        XCTAssertEqual(reason, OnboardingCopy.confirmHotkeyFirst)
    }

    /// 权限缺一项就说权限。模型那一件**不在这里说**：那一页早有自己的一行 + 一颗「下载模型」，
    /// 说第二遍只会让人以为是两件不同的事
    func testBlockedByPermissionsAndNeverByTheModel() {
        XCTAssertEqual(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(hotkeyConfirmed: true, microphone: false,
                               accessibility: true, modelReady: true)),
                       OnboardingCopy.permissionsStillMissing)
        XCTAssertEqual(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(hotkeyConfirmed: true, microphone: true,
                               accessibility: false, modelReady: true)),
                       OnboardingCopy.permissionsStillMissing)
        XCTAssertNil(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(hotkeyConfirmed: true, microphone: true,
                               accessibility: true, modelReady: false)))
    }

    /// 顺序 = 引导的顺序：先说最靠前那一件没办完的事（和 firstIncompletePage 同一条链）
    func testBlockedReasonFollowsTheGuideOrder() {
        XCTAssertEqual(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(hotkeyConfirmed: false, microphone: false,
                               accessibility: false, modelReady: false)),
                       OnboardingCopy.confirmHotkeyFirst)
    }

    // MARK: - 权限页开头那两句

    /// 「正在后台下载」只有真的在下的时候才说。选了云端识别、取消过、失败过的人看到的
    /// 下一行正写着「已取消」——上面压一句"已经在后台下载"就是当面说假话
    func testPermissionsIntroOnlyClaimsADownloadThatIsRunning() {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            let idle = OnboardingCopy.permissionsIntro(modelDownloading: false)
            let running = OnboardingCopy.permissionsIntro(modelDownloading: true)
            XCTAssertTrue(running.hasPrefix(idle), running)
            XCTAssertGreaterThan(running.count, idle.count)
        }
        L10n.shared.language = .zh
        XCTAssertFalse(OnboardingCopy.permissionsIntro(modelDownloading: false).contains("下载"))
        XCTAssertTrue(OnboardingCopy.permissionsIntro(modelDownloading: true).contains("下载"))
        L10n.shared.language = .en
        XCTAssertFalse(OnboardingCopy.permissionsIntro(modelDownloading: false)
                        .lowercased().contains("download"))
        XCTAssertTrue(OnboardingCopy.permissionsIntro(modelDownloading: true)
                        .lowercased().contains("download"))
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
