using MicType.Win.Core;

namespace MicType.Windows.Tests;

public sealed class TextPostProcessorTests
{
    [Fact]
    public void VocabEchoDetectsPrefix()
    {
        Assert.True(TextPostProcessor.IsVocabEcho("常用词汇：Gen、MicType、Qwen", new[] { "Gen", "MicType", "Qwen" }));
    }

    [Fact]
    public void VocabEchoDetectsThreeHitsWithNoResidue()
    {
        Assert.True(TextPostProcessor.IsVocabEcho("Gen、MicType、Qwen。", new[] { "Gen", "MicType", "Qwen" }));
    }

    [Fact]
    public void VocabEchoDoesNotKillNormalSentence()
    {
        Assert.False(TextPostProcessor.IsVocabEcho("今天用 MicType 给 Gen 发消息。", new[] { "Gen", "MicType", "Qwen" }));
    }

    [Fact]
    public void FixMixedPunctuationConvertsFullWidthAfterEnglish()
    {
        Assert.Equal("Open API, 然后测试。", TextPostProcessor.FixMixedPunctuation("Open API，然后测试。"));
    }

    [Fact]
    public void FixMixedPunctuationKeepsChinesePunctuationAfterChinese()
    {
        Assert.Equal("你好，世界。", TextPostProcessor.FixMixedPunctuation("你好，世界。"));
    }

    [Fact]
    public void CleanTranscriptStripsEngineTokens()
    {
        Assert.Equal(
            "今天下午三点开会",
            TextPostProcessor.CleanTranscript("<|zh|><|NEUTRAL|>今天下午三点开会", Array.Empty<string>()));
    }

    [Fact]
    public void CleanTranscriptStripsAngleBracketTags()
    {
        Assert.Equal("helloworld", TextPostProcessor.CleanTranscript("hello<br>world", Array.Empty<string>()));
    }

    [Fact]
    public void CleanTranscriptKeepsComparisonWithSpaces()
    {
        // 「a < b > c」是用户真说出口的内容，尖括号过滤不能碰
        Assert.Equal("a < b > c", TextPostProcessor.CleanTranscript("a < b > c", Array.Empty<string>()));
    }

    [Fact]
    public void FillerWordsRemoveLatinWholeWordOnly()
    {
        Assert.Equal(
            "I think umbrella is fine",
            TextPostProcessor.CleanTranscript("um I think umbrella is fine", new[] { "um" }));
    }

    [Fact]
    public void FillerWordsKeepChineseWordInsideOtherWords()
    {
        // 「那个」在「那个人」里是词的一部分，绝不能删；句首的「嗯」连同残留的逗号一起清掉
        Assert.Equal(
            "那个人已经到了。",
            TextPostProcessor.CleanTranscript("嗯，那个人已经到了。", new[] { "嗯", "那个" }));
    }

    [Fact]
    public void FillerWordsCollapseLeftoverPunctuation()
    {
        Assert.Equal(
            "我觉得，可以。",
            TextPostProcessor.CleanTranscript("我觉得，嗯，可以。", new[] { "嗯" }));
    }

    // 内置口水词（与 Mac 端 4.0.2 同源：界面上没有这张表了，它自动生效）

    /// 用户一条都没填，内置表照样生效：这才是默认体验
    [Fact]
    public void BuiltInFillersRunWithoutAnyUserList()
    {
        Assert.Equal("好的。", TextPostProcessor.CleanTranscript("嗯，那个，好的。", Array.Empty<string>()));
        Assert.Equal("let's start", TextPostProcessor.CleanTranscript("um, let's start", Array.Empty<string>()));
    }

    /// 这张表只许删"独立成分"：词里的同一个字、正经句子里的同一个词，一个都不许动。
    /// 这条比"能删掉多少口水词"重要得多——删错一次就是改写了用户说的话。
    [Theory]
    [InlineData("那个人已经到了。")]
    [InlineData("这个月的预算是 1000 块。")]
    [InlineData("他就是说话慢了点。")]
    [InlineData("umbrella and uber are fine")]
    [InlineData("do you know the answer")]
    [InlineData("好啊。")]
    [InlineData("بالذكاء الاصطناعي مهم")]
    public void BuiltInFillersNeverTouchRealWords(string text)
    {
        Assert.Equal(text, TextPostProcessor.CleanTranscript(text, Array.Empty<string>()));
    }

    /// 多词西文（you know）只在后面紧跟句读时才删：那是口水词的长相，
    /// 「do you know the answer」里的那两个词是句子本身
    [Fact]
    public void BuiltInPhraseFillerNeedsTrailingPunctuation()
    {
        Assert.Equal("I think, it is fine",
            TextPostProcessor.CleanTranscript("I think, you know, it is fine", Array.Empty<string>()));
        Assert.Equal("you know it is fine",
            TextPostProcessor.CleanTranscript("you know it is fine", Array.Empty<string>()));
    }

