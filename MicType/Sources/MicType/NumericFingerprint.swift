import Foundation

/// 数字指纹：让保真校验看懂「一百零一」和「101」是同一个数。
///
/// 为什么 4.1.6 非做不可：本机识别模型吐出来的中文数字**永远是汉字**（「一百零一人民币」
/// 「二零一一年」），而润色提示词第 7 条从这一版起要求把它们写成阿拉伯数字——
/// 这正是用户想要的成品文本。但 4.1.5 的保真校验第 1) 条比的是**数字字符的多重集**，
/// 汉字数字里一个阿拉伯数字都没有，于是每一次正确的改写都会被判成「digits changed」、
/// 整段润色被丢回识别原文。提示词和这道校验必须同一版一起改。
///
/// 三条纪律（从 4.1.5 继承，一条都不松）：
///   • 纯函数、零网络、零 LLM 成本；
///   • 数值一位都不许变：这里做的只是「换个写法之后再比」，不是放宽；
///   • **失败原因里永远只有个数，绝不带数字本身**——日志尾巴会被「复制诊断信息」
///     整段贴进 issue，原样带上等于把用户刚说的验证码 / 电话 / 金额漏出去。
///
/// **已知性质（4.1.5 就是这样，这次没有变得更糟）**：比较是"无序 + 字符级"的，
/// 所以同一串数字**内部重排**（101 → 110）和**两个数之间互换数位**（214/315 → 314/215）
/// 都抓不住；抓得住的是"多了一位、少了一位、改了一位"——模型真正会犯的那几种错。
extension TextPostProcessor {

    /// 一段文字里的数字指纹。
    ///
    /// 分两桶是必须的：汉字数字里**孤零零一个字、还没有单位**的那种（「三点五公里」的三和五、
    /// 「十二块五」的五、「第一次」的一、版本号「四点一点六」的三个字）到底是不是一个数，
    /// 只有上下文知道——把它们当数字记进 digits，润色只要不改它就会被判成"数字被删"；
    /// 完全不记，润色把它写成阿拉伯数字又会被判成"凭空多出数字"。
    /// 所以单独记一桶 wildcards：它只用来**解释对面多出来的那一位**，自己消失了不算错。
    struct NumericFingerprint: Equatable {
        /// 归一化之后所有阿拉伯数字字符的多重集（与 4.1.5 的 digitMultiset 同一口径）
        var digits: [Character: Int] = [:]
        /// 没有单位的单个汉字数字，按它代表的数字字符记（两 = 2、幺 = 1）
        var wildcards: [Character: Int] = [:]
        /// 归一化之后**连续 ≥ 2 位**的数字串，去重。
        /// 第二层判据就靠它：汉字转阿拉伯数字最典型的错法是**零的位置错了 / 数位调了个儿**
        /// （一万零二百 = 10200 写成 12000、一千零五十 = 1050 写成 1500、101 写成 110），
        /// 这几对的数字字符多重集**一模一样**，只有"这个数原封不动出现过吗"看得出来。
        var tokens: [String] = []
        /// 归一化 + 去掉数字之间分隔符之后的整段文字（第二层拿它做包含判断）
        var text: String = ""
        /// **软数字**：可以用来解释对面多出来的位，但从不要求对面有。
        /// 时间的几种写法差异全靠它（三点半 → 3点半 / 3:30 / 15:30 都得放行）。
        /// 只进 extra 那一侧的兜底池，绝不产生 token、绝不要求出现。
        var softDigits: [Character: Int] = [:]
        /// 摘掉的编号列表序号个数（只给日志当旗子用，不参与判断）
        var listMarkers: Int = 0
        /// **列表条数**的数字（1…n 的 n）。润色按提示词第 8 条「列表前用一句话引出」时，
        /// 很爱在引出句里把条数写出来（「目前主要有3个问题：」）——而说话人只说了
        /// 「有几个问题」，原文里根本没有这个数。它是模型**数出来的结构信息**，不是事实，
        /// 所以和时间的软数字一样：**可以解释多出来的位，但从不要求出现，也不产生 token**。
        /// 只有真的摘掉了一串连号（n ≥ 2）才有值。
        var listCountDigits: [Character: Int] = [:]
        /// 这段文字里有没有时间说法（点 / 上下午 / o'clock / 3:10）——只给日志当旗子用
        var hasTimeWords: Bool = false
        /// 这段文字里有没有英文数字词（twenty five / March third）——只给日志当旗子用
        var hasEnglishNumbers: Bool = false
    }

