import Foundation
import NaturalLanguage

/// 润色保真校验的三道新闸门（5.0.6）：文字系统翻转、否定范围、人名同音。
/// 由 `TextPostProcessor.polishDriftCheck` 按顺序调用；这里只放判断本身，全是纯函数。
///
/// 来历：iOS 2026-09-28 真机 + live 评测（润色换 gpt-5.6-terra 后），移植自 iOS
/// `PolishGuard.swift` / `CloudTextScriptGuard.hanShare`：
///   • C1「我感觉不需要把其实就是要换一下那个滤芯的问题」→「我感觉不需要更换滤芯」——
///     说话人放弃了「不需要」、改口肯定「换滤芯」，润色却把否定套到了肯定的内容上。
///     否定数 1→1，按数量比的规则看不见；在提示词里加条款实测 3/3 照样复现，只能靠代码闸门。
///   • C2「早上好呀，我去跟汉总说一下」→「早上好，我去跟韩总说一下」——第 5 条同音纠错用在了人名上。
///   • 2026-09-22 live 评测：gpt-5.6 把一段含「用英语来回答」的中文口述真的译成了英文（2/3 轮）。
///
/// **纪律（与 polishDriftCheck 同一条）**：这里的每个 helper 手上都是用户的原话，
/// 一律不进日志；对外只交计数 / 百分比。
enum PolishFidelity {

    // MARK: - 文字系统翻转（scriptFlipped）

    /// 各文字系统的字母数。数字、标点、emoji、空白一律不计。
    ///
    /// 与 iOS `CloudTextScriptGuard.classify` 同一套码点区间，**多了一类阿拉伯字母**：
    /// iOS 把阿语算进 `.other`、两边都不计——对 iOS 无所谓（它不支持阿语），
    /// 对 Mac 不行：阿拉伯语是必须支持的输入语言（用户在 UAE），阿语口述被整段译成英文
    /// 恰恰是这道闸门要拦的事。
    struct ScriptCounts: Equatable {
        var han = 0, kana = 0, hangul = 0, latin = 0, cyrillic = 0, arabic = 0
        var total: Int { han + kana + hangul + latin + cyrillic + arabic }
    }

    static func scriptCounts(_ text: String) -> ScriptCounts {
        var c = ScriptCounts()
        for u in text.unicodeScalars {
            switch u.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x3005...0x3007:
                c.han += 1                                             // 含繁体 / 々〆〇
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                c.kana += 1
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xD7B0...0xD7FF:
                c.hangul += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
                c.latin += 1
            case 0x00C0...0x024F where u.value != 0x00D7 && u.value != 0x00F7:
                c.latin += 1                                           // é ñ ß œ…（剔掉 × ÷）
            case 0x0400...0x04FF:
                c.cyrillic += 1
            case 0x0620...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
                // 与 TextPostProcessor.isMostlyArabic 同一组区块；再过一道 isAlphabetic，
                // 把阿拉伯-印度数字（٠-٩ / ۰-۹）与阿语句号 ۔ 这类非字母剔掉——数字、标点不计
                if u.properties.isAlphabetic { c.arabic += 1 }
            default:
                continue
            }
        }
        return c
    }

    /// 汉字、阿语字母各占字母总数的百分比（0–100）。字母不足 4 个 → nil（太短，不判）。
    static func scriptShares(_ text: String) -> (han: Int, arabic: Int)? {
        let c = scriptCounts(text)
        guard c.total >= 4 else { return nil }
        return (c.han * 100 / c.total, c.arabic * 100 / c.total)
    }

    /// 润色换了文字系统 = 翻译了（提示词铁律 1 禁止翻译）。返回日志原因串（只含百分比），nil = 没翻。
    ///
    /// 规则与 iOS 相同、按文字分别判：原文某文字（汉字或阿语）占 ≥ 60% 而润色 ≤ 10%，
    /// 或原文 ≤ 10% 而润色 ≥ 60% → 拦。**混排（10–60%）永不判**：中英混说正是铁律 1 要保护的，
    /// 不是翻译。
    static func scriptFlipReason(raw: String, polished: String) -> String? {
        guard let r = scriptShares(raw), let p = scriptShares(polished) else { return nil }
        func flipped(_ a: Int, _ b: Int) -> Bool { (a >= 60 && b <= 10) || (a <= 10 && b >= 60) }
        guard flipped(r.han, p.han) || flipped(r.arabic, p.arabic) else { return nil }
        return "script flipped rawHan=\(r.han)% polHan=\(p.han)% rawAr=\(r.arabic)% polAr=\(p.arabic)%"
    }

    // MARK: - 列表

    /// 润色是不是排成了列表。提示词第 8 条会产出两种：`•` 开头的行，和编号行（1. 2、3)）。
    /// 编号行复用数字指纹那边的判定（`strippedOfListMarkers`：序号连成 1…n 且 n ≥ 2 才算），
    /// 两处对「什么是列表」必须是同一个答案——孤零零一个「1.」是数据，不是列表。
    static func looksLikeList(_ text: String) -> Bool {
        if text.hasPrefix("•") || text.contains("\n•") { return true }
        return TextPostProcessor.strippedOfListMarkers(text).markers >= 2
    }
}

