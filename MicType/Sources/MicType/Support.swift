import AppKit
import AVFoundation
import ApplicationServices

// MARK: - 错误类型

struct MTError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - 路径

enum Paths {
    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MicType", isDirectory: true)
        // 改名迁移：把旧的 VoiceFlow 数据目录（含约 860MB 识别模型）原地改名，免重新下载
        let legacy = base.appendingPathComponent("VoiceFlow", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var modelsDir: URL {
        let dir = appSupportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - 文本后处理

enum TextPostProcessor {

    /// 西文"词内字符"类（含带变音符的西文字母）：只有西文词条才需要词边界，CJK 不需要
    private static let latinClass = "[A-Za-z0-9\u{00C0}-\u{024F}]"
    /// 阿语"词内字符"类：字母 + tatweel + 音符 + 阿拉伯-印度数字 + 扩展/表现形式区，
    /// **刻意排除** U+0600–061F（含读点 ، 分号 ؛ 问号 ؟）与 U+06D4 阿语句号 ۔ ——那些是词的边界。
    /// 写成显式码点区间而不是 \p{Arabic}：脚本类会把 ، ؟ 之外的句读也算进去，而且 .NET 那边
    /// 只有按**区块**的 \p{IsArabic}（含标点），显式区间是两端行为逐字一致的唯一写法。
    /// 阿语靠前后缀粘连成词（الذكاء 就出现在 بالذكاء 内部），没有这一类词表替换会退化成子串匹配。
    private static let arabicClass =
        "[\\u0620-\\u06D3\\u06D5-\\u06FF\\u0750-\\u077F\\u08A0-\\u08FF\\uFB50-\\uFDFF\\uFE70-\\uFEFF]"
    /// 阿语句读：读点 ، (U+060C)、问号 ؟ (U+061F)、分号 ؛ (U+061B)
    private static let arabicPunct = "،؟؛"
    /// 句读 / 空白：判断一个中文口水词是否"独立成分"的边界字符集
    private static let boundaryClass = "\\s，。！？、；：…—,.!?;:" + arabicPunct
    /// 收尾清理会碰的句读（删词后留下的重复标点、句首孤儿标点）
    private static let punctClass = "，。！？、；：,.!?;:" + arabicPunct

    // MARK: 内置口水词

    /// 内置口水词表（中 / 英 / 阿三套）。4.0.2 起口水词过滤不再是一个要用户自己填的输入框
    /// ——没有人应该为了不打出「嗯」去维护一张表（用户 2026-09-19 实测反馈）。
    ///
    /// 这张表刻意只收**最没有歧义**的那几个，分寸由下面 removeFillerWords 的三条规则保证：
    ///   • 中文只在"前后都是标点或空白"时删 → 「那个人」「这个月」一个字都不动；
    ///   • 单词西文按整词删 → um 不会动 umbrella；
    ///   • 多词西文（you know）还要求**后面紧跟句读** → 「do you know the answer」不动。
    /// 设置键 fillerWords 仍在（导入的老设置照旧生效），只是界面上不再有它。
    /// 与 Windows 端 TextPostProcessor.BuiltInFillerWords 逐条同源。
    static let builtInFillerWords: [String] = [
        "嗯", "呃", "啊", "那个", "这个", "就是说", "然后呢",
        "um", "uh", "erm", "you know",
        "يعني", "آآ", "إيه",
    ]

    // MARK: 清理识别原文

    /// 清理识别引擎的原始输出：去标记、折叠复读幻觉、删口水词（内置表 + 导入的老设置）
    static func cleanTranscript(_ text: String) -> String {
        cleanTranscript(text, fillerWords: Settings.shared.fillerWords)
    }

    /// 纯函数版（可单测）。fillerWords 是**额外**的那几条（导入的老设置里可能有），
    /// 内置表无论如何都生效——这一步在本机做，不联网、不花润色额度，「仅识别」档也一样。
    static func cleanTranscript(_ text: String, fillerWords: [String]) -> String {
        var t = text
        // 引擎控制 token 与非语音伪影。顺序有讲究：先删 <|zh|>/<|endoftext|> 这类成对标记，
        // 再删 <TAG>/<br>，否则后者会把前者切碎、留下 "zh|" 这种残渣。
        // <TAG> 只认"紧跟字母、内部无空格"的形式，避免误伤用户真说出口的「a < b > c」。
        for pattern in ["<\\|[^>]*\\|>",
                        "<[A-Za-z][A-Za-z0-9_/\\-]{0,30}>",
                        "\\[[^\\]]*\\]",            // [BLANK_AUDIO]
                        "\\([^)]*\\)",              // (字幕)
                        "[♪♫♬]+"] {                 // 音乐符号：非语音段的常见幻觉
            t = replaceAll(t, pattern, "")
        }
        // Qwen 官方后处理的两级阈值（brief §3.1）：复读是这个模型公认的故障模式（上游 issue #129
        // 见过同一 token 重复约 2000 次），而库里那道闸门只数"同一 token 连续 10 次"，
        // 命中时还会把尾巴静默丢掉。必须排在下面两条之前：单字符复读会被 `(.{2,24}?)\1{2,}`
        // 按"两个字符一组"折叠成两个字，轮到官方那条单字符规则时已经不足 20 次了。
        t = collapseRepetitions(t)
        // 词级复读的止损（探针实测的那条失败路径：语言漂移 → 开始翻译 → 掉进短语循环，
        // 一直烧到 token 预算耗尽）。字符级那两条规则盖不住它——循环的那个短语往往超过 24 字符。
        t = cutPhraseRepetition(t)
        // 折叠"复读机"式重复：同一短语连续出现 3 次以上时只保留一次
        t = replaceAll(t, "(.{2,24}?)\\1{2,}", "$1", options: [.dotMatchesLineSeparators])
        // 整大段内容被原样复述一遍也只保留一次
        t = replaceAll(t, "(.{12,400}?)\\1+", "$1", options: [.dotMatchesLineSeparators])
        // 内置表排在前面，用户/导入的那几条跟在后面：两张表走的是同一套保守规则
        t = removeFillerWords(t, fillerWords: builtInFillerWords + fillerWords)
        // 数字策略（当前 .keep，恒等）：位置在这里是为了实测后翻常量即生效，不必再改调用点
        t = applyArabicIndicDigitsPolicy(t)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 本地口水词过滤：在本机就地删掉，不依赖云端润色（无 Key 的纯听写路径也能用）。
    /// 分寸是刻意保守的（宁可少删，绝不改变原意）：
    ///   • 单词西文（um / uh / erm）按整词删、大小写不敏感；词内出现不动（"um" 不动 "umbrella"）。
    ///   • **多词西文**（you know / i mean）还要求后面紧跟句读：口水词的「you know」总是
    ///     跟着一个逗号，而「do you know the answer」里的那两个词是句子的一部分——
    ///     只按整词删的话这句话会被删成「do the answer」，那是改写用户说的话。
    ///   • 其他（中文 嗯 / 那个 / 就是说，阿语 يعني）只在"两侧都是句读、空白或文本边界"时删——
    ///     所以「那个人」「不嗯」里的词永远不动，只有独立成分的口水词会被删。
    ///   • 删完做收尾：合并因此出现的重复标点、去掉标点前的空格与句首孤儿标点。
    static func removeFillerWords(_ text: String, fillerWords: [String]) -> String {
        // 去空白用 whitespacesAndNewlines：.whitespaces 不含 \r，带尾随 CR 的口水词
        // 经 escapedPattern 转义后永远匹配不到——用户以为开了过滤，其实一个词都没删
        let fillers = fillerWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !fillers.isEmpty, !text.isEmpty else { return text }

        var t = text
        for filler in fillers {
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            if isLatinToken(filler) {
                // (?<!类) / (?!类) 在文本首尾也成立，等价于西文词边界
                var pattern = "(?<!\(latinClass))" + escaped + "(?!\(latinClass))"
                // 多词词条再加一道：后面（允许有空格）必须是句读，否则这两三个词多半是句子本身
                if filler.contains(" ") {
                    pattern += "(?=[ \\t]*[\(punctClass)])"
                }
                t = replaceAll(t, pattern, "", options: [.caseInsensitive])
            } else {
                // (?<![^边界]) = "前面没有字符，或前面那个字符是边界"，定长、比变长 lookbehind 稳
                t = replaceAll(t, "(?<![^\(boundaryClass)])" + escaped + "(?![^\(boundaryClass)])", "")
            }
        }
        // 收尾：删词留下的空洞
        t = replaceAll(t, "([\(punctClass)])[ \\t]*\\1+", "$1")            // 、、 → 、
        // ，。 → 。（逗号紧跟其他句读必是残留）。阿语读点 ، 同理
        t = replaceAll(t, "[，、,،][ \\t]*(?=[\(punctClass)])", "")
        t = replaceAll(t, "[ \\t]{2,}", " ")
        t = replaceAll(t, "[ \\t]+([\(punctClass)])", "$1")
        t = replaceAll(t, "^[ \\t]*[\(punctClass)]+[ \\t]*", "")           // 句首孤儿标点
        return t
    }

    /// Qwen 官方的复读折叠（brief §3.1 末条）：单字符重复 **>20 次**压成 1 个；
    /// 任意 **≤20 字符**的模式重复 **≥20 次**压成 1 份。两条阈值都照官方口径写死，
    /// 不自己发明——它们是模型作者对自家故障模式的定义，两端（Mac / Windows）必须逐字一致。
    ///
    /// 分段识别下这一步**按段执行、拼接之前**：一段跑飞不该污染整篇的拼接。
    static func collapseRepetitions(_ text: String) -> String {
        var t = replaceAll(text, "(.)\\1{20,}", "$1", options: [.dotMatchesLineSeparators])
        t = replaceAll(t, "(.{1,20}?)\\1{19,}", "$1", options: [.dotMatchesLineSeparators])
        return t
    }

    /// 短语级复读的止损：同一个短语**连着重复 3 次、跨度到 4 个词**就在第一次出现之后截断，
    /// 后面全部丢掉。
    ///
    /// 为什么需要它：mlx-swift-asr 的 maxRepetition 只数"同一个 token 连续 10 次"，
    /// 而这个模型真实的跑飞长相是词级循环（探针录到的原话是 "the day of the day of the day…"
    /// ——注意循环节是 3 个词，不是 4 个），上面那条字符级折叠又只认 ≤24 字符的片段。
    /// 循环一旦开始，后面的内容全是垃圾，留着只会被原样插进用户的输入框——截断才是对的。
    ///
    /// 判据写成"循环节 period ≤ 8 个词、连着重复 repeats 次、且 period × repeats ≥ minWords"：
    ///   • 循环节长度不写死，因为真实的循环节可长可短（"the day of" 是 3）；
    ///   • 跨度门槛（默认 4 个词）挡住"好 好 好"「no no no」这种正常说话里的强调重复，
    ///     那类单词重复由上面的字符级规则负责。
    ///
    /// 只处理靠空格断词的文字（英语、阿语……）：中日韩没有词边界，字符级那两条已经管住了。
    /// 纯函数，可单测。
    static func cutPhraseRepetition(_ text: String, minWords: Int = 4, repeats: Int = 3,
                                    maxPeriod: Int = 8) -> String {
        guard minWords > 0, repeats > 1, maxPeriod > 0 else { return text }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= minWords else { return text }
        let keys = words.map { $0.lowercased() }
        for start in 0..<words.count {
            for period in 1...maxPeriod {
                let span = period * repeats
                guard span >= minWords, start + span <= words.count else { continue }
                var isLoop = true
                for offset in 0..<(period * (repeats - 1))
                where keys[start + offset] != keys[start + offset + period] {
                    isLoop = false
                    break
                }
                guard isLoop else { continue }
                // 留下第一份循环节，从第二份开始整段砍掉（Substring 带着它在原串里的位置，
                // 所以截断点是原文里的真实位置，不用把词重新拼一遍、不动原有的空白与标点）
                let cut = words[start + period - 1].endIndex
                return String(text[text.startIndex..<cut])
            }
        }
        return text
    }

    // MARK: 分段拼接

    /// 分段识别结果的拼接（brief §3.3）。官方 `" ".join(...)` 对中文是错的——
    /// 中文段之间凭空多出空格；对阿语和西文又必须有空格，否则两个词会粘成一个词。
    ///
    /// 规则（缝两侧各看一个字符）：
    ///   • 两侧都是中日韩文字（含全角句读）→ 不加分隔；
    ///   • 任一侧是拉丁或阿语 → 一个空格；
    ///   • 每段先去首尾空白再拼，所以永远不会出现两个连续空格；
    ///   • 只去空白，**不动任何标点**——段末的句号是模型断句的结果，吞掉就是改写用户说的话。
    static func joinSegments(_ parts: [String]) -> String {
        var out = ""
        for part in parts {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            guard let left = out.unicodeScalars.last, let right = piece.unicodeScalars.first else {
                out = piece
                continue
            }
            out += needsSegmentSpace(after: left, before: right) ? " " + piece : piece
        }
        return out
    }

    /// 缝上要不要空格。默认给空格，只有两种情况不给：
    ///   • **两侧都是 CJK**（中日韩字形自带间距，插空格是排版错误）；
    ///   • 右侧以收尾标点开头（", world" / "." / "」"）——那是上一句的尾巴被切到了下一段，
    ///     标点前面不该有空格。
    /// 其余一律一个空格：阿语和西文一样靠空格断词，判不准时多一个空格顶多难看，
    /// 少一个空格会把两个词粘成一个不存在的词。
    static func needsSegmentSpace(after left: Unicode.Scalar, before right: Unicode.Scalar) -> Bool {
        if isTrailingPunctuationScalar(right) { return false }
        return !(isCJKScalar(left) && isCJKScalar(right))
    }

    /// 只会跟在前一个词屁股后面的标点：句读、收尾的括号引号。中英阿三套都算上。
    private static func isTrailingPunctuationScalar(_ scalar: Unicode.Scalar) -> Bool {
        ",.!?;:)]}\"'".unicodeScalars.contains(scalar)
            || "，。！？、；：）」』”’…".unicodeScalars.contains(scalar)
            || "،؟؛".unicodeScalars.contains(scalar)
    }

    /// 中日韩文字与全角句读：这些字形自带间距，中间再插空格就是排版错误。
    /// **韩文也算**（谚文同样不靠空格断词组）——漏了它，韩语段落缝上会多出一个空格。
    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,        // 谚文字母
             0x3000...0x303F,        // CJK 标点（。、！？…—）
             0x3040...0x30FF,        // 平假名 / 片假名
             0x3130...0x318F,        // 兼容谚文字母
             0x3400...0x4DBF,        // 扩展 A
             0x4E00...0x9FFF,        // 统一汉字
             0xA960...0xA97F,        // 谚文字母扩展 A
             0xAC00...0xD7AF,        // 谚文音节
             0xF900...0xFAFF,        // 兼容汉字
             0xFF01...0xFF65:        // 全角形式（，：；！？）
            return true
        default:
            return false
        }
    }

    // MARK: 词汇表硬替换

    /// 词汇表硬替换（"错写=正写"词条）：确定性字符串替换，零耗时、不依赖模型。
    /// 完全同音的专有名词（如 杰文→捷文）概率方法救不了，这是最后一道硬保证。
    static func applyVocabReplacements(_ text: String) -> String {
        applyVocabReplacements(text, replacements: Settings.shared.vocabularyReplacements)
    }

    /// 纯函数版（可单测）。三条规则都是为了不"腐蚀"文本：
    ///   1. 最长错写优先——短词条不能先把包含它的长词条吃掉（「文档」不许污染「文档助手」）。
    ///   2. 西文词条大小写不敏感、且要求词边界；正写一侧原样写出（用户填的大小写就是他要的）。
    ///   3. 单趟扫描：替换结果不再参与匹配，避免 A→B、B→C 串成链。
    static func applyVocabReplacements(_ text: String,
                                       replacements: [(wrong: String, right: String)]) -> String {
        guard !text.isEmpty else { return text }
        let entries = replacements
            .filter { !$0.wrong.isEmpty }
            .enumerated()
            .sorted { a, b in
                // 长的在前；等长时保持用户填写顺序，结果才是确定的（字典序不定曾是老实现的隐患）
                if a.element.wrong.count != b.element.wrong.count {
                    return a.element.wrong.count > b.element.wrong.count
                }
                return a.offset < b.offset
            }
            .map { $0.element }
        guard !entries.isEmpty else { return text }

        // 一条大正则：分支顺序 = 最长优先顺序，命中哪个捕获组就用哪条词条的正写
        let pattern = entries.map { "(" + vocabPattern(for: $0.wrong) + ")" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            Log.warn("Vocab replacement regex build failed, falling back to plain replace")
            var fallback = text
            for (wrong, right) in entries {
                fallback = fallback.replacingOccurrences(of: wrong, with: right)
            }
            return fallback
        }

        let ns = text as NSString
        var out = ""
        var cursor = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match = match else { return }
            var hit = -1
            for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                hit = group - 1
                break
            }
            guard hit >= 0, hit < entries.count else { return }
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            out += entries[hit].right
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// 西文 / 阿语词条两侧补词边界；中日韩词条不补（中文没有空格，补了就永远匹配不上）。
    /// 两侧各自判断：一侧阿语一侧西文的混排词条，前后可以各用各的类。
    private static func vocabPattern(for wrong: String) -> String {
        var pattern = NSRegularExpression.escapedPattern(for: wrong)
        if let first = wrong.unicodeScalars.first {
            if isLatinWordScalar(first) {
                pattern = "(?<!\(latinClass))" + pattern
            } else if isArabicWordScalar(first) {
                pattern = "(?<!\(arabicClass))" + pattern
            }
        }
        if let last = wrong.unicodeScalars.last {
            if isLatinWordScalar(last) {
                pattern += "(?!\(latinClass))"
            } else if isArabicWordScalar(last) {
                pattern += "(?!\(arabicClass))"
            }
        }
        return pattern
    }

    // MARK: 润色保真校验（drift guard）

    /// 润色保真校验：纯机械比对，零 LLM 成本、零网络往返。
    /// 返回 nil = 通过；否则返回失败原因（写日志用，不直接给用户看）。
    /// 三条判据都是"模型跑飞"的强信号——数字被改、否定被吞、内容被大段砍掉，
    /// 正是语音输入里代价最高的三种错。宁可多回退一次原文，也不让改错的稿子进用户的输入框。
    ///
    /// 两条**刻意的容差**，都是阿语实测逼出来的（否则阿语等于用不上润色）：
    ///   • 只动了标点/空白 → 直接放行。模型对阿语基本不吐标点（短句一个都没有），
    ///     补标点正是润色在阿语上最主要的工作，不能被自己的保真校验判成跑飞；
    ///   • 阿语里"数字变成数字符号" → 放行。阿语数字是**词**（خمسة 而不是 5），ITN 只能由润色做，
    ///     所以纯新增数字算正常；但凡有一个数字被删或被改，照样拦（见 digitsOnlyAdded）。
    static func polishDriftCheck(raw: String, polished: String) -> String? {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return nil }
        if p.isEmpty { return "polished text is empty" }

        // 0) 去掉标点与空白之后一模一样 → 这次润色只动了标点，不可能是跑飞
        if strippedOfPunctuation(r) == strippedOfPunctuation(p) { return nil }

        // 1) 数字多重集：只看数字字符本身，所以 1,000 / 1000 / 1 000 视为一致；全角数字先折半角。
        //    金额、日期、房号改错一位就是事故，这里不留容差（阿语 ITN 那条容差见下）。
        let rawDigits = digitMultiset(r)
        let polDigits = digitMultiset(p)
        if rawDigits != polDigits, !(isMostlyArabic(r) && digitsOnlyAdded(raw: rawDigits, polished: polDigits)) {
            // **只报个数，绝不报数字本身**：这句话会被 Log.warn 写进日志，而「复制诊断信息」
            // 把今天日志的尾巴整段放进剪贴板，用户会把它贴进 issue。原样带上数字等于把他刚说的
            // 验证码 / 电话 / 金额漏出去（四位数按多重集也就 24 种排列）。
            return "digits changed rawCount=\(rawDigits.values.reduce(0, +))"
                + " polishedCount=\(polDigits.values.reduce(0, +))"
                + " distinct=\(rawDigits.count)/\(polDigits.count)"
        }
        // 2) 否定词计数：允许少量增减（删口头重复、句式改写会动一两个），差太多说明语义被翻转
        let rawNeg = negationCount(r)
        let polNeg = negationCount(p)
        if abs(rawNeg - polNeg) > max(1, rawNeg / 3) {
            return "negation drift raw=\(rawNeg) polished=\(polNeg)"
        }
        // 3) 长度比：长输入被砍到三分之一以下 = 模型在"总结"而不是"润色"。
        //    短输入不查——一两句话的轻清理本来就可能砍掉一半（全是语气词）。
        if r.count > 40, Double(p.count) < Double(r.count) * 0.35 {
            return "too short raw=\(r.count) polished=\(p.count)"
        }
        return nil
    }

    /// 去掉标点与空白（数字、字母、汉字、阿语字母都留着）。
    /// 只给 drift guard 的"只动了标点"那条容差用——**绝不进日志**，它带着用户说的原话。
    private static func strippedOfPunctuation(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            !(CharacterSet.punctuationCharacters.contains(scalar)
              || CharacterSet.whitespacesAndNewlines.contains(scalar)
              || CharacterSet.symbols.contains(scalar)
              || "،؟؛۔".unicodeScalars.contains(scalar))
        }.map(Character.init))
    }

    /// 这段文字是不是主要由阿语字母组成（阿语字母比西文字母 + 汉字都多）。
    /// 判"要不要放过 ITN"这一件事用，宁可判严：判错的代价是阿语少一次润色，不是插入错数字。
    static func isMostlyArabic(_ text: String) -> Bool {
        var arabic = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0620...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF,
                 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                arabic += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F,
                 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF:
                other += 1
            default:
                break
            }
        }
        return arabic > 0 && arabic > other
    }

    /// 润色只**新增**了数字（一个都没删、没改）。阿语口述里的数字是词，
    /// 「خمسة」→「5」属于正常的 ITN；而「٢٠٢٦」→「2027」会在这里被挡住（6 没了）。
    static func digitsOnlyAdded(raw: [Character: Int], polished: [Character: Int]) -> Bool {
        for (digit, count) in raw where polished[digit, default: 0] < count { return false }
        return true
    }

    private static func digitMultiset(_ text: String) -> [Character: Int] {
        var counts: [Character: Int] = [:]
        for scalar in text.unicodeScalars {
            var value = scalar.value
            if (0xFF10...0xFF19).contains(value) { value -= 0xFF10 - 0x30 }  // 全角数字折半角
            // 阿拉伯-印度数字折西文：润色把 ٢٠٢٦ 写成 2026 是"同一个数"，不是改数字。
            // 不折的话阿语润色会次次被保真校验判成"数字被改"而整段回退，等于阿语用不上润色。
            if (0x0660...0x0669).contains(value) { value -= 0x0660 - 0x30 }
            if (0x06F0...0x06F9).contains(value) { value -= 0x06F0 - 0x30 }
            guard (0x30...0x39).contains(value), let half = Unicode.Scalar(value) else { continue }
            counts[Character(half), default: 0] += 1
        }
        return counts
    }

    /// 数字多重集摊成字符串，**只给单测用**：它带着用户说过的数字本身，永远不许进日志
    /// （日志尾巴会被「复制诊断信息」原样贴出去）。
    static func digitSummary(_ counts: [Character: Int]) -> String {
        counts.keys.sorted()
            .map { String(repeating: String($0), count: counts[$0] ?? 0) }
            .joined()
    }

    private static func negationCount(_ text: String) -> Int {
        var count = text.reduce(0) { $0 + ("不没无别未".contains($1) ? 1 : 0) }
        if let regex = try? NSRegularExpression(pattern: "\\b(not|no|never)\\b|n['’]t",
                                                options: [.caseInsensitive]) {
            count += regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        return count
    }

    // MARK: 空音频复读

    /// 空音频幻觉检测（3.2.2）：模型对无声输入会把热词上下文"复读"成识别结果。
    /// 判定：输出以"常用词汇"开头，或命中 ≥ minHits 个词表词且去掉词表词后几乎不剩内容。
    ///
    /// minHits 默认 3（正常音量那条路上的口径：三个词都撞上才敢说是复读，否则会错杀
    /// "苹果、香蕉、橙子"这种真的在念词表词的句子）。**近静音那一档要放宽到 1**：
    /// 那段音频本来就接近没声音，词表只有一两条的用户（多数）在默认口径下一个都兜不住。
    static func isVocabEcho(_ text: String, terms: [String], minHits: Int = 3) -> Bool {
        guard !text.isEmpty else { return false }
        // 两种热词前缀都要认（RecognitionLanguages.hotwordPrefix）：英语/阿语会话的前缀是英文的，
        // 只认中文那条会让非中文会话的复读整段漏过去
        if text.hasPrefix("常用词汇") || text.hasPrefix("Common terms") { return true }
        guard terms.count >= minHits else { return false }
        var residue = text
        var hits = 0
        for term in terms where residue.contains(term) {
            hits += 1
            residue = residue.replacingOccurrences(of: term, with: "")
        }
        guard hits >= minHits else { return false }
        // 阿语句读也算"只是标点"（否则阿语词表的复读会因为剩下几个 ، 而漏判）
        residue = residue.filter { !"、，,。.；; ：:،؟؛".contains($0) }
        return residue.count <= max(2, text.count / 10)
    }

    // MARK: 标点

    /// 中英混合标点修正：英文内容后面的全角标点改为半角（像豆包那样）
    /// 例：「to test。」→「to test.」  「iPhone，然后」→「iPhone, 然后」
    ///
    /// 阿语三条纪律（brief §3.4：模型实际吐哪种标点无官方说法，只能不动）：
    ///   1. ، ؟ ؛ **永远不转** ASCII——它们是阿语正字法的一部分，换掉就是改写用户说的话；
    ///   2. 全角句读后面紧跟阿语时也不转：那是一句阿语，句读该由阿语一侧决定，不是西文一侧；
    ///   3. 补空格的"后随文字"类只含西文与汉字，**不含阿语**——阿语里句读与词的间距靠模型输出，
    ///      我们自己往 RTL 文本里插空格只会插错位置。
    static func fixMixedPunctuation(_ text: String) -> String {
        var t = text
        let pairs: [(String, String)] = [
            ("。", "."), ("，", ","), ("？", "?"), ("！", "!"), ("：", ":"), ("；", ";"),
        ]
        for (full, half) in pairs {
            // \p{Latin} 覆盖带变音符的西文字母（café、über 等）；
            // (?!\s*阿语) = 后面是阿语（哪怕隔着空格）就放过——阿英混说的「board، غدا」不动
            t = replaceAll(t, "([\\p{Latin}0-9])" + full + "(?!\\s*" + arabicClass + ")", "$1" + half)
        }
        // 半角句读后若紧跟文字（字母或汉字），补一个空格。阿语一侧刻意不参与（见上第 3 条）
        t = replaceAll(t, "([.,!?;:])([\\p{Latin}\\u4e00-\\u9fff])", "$1 $2")
        return t
    }

    // MARK: 阿拉伯-印度数字

    /// 阿拉伯-印度数字（٠١٢٣…）要不要归一成西文数字（0123…）。
    enum ArabicIndicDigitsPolicy: Equatable {
        /// 保持模型原样输出（当前策略）
        case keep
        /// 归一为西文数字
        case toWestern
    }

    /// **当前策略：保持原样。**
    /// 依据（brief §3.4 与「不确定项」第 7 条）：Qwen3-ASR 在阿语上到底吐阿拉伯-印度数字还是西文数字，
    /// 官方没有任何说明，社区惯例（归一为西文）也不等于模型行为。在 mini 上跑完 §3.6 的
    /// 数字/日期语料之前，任何归一都可能把模型本来正确的输出改错——所以先不动。
    /// 实测之后要翻策略，**只改这一个常量**，`normalizeArabicIndicDigits` 已经就位。
    static let arabicIndicDigitsPolicy: ArabicIndicDigitsPolicy = .keep

    /// 按当前策略处理数字。.keep 时是恒等函数（原样返回），所以现在把它放在管线里不改变任何行为。
    static func applyArabicIndicDigitsPolicy(_ text: String) -> String {
        switch arabicIndicDigitsPolicy {
        case .keep: return text
        case .toWestern: return normalizeArabicIndicDigits(text)
        }
    }

    /// ٠–٩ (U+0660–0669) 与扩展阿拉伯-印度数字 ۰–۹ (U+06F0–06F9，波斯/乌尔都) → 0–9。
    /// 只动数字本身，不动任何别的字符。
    static func normalizeArabicIndicDigits(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0660...0x0669:
                out.append(Unicode.Scalar(scalar.value - 0x0660 + 0x30)!)
            case 0x06F0...0x06F9:
                out.append(Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!)
            default:
                out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: 小工具

    private static func replaceAll(_ text: String, _ pattern: String, _ template: String,
                                   options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text,
                                              range: NSRange(text.startIndex..., in: text),
                                              withTemplate: template)
    }

    private static func isLatinWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return true
        default: return false
        }
    }

    /// 阿语"词内字符"：与上面 arabicClass 的码点区间**逐位一致**（一个改了另一个必须跟着改）。
    /// U+0600–061F 的各种标记与读点（، ؛ ؟）、U+06D4 句号 ۔ 都不算词内字符——它们是边界。
    private static func isArabicWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0620...0x06D3,        // 字母 / tatweel / 音符 / 阿拉伯-印度数字
             0x06D5...0x06FF,        // 更多字母与标记（跳过 U+06D4 阿语句号）
             0x0750...0x077F,        // Arabic Supplement
             0x08A0...0x08FF,        // Arabic Extended-A
             0xFB50...0xFDFF,        // Arabic Presentation Forms-A
             0xFE70...0xFEFF:        // Arabic Presentation Forms-B
            return true
        default: return false
        }
    }

    /// 纯西文词条（允许词内的空格、连字符、撇号，如 "you know" / "kind-of" / "don't"）
    private static func isLatinToken(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy {
            isLatinWordScalar($0) || $0 == " " || $0 == "-" || $0 == "'" || $0 == "’"
        }
    }
}

