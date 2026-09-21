import XCTest
@testable import MicType

/// Plan C 的文案预算（用户 2026-09-20 拍板）：**这条测试就是那条预算本身**。
///
/// 为什么非得是测试而不是一条约定：4.0.1 的设置页不是某一句写长了，而是每一次改动都顺手
/// 多挂一行解释，谁也没觉得自己是"那一句"——半年下来控件被挤到第三屏。人眼 review 挡不住
/// 这种一次加一行的漂移，所以把数字写死：
///   • 控件下面那一行：中文 ≤ 16 字，英文 ≤ 60 字符，且**不许换行**（换行就是一段话了）；
///   • 段头那颗 ⓘ：中文 ≤ 120 字（气泡是给人点开读一次的，不是收容所）；
///   • 单个编辑页的说明合计：中文 ≤ 200 字；
///   • 边界状态：一行结论（中文 ≤ 34 字）+ 一颗按钮，永远不写成一段话。
///
/// 这条测试红了**就去改文案**，不要往白名单里加——白名单一开，预算就没了。
final class SettingsCopyBudgetTests: XCTestCase {

    private var savedLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: - 预算

    private static let captionZhLimit = 16
    private static let captionEnLimit = 60
    private static let infoZhLimit = 120
    private static let editorZhLimit = 200
    private static let boundaryZhLimit = 34

    func testEveryCaptionFitsOneLine() {
        L10n.shared.language = .zh
        for caption in SettingsCopy.allCaptions {
            XCTAssertFalse(caption.isEmpty)
            XCTAssertLessThanOrEqual(caption.count, Self.captionZhLimit,
                                     "控件说明超预算（中文 ≤ \(Self.captionZhLimit) 字）：\(caption)")
            XCTAssertFalse(caption.contains("\n"), "控件说明只有一行，不许换行：\(caption)")
        }
        L10n.shared.language = .en
        for caption in SettingsCopy.allCaptions {
            XCTAssertFalse(caption.isEmpty)
            XCTAssertLessThanOrEqual(caption.count, Self.captionEnLimit,
                                     "English caption is over budget (\(Self.captionEnLimit)): \(caption)")
            XCTAssertFalse(caption.contains("\n"), caption)
        }
    }

    /// 细则收进 ⓘ 是有代价的：点开的人要一口气读完。超了就是把设置页的毛病搬进了气泡里
    func testEveryInfoPopoverFitsInOneRead() {
        L10n.shared.language = .zh
        for info in SettingsCopy.allInfos {
            XCTAssertFalse(info.isEmpty)
            XCTAssertLessThanOrEqual(info.count, Self.infoZhLimit,
                                     "ⓘ 超预算（中文 ≤ \(Self.infoZhLimit) 字，现在 \(info.count)）：\(info)")
        }
    }

    /// 一页说了多少字，是这次改版真正要管住的那个数——单条都合规、加起来仍然是一堵墙
    func testEachEditorStaysUnderItsPageBudget() {
        L10n.shared.language = .zh
        let pages: [(String, [String])] = [
            ("输入", SettingsCopy.inputCaptions),
            ("本地识别", SettingsCopy.recognitionCaptions),
            ("云端 AI", SettingsCopy.cloudCaptions),
            // 首启动引导走同一条线，而且该更紧：第一次打开 MicType 的人最没耐心读字
            ("引导", OnboardingCopy.captions),
        ]
        for (name, captions) in pages {
            let total = captions.reduce(0) { $0 + $1.count }
            XCTAssertLessThanOrEqual(total, Self.editorZhLimit,
                                     "「\(name)」页的说明合计 \(total) 字，超了 \(Self.editorZhLimit)")
        }
    }

    /// 边界状态：一行结论 + 一颗按钮。写成一段话的那一刻，用户就不读它了
    func testBoundaryLinesStayOneLine() {
        L10n.shared.language = .zh
        for line in SettingsCopy.boundaryLines {
            XCTAssertFalse(line.isEmpty)
            XCTAssertFalse(line.contains("\n"), "边界状态只有一行：\(line)")
            XCTAssertLessThanOrEqual(line.count, Self.boundaryZhLimit,
                                     "边界状态写成了一段话（中文 ≤ \(Self.boundaryZhLimit) 字）：\(line)")
        }
    }