// MARK: - 否定范围（negationScope，C1）

/// 为什么数量之外还要看范围：C1 那一稿保住了唯一的「不需要」，意思却反了——原文的否定撞上
/// 一个半截的分句（「不需要把——其实就是要换…」），润色把它挂到了说话人刚**肯定**的东西上。两条规则：
///   1. overAffirmed（C1）——原文的否定还没接上宾语就被转折（其实 / 而是 / 只是 / 但是…）截断，
///      等于什么都没否定；转折之后、到分句结束或下一个真否定为止的内容是被**肯定**的。
///      润色里某个否定的宾语有 ≥2 个单元落在这段肯定内容里、又不在原文任何否定的宾语里
///      = 否定被挪到了新对象上。
///   2. unmatched——原文每个否定的宾语（其后 ≤3 个内容单元；需要 / 有 / 是 这类中心词和
///      的 / 了 / 把 / 就 / 那个 / 一下 这类虚词跳过）要么仍在润色的某个否定之下，要么在润色里
///      整个没了（改写 / 连否定一起删掉）。宾语还在、所在分句却一个否定都没有了 = 否定从它身上
///      掉了（2→1 在数量容差之内，数不出来）。润色里**没有宾语**的否定（句末「不用，」「没有，」）
///      覆盖与它开头相同的那个原文否定：没标点的原文「不用了谢谢你啊」会把后一句当成「宾语」，
///      而润色只是把逗号加回去。
/// 原文一侧读得**严**（特别 / 不过 / 无论 这类固定词、是不是 / 有没有、结巴、以及说话人在
/// 「不对 / 我是说 / 应该是」之前收回的否定，都不保护）；润色一侧在规则 2 里读得**宽**
/// （任何 不 / 没 / 别 / 无 / 未 / not 都算覆盖）——这里每一次误报都要花一趟轻清理重试、丢掉一次
/// 好润色，所以拿不准就放行。
/// 单元而非词：不分词，一个汉字一个单元，一个西文词、一串数字各一个单元，任何数字（三 / 3 / 两）
/// 算同一个单元，所以「不到两秒」→「不到2秒」照样对得上（数值对不对是数字指纹的事）。
extension PolishFidelity {

    enum ScopeUnit: Hashable {
        case han(Character)
        case word(String)     // 小写西文词，保留撇号（don't）
        case number           // 一串阿拉伯数字，或任何一个汉字数字
        case clauseBreak      // 任何标点 / 换行（阿语、假名等不参与判断的字母也落在这里）
    }

    struct NegationScope {
        /// 否定词本身 + 紧跟着被跳过的中心词（不+用、没+有、不+需要）：句末的「不用，」
        /// 靠它认出原文里连着写的「不用我自己来」（规则 2 的开头匹配）。
        var lead: [ScopeUnit] = []
        var object: [ScopeUnit] = []
        /// 只有「还没接上宾语就被转折截断」时才非空。
        var affirmed: [ScopeUnit] = []
    }

