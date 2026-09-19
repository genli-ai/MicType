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

    // MARK: 阿语模型推荐

    /// 只在「显式选了阿语 + 还在小模型」时推荐；推荐是一条可点的建议，不是自动切换
    func testArabicRecommendsTheLargeModel() {
        XCTAssertTrue(QwenModels.recommendsLargeModel(languageCode: "ar",
                                                      currentRepo: QwenModels.defaultRepo))
        XCTAssertFalse(QwenModels.recommendsLargeModel(languageCode: "ar",
                                                       currentRepo: QwenModels.largeRepo))
        XCTAssertFalse(QwenModels.recommendsLargeModel(languageCode: "zh",
                                                       currentRepo: QwenModels.defaultRepo))
        // Auto 不推荐：用户没说他要说阿语，我们就不替他判
        XCTAssertFalse(QwenModels.recommendsLargeModel(languageCode: RecognitionLanguages.autoCode,
                                                       currentRepo: QwenModels.defaultRepo))
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