// MARK: - 静音闸门

/// 松手之后「这段音频要不要送去识别」的判据（路线图 bug 9）。
///
/// 老实现是一条线：峰值 < 0.012 就整段丢掉，报「没有听到内容」。问题在于它同时承担了两件事——
/// 「真的没开口」和「声音太小」——而后者是**用户完全可以救回来的情况**（挪近一点、换只麦克风），
/// 却被当成误触悄悄丢了，用户只知道"又没识别到"，不知道该做什么。
///
/// 所以拆成三档：
///   • .silent（峰值 < 0.006）＝ 基本等于数字静音，误触或压根没开口 → 不送识别。
///     这道闸门还有第二个作用：空音频最容易诱发模型把热词上下文"复读"成识别结果（3.2.2），
///     所以它必须留着，只是线压低到"真静音"那一档。
///   • .faint（0.006 ≤ 峰值 < 0.02 且 RMS 极小）＝ 远处说话 / 麦克风没选对 → **照样送识别**
///     （这一档常常是能识别出来的，凭什么不给用户试），只有识别真的出来空的时候才提示"声音太小"。
///   • .normal ＝ 正常走。
/// 光看峰值不够：一声咳嗽也能顶出 0.05 的峰值而整段没人声，RMS 才反映"整段有多少能量"，
/// 两个一起看才分得清"小声说了一整段"和"安静里蹦了一下"。
///
/// 纯函数、可单测，不碰任何设置与 UI。阈值是常量而不是设置项：这是识别链路的内部判据，
/// 不是用户该调的旋钮（要调的是"麦克风选哪只"）。
enum SilenceGate {

