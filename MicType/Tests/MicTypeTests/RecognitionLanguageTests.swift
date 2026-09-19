import XCTest
@testable import MicType

/// 识别语言表 + 热词前缀的纯函数单测。
/// 语言名是**送进模型 prompt 的字面量**（mlx-swift-asr 把 language 原样拼进 prompt），
/// 所以这里的断言实际是在钉死一份对外接口，不是在测一个内部映射。
final class RecognitionLanguageTests: XCTestCase {

    // MARK: 语言表

    /// 30 种语言，一个不多一个不少（Qwen3-ASR config.json 的 support_languages）
    func testTableHasThirtyLanguages() {
        XCTAssertEqual(RecognitionLanguages.all.count, 30)
    }

    /// 模型名必须是英文全名：传语言代码会让模型看到字面的「language ar」
    func testModelLanguageUsesEnglishFullName() {
        XCTAssertEqual(RecognitionLanguages.modelLanguage(for: "ar"), "Arabic")
        XCTAssertEqual(RecognitionLanguages.modelLanguage(for: "zh"), "Chinese")
        XCTAssertEqual(RecognitionLanguages.modelLanguage(for: "en"), "English")
        XCTAssertEqual(RecognitionLanguages.modelLanguage(for: "yue"), "Cantonese")
    }

    /// 支持列表里的名字全部与 config.json 逐字一致（抄错一个字母就是静默降级为「没这语言」）
    func testEveryModelNameIsInTheOfficialSupportList() {
        let official: Set<String> = [
            "Chinese", "English", "Cantonese", "Arabic", "German", "French", "Spanish",
            "Portuguese", "Indonesian", "Italian", "Korean", "Russian", "Thai", "Vietnamese",
            "Japanese", "Turkish", "Hindi", "Malay", "Dutch", "Swedish", "Danish", "Finnish",
            "Polish", "Czech", "Filipino", "Persian", "Greek", "Romanian", "Hungarian", "Macedonian",
        ]
        XCTAssertEqual(Set(RecognitionLanguages.all.map(\.modelName)), official)
    }

    /// Auto（空串）与任何脏值一律 nil = 让模型自动检测，绝不把乱码拼进 prompt
    func testAutoAndGarbageBothMeanAutomaticDetection() {
        XCTAssertNil(RecognitionLanguages.modelLanguage(for: RecognitionLanguages.autoCode))
        XCTAssertNil(RecognitionLanguages.modelLanguage(for: "  "))
        XCTAssertNil(RecognitionLanguages.modelLanguage(for: "auto"))
        XCTAssertNil(RecognitionLanguages.modelLanguage(for: "klingon"))
    }

    func testModelLanguageToleratesSurroundingWhitespace() {
        XCTAssertEqual(RecognitionLanguages.modelLanguage(for: " ar "), "Arabic")
    }

