import XCTest
@testable import MicType

/// 「一小时多少钱 / 一句话多少钱」与拿 Key 的那几步。
///
/// 为什么这几条值得钉住：5.0.0 起用户在引导 ③ 要在两家之间做一个**会花他自己的钱**的选择，
/// 而这些数字和链接就是他做那个选择的全部依据。数字写错了他选错家，链接写错了他卡在第一分钟。
final class PricingCopyTests: XCTestCase {

    private var savedLanguage: AppLanguage = .zh

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: - 价格

    /// 两段费用各自的来路（识别是查过的、润色是估的）都必须是正数，
    /// 而且**识别那一段占大头**——写反了说明有人把两个常量填串了
    func testHourlyCostIsDominatedByRecognition() {
        for provider in LLMProvider.allCases {
            XCTAssertGreaterThan(LLMCatalog.asrHourlyUSD(provider: provider), 0, provider.rawValue)
            XCTAssertGreaterThan(LLMCatalog.polishHourlyUSD(provider: provider), 0, provider.rawValue)
            XCTAssertGreaterThan(LLMCatalog.asrHourlyUSD(provider: provider),
                                 LLMCatalog.polishHourlyUSD(provider: provider),
                                 "\(provider.rawValue)：识别才是大头，润色只是零头")
            XCTAssertEqual(LLMCatalog.hourlyUSD(provider: provider),
                           LLMCatalog.asrHourlyUSD(provider: provider)
                               + LLMCatalog.polishHourlyUSD(provider: provider),
                           accuracy: 0.0001)
        }
    }

    /// **阿里云必须明显更便宜**——那是引导 ③ 两张卡片之间最大的差别（设计文档第 3 节写的是
    /// 约 $0.2 对约 $1.1）。这一条一旦反过来，卡片上那句「更便宜、更快」就成了假话。
    func testAlibabaIsTheCheapOne() {
        XCTAssertLessThan(LLMCatalog.hourlyUSD(provider: .qwen),
                          LLMCatalog.hourlyUSD(provider: .openai))
        XCTAssertLessThan(LLMCatalog.hourlyUSD(provider: .qwen), 0.5)
        XCTAssertGreaterThan(LLMCatalog.hourlyUSD(provider: .openai), 0.8)
    }

    /// 「约 $1.1/小时」：**只留一位小数、永远带"约"**。给一个 $1.1234 的数字，
    /// 等于假装我们知道用户会说多久、说多密。
    func testHourlyNoteIsRoundedAndHedged() {
        L10n.shared.language = .zh
        XCTAssertEqual(LLMCatalog.hourlyCostNote(provider: .qwen), "约 $0.2/小时")
        XCTAssertEqual(LLMCatalog.hourlyCostNote(provider: .openai), "约 $1.1/小时")
        L10n.shared.language = .en
        XCTAssertEqual(LLMCatalog.hourlyCostNote(provider: .qwen), "about $0.2/hour")
        XCTAssertEqual(LLMCatalog.hourlyCostNote(provider: .openai), "about $1.1/hour")
    }

    /// 「每句话约 $0.003」：引导 ③ 验通之后念的就是它。一小时的数字对还没用过的人
    /// 没有概念，而"一句话"是他真正的计量单位。
    func testPerSentenceNoteFollowsTheHourlyPrice() {
        for provider in LLMProvider.allCases {
            XCTAssertEqual(LLMCatalog.perSentenceUSD(provider: provider),
                           LLMCatalog.hourlyUSD(provider: provider) / LLMCatalog.sentencesPerHour,
                           accuracy: 0.000001)
        }
        L10n.shared.language = .zh
        XCTAssertEqual(LLMCatalog.perSentenceCostNote(provider: .qwen), "每句话约 $0.001")
        XCTAssertEqual(LLMCatalog.perSentenceCostNote(provider: .openai), "每句话约 $0.003")
        L10n.shared.language = .en
        XCTAssertTrue(LLMCatalog.perSentenceCostNote(provider: .openai).hasPrefix("about $0.003"))
    }

