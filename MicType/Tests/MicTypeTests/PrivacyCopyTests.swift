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

    /// 云端那几句不进 allLines（关于页讲的是默认状态），但它们同样要两种语言都在、英文侧干净。
    /// 这几句是用户点下"云端"之前唯一能读到的代价说明，一句都不能空。
    func testCloudLinesAreCompleteInBothLanguages() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            for line in PrivacyCopy.cloudAlibabaLines + PrivacyCopy.cloudOpenAILines {
                XCTAssertFalse(line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            XCTAssertEqual(Set(PrivacyCopy.cloudAlibabaLines).count, PrivacyCopy.cloudAlibabaLines.count,
                           "ForEach(id: \\.self) 渲染，重复会丢行")
        }
        L10n.shared.language = .en
        for line in PrivacyCopy.cloudAlibabaLines + PrivacyCopy.cloudOpenAILines {
            XCTAssertFalse(CJKSourceScanner.containsFlagged(line), "英文侧混进了中文：\(line)")
        }
        // 三件必须说的事：音频会上传、按秒计费、失败还有本地退路
        XCTAssertTrue(PrivacyCopy.cloudAudioLeaves.lowercased().contains("uploaded"))
        XCTAssertTrue(PrivacyCopy.cloudBilledPerSecond.lowercased().contains("billed by the second"))
        XCTAssertTrue(PrivacyCopy.cloudFallsBackToLocal.lowercased().contains("locally"))
        // 阿里云那一档多一句"先去控制台开通模型"，OpenAI 那一档没有这一步
        XCTAssertTrue(PrivacyCopy.cloudAlibabaLines.contains(PrivacyCopy.cloudEnableModelFirst))
        XCTAssertFalse(PrivacyCopy.cloudOpenAILines.contains(PrivacyCopy.cloudEnableModelFirst))
        XCTAssertFalse(PrivacyCopy.allLines.contains(PrivacyCopy.cloudAudioLeaves),
                       "云端那几句不该混进关于页的六句")
    }

    /// 六句话各自对应一条能在代码里指出来的行为，关键词漏了就说明句子被改空了
    func testEachClaimKeepsItsKeyword() {
        L10n.shared.language = .en
        // v4.0 起多了一档可选的云端识别：这句话必须同时说清"默认在本机"和"云端才会上传"，
        // 不能再是一句无条件的承诺（那在云端档下不成立）
        XCTAssertTrue(PrivacyCopy.audioStaysLocal.contains("On-device recognition by default"))
        XCTAssertTrue(PrivacyCopy.audioStaysLocal.contains("only if you choose a cloud engine"))
        XCTAssertTrue(PrivacyCopy.onlyTextLeaves.lowercased().contains("only the recognized text"))
        XCTAssertTrue(PrivacyCopy.noRetention.contains("store:false"))
        XCTAssertTrue(PrivacyCopy.keyInKeychain.contains("Keychain"))
        XCTAssertTrue(PrivacyCopy.youPayProvider.contains("pay the provider directly"))
        XCTAssertTrue(PrivacyCopy.webSearchBilled.contains("off by default"))

        L10n.shared.language = .zh
        XCTAssertTrue(PrivacyCopy.audioStaysLocal.contains("默认本地识别"))
        XCTAssertTrue(PrivacyCopy.audioStaysLocal.contains("只有选择云端引擎时音频才会上传"))
        XCTAssertTrue(PrivacyCopy.noRetention.contains("store:false"))
        XCTAssertTrue(PrivacyCopy.keyInKeychain.contains("钥匙串"))
        XCTAssertTrue(PrivacyCopy.webSearchBilled.contains("默认关闭"))
    }
}

/// 通用页的段序（v4.0 §4.4）：第一个控件必须是快捷键，界面语言必须在最后。
/// 值得一条测试：这次重排的全部产出就是"顺序"，而顺序是最容易在下一次改动里被顺手推回去的东西。
final class GeneralSectionOrderTests: XCTestCase {

    func testOrderIsHotkeyFirstAndLanguageLast() {
        XCTAssertEqual(GeneralSectionOrder.allCases,
                       [.hotkey, .recording, .overlay, .behaviour, .permissions, .languageAndBackup])
        XCTAssertEqual(GeneralSectionOrder.allCases.first, .hotkey)
        XCTAssertEqual(GeneralSectionOrder.allCases.last, .languageAndBackup)
    }

    func testRawValuesAreContiguousFromZero() {
        // ForEach(id: \.self) 靠 rawValue 稳定排序；插新段落必须显式排到位置上
        XCTAssertEqual(GeneralSectionOrder.allCases.map(\.rawValue), Array(0..<6))
    }
}