    enum Decision: String, Equatable {
        /// 太短，当误触丢弃（静默）
        case tooShort
        /// 几乎数字静音，不送识别
        case silent
        /// 声音很小但不是静音：照样送识别，识别为空时给"声音太小"的针对性提示
        case faint
        case normal
    }

    /// 低于这个时长一律当误触（手滑碰到热键），静默丢弃
    static let minDurationSeconds: Double = 0.4
    /// "真静音"线：低于它就不送识别
    static let silentPeak: Float = 0.006
    /// "声音太小"线：峰值在 [silentPeak, faintPeak) 且 RMS 也极小 → .faint
    static let faintPeak: Float = 0.02
    static let faintRMS: Float = 0.004

    static func decide(peak: Float, rms: Float, duration: Double) -> Decision {
        if duration < minDurationSeconds { return .tooShort }
        // 写成 !(peak >= x) 而不是 peak < x：NaN（转换器出岔子时可能出现）两种比较都为假，
        // 前者会把它判成 .silent（安全侧），后者会把一段坏数据送进识别
        if !(peak >= silentPeak) { return .silent }
        if peak < faintPeak, rms < faintRMS { return .faint }
        return .normal
    }

    /// 峰值 + RMS 一趟算完（5 分钟录音 ≈ 480 万个采样，扫两遍没必要）。
    /// 空数组返回 (0, 0) → decide 判 .silent，和"什么都没录到"一致。
    ///
    /// excluding：要排除的采样区间——App 自己的开始音会被同一只麦克风录进来（外放时尤其响），
    /// 这一声是 MicType 自产自销的，算进峰值就等于拿自己的提示音去判"用户开没开口"。
    /// 区间由录音侧按闸门时刻换算（「按下即录」那条路上开始音落在整段的中间，不是开头，
    /// 所以这里收的是区间而不是"跳过前 n 个采样"）。
    static func stats(_ samples: [Float], excluding: Range<Int>? = nil) -> (peak: Float, rms: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        let whole = 0..<samples.count
        let skip = excluding.map { $0.clamped(to: whole) } ?? whole.upperBound..<whole.upperBound
        // 排除段前后各扫一遍（每段内部都是连续内存，不必为跳过的那几千个采样在循环里加判断）
        let head = scan(samples[whole.lowerBound..<skip.lowerBound])
        let tail = scan(samples[skip.upperBound..<whole.upperBound])
        let count = head.count + tail.count
        // 闸门把整段都盖住了（录音短到只剩提示音）：和"什么都没录到"一样判静音
        guard count > 0 else { return (0, 0) }
        return (max(head.peak, tail.peak),
                Float(((head.sumSquares + tail.sumSquares) / Double(count)).squareRoot()))
    }