    private static let hanNegations: Set<Character> = ["不", "没", "無", "无", "别", "未"]
    private static let chineseNumerals: Set<Character> = Set("零〇一二三四五六七八九十百千万亿两")
    /// 否定词**自带**的那半截，跳过之后才是宾语：不需要 / 没有 / 不是 / 不能 / 不太想。
    /// 长的在前（贪心、可连续匹配）。
    private static let negationHeads: [[Character]] = ["需要", "必要", "应该", "可以", "可能", "一定",
        "怎么", "那么", "这么", "要", "用", "必", "有", "是", "会", "能", "想", "该", "太", "再", "大",
        "够", "都", "也", "还", "很", "算"].map { Array($0) }
    /// 虚词与口头填充（的 / 了 / 把 / 就 / 是、语气词、那个 / 这个 / 一下）：永远不是宾语。
    private static let scopeParticles: [[Character]] = ["那个", "这个", "一下", "的", "了", "把", "就",
        "是", "啊", "呀", "吧", "呢", "吗", "嘛", "哦", "啦", "着", "地"].map { Array($0) }
    /// 否定一头撞上这些词就丢了宾语（C1：不需要把｜其实就是要…）。
    /// **刻意不收**单独的「就是」：「这不就是一个电风扇吗」是反问，否定管着后面的宾语。
    private static let scopePivots: [[Character]] = ["我是说", "其实", "而是", "只是", "但是", "可是", "反正"]
        .map { Array($0) }
    /// 自我修正标记：出现在它们**之前**的原文否定是说话人收回的，提示词第 9 条（执行说话人的
    /// 自我修正）允许连同宾语一起删掉。
    private static let correctionMarkers: [[Character]] = ["我的意思是", "我是说", "说错了", "应该是", "不对"]
        .map { Array($0) }
    /// 含否定字、整体却不否定任何东西的固定词（只在原文一侧、严读时用）。
    private static let negationIdioms: [[Character]] = ["特别", "区别", "分别", "告别", "别人", "别的",
        "级别", "类别", "性别", "识别", "辨别", "差别", "个别", "离别", "别墅", "别致", "不过", "不管",
        "不仅", "不但", "不断", "不少", "不错", "不然", "要不", "对不起", "了不起", "差不多", "不好意思",
        "不得了", "不得不", "不久", "没准", "无论", "无聊", "无所谓", "无数", "无非", "无奈", "未来", "未免"]
        .map { Array($0) }
    private static let englishHeads: Set<String> = ["be", "to", "a", "an", "the", "really", "even", "very",
        "so", "too", "that", "have", "been", "going", "gonna", "need", "any", "at", "all", "quite", "just",
        "ever", "it"]

    /// 两个计数：unmatched = 原文否定的宾语还在润色里、却不再被任何否定管着；
    /// overAffirmed = 润色里宾语落在原文**被肯定**那段内容上的否定（C1 的形状）。
    static func negationScopeVerdict(raw: String, polished: String) -> (unmatched: Int, overAffirmed: Int) {
        let rawUnits = scopeUnits(raw), polUnits = scopeUnits(polished)
        let rawScopes = negationScopes(rawUnits, strict: true, objectLimit: 3)
        // 0→n 永不判：润色补回一个被识别吞掉的「不」是修复（与 negation lost 那条同一个道理）。
        guard !rawScopes.isEmpty else { return (0, 0) }

        // 规则 1 —— overAffirmed（C1）
        var overAffirmed = 0
        let affirmed = Set(rawScopes.flatMap(\.affirmed))
        if !affirmed.isEmpty {
            let negatedInRaw = Set(rawScopes.flatMap(\.object))
            // ≥2 个单元（C1 是 换 / 滤 / 芯），免得「个」「我」这种常用字一个字两边都有就触发。
            let needed = min(2, affirmed.count)
            for scope in negationScopes(polUnits, strict: true, objectLimit: 10)
            where scope.object.filter({ affirmed.contains($0) && !negatedInRaw.contains($0) }).count >= needed {
                overAffirmed += 1
            }
        }

        // 规则 2 —— unmatched
        let polLoose = negationScopes(polUnits, strict: false, objectLimit: 10)
        let rawContent = contentUnits(rawUnits)
        // 润色里**一个否定都没有**的分句：「宾语还在、否定没了」只可能发生在这里。
        // 仍带着否定的分句（「我不觉得…严重」→「我觉得…没那么严重」，否定在分句内挪了位置）放行。
        let negationFreeClauses = polUnits.split(separator: .clauseBreak)
            .filter { !$0.contains(where: isNegation) }.map { contentUnits(Array($0)) }
        var unmatched = 0
        for scope in rawScopes where !scope.object.isEmpty {
            if polLoose.contains(where: { covers($0, scope) }) { continue }
            if objectSurvives(scope.object, rawContent: rawContent, in: negationFreeClauses) { unmatched += 1 }
        }
        return (unmatched, overAffirmed)
    }

