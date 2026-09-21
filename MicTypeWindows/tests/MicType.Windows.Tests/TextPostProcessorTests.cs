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

    // 否定词计数的清洗：与 Mac 端 TextPostProcessorTests.swift 的同名用例一一对应
    // （Mac 4.1.5 日志 `negation drift raw=4 polished=0`——那句话一个否定都没被吞，
    // 掉的是口头的「不不」和被数进去的「识别」）

    /// 口头自我纠正被润色删掉 = 润色做对了事，不该判成"否定被吞"
    [Fact]
    public void DriftCheckAcceptsSpokenSelfCorrection()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck(
            "我说错了，不不，云端的识别就是转写加润色", "我说错了，云端识别就是转写加润色。"));
        // 刻意**不拿数字举例**：自我修正掉的如果是个数字，4.1.6 的数字指纹会因为
        // "少了一个数"而拦下来（见 SelfCorrectedNumberFallsBackToTheRawText）
        Assert.Null(TextPostProcessor.PolishDriftCheck(
            "明天上午开会，不对，是下午开会", "明天下午开会。"));
    }

    /// 英文口头禅同理（「no no, I mean…」/「no, no, …」两种写法都要认）
    [Fact]
    public void DriftCheckAcceptsEnglishFillerNo()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck(
            "no no, I mean the cloud engine", "I mean the cloud engine."));
        Assert.Null(TextPostProcessor.PolishDriftCheck("no, no, I mean tomorrow", "I mean tomorrow."));
    }

    /// 含「不没无别未」却不是否定的常用词：润色动了其中一个不该让整段回退
    [Fact]
    public void DriftCheckAcceptsPolishTouchingNonNegationWords()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck(
            "这个识别特别准，未来的识别会更好", "识别特别准，未来会更好。"));
    }

    /// 清洗表**不许**吃掉真的否定
    [Fact]
    public void NegationCountStillSeesRealNegations()
    {
        Assert.Equal(1, TextPostProcessor.NegationCount("我不去"));
        Assert.Equal(0, TextPostProcessor.NegationCount("我去"));
        Assert.Equal(1, TextPostProcessor.NegationCount("don't send it"));
        Assert.Equal(2, TextPostProcessor.NegationCount("这个方案不行，我们别做了"));
        // 只有**整段独占**句读之间才算口头禅：句子内部的否定一个都不摘
        Assert.Equal(1, TextPostProcessor.NegationCount("没有问题"));
        Assert.Equal(1, TextPostProcessor.NegationCount("there is no way"));
        Assert.Equal(2, TextPostProcessor.NegationCount("我不是不想去"));
    }

    /// 非否定词表的口径：整词摘掉，一个否定都不记
    [Fact]
    public void NegationCountIgnoresCommonNonNegationWords()
    {
        Assert.Equal(0, TextPostProcessor.NegationCount("识别特别准，未来无论如何都要做"));
        Assert.Equal(0, TextPostProcessor.NegationCount("差不多了，对不起，不好意思，了不起"));
        Assert.Equal(0, TextPostProcessor.NegationCount("不得不做"));   // 「不得不」= 必须，是肯定
    }

    /// 摘掉口头禅之后两段**不能粘成新词**：「…说不。」+「过来吧」若被接成「不过」，
    /// 就会被非否定词表整词摘掉——等于凭空吞掉一个真否定
    [Fact]
    public void ScrubDoesNotWeldNewWordsAcrossSentences()
    {
        Assert.Equal(1, TextPostProcessor.NegationCount("他说不。过来吧"));
    }

    /// 清洗之后照样拦得住"否定被吞"——这才是这道校验的本职
    [Fact]
    public void DriftCheckStillRejectsFlippedNegations()
    {
        Assert.NotNull(TextPostProcessor.PolishDriftCheck("这个方案不行，我们别做了", "这个方案行，我们做吧。"));
        Assert.NotNull(TextPostProcessor.PolishDriftCheck("don't send it, I never agreed", "send it, I agreed."));
        Assert.NotNull(TextPostProcessor.PolishDriftCheck("我不去，识别这件事也别做了", "我去，识别这件事也做吧。"));
    }

    /// **一字翻转必须拦**（2a）：原有容差 > max(1, raw/3) 恰好漏掉"只有一个否定、
    /// 而它被吞了"这一种，而那正是代价最高的一种错。Mac 端同源。
    [Fact]
    public void SingleLostNegationIsRejected()
    {
        Assert.NotNull(TextPostProcessor.PolishDriftCheck("我不去", "我去"));
        Assert.NotNull(TextPostProcessor.PolishDriftCheck("don't send it", "send it"));
        // 失败原因里只有计数，没有用户说的话
        Assert.Equal("negation lost raw=1 polished=0", TextPostProcessor.PolishDriftCheck("我不去", "我去"));
    }

    /// **刻意不做对称的那一条**：识别偶尔吞掉一个「不」，润色把它补回来是帮了忙
    [Fact]
    public void RestoredNegationIsNotRejected()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck("他说他去", "他说他不去。"));
    }

    /// A 不 A 疑问句是**疑问**不是否定：「你能不能帮我」→「你能帮我吗」是正常润色
    [Fact]
    public void DriftCheckAcceptsANotAQuestions()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck("你能不能帮我看一下", "你能帮我看一下吗"));
        Assert.Null(TextPostProcessor.PolishDriftCheck("是不是明天开会，对不对", "是明天开会吗？"));
        Assert.Null(TextPostProcessor.PolishDriftCheck("有没有人知道这件事", "有人知道这件事吗？"));
    }

    /// 「要不然 / 不然 / 要不」= 否则、要么，没否定任何一句话
    [Fact]
    public void DriftCheckAcceptsOtherwiseWords()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck("要不然我们明天再说", "我们明天再说吧。"));
    }

    /// 真的还剩着否定的句子照样放行（2a 只在"一个不剩"时开火）
    [Fact]
    public void DriftCheckAcceptsPolishThatKeepsTheNegation()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck("嗯我今天不想去开会那个", "我今天不想去开会。"));
    }

    /// A 不 A 与词表的**顺序**：A 不 A 必须先跑，否则「要不要」会先被「要不」吃掉半截
    [Fact]
    public void ANotAIsScrubbedBeforeTheWordTable()
    {
        Assert.Equal(0, TextPostProcessor.NegationCount("你要不要来"));
        Assert.Equal(0, TextPostProcessor.NegationCount("有没有问题"));
        Assert.Equal(0, TextPostProcessor.NegationCount("行不行，好不好，会不会"));
        // 但句子内部真正的否定一个都不许被它带走
        Assert.Equal(2, TextPostProcessor.NegationCount("我不是不想去"));
        Assert.Equal(2, TextPostProcessor.NegationCount("这个方案不行，我们别做了"));
    }

    // 数字指纹（4.1.6）：与 Mac 端 NumericFingerprintTests.swift 的同名用例一一对应。
    // 润色从这一版起要把汉字数字改写成阿拉伯数字（提示词第 7 条），保真校验必须看懂
    // 「一百零一」和「101」是同一个数——否则每一次正确的改写都会被判成 digits changed。

    private static (string Digits, string Wildcards) Fingerprint(string text)
    {
        var fp = TextPostProcessor.NumericFingerprint(text);
        return (TextPostProcessor.DigitSummary(fp.Digits), TextPostProcessor.DigitSummary(fp.Wildcards));
    }

    [Theory]
    [InlineData("十", "01")]                      // 10
    [InlineData("十二", "12")]                    // 打头的十是 1
    [InlineData("二十", "02")]
    [InlineData("一百零一", "011")]                // 101：念了「零」，尾数就是个位
    [InlineData("一百一十", "011")]                // 110
    [InlineData("一千零五十", "0015")]
    [InlineData("七百三十二", "237")]
    [InlineData("一万二千", "00012")]
    [InlineData("三千五百万", "00000035")]
    [InlineData("十万", "000001")]
    [InlineData("一亿二千万", "000000012")]
    [InlineData("两千五", "0025")]                 // 省略的尾数：2500，不是 2005
    [InlineData("三百五", "035")]
    [InlineData("一万二", "00012")]
    [InlineData("二零一一", "0112")]               // 没单位的多字串 = 一串数位
    [InlineData("二零一八", "0128")]
    [InlineData("幺三八零零幺三八零零零", "00000113388")]
    [InlineData("两三", "23")]
    [InlineData("1.2万", "00012")]                // 阿拉伯数字 + 汉字单位
    [InlineData("3500万", "00000035")]
    [InlineData("2亿", "000000002")]
    [InlineData("1.25万", "00125")]
    [InlineData("3000万", "00000003")]
    [InlineData("百分之二十", "02")]
    [InlineData("百分之三十五", "35")]
    [InlineData("20%", "02")]
    [InlineData("12,000", "00012")]
    [InlineData("１２３", "123")]                  // 全角折半角
    [InlineData("十分钟", "01")]                   // 十分钟 = 10 分钟
    [InlineData("三千万", "00000003")]             // 前面挨着数字就是数
    [InlineData("万一", "")]                       // 成语：不是数
    [InlineData("十分重要", "")]
    [InlineData("千万别迟到", "")]
    [InlineData("星期三", "")]
    [InlineData("上万人", "")]                     // 光秃秃一个单位字是约数
    public void NumericFingerprintNormalizesTheWayNumbersAreWritten(string text, string digits)
    {
        Assert.Equal(digits, Fingerprint(text).Digits);
    }

    /// 单个汉字数字、没有单位 → 不算数，只记通配
    [Theory]
    [InlineData("三个人", "", "3")]
    [InlineData("一点五", "", "15")]               // 1.5
    [InlineData("四点一点六", "", "146")]           // 版本号 4.1.6
    [InlineData("第一次", "", "1")]
    [InlineData("十二块五", "12", "5")]
    [InlineData("三点半", "", "3")]
    public void BareNumeralsBecomeWildcards(string text, string digits, string wildcards)
    {
        var fp = Fingerprint(text);
        Assert.Equal(digits, fp.Digits);
        Assert.Equal(wildcards, fp.Wildcards);
    }

    /// 2026-09-21 在 qwen3.8-flash 上实测的七句：每一句在 4.1.5 都会被判成 digits changed
    [Theory]
    [InlineData("一共是一百零一人民币然后运费另外算十二块五", "一共是101人民币，运费另外算12块5。")]
    [InlineData("我是二零一一年毕业的然后二零一九年三月十五号来的", "我是2011年毕业的，2019年3月15日来的。")]
    [InlineData("下午三点半开会大概两三个人参加十分重要你们千万别迟到", "下午3点半开会，大概两三个人参加，十分重要，你们千万别迟到。")]
    [InlineData("增长了百分之二十左右大概有一万二千个用户其中三分之一是付费的", "增长了20%左右，大概有1.2万个用户，其中三分之一是付费的。")]
    [InlineData("电话是幺三八零零幺三八零零零房间号是二零一八", "电话是13800138000，房间号是2018。")]
    [InlineData("第一次来万一迟到了你先等我一下我们一起走", "第一次来，万一迟到了你先等我一下，我们一起走。")]
    [InlineData("版本四点一点六修了三个问题跑了七百三十二个测试", "版本4.1.6修了3个问题，跑了732个测试。")]
    [InlineData("等十分钟", "等10分钟")]
    [InlineData("涨了三千万", "涨了3000万")]
    [InlineData("来了三个人", "来了3个人")]
    [InlineData("这件事十分重要", "这件事非常重要")]
    [InlineData("万一他不来呢", "如果他不来呢")]
    [InlineData("预算是一千块", "预算是1000块")]
    [InlineData("走了三点五公里", "走了3.5公里")]
    [InlineData("大概有一万二", "大概有1.2万")]
    [InlineData("百分之二十的人", "20%的人")]
    public void RewritingHowANumberIsWrittenPasses(string raw, string polished)
    {
        Assert.True(TextPostProcessor.NumbersPreserved(raw, polished));
        Assert.Null(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// 数值真的变了 → 照样拦
    [Theory]
    [InlineData("一共一百零一块", "一共102块")]
    [InlineData("我是二零一一年毕业的", "我是2012年毕业的")]
    [InlineData("运费十二块五", "运费12块8")]
    [InlineData("增长了百分之二十", "增长了30%")]
    [InlineData("来了三个人", "来了5个人")]
    [InlineData("大概有一万二千个用户", "大概有1.3万个用户")]
    [InlineData("一共是一百零一块运费另外十二块", "一共是101块")]
    [InlineData("今天开会讨论了方案", "今天开会讨论了50个方案")]
    [InlineData("电话是幺三八零零幺三八零零零", "电话是1380013800")]
    public void ChangedNumbersAreRejected(string raw, string polished)
    {
        Assert.NotNull(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// **4.1.6 的既定代价**：说话人口头改了一个数字，润色把说错的那个删掉——
    /// 从数字指纹看就是"少了一个数"，而数字这条是零容差的，于是回退原文（方向是安全的）
    [Fact]
    public void SelfCorrectedNumberFallsBackToTheRawText()
    {
        Assert.NotNull(TextPostProcessor.PolishDriftCheck("明天上午十点，不对，是十一点", "明天上午11点。"));
        Assert.Null(TextPostProcessor.PolishDriftCheck("明天上午开会，不对，是下午开会", "明天下午开会。"));
    }

    /// 第二层：零的位置错了 / 数位调了个儿——这几对的数字字符多重集**一模一样**，
    /// 第一层一个都拦不住
    [Theory]
    [InlineData("一共一百零一块", "一共110块")]
    [InlineData("一共一万零二百块", "一共12000块")]
    [InlineData("一共一万二千块", "一共10200块")]
    [InlineData("预算一千零五十", "预算1500")]
    [InlineData("我是二零一九年来的", "我是2091年来的")]
    [InlineData("一共十二个", "一共21个")]
    [InlineData("电话是幺三八零零幺三八零零零", "电话是13008138000")]
    public void ZeroPlacementAndTranspositionAreRejected(string raw, string polished)
    {
        Assert.False(TextPostProcessor.NumbersPreserved(raw, polished));
        Assert.NotNull(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// 先钉住"第一层确实看不出来"，免得以后有人以为上面那几条是多余的
    [Fact]
    public void TheDigitMultisetAloneCannotSeeZeroPlacement()
    {
        Assert.Equal(Fingerprint("一百零一").Digits, Fingerprint("110").Digits);
        Assert.Equal(Fingerprint("一万零二百").Digits, Fingerprint("12000").Digits);
        Assert.Equal(Fingerprint("一千零五十").Digits, Fingerprint("1500").Digits);
    }

    /// 同一个数换了写法、加了单位、接了小数、改了标点——第二层一律放行（"包含"不是"相等"）
    [Theory]
    [InlineData("运费十二块五", "运费12.5元")]
    [InlineData("大概有一万二千个用户", "大概有1.2万个用户")]
    [InlineData("大概有一万二千个用户", "大概有12000个用户")]
    [InlineData("大概有一万二千个用户", "大概有12,000个用户")]
    [InlineData("电话是幺三八零零幺三八零零零", "电话是138-0013-8000")]
    [InlineData("电话是幺三八零零幺三八零零零", "电话是138 0013 8000")]
    [InlineData("涨了三千五百万", "涨了3500万")]
    [InlineData("12,000 users", "12000 users")]
    [InlineData("版本四点一点六", "版本4.1.6")]
    [InlineData("我是二零一一年毕业的", "我是2011年毕业的。")]
    public void TheSameNumberWrittenDifferentlyStillPasses(string raw, string polished)
    {
        Assert.True(TextPostProcessor.NumbersPreserved(raw, polished));
        Assert.Null(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// token 只收 ≥ 2 位：单个数字归第一层的多重集 + wildcard 管
    [Fact]
    public void NumberTokensOnlyCoverMultiDigitNumbers()
    {
        Assert.Equal(new[] { "101", "12000" }, TextPostProcessor.NumberTokens("101 和 12000"));
        Assert.Empty(TextPostProcessor.NumberTokens("4.1.6"));
        Assert.Empty(TextPostProcessor.NumberTokens("3 个人 5 点到"));
        Assert.Equal(new[] { "2011" }, TextPostProcessor.NumberTokens("2011 和 2011"));
    }

    /// 口语式的省略尾数，阿拉伯数字版
    [Theory]
    [InlineData("1万2", "00012")]      // 12000
    [InlineData("3千5", "0035")]       // 3500
    [InlineData("2百5", "025")]        // 250
    public void ArabicAbbreviatedTail(string text, string digits)
    {
        Assert.Equal(digits, Fingerprint(text).Digits);
    }

    /// **仍然抓不住的那一种（诚实记在这里）**：两个各自只有一位的数互相换了位置
    [Fact]
    public void StillNotCaughtTwoSingleDigitNumbersSwapping()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck("三个人五点到", "5个人3点到"));
    }

    // 4.2.1：编号列表 / 时间 / 英文数字（与 Mac 端 NumericFingerprintTests 同名用例一一对应）

    /// 提示词第 8 条**要求**润色把多个要点整理成编号列表，于是成品里凭空多出「1. 2. 3.」——
    /// 原文里一个数字都没有。长口述最需要润色，却每次都被这道校验拦下
    [Theory]
    [InlineData("首先要把合同发出去然后给客户回个电话最后把报销单交了",
                "1. 把合同发出去\n2. 给客户回电话\n3. 提交报销单")]
    [InlineData("主要有三点第一个是时间第二个是人手第三个是预算", "主要有三点：1. 时间；2. 人手；3. 预算。")]
    [InlineData("两件事一个是合同一个是发票", "两件事：(1) 合同 (2) 发票")]
    public void NumberedListMarkersPass(string raw, string polished)
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// 引出句里的**条数**也是润色数出来的，不是说话人说的
    /// （联网实测：说话人说「有几个问题」，模型写「目前主要有3个问题：」+ 1. 2. 3.）
    [Fact]
    public void ListCountInTheLeadInSentenceIsCovered()
    {
        const string raw = "这个项目现在有几个问题嗯首先是时间太紧我们原来定的是这个月底但是现在看起来肯定来不及"
            + "然后就是人手也不够本来说好的两个人现在只有一个人还有就是预算这块其实已经超了一些了"
            + "所以我的想法是要么我们把范围砍一砍要么就往后推一推大概就是这个意思你看一下";
        const string polished = "关于这个项目，目前主要有3个问题：\n1. 时间太紧，原定本月底完成；"
            + "\n2. 人手不足：原计划2人，现仅1人；\n3. 预算超支。\n建议缩减范围或推迟交付。";
        Assert.Null(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// **联网实测抓到的那一句**：润色一边把「两个人 / 一个人」转成「2人 / 1人」，
    /// 一边自己新造了「三个问题」「二选一」——4.2.1 之前 extra 池要减去润色侧的 wildcard，
    /// 新造的那个「二」正好抵掉了本该解释「2人」的 wildcard 2
    [Fact]
    public void PolishMintingItsOwnChineseNumeralsDoesNotCancelTheRawWildcards()
    {
        const string raw = "这个项目现在有几个问题嗯首先是时间太紧我们原来定的是这个月底但是现在看起来肯定来不及"
            + "然后就是人手也不够本来说好的两个人现在只有一个人还有就是预算这块其实已经超了一些了"
            + "所以我的想法是要么我们把范围砍一砍要么就往后推一推大概就是这个意思你看一下";
        const string polished = "关于这个项目，目前主要有三个问题：\n1. 时间太紧，原定月底完成，现在看肯定来不及；"
            + "\n2. 人手不够，原计划2人，现在只有1人；\n3. 预算已超支。"
            + "\n建议二选一：要么缩减项目范围，要么延后交付时间。请看一下。";
        Assert.Null(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// **已知代价，诚实记在这里**：原文里的孤立汉字数字可以解释一个同值的阿拉伯数字，
    /// 哪怕那个汉字还留在成品里。换来的是上面那一类不再被误杀
    [Fact]
    public void KnownCostABareNumeralCanExplainOneSameValuedDigit()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck("三个人来", "三个人来，花了3小时"));
    }

    /// 底线没松：原文一个数字都没有就兜不住；值不对照样拦
    [Theory]
    [InlineData("今天开会讨论了方案", "今天开会讨论了3个方案")]
    [InlineData("本来说好的两个人", "本来说好5人")]
    public void TheExtraPoolStillHasABottomLine(string raw, string polished)
    {
        Assert.NotNull(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// 条数说错了、或条目里凭空冒出数字，照样拦
    [Theory]
    [InlineData("这几个事都得办合同要发邮件要回会议室要订",
                "主要有4个问题：\n1. 发合同\n2. 回邮件\n3. 订会议室")]
    [InlineData("这几个事都得办预算要定延期要谈人手要补",
                "主要有3个问题：\n1. 预算50万\n2. 延期\n3. 补人手")]
    public void WrongListCountOrInventedItemNumberIsRejected(string raw, string polished)
    {
        Assert.NotNull(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// 列表条数那桶软数字出身在**润色侧**，只解释润色多出来的位
    [Fact]
    public void ListCountSoftDigitsOnlyExplainPolishedExtras()
    {
        Assert.Equal("3", TextPostProcessor.DigitSummary(
            TextPostProcessor.NumericFingerprint("有3件事：\n1. 甲\n2. 乙\n3. 丙").ListCountDigits));
        Assert.Empty(TextPostProcessor.NumericFingerprint("有3件事").ListCountDigits);
        // 原文说了数字、润色把它丢了 —— 列表条数不能替它开脱
        Assert.NotNull(TextPostProcessor.PolishDriftCheck("预算是一百零一万还有三件事要办",
                                                          "有3件事：\n1. 甲\n2. 乙\n3. 丙"));
    }

    /// 列表项**里面**的真数字照样一位不许变；假列表也偷渡不进来
    [Fact]
    public void ListMarkersDoNotWeakenTheGuard()
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck("第一预算是一百零一万第二时间要两周",
                                                       "1. 预算101万\n2. 时间两周"));
        Assert.NotNull(TextPostProcessor.PolishDriftCheck("第一预算是一百零一万第二时间要两周",
                                                          "1. 预算102万\n2. 时间两周"));
        Assert.NotNull(TextPostProcessor.PolishDriftCheck("预算的事还要再看看延期的事也要定下来",
                                                          "1. 预算50万\n2. 延期"));
    }

    /// 只有连成 1,2,…,n（n ≥ 2）才算列表；别的一律当数据
    [Theory]
    [InlineData("版本4.1.6", 0)]
    [InlineData("1.5元，2.5元", 0)]
    [InlineData("1. 只有一条", 0)]
    [InlineData("3. 这个 5. 那个", 0)]
    [InlineData("1. 这个\n2. 那个", 2)]
    public void OnlyAConsecutiveSequenceCountsAsAList(string text, int markers)
    {
        Assert.Equal(markers, TextPostProcessor.StrippedOfListMarkers(text).Markers);
    }

    /// 「一点」以前被整条当口头禅摘掉，润色写出来的「1点」于是成了没人认领的多余数字
    [Theory]
    [InlineData("明天下午一点开会", "明天下午1点开会")]
    [InlineData("一点到三点都有空", "1点到3点都有空")]
    [InlineData("三点十分结束", "3点10分结束")]
    [InlineData("三点十分结束", "3:10结束")]
    [InlineData("下午三点半再碰一次", "下午3点半再碰一次")]
    [InlineData("下午三点半再碰一次", "下午3:30再碰一次")]
    [InlineData("下午三点半再碰一次", "下午15:30再碰一次")]
    [InlineData("晚上八点一刻出发", "晚上8:15出发")]
    [InlineData("有一点累", "有点累")]
    public void ClockHoursSurvive(string raw, string polished)
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// 钟点改错了照样拦——软数字只解释"说法自带的那几位"
    [Theory]
    [InlineData("下午三点开会", "下午16:00开会")]
    [InlineData("三点十分结束", "3点20分结束")]
    [InlineData("一点到三点", "1点到4点")]
    public void WrongClockTimeIsStillRejected(string raw, string polished)
    {
        Assert.NotNull(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// 「十分」的两副面孔：前面挨着点 / 数字时是 10，别处是"非常"
    [Theory]
    [InlineData("三点十分", "01")]
    [InlineData("四十分钟", "04")]
    [InlineData("十分重要", "")]
    [InlineData("这件事十分好", "")]
    public void TenMinutesVersusVeryMuch(string text, string digits)
    {
        Assert.Equal(digits, Fingerprint(text).Digits);
    }

    /// 软数字：点半 → 30、点一刻 → 15、点三刻 → 45、下午 N 点 → N+12
    [Theory]
    [InlineData("三点半", "03")]
    [InlineData("八点一刻", "15")]
    [InlineData("九点三刻", "45")]
    [InlineData("下午三点", "15")]
    [InlineData("上午三点", "")]
    public void SoftDigitsComeFromTimeWords(string text, string soft)
    {
        Assert.Equal(soft, TextPostProcessor.DigitSummary(TextPostProcessor.SoftDigits(text)));
    }

    /// 英文数字词：模型自己就会把 "twenty five dollars" 写成 "$25"
    [Theory]
    [InlineData("it costs twenty five dollars", "It costs $25.")]
    [InlineData("let's meet on March third", "Let's meet on March 3.")]
    [InlineData("let's meet on March third", "Let's meet on March 3rd.")]
    [InlineData("call me at nine thirty", "Call me at 9:30.")]
    [InlineData("we shipped it in two thousand twenty six", "We shipped it in 2026.")]
    [InlineData("we shipped it in twenty twenty six", "We shipped it in 2026.")]
    [InlineData("there were a hundred and one issues", "There were 101 issues.")]
    [InlineData("three people came", "3 people came.")]
    [InlineData("one of the things we discussed", "One thing we discussed.")]
    public void EnglishNumberWordsPass(string raw, string polished)
    {
        Assert.Null(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// 英文数值改了照样拦
    [Theory]
    [InlineData("it costs twenty five dollars", "It costs $35.")]
    [InlineData("fifteen people came", "50 people came.")]
    [InlineData("we need more seats", "we need 5 seats")]
    public void EnglishNumbersChangedAreRejected(string raw, string polished)
    {
        Assert.NotNull(TextPostProcessor.PolishDriftCheck(raw, polished));
    }

    /// 英文数字的口径对照表
    [Theory]
    [InlineData("twenty five", "25", "")]
    [InlineData("twenty-five", "25", "")]
    [InlineData("Twenty Five", "25", "")]
    [InlineData("fifteen", "15", "")]
    [InlineData("a hundred and one", "011", "")]
    [InlineData("two thousand twenty six", "0226", "")]
    [InlineData("twenty twenty six", "0226", "")]
    [InlineData("nine thirty", "03", "9")]
    [InlineData("three", "", "3")]
    [InlineData("March third", "", "3")]
    [InlineData("none someone often tension anyone", "", "")]
    [InlineData("hundreds of people", "", "")]
    public void EnglishNumberFingerprints(string text, string digits, string wildcards)
    {
        var fp = Fingerprint(text);
        Assert.Equal(digits, fp.Digits);
        Assert.Equal(wildcards, fp.Wildcards);
    }

    /// 失败原因后面那几面旗子：只有个数与真假，一个字都不来自用户
    [Fact]
    public void FailureFlagsAreDiagnosticButCarryNoContent()
    {
        var reason = TextPostProcessor.PolishDriftCheck("预算的事再看看", "1. 预算50万\n2. 延期");
        Assert.NotNull(reason);
        Assert.Contains("extra=", reason);
        Assert.Contains("listMarkers=", reason);
        Assert.Contains("rawTimeWords=", reason);
        Assert.Contains("rawEnglishNumbers=", reason);
        Assert.DoesNotContain("50", reason);
        Assert.DoesNotContain("预算", reason);
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