    /// 一段采样的峰值、平方和、个数。平方和用 Double 累加：几百万个平方项用 Float 累加会把小值吃掉
    private static func scan(_ samples: ArraySlice<Float>) -> (peak: Float, sumSquares: Double, count: Int) {
        var peak: Float = 0
        var sum: Double = 0
        for v in samples {
            let a = abs(v)
            if a > peak { peak = a }
            sum += Double(v) * Double(v)
        }
        return (peak, sum, samples.count)
    }
}

// MARK: - 提示音

/// 四个提示音。自带短音（Resources/Sounds/*.wav，由 scripts/generate_sounds.py 生成），
/// 而不是系统的 Pop/Glass/Basso/Bottle：系统警告音是"出事了"的语义，语音输入一天要响几十次，
/// 而且用户可以在系统设置里把它们换掉，我们就彻底失去了对提示音的控制。
/// 资源缺失（比如直接跑 .build 里的裸可执行文件，没打成 .app）时退回老的系统音，不至于静音。
enum Sounds {

    private enum Cue: String {
        case start, success, error, cancel

        /// 资源缺失时的兜底：3.2.19 之前一直用的那四个系统音
        var systemFallback: String {
            switch self {
            case .start:   return "Pop"
            case .success: return "Glass"
            case .error:   return "Basso"
            case .cancel:  return "Bottle"
            }
        }
    }