    /// 润色的这个否定还管着原文那个吗。两边宾语都有 ≥2 个单元时要共享 2 个（「不去北京」对
    /// 「不去上海」只共享「去」——那正是调包，不是对上）；任何一边更短时共享 1 个即可（没标点的
    /// 原文会连着写下去：「不想来是真的」对「不想来，」）。没有宾语的润色否定，覆盖与它开头互为
    /// 前缀的原文否定（「不用，」↔「不用了我…」、「不，」↔「不我自己来」）——但不同的中心词不算
    /// （「不用，」不覆盖「不需要帮忙」）。
    private static func covers(_ polishedScope: NegationScope, _ rawScope: NegationScope) -> Bool {
        if polishedScope.object.isEmpty {
            return isPrefix(polishedScope.lead, of: rawScope.lead) || isPrefix(rawScope.lead, of: polishedScope.lead)
        }
        return sharedUnits(rawScope.object, polishedScope.object)
            >= min(2, rawScope.object.count, polishedScope.object.count)
    }

    static func scopeUnits(_ text: String) -> [ScopeUnit] {
        var units: [ScopeUnit] = []
        var word = "", inNumber = false
        func flush() {
            if !word.isEmpty { units.append(.word(word.lowercased())); word = "" }
            if inNumber { units.append(.number); inNumber = false }
        }
        for ch in text {
            if ch.isASCII, ch.isLetter || (!word.isEmpty && (ch == "'")) {
                if inNumber { flush() }
                word.append(ch)
            } else if ch == "’", !word.isEmpty {
                word.append("'")
            } else if ch.isNumber, ch.unicodeScalars.allSatisfy({ $0.properties.numericType == .decimal }) {
                if !word.isEmpty { flush() }
                inNumber = true
            } else if inNumber, ".,:：．%".contains(ch) {
                continue   // 3.5 / 1,000 / 9:30 / 20% 仍是一个数
            } else if isHan(ch) {
                flush()
                units.append(chineseNumerals.contains(ch) ? .number : .han(ch))
            } else if ch.isWhitespace, !ch.isNewline {
                flush()
            } else {
                flush()
                if units.last != .clauseBreak { units.append(.clauseBreak) }
            }
        }
        flush()
        return units
    }

    static func negationScopes(_ units: [ScopeUnit], strict: Bool, objectLimit: Int) -> [NegationScope] {
        let lastCorrection = strict ? lastCorrectionMarker(units) : nil
        var scopes: [NegationScope] = []
        for i in units.indices where isNegation(units[i]) {
            if strict {
                if i > 0, units[i - 1] == units[i] { continue }                                   // 不不不 结巴
                if i > 0, i + 1 < units.count, case .han = units[i], units[i - 1] == units[i + 1] { continue } // 是不是
                if isIdiomNegation(units, at: i) { continue }
                if let marker = lastCorrection, i < marker { continue }                            // 已收回
            }
            var scope = NegationScope(lead: [units[i]])
            var j = i + 1
            while j < units.count, units[j] == units[i] { j += 1 }
            while j < units.count, scope.object.count < objectLimit {
                let unit = units[j]
                if unit == .clauseBreak { break }
                if isNegation(unit) {                    // 不能不去：跳过里面那个；不去也不想：到此为止
                    if scope.object.isEmpty { j += 1; continue } else { break }
                }
                if let pivot = prefixMatch(scopePivots, units, at: j) {   // 转折永远结束这一分句
                    if scope.object.isEmpty {
                        // 肯定内容只算到分句结束或下一个真否定：那之后的东西在原文里是被否定的，
                        // 不是被肯定的（「不是其实我也不想去北京出差」——iOS 初稿一路算到「出差」，
                        // 结果把忠实的「其实我也不想去北京出差」拦了）。
                        var end = j + pivot
                        while end < units.count, units[end] != .clauseBreak,
                              !(isNegation(units[end]) && !isIdiomNegation(units, at: end)) { end += 1 }
                        scope.affirmed = contentUnits(Array(units[(j + pivot)..<end]))
                    }
                    break
                }
                if scope.object.isEmpty, let head = prefixMatch(negationHeads, units, at: j) {
                    scope.lead += units[j..<(j + head)]
                    j += head
                    continue
                }
                if let particle = prefixMatch(scopeParticles, units, at: j) { j += particle; continue }
                if scope.object.isEmpty, case .word(let w) = unit, englishHeads.contains(w) {
                    scope.lead.append(unit)
                    j += 1
                    continue
                }
                scope.object.append(unit)
                j += 1
            }
            scopes.append(scope)
        }
        return scopes
    }