    /// 把一段文字里的数字统一成阿拉伯数字之后取指纹。纯函数。
    /// **绝不进日志**：返回值带着用户说过的数字本身（和 strippedOfPunctuation 同一条纪律）。
    static func numericFingerprint(_ text: String) -> NumericFingerprint {
        // a) 全角 / 阿拉伯-印度数字折成半角，后面几步才认得出它们是数字
        var work = foldedDigits(text)
        // a2) 编号列表的序号（1. 2. 3.）——那是润色按提示词第 8 条加的**结构**，不是事实里的数
        let delisted = strippedOfListMarkers(work)
        work = delisted.text
        // b) 含数字字的成语、固定说法、星期 —— 它们不是数，先整个摘掉
        work = strippedOfNumberIdioms(work)
        // b2) 时间的软数字：要在汉字数字还看得见的时候算（三点半 / 下午三点）
        let soft = softDigits(in: work)
        // c) 「1.2万」「3500万」这类阿拉伯数字 + 汉字单位 → 摊平成 12000 / 35000000
        work = expandedArabicUnits(work)
        // d) 汉字数字串 → 阿拉伯数字（顺带把"单个字、没单位"的收进 wildcards）
        var wildcards: [Character: Int] = [:]
        work = expandedChineseNumerals(work, wildcards: &wildcards)
        // d2) 英文数字词（twenty five / March third）→ 阿拉伯数字，口径与汉字那边一致
        var hasEnglish = false
        work = expandedEnglishNumerals(work, wildcards: &wildcards, found: &hasEnglish)
        // f) 去掉**夹在两个数字之间**的千分位 / 连字符 / 空格：1,000 与 1000、
        //    138-0013-8000 与 13800138000 是同一个数，不能因为写法不同就判成改了数
        work = strippedOfGroupSeparators(work)
        // e) 剩下的就只是阿拉伯数字了，照 4.1.5 的老口径数一遍
        return NumericFingerprint(digits: digitMultiset(work), wildcards: wildcards,
                                  tokens: numberTokens(in: work), text: work,
                                  softDigits: soft, listMarkers: delisted.markers,
                                  listCountDigits: delisted.markers >= 2
                                      ? digitsOf(delisted.markers) : [:],
                                  hasTimeWords: containsTimeWords(text),
                                  hasEnglishNumbers: hasEnglish)
    }

    /// 归一化之后连续 ≥ 2 位的数字串，去重。
    /// **只收 ≥ 2 位**：单个数字由多重集 + wildcard 那一层管（版本号 4.1.6 / 四点一点六
    /// 因此一个 token 都不产生，不会被这一层误伤）。
    static func numberTokens(in normalized: String) -> [String] {
        var tokens: [String] = []
        var run = ""
        func flush() {
            if run.count >= 2, !tokens.contains(run) { tokens.append(run) }
            run = ""
        }
        for character in normalized {
            if character.isASCII, character.isNumber { run.append(character) } else { flush() }
        }
        flush()
        return tokens
    }

    /// 两段文字里的数字是不是同一批。false = 这次润色动了数值，必须回退原文。
    /// 两层都得过（哪一层没过要写进日志的话，见 polishDriftCheck 里分开调的那两步）。
    static func numbersPreserved(raw: String, polished: String) -> Bool {
        let r = numericFingerprint(raw)
        let p = numericFingerprint(polished)
        return digitsPreserved(r, p) && missingNumberTokens(r, p).isEmpty
    }

    /// 第一层：数字字符的多重集 + wildcard 兜底。
    ///
    /// 判据对称地走两遍：
    ///   • 原文有、润色没有的那些位（missing），必须由润色**多出来的** wildcard 解释
    ///     （「12块5」→「十二块五」这个方向：那个 5 在润色侧变回了没单位的汉字）；
    ///   • 润色有、原文没有的那些位（extra），必须由原文**多出来的** wildcard 解释
    ///     （「三点五公里」→「3.5公里」这个方向，也是这一版的主场景）；
    ///   • wildcard 自己凭空消失不算错：口头的「那个一」被润色删掉是它的本职。
    /// 软数字只站在 extra 这一侧：原文说「三点半」，润色写 3:30 / 15:30 都放行；
    /// 但反过来绝不要求润色里非得出现 30——它本来就可以写成「3点半」。
    ///
    /// 两桶软数字各有各的**出身侧**，混不得：
    ///   • 时间那桶来自**原文**（说话人说了「三点半」，所以润色可以写 30）；
    ///   • 列表条数那桶来自**润色**（列表是润色摆出来的，条数也是它数出来的），
    ///     所以只用来解释润色多出来的那一位，绝不参与 missing 那一侧。
    /// 反过来把润色那侧的时间软数字也放进池子会白白松一大截——那是它自己写的字，
    /// 不能用来给它自己背书。
    ///
    /// **extra 那一侧的池子不再减去润色的 wildcard（4.2.1 实测后改）**：
    /// 减法的前提是"润色里还留着的那个汉字数字，就是原文里的同一个"。它不是。
    /// 润色一边**转换**口语数字（两个人 → 2人），一边按我们自己提示词的第 8 条
    /// **新造**结构性的汉字数字（二选一 / 三个问题 / 三点建议），而多重集分不清哪个是哪个——
    /// 新造的那个「二」抵掉了本该解释「2人」的 wildcard 2，一段忠实的润色就这么被丢掉，
    /// 长口述大约三次里挂一次（联网实测抓到的）。
    /// 代价小且是单向的：原文里有一个孤立汉字数字时，它可以解释一个同值的阿拉伯数字，
    /// **哪怕那个汉字还留在成品里**（「三个人来」→「三个人来，花了3小时」会放过那个 3，
    /// 见 testKnownCostABareNumeralCanExplainOneSameValuedDigit）。
    /// 这道校验真正守的东西一样没松：多位数仍由数字多重集 + 连续 token 那一层钉着，
    /// 原文一个数字都没有时池子是空的（凭空造数照样拦），missing 那一侧照旧做减法。
    static func digitsPreserved(_ r: NumericFingerprint, _ p: NumericFingerprint) -> Bool {
        let missing = subtracting(r.digits, p.digits)
        let extra = subtracting(p.digits, r.digits)
        let extraPool = merging(merging(r.wildcards, r.softDigits), p.listCountDigits)
        return covered(missing, by: subtracting(p.wildcards, r.wildcards))
            && covered(extra, by: extraPool)
    }

