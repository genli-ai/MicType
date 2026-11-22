import Foundation

// MARK: - DeepSeek 的联网搜索（5.5.0，纯函数）
//
// 规矩是「支持的服务商下永远开」：DeepSeek 档的每一条语音指令都挂着服务端工具
// `tools: [{type: "deepseek_web_search"}]`（LLMClient.chatBody）。这个工具**不能用 tool_choice 强制**
// （400，iOS 中文版 2026-11-14 实测），搜不搜由模型自己定——实测它常常不搜、凭记忆编一个答案
// （「查北京明天天气」三次里三次没搜，编了天气），还会编一个"今天"去搜。所以有两道补救：
//   1. 指令的系统提示末尾加一行当天日期（只加给 DeepSeek 的指令路径，润色 prompt 一个字不动）；
//   2. 回包 `usage.server_tool_use.tool_search > 0` 才算真搜了。没搜、而用户**明说了要查**
//      （wantsSearch）→ App 自己调 `POST /v1/tools/search` 直接搜一次，把结果当上下文再问一次模型作答；
//      直接搜索也失败 / 没结果 → 按现有「指令失败」那条路报错，什么都不插入。
//
// 为什么兜底只看"用户明说了要查"：工具永远挂着，「把这段翻成英文」不搜是对的——要是"没搜就直接搜"，
// 每条指令都会多花一次搜索的钱、还会拿搜索结果去回答一个不需要它的问题。判据照搬 iOS 中文版
// CommandWebSearch.wantsSearch（含它补过的那几处名词误判），日期与结果块的写法也照搬（同一批实测）。
//
// 移植自 `10 mictype_ios_cn/MicTypeCore/Sources/MicTypeCore/CommandWebSearch.swift`（只读参考）。
enum DeepSeekWebSearch {

    // MARK: 用户明说了要查吗

    /// 明确的中文说法
    static let chineseTriggers = ["搜索", "搜一下", "搜一搜", "搜下", "搜搜",
                                  "联网", "上网查", "网上查", "网上搜"]
    /// 「联网」前面是这几个字时是名词（互联网 / 物联网 / 车联网…），不是要搜
    static let lianwangNounPrefixes: Set<Character> = ["互", "物", "车", "因", "局", "广"]
    /// 「搜索」后面是这几个词时是名词（搜索引擎 / 搜索框…），不是要搜
    static let sousuoNounSuffixes = ["引擎", "框", "栏", "结果", "记录", "功能", "历史"]
    /// 查字族：有选区（有一段字要处理）时「查一下这段有没有错别字」是"检查"，不是"搜"——只在没有目标时算
    static let chaTriggers = ["查一下", "查一查", "查查", "查下"]
    /// 以 搜 / 查 开头算要搜——这两个动词除外
    static let leadingExclusions = ["搜集", "查看"]

