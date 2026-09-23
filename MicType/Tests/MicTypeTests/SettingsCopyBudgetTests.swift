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

    /// 页面开头那一整句走的是另一条线（中文 ≤ 60 字 / 英文 ≤ 200）：它回答的是
    /// "这一页是干什么的"，装不进 16 字，而硬压成 16 字只会得到一句谁也看不懂的口号。
    /// 和引导里那些整句说明同一条线（OnboardingCopy.paragraphs）。
    func testPageIntrosUseTheParagraphBudget() {
        L10n.shared.language = .zh
        for line in SettingsCopy.pageIntros {
            XCTAssertFalse(line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(line.contains("\n"), "开场白也只有一段：\(line)")
            XCTAssertLessThanOrEqual(line.count, 60, "页面开场白超预算（中文 ≤ 60 字）：\(line)")
            // 它不该混进控件说明那张表：混进去就会被 16 字那条线拦下，然后被压成口号
            XCTAssertFalse(SettingsCopy.allCaptions.contains(line), line)
        }
        L10n.shared.language = .en
        for line in SettingsCopy.pageIntros {
            XCTAssertLessThanOrEqual(line.count, 200, line)
            XCTAssertFalse(CJKSourceScanner.containsFlagged(line), line)
        }
    }

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
            ("写作偏好", SettingsCopy.writingCaptions),
            ("设置", SettingsCopy.cloudCaptions),
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

    // 模型目录那条说明的预算测试随目录一起删掉（5.0.0）：没有本机模型了。

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

    /// 5.0.0：「词汇表」与「自定义规则」搬去了自己的「写作偏好」页，那两颗 ⓘ 也跟着记在那里。
    /// 说明**必须和控件在同一页**——留在旧页的预算表里，那一页就能在没人察觉的情况下
    /// 再长出两段字来，而这条预算量的正是"一页一共说了多少"。
    func testMovedCopyIsBudgetedOnThePageThatShowsIt() {
        XCTAssertTrue(SettingsCopy.writingInfos.contains(SettingsCopy.vocabularyInfo))
        XCTAssertTrue(SettingsCopy.writingInfos.contains(SettingsCopy.customRulesInfo))
        XCTAssertFalse(SettingsCopy.cloudInfos.contains(SettingsCopy.customRulesInfo))

        XCTAssertTrue(SettingsCopy.writingCaptions.contains(SettingsCopy.vocabularyHardReplace))
        XCTAssertTrue(SettingsCopy.writingCaptions.contains(SettingsCopy.customRulesPlaceholder))
        XCTAssertFalse(SettingsCopy.cloudCaptions.contains(SettingsCopy.customRulesPlaceholder))
    }

    /// 选择器下面那行「预览中」必须点名**正在生效**的那一家：预览的这一刻
    /// 「正在使用 ✓」恰好不在屏幕上，而"现在真正在用哪一家"正是这一版要解决的问题
    func testPreviewHintNamesTheProviderStillInUse() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertTrue(SettingsCopy.providerNotSetUp(current: "OpenAI").contains("OpenAI"),
                          SettingsCopy.providerNotSetUp(current: "OpenAI"))
        }
    }

    // 联网搜索那颗 ⓘ 的预算测试随那个开关一起删掉（5.0.0）。

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

    // MARK: - 云端识别的代价

    // 「识别也用云端」那颗 ⓘ 的预算测试随那个开关一起删掉（5.0.0）：
    // 两家的计费与留存口径现在由 PrivacyCopyTests 钉着。

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

    /// Key 那颗 ⓘ 必须逐字引用 LLMCatalog 的存储与费用两句（全 App 唯一出处），
    /// 而且阿里云那一档多说一句"接入地址去哪儿找"——那一栏自己没有 ⓘ。
    ///
    /// 4.3.2 起费用那句只住在这颗 ⓘ 里（原来它常驻在输入框下面），所以这条测试
    /// 同时是"它没被漏掉"的保险。
    func testKeyInfoQuotesTheSingleSource() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            let base = SettingsCopy.keyInfo(hostField: false)
            XCTAssertTrue(base.contains(LLMCatalog.keyStorageNote), base)
            XCTAssertTrue(base.contains(LLMCatalog.billingNote), base)
            let withHost = SettingsCopy.keyInfo(hostField: true)
            XCTAssertGreaterThan(withHost.count, base.count)
            XCTAssertTrue(withHost.lowercased().contains("api host"), withHost)
        }
    }

    /// 这一页只剩一颗 ⓘ（5.0.0：整页只有服务商 / Key / 接入地址三行）。
    /// 这里钉的是"没人再把 ⓘ 悄悄加回来"。
    func testCloudPageKeepsOnlyOneInfoPopover() {
        // 5.0.0 起整页只有一颗 ⓘ：API Key（阿里云那一档多一句"接入地址在哪儿找"，所以是两份文案）
        XCTAssertEqual(SettingsCopy.cloudInfos.count, 2, "\(SettingsCopy.cloudInfos)")
    }

    // MARK: - 隐私文案只在关于页出现

    /// 「音频不出机 / 只发文字 / 不留存 / Key 在钥匙串 / 费用直付 / 搜索计费」这六句是
    /// **关于页**的内容，别处一句都不复述。一旦开始在各处复述就会出现两个问题：
    /// 同一个承诺有了第二种措辞（改一处漏一处就自相矛盾），以及每天被读一百遍。
    ///
    /// 5.0.1 起引导第一屏那一句也没了（用户 2026-09-22 拍板：那一屏只教两个手势）——
    /// 所以这里数的是 0，而不是 1。
    ///
    /// 扫描器按"去掉注释之后还提不提 PrivacyCopy."判——注释里提它是好事（指路），
    /// 真正要拦的是渲染它。
    func testPrivacyCopyIsOnlyRenderedInAbout() throws {
        let dir = Self.sourcesDirectory
        let files = Self.swiftFiles(under: dir)
        XCTAssertGreaterThan(files.count, 10, "源码目录没找对")

        // AboutPanel 住在 SettingsEditors.swift 里
        let allowed: Set<String> = ["PrivacyCopy.swift", "SettingsEditors.swift"]
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
            隐私与费用文案只该出现在关于页，这几处在复述它：\(offenders.joined(separator: "、"))
            —— 某个具体选择的代价，写在做那个选择的地方（例如 SettingsCopy.cloudRecognitionInfo）。
            """)
        XCTAssertEqual(onboardingReferences, 0,
                       "引导里一句隐私文案都不留（5.0.1），现在有 \(onboardingReferences) 处")
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

    /// **段标题不许和它下面那一行的栏名说同一件事**（用户 2026-09-22 点名的"冗余"）。
    ///
    /// 4.3.1 的三页上到处是这种一模一样的两行：段标题「麦克风 ⓘ」下面第一行栏名
    /// 又是「麦克风：」，「识别语言」「识别模型」「快捷键」「服务商」「模型」全都如此。
    /// 收掉之后最容易复发的就是它——下一次加一段，顺手又写一个同名的帽子。
    ///
    /// 扫的是源码：把 `SectionHeader(title: tr("X", …)` 与 `SettingsFieldRow(label: tr("X", …)`
    /// 两串里的中文抠出来，取交集。**数据断言做不到**：栏名与段标题都活在视图代码里，
    /// 不在 SettingsCopy 那张表上（它们是控件的名字，不是说明）。
    func testNoSectionTitleRepeatsTheFieldLabelBelowIt() throws {
        let dir = Self.sourcesDirectory
        // 「X：」和「X」算同一个名字：4.3.2 之前正是靠那个冒号看着像两样东西
        func normalized(_ raw: String) -> String {
            raw.trimmingCharacters(in: CharacterSet(charactersIn: "：: "))
        }
        func zhLiterals(_ source: String, after marker: String) -> Set<String> {
            var out = Set<String>()
            for chunk in source.components(separatedBy: marker).dropFirst() {
                // 形如 `tr("中", "EN")` 或直接一个字面量
                guard let open = chunk.firstIndex(of: "\"") else { continue }
                let rest = chunk[chunk.index(after: open)...]
                guard let close = rest.firstIndex(of: "\"") else { continue }
                let literal = normalized(String(rest[rest.startIndex..<close]))
                if !literal.isEmpty { out.insert(literal) }
            }
            return out
        }
        var offenders: [String] = []
        var allTitles = Set<String>()
        var allLabels = Set<String>()
        for file in Self.swiftFiles(under: dir) {
            let source = Self.stripComments(
                try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8))
            let titles = zhLiterals(source, after: "SectionHeader(title: ")
            let labels = zhLiterals(source, after: "SettingsFieldRow(label: ")
                .union(zhLiterals(source, after: "SettingsToggleRow(label: "))
            allTitles.formUnion(titles)
            allLabels.formUnion(labels)
            for shared in titles.intersection(labels).sorted() {
                offenders.append("\(file): 「\(shared)」")
            }
        }
        // 扫不到东西的话上面那个交集永远是空的，这条测试就成了摆设——先证明它有活干
        // 5.0.0 之后整个设置窗口只剩两个段标题（词汇表 / 自定义规则，都在写作偏好那一页）
        // ——门槛跟着降；再低就说明抓取方式坏了，而不是界面又简化了
        XCTAssertGreaterThanOrEqual(allTitles.count, 2, "没扫到段标题，抓取方式该修了")
        XCTAssertGreaterThan(allLabels.count, 2, "没扫到栏名，抓取方式该修了")
        XCTAssertTrue(offenders.isEmpty, """
            段标题和它下面那一行的栏名逐字相同：\(offenders.joined(separator: "、"))
            —— 删掉段标题，把它那颗 ⓘ 搬到那一行的右端（4.3.2 的版式）。
            """)
    }

    /// 关于页仍然逐句摆着那几句——这条是上面那条的反面：收口不能收成"哪儿都不说了"。
    /// 5.0.0 起是八句（多了「听写历史只在本机」那一条：别的东西都上云之后，
    /// 用户很容易以为历史也跟着上去了）
    func testAboutPanelStillRendersEveryPrivacyLine() throws {
        let source = try String(contentsOf: Self.sourcesDirectory.appendingPathComponent("SettingsEditors.swift"),
                                encoding: .utf8)
        XCTAssertTrue(Self.stripComments(source).contains("PrivacyCopy.allLines"),
                      "关于页必须仍然把隐私文案逐句摆出来")
        XCTAssertEqual(PrivacyCopy.allLines.count, 8)
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