    /// 一个数拆成数字字符的多重集（12 → {1:1, 2:1}）
    private static func digitsOf(_ number: Int) -> [Character: Int] {
        var out: [Character: Int] = [:]
        for character in String(number) { out[character, default: 0] += 1 }
        return out
    }

    /// 失败原因后面挂的几面小旗子：**只有个数与真假，没有一个字来自用户**。
    /// 4.1.6 日志里那两行 `rawCount=0 polishedCount=3` 说明"多出来三位"，
    /// 但说不出那三位是列表序号、时间，还是英文数字——查不出来就只能猜，所以补上这几面旗。
    /// - includeCounts: 「number rewritten …」那行本来就带 missing=，再来一个会把日志的
    ///   key 搞重，所以那行只挂后半截。
    static func numericFailureFlags(_ r: NumericFingerprint, _ p: NumericFingerprint,
                                    includeCounts: Bool = true) -> String {
        var out = ""
        if includeCounts {
            let missing = subtracting(r.digits, p.digits).values.reduce(0, +)
            let extra = subtracting(p.digits, r.digits).values.reduce(0, +)
            out += " extra=\(extra) missing=\(missing)"
        }
        return out + " listMarkers=\(r.listMarkers + p.listMarkers)"
            + " rawTimeWords=\(r.hasTimeWords) rawEnglishNumbers=\(r.hasEnglishNumbers)"
    }

    /// 两个多重集相加（软数字并进 wildcard 池时用）
    private static func merging(_ a: [Character: Int], _ b: [Character: Int]) -> [Character: Int] {
        var out = a
        for (key, count) in b { out[key, default: 0] += count }
        return out
    }

    /// 第二层：**原文里每一个多位数，都得原封不动地在润色里出现过**。
    ///
    /// 为什么光有多重集不够：汉字转阿拉伯数字最典型的错就是零的位置错了 / 数位调了个儿——
    /// 一万零二百（10200）写成 12000、一千零五十（1050）写成 1500、一百零一（101）写成 110，
    /// 这几对的数字字符多重集完全相同，第一层一个都拦不住。
    ///
    /// 用"包含"而不是"相等"：润色会在数字周围加单位、改标点、接小数
    /// （「十二块五」→「12.5元」里 token 12 是 12.5 的一截），
    /// 而「1.2万」在比之前已经被摊成 12000。包含只可能过于宽松，绝不会冤枉一次忠实的改写。
    static func missingNumberTokens(_ r: NumericFingerprint, _ p: NumericFingerprint) -> [String] {
        r.tokens.filter { !p.text.contains($0) }
    }

    /// a ∖ b（多重集差），负数不留
    static func subtracting(_ a: [Character: Int], _ b: [Character: Int]) -> [Character: Int] {
        var out: [Character: Int] = [:]
        for (key, count) in a {
            let left = count - b[key, default: 0]
            if left > 0 { out[key] = left }
        }
        return out
    }

    /// needed 里每一位都被 pool 里的 wildcard 兜住了吗
    private static func covered(_ needed: [Character: Int], by pool: [Character: Int]) -> Bool {
        for (key, count) in needed where pool[key, default: 0] < count { return false }
        return true
    }

    // MARK: - a) 折半角

