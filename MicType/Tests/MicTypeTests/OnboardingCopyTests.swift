import XCTest
@testable import MicType

/// 引导三屏（5.3.0）的文案与"配好了没有"的判断。
/// 这一层错了不会崩，但会正正好在第一次打开 MicType 的那一分钟说反话。
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

    /// **三屏**，顺序写死（用户 2026-09-29 拍板，推翻 09-22「五屏」）：
    /// 按住右 Option 说话（含权限）→ 贴上 Key → 试一下。
    func testOnboardingIsThreePagesInOrder() {
        XCTAssertEqual(OnboardingPage.allCases.count, 3)
        XCTAssertEqual(OnboardingPage.hold.rawValue, 0)
        XCTAssertEqual(OnboardingPage.hold.rawValue + 1, OnboardingPage.key.rawValue)
        XCTAssertEqual(OnboardingPage.key.rawValue + 1, OnboardingPage.tryIt.rawValue)
        XCTAssertEqual(OnboardingPage(rawValue: 2), .tryIt)
    }

    /// 三件必办的事的关卡落在 ① ②，**不在最后一屏**：走到「试一下」的人已经被放行过一次了
    func testTheGateSitsBeforeTheLastPage() {
        for page in [FirstRunEssentials(microphone: false, accessibility: true, keyReady: true),
                     FirstRunEssentials(microphone: true, accessibility: true, keyReady: false)]
            .compactMap(\.firstIncompletePage) {
            XCTAssertNotEqual(page, .tryIt, "关卡不许落在最后一屏上")
        }
    }

    /// 判据本身：凭据 + 拼得出来的地址 + 非空型号，三样齐了才算配好
    func testAIStatusNeedsCredentialAndEndpoint() {
        XCTAssertEqual(LLMCatalog.aiStatus(hasCredential: true, baseURL: "https://api.openai.com/v1",
                                           polishModel: "gpt-5.6-luna"), .ready)
        XCTAssertEqual(LLMCatalog.aiStatus(hasCredential: false, baseURL: "https://api.openai.com/v1",
                                           polishModel: "gpt-5.6-luna"), .off)
        XCTAssertEqual(LLMCatalog.aiStatus(hasCredential: true, baseURL: "",
                                           polishModel: "gpt-5.6-luna"), .off)
    }

    // MARK: - ① 按住右 Option (⌥) 说话

    /// 标题就是那个手势，键名写全（任何地方不用「R⌥」缩写），副标题一行说清两种手势
    func testHoldPageNamesTheKeyAndBothGestures() {
        L10n.shared.language = .zh
        XCTAssertTrue(OnboardingCopy.holdTitle.contains("右 Option (⌥)"), OnboardingCopy.holdTitle)
        XCTAssertTrue(OnboardingCopy.holdTitle.contains("按住"), OnboardingCopy.holdTitle)
        XCTAssertTrue(OnboardingCopy.gestureLine.contains("轻点"), OnboardingCopy.gestureLine)
        XCTAssertTrue(OnboardingCopy.gestureLine.contains("按住"), OnboardingCopy.gestureLine)

        L10n.shared.language = .en
        XCTAssertTrue(OnboardingCopy.holdTitle.contains("Right Option (⌥)"), OnboardingCopy.holdTitle)
        XCTAssertTrue(OnboardingCopy.holdTitle.lowercased().hasPrefix("hold"), OnboardingCopy.holdTitle)
        XCTAssertTrue(OnboardingCopy.gestureLine.lowercased().contains("tap"), OnboardingCopy.gestureLine)
    }

    // MARK: - ② 贴上你的 OpenAI Key

    /// 标题**不写「可选」**（5.0.0 起没有 Key 这个产品一件事都干不了），并且点名 OpenAI
    func testKeyTitleIsNotOptionalAndNamesOpenAI() {
        L10n.shared.language = .zh
        XCTAssertFalse(OnboardingCopy.keyTitle.contains("可选"), OnboardingCopy.keyTitle)
        XCTAssertTrue(OnboardingCopy.keyTitle.contains("OpenAI"), OnboardingCopy.keyTitle)
        L10n.shared.language = .en
        XCTAssertFalse(OnboardingCopy.keyTitle.lowercased().contains("optional"), OnboardingCopy.keyTitle)
        XCTAssertTrue(OnboardingCopy.keyTitle.contains("OpenAI"), OnboardingCopy.keyTitle)
    }

    // MARK: - ③ 试一下

    /// 给一句能照着念的话，而且说清是**轻点**
    func testTryItSubtitleGivesALineToSay() {
        L10n.shared.language = .zh
        XCTAssertTrue(OnboardingCopy.trySubtitle.contains("轻点"), OnboardingCopy.trySubtitle)
        XCTAssertTrue(OnboardingCopy.trySubtitle.contains("明天下午三点开会"), OnboardingCopy.trySubtitle)
        L10n.shared.language = .en
        XCTAssertTrue(OnboardingCopy.trySubtitle.lowercased().hasPrefix("tap right option"),
                      OnboardingCopy.trySubtitle)
    }

    /// 字落下来之后那一行回答"它在哪"：Dock 和菜单栏两处都要点名（4.3.5 起两枚图标都在）
    func testThatsItSaysWhereItLives() {
        L10n.shared.language = .zh
        XCTAssertTrue(OnboardingCopy.thatsIt.contains("菜单栏"), OnboardingCopy.thatsIt)
        XCTAssertTrue(OnboardingCopy.thatsIt.contains("Dock"), OnboardingCopy.thatsIt)
        L10n.shared.language = .en
        XCTAssertTrue(OnboardingCopy.thatsIt.lowercased().contains("menu bar"), OnboardingCopy.thatsIt)
        XCTAssertTrue(OnboardingCopy.thatsIt.contains("Dock"), OnboardingCopy.thatsIt)
    }

    /// 登录自启那一行照实写两种状态，而且两种说法不一样
    func testLaunchAtLoginLineHasBothStates() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertNotEqual(OnboardingCopy.launchAtLogin(on: true), OnboardingCopy.launchAtLogin(on: false))
        }
    }

    // MARK: - 出口

    /// 「先跳过」与「听写暂不可用」是**一对**：出口和它的代价必须同时说出来
    func testSkipLinkAndItsConsequenceAreBothSpelledOut() {
        L10n.shared.language = .zh
        XCTAssertEqual(OnboardingCopy.skipForNow, "先跳过")
        XCTAssertEqual(OnboardingCopy.dictationUnavailable, "听写暂不可用")
        XCTAssertEqual(OnboardingCopy.later, "稍后")

        L10n.shared.language = .en
        XCTAssertEqual(OnboardingCopy.skipForNow, "Skip for now")
        XCTAssertEqual(OnboardingCopy.dictationUnavailable, "Dictation will not work yet")
        XCTAssertEqual(OnboardingCopy.later, "Later")
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

    // MARK: - 全部文案

    private var everyLine: [String] {
        [OnboardingCopy.later, OnboardingCopy.continueLabel, OnboardingCopy.backLabel,
         OnboardingCopy.skipForNow, OnboardingCopy.dictationUnavailable,
         OnboardingCopy.permissionsStillMissing,
         OnboardingCopy.holdTitle, OnboardingCopy.gestureLine,
         OnboardingCopy.allowMicrophone, OnboardingCopy.enableAccessibility, OnboardingCopy.openLabel,
         OnboardingCopy.permissionsStuckHint,
         OnboardingCopy.keyTitle, OnboardingCopy.keySubtitle,
         OnboardingCopy.tryTitle, OnboardingCopy.trySubtitle, OnboardingCopy.thatsIt,
         OnboardingCopy.startUsing, OnboardingCopy.launchAtLogin(on: true),
         OnboardingCopy.launchAtLogin(on: false), OnboardingCopy.keyMissingForTryIt]
    }

    /// 英文界面下一个汉字都不许夹
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

    /// Apple 系统提示的口吻（UX 方案 §0 / §3 H）：没有「请」「抱歉」、没有感叹号、没有长破折号
    func testNoPleaseNoSorryNoExclamation() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            for copy in everyLine {
                for banned in ["请", "抱歉", "！", "!", "——", "please", "Please", "sorry", "Sorry"] {
                    XCTAssertFalse(copy.contains(banned), "\(banned) in \(copy)")
                }
            }
        }
    }

    // MARK: - 「开始使用」为什么点不动

    func testNoBlockedReasonWhenEverythingIsDone() {
        XCTAssertNil(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(microphone: true, accessibility: true, keyReady: true)))
    }

    /// 权限缺一项就说权限。Key 那一件**不在这里说**：③ 早有自己那一行（keyMissingForTryIt）
    func testBlockedByPermissionsAndNeverByTheKey() {
        XCTAssertEqual(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(microphone: false, accessibility: true, keyReady: true)),
                       OnboardingCopy.permissionsStillMissing)
        XCTAssertEqual(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(microphone: true, accessibility: false, keyReady: true)),
                       OnboardingCopy.permissionsStillMissing)
        XCTAssertNil(OnboardingCopy.finishBlockedReason(
            FirstRunEssentials(microphone: true, accessibility: true, keyReady: false)))
    }

    // MARK: - 预算

    /// 整句说明（标题、副标题、收尾那一行）：中文 ≤ 60 字、英文 ≤ 200 字符，不写成多段
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

    /// 标题要短：28 pt 的大字在 544 pt 宽的卡片里一行装得下（中文 ≤ 18 字；「按住右 Option (⌥) 说话」17 字）
    func testTitlesFitOnOneLine() {
        L10n.shared.language = .zh
        for title in [OnboardingCopy.holdTitle, OnboardingCopy.keyTitle, OnboardingCopy.tryTitle] {
            XCTAssertLessThanOrEqual(title.count, 18, title)
        }
    }

    func testEveryParagraphIsWrittenInBothLanguages() {
        L10n.shared.language = .zh
        let zh = OnboardingCopy.paragraphs
        L10n.shared.language = .en
        let en = OnboardingCopy.paragraphs
        XCTAssertEqual(zh.count, en.count)
        for (a, b) in zip(zh, en) { XCTAssertNotEqual(a, b, "这一句没走 tr()：\(a)") }
    }

    /// 计入预算的那几行确实被挂进了设置页那张总表——挂漏了，16 字那条线就量不到引导
    func testGuideCaptionsAreCountedByTheCopyBudget() {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            for caption in OnboardingCopy.captions {
                XCTAssertTrue(SettingsCopy.allCaptions.contains(caption), caption)
            }
        }
    }
}
