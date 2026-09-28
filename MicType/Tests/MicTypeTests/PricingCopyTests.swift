import XCTest
@testable import MicType

/// 「一小时多少钱 / 一句话多少钱」与拿 Key 的那几步。
///
/// 为什么这几条值得钉住：这些数字是用户在 Key 那颗 ⓘ 与验通之后的状态行里读到的
/// "这要花我多少钱"，链接是他拿到 Key 的唯一路径——链接写错了他卡在第一分钟。
/// （5.0.x 引导 ③ 的两家对比卡片与阿里云那几条 5.1.0 随那一档删掉。）
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

    /// 「约 $1.7/小时」（5.1.0 起识别多了整段那一趟 $0.0045/分钟）：**只留一位小数、永远带"约"**。给一个 $1.1234 的数字，
    /// 等于假装我们知道用户会说多久、说多密。
    func testHourlyNoteIsRoundedAndHedged() {
        L10n.shared.language = .zh
        XCTAssertEqual(LLMCatalog.hourlyCostNote(provider: .openai), "约 $1.7/小时")
        L10n.shared.language = .en
        XCTAssertEqual(LLMCatalog.hourlyCostNote(provider: .openai), "about $1.7/hour")
    }

    /// 「每句话约 $0.005」：引导 ③ 验通之后念的就是它。一小时的数字对还没用过的人
    /// 没有概念，而"一句话"是他真正的计量单位。
    func testPerSentenceNoteFollowsTheHourlyPrice() {
        for provider in LLMProvider.allCases {
            XCTAssertEqual(LLMCatalog.perSentenceUSD(provider: provider),
                           LLMCatalog.hourlyUSD(provider: provider) / LLMCatalog.sentencesPerHour,
                           accuracy: 0.000001)
        }
        L10n.shared.language = .zh
        XCTAssertEqual(LLMCatalog.perSentenceCostNote(provider: .openai), "每句话约 $0.005")
        L10n.shared.language = .en
        XCTAssertTrue(LLMCatalog.perSentenceCostNote(provider: .openai).hasPrefix("about $0.005"))
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
    func testPriceNotesAreCleanInEnglish() {
        L10n.shared.language = .en
        for provider in LLMProvider.allCases {
            for note in [LLMCatalog.hourlyCostNote(provider: provider),
                         LLMCatalog.perSentenceCostNote(provider: provider)] {
                XCTAssertFalse(CJKSourceScanner.containsFlagged(note), note)
            }
        }
    }

    // 「两张卡片各说各的」（audienceNote / strengthNote）5.1.0 随那两张卡片删掉。

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

    /// 「去申请 Key ↗」直达 OpenAI 的 API Key 页（5.0.4 为阿里云加的两站小菜单 5.1.0 删掉）；
    /// 引导 ③ 的文案里仍然**一个字都不提「国内 / 国际站 / 中国站」**（用户 2026-09-22 拍板）
    func testKeyConsoleEntryAndStepsWording() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            XCTAssertTrue(LLMCatalog.apiKeyConsoleURL(for: .openai).hasPrefix("https://"))
            XCTAssertFalse(LLMCatalog.getAKeyLabel.isEmpty)
            for step in LLMCatalog.consoleSteps(for: .openai) {
                for banned in ["国内", "国际站", "中国站"] {
                    XCTAssertFalse(step.text.contains(banned), step.text)
                }
            }
        }
        L10n.shared.language = .en
        XCTAssertFalse(CJKSourceScanner.containsFlagged(LLMCatalog.getAKeyLabel),
                       LLMCatalog.getAKeyLabel)
    }

    /// OpenAI 那三步各去各的页面：充值和建 Key 是两个地方，合成一个链接等于让人自己找
    func testOpenAIStepsPointAtDistinctPages() {
        let urls = LLMCatalog.consoleSteps(for: .openai).flatMap { $0.links.map(\.url) }
        XCTAssertEqual(Set(urls).count, urls.count, "\(urls)")
        XCTAssertTrue(urls.contains { $0.contains("billing") })
        XCTAssertTrue(urls.contains(LLMCatalog.apiKeyConsoleURL(for: .openai)),
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