    /// 用户自己填的 / 导入的那几条照旧生效，且与内置表用同一套规则
    [Fact]
    public void UserFillerWordsStillApplyOnTopOfTheBuiltInList()
    {
        Assert.Equal("我同意。", TextPostProcessor.CleanTranscript("怎么说呢，我同意。", new[] { "怎么说呢" }));
    }

    [Fact]
    public void DriftCheckAcceptsNumberFormattingDifference()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck("预算是 1000 块，不能再多了", "预算是 1,000 块，不能再多了。"));
    }

    [Fact]
    public void DriftCheckRejectsChangedDigits()
    {
        Assert.NotNull(TextPostProcessor.PolishDriftCheck("预算是 1000 块", "预算是 100 块"));
    }

    /// 润色保真校验的失败原因只报个数，绝不带用户说过的数字本身——
    /// DictationController 会把它原样 Log.Warn 进明文日志（保留 7 天，报故障时整包带走）。
    /// 与 Mac 端 TextPostProcessorTests.swift 的
    /// testPolishDriftReasonNeverCarriesTheDigits 一一对应。
    [Fact]
    public void DriftReasonNeverCarriesTheDigits()
    {
        var reason = TextPostProcessor.PolishDriftCheck("验证码是 4821", "验证码是 4822");
        Assert.NotNull(reason);
        Assert.DoesNotContain("4821", reason);
        Assert.DoesNotContain("4822", reason);
        Assert.Contains("digits changed", reason);
        // 数字字符一个都不许出现在"digits changed"之后的那几个字段名之外：
        // 只许是计数（rawCount/polishedCount/distinct）
        Assert.Contains("rawCount=", reason);
        Assert.Contains("polishedCount=", reason);
        Assert.Contains("distinct=", reason);
    }

    [Fact]
    public void DriftCheckRejectsSwallowedNegations()
    {
        Assert.NotNull(TextPostProcessor.PolishDriftCheck(
            "我不去，他也不去，这件事不行，没人同意，无解。",
            "大家都同意这件事。"));
    }

    [Fact]
    public void DriftCheckToleratesOneNegationDifference()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck("这个我不太确定", "这个我不确定。"));
    }

    [Fact]
    public void DriftCheckRejectsOverAggressiveShortening()
    {
        Assert.NotNull(TextPostProcessor.PolishDriftCheck(new string('啊', 60), new string('啊', 5)));
    }

    [Fact]
    public void DriftCheckSkipsLengthRuleForShortInput()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck("嗯嗯嗯就是说那个好的", "好的。"));
    }

    // 阿拉伯语安全：与 Mac 端 TextPostProcessorTests.swift 的同名用例一一对应

    /// 阿语句读 ، ؟ ؛ 一律保持原样：换成 ASCII 就是改写用户说的话
    [Fact]
    public void ArabicPunctuationIsNeverConvertedToAscii()
    {
        const string text = "مرحبا، كيف حالك؟ نلتقي غدا؛ إن شاء الله.";
        Assert.Equal(text, TextPostProcessor.FixMixedPunctuation(text));
    }

    /// 阿英混说：全角标点后面跟的是阿语时不转半角
    [Fact]
    public void FullWidthPunctuationBeforeArabicIsLeftAlone()
    {
        Assert.Equal("اجتماع الـ board，غدا", TextPostProcessor.FixMixedPunctuation("اجتماع الـ board，غدا"));
        Assert.Equal("اجتماع الـ board， غدا", TextPostProcessor.FixMixedPunctuation("اجتماع الـ board， غدا"));
    }

    /// 绝不往阿语里插空格（Windows 这边尤其要防：\p{L} 本来是含阿语字母的）
    [Fact]
    public void NoSpaceIsInsertedInsideArabic()
    {
        Assert.Equal("مرحبا,العالم", TextPostProcessor.FixMixedPunctuation("مرحبا,العالم"));
    }

    /// 阿语靠前后缀粘连成词：「الذكاء」在「بالذكاء」内部绝不能被词表替换命中
    [Fact]
    public void VocabReplacementRespectsArabicWordBoundary()
    {
        Assert.Equal("بالذكاء الاصطناعي", TextPostProcessor.ApplyVocabReplacements(
            "بالذكاء الاصطناعي", new (string Wrong, string Right)[] { ("الذكاء", "AI") }));
    }

    /// 独立成词时照常替换；阿语句读是边界，不是词的一部分
    [Fact]
    public void VocabReplacementStillMatchesStandaloneArabicWord()
    {
        Assert.Equal("AI الاصطناعي مهم", TextPostProcessor.ApplyVocabReplacements(
            "الذكاء الاصطناعي مهم", new (string Wrong, string Right)[] { ("الذكاء", "AI") }));
        Assert.Equal("نعم، AI؟", TextPostProcessor.ApplyVocabReplacements(
            "نعم، الذكاء؟", new (string Wrong, string Right)[] { ("الذكاء", "AI") }));
    }

    /// 口水词过滤把阿语句读当边界，删完的重复读点要合并
    [Fact]
    public void FillerRemovalTreatsArabicPunctuationAsBoundary()
    {
        Assert.Equal("مرحبا، العالم",
            TextPostProcessor.CleanTranscript("مرحبا، يعني، العالم", new[] { "يعني" }));
    }

    /// 当前策略是「保持模型原样」——实测之前不归一
    [Fact]
    public void ArabicIndicDigitsAreKeptAsIs()
    {
        Assert.Equal(TextPostProcessor.ArabicDigitsPolicy.Keep, TextPostProcessor.ArabicIndicDigitsPolicy);
        Assert.Equal("الموعد ٢٠٢٦", TextPostProcessor.ApplyArabicIndicDigitsPolicy("الموعد ٢٠٢٦"));
        Assert.Equal("الموعد ٢٠٢٦", TextPostProcessor.CleanTranscript("الموعد ٢٠٢٦", Array.Empty<string>()));
    }

    /// 翻策略的那一天要用的转换已经就位：改常量即生效
    [Fact]
    public void ArabicIndicDigitsNormalizerIsReadyForTheFlip()
    {
        Assert.Equal("2026 و 5", TextPostProcessor.NormalizeArabicIndicDigits("٢٠٢٦ و ۵"));
        Assert.Equal("no digits", TextPostProcessor.NormalizeArabicIndicDigits("no digits"));
    }

    /// 润色把 ٢٠٢٦ 写成 2026 是同一个数，不是"数字被改"
    [Fact]
    public void DriftCheckTreatsArabicIndicDigitsAsTheSameNumber()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck("الموعد ٢٠٢٦", "الموعد 2026."));
        Assert.NotNull(TextPostProcessor.PolishDriftCheck("الموعد ٢٠٢٦", "الموعد 2027."));
    }

    /// 两种热词前缀都要被复读检测认出来（Mac 端按会话语言二选一）
    [Fact]
    public void VocabEchoDetectsEnglishPrefix()
    {
        Assert.True(TextPostProcessor.IsVocabEcho("Common terms: Rappel", new[] { "Rappel" }));
    }

    /// 上游 issue #129 式的样本：同一个字重复约 2000 次。官方那条单字符规则必须排在
    /// `(.{2,24}?)\1{2,}` 之前，否则复读先被折叠成两个字，20 次的门槛就够不着了。
    /// 与 Mac 端 TextPostProcessorTests.testCollapsesTwoThousandRepeatsOfASingleCharacter 同源。
    [Fact]
    public void CollapsesTwoThousandRepeatsOfASingleCharacter()
    {
        var text = "好" + new string('的', 2000);
        Assert.Equal("好的", TextPostProcessor.CollapseRepetitions(text));
        Assert.Equal("好的", TextPostProcessor.CleanTranscript(text, Array.Empty<string>()));
    }

    /// ≤20 字符的模式重复 ≥20 次 → 只留一份
    [Fact]
    public void CollapsesShortPatternRepeatedTwentyTimes()
    {
        var text = string.Concat(Enumerable.Repeat("the day of ", 25));
        Assert.Equal("the day of ", TextPostProcessor.CollapseRepetitions(text));
    }

    /// 正常文本一个字都不许动：叠词、重复的词都不是复读
    [Fact]
    public void CollapseLeavesNormalTextAlone()
    {
        Assert.Equal("谢谢，今天的会议就到这里。",
            TextPostProcessor.CollapseRepetitions("谢谢，今天的会议就到这里。"));
        Assert.Equal("hello hello", TextPostProcessor.CollapseRepetitions("hello hello"));
    }

    /// 补空格只认西文与汉字：假名 / 谚文前不补，否则 Mac 出 "API,はい"、Windows 出 "API, はい"
    [Fact]
    public void NoSpaceIsInsertedBeforeKanaOrHangul()
    {
        Assert.Equal("API,はい", TextPostProcessor.FixMixedPunctuation("API，はい"));
        Assert.Equal("API,네", TextPostProcessor.FixMixedPunctuation("API，네"));
    }

    /// 西里尔 / 希伯来同理（引擎现在产不出来，但规则不该按"哪天被咬到再打补丁"写）
    [Fact]
    public void NoSpaceIsInsertedBeforeNonLatinLetters()
    {
        Assert.Equal("test,привет", TextPostProcessor.FixMixedPunctuation("test,привет"));
        Assert.Equal("test,שלום", TextPostProcessor.FixMixedPunctuation("test,שלום"));
    }

    /// 带变音符的西文照旧补空格（café / Việt 都在 \p{Latin} 里）
    [Fact]
    public void SpaceIsStillInsertedBeforeAccentedLatin()
    {
        Assert.Equal("ok, café", TextPostProcessor.FixMixedPunctuation("ok,café"));
        Assert.Equal("ok, Việt", TextPostProcessor.FixMixedPunctuation("ok,Việt"));
    }
}
