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

    /// **三句**（5.0.2，用户 2026-09-23 拍板：关于页文字减半）。
    /// 八句摆在一屏上的结果是一句都没人读；留下的这三句各回答一个问题——
    /// 录音去哪、还有什么跟着走、钱和 Key 归谁。
    func testThreeSentencesInFixedOrder() {
        XCTAssertEqual(PrivacyCopy.allLines.count, 3)
        // 顺序是文案的一部分
        XCTAssertEqual(PrivacyCopy.allLines, PrivacyCopy.dataFlowLines + PrivacyCopy.keyAndCostLines)
        XCTAssertEqual(PrivacyCopy.dataFlowLines.count, 2)
        XCTAssertEqual(PrivacyCopy.keyAndCostLines.count, 1)
    }

    /// Fast 档与联网搜索那两个半句 5.0.2 搬进了 Key 那一行的 ⓘ（关于页只剩三句）。
    /// 它们讲的是**花钱**，而那颗 ⓘ 本来就在说"这一档一小时多少钱"。
    /// 单价的唯一出处仍然是 LLMCatalog：这里守的就是"引用，不复述"。
    func testMoneySentencesLiveInTheKeyPopoverNow() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            // OpenAI 那一档两句都在（Fast 档只对官方接口成立，所以只对 OpenAI 说）
            let openai = SettingsCopy.keyInfo(hostField: false)
            XCTAssertTrue(openai.contains(LLMCatalog.fastTierPriceNote), openai)
            XCTAssertTrue(openai.contains(LLMCatalog.webSearchPriceNote), openai)
            // 阿里云那一档没有 Fast 档这回事；搜索那句念的是它自己那一版
            //（我们报不出阿里云的搜索单价，见 LLMCatalog.providerBilledSearchNote）
            let qwen = SettingsCopy.keyInfo(hostField: true)
            XCTAssertFalse(qwen.contains(LLMCatalog.fastTierPriceNote), qwen)
            XCTAssertTrue(qwen.contains(LLMCatalog.providerBilledSearchNote), qwen)
            // 关于页那三句里一个价钱都不出现了
            for line in PrivacyCopy.allLines {
                XCTAssertFalse(line.contains(LLMCatalog.fastTierPriceNote), line)
                XCTAssertFalse(line.contains(LLMCatalog.webSearchPriceNote), line)
                XCTAssertFalse(line.contains(LLMCatalog.providerBilledSearchNote), line)
            }
        }
    }

    /// Key 怎么存、钱怎么付：关于页那两句和 Key 输入框旁边那两句必须是**同一串**。
    /// 4.1.0 之前是两套各写各的措辞（关于页「不写进文件」vs ⓘ 里「加密、仅本机可读」），
    /// 改一处漏一处就是两句对不上的承诺——而扫描器只数 `PrivacyCopy.`，看不见这种漂移。
    func testKeyAndBillingPromisesHaveASingleSource() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            // 5.0.2 起两句并成一句，但两截仍然逐字来自 LLMCatalog
            XCTAssertTrue(PrivacyCopy.keyAndBilling.contains(LLMCatalog.keyStorageNote),
                          PrivacyCopy.keyAndBilling)
            XCTAssertTrue(PrivacyCopy.keyAndBilling.contains(LLMCatalog.billingNote),
                          PrivacyCopy.keyAndBilling)
            XCTAssertTrue(SettingsCopy.keyInfo(hostField: false).contains(LLMCatalog.keyStorageNote))
        }
    }

    /// 听写历史存哪儿、最多几条：**条数那个常量只有一个出处**（HistoryStore.storageNote）。
    ///
    /// 5.0.2 起这句话住在「保存听写历史」那个开关的 ⓘ 里，不在关于页那三句里——
    /// 它讲的是这个开关的事，摆在开关旁边才有人读。行为不变：仍然只写一处，ⓘ 引用它。
    func testHistoryStorageFactsHaveASingleSource() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertTrue(HistoryStore.storageNote.contains("\(HistoryStore.maxCount)"),
                          HistoryStore.storageNote)
            XCTAssertTrue(SettingsCopy.behaviourInfo.hasPrefix(HistoryStore.storageNote),
                          SettingsCopy.behaviourInfo)
            // 关于页那三句里不再复述它
            for line in PrivacyCopy.allLines {
                XCTAssertFalse(line.contains(HistoryStore.storageNote), line)
            }
        }
        L10n.shared.language = .en
        XCTAssertFalse(CJKSourceScanner.containsFlagged(HistoryStore.storageNote),
                       HistoryStore.storageNote)
        XCTAssertFalse(CJKSourceScanner.containsFlagged(SettingsCopy.behaviourInfo),
                       SettingsCopy.behaviourInfo)
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
    /// 这里守住"别再搬回来"：这几句讲的是**打开 MicType 就成立**的事实，
    /// 具体单价、去控制台开通模型这类只在某一档下才成立的话，混进来就成了假话。
    /// （一小时多少钱那句住在设置页 Key 那颗 ⓘ 与引导 ③ 的卡片上。）
    func testPerProviderPricingDoesNotLiveHere() {
        L10n.shared.language = .zh
        for line in PrivacyCopy.allLines {
            XCTAssertFalse(line.contains("开通"), line)
            XCTAssertFalse(line.contains("/小时"), line)
        }
        L10n.shared.language = .en
        for line in PrivacyCopy.allLines {
            XCTAssertFalse(line.lowercased().contains("enable the model"), line)
            XCTAssertFalse(line.lowercased().contains("/hour"), line)
        }
    }

    /// 每句话各自对应一条能在代码里指出来的行为，关键词漏了就说明句子被改空了
    func testEachClaimKeepsItsKeyword() {
        L10n.shared.language = .en
        // 5.0.0：识别只有云端一条路，所以这句话必须说清**边说边传**，
        // 以及 Esc 只能停下、收不回已经传出去的那几秒
        XCTAssertTrue(PrivacyCopy.audioGoesToProvider.lowercased().contains("while you are still speaking"))
        XCTAssertTrue(PrivacyCopy.audioGoesToProvider.contains("Esc"))
        XCTAssertFalse(PrivacyCopy.audioGoesToProvider.lowercased().contains("on-device"),
                       "没有本机识别那一档了，别再承诺它")
        // 指令模式会把**前台应用的选区原文**发出去（常常不是用户自己说的话），
        // 这句话必须把它点名说出来——以前写的"只有识别出的文字"在主路径上就不成立
        XCTAssertTrue(PrivacyCopy.onlyTextLeaves.lowercased().contains("recognized text"))
        XCTAssertTrue(PrivacyCopy.onlyTextLeaves.lowercased().contains("selected"))
        XCTAssertTrue(PrivacyCopy.onlyTextLeaves.lowercased().contains("vocabulary"))
        XCTAssertFalse(PrivacyCopy.onlyTextLeaves.lowercased().contains("only the recognized text"),
                       "这句话不能再声称只有识别文字出门")
        XCTAssertTrue(PrivacyCopy.keyAndBilling.contains("Keychain"))
        XCTAssertTrue(PrivacyCopy.keyAndBilling.contains("pay the provider directly"))

        L10n.shared.language = .zh
        XCTAssertTrue(PrivacyCopy.audioGoesToProvider.contains("你选的服务商"))
        XCTAssertTrue(PrivacyCopy.audioGoesToProvider.contains("收不回来"))
        XCTAssertFalse(PrivacyCopy.audioGoesToProvider.contains("本机"), "没有本机识别那一档了")
        XCTAssertTrue(PrivacyCopy.onlyTextLeaves.contains("选中"))
        XCTAssertTrue(PrivacyCopy.keyAndBilling.contains("钥匙串"))
        XCTAssertTrue(PrivacyCopy.keyAndBilling.contains("不经手"))
    }

    // 留存那两条测试（store:false 按生效档说、界面用现算的那一句）5.0.2 随
    // PrivacyCopy.retention 一起删掉：关于页压到三句之后，它不在那三句里了。
    // 行为没变（请求体照旧带 store:false，判据仍是 LLMClient.usesResponsesAPI），
    // 只是界面上不再逐档解释留存政策。
}

// 「输入」页的段序测试（InputSectionOrderTests）5.0.0 删掉：设置只剩一页，
// 那一页没有了（快捷键 / 界面语言 / 开机自启三样都走出厂默认或搬去了菜单栏与引导）。
