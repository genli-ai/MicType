using MicType.Win.Core;

namespace MicType.Windows.Tests;

public sealed class VocabularyTests
{
    [Fact]
    public void ParsesPlainTermsAndReplacements()
    {
        var parsed = AppSettings.ParseVocabulary("Gen, 杰文=捷文，Qwen");

        Assert.Equal(new[] { "Gen", "捷文", "Qwen" }, parsed.Terms);
        Assert.Equal(new (string Wrong, string Right)[] { ("杰文", "捷文") }, parsed.Replacements);
    }

    [Fact]
    public void ParsesFullWidthEqualsAndIgnoresInvalidEntries()
    {
        var parsed = AppSettings.ParseVocabulary("杰文＝捷文, =空, 缺=, 普通词");

        Assert.Equal(new[] { "捷文", "普通词" }, parsed.Terms);
        Assert.Equal(new (string Wrong, string Right)[] { ("杰文", "捷文") }, parsed.Replacements);
    }

    [Fact]
    public void ApplyVocabReplacementsReplacesAllOccurrences()
    {
        var text = TextPostProcessor.ApplyVocabReplacements(
            "杰文说杰文今天到。",
            new (string Wrong, string Right)[] { ("杰文", "捷文") });

        Assert.Equal("捷文说捷文今天到。", text);
    }

    [Fact]
    public void ApplyVocabReplacementsWithEmptyListReturnsOriginal()
    {
        Assert.Equal("hello", TextPostProcessor.ApplyVocabReplacements("hello", Array.Empty<(string Wrong, string Right)>()));
    }

    [Fact]
    public void ParsesMultipleWrongFormsForOneRightForm()
    {
        var parsed = AppSettings.ParseVocabulary("杰文|捷纹｜结文=捷文");

        Assert.Equal(new[] { "捷文" }, parsed.Terms);
        Assert.Equal(
            new (string Wrong, string Right)[] { ("杰文", "捷文"), ("捷纹", "捷文"), ("结文", "捷文") },
            parsed.Replacements);
    }

    [Fact]
    public void ParsesFillerWords()
    {
        Assert.Equal(new[] { "嗯", "那个", "um" }, AppSettings.ParseFillerWords("嗯，那个\num"));
    }

    [Fact]
    public void ApplyVocabReplacementsPrefersLongestWrongForm()
    {
        var text = TextPostProcessor.ApplyVocabReplacements(
            "文档助手很好用",
            new (string Wrong, string Right)[] { ("文档", "文件"), ("文档助手", "助手") });

        Assert.Equal("助手很好用", text);
    }

    [Fact]
    public void ApplyVocabReplacementsIsCaseInsensitiveForLatinAndKeepsRightCasing()
    {
        var text = TextPostProcessor.ApplyVocabReplacements(
            "Ios 和 IOS 都要改",
            new (string Wrong, string Right)[] { ("ios", "iOS") });

        Assert.Equal("iOS 和 iOS 都要改", text);
    }

    [Fact]
    public void ApplyVocabReplacementsRespectsLatinWordBoundary()
    {
        var text = TextPostProcessor.ApplyVocabReplacements(
            "ai 和 aiming 不一样",
            new (string Wrong, string Right)[] { ("ai", "AI") });

        Assert.Equal("AI 和 aiming 不一样", text);
    }

    [Fact]
    public void ApplyVocabReplacementsDoesNotChainReplacements()
    {
        // 单趟扫描：a→b 产出的 b 不再被 b→c 吃掉
        var text = TextPostProcessor.ApplyVocabReplacements(
            "a b",
            new (string Wrong, string Right)[] { ("a", "b"), ("b", "c") });

        Assert.Equal("b c", text);
    }
}