    /// 只留内容：去掉分句符和虚词——「宾语还在不在」拿它来比。
    static func contentUnits(_ units: [ScopeUnit]) -> [ScopeUnit] {
        var out: [ScopeUnit] = []
        var j = 0
        while j < units.count {
            if units[j] == .clauseBreak { j += 1; continue }
            if let particle = prefixMatch(scopeParticles, units, at: j) { j += particle; continue }
            out.append(units[j])
            j += 1
        }
        return out
    }

    /// 原文的宾语是不是还在润色里、而且所在分句没有任何否定？≥2 个单元：它的前两个单元
    /// 在那里紧挨着出现。1 个单元：它在那里，而且润色里它出现的次数不少于原文
    /// （这样被删掉的就不可能是被否定的那一次）。
    private static func objectSurvives(_ object: [ScopeUnit], rawContent: [ScopeUnit],
                                       in negationFreeClauses: [[ScopeUnit]]) -> Bool {
        if object.count >= 2 {
            return negationFreeClauses.contains { clause in
                zip(clause, clause.dropFirst()).contains { sameUnit($0.0, object[0]) && sameUnit($0.1, object[1]) }
            }
        }
        guard let only = object.first,
              negationFreeClauses.contains(where: { $0.contains { sameUnit($0, only) } }) else { return false }
        let inPolished = negationFreeClauses.joined().filter { sameUnit($0, only) }.count
        return inPolished >= rawContent.filter { sameUnit($0, only) }.count
    }

    /// 原文宾语的单元里，有几个也出现在润色这个否定的宾语里。
    private static func sharedUnits(_ rawObject: [ScopeUnit], _ polishedObject: [ScopeUnit]) -> Int {
        rawObject.filter { x in polishedObject.contains { sameUnit(x, $0) } }.count
    }

    /// 西文词共享 ≥3 个字母的前缀也算同一个（go / going、need / needed）。
    private static func sameUnit(_ a: ScopeUnit, _ b: ScopeUnit) -> Bool {
        if case .word(let x) = a, case .word(let y) = b {
            return x == y || (min(x.count, y.count) >= 3 && (x.hasPrefix(y) || y.hasPrefix(x)))
        }
        return a == b
    }

    private static func isPrefix(_ a: [ScopeUnit], of b: [ScopeUnit]) -> Bool {
        a.count <= b.count && zip(a, b).allSatisfy { $0.0 == $0.1 }
    }

    private static func isNegation(_ unit: ScopeUnit) -> Bool {
        switch unit {
        case .han(let c): return hanNegations.contains(c)
        case .word(let w): return ["not", "no", "never", "cannot"].contains(w) || w.hasSuffix("n't")
        default: return false
        }
    }

    /// 固定词里的否定字，不否定任何东西（特别、不过、无论…）。
    private static func isIdiomNegation(_ units: [ScopeUnit], at index: Int) -> Bool {
        guard case .han = units[index] else { return false }
        return negationIdioms.contains { matches($0, units, covering: index) }
    }

