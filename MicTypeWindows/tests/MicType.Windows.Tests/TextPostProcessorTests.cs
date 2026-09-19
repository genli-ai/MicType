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

    [Fact]
    public void FillerWordsEmptyListLeavesTextUntouched()
    {
        Assert.Equal("嗯，那个，好的。", TextPostProcessor.CleanTranscript("嗯，那个，好的。", Array.Empty<string>()));
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
}