    /// 代码唯一：两条同 code 的词条会让 Picker 选中错误的那一条
    func testCodesAreUnique() {
        let codes = RecognitionLanguages.all.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    // MARK: Picker 顺序

    func testPickerPutsChineseEnglishArabicFirst() {
        XCTAssertEqual(RecognitionLanguages.pickerOrdered.prefix(3).map(\.code), ["zh", "en", "ar"])
    }

    /// 其余按当前界面语言的显示名排序（中文界面按拼音、英文界面按字母）
    func testPickerSortsTheRestByDisplayName() {
        let rest = RecognitionLanguages.pickerOrdered.dropFirst(3).map(\.displayName)
        let sorted = rest.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(rest, sorted)
        XCTAssertEqual(RecognitionLanguages.pickerOrdered.count, 30)
    }

    // MARK: 热词前缀

    func testChinesePrefixWhenChineseIsSelected() {
        XCTAssertEqual(RecognitionLanguages.hotwordContext(terms: ["捷文", "云术法"], languageCode: "zh"),
                       "常用词汇：捷文、云术法")
    }

    func testEnglishPrefixWhenEnglishIsSelected() {
        XCTAssertEqual(RecognitionLanguages.hotwordContext(terms: ["Rappel", "MicType"], languageCode: "en"),
                       "Common terms: Rappel, MicType")
    }

    /// 阿语会话绝不能拿到中文前缀：那是一句中文系统提示，会带偏输出风格
    func testArabicSessionGetsEnglishPrefix() {
        let context = RecognitionLanguages.hotwordContext(terms: ["الذكاء الاصطناعي"], languageCode: "ar")
        XCTAssertEqual(context, "Common terms: الذكاء الاصطناعي")
    }

    /// Auto：看词表本身。中文词表 → 中文前缀；纯西文词表 → 英文前缀。不猜别的。
    func testAutoFollowsTheVocabularyScript() {
        XCTAssertEqual(RecognitionLanguages.hotwordPrefix(languageCode: "", terms: ["捷文"]), "常用词汇：")
        XCTAssertEqual(RecognitionLanguages.hotwordPrefix(languageCode: "", terms: ["Rappel"]), "Common terms: ")
        // 日文假名也算 CJK（分隔符与前缀同源）
        XCTAssertEqual(RecognitionLanguages.hotwordPrefix(languageCode: "", terms: ["カメラ"]), "常用词汇：")
    }

    func testCantoneseCountsAsChinese() {
        XCTAssertEqual(RecognitionLanguages.hotwordPrefix(languageCode: "yue", terms: ["Rappel"]), "常用词汇：")
    }

    /// 词表为空返回 nil：只有前缀的上下文正是空音频复读的燃料（3.2.2）
    func testEmptyVocabularyProducesNoContext() {
        XCTAssertNil(RecognitionLanguages.hotwordContext(terms: [], languageCode: "en"))
    }

    /// 800 字上限只截词条串，前缀永远完整
    func testContextIsCappedButKeepsThePrefix() {
        let terms = (0..<400).map { "term\($0)" }
        let context = RecognitionLanguages.hotwordContext(terms: terms, languageCode: "en")
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.hasPrefix("Common terms: "))
        XCTAssertEqual(context!.count, "Common terms: ".count + 800)
    }

    /// 两种前缀都要被复读检测认出来，否则非中文会话的复读会整段漏进输入框
    func testBothPrefixesAreCaughtByVocabEcho() {
        XCTAssertTrue(TextPostProcessor.isVocabEcho("常用词汇：捷文", terms: ["捷文"]))
        XCTAssertTrue(TextPostProcessor.isVocabEcho("Common terms: Rappel", terms: ["Rappel"]))
    }

    // MARK: 热词前缀永远不是阿语