    /// 全角（１２３）与阿拉伯-印度数字（٢٠٢٦ / ۲۰۲۶）折成 ASCII，其余字符原样。
    /// 与 digitMultiset 里的折算表逐位一致——一边改了另一边必须跟着改。
    private static func foldedDigits(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            var value = scalar.value
            if (0xFF10...0xFF19).contains(value) { value -= 0xFF10 - 0x30 }
            if (0x0660...0x0669).contains(value) { value -= 0x0660 - 0x30 }
            if (0x06F0...0x06F9).contains(value) { value -= 0x06F0 - 0x30 }
            out.append(Unicode.Scalar(value) ?? scalar)
        }
        return String(out)
    }

    // MARK: - a2) 编号列表的序号

    /// 一个可能是列表序号的位置：**1–30 的数字 + 点/顿号/右括号**，
    /// 前面只能是行首 / 空白 / 句读 / 左括号（所以绝不会咬住 4.1.6、1.5元、12.5 里的数字），
    /// 后面不能再跟数字。`:` `：` 故意不算——「主要有三点：」后面那个冒号属于引出句。
    private static let listMarkerRegex = try? NSRegularExpression(
        pattern: "(^|[\\n\\r \\t：:；;，,。(（])(\\d{1,2})([.．、)）])(?!\\d)")

    /// 摘掉编号列表的序号，返回摘干净的文本 + 摘掉几个。
    ///
    /// 为什么必须摘（4.1.6 用户日志里 `rawCount=0 polishedCount=5 distinct=0/4` 那一条）：
    /// 提示词第 8 条**要求**润色把多个要点整理成编号列表，于是一段 59 秒的口述被分成四点，
    /// 成品里凭空多出「1. 2. 3. 4.」四个数字——原文里一个都没有（「首先…然后…最后」不含数字），
    /// 保真校验只能判它"凭空多出数字"。这不是 4.1.6 引入的，老版本一样拦，
    /// 而长口述正是最需要润色的场景。
    ///
    /// **只有序号连成 1,2,…,n（n ≥ 2）才摘**：孤零零一个「1.」或者「3. 5.」是数据不是列表，
    /// 一律不动。这条是整个函数的安全底线——否则「1. 预算50万 2. 延期」这种
    /// 假列表就能把一个凭空冒出来的 50 万偷渡进去（那一条有单测钉着）。
    static func strippedOfListMarkers(_ text: String) -> (text: String, markers: Int) {
        guard let regex = listMarkerRegex else { return (text, 0) }
        let ns = text as NSString
        var ranges: [NSRange] = []
        var numbers: [Int] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let value = Int(ns.substring(with: match.range(at: 2))),
                  (1...30).contains(value) else { continue }
            ranges.append(NSRange(location: match.range(at: 2).location,
                                  length: match.range(at: 2).length + match.range(at: 3).length))
            numbers.append(value)
        }
        guard numbers.count >= 2, numbers == Array(1...numbers.count) else { return (text, 0) }
        var out = text
        for range in ranges.reversed() {
            guard let swiftRange = Range(range, in: out) else { continue }
            out.replaceSubrange(swiftRange, with: " ")
        }
        return (out, numbers.count)
    }

    // MARK: - b2) 时间的软数字

    /// 「点半 / 点一刻 / 点三刻」——分钟数是**说法自带的**，原文里没有对应的数字
    private static let clockFractionRegex =
        try? NSRegularExpression(pattern: "[点點](半|一刻|三刻)")

    /// 「N 点」里的 N（阿拉伯数字或汉字），用来判 12 小时制 → 24 小时制
    private static let clockHourRegex =
        try? NSRegularExpression(pattern: "([0-9]{1,2}|[零〇一二三四五六七八九十两]{1,3})[点點]")

    /// 说了这些词，「三点」就是 15 点——模型写成 15:00 是对的，不能判它凭空造数
    private static let afternoonMarkers = ["下午", "晚上", "傍晚", "今晚", "夜里", "晚间"]

    /// 时间说法带来的**软数字**（可以解释多出来的位，但从不要求出现）：
    ///   • 点半 → 30、点一刻 → 15、点三刻 → 45；
    ///   • 下午/晚上…N 点（N ≤ 11）→ N+12（下午三点 = 15 点）。
    /// 这是刻意开的口子：它让「三点半」→「3:30」「15:30」都能过，代价是原文里有「点半」时，
    /// 润色那边多出来的 3 或 0 也会被放过一次。时间是语音输入里最常说的东西，值这个价。
    static func softDigits(in text: String) -> [Character: Int] {
        var soft: [Character: Int] = [:]
        func add(_ number: Int) {
            for character in String(number) { soft[character, default: 0] += 1 }
        }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if let regex = clockFractionRegex {
            for match in regex.matches(in: text, range: whole) {
                switch ns.substring(with: match.range(at: 1)) {
                case "半": add(30)
                case "一刻": add(15)
                default: add(45)
                }
            }
        }
        if let regex = clockHourRegex {
            for match in regex.matches(in: text, range: whole) {
                let hourText = ns.substring(with: match.range(at: 1))
                guard let hour = hourValue(hourText), (1...11).contains(hour) else { continue }
                // 往前看 6 个字：口语里「下午」「晚上」总在钟点前面不远处
                let start = match.range.location
                let lookBehind = NSRange(location: max(0, start - 6), length: min(6, start))
                let context = ns.substring(with: lookBehind)
                guard afternoonMarkers.contains(where: { context.contains($0) }) else { continue }
                add(hour + 12)
            }
        }
        return soft
    }

    private static func hourValue(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        return positionalValue(of: text)
    }

    /// 这段话里有没有时间说法——**只给日志当旗子**，不参与任何判断
    private static let timeWordRegex = try? NSRegularExpression(
        pattern: "[点點]|o'?clock|[0-9]\\s*:\\s*[0-9]|[上下]午|晚上", options: [.caseInsensitive])

    static func containsTimeWords(_ text: String) -> Bool {
        guard let regex = timeWordRegex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - b) 不是数的那些「数字」

    /// 含数字字、却**根本不表数量**的固定说法：比数之前整个摘掉，两边一视同仁。
    /// 摘不干净的代价只是多回退一次润色；摘错一条（把真数量词写进来）等于在那个词上
    /// 把保真校验挖穿——所以只收**明确安全**的条目，拿不准的一律不收。
    /// 与润色提示词第 7 条「保持汉字」的那一串是同一批词，一边加词另一边也要想一想。
    private static let numberIdioms: [String] = [
        // 「一」不表数量
        "一旦", "统一", "唯一", "一些", "一下", "一起", "一样", "一直", "一定", "一般",
        "一边", "一切", "一共", "一会儿", "一方面", "不一样", "一点点", "有一点", "万一",
        // 成语 / 四字格
        "三心二意", "一心一意", "乱七八糟", "七上八下", "五花八门", "四面八方",
        "十全十美", "一模一样", "独一无二", "接二连三", "千方百计", "百分百",
        "万分", "百般",
        // 「百分之 / 百分点」是**单位词**不是数：不摘掉的话那个「百」会被当成 100
        "百分之", "百分点",
    ].sorted { $0.count > $1.count }

    /// 要看上下文才能判的几条（写成正则，不能整词摘）：
    ///   • 「十分」= 非常（十分重要），但**紧挨着前面是「点」或一个数字**时它是 10
    ///     （三点十分 = 3:10、四十分钟）；后面跟「钟」「之」的老例外照旧；
    ///   • 「千万」= 务必，除非**紧挨着前面**就是一个数字（三千万 / 3千万 是数）；
    ///   • 星期 / 周 / 礼拜 + 一二三四五六日天 = 日期名，不是数量。
    ///
    /// **4.2.1 删掉了「一点」那一条**：它把「下午一点开会」「一点到三点」里的钟点整个吃掉，
    /// 于是润色写出来的「1点」成了没人认领的多余数字，整段被判跑飞。
    /// 现在「一」照常当成没有单位的单个数字（wildcard）——wildcard 消失不算错，
    /// 所以「有一点累」→「有点累」仍然放行，而「一点开会」→「1点开会」也放行了。
    private static let contextualNumberIdioms: [NSRegularExpression] = [
        "(?<![点點零〇一二三四五六七八九十两幺0-9])十分(?![钟之])",
        "(?<![零〇一二三四五六七八九两幺0-9])千万",
        "(星期|周|礼拜)[一二三四五六日天]",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static func strippedOfNumberIdioms(_ text: String) -> String {
        var out = text
        // 长的先摘：短词先动手会把长词咬掉一半（「一点点」被「一点」咬成「点」）
        for idiom in numberIdioms {
            out = out.replacingOccurrences(of: idiom, with: " ")
        }
        for regex in contextualNumberIdioms {
            out = regex.stringByReplacingMatches(in: out,
                                                 range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: " ")
        }
        return out
    }

    // MARK: - c) 阿拉伯数字 + 汉字单位

    /// 「1.2万」「3500万」「2亿」：润色最爱写的形式，摊平成整数才比得了。
    /// 用 Decimal 而不是 Double：1.2 * 10000 在二进制浮点里是 12000.000000000002，
    /// 摊出来就多一串 0 和 2，这道校验会当场判"数字被改"。
    private static let arabicUnitRegex =
        try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)(千万|百万|十万|万|亿|千|百)")

    /// 口语式的省略尾数，阿拉伯数字版：1万2 = 12000、3千5 = 3500、2百5 = 250。
    /// 尾数跟的是这个单位的下一档，和汉字那边 positionalValue 的规则同源。
    /// 后面再跟数字或单位就不是这个形状（1万23 / 1万2千），交给别的分支。
    private static let arabicAbbreviatedRegex =
        try? NSRegularExpression(pattern: "(\\d+)(万|千|百)(\\d)(?![0-9万亿千百十])")

    /// 夹在**两个数字之间**的千分位 / 连字符 / 各种空格：1,000 = 1000、
    /// 138-0013-8000 = 13800138000。只在两边都是数字时删，句子里正常的逗号空格不受影响。
    private static let groupSeparatorRegex =
        try? NSRegularExpression(pattern: "(?<=[0-9])[,，\\u00A0\\u2009\\u202F \\-](?=[0-9])")

    private static func strippedOfGroupSeparators(_ text: String) -> String {
        guard let regex = groupSeparatorRegex else { return text }
        return regex.stringByReplacingMatches(in: text,
                                              range: NSRange(text.startIndex..., in: text),
                                              withTemplate: "")
    }

    private static let unitValues: [String: Decimal] = [
        "亿": 100_000_000, "千万": 10_000_000, "百万": 1_000_000, "十万": 100_000,
        "万": 10_000, "千": 1_000, "百": 100,
    ]

    private static func expandedArabicUnits(_ text: String) -> String {
        // 省略尾数那一形状要**先摊**：不然 1万2 会被下面的规则吃成 10000 + 一个孤零零的 2
        var text = expandedArabicAbbreviations(text)
        guard let regex = arabicUnitRegex else { return text }
        let ns = text as NSString
        var out = text
        // 从后往前替换，前面的 range 才不会被前一次替换挪走
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let number = ns.substring(with: match.range(at: 1))
            let unit = ns.substring(with: match.range(at: 2))
            guard let value = Decimal(string: number), let scale = unitValues[unit] else { continue }
            let expanded = NSDecimalNumber(decimal: value * scale).stringValue
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: " " + expanded + " ")
        }
        return out
    }

    private static func expandedArabicAbbreviations(_ text: String) -> String {
        guard let regex = arabicAbbreviatedRegex else { return text }
        let ns = text as NSString
        var out = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let head = ns.substring(with: match.range(at: 1))
            let unit = ns.substring(with: match.range(at: 2))
            let tail = ns.substring(with: match.range(at: 3))
            guard let headValue = Decimal(string: head), let tailValue = Decimal(string: tail),
                  let scale = unitValues[unit] else { continue }
            let value = headValue * scale + tailValue * scale / 10
            let expanded = NSDecimalNumber(decimal: value).stringValue
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: " " + expanded + " ")
        }
        return out
    }

    // MARK: - d) 汉字数字

    /// 「两」= 2、「幺」= 1（报电话号码时的读法）；「零」「〇」都是 0
    private static let chineseDigitValues: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "两": 2, "幺": 1,
    ]
    private static let chineseUnitValues: [Character: Int] = [
        "十": 10, "百": 100, "千": 1_000, "万": 10_000, "亿": 100_000_000,
    ]

    /// 把每一段连续的汉字数字换成阿拉伯数字。三种情形：
    ///   • 段里有单位 → 按位值算（十二 → 12、一百零一 → 101、一万二 → 12000）；
    ///   • 没单位但 ≥ 2 个字 → 当成一串数位念（二零一一 → 2011、幺三八零零 → 13800）。
    ///     「两三个」会被念成 23，两边都这么念，所以不影响比较；
    ///   • 没单位、只有一个字 → **不算数**，记进 wildcards（见 NumericFingerprint 的注释）。
    private static func expandedChineseNumerals(_ text: String,
                                                wildcards: inout [Character: Int]) -> String {
        var out = ""
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            out += " " + converted(run: run, wildcards: &wildcards) + " "
            run = ""
        }
        for character in text {
            if chineseDigitValues[character] != nil || chineseUnitValues[character] != nil {
                run.append(character)
            } else {
                flush()
                out.append(character)
            }
        }
        flush()
        return out
    }

    private static func converted(run: String, wildcards: inout [Character: Int]) -> String {
        let hasUnit = run.contains { chineseUnitValues[$0] != nil }
        if hasUnit {
            // 光秃秃一个单位字（上万人、成千、过百）是约数不是数——
            // 唯一的例外是「十」，它自己就是 10（十个人）
            if run.count == 1, run != "十" { return "" }
            if let value = positionalValue(of: run) { return String(value) }
            // 位值算不出来（溢出 / 怪组合）：退回逐字摊开，两边一视同仁
            return String(run.map { Character(String(chineseDigitValues[$0] ?? 0)) })
        }
        if run.count >= 2 {
            // 没单位的多字串：当成一串数位念（二零一一 → 2011、幺三八零零 → 13800）
            return String(run.map { Character(String(chineseDigitValues[$0] ?? 0)) })
        }
        if let first = run.first, let value = chineseDigitValues[first] {
            wildcards[Character(String(value)), default: 0] += 1
        }
        return ""
    }

    // MARK: - d2) 英文数字词

    /// 为什么英文也得认（4.1.6 用户实测）：gpt-5.6-luna 不管提示词怎么写，都会自己把
    /// "twenty five dollars" 写成 "$25"、"March third" 写成 "March 3"——那正是用户要的成品。
    /// 而这道校验以前只认汉字数字，于是**每一句带英文数字词的听写都回退原文**。
    /// 口径与汉字那边逐条对齐：整串算出一个值就是"必须保住的数"，
    /// 孤零零一个 zero–nine（one of…、a second、March third）只当 wildcard。
    private static let englishSmallWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
        // 序数：日期里最常见（March third / the first）
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
        "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
        "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    ]
    private static let englishTensWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "twentieth": 20, "thirtieth": 30,
    ]
    /// 复数（hundreds of / thousands of）**故意不收**：那是约数，不是数
    private static let englishScaleWords: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    private static let englishWordRegex = try? NSRegularExpression(pattern: "[A-Za-z]+")

    /// 把每一串连着的英文数字词换成阿拉伯数字。分词用 `[A-Za-z]+`，所以
    /// none / someone / often / tension 这些"里面含数字词"的普通词一个都不会被认出来。
    private static func expandedEnglishNumerals(_ text: String,
                                                wildcards: inout [Character: Int],
                                                found: inout Bool) -> String {
        guard let regex = englishWordRegex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let words = matches.map { ns.substring(with: $0.range).lowercased() }

        func isNumberWord(_ index: Int) -> Bool {
            let word = words[index]
            return englishSmallWords[word] != nil || englishTensWords[word] != nil
                || englishScaleWords[word] != nil
        }
        /// 「a hundred」里的 a 才算数；别处的 a 就是个冠词
        func isArticleBeforeScale(_ index: Int) -> Bool {
            words[index] == "a" && index + 1 < words.count
                && englishScaleWords[words[index + 1]] != nil
        }
        /// 两个词之间只隔着空格 / 连字符才算同一串（逗号、句号一律断开）
        func joinable(_ left: Int, _ right: Int) -> Bool {
            let gapStart = matches[left].range.location + matches[left].range.length
            let gap = ns.substring(with: NSRange(location: gapStart,
                                                 length: matches[right].range.location - gapStart))
            return gap.allSatisfy { $0 == " " || $0 == "\t" || $0 == "-" || $0 == "\u{2011}" }
        }

        var replacements: [(NSRange, String)] = []
        var index = 0
        while index < words.count {
            guard isNumberWord(index) || isArticleBeforeScale(index) else { index += 1; continue }
            var end = index
            while end + 1 < words.count, joinable(end, end + 1) {
                if isNumberWord(end + 1) || isArticleBeforeScale(end + 1) { end += 1; continue }
                // and 只在两个数字中间才被吸收（a hundred and one）
                if words[end + 1] == "and", end + 2 < words.count, joinable(end + 1, end + 2),
                   isNumberWord(end + 2) {
                    end += 1
                    continue
                }
                break
            }
            found = true
            var digits: [String] = []
            for number in parseEnglishNumbers(Array(words[index...end])) {
                if number.words == 1, (0...9).contains(number.value) {
                    // 单独一个 one / three / third：是不是数只有上下文知道 → 只当 wildcard
                    wildcards[Character(String(number.value)), default: 0] += 1
                } else {
                    digits.append(String(number.value))
                }
            }
            let start = matches[index].range.location
            let range = NSRange(location: start,
                                length: matches[end].range.location + matches[end].range.length - start)
            replacements.append((range, " " + digits.joined(separator: " ") + " "))
            index = end + 1
        }
        var out = text
        for (range, replacement) in replacements.reversed() {
            guard let swiftRange = Range(range, in: out) else { continue }
            out.replaceSubrange(swiftRange, with: replacement)
        }
        return out
    }

    /// 一串英文数字词 → 若干个数（每个带"用了几个词"，单个小词才算 wildcard）。
    ///
    /// **贪心且会断开**：读到一个接不上的词就把手里的数交出去，再起一个新的。
    /// 年份的口语读法正靠这条——"twenty twenty six" 断成 20 和 26，
    /// 两个数的数字加起来正好是 2026 的那几位，而 "20"/"26" 又都是 "2026" 的子串，
    /// 所以两层判据都过得去（有单测钉着）。
    /// 溢出（billion billion…）直接放弃整串，两边一视同仁。
    private static func parseEnglishNumbers(_ words: [String]) -> [(value: Int, words: Int)] {
        var out: [(value: Int, words: Int)] = []
        var total = 0, current = 0, wordCount = 0
        var hasUnits = false, hasTens = false
        var overflowed = false

        func add(_ a: Int, _ b: Int) -> Int {
            let (sum, overflow) = a.addingReportingOverflow(b)
            if overflow { overflowed = true; return 0 }
            return sum
        }
        func multiply(_ a: Int, _ b: Int) -> Int {
            let (product, overflow) = a.multipliedReportingOverflow(by: b)
            if overflow { overflowed = true; return 0 }
            return product
        }
        func flush() {
            guard wordCount > 0 else { return }
            out.append((add(total, current), wordCount))
            total = 0; current = 0; wordCount = 0; hasUnits = false; hasTens = false
        }

        for word in words {
            if overflowed { break }
            if word == "and" { continue }
            if word == "a" {
                current = 1
                wordCount += 1
                continue
            }
            if let scale = englishScaleWords[word] {
                if scale == 100 {
                    current = multiply(current == 0 ? 1 : current, 100)
                } else {
                    total = add(total, multiply(current == 0 ? 1 : current, scale))
                    current = 0
                }
                hasUnits = false
                hasTens = false
                wordCount += 1
                continue
            }
            if let tens = englishTensWords[word] {
                if hasTens || hasUnits { flush() }
                current = add(current, tens)
                hasTens = true
                wordCount += 1
                continue
            }
            guard let small = englishSmallWords[word] else { continue }
            // 个位后面又来个位、十几后面又来十几 → 这是两个数（twenty twenty six 的断法）
            if hasUnits || (small >= 10 && hasTens) { flush() }
            current = add(current, small)
            hasUnits = true
            if small >= 10 { hasTens = true }
            wordCount += 1
        }
        flush()
        return overflowed ? [] : out
    }

    /// 汉字数字的位值解析。返回 nil = 这串算不出来（溢出 / 怪组合），调用方退回逐字摊开。
    ///
    /// 三档累加（亿 / 万 / 个）才算得对「一亿二千万」；两个细节是口语里最常见、
    /// 少了就会错得离谱的：
    ///   • **打头的十**：十二 = 12（不是 2）；
    ///   • **省略的尾数**：两千五 = 2500、三百五 = 350、一万二 = 12000——
    ///     尾数跟的是上一个单位的下一档。但只要中间念了「零」，尾数就是实打实的个位：
    ///     一百零一 = 101，绝不是 110。
    private static func positionalValue(of run: String) -> Int? {
        var total = 0        // 亿 及以上
        var section = 0      // 万 档
        var current = 0      // 个 档
        var number = 0       // 还没落位的那个数字
        var lastUnit = 0     // 最近用过的单位，给"省略的尾数"用
        var sawZero = false  // 上一个单位之后念过「零」吗

        func add(_ a: Int, _ b: Int) -> Int? {
            let (sum, overflow) = a.addingReportingOverflow(b)
            return overflow ? nil : sum
        }
        func multiply(_ a: Int, _ b: Int) -> Int? {
            let (product, overflow) = a.multipliedReportingOverflow(by: b)
            return overflow ? nil : product
        }

        for character in run {
            if let digit = chineseDigitValues[character] {
                if digit == 0 { sawZero = true } else { number = digit }
                continue
            }
            guard let unit = chineseUnitValues[character] else { return nil }
            if unit == 10_000 || unit == 100_000_000 {
                // 万 / 亿：把这一档以下攒的所有零碎整体抬上去。
                // 万只抬"万以下那一段"、亿那一档原样留着，「一亿二千万」才算得对。
                guard let below = add(section, current), let head = add(below, number) else { return nil }
                if unit == 10_000 {
                    guard let lifted = multiply(head, unit) else { return nil }
                    section = lifted
                } else {
                    guard let whole = add(total, head), let lifted = multiply(whole, unit) else { return nil }
                    total = lifted
                    section = 0
                }
                current = 0
                number = 0
            } else {
                // 打头的十：十二 = 12
                if number == 0, !sawZero, unit == 10 { number = 1 }
                guard let piece = multiply(number, unit), let sum = add(current, piece) else { return nil }
                current = sum
                number = 0
            }
            lastUnit = unit
            sawZero = false
        }
        // 省略的尾数：跟的是上一个单位的下一档（两千五 = 2500）；念过「零」就是实打实的个位
        if number != 0 {
            let scale = (!sawZero && lastUnit >= 100) ? lastUnit / 10 : 1
            guard let piece = multiply(number, scale), let sum = add(current, piece) else { return nil }
            current = sum
        }
        guard let head = add(total, section), let value = add(head, current) else { return nil }
        return value
    }
}
