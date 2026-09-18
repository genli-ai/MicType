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
}