    private static let englishTrigger = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])(search\s+for|search\s+the\s+web|search\s+online|search\s+it|web\s+search|look\s+up|look\s+it\s+up|google\s+it|google\s+for|search\s*一?下|google\s*一?下)(?![A-Za-z])"#,
        options: [.caseInsensitive])
    private static let englishLeading = try! NSRegularExpression(
        pattern: #"^(search|google)\s"#, options: [.caseInsensitive])

    /// 指令里是不是明说了要联网查。`hasTarget` = 这条指令有一段字要处理（选区）：那时查字族不算。
    static func wantsSearch(_ instruction: String, hasTarget: Bool) -> Bool {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        for trigger in chineseTriggers + (hasTarget ? [] : chaTriggers) {
            var searchStart = text.startIndex
            while let range = text.range(of: trigger, range: searchStart..<text.endIndex) {
                searchStart = range.upperBound
                let preceding = range.lowerBound > text.startIndex
                    ? text[text.index(before: range.lowerBound)] : nil
                if trigger.hasPrefix("查"), preceding == "检" { continue }
                if trigger == "联网", let p = preceding, lianwangNounPrefixes.contains(p) { continue }
                if trigger == "搜索", isSousuoNoun(text, after: range.upperBound) { continue }
                return true
            }
        }
        if let first = text.first, first == "搜" || (first == "查" && !hasTarget), text.count > 1,
           !leadingExclusions.contains(where: { text.hasPrefix($0) }),
           !(text.hasPrefix("搜索") && isSousuoNoun(text, after: text.index(text.startIndex, offsetBy: 2))) {
            return true
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return englishLeading.firstMatch(in: text, range: range) != nil
            || englishTrigger.firstMatch(in: text, range: range) != nil
    }

    private static func isSousuoNoun(_ text: String, after index: String.Index) -> Bool {
        sousuoNounSuffixes.contains { text[index...].hasPrefix($0) }
    }

    // MARK: 搜了没有

    /// 回包 `usage.server_tool_use.tool_search`：服务端真跑了几次搜索。字段缺失 / 不是数 → nil
    static func searchCount(in json: [String: Any]) -> Int? {
        guard let usage = json["usage"] as? [String: Any],
              let tools = usage["server_tool_use"] as? [String: Any] else { return nil }
        if let count = tools["tool_search"] as? Int { return count }
        if let count = tools["tool_search"] as? Double { return Int(count) }
        return nil
    }

    /// 这一条指令的回包之后该怎么办
    enum Decision: Equatable {
        /// 照常交付：要么真搜过了，要么用户压根没要求搜
        case accept
        /// 没搜、而用户明说了要查 → App 自己直接搜一次再作答
        case directSearch
    }

    /// 纯函数：`tool_search > 0` 才算搜了（缺失 = 0 = 没搜）
    static func decide(searchCount: Int?, instruction: String, hasTarget: Bool) -> Decision {
        if (searchCount ?? 0) > 0 { return .accept }
        return wantsSearch(instruction, hasTarget: hasTarget) ? .directSearch : .accept
    }

    // MARK: 日期

    /// 「今天是 2026 年 11 月 22 日，星期日」——设备时区里的今天（模型不知道今天几号，不给就编一个去搜）
    static func dateLine(now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = weekdays[((c.weekday ?? 1) - 1) % 7]
        return "今天是 \(c.year ?? 0) 年 \(c.month ?? 0) 月 \(c.day ?? 0) 日，星期\(weekday)"
    }

    /// 指令系统提示末尾那一行（只给 DeepSeek 的指令路径）
    static func commandDateSuffix(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        "\n" + dateLine(now: now, timeZone: timeZone) + "。"
    }

    static func dayText(_ date: Date, timeZone: TimeZone, omitYear: Int? = nil) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let md = "\(c.month ?? 0) 月 \(c.day ?? 0) 日"
        return c.year == omitYear ? md : "\(c.year ?? 0) 年 " + md
    }

    /// 「昨天是 11 月 21 日，今天是 11 月 22 日，明天是 …，后天是 …」：替模型把"哪一天"先算好
    static func relativeDaysLine(now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = calendar.component(.year, from: now)
        let names = [(-1, "昨天"), (0, "今天"), (1, "明天"), (2, "后天")]
        return names.map { offset, name in
            let day = calendar.date(byAdding: .day, value: offset, to: now) ?? now
            return "\(name)是 \(dayText(day, timeZone: timeZone, omitYear: year))"
        }.joined(separator: "，")
    }

    /// 结果的 `date`（RFC 3339，UTC）→ 用户时区里的发布日；认不出 → nil
    static func publishedDay(_ raw: String, timeZone: TimeZone) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: text) ?? fractional.date(from: text) {
            return dayText(date, timeZone: timeZone)
        }
        let dayOnly = DateFormatter()
        dayOnly.calendar = Calendar(identifier: .gregorian)
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = timeZone
        dayOnly.dateFormat = "yyyy-MM-dd"
        if text.count == 10, let date = dayOnly.date(from: text) { return dayText(date, timeZone: timeZone) }
        return nil
    }

    // MARK: 直接搜索（POST {base}/v1/tools/search）

    static let directSearchPath = "/v1/tools/search"
    /// 每次要几条结果
    static let directSearchCount = 8
    /// `query` / `ori_question` 各 1–128 字（端点的限制）
    static let directSearchFieldLimit = 128
    /// 实测约 0.5 秒返回，10 秒已经是"不会来了"
    static let directSearchTimeout: TimeInterval = 10

    /// 从指令里剥掉开头的"请帮我查一下"之类当搜索词（实测原句当搜索词搜回来的多是英文垃圾页）
    static let queryLeadIns = [
        "请", "麻烦你", "麻烦", "帮我", "帮忙", "给我",
        "联网搜索一下", "联网搜索", "联网搜一下", "联网搜", "联网查一下", "联网查",
        "上网查一下", "上网查", "上网搜一下", "上网搜", "网上查一下", "网上查", "网上搜一下", "网上搜",
        "搜索一下", "搜索", "搜一下", "搜一搜", "搜搜", "搜下",
        "查一下", "查一查", "查查", "查下", "查询一下", "查询",
        "搜", "查",
    ]
    /// 以 搜 / 查 开头的名字：单字动词不从它们身上剥
    static let queryKeepPrefixes = ["搜狐", "搜狗", "查理", "查尔斯", "查克", "查令"]
    private static let englishLeadIn = try! NSRegularExpression(
        pattern: #"^(please\s+|can\s+you\s+|could\s+you\s+|search\s+the\s+web\s+for\s+|search\s+online\s+for\s+|search\s+for\s+|search\s+|look\s+up\s+|google\s+for\s+|google\s+)"#,
        options: [.caseInsensitive])
    private static let leadingSeparators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "：:，,、。.！!？?"))

    /// 指令 → 搜索词：反复剥掉开头的请求词，截到 128 字。剥完什么都不剩就用原指令
    static func searchQuery(from instruction: String) -> String {
        let original = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = original
        var changed = true
        while changed {
            changed = false
            let trimmed = text.trimmingCharacters(in: leadingSeparators)
            if trimmed != text { text = trimmed; changed = true }
            if let leadIn = queryLeadIns.first(where: { text.hasPrefix($0) }),
               leadIn.count > 1 || !queryKeepPrefixes.contains(where: { text.hasPrefix($0) }) {
                if leadIn.count == text.count { text = ""; break }
                text.removeFirst(leadIn.count); changed = true; continue
            }
            let ns = text as NSString
            if let m = englishLeadIn.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
               m.range.length < ns.length {
                text = ns.substring(from: m.range.length); changed = true
            }
        }
        return clipped(text.isEmpty ? original : text)
    }

    static func clipped(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(directSearchFieldLimit))
    }

    /// 直接搜索的请求体 `{query, ori_question, count}`（iOS 中文版逐字同形）
    static func directSearchBody(query: String, question: String,
                                 count: Int = directSearchCount) -> [String: Any] {
        let q = clipped(query)
        let ori = clipped(question)
        return ["query": q.isEmpty ? ori : q, "ori_question": ori.isEmpty ? q : ori, "count": count]
    }

    /// 一条搜索结果（只取作答要用的字段）
    struct SearchResult: Equatable {
        var title: String = ""
        var url: String = ""
        var siteName: String = ""
        var date: String = ""
        var summary: String = ""
        var snippet: String = ""

        /// summary，没有就 snippet
        var text: String {
            let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? snippet.trimmingCharacters(in: .whitespacesAndNewlines) : s
        }
    }

    /// `{"results": [...]}` → 结果。nil = 形状不对；[] = 没结果。既没标题也没正文的条目跳过
    static func parseSearchResults(_ data: Data) -> [SearchResult]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = json["results"] as? [Any] else { return nil }
        return raw.compactMap { item in
            guard let o = item as? [String: Any] else { return nil }
            func str(_ key: String) -> String {
                ((o[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let hit = SearchResult(title: str("title"), url: str("url"), siteName: str("site_name"),
                                   date: str("date"), summary: str("summary"), snippet: str("snippet"))
            return hit.title.isEmpty && hit.text.isEmpty ? nil : hit
        }
    }

    /// 结果块的字数预算
    static let resultsCharBudget = 6000

    /// 编号结果块：「[n] 标题」「来源：站点 · 发布于 …」「内容：…」。**不带 URL**：
    /// 带网址的东西一个字都不该落进用户的输入框
    static func resultsBlock(_ results: [SearchResult], timeZone: TimeZone,
                             budget: Int = resultsCharBudget) -> String {
        var out = ""
        for (index, hit) in results.enumerated() {
            var meta: [String] = []
            if !hit.siteName.isEmpty { meta.append("来源：\(hit.siteName)") }
            meta.append(publishedDay(hit.date, timeZone: timeZone).map { "发布于 \($0)" } ?? "发布日期未知")
            var entry = "[\(index + 1)] \(hit.title.isEmpty ? "（无标题）" : hit.title)"
            entry += "\n" + meta.joined(separator: " · ")
            if !hit.text.isEmpty { entry += "\n内容：" + hit.text }
            let separator = out.isEmpty ? "" : "\n\n"
            let room = budget - out.count - separator.count
            if entry.count <= room {
                out += separator + entry
                continue
            }
            if room >= 200 { out += separator + String(entry.prefix(room - 1)) + "…" }
            break
        }
        return out
    }

    /// 兜底作答的系统提示（iOS 中文版 fallbackSystemPrompt 逐字照搬：那几条日期规则是实测踩出来的）
    static func fallbackSystemPrompt(results: [SearchResult], now: Date, timeZone: TimeZone,
                                     hasText: Bool = false) -> String {
        """
        你是联网搜索助手。\(dateLine(now: now, timeZone: timeZone))。\(relativeDaysLine(now: now, timeZone: timeZone))。下面是刚刚为用户的问题联网搜索到的结果。
        只依据这些搜索结果回答，不要用你自己的记忆补充。先按上面的日期确定用户问的是具体哪一天。
        日期规则：搜索结果正文里的「今天」「明天」「今夜」等，是相对那条结果自己的发布日期说的，不是相对今天；先按它的发布日期把它换算成具体日期，再和用户问的那一天比对，对得上才能用。发布日期未知的结果，其中的「今天」「明天」不能当作任何具体日期使用；只有正文明确写了具体日期（如「15 日」「11 月 15 日」）的内容才可用。
        如果没有任何一条结果能对上用户问的那一天，就回答能确定的最接近的信息并写明它是哪一天的，或者直接说没有查到；绝不能把别的日期的内容说成用户问的那一天。结果不足以回答时直接说没有查到相关信息，不要编造。
        回答会直接插入输入框：只输出答案的纯文本，用用户的语言，简洁；不要 Markdown 标记（不要 **、#、列表符号），不要任何链接、网址、引用标注或来源列表。
        """ + (hasText ? "\n用户消息里附有「待处理文字」：按指令结合搜索结果处理它。" : "")
            + "\n\n搜索结果：\n" + resultsBlock(results, timeZone: timeZone)
    }

    static let inputMarker = "\n\n待处理文字：\n"

    /// 兜底作答的两条消息（**不挂工具**）：系统提示 + 用户的原指令（有选区就附上那段字）
    static func fallbackMessages(instruction: String, input: String, results: [SearchResult],
                                 now: Date = Date(), timeZone: TimeZone = .current) -> [[String: String]] {
        let ask = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let withText = !text.isEmpty
        return [
            ["role": "system",
             "content": fallbackSystemPrompt(results: results, now: now, timeZone: timeZone, hasText: withText)],
            ["role": "user", "content": withText ? ask + inputMarker + input : ask],
        ]
    }

    /// 直接搜索的结果 → 悬浮窗「已联网 · N 来源」那几条来源（有网址的才算）
    static func citations(from results: [SearchResult]) -> [Citation] {
        var seen = Set<String>()
        return results.compactMap { hit in
            guard !hit.url.isEmpty, seen.insert(hit.url).inserted else { return nil }
            return Citation(title: hit.title, url: hit.url)
        }
    }
}
