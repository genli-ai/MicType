import XCTest
@testable import MicType

/// 纯函数层单测：词表硬替换 / 伪影与口水词过滤 / 润色保真校验。
/// 三者都不碰 UserDefaults（一律走显式传参的重载），所以跑测试不会改到用户设置。
/// 与 Windows 端 MicTypeWindows/tests 的同名用例一一对应，双端行为必须一致。
final class TextPostProcessorTests: XCTestCase {

    // MARK: cleanTranscript

    func testCleanTranscriptStripsEngineTokens() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("<|zh|><|NEUTRAL|>今天下午三点开会", fillerWords: []),
                       "今天下午三点开会")
    }

    func testCleanTranscriptStripsAngleBracketTags() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("hello<br>world", fillerWords: []), "helloworld")
    }

    func testCleanTranscriptKeepsComparisonWithSpaces() {
        // 「a < b > c」是用户真说出口的内容，尖括号过滤不能碰
        XCTAssertEqual(TextPostProcessor.cleanTranscript("a < b > c", fillerWords: []), "a < b > c")
    }

    func testCleanTranscriptStillStripsBracketMarkers() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("[BLANK_AUDIO]你好", fillerWords: []), "你好")
    }

    // MARK: 口水词

    func testFillerWordsRemoveLatinWholeWordOnly() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("um I think umbrella is fine", fillerWords: ["um"]),
                       "I think umbrella is fine")
    }

    func testFillerWordsKeepChineseWordInsideOtherWords() {
        // 「那个」在「那个人」里是词的一部分，绝不能删；句首的「嗯」连同残留的逗号一起清掉
        XCTAssertEqual(TextPostProcessor.cleanTranscript("嗯，那个人已经到了。", fillerWords: ["嗯", "那个"]),
                       "那个人已经到了。")
    }

    func testFillerWordsCollapseLeftoverPunctuation() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("我觉得，嗯，可以。", fillerWords: ["嗯"]),
                       "我觉得，可以。")
    }

    func testFillerWordsEmptyListLeavesTextUntouched() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("嗯，那个，好的。", fillerWords: []), "嗯，那个，好的。")
    }

    // MARK: 词表硬替换

    func testVocabReplacementPrefersLongestWrongForm() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "文档助手很好用",
            replacements: [("文档", "文件"), ("文档助手", "助手")]), "助手很好用")
    }

    func testVocabReplacementIsCaseInsensitiveForLatinAndKeepsRightCasing() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "Ios 和 IOS 都要改", replacements: [("ios", "iOS")]), "iOS 和 iOS 都要改")
    }

    func testVocabReplacementRespectsLatinWordBoundary() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "ai 和 aiming 不一样", replacements: [("ai", "AI")]), "AI 和 aiming 不一样")
    }

    func testVocabReplacementHasNoBoundaryRequirementForCJK() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "杰文说杰文今天到。", replacements: [("杰文", "捷文")]), "捷文说捷文今天到。")
    }

    func testVocabReplacementDoesNotChain() {
        // 单趟扫描：a→b 产出的 b 不再被 b→c 吃掉
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "a b", replacements: [("a", "b"), ("b", "c")]), "b c")
    }

    func testVocabReplacementWithEmptyListReturnsOriginal() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements("hello", replacements: []), "hello")
    }

    // MARK: 润色保真校验

    func testDriftCheckAcceptsNumberFormattingDifference() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "预算是 1000 块，不能再多了",
                                                        polished: "预算是 1,000 块，不能再多了。"))
    }

    func testDriftCheckRejectsChangedDigits() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "预算是 1000 块", polished: "预算是 100 块"))
    }

    func testDriftCheckRejectsSwallowedNegations() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(
            raw: "我不去，他也不去，这件事不行，没人同意，无解。", polished: "大家都同意这件事。"))
    }

    func testDriftCheckToleratesOneNegationDifference() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "这个我不太确定", polished: "这个我不确定。"))
    }

    func testDriftCheckRejectsOverAggressiveShortening() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: String(repeating: "啊", count: 60),
                                                           polished: String(repeating: "啊", count: 5)))
    }

    func testDriftCheckSkipsLengthRuleForShortInput() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "嗯嗯嗯就是说那个好的", polished: "好的。"))
    }

    func testDriftCheckRejectsEmptyPolishedText() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "今天开会", polished: "   "))
    }

    // MARK: 空音频复读（3.2.2）

    /// 默认口径要命中 ≥3 个词表词：正常音量那条路上不能因为一句话里出现一个词表词就丢掉
    func testVocabEchoNeedsThreeHitsByDefault() {
        XCTAssertTrue(TextPostProcessor.isVocabEcho("常用词汇：捷文", terms: ["捷文"]))
        XCTAssertFalse(TextPostProcessor.isVocabEcho("捷文", terms: ["捷文"]))
        XCTAssertTrue(TextPostProcessor.isVocabEcho("捷文、云术法、Rappel",
                                                    terms: ["捷文", "云术法", "Rappel"]))
    }

    /// 近静音那一档放宽到 1：词表只有一两条的用户，默认口径一个都兜不住——
    /// 没开口却被粘上一个热词，正是 3.2.2 要挡的那种事故
    func testVocabEchoRelaxedToOneHitForFaintAudio() {
        XCTAssertTrue(TextPostProcessor.isVocabEcho("捷文", terms: ["捷文"], minHits: 1))
        // 真的说了一整句（词表词只是其中一个词）不能被当成复读
        XCTAssertFalse(TextPostProcessor.isVocabEcho("帮我把捷文那份报告发出去",
                                                     terms: ["捷文"], minHits: 1))
    }

    // MARK: 诊断信息脱敏

    /// 日志尾巴会被「复制诊断信息」整段贴出去：绝对路径里的账户短名必须先换掉
    func testDiagnosticsRedactsHomePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let line = "2026-01-01 [INFO] Update script=\(home)/Library/Application Support/MicType/u.sh"
        let redacted = Diagnostics.redact(line)
        XCTAssertFalse(redacted.contains(home))
        XCTAssertTrue(redacted.contains("~/Library/Application Support/MicType/u.sh"))
    }

    /// 润色保真校验的失败原因只报个数，绝不带用户说过的数字本身（它会进日志 → 进诊断信息）
    func testPolishDriftReasonNeverCarriesTheDigits() {
        let reason = TextPostProcessor.polishDriftCheck(raw: "验证码是 4821", polished: "验证码是 4822")
        XCTAssertNotNil(reason)
        XCTAssertFalse(reason!.contains("4821"))
        XCTAssertFalse(reason!.contains("4822"))
        XCTAssertTrue(reason!.contains("digits changed"))
    }

    // MARK: 阿拉伯语安全（brief §3.4/§3.5）

    /// 阿语句读 ، ؟ ؛ 一律保持原样：换成 ASCII 就是改写用户说的话
    func testArabicPunctuationIsNeverConvertedToAscii() {
        let text = "مرحبا، كيف حالك؟ نلتقي غدا؛ إن شاء الله."
        XCTAssertEqual(TextPostProcessor.fixMixedPunctuation(text), text)
    }

    /// 阿英混说：全角标点后面跟的是阿语时不转半角——那是一句阿语，标点不归西文一侧管
    func testFullWidthPunctuationBeforeArabicIsLeftAlone() {
        XCTAssertEqual(TextPostProcessor.fixMixedPunctuation("اجتماع الـ board，غدا"),
                       "اجتماع الـ board，غدا")
        XCTAssertEqual(TextPostProcessor.fixMixedPunctuation("اجتماع الـ board， غدا"),
                       "اجتماع الـ board， غدا")
    }

    /// 中英那条老规则不能被阿语守卫误伤（回归）
    func testMixedPunctuationStillFixesLatinFollowedByChinese() {
        XCTAssertEqual(TextPostProcessor.fixMixedPunctuation("Open API，然后测试。"), "Open API, 然后测试。")
    }

    /// 绝不往阿语里插空格：补空格的"后随文字"类里没有阿语
    func testNoSpaceIsInsertedInsideArabic() {
        XCTAssertEqual(TextPostProcessor.fixMixedPunctuation("مرحبا,العالم"), "مرحبا,العالم")
    }

    /// 阿语靠前后缀粘连成词：「الذكاء」在「بالذكاء」内部绝不能被词表替换命中
    func testVocabReplacementRespectsArabicWordBoundary() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "بالذكاء الاصطناعي", replacements: [("الذكاء", "AI")]), "بالذكاء الاصطناعي")
    }

    /// 独立成词时照常替换（词边界不能严到把真该替换的也挡掉）
    func testVocabReplacementStillMatchesStandaloneArabicWord() {
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "الذكاء الاصطناعي مهم", replacements: [("الذكاء", "AI")]), "AI الاصطناعي مهم")
        // 阿语句读是边界，不是词的一部分
        XCTAssertEqual(TextPostProcessor.applyVocabReplacements(
            "نعم، الذكاء؟", replacements: [("الذكاء", "AI")]), "نعم، AI؟")
    }

    /// 口水词过滤把阿语句读当边界，删完的重复读点要合并
    func testFillerRemovalTreatsArabicPunctuationAsBoundary() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("مرحبا، يعني، العالم", fillerWords: ["يعني"]),
                       "مرحبا، العالم")
    }

    // MARK: 阿拉伯-印度数字策略

    /// 当前策略是「保持模型原样」——实测（brief §3.6 的数字语料）之前不归一
    func testArabicIndicDigitsAreKeptAsIs() {
        XCTAssertEqual(TextPostProcessor.arabicIndicDigitsPolicy, .keep)
        XCTAssertEqual(TextPostProcessor.applyArabicIndicDigitsPolicy("الموعد ٢٠٢٦"), "الموعد ٢٠٢٦")
        XCTAssertEqual(TextPostProcessor.cleanTranscript("الموعد ٢٠٢٦", fillerWords: []), "الموعد ٢٠٢٦")
    }

    /// 翻策略的那一天要用的转换已经就位：改常量即生效，不必再改调用点
    func testArabicIndicDigitsNormalizerIsReadyForTheFlip() {
        XCTAssertEqual(TextPostProcessor.normalizeArabicIndicDigits("٢٠٢٦ و ۵"), "2026 و 5")
        XCTAssertEqual(TextPostProcessor.normalizeArabicIndicDigits("no digits"), "no digits")
    }

    /// 润色把 ٢٠٢٦ 写成 2026 是同一个数，不是"数字被改"——否则阿语永远用不上润色
    func testDriftCheckTreatsArabicIndicDigitsAsTheSameNumber() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "الموعد ٢٠٢٦", polished: "الموعد 2026."))
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "الموعد ٢٠٢٦", polished: "الموعد 2027."))
    }

    // MARK: 复读折叠（Qwen 官方阈值）

    /// 上游 issue #129 式的样本：同一个字重复约 2000 次。
    /// 老实现会先被 `(.{2,24}?)\1{2,}` 按"两个字一组"折叠成两个字，官方那条单字符规则
    /// 就再也够不着 20 次的门槛了——所以官方规则必须排在前面。
    func testCollapsesTwoThousandRepeatsOfASingleCharacter() {
        let text = "好" + String(repeating: "的", count: 2000)
        XCTAssertEqual(TextPostProcessor.collapseRepetitions(text), "好的")
        XCTAssertEqual(TextPostProcessor.cleanTranscript(text, fillerWords: []), "好的")
    }

    /// ≤20 字符的模式重复 ≥20 次 → 只留一份
    func testCollapsesShortPatternRepeatedTwentyTimes() {
        let text = String(repeating: "the day of ", count: 25)
        XCTAssertEqual(TextPostProcessor.collapseRepetitions(text), "the day of ")
    }

    /// 正常文本一个字都不许动：叠词（"谢谢"）、重复的标点都不是复读
    func testCollapseLeavesNormalTextAlone() {
        XCTAssertEqual(TextPostProcessor.collapseRepetitions("谢谢，今天的会议就到这里。"),
                       "谢谢，今天的会议就到这里。")
        XCTAssertEqual(TextPostProcessor.collapseRepetitions("hello hello"), "hello hello")
    }

    // MARK: 分段拼接

    /// 中文缝：不加空格（官方配方的 `" ".join` 对中文是错的）
    func testJoinsChineseSegmentsWithoutSpace() {
        XCTAssertEqual(TextPostProcessor.joinSegments(["今天下午三点开会。", "地点在二楼。"]),
                       "今天下午三点开会。地点在二楼。")
    }

    /// 西文缝：一个空格，且不许变成两个
    func testJoinsLatinSegmentsWithExactlyOneSpace() {
        XCTAssertEqual(TextPostProcessor.joinSegments(["we start at nine", "and finish by noon"]),
                       "we start at nine and finish by noon")
        XCTAssertEqual(TextPostProcessor.joinSegments(["we start at nine ", "  and finish by noon"]),
                       "we start at nine and finish by noon")
    }

    /// 阿语缝：同样要一个空格，否则两个词会粘成一个不存在的词
    func testJoinsArabicSegmentsWithOneSpace() {
        XCTAssertEqual(TextPostProcessor.joinSegments(["الاجتماع غدا", "في الساعة التاسعة"]),
                       "الاجتماع غدا في الساعة التاسعة")
    }

    /// 中英混缝：任一侧是拉丁字母就给空格
    func testJoinsMixedScriptsWithSpace() {
        XCTAssertEqual(TextPostProcessor.joinSegments(["会议纪要", "draft"]), "会议纪要 draft")
        XCTAssertEqual(TextPostProcessor.joinSegments(["draft", "会议纪要"]), "draft 会议纪要")
    }

    /// 段末的终止标点是模型断句的结果，拼接时一个都不许吞
    func testJoinKeepsTerminalPunctuation() {
        XCTAssertEqual(TextPostProcessor.joinSegments(["第一段。", "第二段！"]), "第一段。第二段！")
        XCTAssertEqual(TextPostProcessor.joinSegments(["Part one.", "Part two?"]),
                       "Part one. Part two?")
    }

    /// 空段（那一段全是静音）直接跳过，不许留下孤零零的空格
    func testJoinSkipsEmptySegments() {
        XCTAssertEqual(TextPostProcessor.joinSegments(["前半句", "", "后半句"]), "前半句后半句")
        XCTAssertEqual(TextPostProcessor.joinSegments(["", ""]), "")
        XCTAssertEqual(TextPostProcessor.joinSegments([]), "")
    }
}