    /// 渲染层要照同一条线截断远端目录里那行说明，所以那个数字必须就是这里的数字
    func testTheRenderedCaptionLimitIsThisBudget() {
        L10n.shared.language = .zh
        XCTAssertEqual(SettingsCopy.captionLimit, Self.captionZhLimit)
        L10n.shared.language = .en
        XCTAssertEqual(SettingsCopy.captionLimit, Self.captionEnLimit)
    }

    /// 模型目录那一行说明直接渲染在选择器下面，所以内置那几条同样要过这条线。
    /// （目录是远端可更新的，线上发一条长的我们拦不住——那一头由渲染时的截断兜着。）
    func testModelCatalogNotesFitTheCaptionBudget() {
        // 量的是**代码里那张字面表**（内置目录）：缓存下来的远端目录不进单测，
        // 否则这条线量的是这台机器上碰巧缓存了什么
        L10n.shared.language = .zh
        for model in ModelCatalog.builtIn.models {
            let note = model.languagesNote.localized
            XCTAssertFalse(note.contains("\n"), note)
            XCTAssertLessThanOrEqual(note.count, Self.captionZhLimit,
                                     "模型目录那一行超预算：\(model.repo) \(note)")
        }
        L10n.shared.language = .en
        for model in ModelCatalog.builtIn.models {
            let note = model.languagesNote.localized
            XCTAssertLessThanOrEqual(note.count, Self.captionEnLimit, note)
            XCTAssertFalse(CJKSourceScanner.containsFlagged(note), note)
        }
    }

