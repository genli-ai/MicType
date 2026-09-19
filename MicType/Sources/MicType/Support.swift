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

    // MARK: 清理识别原文

    /// 清理识别引擎的原始输出：去标记、折叠复读幻觉、删用户自定义口水词
    static func cleanTranscript(_ text: String) -> String {
        cleanTranscript(text, fillerWords: Settings.shared.fillerWords)
    }

    /// 纯函数版（可单测）。fillerWords 为空时行为与历史版本完全一致——口水词过滤是纯粹的用户选项。
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
        // 折叠"复读机"式重复：同一短语连续出现 3 次以上时只保留一次
        t = replaceAll(t, "(.{2,24}?)\\1{2,}", "$1", options: [.dotMatchesLineSeparators])
        // 整大段内容被原样复述一遍也只保留一次
        t = replaceAll(t, "(.{12,400}?)\\1+", "$1", options: [.dotMatchesLineSeparators])
        t = removeFillerWords(t, fillerWords: fillerWords)
        // 数字策略（当前 .keep，恒等）：位置在这里是为了实测后翻常量即生效，不必再改调用点
        t = applyArabicIndicDigitsPolicy(t)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 本地口水词过滤：用户列出的词在本机就地删掉，不依赖云端润色（无 Key 的纯听写路径也能用）。
    /// 分寸是刻意保守的（宁可少删，绝不改变原意）：
    ///   • 纯西文词条（um / uh / you know）按整词删、大小写不敏感；词内出现不动（"like" 不动 "likely"）。
    ///   • 其他（中文 嗯 / 那个 / 就是说）只在"两侧都是句读、空白或文本边界"时删——
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
                t = replaceAll(t, "(?<!\(latinClass))" + escaped + "(?!\(latinClass))", "",
                               options: [.caseInsensitive])
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
    static func polishDriftCheck(raw: String, polished: String) -> String? {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return nil }
        if p.isEmpty { return "polished text is empty" }

        // 1) 数字多重集：只看数字字符本身，所以 1,000 / 1000 / 1 000 视为一致；全角数字先折半角。
        //    金额、日期、房号改错一位就是事故，这里不留容差。
        let rawDigits = digitMultiset(r)
        let polDigits = digitMultiset(p)
        if rawDigits != polDigits {
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
    static func openKeyboardSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        NSWorkspace.shared.open(url)
    }
}
