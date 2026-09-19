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
    /// 四件事一件都不能少：音频会上传、按秒计费、要先开通模型、出错会回落本机。
    func testCloudRecognitionInfoStatesEveryCost() {
        L10n.shared.language = .zh
        let zh = SettingsCopy.cloudRecognitionInfo
        XCTAssertTrue(zh.contains("上传"), zh)
        XCTAssertTrue(zh.contains("计费"), zh)
        XCTAssertTrue(zh.contains("开通"), zh)
        XCTAssertTrue(zh.contains("本机"), zh)

        L10n.shared.language = .en
        let en = SettingsCopy.cloudRecognitionInfo.lowercased()
        XCTAssertTrue(en.contains("uploaded"), en)
        XCTAssertTrue(en.contains("billed by the second"), en)
        XCTAssertTrue(en.contains("enable the model"), en)
        XCTAssertTrue(en.contains("on this mac"), en)
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

    /// 关于页仍然逐句摆着那六句——这条是上面那条的反面：收口不能收成"哪儿都不说了"
    func testAboutPanelStillRendersAllSixLines() throws {
        let source = try String(contentsOf: Self.sourcesDirectory.appendingPathComponent("SettingsEditors.swift"),
                                encoding: .utf8)
        XCTAssertTrue(Self.stripComments(source).contains("PrivacyCopy.allLines"),
                      "关于页必须仍然把六句隐私文案逐句摆出来")
        XCTAssertEqual(PrivacyCopy.allLines.count, 6)
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

    private static func swiftFiles(under dir: URL) -> [String] {
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

    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MicType", isDirectory: true)
    }
}