    /// 价格串里**不许出现"分钱"**：中文的"分"既能读成人民币也能读成美分，
    /// 而这笔钱是用户拿自己的卡直接付给服务商的——写清货币符号比读着顺重要
    func testPriceNotesAlwaysCarryACurrencySymbol() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            for provider in LLMProvider.allCases {
                for note in [LLMCatalog.hourlyCostNote(provider: provider),
                             LLMCatalog.perSentenceCostNote(provider: provider)] {
                    XCTAssertTrue(note.contains("$"), note)
                    XCTAssertFalse(note.contains("分钱"), note)
                }
            }
        }
    }

    /// 英文界面里这几串不许夹中文或全角标点
    func testPriceAndCardNotesAreCleanInEnglish() {
        L10n.shared.language = .en
        for provider in LLMProvider.allCases {
            for note in [LLMCatalog.hourlyCostNote(provider: provider),
                         LLMCatalog.perSentenceCostNote(provider: provider),
                         LLMCatalog.audienceNote(provider: provider),
                         LLMCatalog.strengthNote(provider: provider)] {
                XCTAssertFalse(CJKSourceScanner.containsFlagged(note), note)
            }
        }
    }

    /// 引导 ③ 两张卡片上那两行必须各说各的：复制粘贴写错一处，两张卡片就一模一样，
    /// 而那一刻用户正靠它们做选择
    func testCardLinesDifferBetweenProviders() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertNotEqual(LLMCatalog.audienceNote(provider: .openai),
                              LLMCatalog.audienceNote(provider: .qwen))
            XCTAssertNotEqual(LLMCatalog.strengthNote(provider: .openai),
                              LLMCatalog.strengthNote(provider: .qwen))
            XCTAssertNotEqual(LLMCatalog.hourlyCostNote(provider: .openai),
                              LLMCatalog.hourlyCostNote(provider: .qwen))
        }
    }

    // MARK: - 拿 Key 的那几步

    /// 每一步都要有话；链接一律 https（引导会把它直接交给 NSWorkspace 打开）；
    /// **三步封顶**（5.0.1）——原先第四步是"回到这里粘贴"，而粘贴框就在这几行字底下
    func testConsoleStepsAreActionableAndSafe() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            for provider in LLMProvider.allCases {
                let steps = LLMCatalog.consoleSteps(for: provider)
                XCTAssertEqual(steps.count, 3, provider.rawValue)
                for step in steps {
                    XCTAssertFalse(step.text.trimmingCharacters(in: .whitespaces).isEmpty)
                    for link in step.links {
                        XCTAssertTrue(link.url.hasPrefix("https://"), link.url)
                        XCTAssertFalse(link.label.isEmpty)
                    }
                }
            }
        }
    }

    /// 阿里云第一步必须给**两个**入口：两个站是两套账号体系，我们无从得知用户在哪一边
    /// ——写死一个的结果是另一边的人点进去看到空页面。
    /// 按钮上只写站点自己的名字，**中英两侧一模一样**（用户 2026-09-22 拍板）
    func testAlibabaOffersBothConsoles() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            let first = LLMCatalog.consoleSteps(for: .qwen).first
            XCTAssertEqual(first?.links.count, 2)
            let urls = first?.links.map(\.url) ?? []
            XCTAssertTrue(urls.contains(LLMCatalog.alibabaConsoleInternational))
            XCTAssertTrue(urls.contains(LLMCatalog.alibabaConsoleChina))
            XCTAssertEqual(first?.links.map(\.label), ["International", "China"])
        }
    }

    /// 引导 ③ 的文案里**一个字都不提「国内 / 国际站 / 中国站」**（用户 2026-09-22 拍板）：
    /// 那是阿里云自己的账号体系，不是用户在这一刻要做的那个选择
    func testNoStationWordingAnywhereInTheSteps() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            for provider in LLMProvider.allCases {
                let lines = LLMCatalog.consoleSteps(for: provider).map(\.text)
                    + [LLMCatalog.audienceNote(provider: provider),
                       LLMCatalog.strengthNote(provider: provider)]
                for line in lines {
                    for banned in ["国内", "国际站", "中国站"] {
                        XCTAssertFalse(line.contains(banned), line)
                    }
                }
            }
        }
    }

    /// OpenAI 那三步各去各的页面：充值和建 Key 是两个地方，合成一个链接等于让人自己找
    func testOpenAIStepsPointAtDistinctPages() {
        let urls = LLMCatalog.consoleSteps(for: .openai).flatMap { $0.links.map(\.url) }
        XCTAssertEqual(Set(urls).count, urls.count, "\(urls)")
        XCTAssertTrue(urls.contains { $0.contains("billing") })
        XCTAssertTrue(urls.contains(LLMCatalog.apiKeyConsoleURL(for: .openai) ?? ""),
                      "建 Key 那一步要和「去申请 Key ↗」指同一页")
    }

    /// 英文侧同样不许夹中文
    func testConsoleStepsAreCleanInEnglish() {
        L10n.shared.language = .en
        for provider in LLMProvider.allCases {
            for step in LLMCatalog.consoleSteps(for: provider) {
                XCTAssertFalse(CJKSourceScanner.containsFlagged(step.text), step.text)
                for link in step.links {
                    XCTAssertFalse(CJKSourceScanner.containsFlagged(link.label), link.label)
                }
            }
        }
    }

    // MARK: - 状态行末尾那半句

    /// **只挂在成功那一档**。挂错地方的后果不是难看，是把失败原因挤下去——
    /// 而那一行恰恰是用户唯一能照着做事的字。
    func testConnectedSuffixOnlyRidesOnSuccess() {
        XCTAssertEqual(KeyEntryView.connectedSuffix(.connected(provider: "X", model: "m"),
                                                    note: "每句话约 $0.003"),
                       " · 每句话约 $0.003")
        XCTAssertEqual(KeyEntryView.connectedSuffix(.verifying, note: "每句话约 $0.003"), "")
        XCTAssertEqual(KeyEntryView.connectedSuffix(.failed(reason: "401", keptPrevious: false),
                                                    note: "每句话约 $0.003"), "")
        XCTAssertEqual(KeyEntryView.connectedSuffix(.cleared, note: "每句话约 $0.003"), "")
        // 调用方没给话就什么都不挂（别留一个孤零零的「 · 」）
        XCTAssertEqual(KeyEntryView.connectedSuffix(.connected(provider: "X", model: "m"),
                                                    note: "   "), "")
    }
}