    static func isHan(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value, ch.unicodeScalars.count == 1 else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    /// `words` 里第一个从 `index` 开始被 `units` 拼出来的词的长度（只认汉字单元）。
    private static func prefixMatch(_ words: [[Character]], _ units: [ScopeUnit], at index: Int) -> Int? {
        words.first { spells($0, units, from: index) }?.count
    }

    private static func spells(_ word: [Character], _ units: [ScopeUnit], from start: Int) -> Bool {
        guard start >= 0, start + word.count <= units.count else { return false }
        for (k, ch) in word.enumerated() {
            // 固定词里的数字（一下、一定）已被 scopeUnits 折成 .number
            let expected: ScopeUnit = chineseNumerals.contains(ch) ? .number : .han(ch)
            if units[start + k] != expected { return false }
        }
        return true
    }

    /// `word` 在 `units` 里是否有一处出现覆盖了 `index` 这个位置。
    private static func matches(_ word: [Character], _ units: [ScopeUnit], covering index: Int) -> Bool {
        word.indices.contains { k in spells(word, units, from: index - k) }
    }

    /// 最后一个自我修正标记（「不对」「我是说」…，或单独成句的「不是，」）的位置。
    private static func lastCorrectionMarker(_ units: [ScopeUnit]) -> Int? {
        var last: Int?
        for j in units.indices {
            if prefixMatch(correctionMarkers, units, at: j) != nil { last = j }
            if spells(Array("不是"), units, from: j), j + 2 < units.count, units[j + 2] == .clauseBreak { last = j }
            if case .word("i") = units[j], j + 1 < units.count, units[j + 1] == .word("mean") { last = j }
        }
        return last
    }
}

// MARK: - 人名同音（nameChanged，C2）

/// C2：提示词第 5 条（修同音错别字）用在了人名上，而第 2 条（保真：人名…不改）明令禁止——
/// 识别按听到的写下了名字，模型的「纠正」只是猜。只有下面三条**同时**成立才拦：
///   1. 原文里一个 2–4 个汉字的词读作人名：NLTagger 标的 `.personalName`（`taggedNames`）
///      ∪ 确定性规则 `heuristicNames`——为什么两样都要，见那两个函数；
///   2. 这个名字在润色里没了；
///   3. 润色里在它的位置出现了一串**等长、逐字无调拼音相同**的汉字（汉 / 韩 → han），它不在
///      原文里、不只是繁转简（王總→王总 是第 6 条的本职），也不是词汇表里的写法（词汇表那一行
///      **要求**模型把听错的名字改成用户的写法）。
/// 所以普通名词的同音纠错（「嘉士奇」→「加湿器」：没有人名读法）照常放行；名字保留、删掉、
/// 或换成读音不同的另一个名字，也都放行。这道闸门误拦的代价比别的大：轻清理也修同音字，
/// 重试往往重复同一处修改、再被拦，最后插原文。
extension PolishFidelity {

    /// 被换成同音异字的原文人名个数（只报个数，绝不报名字）。
    static func homophoneNameChanges(raw: String, polished: String, glossary: [String]) -> Int {
        // NLTagger 之前先便宜地挡一道：同音替换必然带进一个原文里没有的汉字。
        let rawHan = Set(raw.filter(isHan))
        guard polished.contains(where: { isHan($0) && !rawHan.contains($0) }) else { return 0 }
        let tagged = taggedNames(in: raw), rules = heuristicNames(in: raw)
        return homophoneSwaps(of: tagged + rules.filter { !tagged.contains($0) },
                              raw: raw, polished: polished, glossary: glossary)
    }

    /// 给定一组原文人名，判第 2–3 条。单独拆出来是为了单测能只跑确定性规则那条路
    /// （不让 NLTagger 替它兜着）。
    static func homophoneSwaps(of names: [String], raw: String, polished: String, glossary: [String]) -> Int {
        let missing = names.filter { !polished.contains($0) }
        guard !missing.isEmpty else { return 0 }
        let pChars = Array(polished)
        let pSyllables = pChars.map { isHan($0) ? pinyin($0) : nil }
        let swapped = missing.filter { name in
            let target = name.map(pinyin)
            guard !target.contains(nil), pChars.count >= name.count else { return false }
            let simplifiedName = simplified(name)
            return (0...(pChars.count - name.count)).contains { start in
                let range = start..<(start + name.count)
                guard Array(pSyllables[range]) == target else { return false }
                let window = String(pChars[range])
                return !raw.contains(window) && window != simplifiedName
                    && !glossary.contains(where: { $0.contains(window) })
            }
        }
        // 一个人只算一次：确定性规则会给出嵌套的候选（汉明 和 汉明签）。
        return swapped.filter { name in !swapped.contains { $0 != name && $0.contains(name) } }.count
    }