    /// NSSound 每次构造都要读文件解码，而提示音是高频路径 → 首次用到时加载一次并留着。
    /// 只在主线程访问（所有 play* 调用点都在主线程）。
    private static var cache: [Cue: NSSound] = [:]

    private static func sound(_ cue: Cue) -> NSSound? {
        if let cached = cache[cue] { return cached }
        var loaded: NSSound? = nil
        if let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav",
                                     subdirectory: "Sounds") {
            loaded = NSSound(contentsOf: url, byReference: false)
            if loaded == nil { Log.warn("Sound decode failed: \(cue.rawValue).wav") }
        }
        if loaded == nil {
            Log.warn("Bundled sound missing: \(cue.rawValue).wav — falling back to system sound")
            loaded = NSSound(named: cue.systemFallback)
        }
        if let loaded = loaded { cache[cue] = loaded }
        return loaded
    }

    private static func play(_ cue: Cue) {
        guard Settings.shared.playSounds else { return }
        guard let s = sound(cue) else { return }
        // 复用同一个 NSSound：上一声还没放完就再触发时必须先 stop，否则 play() 被忽略
        if s.isPlaying { s.stop() }
        s.play()
    }

    static func playStart()   { play(.start) }
    static func playSuccess() { play(.success) }
    static func playError()   { play(.error) }
    static func playCancel()  { play(.cancel) }
}

// MARK: - 权限

enum Permissions {

    static var isAccessibilityTrusted: Bool {
        return AXIsProcessTrusted()
    }

    /// 弹出系统的辅助功能授权提示
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var microphoneStatus: AVAuthorizationStatus {
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var microphoneGranted: Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// 确保麦克风权限，completion 在主线程回调
    static func ensureMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    /// 键盘设置页：用 Fn / 🌐 当热键的人要去这里把「按下🌐键」改成「不执行任何操作」，
    /// 否则每次触发都会被系统抢去弹输入法切换或表情面板。
    /// 4.0.1 起 Fn 不在可选热键里了（设置页只摆右侧三颗），这个入口暂时没有调用方——
    /// 留着是因为 Fn 仍然是能存进设置的合法值（老设置 / 导入的设置文件）。
    static func openKeyboardSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