    /// 实测（2026-09-19）：英文前缀 4.04%、中文前缀 4.38%、**阿语前缀 13.8% 且不吐标点**。
    /// 所以阿语会话必须走英文前缀这一支——这条测试就是拦住"好心给阿语本地化一个前缀"的。
    func testArabicSessionsUseTheEnglishHotwordPrefix() {
        XCTAssertEqual(RecognitionLanguages.hotwordPrefix(languageCode: "ar", terms: ["Power BI"]),
                       "Common terms: ")
        // 阿语词表 + 阿语会话也一样：前缀跟着"会话语言不是中文"走，不跟着词表的文字走
        XCTAssertEqual(RecognitionLanguages.hotwordPrefix(languageCode: "ar", terms: ["الاجتماع"]),
                       "Common terms: ")
        XCTAssertEqual(RecognitionLanguages.hotwordSeparator(languageCode: "ar", terms: ["الاجتماع"]),
                       ", ")
        // 前缀只有两种可能，永远不含阿语字母
        for code in RecognitionLanguages.all.map({ $0.code }) + [RecognitionLanguages.autoCode] {
            let prefix = RecognitionLanguages.hotwordPrefix(languageCode: code, terms: ["Power BI"])
            XCTAssertTrue(prefix == "Common terms: " || prefix == "常用词汇：", "prefix=\(prefix)")
            XCTAssertFalse(prefix.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) })
        }
    }

    // MARK: 语言锁

    /// 第一段检测出的语言要能原样回传给模型（英文全名，逐字对齐 support_languages）
    func testLockableModelLanguageAcceptsNamesAndCodes() {
        XCTAssertEqual(RecognitionLanguages.lockableModelLanguage("Arabic"), "Arabic")
        XCTAssertEqual(RecognitionLanguages.lockableModelLanguage("arabic"), "Arabic")
        // 库有时给的是代码，送回去的仍然必须是全名（传 "ar" 等于往 prompt 里塞一句它没见过的话）
        XCTAssertEqual(RecognitionLanguages.lockableModelLanguage("ar"), "Arabic")
        XCTAssertEqual(RecognitionLanguages.lockableModelLanguage("Chinese"), "Chinese")
    }

    /// 认不出来一律不锁：宁可后面几段继续自动检测，也不能把乱码拼进 prompt
    func testLockableModelLanguageRejectsGarbage() {
        XCTAssertNil(RecognitionLanguages.lockableModelLanguage(nil))
        XCTAssertNil(RecognitionLanguages.lockableModelLanguage(""))
        XCTAssertNil(RecognitionLanguages.lockableModelLanguage("   "))
        XCTAssertNil(RecognitionLanguages.lockableModelLanguage("auto"))
        XCTAssertNil(RecognitionLanguages.lockableModelLanguage("Klingon"))
    }

    // MARK: 分段上下文

    /// 热词在前、上一段的尾巴在后（brief §3.3）：模型先看到要纠正的专名，再看到话说到哪儿了
    func testSegmentContextPutsHotwordsBeforeTheTail() {
        let context = RecognitionLanguages.segmentContext(
            terms: ["捷文"], languageCode: "zh",
            previousText: "我们先说第一点，然后再说第二点")
        XCTAssertNotNil(context)
        let hotIndex = context!.range(of: "捷文")!.lowerBound
        let tailIndex = context!.range(of: "第二点")!.lowerBound
        XCTAssertTrue(hotIndex < tailIndex)
    }

    /// 尾巴最多 100 字：整段历史全塞进去只会挤掉词表，而模型只需要知道上一句说到哪儿
    func testSegmentContextTailIsCappedAtOneHundredCharacters() {
        let long = String(repeating: "话", count: 500)
        let context = RecognitionLanguages.segmentContext(
            terms: [], languageCode: "zh", previousText: long)
        XCTAssertEqual(context?.count, RecognitionLanguages.segmentTailLimit)
    }

    /// 没有上一段（第一段）时就是原来的热词上下文，一个字都不多
    func testSegmentContextWithoutTailIsJustHotwords() {
        XCTAssertEqual(RecognitionLanguages.segmentContext(terms: ["MicType"], languageCode: "en",
                                                           previousText: ""),
                       RecognitionLanguages.hotwordContext(terms: ["MicType"], languageCode: "en"))
        XCTAssertNil(RecognitionLanguages.segmentContext(terms: [], languageCode: "en",
                                                         previousText: "   "))
    }

    /// 总长永远不超过 800 字；预算不够时**先砍尾巴**，用户明确配置的词表一个都不能少
    func testSegmentContextNeverExceedsTheLimitAndKeepsHotwords() {
        let terms = (0..<200).map { "词条\($0)" }
        let context = RecognitionLanguages.segmentContext(
            terms: terms, languageCode: "zh",
            previousText: String(repeating: "尾", count: 100))
        XCTAssertNotNil(context)
        XCTAssertLessThanOrEqual(context!.count, 800)
        XCTAssertFalse(context!.contains("尾"))
        XCTAssertTrue(context!.hasPrefix("常用词汇："))
    }
}