    /// 价格那几句不进 captions 表（它们是代价不是解释），但**仍然只有一行**：
    /// 开关旁边一行价钱换了行，下面所有控件都得往下挪一格
    func testPriceNotesStayOnOneLine() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            for note in [LLMCatalog.webSearchPriceNote, LLMCatalog.providerBilledSearchNote,
                         LLMCatalog.fastTierPriceNote, LLMCatalog.billingNote] {
                XCTAssertFalse(note.isEmpty)
                XCTAssertFalse(note.contains("\n"), note)
            }
        }
    }

    // MARK: - 说的话和代码做的事对得上

    /// 云端识别开着的时候，「使用方式」下面那一行**绝不能**还写着"本机识别"。
    /// AISetup.mode 把"引擎是云端"也算成「本地 + AI」，所以只看档位选文案，正好会在
    /// 每段录音都在上传的那一刻说反话——这是这条测试唯一要拦的东西。
    func testUsageCaptionFollowsTheEngineNotJustTheMode() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertEqual(SettingsCopy.usageCaption(mode: .localOnly, engine: .local),
                           SettingsCopy.usageLocalOnly)
            // 「只用本地」这一档本来就不可能是云端引擎，真出现了也仍然只说这一句
            XCTAssertEqual(SettingsCopy.usageCaption(mode: .withAI, engine: .local),
                           SettingsCopy.usageWithAI)
            for engine in RecognitionEngineChoice.allCases where engine.isCloud {
                let caption = SettingsCopy.usageCaption(mode: .withAI, engine: engine)
                XCTAssertEqual(caption, SettingsCopy.usageWithCloudRecognition, caption)
                XCTAssertNotEqual(caption, SettingsCopy.usageWithAI)
            }
        }
        L10n.shared.language = .zh
        XCTAssertFalse(SettingsCopy.usageWithCloudRecognition.contains("本机"),
                       SettingsCopy.usageWithCloudRecognition)
        L10n.shared.language = .en
        XCTAssertFalse(SettingsCopy.usageWithCloudRecognition.lowercased().contains("on this mac"),
                       SettingsCopy.usageWithCloudRecognition)
    }

    /// 「只用本地」写回的只有"润色关掉 + 识别回本机"，**钥匙串里那把 Key 不动**，
    /// 而指令路径只看 LLMClient.isConfigured——所以这一档下按住说指令照样会计费。
    /// 边界那一行（storedKeyWhileLocalOnly）说的就是这件事，ⓘ 不许在隔壁说反话。
    func testUsageInfoDoesNotContradictTheStoredKeyNotice() {
        L10n.shared.language = .zh
        XCTAssertFalse(SettingsCopy.usageInfo.contains("那一档没有"), SettingsCopy.usageInfo)
        XCTAssertTrue(SettingsCopy.usageInfo.contains("按住说指令仍然要有 Key"), SettingsCopy.usageInfo)
        XCTAssertTrue(SettingsCopy.storedKeyWhileLocalOnly(provider: "OpenAI").contains("计费"))

        L10n.shared.language = .en
        let en = SettingsCopy.usageInfo.lowercased()
        XCTAssertFalse(en.contains("not available"), SettingsCopy.usageInfo)
        XCTAssertTrue(en.contains("still needs a key"), SettingsCopy.usageInfo)
    }

    /// 「自定义规则」那颗 ⓘ 讲的是**数据流向**，写错就是告诉用户每一次轻点都在把个人信息
    /// 发出去。4.1.1 起只有一个框（「关于我」已经并进来了），所以这里也不许再提第二个框。
    func testCustomRulesInfoMatchesWhereTheTextActuallyGoes() {
        L10n.shared.language = .zh
        let zh = SettingsCopy.customRulesInfo
        XCTAssertTrue(zh.contains("润色") && zh.contains("指令"), zh)
        // 界面上已经没有这个框了，ⓘ 里再点它的名字就是指着一个不存在的控件
        XCTAssertFalse(zh.contains("关于我"), zh)
        XCTAssertFalse(zh.contains("两个框"), zh)

        L10n.shared.language = .en
        let en = SettingsCopy.customRulesInfo.lowercased()
        XCTAssertTrue(en.contains("polish") && en.contains("command"), en)
        XCTAssertFalse(en.contains("about me"), en)
        XCTAssertFalse(en.contains("both boxes"), en)
    }

    /// 4.1.6：「自定义规则」和「词汇表」搬去了「输入」页，那两颗 ⓘ 也跟着记在那一页头上。
    /// 说明**必须和控件在同一页**——留在旧页的预算表里，那一页就能在没人察觉的情况下
    /// 再长出两段字来，而这条预算量的正是"一页一共说了多少"。
    func testMovedCopyIsBudgetedOnThePageThatShowsIt() {
        XCTAssertTrue(SettingsCopy.inputInfos.contains(SettingsCopy.vocabularyInfo))
        XCTAssertTrue(SettingsCopy.inputInfos.contains(SettingsCopy.customRulesInfo))
        XCTAssertFalse(SettingsCopy.recognitionInfos.contains(SettingsCopy.vocabularyInfo))
        XCTAssertFalse(SettingsCopy.cloudInfos.contains(SettingsCopy.customRulesInfo))

        XCTAssertTrue(SettingsCopy.inputCaptions.contains(SettingsCopy.vocabularyArabicTip))
        XCTAssertTrue(SettingsCopy.inputCaptions.contains(SettingsCopy.customRulesPlaceholder))
        XCTAssertTrue(SettingsCopy.inputCaptions.contains(SettingsCopy.rulesNeedAI))
        XCTAssertFalse(SettingsCopy.recognitionCaptions.contains(SettingsCopy.vocabularyArabicTip))
        XCTAssertFalse(SettingsCopy.cloudCaptions.contains(SettingsCopy.customRulesPlaceholder))
    }

    /// 「模型」那颗 ⓘ 只许指屏幕上**真有**的控件：三家官方档的「高级」里只剩「测试模型」，
    /// 「刷新模型列表」只长在没有内置清单的那两档上（SettingsEditors.modelMaintenance）。
    /// 指一个不存在的按钮，用户会以为界面少了东西。
    func testModelInfoOnlyPointsAtControlsThatExist() {
        for provider in LLMProvider.allCases where !LLMCatalog.modelMenu(for: provider).isEmpty {
            L10n.shared.language = .zh
            XCTAssertFalse(SettingsCopy.cloudModelInfo(provider: provider).contains("刷新"),
                           provider.rawValue)
            L10n.shared.language = .en
            XCTAssertFalse(SettingsCopy.cloudModelInfo(provider: provider)
                            .lowercased().contains("refresh"), provider.rawValue)
        }
        // 那两档反过来：它们的「高级」里真有那颗按钮，ⓘ 该说
        for provider in [LLMProvider.custom, .local] {
            L10n.shared.language = .zh
            XCTAssertTrue(SettingsCopy.cloudModelInfo(provider: provider).contains("刷新"),
                          provider.rawValue)
        }
    }

    /// 选择器下面那行「预览中」必须点名**正在生效**的那一家：预览的这一刻
    /// 「正在使用 ✓」恰好不在屏幕上，而"现在真正在用哪一家"正是这一版要解决的问题
    func testPreviewHintNamesTheProviderStillInUse() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertTrue(SettingsCopy.providerNotSetUp(current: "DeepSeek").contains("DeepSeek"),
                          SettingsCopy.providerNotSetUp(current: "DeepSeek"))
        }
    }

    /// 联网搜索那颗 ⓘ 只说这个开关管到哪儿；**单价不许搬进来**——价格是代价不是解释，
    /// 它的唯一出处是 LLMCatalog，摆在开关旁边
    func testWebSearchInfoDoesNotRestateThePrice() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertFalse(SettingsCopy.webSearchInfo.contains("0.01"), SettingsCopy.webSearchInfo)
            XCTAssertFalse(SettingsCopy.webSearchInfo.contains(LLMCatalog.webSearchPriceNote),
                           SettingsCopy.webSearchInfo)
        }
    }

    // MARK: - 两种语言

    func testEnglishSideHasNoCJK() {
        L10n.shared.language = .en
        for text in SettingsCopy.allCaptions + SettingsCopy.allInfos + SettingsCopy.boundaryLines {
            XCTAssertFalse(CJKSourceScanner.containsFlagged(text),
                           "英文界面的设置文案混进了中文/全角标点：\(text)")
        }
    }

    /// 漏写一侧的典型表现：两种语言拿到同一串
    func testCopyActuallyDiffersBetweenLanguages() {
        L10n.shared.language = .zh
        let zh = SettingsCopy.allCaptions + SettingsCopy.boundaryLines
        L10n.shared.language = .en
        let en = SettingsCopy.allCaptions + SettingsCopy.boundaryLines
        for (a, b) in zip(zh, en) {
            XCTAssertNotEqual(a, b, "这一句没走 tr()：\(a)")
        }
    }

    /// 同一句话在两个控件下面出现两次，就是"同一个事实写了两处"的开始
    func testCaptionsAreNotDuplicated() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            let captions = SettingsCopy.allCaptions
            XCTAssertEqual(Set(captions).count, captions.count, "\(language) 下有重复的控件说明")
        }
    }

    // MARK: - 云端识别的代价说全了没有

    /// 这颗 ⓘ 是用户点下「识别也用云端」之前唯一能读到的代价说明。
    /// 每一家都要说全：音频会上传、怎么计费、出错会回落本机。
    func testCloudRecognitionInfoStatesEveryCost() {
        L10n.shared.language = .zh
        for provider in CloudASRProvider.allCases {
            let zh = SettingsCopy.cloudRecognitionInfo(provider: provider)
            XCTAssertTrue(zh.contains("传给"), zh)
            XCTAssertTrue(zh.contains("计费"), zh)
            XCTAssertTrue(zh.contains("本机"), zh)
        }
        // 阿里云那一档还要提醒"先去控制台开通一次模型"
        XCTAssertTrue(SettingsCopy.cloudRecognitionInfo(provider: .alibaba).contains("开通"))
        // OpenAI 那一档必须点名它贵得多——两家差着近八倍，这是选择的一部分
        XCTAssertTrue(SettingsCopy.cloudRecognitionInfo(provider: .openai).contains("数倍"))

        L10n.shared.language = .en
        for provider in CloudASRProvider.allCases {
            let en = SettingsCopy.cloudRecognitionInfo(provider: provider).lowercased()
            XCTAssertTrue(en.contains("streams to"), en)
            XCTAssertTrue(en.contains("billed"), en)
            XCTAssertTrue(en.contains("on this mac"), en)
        }
        XCTAssertTrue(SettingsCopy.cloudRecognitionInfo(provider: .alibaba)
            .lowercased().contains("enable the model"))
        XCTAssertTrue(SettingsCopy.cloudRecognitionInfo(provider: .openai)
            .lowercased().contains("several times"))
    }

    /// 云端识别的单价**只有一个出处**（LLMCatalog.cloudASRPriceNote），而且必须摆在
    /// 开关旁边而不是 ⓘ 里：两家差着近八倍，那是选择本身的一部分
    func testCloudASRPriceHasASingleSource() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            for provider in CloudASRProvider.allCases {
                let note = LLMCatalog.cloudASRPriceNote(provider: provider)
                XCTAssertFalse(note.isEmpty)
                XCTAssertTrue(note.contains("$"), note)
                XCTAssertFalse(CJKSourceScanner.containsFlagged(
                    LLMCatalog.cloudASRPriceNote(provider: provider)) && language == .en, note)
            }
            XCTAssertNotEqual(LLMCatalog.cloudASRPriceNote(provider: .alibaba),
                              LLMCatalog.cloudASRPriceNote(provider: .openai))
        }
    }

    /// Key 那颗 ⓘ 必须逐字引用 LLMCatalog 的存储说明（全 App 唯一出处），
    /// 而且开着云端识别时多说一句"这把 Key 走的是识别端点"
    func testKeyInfoQuotesTheSingleSource() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertTrue(SettingsCopy.keyInfo(cloudASRProbe: false).contains(LLMCatalog.keyStorageNote))
            XCTAssertTrue(SettingsCopy.keyInfo(cloudASRProbe: false).contains(LLMCatalog.newAccountNote))
            XCTAssertGreaterThan(SettingsCopy.keyInfo(cloudASRProbe: true).count,
                                 SettingsCopy.keyInfo(cloudASRProbe: false).count)
        }
    }

    // MARK: - 隐私文案只在关于页与引导页出现

    /// 「音频不出机 / 只发文字 / 不留存 / Key 在钥匙串 / 费用直付 / 搜索计费」这六句是
    /// **关于页**的内容，外加引导第一屏那一句。它们一旦开始在设置页各处复述，就会出现
    /// 两个问题：同一个承诺有了第二种措辞（改一处漏一处就自相矛盾），以及每天被读一百遍。
    ///
    /// 扫描器按"去掉注释之后还提不提 PrivacyCopy."判——注释里提它是好事（指路），
    /// 真正要拦的是渲染它。
    func testPrivacyCopyIsOnlyRenderedInAboutAndOnboarding() throws {
        let dir = Self.sourcesDirectory
        let files = Self.swiftFiles(under: dir)
        XCTAssertGreaterThan(files.count, 10, "源码目录没找对")

        // AboutPanel 住在 SettingsEditors.swift 里；引导第一屏住在 OnboardingWindow.swift
        let allowed: Set<String> = ["PrivacyCopy.swift", "SettingsEditors.swift", "OnboardingWindow.swift"]
        var offenders: [String] = []
        var onboardingReferences = 0
        for file in files {
            let source = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            let count = Self.referenceCount(to: "PrivacyCopy", in: source)
            guard count > 0 else { continue }
            if !allowed.contains(file) {
                offenders.append("\(file)（\(count) 处）")
            }
            if file == "OnboardingWindow.swift" { onboardingReferences = count }
        }
        XCTAssertTrue(offenders.isEmpty, """
            隐私与费用文案只该出现在关于页和引导第一屏，这几处在复述它：\(offenders.joined(separator: "、"))
            —— 某个具体选择的代价，写在做那个选择的地方（例如 SettingsCopy.cloudRecognitionInfo）。
            """)
        XCTAssertEqual(onboardingReferences, 1,
                       "引导里只留一句隐私文案（第一屏的数据流向），现在有 \(onboardingReferences) 处")
    }

    /// 引导里那句隐私承诺只有第一屏那一条（PrivacyCopy.audioStaysLocal），而且它写清了边界：
    /// 只有选了云端引擎才上传。上面那条测试只数 `PrivacyCopy.` 出现了几次，所以**换个说法**
    /// 复述同一句承诺它一个都拦不住——4.1.0 之前权限页就写着"识别过程不联网"，
    /// 而那一页可以从第三屏（摆着「识别也用云端」开关）点「上一步」回来。
    func testOnboardingDoesNotParaphraseThePrivacyPromise() throws {
        let source = try String(contentsOf: Self.sourcesDirectory
                                    .appendingPathComponent("OnboardingWindow.swift"),
                                encoding: .utf8)
        let code = Self.stripComments(source)
        // 只拦"无条件的本机承诺"这一类说法。"这台 Mac 上跑"这种讲清楚了边界的句子不在此列
        for phrase in ["不联网", "识别全在本机", "no network", "recognized on this Mac"] {
            XCTAssertFalse(code.contains(phrase), """
                引导里换了个说法复述隐私承诺：\(phrase)
                —— 默认那一档的承诺只写第一屏那一句（PrivacyCopy.audioStaysLocal），
                它把"选了云端引擎才上传"这条边界也写清了；这里复述一遍就会在云端档下变成假话。
                """)
        }
    }

    /// `Caption` 收什么字都行，于是"顺手在视图里写一句说明"永远是最省事的写法——
    /// 而那一句谁也量不到。4.1.0 之前正是这样漏掉了好几行。
    /// 文案要么住在 SettingsCopy / OnboardingCopy（被上面那几条逐条量），要么是价格、
    /// 是一次性状态快照；**就地现写一句**这条路直接堵掉。
    func testNoAdHocCaptionLiteralsOutsideTheCopyTables() throws {
        let dir = Self.sourcesDirectory
        var offenders: [String] = []
        for file in Self.swiftFiles(under: dir) {
            let source = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            let count = Self.stripComments(source).components(separatedBy: "Caption(tr(").count - 1
            if count > 0 { offenders.append("\(file)（\(count) 处）") }
        }
        XCTAssertTrue(offenders.isEmpty, """
            这几处直接把字面量塞进了 Caption，没有任何预算量得到它：\(offenders.joined(separator: "、"))
            —— 一行说明请写进 SettingsCopy / OnboardingCopy。
            """)
    }

    /// 关于页仍然逐句摆着那几句——这条是上面那条的反面：收口不能收成"哪儿都不说了"。
    /// 4.1.6 起是七句（多了 Fast 档那一条：界面上已经没有那个开关，多花的钱只剩这一处写着）
    func testAboutPanelStillRendersEveryPrivacyLine() throws {
        let source = try String(contentsOf: Self.sourcesDirectory.appendingPathComponent("SettingsEditors.swift"),
                                encoding: .utf8)
        XCTAssertTrue(Self.stripComments(source).contains("PrivacyCopy.allLines"),
                      "关于页必须仍然把隐私文案逐句摆出来")
        XCTAssertEqual(PrivacyCopy.allLines.count, 7)
    }

    // MARK: - 工具

    /// 去掉注释之后，`Name.` 出现了几次
    private static func referenceCount(to name: String, in source: String) -> Int {
        let stripped = stripComments(source)
        return stripped.components(separatedBy: "\(name).").count - 1
    }

    /// 极简注释剥离：先去块注释，再去每行的 `//` 之后（字符串里出现 `//` 的情况本项目没有，
    /// 真出现了也只会让这条测试更严格，不会放行）
    static func stripComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") {
                    inBlock = false
                    index = source.index(index, offsetBy: 2)
                    continue
                }
                index = source.index(after: index)
                continue
            }
            if rest.hasPrefix("/*") {
                inBlock = true
                index = source.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }

    static func swiftFiles(under dir: URL) -> [String] {
        let root = dir.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: dir.standardizedFileURL,
                                                          includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path
            out.append(path.hasPrefix(root) ? String(path.dropFirst(root.count)) : url.lastPathComponent)
        }
        return out.sorted()
    }

    static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MicType", isDirectory: true)
    }
}
