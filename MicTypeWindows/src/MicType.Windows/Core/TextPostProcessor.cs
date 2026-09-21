using System.Globalization;
using System.Text.RegularExpressions;

namespace MicType.Win.Core;

/// 文本后处理。与 Mac 端 Support.swift 的 TextPostProcessor 同源——两端行为必须一致，
/// 且 Windows 引擎（sherpa-onnx + SenseVoice）没有 decoder 热词，这一层的权重比 Mac 更大。
public static partial class TextPostProcessor
{
    private const string LatinOrDigit = "([A-Za-z0-9\\u00C0-\\u024F])";
    /// 西文"词内字符"类：只有西文词条才需要词边界，CJK 不需要
    private const string LatinClass = "[A-Za-z0-9\\u00C0-\\u024F]";
    /// 西文字母（不含数字）的**内容**，用来拼进别的字符类。
    /// 显式码点近似 Swift 的 \p{Latin}：基本拉丁 + Latin-1/扩展 A、B（À–ɏ）+ 扩展附加（Ḁ–ỿ，越南语）。
    private const string LatinLetterClass = "A-Za-z\\u00C0-\\u024F\\u1E00-\\u1EFF";
    /// 阿语"词内字符"类：字母 + tatweel + 音符 + 阿拉伯-印度数字 + 扩展/表现形式区，
    /// **刻意排除** U+0600–061F（含读点 ، 分号 ؛ 问号 ؟）与 U+06D4 阿语句号 ۔ ——那些是词的边界。
    /// 写成显式码点区间而不是 \p{IsArabic}：后者是**区块**，会把上面那些句读一起算进词内字符。
    /// 与 Mac 端 Support.swift 的 arabicClass 逐位一致。
    private const string ArabicClass =
        "[\\u0620-\\u06D3\\u06D5-\\u06FF\\u0750-\\u077F\\u08A0-\\u08FF\\uFB50-\\uFDFF\\uFE70-\\uFEFF]";
    /// 阿语句读：读点 ، (U+060C)、问号 ؟ (U+061F)、分号 ؛ (U+061B)
    private const string ArabicPunct = "،؟؛";
    /// 句读 / 空白：判断一个中文口水词是否"独立成分"的边界字符集
    private const string BoundaryClass = "\\s，。！？、；：…—,.!?;:" + ArabicPunct;
    /// 收尾清理会碰的句读
    private const string PunctClass = "，。！？、；：,.!?;:" + ArabicPunct;

    /// 内置口水词表（中 / 英 / 阿三套）。Mac 端 4.0.2 起把「口水词过滤」那个输入框删了
    /// ——没有人应该为了不打出「嗯」去维护一张表（用户 2026-09-19 实测反馈）。
    ///
    /// 这张表刻意只收**最没有歧义**的那几个，分寸由 RemoveFillerWords 的三条规则保证：
    ///   • 中文只在"前后都是标点或空白"时删 → 「那个人」「这个月」一个字都不动；
    ///   • 单词西文按整词删 → um 不会动 umbrella；
    ///   • 多词西文（you know）还要求**后面紧跟句读** → 「do you know the answer」不动。
    /// 与 Mac 端 Support.swift 的 builtInFillerWords **逐条同源**，改一端必须改另一端。
    public static readonly IReadOnlyList<string> BuiltInFillerWords = new[]
    {
        "嗯", "呃", "啊", "那个", "这个", "就是说", "然后呢",
        "um", "uh", "erm", "you know",
        "يعني", "آآ", "إيه"
    };

    public static string CleanTranscript(string text)
    {
        return CleanTranscript(text, SettingsStore.Instance.Current.FillerWordList);
    }

    /// 纯函数版（可单测）。fillerWords 是**额外**的那几条（用户自己填的 / 导入的设置里带的），
    /// 内置表无论如何都生效——这一步在本机做，不联网、不花润色额度，「仅识别」档也一样。
    public static string CleanTranscript(string text, IReadOnlyList<string> fillerWords)
    {
        // 引擎控制 token 与非语音伪影。顺序有讲究：先删 <|zh|>/<|endoftext|> 这类成对标记，
        // 再删 <TAG>/<br>，否则后者会把前者切碎、留下 "zh|" 这种残渣。
        // <TAG> 只认"紧跟字母、内部无空格"的形式，避免误伤用户真说出口的「a < b > c」。
        var value = EngineTokenRegex().Replace(text, "");
        value = TagTokenRegex().Replace(value, "");
        value = BracketMarkerRegex().Replace(value, "");
        value = ParenthesesMarkerRegex().Replace(value, "");
        value = MusicMarkerRegex().Replace(value, "");
        // Qwen 官方后处理的两级阈值（与 Mac 端 Support.swift 逐字同源）。必须排在下面两条之前：
        // 单字符复读会被 `(.{2,24}?)\1{2,}` 按"两个字符一组"折叠成两个字，
        // 轮到官方那条单字符规则时已经不足 20 次了。
        value = CollapseRepetitions(value);
        value = ShortRepeatRegex().Replace(value, "$1");
        value = LongRepeatRegex().Replace(value, "$1");
        // 内置表排在前面，用户/导入的那几条跟在后面：两张表走的是同一套保守规则
        value = RemoveFillerWords(value, BuiltInFillerWords.Concat(fillerWords).ToList());
        // 数字策略（当前 Keep，恒等）：位置在这里是为了实测后翻常量即生效，不必再改调用点
        value = ApplyArabicIndicDigitsPolicy(value);
        return value.Trim();
    }

    /// Qwen 官方的复读折叠：单字符重复 **>20 次**压成 1 个；任意 **≤20 字符**的模式
    /// 重复 **≥20 次**压成 1 份。阈值照官方口径写死，不自己发明——它们是模型作者对
    /// 自家故障模式的定义，两端（Mac / Windows）必须逐字一致。
    public static string CollapseRepetitions(string text)
    {
        var value = SingleCharRepeatRegex().Replace(text, "$1");
        return PatternRepeatRegex().Replace(value, "$1");
    }

