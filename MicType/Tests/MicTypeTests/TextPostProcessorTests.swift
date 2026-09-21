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

    // MARK: 内置口水词（4.0.2 起不再需要用户自己填表）

    /// 用户一条都没填，内置表照样生效：这才是 4.0.2 的默认体验
    func testBuiltInFillersRunWithoutAnyUserList() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("嗯，那个，好的。", fillerWords: []), "好的。")
        XCTAssertEqual(TextPostProcessor.cleanTranscript("um, let's start", fillerWords: []), "let's start")
    }

    /// 这张表只许删"独立成分"：词里的同一个字、正经句子里的同一个词，一个都不许动。
    /// 这条比"能删掉多少口水词"重要得多——删错一次就是改写了用户说的话。
    func testBuiltInFillersNeverTouchRealWords() {
        for text in ["那个人已经到了。", "这个月的预算是 1000 块。", "他就是说话慢了点。",
                     "umbrella and uber are fine", "do you know the answer", "好啊。",
                     "بالذكاء الاصطناعي مهم"] {
            XCTAssertEqual(TextPostProcessor.cleanTranscript(text, fillerWords: []), text, text)
        }
    }

    /// 多词西文（you know）只在后面紧跟句读时才删：那是口水词的长相，
    /// 「do you know the answer」里的那两个词是句子本身
    func testBuiltInPhraseFillerNeedsTrailingPunctuation() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("I think, you know, it is fine", fillerWords: []),
                       "I think, it is fine")
        XCTAssertEqual(TextPostProcessor.cleanTranscript("you know it is fine", fillerWords: []),
                       "you know it is fine")
    }

    /// 阿语那几条走"两侧都是边界"的规则（阿语句读 ، ؟ ؛ 也算边界）
    func testBuiltInArabicFillersAreRemovedWhenStandalone() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("مرحبا، يعني، العالم", fillerWords: []),
                       "مرحبا، العالم")
    }

    /// 导入的老设置里那几条照旧生效，且与内置表用同一套规则
    func testImportedFillerWordsStillApplyOnTopOfTheBuiltInList() {
        XCTAssertEqual(TextPostProcessor.cleanTranscript("怎么说呢，我同意。", fillerWords: ["怎么说呢"]),
                       "我同意。")
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

    // MARK: 保真校验：否定词计数的清洗（4.1.5 误报，TODO 待修 bug 4）
    //
    // 4.1.5 的口径是逐字数「不没无别未」，两类东西被当成了否定：
    //   ① 口头自我纠正（「不不」「不对」独立成句）——删掉它们正是润色的本职；
    //   ② 压根不是否定的常用词（「识别」「特别」「未来」…）——这位用户几乎每句话都在说「识别」。
    // 日志里的形状：`negation drift raw=4 polished=0`，而那句话一个否定都没被吞。

    /// 用户那一句的形状：「我说错了……不不，云端的识别就是……」——
    /// 润色把口头的「不不」删掉、把「云端的识别」收紧成「云端识别」，两样都做对了
    func testDriftCheckAcceptsSpokenSelfCorrection() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "我说错了，不不，云端的识别就是转写加润色",
            polished: "我说错了，云端识别就是转写加润色。"))
    }

    /// 「不对」「没有没有」这类独立成句的纠正同理。
    /// 刻意**不拿数字举例**：自我修正掉的如果是个数字（「十点，不对，十一点」），
    /// 4.1.6 的数字指纹会因为"少了一个数"而拦下来——那是数字那条零容差规则的既定代价，
    /// 单独记在 NumericFingerprintTests.testSelfCorrectedNumberFallsBackToTheRawText 里
    func testDriftCheckAcceptsCorrectionInterjections() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "明天上午开会，不对，是下午开会", polished: "明天下午开会。"))
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "没有没有，这件事我来办", polished: "这件事我来办。"))
    }

    /// 英文口头禅同理（「no no, I mean…」/「no, no, …」两种写法都要认）
    func testDriftCheckAcceptsEnglishFillerNo() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "no no, I mean the cloud engine", polished: "I mean the cloud engine."))
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "no, no, I mean tomorrow", polished: "I mean tomorrow."))
    }

    /// 含「不没无别未」却不是否定的常用词：润色动了其中一个（合并、改写、删重复）
    /// 不该让整段回退
    func testDriftCheckAcceptsPolishTouchingNonNegationWords() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "这个识别特别准，未来的识别会更好", polished: "识别特别准，未来会更好。"))
    }

    /// 清洗表**不许**吃掉真的否定：这两句的计数必须还是 1 和 0
    /// （拦不拦得住是下面那条阈值的事，和口径无关）
    func testNegationCountStillSeesRealNegations() {
        XCTAssertEqual(TextPostProcessor.negationCount("我不去"), 1)
        XCTAssertEqual(TextPostProcessor.negationCount("我去"), 0)
        XCTAssertEqual(TextPostProcessor.negationCount("don't send it"), 1)
        XCTAssertEqual(TextPostProcessor.negationCount("send it"), 0)
        XCTAssertEqual(TextPostProcessor.negationCount("这个方案不行，我们别做了"), 2)
        XCTAssertEqual(TextPostProcessor.negationCount("这个方案行，我们做吧"), 0)
        // 只有**整段独占**句读之间才算口头禅：句子内部的否定一个都不摘
        XCTAssertEqual(TextPostProcessor.negationCount("没有问题"), 1)
        XCTAssertEqual(TextPostProcessor.negationCount("there is no way"), 1)
        XCTAssertEqual(TextPostProcessor.negationCount("我不是不想去"), 2)
    }

    /// 非否定词表的口径：整词摘掉，一个否定都不记
    func testNegationCountIgnoresCommonNonNegationWords() {
        XCTAssertEqual(TextPostProcessor.negationCount("识别特别准，未来无论如何都要做"), 0)
        XCTAssertEqual(TextPostProcessor.negationCount("差不多了，对不起，不好意思，了不起"), 0)
        XCTAssertEqual(TextPostProcessor.negationCount("不得不做"), 0)   // 「不得不」= 必须，是肯定
        XCTAssertEqual(TextPostProcessor.negationCount("区别、级别、性别、别人、别的"), 0)
    }

    /// 摘掉口头禅之后两段**不能粘成新词**：「…说不。」+「过来吧」若被接成「不过」，
    /// 就会被非否定词表整词摘掉——等于凭空吞掉一个真否定
    func testScrubDoesNotWeldNewWordsAcrossSentences() {
        XCTAssertEqual(TextPostProcessor.negationCount("他说不。过来吧"), 1)
    }

    /// 清洗之后照样拦得住"否定被吞"——这才是这道校验的本职
    func testDriftCheckStillRejectsFlippedNegations() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(
            raw: "这个方案不行，我们别做了", polished: "这个方案行，我们做吧。"))
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(
            raw: "don't send it, I never agreed", polished: "send it, I agreed."))
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(
            raw: "我不去，识别这件事也别做了", polished: "我去，识别这件事也做吧。"))
    }

    /// **一字翻转必须拦**（2a）：原有容差 `> max(1, raw/3)` 恰好漏掉"只有一个否定、
    /// 而它被吞了"这一种，而那正是代价最高的一种错。raw ≥ 2 → 0 原本就拦得住。
    func testSingleLostNegationIsRejected() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "我不去", polished: "我去"))
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "don't send it", polished: "send it"))
        // 失败原因里只有计数，没有用户说的话
        let reason = TextPostProcessor.polishDriftCheck(raw: "我不去", polished: "我去")
        XCTAssertEqual(reason, "negation lost raw=1 polished=0")
    }

    /// **刻意不做对称的那一条**：识别偶尔吞掉一个「不」，润色把它补回来是帮了忙——
    /// 0 → 1 拦下来等于把一次正确的修复丢进垃圾桶
    func testRestoredNegationIsNotRejected() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "他说他去", polished: "他说他不去。"))
    }

    /// A 不 A 疑问句是**疑问**不是否定：「你能不能帮我」→「你能帮我吗」是最常见的正常润色。
    /// 2a 收紧之后这一类不摘掉就会天天误报
    func testDriftCheckAcceptsANotAQuestions() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "你能不能帮我看一下", polished: "你能帮我看一下吗"))
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "是不是明天开会，对不对", polished: "是明天开会吗？"))
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "有没有人知道这件事", polished: "有人知道这件事吗？"))
    }

    /// 「要不然 / 不然 / 要不」= 否则、要么，提的是另一个选择，没否定任何一句话
    func testDriftCheckAcceptsOtherwiseWords() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "要不然我们明天再说", polished: "我们明天再说吧。"))
    }

    /// 真的还剩着否定的句子照样放行（2a 只在"一个不剩"时开火）
    func testDriftCheckAcceptsPolishThatKeepsTheNegation() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "嗯我今天不想去开会那个", polished: "我今天不想去开会。"))
    }

    /// A 不 A 与词表的**顺序**：A 不 A 必须先跑，否则「要不要」会先被词表里的「要不」
    /// 吃掉半截，剩下的「要」+ 漏下的那个不 被当成一个真否定记上
    func testANotAIsScrubbedBeforeTheWordTable() {
        XCTAssertEqual(TextPostProcessor.negationCount("你要不要来"), 0)
        XCTAssertEqual(TextPostProcessor.negationCount("有没有问题"), 0)
        XCTAssertEqual(TextPostProcessor.negationCount("行不行，好不好，会不会"), 0)
        // 但句子内部真正的否定一个都不许被它带走
        XCTAssertEqual(TextPostProcessor.negationCount("我不是不想去"), 2)
        XCTAssertEqual(TextPostProcessor.negationCount("这个方案不行，我们别做了"), 2)
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

    /// 只补了标点（阿语最需要的那种润色）→ 一定放行。
    /// 模型对阿语短句一个标点都不吐，补标点正是润色在这门语言上的主要工作。
    func testDriftCheckAllowsPunctuationOnlyChanges() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "الاجتماع غدا في الساعة التاسعة",
            polished: "الاجتماع غدا، في الساعة التاسعة."))
        XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: "今天下午三点开会 地点在二楼",
                                                        polished: "今天下午三点开会，地点在二楼。"))
    }

    /// 阿语的数字是**词**（خمسة 而不是 5）：润色把它写成数字属于 ITN，不是改数字
    func testDriftCheckAllowsArabicNumeralWordsBecomingDigits() {
        XCTAssertNil(TextPostProcessor.polishDriftCheck(
            raw: "لدينا خمسة اجتماعات اليوم",
            polished: "لدينا 5 اجتماعات اليوم."))
    }

    /// 但"新增"以外的一律照拦：删掉一个数字、改掉一位，在阿语里同样是事故
    func testDriftCheckStillRejectsChangedDigitsInArabic() {
        // 214 → 215：多重集不同（4 没了、5 冒出来）→ 拦住。
        // （214 → 241 这种纯换位按设计算同一组数字，见 digitMultiset 的注释）
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "الغرفة 214", polished: "الغرفة 215."))
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "الغرفة 214", polished: "الغرفة."))
        XCTAssertTrue(TextPostProcessor.digitsOnlyAdded(raw: [:], polished: ["5": 1]))
        XCTAssertFalse(TextPostProcessor.digitsOnlyAdded(raw: ["6": 1], polished: ["7": 1]))
    }

    /// 非阿语文本不吃这条容差：英文/中文的数字是模型直接听出来的，凭空多一个就是跑飞
    func testDriftCheckKeepsTheStrictDigitRuleForOtherScripts() {
        XCTAssertNotNil(TextPostProcessor.polishDriftCheck(raw: "we need five seats",
                                                           polished: "we need 5 seats"))
        XCTAssertFalse(TextPostProcessor.isMostlyArabic("we need five seats"))
        XCTAssertTrue(TextPostProcessor.isMostlyArabic("لدينا خمسة اجتماعات"))
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

    /// 阿语与西文混缝也是一个空格：阿语靠空格断词，和中日韩不是一回事
    func testJoinsArabicAndLatinWithOneSpace() {
        XCTAssertEqual(TextPostProcessor.joinSegments(["الاجتماع", "Power BI"]),
                       "الاجتماع Power BI")
        XCTAssertEqual(TextPostProcessor.joinSegments(["Power BI", "الاجتماع"]),
                       "Power BI الاجتماع")
        XCTAssertEqual(TextPostProcessor.joinSegments(["مرحبا", "بالعالم"]), "مرحبا بالعالم")
    }

    /// 只有"两侧都是中日韩"这一种情况不加分隔符
    func testOnlyCJKNeighboursJoinWithoutASeparator() {
        XCTAssertEqual(TextPostProcessor.joinSegments(["これは", "テスト"]), "これはテスト")
        XCTAssertEqual(TextPostProcessor.joinSegments(["안녕", "하세요"]), "안녕하세요")
        XCTAssertEqual(TextPostProcessor.joinSegments(["今天天气", "不错啊"]), "今天天气不错啊")
    }

    /// 下一段以收尾标点开头（上一句的尾巴被切过来了）→ 标点前不加空格
    func testJoinDoesNotSpaceBeforeTrailingPunctuation() {
        XCTAssertEqual(TextPostProcessor.joinSegments(["hello", ", world"]), "hello, world")
        XCTAssertEqual(TextPostProcessor.joinSegments(["done", "."]), "done.")
        XCTAssertEqual(TextPostProcessor.joinSegments(["الاجتماع", "، غدا"]), "الاجتماع، غدا")
    }

    /// 缝上永远不会出现两个空格（每段先去首尾空白再拼）
    func testJoinNeverProducesDoubleSpaces() {
        let joined = TextPostProcessor.joinSegments(["  one  ", " two ", "", "  three  "])
        XCTAssertEqual(joined, "one two three")
        XCTAssertFalse(joined.contains("  "))
    }

    // MARK: 短语级复读的止损

    /// 短语连着出现 3 次 = 模型掉进循环了：留第一份循环节，后面全砍掉。
    /// 探针录到的真实样本就是这个形状（语言漂移 → 开始翻译 → 循环到烧完 token），
    /// 循环节是 "the day of" 这三个词。
    func testCutsPhraseLevelRepetition() {
        let text = "we will meet the day of the day of the day of the day of the"
        XCTAssertEqual(TextPostProcessor.cutPhraseRepetition(text), "we will meet the day of")
    }

    /// 四词循环节同样要认（探针之外最常见的另一种形状）
    func testCutsFourWordPhraseLoop() {
        let text = "please send the report please send the report please send the report ok"
        XCTAssertEqual(TextPostProcessor.cutPhraseRepetition(text), "please send the report")
    }

    /// 单词重复不归它管（跨度不足 4 个词）：正常说话里的强调重复不许被砍
    func testKeepsShortEmphaticRepeats() {
        XCTAssertEqual(TextPostProcessor.cutPhraseRepetition("no no no we are not going"),
                       "no no no we are not going")
    }

    /// 阿语同样按词处理（阿语也靠空格断词）
    func testCutsPhraseLevelRepetitionInArabic() {
        let loop = "في الساعة التاسعة صباحا "
        let text = "الاجتماع " + String(repeating: loop, count: 4)
        let cut = TextPostProcessor.cutPhraseRepetition(text)
        XCTAssertEqual(cut, "الاجتماع في الساعة التاسعة صباحا")
    }

    /// 只重复两次不算循环：真实口述里"再说一遍"很常见，砍掉就是丢字
    func testKeepsPhraseRepeatedOnlyTwice() {
        let text = "the day of the the day of the and then we go"
        XCTAssertEqual(TextPostProcessor.cutPhraseRepetition(text), text)
    }

    /// 正常长文一个字都不许动
    func testPhraseCutLeavesNormalTextAlone() {
        let text = "we start at nine and finish by noon, then the review begins"
        XCTAssertEqual(TextPostProcessor.cutPhraseRepetition(text), text)
        XCTAssertEqual(TextPostProcessor.cutPhraseRepetition("短句"), "短句")
        XCTAssertEqual(TextPostProcessor.cutPhraseRepetition(""), "")
    }

    /// 清理管线里也要真的生效（按段做、拼接之前）
    func testCleanTranscriptCutsPhraseLoops() {
        let text = "the meeting is on the day of the day of the day of the day of the"
        let cleaned = TextPostProcessor.cleanTranscript(text, fillerWords: [])
        XCTAssertFalse(cleaned.contains("the day of the day of the day"))
    }
}
