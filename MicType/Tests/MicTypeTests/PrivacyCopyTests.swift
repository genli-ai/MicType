import XCTest
@testable import MicType

/// 隐私与费用文案：以前关于页与引导页各写一遍，措辞不一致，用户只能猜哪句算数。
/// 现在只有 `PrivacyCopy` 一个出处——这组测试钉住的正是"一处"这件事本身：
/// 句数、顺序、两种语言都不为空、英文侧不许漏中文、两个子集加起来就是全集。
final class PrivacyCopyTests: XCTestCase {

    /// 每个用例前后都要把界面语言放回原样：L10n 是全局单例，改了不还会污染同批次其它测试
    private var savedLanguage: AppLanguage = .zh

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    func testSixSentencesInFixedOrder() {
        XCTAssertEqual(PrivacyCopy.allLines.count, 6)
        // 顺序是文案的一部分：先说数据去了哪，再说钱谁收
        XCTAssertEqual(PrivacyCopy.allLines, PrivacyCopy.dataFlowLines + PrivacyCopy.keyAndCostLines)
        XCTAssertEqual(PrivacyCopy.dataFlowLines.count, 2)
        XCTAssertEqual(PrivacyCopy.keyAndCostLines.count, 4)
    }

    /// 联网搜索的单价只有一个出处：隐私那句必须原样引用 LLMCatalog 的那一句。
    /// 以前两处各写各的价钱，改一次价就会有两句话打架，用户不知道哪句算数。
    func testWebSearchPriceHasASingleSource() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertTrue(PrivacyCopy.webSearchBilled.contains(LLMCatalog.webSearchPriceNote),
                          "\(language) 下隐私文案没有引用 LLMCatalog.webSearchPriceNote")
            // 价钱只出现一次（引用而不是复述）
            XCTAssertEqual(PrivacyCopy.webSearchBilled.components(separatedBy: "10").count - 1,
                           LLMCatalog.webSearchPriceNote.components(separatedBy: "10").count - 1)
        }
    }

    /// Key 怎么存、钱怎么付：关于页那两句和 Key 输入框旁边那两句必须是**同一串**。
    /// 4.1.0 之前是两套各写各的措辞（关于页「不写进文件」vs ⓘ 里「加密、仅本机可读」），
    /// 改一处漏一处就是两句对不上的承诺——而扫描器只数 `PrivacyCopy.`，看不见这种漂移。
    func testKeyAndBillingPromisesHaveASingleSource() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertEqual(PrivacyCopy.keyInKeychain, LLMCatalog.keyStorageNote)
            XCTAssertEqual(PrivacyCopy.youPayProvider, LLMCatalog.billingNote)
        }
    }

    /// 听写历史存哪儿、最多几条：关于页那一句和条数那个常量只有一个出处。
    /// 「输入」页那颗 ⓘ 只说怎么关、怎么清——它再也不自己写一遍条数了
    func testHistoryStorageFactsHaveASingleSource() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertTrue(HistoryStore.storageNote.contains("\(HistoryStore.maxCount)"),
                          HistoryStore.storageNote)
            XCTAssertFalse(SettingsCopy.behaviourInfo.contains("\(HistoryStore.maxCount)"),
                           SettingsCopy.behaviourInfo)
        }
        L10n.shared.language = .zh
        XCTAssertFalse(SettingsCopy.behaviourInfo.contains("从不上传"), SettingsCopy.behaviourInfo)
        L10n.shared.language = .en
        XCTAssertFalse(SettingsCopy.behaviourInfo.lowercased().contains("never uploaded"),
                       SettingsCopy.behaviourInfo)
        XCTAssertFalse(CJKSourceScanner.containsFlagged(HistoryStore.storageNote),
                       HistoryStore.storageNote)
    }

    func testEveryLineIsPresentAndDistinctInBothLanguages() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            let lines = PrivacyCopy.allLines
            for line in lines {
                XCTAssertFalse(line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language) 下有一句隐私文案是空的")
            }
            XCTAssertEqual(Set(lines).count, lines.count,
                           "\(language) 下有两句隐私文案重复——关于页用 ForEach(id: \\.self) 渲染，重复会丢行")
        }
    }

    func testChineseAndEnglishAreActuallyDifferent() {
        L10n.shared.language = .zh
        let zh = PrivacyCopy.allLines
        L10n.shared.language = .en
        let en = PrivacyCopy.allLines
        for (index, pair) in zip(zh, en).enumerated() {
            XCTAssertNotEqual(pair.0, pair.1, "第 \(index + 1) 句没走 tr()，两种语言拿到同一串")
        }
    }

    func testEnglishSideHasNoCJK() {
        L10n.shared.language = .en
        for line in PrivacyCopy.allLines {
            XCTAssertFalse(CJKSourceScanner.containsFlagged(line),
                           "英文界面的隐私文案混进了中文/全角标点：\(line)")
        }
    }

    /// 云端识别那几句 4.0.2 起不在 PrivacyCopy 里：它们搬去了做那个选择的地方
    /// （SettingsCopy.cloudRecognitionInfo，由 SettingsCopyBudgetTests 把四件代价钉死）。
    /// 这里守住"别再搬回来"：这六句讲的是**默认状态**下的承诺，按秒计费、先去控制台开通模型
    /// 这类只有开着那个开关才成立的话，混进来就成了对所有人说的假话。
    func testCloudRecognitionCostDoesNotLiveHere() {
        L10n.shared.language = .zh
        for line in PrivacyCopy.allLines {
            XCTAssertFalse(line.contains("按秒计费"), line)
            XCTAssertFalse(line.contains("开通"), line)
        }
        L10n.shared.language = .en
        for line in PrivacyCopy.allLines {
            XCTAssertFalse(line.lowercased().contains("billed by the second"), line)
            XCTAssertFalse(line.lowercased().contains("enable the model"), line)
        }
        // 反过来，默认那一档必须仍然把"只有选了云端才上传"说清楚——收口不是删掉边界
        L10n.shared.language = .zh
        XCTAssertTrue(PrivacyCopy.audioStaysLocal.contains("云端引擎"))
    }

    /// 六句话各自对应一条能在代码里指出来的行为，关键词漏了就说明句子被改空了
    func testEachClaimKeepsItsKeyword() {
        L10n.shared.language = .en
        // v4.0 起多了一档可选的云端识别：这句话必须同时说清"默认在本机"和"云端才会上传"，
        // 不能再是一句无条件的承诺（那在云端档下不成立）
        XCTAssertTrue(PrivacyCopy.audioStaysLocal.contains("On-device recognition by default"))
        XCTAssertTrue(PrivacyCopy.audioStaysLocal.contains("only if you choose a cloud engine"))
        // 指令模式会把**前台应用的选区原文**发出去（常常不是用户自己说的话），
        // 这句话必须把它点名说出来——以前写的"只有识别出的文字"在主路径上就不成立
        XCTAssertTrue(PrivacyCopy.onlyTextLeaves.lowercased().contains("recognized text"))
        XCTAssertTrue(PrivacyCopy.onlyTextLeaves.lowercased().contains("selected"))
        XCTAssertTrue(PrivacyCopy.onlyTextLeaves.lowercased().contains("vocabulary"))
        XCTAssertFalse(PrivacyCopy.onlyTextLeaves.lowercased().contains("only the recognized text"),
                       "这句话不能再声称只有识别文字出门")
        XCTAssertTrue(PrivacyCopy.keyInKeychain.contains("Keychain"))
        XCTAssertTrue(PrivacyCopy.youPayProvider.contains("pay the provider directly"))
        // 单价那句由 LLMCatalog 提供（唯一出处），所以只认意思、不认大小写
        // 4.1.1 起默认**开**（支持的服务商）：这句话跟着改，写着"默认关闭"而实际开着，
        // 比不说更糟——用户按它判断自己有没有在花这笔钱
        XCTAssertTrue(PrivacyCopy.webSearchBilled.lowercased().contains("on by default"))

        L10n.shared.language = .zh
        XCTAssertTrue(PrivacyCopy.audioStaysLocal.contains("默认本地识别"))
        XCTAssertTrue(PrivacyCopy.audioStaysLocal.contains("只有选择云端引擎时音频才会上传"))
        XCTAssertTrue(PrivacyCopy.onlyTextLeaves.contains("选中"))
        XCTAssertTrue(PrivacyCopy.keyInKeychain.contains("钥匙串"))
        XCTAssertTrue(PrivacyCopy.webSearchBilled.contains("默认开启"))
    }

    /// 「请求带 store:false」这句话只有在**真的会发 store:false 的那条路**上才许出现。
    /// 代码里 `store: false` 只存在于 responsesBody，而那条路的判据就是
    /// `provider == .openai && LLMClient.usesResponsesAPI(baseURL:)`——所以这条测试直接用同一个谓词。
    func testRetentionSentenceTracksTheResponsesPath() {
        L10n.shared.language = .en
        let cases: [(LLMProvider, String)] = [
            (.openai, "https://api.openai.com/v1"),
            (.openai, "https://gateway.example.com/v1"),   // OpenAI 档改了 Base URL → 走 chat
            (.deepseek, "https://api.deepseek.com"),
            (.qwen, "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
            (.custom, "https://api.moonshot.cn/v1"),
            (.local, "http://localhost:11434/v1"),
        ]
        for (provider, baseURL) in cases {
            let line = PrivacyCopy.retention(provider: provider, baseURL: baseURL)
            let onResponsesPath = provider == .openai && LLMClient.usesResponsesAPI(baseURL: baseURL)
            XCTAssertEqual(line.contains("store:false"), onResponsesPath,
                           "\(provider.rawValue) @ \(baseURL) 的留存文案和实际请求体对不上")
            XCTAssertFalse(line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(CJKSourceScanner.containsFlagged(line), "英文侧混进了中文：\(line)")
        }
        // 本机模型那一档说的是"请求不出网"，不是"服务商不留存"
        XCTAssertTrue(PrivacyCopy.retention(provider: .local, baseURL: "http://localhost:11434/v1")
                        .lowercased().contains("no request leaves it"))
        // 第三方云端那一档必须把留存交回给服务商的政策，不许留下任何"我们保证"的暗示
        XCTAssertTrue(PrivacyCopy.retention(provider: .deepseek, baseURL: "https://api.deepseek.com")
                        .lowercased().contains("its own policy"))
    }

    /// 界面上那一句必须就是按当前生效服务商现算出来的那一句（不是一句写死的承诺）
    func testKeyAndCostLinesUseTheLiveRetentionSentence() {
        XCTAssertEqual(PrivacyCopy.keyAndCostLines.first, PrivacyCopy.retentionLine)
        XCTAssertEqual(PrivacyCopy.retentionLine,
                       PrivacyCopy.retention(provider: Settings.shared.llmProvider,
                                             baseURL: Settings.shared.baseURL(for: Settings.shared.llmProvider)))
    }
}

/// 「输入」页的段序：第一个控件必须是快捷键，界面语言必须在最后。
/// 值得一条测试：这次重排的全部产出就是"顺序"，而顺序是最容易在下一次改动里被顺手推回去的东西。
final class InputSectionOrderTests: XCTestCase {

    func testOrderIsHotkeyFirstAndLanguageLast() {
        XCTAssertEqual(InputSectionOrder.allCases,
                       [.hotkey, .overlay, .recording, .behaviour, .languageAndBackup])
        XCTAssertEqual(InputSectionOrder.allCases.first, .hotkey)
        XCTAssertEqual(InputSectionOrder.allCases.last, .languageAndBackup)
    }

    /// 权限不再是这一页的一段：缺权限是"现在用不了"，归概览顶上那条横幅管。
    /// 钉住它是因为"顺手把权限搬回设置页"正是最容易发生的那次回退。
    func testPermissionsAreNotASectionOfThisPage() {
        XCTAssertEqual(InputSectionOrder.allCases.count, 5)
    }

    func testRawValuesAreContiguousFromZero() {
        // ForEach(id: \.self) 靠 rawValue 稳定排序；插新段落必须显式排到位置上
        XCTAssertEqual(InputSectionOrder.allCases.map(\.rawValue), Array(0..<5))
    }
}