    /// NLTagger 标成 `.personalName` 的 2–4 字汉字词（去重）。**语言固定为简体中文**——
    /// iOS 实测不固定时，混排句里的「一下」会被标成人名。
    /// iOS 2026-09-28 探测：macOS 26 上它认得 汉总 / 韩总 / 王总 / 李经理 / 陈老师 / 张伟 / 小明，
    /// 能分语境（「让高明来一趟」是人名，「这个方案很高明」不是）；iOS 27 模拟器上一个都不认。
    /// Mac 最低支持 macOS 15，那上面认不认**没验证过**——所以它只是加分项，
    /// `heuristicNames` 才是底线，两样都跑。
    static func taggedNames(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.setLanguage(.simplifiedChinese, range: text.startIndex..<text.endIndex)
        var names: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let token = String(text[range])
            if tag == .personalName, (2...4).contains(token.count), token.allSatisfy(isHan), !names.contains(token) {
                names.append(token)
            }
            return true
        }
        return names
    }

    /// 名字后面常跟的称呼（王总、李老师、刘哥）。
    private static let nameTitles: [[Character]] = ["老师", "经理", "医生", "主任", "律师", "教授", "老板",
        "总监", "总", "哥", "姐"].map { Array($0) }
    /// 引出一个人的字（跟汉明说、找小李、问老陈、给张总）。
    private static let nameIntroducers: Set<Character> = ["跟", "和", "找", "问", "给"]
    /// 在这里永远不算名字的一部分：代词、助词、最常用的虚词。
    /// 5.4.0 起词汇提议（VocabularySuggestions）也用它：「他们 → 它们」不是识别错了一个词
    static let nonNameChars: Set<Character> = Set("我你您他她它咱们的得地了着过吗呢吧啊呀嘛哦啦"
        + "是在再有和跟与给找问说就都也还又会要想能把被让对向往从到这那哪谁啥么个些不没很太")

    /// 确定性底线。候选是一个 2–3 字的汉字词，满足其一：
    ///   • 以称呼结尾：总 / 哥 / 姐 前 1–2 字，老师 / 经理 / … 前 1 字（汉总、李老师）；
    ///   • 紧跟在 跟 / 和 / 找 / 问 / 给 后面（跟汉明说 → 汉明）；
    /// 而且不含 `nonNameChars`。不加这层过滤的话，「我和他跑的很快」→「跑得」（天天发生的
    /// 的 / 得 纠错）和「他老师迟到」→「他老是迟到」都会被读成改名；「会总」→「汇总」同理（会）。
    /// 仍可能误拦的：紧跟「和」之后的同音纠错（「苹果和相交」→「香蕉」）或长得像称呼的词
    /// （「这首哥」→「这首歌」）——识别很少吐出这种东西，代价是一次润色。
    static func heuristicNames(in text: String) -> [String] {
        let chars = Array(text)
        func nameLike(_ range: Range<Int>) -> Bool {
            range.lowerBound >= 0 && range.upperBound <= chars.count
                && chars[range].allSatisfy { isHan($0) && !nonNameChars.contains($0) }
        }
        var names: [String] = []
        func add(_ range: Range<Int>) {
            let token = String(chars[range])
            if !names.contains(token) { names.append(token) }
        }
        for i in chars.indices {
            for title in nameTitles where i + title.count <= chars.count && Array(chars[i..<(i + title.count)]) == title {
                for prefix in 1...(title.count == 1 ? 2 : 1) where nameLike((i - prefix)..<i) {
                    add((i - prefix)..<(i + title.count))
                }
            }
            if nameIntroducers.contains(chars[i]) {
                for length in 2...3 where nameLike((i + 1)..<(i + 1 + length)) {
                    add((i + 1)..<(i + 1 + length))
                }
            }
        }
        return names
    }

    /// 一个汉字的无调小写拼音（汉 / 韩 → "han"）；转换失败返回 nil。
    static func pinyin(_ ch: Character) -> String? {
        guard let latin = String(ch).applyingTransform(.mandarinToLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false) else { return nil }
        let syllable = latin.lowercased().trimmingCharacters(in: .whitespaces)
        return syllable.isEmpty || syllable == String(ch) ? nil : syllable
    }

    /// 繁转简（Foundation 自带的 ICU 变换）。转换失败就原样返回——只会让闸门更严，不会更松。
    static func simplified(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }
}