    /// 本地口水词过滤：在本机就地删掉，不依赖云端润色（无 Key 的纯听写路径也能用）。
    /// 分寸是刻意保守的（宁可少删，绝不改变原意）：
    ///   • 单词西文（um / uh / erm）按整词删、大小写不敏感；词内出现不动（"um" 不动 "umbrella"）。
    ///   • **多词西文**（you know / i mean）还要求后面紧跟句读：口水词的「you know」总是
    ///     跟着一个逗号，而「do you know the answer」里的那两个词是句子的一部分——
    ///     只按整词删的话这句话会被删成「do the answer」，那是改写用户说的话。
    ///   • 其他（中文 嗯 / 那个 / 就是说，阿语 يعني）只在"两侧都是句读、空白或文本边界"时删——
    ///     所以「那个人」里的词永远不动，只有独立成分的口水词会被删。
    ///   • 删完做收尾：合并因此出现的重复标点、去掉标点前的空格与句首孤儿标点。
    public static string RemoveFillerWords(string text, IReadOnlyList<string> fillerWords)
    {
        if (string.IsNullOrEmpty(text) || fillerWords.Count == 0) return text;

        var fillers = fillerWords
            .Select(f => f.Trim())
            .Where(f => f.Length > 0)
            .ToList();
        if (fillers.Count == 0) return text;

        var value = text;
        foreach (var filler in fillers)
        {
            var escaped = Regex.Escape(filler);
            if (IsLatinToken(filler))
            {
                // (?<!类) / (?!类) 在文本首尾也成立，等价于西文词边界
                var pattern = $"(?<!{LatinClass}){escaped}(?!{LatinClass})";
                // 多词词条再加一道：后面（允许有空格）必须是句读，否则这两三个词多半是句子本身
                if (filler.Contains(' ')) pattern += $"(?=[ \\t]*[{PunctClass}])";
                value = Regex.Replace(value, pattern, "",
                    RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            }
            else
            {
                // (?<![^边界]) = "前面没有字符，或前面那个字符是边界"
                value = Regex.Replace(value, $"(?<![^{BoundaryClass}]){escaped}(?![^{BoundaryClass}])", "");
            }
        }

        // 收尾：删词留下的空洞
        value = Regex.Replace(value, $"([{PunctClass}])[ \\t]*\\1+", "$1");          // 、、 → 、
        value = Regex.Replace(value, $"[，、,،][ \\t]*(?=[{PunctClass}])", "");       // ，。 → 。（阿语读点同理）
        value = Regex.Replace(value, "[ \\t]{2,}", " ");
        value = Regex.Replace(value, $"[ \\t]+([{PunctClass}])", "$1");
        value = Regex.Replace(value, $"^[ \\t]*[{PunctClass}]+[ \\t]*", "");         // 句首孤儿标点
        return value;
    }

    /// 中英混合标点修正。阿语三条纪律（与 Mac 端同源）：
    ///   1. ، ؟ ؛ **永远不转** ASCII——它们是阿语正字法的一部分，换掉就是改写用户说的话；
    ///   2. 全角句读后面紧跟阿语时也不转：那是一句阿语，句读不归西文一侧管；
    ///   3. 补空格的"后随文字"类只含西文与汉字（白名单），阿语天然在外——往 RTL 文本里插空格只会插错位置。
    public static string FixMixedPunctuation(string text)
    {
        var value = text;
        (string Full, string Half)[] pairs =
        [
            ("。", "."), ("，", ","), ("？", "?"), ("！", "!"), ("：", ":"), ("；", ";")
        ];

        foreach (var (full, half) in pairs)
        {
            // (?!\s*阿语) = 后面是阿语（哪怕隔着空格）就放过——阿英混说的「board، غدا」不动
            value = Regex.Replace(value, LatinOrDigit + Regex.Escape(full) + $"(?!\\s*{ArabicClass})",
                "$1" + half);
        }

        // 后随文字类**只含西文字母与汉字**，和 Mac 端的 [\p{Latin}一-鿿] 同源。
        // 别写成 \p{L}：那是"所有 Unicode 字母"，假名 / 谚文 / 西里尔 / 希伯来全都会命中，
        // Mac 不补空格而 Windows 补（「API，はい」→ Mac "API,はい"、Windows "API, はい"），
        // 而且每冒出一种新文字就得再加一条负向预查。白名单把阿语天然挡在外面，
        // 原来那条 (?!阿语) 随之冗余，删掉。
        return Regex.Replace(value, $"([.,!?;:])([{LatinLetterClass}\\u4e00-\\u9fff])", "$1 $2");
    }

    /// 阿拉伯-印度数字（٠١٢٣…）要不要归一成西文数字（0123…）
    public enum ArabicDigitsPolicy
    {
        /// 保持模型原样输出（当前策略）
        Keep,
        /// 归一为西文数字
        ToWestern
    }

    /// **当前策略：保持原样。**
    /// 模型在阿语上到底吐阿拉伯-印度数字还是西文数字，官方没有任何说明，社区惯例不等于模型行为；
    /// 实测之前任何归一都可能把本来正确的输出改错。要翻策略**只改这一个常量**。
    /// 与 Mac 端 TextPostProcessor.arabicIndicDigitsPolicy 同源，两端必须同时翻。
    public static readonly ArabicDigitsPolicy ArabicIndicDigitsPolicy = ArabicDigitsPolicy.Keep;

    /// 按当前策略处理数字。Keep 时是恒等函数，所以现在把它放进管线不改变任何行为。
    public static string ApplyArabicIndicDigitsPolicy(string text)
    {
        return ArabicIndicDigitsPolicy == ArabicDigitsPolicy.ToWestern
            ? NormalizeArabicIndicDigits(text)
            : text;
    }

    /// ٠–٩ (U+0660–0669) 与扩展阿拉伯-印度数字 ۰–۹ (U+06F0–06F9) → 0–9，别的字符一律不动
    public static string NormalizeArabicIndicDigits(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        var buffer = text.ToCharArray();
        for (var i = 0; i < buffer.Length; i++)
        {
            var c = buffer[i];
            if (c >= '\u0660' && c <= '\u0669') buffer[i] = (char)(c - '\u0660' + '0');
            else if (c >= '\u06F0' && c <= '\u06F9') buffer[i] = (char)(c - '\u06F0' + '0');
        }
        return new string(buffer);
    }

    public static string ApplyVocabReplacements(string text)
    {
        return ApplyVocabReplacements(text, SettingsStore.Instance.Current.VocabularyReplacements);
    }

    /// 词汇表硬替换。三条规则都是为了不"腐蚀"文本：
    ///   1. 最长错写优先——短词条不能先把包含它的长词条吃掉（「文档」不许污染「文档助手」）。
    ///   2. 西文词条大小写不敏感、且要求词边界；正写一侧原样写出（用户填的大小写就是他要的）。
    ///   3. 单趟扫描：替换结果不再参与匹配，避免 A→B、B→C 串成链。
    public static string ApplyVocabReplacements(
        string text,
        IReadOnlyList<(string Wrong, string Right)> replacements)
    {
        if (string.IsNullOrEmpty(text)) return text;

        // 长的在前；等长时保持用户填写顺序，结果才是确定的（字典序不定曾是老实现的隐患）
        var entries = replacements
            .Select((entry, index) => (entry.Wrong, entry.Right, Index: index))
            .Where(e => e.Wrong.Length > 0)
            .OrderByDescending(e => e.Wrong.Length)
            .ThenBy(e => e.Index)
            .ToList();
        if (entries.Count == 0) return text;

        // 一条大正则：分支顺序 = 最长优先顺序，命中哪个捕获组就用哪条词条的正写
        var pattern = string.Join("|", entries.Select(e => "(" + VocabPattern(e.Wrong) + ")"));
        Regex regex;
        try
        {
            regex = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }
        catch (ArgumentException ex)
        {
            Log.Error(ex, "Vocab replacement regex build failed, falling back to plain replace");
            var fallback = text;
            foreach (var entry in entries)
            {
                fallback = fallback.Replace(entry.Wrong, entry.Right, StringComparison.Ordinal);
            }
            return fallback;
        }

        return regex.Replace(text, match =>
        {
            for (var group = 1; group < match.Groups.Count; group++)
            {
                if (match.Groups[group].Success) return entries[group - 1].Right;
            }
            return match.Value;
        });
    }

    /// 西文 / 阿语词条两侧补词边界；中日韩词条不补（中文没有空格，补了就永远匹配不上）。
    /// 两侧各自判断，混排词条前后可以用不同的类。
    private static string VocabPattern(string wrong)
    {
        var pattern = Regex.Escape(wrong);
        if (IsLatinWordChar(wrong[0])) pattern = $"(?<!{LatinClass})" + pattern;
        else if (IsArabicWordChar(wrong[0])) pattern = $"(?<!{ArabicClass})" + pattern;
        if (IsLatinWordChar(wrong[^1])) pattern += $"(?!{LatinClass})";
        else if (IsArabicWordChar(wrong[^1])) pattern += $"(?!{ArabicClass})";
        return pattern;
    }

    /// 润色保真校验：纯机械比对，零 LLM 成本、零网络往返。
    /// 返回 null = 通过；否则返回失败原因（写日志用，不直接给用户看）。
    /// 三条判据都是"模型跑飞"的强信号——数字被改、否定被吞、内容被大段砍掉。
    public static string? PolishDriftCheck(string raw, string polished)
    {
        var r = raw.Trim();
        var p = polished.Trim();
        if (r.Length == 0) return null;
        if (p.Length == 0) return "polished text is empty";

        // 1) 数字指纹：把两边的数字都**归一化成阿拉伯数字**之后比多重集，所以
        //    1,000 / 1000 / 1 000 视为一致，「一百零一」和「101」、「1.2万」和「一万二千」
        //    也视为一致（4.1.6：润色从这一版起要把汉字数字改写成阿拉伯数字，见提示词第 7 条；
        //    不这么比的话每一次正确的改写都会被判成"数字被改"）。与 Mac 端逐条同源。
        var rawFingerprint = NumericFingerprint(r);
        var polFingerprint = NumericFingerprint(p);
        var rawDigits = rawFingerprint.Digits;
        var polDigits = polFingerprint.Digits;
        // 第一层：数字字符的多重集。
        // **只报个数，绝不报数字本身**：这句话会被 DictationController 原样 Log.Warn 写进
        // %LOCALAPPDATA%\MicType\logs\mictype-yyyyMMdd.log（明文、保留 7 天，报故障时会被
        // 整包发出去）。带上数字等于把用户刚说的验证码 / 电话 / 金额漏出去——四位数按多重集
        // 也就 24 种排列，等于没脱敏。Mac 端（Support.swift polishDriftCheck）同源。
        if (!DigitsPreserved(rawFingerprint, polFingerprint))
        {
            return $"digits changed rawCount={rawDigits.Values.Sum()}"
                 + $" polishedCount={polDigits.Values.Sum()}"
                 + $" distinct={rawDigits.Count}/{polDigits.Count}";
        }
        // 第二层：原文里每一个多位数都得原封不动地出现在润色里。零的位置错了 / 数位调了个儿
        // （一万零二百 → 12000、一百零一 → 110）在第一层看不出来——两边多重集一模一样。同样只报个数。
        var missingTokens = MissingNumberTokens(rawFingerprint, polFingerprint);
        if (missingTokens.Count > 0)
        {
            return $"number rewritten tokens={rawFingerprint.Tokens.Count}"
                 + $" missing={missingTokens.Count}";
        }

        // 2) 否定词计数：允许少量增减（删口头重复、句式改写会动一两个），差太多说明语义被翻转。
        //    两边都先清洗过（NegationCount 里摘掉 A 不 A 疑问句、「识别 / 特别 / 未来」这类
        //    非否定词，和独立成句的「不不 / 不对」这类口头自我纠正），否则润色做对了事反而被判跑飞。
        var rawNeg = NegationCount(r);
        var polNeg = NegationCount(p);
        //    2a) 否定被吞光：原文有否定、润色一个不剩。容差 > max(1, raw/3) 恰恰漏掉这一种——
        //    只有一个否定的句子把它丢了（「我不去」→「我去」、"don't send it"→"send it"），
        //    而那正是这道校验最该拦的、代价最高的一种错（raw >= 2 → 0 本来就拦得住）。
        //    **刻意不做对称的那一条（0 → >=1）**：识别偶尔会吞掉一个「不」，润色把它补回来是
        //    帮了忙，拦下来等于把一次正确的修复丢进垃圾桶。与 Mac 端逐条同源。
        if (rawNeg >= 1 && polNeg == 0)
        {
            return $"negation lost raw={rawNeg} polished=0";
        }
        if (Math.Abs(rawNeg - polNeg) > Math.Max(1, rawNeg / 3))
        {
            return $"negation drift raw={rawNeg} polished={polNeg}";
        }

        // 3) 长度比：长输入被砍到三分之一以下 = 模型在"总结"而不是"润色"
        if (r.Length > 40 && p.Length < r.Length * 0.35)
        {
            return $"too short raw={r.Length} polished={p.Length}";
        }

        return null;
    }

    private static Dictionary<char, int> DigitMultiset(string text)
    {
        var counts = new Dictionary<char, int>();
        foreach (var ch in text)
        {
            var c = ch;
            if (c >= '０' && c <= '９') c = (char)(c - '０' + '0');  // 全角数字折半角
            // 阿拉伯-印度数字折西文：润色把 ٢٠٢٦ 写成 2026 是"同一个数"，不是改数字。
            // 不折的话阿语润色会次次被保真校验判成"数字被改"而整段回退，等于阿语用不上润色。
            if (c >= '\u0660' && c <= '\u0669') c = (char)(c - '\u0660' + '0');
            if (c >= '\u06F0' && c <= '\u06F9') c = (char)(c - '\u06F0' + '0');
            if (c < '0' || c > '9') continue;
            counts[c] = counts.TryGetValue(c, out var n) ? n + 1 : 1;
        }
        return counts;
    }

    /// 数字多重集摊成字符串，**只给单测用**：它带着用户说过的数字本身，永远不许进日志
    /// （日志是明文落盘、保留 7 天，用户报故障时会整包带走）。
    public static string DigitSummary(Dictionary<char, int> counts)
    {
        return string.Concat(counts.Keys.OrderBy(k => k).Select(k => new string(k, counts[k])));
    }

    // MARK: 数字指纹（4.1.6，与 Mac 端 NumericFingerprint.swift 逐条同源）
    //
    // 为什么非做不可：润色从 4.1.6 起要把汉字数字改写成阿拉伯数字（提示词第 7 条），
    // 而 4.1.5 的保真校验比的是**数字字符的多重集**——汉字数字里一个阿拉伯数字都没有，
    // 于是每一次正确的改写都会被判成 digits changed、整段回退。提示词和这道校验必须一起改。
    //
    // **已知性质**：比较是"无序 + 字符级"的，同一个数内部重排（101 → 110）、
    // 两个数之间互换数位（214/315 → 314/215）都抓不住；抓得住的是"多一位、少一位、改一位"。

    /// 一段文字里的数字指纹。
    /// Wildcards = 孤零零一个汉字数字、还没有单位的那种（「三点五」的三和五、「第一次」的一）：
    /// 它到底是不是一个数只有上下文知道，所以单独记一桶，只用来**解释对面多出来的那一位**，
    /// 自己消失了不算错。
    /// Tokens = 归一化之后连续 ≥ 2 位的数字串（去重）；Text = 归一化 + 去分隔符之后的整段文字。
    /// 第二层判据就靠这两样：汉字转阿拉伯数字最典型的错是**零的位置错了 / 数位调了个儿**
    /// （一万零二百 = 10200 写成 12000、一百零一 = 101 写成 110），这几对的数字字符多重集
    /// 一模一样，只有"这个数原封不动出现过吗"看得出来。
    public static (Dictionary<char, int> Digits, Dictionary<char, int> Wildcards,
                   List<string> Tokens, string Text) NumericFingerprint(string text)
    {
        var work = FoldedDigits(text);            // a) 全角 / 阿拉伯-印度数字折半角
        work = StrippedOfNumberIdioms(work);      // b) 含数字字却不表数量的固定说法
        work = ExpandedArabicUnits(work);         // c) 1万2 → 12000、1.2万 → 12000
        var wildcards = new Dictionary<char, int>();
        work = ExpandedChineseNumerals(work, wildcards);  // d) 汉字数字 → 阿拉伯数字
        work = StrippedOfGroupSeparators(work);   // f) 1,000 = 1000、138-0013-8000 = 13800138000
        return (DigitMultiset(work), wildcards, NumberTokens(work), work);  // e)
    }

    /// 归一化之后连续 ≥ 2 位的数字串，去重。**只收 ≥ 2 位**：单个数字由多重集 + wildcard
    /// 那一层管（版本号 4.1.6 因此一个 token 都不产生，不会被这一层误伤）。
    public static List<string> NumberTokens(string normalized)
    {
        var tokens = new List<string>();
        var run = "";
        foreach (var character in normalized)
        {
            if (character >= '0' && character <= '9')
            {
                run += character;
                continue;
            }
            if (run.Length >= 2 && !tokens.Contains(run)) tokens.Add(run);
            run = "";
        }
        if (run.Length >= 2 && !tokens.Contains(run)) tokens.Add(run);
        return tokens;
    }

    /// 两段文字里的数字是不是同一批。false = 这次润色动了数值，必须回退原文。两层都得过。
    public static bool NumbersPreserved(string raw, string polished)
    {
        var r = NumericFingerprint(raw);
        var p = NumericFingerprint(polished);
        return DigitsPreserved(r, p) && MissingNumberTokens(r, p).Count == 0;
    }

    /// 第一层：数字字符的多重集 + wildcard 兜底（对称地走两遍）
    private static bool DigitsPreserved(
        (Dictionary<char, int> Digits, Dictionary<char, int> Wildcards, List<string> Tokens, string Text) r,
        (Dictionary<char, int> Digits, Dictionary<char, int> Wildcards, List<string> Tokens, string Text) p)
    {
        var missing = Subtracting(r.Digits, p.Digits);
        var extra = Subtracting(p.Digits, r.Digits);
        return Covered(missing, Subtracting(p.Wildcards, r.Wildcards))
            && Covered(extra, Subtracting(r.Wildcards, p.Wildcards));
    }

    /// 第二层：**原文里每一个多位数，都得原封不动地在润色里出现过**。
    /// 用"包含"而不是"相等"：润色会在数字周围加单位、改标点、接小数
    /// （「十二块五」→「12.5元」里 token 12 是 12.5 的一截），而「1.2万」在比之前已摊成 12000。
    /// 包含只可能过于宽松，绝不会冤枉一次忠实的改写。
    private static List<string> MissingNumberTokens(
        (Dictionary<char, int> Digits, Dictionary<char, int> Wildcards, List<string> Tokens, string Text) r,
        (Dictionary<char, int> Digits, Dictionary<char, int> Wildcards, List<string> Tokens, string Text) p)
    {
        return r.Tokens.Where(token => !p.Text.Contains(token, StringComparison.Ordinal)).ToList();
    }

    /// 夹在**两个数字之间**的千分位 / 连字符 / 各种空格：1,000 = 1000、
    /// 138-0013-8000 = 13800138000。只在两边都是数字时删，句子里正常的逗号空格不受影响。
    private static string StrippedOfGroupSeparators(string text)
    {
        return GroupSeparatorRegex().Replace(text, "");
    }

    /// a ∖ b（多重集差），负数不留
    private static Dictionary<char, int> Subtracting(Dictionary<char, int> a, Dictionary<char, int> b)
    {
        var outCounts = new Dictionary<char, int>();
        foreach (var (key, count) in a)
        {
            var left = count - (b.TryGetValue(key, out var other) ? other : 0);
            if (left > 0) outCounts[key] = left;
        }
        return outCounts;
    }

    /// needed 里每一位都被 pool 里的 wildcard 兜住了吗
    private static bool Covered(Dictionary<char, int> needed, Dictionary<char, int> pool)
    {
        foreach (var (key, count) in needed)
        {
            if ((pool.TryGetValue(key, out var have) ? have : 0) < count) return false;
        }
        return true;
    }

    /// 全角（１２３）与阿拉伯-印度数字折成 ASCII。与 DigitMultiset 的折算表逐位一致
    private static string FoldedDigits(string text)
    {
        var chars = text.ToCharArray();
        for (var i = 0; i < chars.Length; i++)
        {
            var c = chars[i];
            if (c >= '０' && c <= '９') chars[i] = (char)(c - '０' + '0');
            else if (c >= '٠' && c <= '٩') chars[i] = (char)(c - '٠' + '0');
            else if (c >= '۰' && c <= '۹') chars[i] = (char)(c - '۰' + '0');
        }
        return new string(chars);
    }

    /// 含数字字、却**根本不表数量**的固定说法：比数之前整个摘掉，两边一视同仁。
    /// 只收明确安全的条目：摘不干净只是多回退一次润色，摘错一条等于在那个词上把校验挖穿。
    /// 与 Mac 端 numberIdioms 逐条同源；「百分之 / 百分点」是单位词，不摘掉那个「百」会被当成 100。
    private static readonly string[] NumberIdioms = new[]
    {
        "一旦", "统一", "唯一", "一些", "一下", "一起", "一样", "一直", "一定", "一般",
        "一边", "一切", "一共", "一会儿", "一方面", "不一样", "一点点", "有一点", "万一",
        "三心二意", "一心一意", "乱七八糟", "七上八下", "五花八门", "四面八方",
        "十全十美", "一模一样", "独一无二", "接二连三", "千方百计", "百分百",
        "万分", "百般", "百分之", "百分点",
    }.OrderByDescending(w => w.Length).ToArray();

    private static string StrippedOfNumberIdioms(string text)
    {
        var result = text;
        // 长的先摘：短词先动手会把长词咬掉一半（「一点点」被「一点」咬成「点」）
        foreach (var idiom in NumberIdioms)
        {
            result = result.Replace(idiom, " ", StringComparison.Ordinal);
        }
        result = VeryMuchIdiomRegex().Replace(result, " ");
        result = MustIdiomRegex().Replace(result, " ");
        result = ABitIdiomRegex().Replace(result, " ");
        result = WeekdayRegex().Replace(result, " ");
        return result;
    }

    private static readonly Dictionary<string, decimal> UnitValues = new(StringComparer.Ordinal)
    {
        ["亿"] = 100_000_000m, ["千万"] = 10_000_000m, ["百万"] = 1_000_000m,
        ["十万"] = 100_000m, ["万"] = 10_000m, ["千"] = 1_000m, ["百"] = 100m,
    };

    /// 「1.2万」「3500万」：润色最爱写的形式，摊平成整数才比得了。
    /// 用 decimal 而不是 double：1.2 * 10000 在二进制浮点里是 12000.000000000002。
    /// G29 是为了去掉 decimal 乘法留下的尾零（1.2m * 10000m = 12000.0）。
    private static string ExpandedArabicUnits(string text)
    {
        // 省略尾数那一形状要**先摊**：不然 1万2 会被下面的规则吃成 10000 + 一个孤零零的 2
        text = ExpandedArabicAbbreviations(text);
        return ArabicUnitRegex().Replace(text, match =>
        {
            if (!decimal.TryParse(match.Groups[1].Value, NumberStyles.Number,
                                  CultureInfo.InvariantCulture, out var value)) return match.Value;
            if (!UnitValues.TryGetValue(match.Groups[2].Value, out var scale)) return match.Value;
            return " " + (value * scale).ToString("G29", CultureInfo.InvariantCulture) + " ";
        });
    }

    /// 口语式的省略尾数，阿拉伯数字版：1万2 = 12000、3千5 = 3500、2百5 = 250。
    /// 尾数跟的是这个单位的下一档，和汉字那边 PositionalValue 的规则同源。
    private static string ExpandedArabicAbbreviations(string text)
    {
        return ArabicAbbreviatedRegex().Replace(text, match =>
        {
            if (!decimal.TryParse(match.Groups[1].Value, NumberStyles.Number,
                                  CultureInfo.InvariantCulture, out var head)) return match.Value;
            if (!decimal.TryParse(match.Groups[3].Value, NumberStyles.Number,
                                  CultureInfo.InvariantCulture, out var tail)) return match.Value;
            if (!UnitValues.TryGetValue(match.Groups[2].Value, out var scale)) return match.Value;
            var value = head * scale + tail * scale / 10m;
            return " " + value.ToString("G29", CultureInfo.InvariantCulture) + " ";
        });
    }

    /// 「两」= 2、「幺」= 1（报电话号码时的读法）；「零」「〇」都是 0
    private static readonly Dictionary<char, int> ChineseDigitValues = new()
    {
        ['零'] = 0, ['〇'] = 0, ['一'] = 1, ['二'] = 2, ['三'] = 3, ['四'] = 4, ['五'] = 5,
        ['六'] = 6, ['七'] = 7, ['八'] = 8, ['九'] = 9, ['两'] = 2, ['幺'] = 1,
    };

    private static readonly Dictionary<char, long> ChineseUnitValues = new()
    {
        ['十'] = 10L, ['百'] = 100L, ['千'] = 1_000L, ['万'] = 10_000L, ['亿'] = 100_000_000L,
    };

    /// 把每一段连续的汉字数字换成阿拉伯数字（三种情形见 Converted）
    private static string ExpandedChineseNumerals(string text, Dictionary<char, int> wildcards)
    {
        var result = "";
        var run = "";
        foreach (var character in text)
        {
            if (ChineseDigitValues.ContainsKey(character) || ChineseUnitValues.ContainsKey(character))
            {
                run += character;
                continue;
            }
            if (run.Length > 0)
            {
                result += " " + Converted(run, wildcards) + " ";
                run = "";
            }
            result += character;
        }
        if (run.Length > 0) result += " " + Converted(run, wildcards) + " ";
        return result;
    }

    private static string Converted(string run, Dictionary<char, int> wildcards)
    {
        var hasUnit = run.Any(c => ChineseUnitValues.ContainsKey(c));
        if (hasUnit)
        {
            // 光秃秃一个单位字（上万人、成千、过百）是约数不是数——唯一的例外是「十」= 10
            if (run.Length == 1 && run != "十") return "";
            var value = PositionalValue(run);
            if (value.HasValue) return value.Value.ToString(CultureInfo.InvariantCulture);
            return SpreadDigits(run);
        }
        if (run.Length >= 2)
        {
            // 没单位的多字串：当成一串数位念（二零一一 → 2011、幺三八零零 → 13800）
            return SpreadDigits(run);
        }
        if (ChineseDigitValues.TryGetValue(run[0], out var single))
        {
            var key = (char)('0' + single);
            wildcards[key] = (wildcards.TryGetValue(key, out var n) ? n : 0) + 1;
        }
        return "";
    }

    private static string SpreadDigits(string run)
    {
        return new string(run.Select(c => (char)('0' + (ChineseDigitValues.TryGetValue(c, out var v) ? v : 0))).ToArray());
    }

    /// 汉字数字的位值解析。返回 null = 这串算不出来（溢出 / 怪组合），调用方退回逐字摊开。
    /// 三档累加（亿 / 万 / 个）才算得对「一亿二千万」；两个口语细节：
    ///   • 打头的十：十二 = 12；
    ///   • 省略的尾数：两千五 = 2500、一万二 = 12000，但中间念了「零」就是实打实的个位
    ///     （一百零一 = 101，绝不是 110）。
    private static long? PositionalValue(string run)
    {
        try
        {
            checked
            {
                long total = 0;      // 亿 及以上
                long section = 0;    // 万 档
                long current = 0;    // 个 档
                long number = 0;     // 还没落位的那个数字
                long lastUnit = 0;   // 最近用过的单位，给"省略的尾数"用
                var sawZero = false; // 上一个单位之后念过「零」吗

                foreach (var character in run)
                {
                    if (ChineseDigitValues.TryGetValue(character, out var digit))
                    {
                        if (digit == 0) sawZero = true;
                        else number = digit;
                        continue;
                    }
                    if (!ChineseUnitValues.TryGetValue(character, out var unit)) return null;
                    if (unit == 10_000L || unit == 100_000_000L)
                    {
                        // 万只抬"万以下那一段"、亿那一档原样留着，「一亿二千万」才算得对
                        var head = section + current + number;
                        if (unit == 10_000L)
                        {
                            section = head * unit;
                        }
                        else
                        {
                            total = (total + head) * unit;
                            section = 0;
                        }
                        current = 0;
                        number = 0;
                    }
                    else
                    {
                        if (number == 0 && !sawZero && unit == 10L) number = 1;  // 打头的十
                        current += number * unit;
                        number = 0;
                    }
                    lastUnit = unit;
                    sawZero = false;
                }

                if (number != 0)
                {
                    var scale = (!sawZero && lastUnit >= 100L) ? lastUnit / 10L : 1L;
                    current += number * scale;
                }
                return total + section + current;
            }
        }
        catch (OverflowException)
        {
            return null;
        }
    }

    /// 否定词计数。**public 只为可单测**：阈值那条规则在 PolishDriftCheck 里，
    /// 而这里的口径（哪些字算否定、哪些不算）才是 4.1.5 误报的根因，值得单独钉住。
    ///
    /// 先清洗再数：光逐字数「不没无别未」会把「识别」「特别」「未来」这些常用词、
    /// 以及「不不」「不对」这类口头自我纠正全算成否定。前者用户几乎每句话都在说，
    /// 后者正是润色**该删**的东西——两边随便哪一类在润色里被动过，计数就凭空掉几格，
    /// 整段润色被判成"否定被吞"丢回原文（Mac 4.1.5 日志：raw=4 polished=0，一个否定都没丢）。
    /// 与 Mac 端 Support.swift 的 negationCount 逐条同源。
    public static int NegationCount(string text)
    {
        var scrubbed = NegationScrubbed(text);
        var count = scrubbed.Count(c => "不没无别未".Contains(c, StringComparison.Ordinal));
        count += NegationWordRegex().Matches(scrubbed).Count;
        return count;
    }

    /// 含「不没无别未」却**整体不表否定**的常用词：计数前整词摘掉。
    /// 收词的唯一标准是"这个词整体与否定无关"（「不得不」= 必须，是肯定）。
    /// 拿不准的一律不收：漏收一个词最多多回退一次润色，收错一个词等于在那个词上
    /// 把保真校验挖穿。已知代价：「不过来/不过去」会被「不过」整体摘掉——
    /// 为了「不过（然而）」这个高频口头转折词，这一处认了。
    /// 按字数从长到短删，免得短词先吃掉长词的一半。与 Mac 端 nonNegationWords 逐条同源。
    private static readonly string[] NonNegationWords = new[]
    {
        // 「别」：区分 / 类属 / 他者，都不是「别做」的那个别。用户几乎每句话都在说「识别」
        "识别", "特别", "区别", "分别", "个别", "级别", "类别", "性别", "告别", "差别", "辨别",
        "别人", "别的",
        // 「不」：转折、递进、范围、客套——整体都不表否定
        "不过", "不仅", "不但", "不管", "差不多", "对不起", "不好意思", "了不起", "不得不",
        // 「要不然 / 不然 / 要不」= 否则、要么，提的是另一个选择，没否定任何一句话。
        // 已知代价：「只要不下雨就去」里的「要不」也会被摘掉（少数派，且只会漏判、不会误报）
        "要不然", "不然", "要不",
        // 「没」「无」「未」
        "没关系", "无论", "无线", "未来",
    }.OrderByDescending(w => w.Length).ToArray();

    /// 独立成句的口头自我纠正 / 应答词：润色删掉它们**正是它的本职**
    /// （「我说错了……不不，云端的识别就是……」里的「不不」）。
    /// 只在它**整段独占**两个句读之间时才摘，句子内部的否定一个都不动——
    /// 「没有问题」「我不去」照样逐字计数。与 Mac 端 selfCorrectionFillers 逐条同源。
    private static readonly HashSet<string> SelfCorrectionFillers = new(StringComparer.Ordinal)
    {
        "不", "不不", "不不不", "不是", "不是不是", "不对", "不对不对",
        "没有", "没有没有", "不行不行",
        "no", "no no", "no no no",
    };

    /// 切"句"的字符：句读、括号、引号。**故意不含空格和撇号**——
    /// 切空格的话「no way」会裂成两段，其中一段正好是 "no"，整句的否定就被当成口头禅摘掉了；
    /// 切撇号的话「don't」会裂成 don + t，n['’]t 从此再也匹配不上。
    private static readonly char[] FillerBreaks =
        "。．.，,、！!？?；;：:…～~—\n\r()（）【】《》「」“”\"".ToCharArray();

    /// 计数前的清洗（三道，**顺序是有讲究的**）。纯函数，**绝不进日志**——它带着用户说的原话。
    /// 与 Mac 端 negationScrubbed 逐条同源。
    private static string NegationScrubbed(string text)
    {
        // ① 独立成句的口头纠正：按句读切开，整段等于表里的词才丢
        var kept = new List<string>();
        foreach (var piece in text.Split(FillerBreaks))
        {
            var trimmed = piece.Trim().ToLowerInvariant();
            if (trimmed.Length > 0 && SelfCorrectionFillers.Contains(trimmed)) continue;
            kept.Add(piece);
        }
        // 用空格拼回去：两段的首尾字绝不能粘成一个新词（「…说不」+「过…」凑出一个「不过」
        // 被下面整词摘掉，那就等于凭空吞掉一个真否定）
        var result = string.Join(" ", kept);
        // ② A 不 A 疑问句——**必须排在词表前面**：否则「要不要」会先被词表里的「要不」
        //    吃掉半截，剩下的「要」+ 漏下的那个不 会被当成一个真否定记上
        result = ANotAQuestionRegex().Replace(result, " ");
        // ③ 含否定字却不表否定的常用词：整词删掉
        foreach (var word in NonNegationWords)
        {
            result = result.Replace(word, " ", StringComparison.Ordinal);
        }
        return result;
    }

    public static bool IsVocabEcho(string text, IReadOnlyList<string> terms)
    {
        if (string.IsNullOrWhiteSpace(text)) return false;
        // 两种热词前缀都要认（Mac 端 RecognitionLanguages.hotwordPrefix 按会话语言二选一）：
        // 只认中文那条会让非中文会话的复读整段漏过去
        if (text.StartsWith("常用词汇", StringComparison.Ordinal)) return true;
        if (text.StartsWith("Common terms", StringComparison.Ordinal)) return true;
        if (terms.Count < 3) return false;

        var residue = text;
        var hits = 0;
        foreach (var term in terms)
        {
            if (!residue.Contains(term, StringComparison.Ordinal)) continue;
            hits++;
            residue = residue.Replace(term, "", StringComparison.Ordinal);
        }

        if (hits < 3) return false;
        // 阿语句读也算"只是标点"（否则阿语词表的复读会因为剩下几个 ، 而漏判）
        residue = new string(residue.Where(c => !"、，,。.；; ：:،؟؛".Contains(c)).ToArray());
        return residue.Length <= Math.Max(2, text.Length / 10);
    }

    private static bool IsLatinWordChar(char c)
    {
        return c is >= '0' and <= '9' or >= 'A' and <= 'Z' or >= 'a' and <= 'z'
            or >= 'À' and <= 'ɏ';
    }

    /// 阿语"词内字符"：与上面 ArabicClass 的码点区间**逐位一致**（一个改了另一个必须跟着改）。
    /// U+0600–061F 的读点（، ؛ ؟）与 U+06D4 句号 ۔ 都是边界，不算词内字符。
    private static bool IsArabicWordChar(char c)
    {
        return c is >= '\u0620' and <= '\u06D3'      // 字母 / tatweel / 音符 / 阿拉伯-印度数字
            or >= '\u06D5' and <= '\u06FF'           // 更多字母与标记（跳过 U+06D4 阿语句号）
            or >= '\u0750' and <= '\u077F'           // Arabic Supplement
            or >= '\u08A0' and <= '\u08FF'           // Arabic Extended-A
            or >= '\uFB50' and <= '\uFDFF'           // Arabic Presentation Forms-A
            or >= '\uFE70' and <= '\uFEFF';          // Arabic Presentation Forms-B
    }

    /// 纯西文词条（允许词内的空格、连字符、撇号，如 "you know" / "kind-of" / "don't"）
    private static bool IsLatinToken(string value)
    {
        if (value.Length == 0) return false;
        return value.All(c => IsLatinWordChar(c) || c is ' ' or '-' or '\'' or '’');
    }

    [GeneratedRegex("<\\|[^>]*\\|>")]
    private static partial Regex EngineTokenRegex();

    [GeneratedRegex("<[A-Za-z][A-Za-z0-9_/\\-]{0,30}>")]
    private static partial Regex TagTokenRegex();

    [GeneratedRegex("\\[[^\\]]*\\]")]
    private static partial Regex BracketMarkerRegex();

    [GeneratedRegex("\\([^)]*\\)")]
    private static partial Regex ParenthesesMarkerRegex();

    [GeneratedRegex("[♪♫♬]+")]
    private static partial Regex MusicMarkerRegex();

    [GeneratedRegex("(.)\\1{20,}", RegexOptions.Singleline)]
    private static partial Regex SingleCharRepeatRegex();

    [GeneratedRegex("(.{1,20}?)\\1{19,}", RegexOptions.Singleline)]
    private static partial Regex PatternRepeatRegex();

    [GeneratedRegex("(.{2,24}?)\\1{2,}", RegexOptions.Singleline)]
    private static partial Regex ShortRepeatRegex();

    [GeneratedRegex("(.{12,400}?)\\1+", RegexOptions.Singleline)]
    private static partial Regex LongRepeatRegex();

    [GeneratedRegex("\\b(not|no|never)\\b|n['’]t", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex NegationWordRegex();

    /// 数字指纹用的四条"要看上下文才算不算数"（与 Mac 端 contextualNumberIdioms 逐条同源）：
    ///   • 「十分」= 非常，除非后面跟「钟」（十分钟 = 10 分钟）或「之」（十分之一）；
    ///   • 「千万」= 务必，除非**紧挨着前面**就是一个数字（三千万 / 3千万 是数）；
    ///   • 「一点」= 一些 / 一点钟，除非后面跟数字、钟、半、多；
    ///   • 星期 / 周 / 礼拜 + 一二三四五六日天 = 日期名，不是数量。
    [GeneratedRegex("十分(?![钟之])")]
    private static partial Regex VeryMuchIdiomRegex();

    [GeneratedRegex("(?<![零〇一二三四五六七八九两幺0-9])千万")]
    private static partial Regex MustIdiomRegex();

    [GeneratedRegex("一点(?![零〇一二三四五六七八九两幺0-9钟半多])")]
    private static partial Regex ABitIdiomRegex();

    [GeneratedRegex("(星期|周|礼拜)[一二三四五六日天]")]
    private static partial Regex WeekdayRegex();

    /// 阿拉伯数字 + 汉字单位（1.2万 / 3500万 / 2亿）
    [GeneratedRegex("(\\d+(?:\\.\\d+)?)(千万|百万|十万|万|亿|千|百)")]
    private static partial Regex ArabicUnitRegex();

    /// 口语式的省略尾数（1万2 / 3千5 / 2百5）：后面再跟数字或单位就不是这个形状
    [GeneratedRegex("(\\d+)(万|千|百)(\\d)(?![0-9万亿千百十])")]
    private static partial Regex ArabicAbbreviatedRegex();

    /// 夹在两个数字之间的千分位 / 连字符 / 各种空格
    [GeneratedRegex("(?<=[0-9])[,，\\u00A0\\u2009\\u202F \\-](?=[0-9])")]
    private static partial Regex GroupSeparatorRegex();

    /// A 不 A 疑问句：能不能 / 是不是 / 对不对 / 好不好 / 要不要 / 会不会 / 行不行…，
    /// 连「有没有」一起认（所以中间那个字是 不 或 没）。整体是一个**疑问**，不是否定——
    /// 「你能不能帮我」→「你能帮我吗」是最常见的正常润色。与 Mac 端 aNotAQuestion 同源。
    [GeneratedRegex("(.)[不没]\\1")]
    private static partial Regex ANotAQuestionRegex();
}
