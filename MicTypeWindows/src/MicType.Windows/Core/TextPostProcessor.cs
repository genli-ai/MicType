using System.Text.RegularExpressions;

namespace MicType.Win.Core;

/// 文本后处理。与 Mac 端 Support.swift 的 TextPostProcessor 同源——两端行为必须一致，
/// 且 Windows 引擎（sherpa-onnx + SenseVoice）没有 decoder 热词，这一层的权重比 Mac 更大。
public static partial class TextPostProcessor
{
    private const string LatinOrDigit = "([A-Za-z0-9\\u00C0-\\u024F])";
    /// 西文"词内字符"类：只有西文词条才需要词边界，CJK 不需要
    private const string LatinClass = "[A-Za-z0-9\\u00C0-\\u024F]";
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

    public static string CleanTranscript(string text)
    {
        return CleanTranscript(text, SettingsStore.Instance.Current.FillerWordList);
    }

    /// 纯函数版（可单测）。fillerWords 为空时行为与历史版本完全一致——口水词过滤是纯粹的用户选项。
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
        value = ShortRepeatRegex().Replace(value, "$1");
        value = LongRepeatRegex().Replace(value, "$1");
        value = RemoveFillerWords(value, fillerWords);
        // 数字策略（当前 Keep，恒等）：位置在这里是为了实测后翻常量即生效，不必再改调用点
        value = ApplyArabicIndicDigitsPolicy(value);
        return value.Trim();
    }

    /// 本地口水词过滤：用户列出的词在本机就地删掉，不依赖云端润色（无 Key 的纯听写路径也能用）。
    /// 分寸是刻意保守的（宁可少删，绝不改变原意）：
    ///   • 纯西文词条（um / uh / you know）按整词删、大小写不敏感；词内出现不动（"like" 不动 "likely"）。
    ///   • 其他（中文 嗯 / 那个 / 就是说）只在"两侧都是句读、空白或文本边界"时删——
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
                value = Regex.Replace(value, $"(?<!{LatinClass}){escaped}(?!{LatinClass})", "",
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
    ///   3. 补空格的"后随文字"类里排除阿语——往 RTL 文本里插空格只会插错位置。
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

        // \p{L} 含阿语字母，所以这里要显式把阿语挡在外面（Mac 端用的是只含西文的 \p{Latin}）
        return Regex.Replace(value, $"([.,!?;:])(?!{ArabicClass})([\\p{{L}}\\u4e00-\\u9fff])", "$1 $2");
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

        // 1) 数字多重集：只看数字字符本身，所以 1,000 / 1000 / 1 000 视为一致；全角数字先折半角。
        var rawDigits = DigitMultiset(r);
        var polDigits = DigitMultiset(p);
        if (!DigitsEqual(rawDigits, polDigits))
        {
            return $"digits changed raw={DigitSummary(rawDigits)} polished={DigitSummary(polDigits)}";
        }

        // 2) 否定词计数：允许少量增减（删口头重复、句式改写会动一两个），差太多说明语义被翻转
        var rawNeg = NegationCount(r);
        var polNeg = NegationCount(p);
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

    private static bool DigitsEqual(Dictionary<char, int> a, Dictionary<char, int> b)
    {
        if (a.Count != b.Count) return false;
        foreach (var (key, value) in a)
        {
            if (!b.TryGetValue(key, out var other) || other != value) return false;
        }
        return true;
    }

    private static string DigitSummary(Dictionary<char, int> counts)
    {
        return string.Concat(counts.Keys.OrderBy(k => k).Select(k => new string(k, counts[k])));
    }

    private static int NegationCount(string text)
    {
        var count = text.Count(c => "不没无别未".Contains(c, StringComparison.Ordinal));
        count += NegationWordRegex().Matches(text).Count;
        return count;
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

    [GeneratedRegex("(.{2,24}?)\\1{2,}", RegexOptions.Singleline)]
    private static partial Regex ShortRepeatRegex();

    [GeneratedRegex("(.{12,400}?)\\1+", RegexOptions.Singleline)]
    private static partial Regex LongRepeatRegex();

    [GeneratedRegex("\\b(not|no|never)\\b|n['’]t", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex NegationWordRegex();
}
