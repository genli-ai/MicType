import Foundation
import Combine

// MARK: - 词汇提议（5.4.0，UX 方案 §3 E「个性化闭环」）

/// 润色每次都在替识别改同一个错（「嘉士奇」→「加湿器」）时，**提议**把它写进词汇表。
///
/// 铁律 P18（用户 2026-09-29 定）：**只提议，绝不静默学习**。所以这里只数数，
/// 一条都不自己往词汇表里写；提议只出现在设置状态卡下面那一行，点「加入」才写。
/// 不在悬浮窗里提（那是用户正在打字的地方），不弹窗。
///
/// 为什么要看"润色改了什么"而不是等用户自己发现：识别错的专名，润色大多能凭上下文改对，
/// 用户看到的是对的字——他永远不会知道识别那一层天天在错，直到哪天润色没改过来。
/// 写进词汇表之后，识别（OpenAI 的 keywords）与「错写=正写」硬替换两层都会兜住它。
enum VocabularySuggestions {

    /// 同一对出现几次才提议。1 次可能只是那一句的语境；3 次说明识别在这个词上稳定地错
    static let threshold = 3

    /// 一句话里比对的上限（字符数）。LCS 是 O(m·n) 的表，一段 10 分钟的口述 3000 字
    /// 就是九百万格；专名纠错在短句里一样看得到，长段落直接跳过
    static let maxAlignedLength = 600

    /// 词对在计数表里的键：「嘉士奇→加湿器」
    static func key(wrong: String, right: String) -> String {
        wrong + "\u{2192}" + right
    }

    static func split(key: String) -> (wrong: String, right: String)? {
        let parts = key.components(separatedBy: "\u{2192}")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// 从一句「识别原文 → 润色结果」里取出替换候选（纯函数，VocabularySuggestionsTests 钉住）。
    ///   • 中文：逐字 LCS 对齐后，长度 2–4、全是汉字、**逐字拼音相同**的替换对；
    ///     两段中间夹着 1 个没动的字（嘉士奇 → 加士器 这种只错两个字的）当作一个词看；
    ///     含代词助词（他们 → 它们）、只是繁转简（機器 → 机器）的不算。
    ///   • 拉丁：按空格切词、逐词 LCS 对齐后一词换一词，两边都是 ≥ 3 个字母，小写后仍不同
    ///     （只差大小写不算），且拼写相近（编辑距离 ≤ 长词的一半）——
    ///     "use → utilize" 这种换词是润色的文风，不是识别错了。
    ///   • 阿语不做：原文或润色里出现阿拉伯字母就返回空。
    /// - vocabulary: 当前词汇表原文。错写已经在里面、或正写已经是词条的，不再提议
    static func candidates(raw: String, polished: String,
                           vocabulary: String = "") -> [(wrong: String, right: String)] {
        guard raw != polished, !raw.isEmpty, !polished.isEmpty else { return [] }
        guard !containsArabic(raw), !containsArabic(polished) else { return [] }
        var found: [(wrong: String, right: String)] = []
        func add(_ pair: (wrong: String, right: String)) {
            guard !found.contains(where: { $0.wrong == pair.wrong && $0.right == pair.right }) else { return }
            found.append(pair)
        }
        hanCandidates(raw: raw, polished: polished).forEach(add)
        latinCandidates(raw: raw, polished: polished).forEach(add)
        return found.filter { !alreadyInVocabulary($0, vocabulary: vocabulary) }
    }

    /// 已经在词汇表里：错写已经是某条的错写，或正写已经是词条 / 某条的正写（不区分大小写）
    static func alreadyInVocabulary(_ pair: (wrong: String, right: String), vocabulary: String) -> Bool {
        let parsed = Settings.parseVocabulary(vocabulary)
        let wrong = pair.wrong.lowercased(), right = pair.right.lowercased()
        if parsed.replacements.contains(where: { $0.wrong.lowercased() == wrong }) { return true }
        return parsed.terms.contains { $0.lowercased() == right }
    }

    // MARK: 中文

    static func hanCandidates(raw: String, polished: String) -> [(wrong: String, right: String)] {
        let a = Array(raw), b = Array(polished)
        guard a.count <= maxAlignedLength, b.count <= maxAlignedLength else { return [] }
        let blocks = mergedBlocks(diff(a, b, equal: ==), a: a, b: b)
        var out: [(wrong: String, right: String)] = []
        for block in blocks {
            let wrong = Array(block.wrong), right = Array(block.right)
            guard wrong.count == right.count, (2...4).contains(wrong.count), wrong != right,
                  wrong.allSatisfy(PolishFidelity.isHan), right.allSatisfy(PolishFidelity.isHan),
                  !wrong.contains(where: PolishFidelity.nonNameChars.contains),
                  !right.contains(where: PolishFidelity.nonNameChars.contains) else { continue }
            let w = String(wrong), r = String(right)
            // 繁转简不是识别错了（拼音当然一样）
            guard PolishFidelity.simplified(w) != r else { continue }
            let wp = wrong.map(PolishFidelity.pinyin), rp = right.map(PolishFidelity.pinyin)
            guard !wp.contains(nil), wp == rp else { continue }
            out.append((w, r))
        }
        return out
    }

    /// 对齐之后的一段：两边各拿出来的字（相同段两边一样）
    struct Block: Equatable {
        var wrong: String
        var right: String
        var changed: Bool
    }

    /// 把 diff 的逐元素结果收成段，再把「改 · 1 个没动的字 · 改」并成一段：
    /// 嘉士奇 → 加士器 在 LCS 里是「嘉→加」「士」「奇→器」三段，各自只有 1 个字，
    /// 不并起来就永远凑不到 2 字的下限
    static func mergedBlocks<T>(_ ops: [DiffOp], a: [T], b: [T],
                                join: ([T]) -> String = { $0.map { "\($0)" }.joined() }) -> [Block] {
        var blocks: [Block] = []
        var ra: [T] = [], rb: [T] = [], eq: [T] = []
        func flushChange() {
            guard !ra.isEmpty || !rb.isEmpty else { return }
            blocks.append(Block(wrong: join(ra), right: join(rb), changed: true))
            ra = []; rb = []
        }
        func flushEqual() {
            guard !eq.isEmpty else { return }
            blocks.append(Block(wrong: join(eq), right: join(eq), changed: false))
            eq = []
        }
        for op in ops {
            switch op {
            case .equal(let i, _):
                flushChange()
                eq.append(a[i])
            case .delete(let i):
                flushEqual()
                ra.append(a[i])
            case .insert(let j):
                flushEqual()
                rb.append(b[j])
            }
        }
        flushChange()
        flushEqual()
        // 改 · 单个相同 · 改 → 一段
        var merged: [Block] = []
        var index = 0
        while index < blocks.count {
            var current = blocks[index]
            while current.changed, index + 2 < blocks.count,
                  !blocks[index + 1].changed, blocks[index + 1].wrong.count == 1,
                  blocks[index + 2].changed {
                current.wrong += blocks[index + 1].wrong + blocks[index + 2].wrong
                current.right += blocks[index + 1].right + blocks[index + 2].right
                index += 2
            }
            merged.append(current)
            index += 1
        }
        return merged
    }

    // MARK: 拉丁

    static func latinCandidates(raw: String, polished: String) -> [(wrong: String, right: String)] {
        let a = latinTokens(raw), b = latinTokens(polished)
        guard !a.isEmpty, !b.isEmpty, a.count <= maxAlignedLength, b.count <= maxAlignedLength else {
            return []
        }
        // 对齐时不分大小写：pyton → Python 要对成"一词换一词"，python → Python 要对成"没变"
        let ops = diff(a, b) { $0.lowercased() == $1.lowercased() }
        let blocks = mergedWordBlocks(ops, a: a, b: b)
        var out: [(wrong: String, right: String)] = []
        for (wrong, right) in blocks {
            guard wrong.count >= 3, right.count >= 3,
                  isLatinWord(wrong), isLatinWord(right),
                  wrong.lowercased() != right.lowercased() else { continue }
            let distance = editDistance(Array(wrong.lowercased()), Array(right.lowercased()))
            guard distance <= max(wrong.count, right.count) / 2 else { continue }
            out.append((wrong, right))
        }
        return out
    }

    /// 只收"一个词换一个词"的段（多词对多词是润色在改句子，不是识别错了一个词）
    private static func mergedWordBlocks(_ ops: [DiffOp], a: [String], b: [String]) -> [(String, String)] {
        var out: [(String, String)] = []
        var ra: [String] = [], rb: [String] = []
        func flush() {
            if ra.count == 1, rb.count == 1 { out.append((ra[0], rb[0])) }
            ra = []; rb = []
        }
        for op in ops {
            switch op {
            case .equal: flush()
            case .delete(let i): ra.append(a[i])
            case .insert(let j): rb.append(b[j])
            }
        }
        flush()
        return out
    }

    /// 按空白切词，剥掉词两头的标点（"Python," → "Python"）
    static func latinTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    static func isLatinWord(_ word: String) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0)
        }
    }

    static func containsArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value)
                || (0x08A0...0x08FF).contains($0.value) || (0xFB50...0xFDFF).contains($0.value)
                || (0xFE70...0xFEFF).contains($0.value)
        }
    }

    // MARK: 对齐（LCS）

    enum DiffOp: Equatable {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// 经典 LCS 回溯。同长度时先出删除再出插入，于是"一段替换"总是先报原文那边——
    /// 收段时两边各自攒着，顺序不影响结果，只影响读日志的人
    static func diff<T>(_ a: [T], _ b: [T], equal: (T, T) -> Bool) -> [DiffOp] {
        let m = a.count, n = b.count
        var table = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0 && n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    table[i][j] = equal(a[i], b[j]) ? table[i + 1][j + 1] + 1
                                                    : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var ops: [DiffOp] = []
        var i = 0, j = 0
        while i < m && j < n {
            if equal(a[i], b[j]) {
                ops.append(.equal(i, j)); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append(.delete(i)); i += 1
            } else {
                ops.append(.insert(j)); j += 1
            }
        }
        while i < m { ops.append(.delete(i)); i += 1 }
        while j < n { ops.append(.insert(j)); j += 1 }
        return ops
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1]
                                                  : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: 词汇表追加

    /// 往词汇表原文末尾追加一行「错写=正写」（走现有解析格式，Settings.parseVocabulary）。
    /// 原文末尾已经是分隔符就不再多补一个换行
    static func appending(_ pair: (wrong: String, right: String), to vocabulary: String) -> String {
        let line = pair.wrong + "=" + pair.right
        let trimmed = vocabulary.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return line }
        if let last = vocabulary.unicodeScalars.last, Settings.listSeparators.contains(last) {
            return vocabulary + line
        }
        return vocabulary + "\n" + line
    }
}

// MARK: - 计数表（suggestions.json）

/// 落盘的样子。**只有词对，一个句子都没有**。
struct VocabularySuggestionLedger: Codable, Equatable {
    /// 「嘉士奇→加湿器」: 3
    var counts: [String: Int] = [:]
    /// 点过「忽略」的词对：永不再提
    var ignored: [String] = []
    /// 某一对第一次到达阈值的时间（同票时先到的先提）
    var suggestedAt: [String: Date] = [:]

    init() {}

    /// 三个字段缺哪个都当空的读（手改过、或者以后加字段时旧文件也读得回来）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counts = try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        ignored = try c.decodeIfPresent([String].self, forKey: .ignored) ?? []
        suggestedAt = try c.decodeIfPresent([String: Date].self, forKey: .suggestedAt) ?? [:]
    }

    /// 记一句里出现的词对（同一句里同一对只算一次）
    mutating func observe(_ pairs: [(wrong: String, right: String)], now: Date = Date()) {
        var seen = Set<String>()
        for pair in pairs {
            let key = VocabularySuggestions.key(wrong: pair.wrong, right: pair.right)
            guard !ignored.contains(key), seen.insert(key).inserted else { continue }
            let next = (counts[key] ?? 0) + 1
            counts[key] = next
            if next >= VocabularySuggestions.threshold, suggestedAt[key] == nil {
                suggestedAt[key] = now
            }
        }
    }

    /// 现在该提的那一条：到了阈值、没被忽略、不在当前词汇表里；计数最高的，同票先到的先提
    func pending(vocabulary: String) -> (wrong: String, right: String)? {
        let ready = counts
            .filter { $0.value >= VocabularySuggestions.threshold && !ignored.contains($0.key) }
            .compactMap { entry -> (key: String, count: Int, pair: (wrong: String, right: String))? in
                guard let pair = VocabularySuggestions.split(key: entry.key),
                      !VocabularySuggestions.alreadyInVocabulary(pair, vocabulary: vocabulary) else { return nil }
                return (entry.key, entry.value, pair)
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                let l = suggestedAt[lhs.key] ?? .distantFuture, r = suggestedAt[rhs.key] ?? .distantFuture
                if l != r { return l < r }
                return lhs.key < rhs.key
            }
        return ready.first?.pair
    }

    /// 撤回一句的票（同一句里同一对只撤一次）：减 1、不低于 0，降到阈值以下就不再算「待提议」
    mutating func retract(_ pairs: [(wrong: String, right: String)]) {
        var seen = Set<String>()
        for pair in pairs {
            let key = VocabularySuggestions.key(wrong: pair.wrong, right: pair.right)
            guard seen.insert(key).inserted, let count = counts[key] else { continue }
            let next = max(0, count - 1)
            counts[key] = next == 0 ? nil : next
            if next < VocabularySuggestions.threshold { suggestedAt[key] = nil }
        }
    }

    /// 加进词汇表之后：计数清掉（它已经不需要被数了）
    mutating func accept(_ pair: (wrong: String, right: String)) {
        let key = VocabularySuggestions.key(wrong: pair.wrong, right: pair.right)
        counts[key] = nil
        suggestedAt[key] = nil
    }

    /// 忽略：进 ignored，计数一并清掉，永不再提
    mutating func ignore(_ pair: (wrong: String, right: String)) {
        let key = VocabularySuggestions.key(wrong: pair.wrong, right: pair.right)
        counts[key] = nil
        suggestedAt[key] = nil
        if !ignored.contains(key) { ignored.append(key) }
    }
}

/// `~/Library/Application Support/MicType/suggestions.json` 的读写 + 设置页订阅的那一份状态。
final class VocabularySuggestionStore: ObservableObject {
    static let shared = VocabularySuggestionStore()

    let fileURL: URL
    @Published private(set) var ledger: VocabularySuggestionLedger

    /// 比对（LCS + 拼音）放后台：交付路径上主线程一毫秒都不该浪费
    private let workQueue = DispatchQueue(label: "com.mictype.suggestions", qos: .utility)

    init(fileURL: URL = VocabularySuggestionStore.defaultFileURL) {
        self.fileURL = fileURL
        ledger = Self.load(from: fileURL)
    }

    static var defaultFileURL: URL {
        if Log.isUnderTest {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("MicTypeTestSuggestions", isDirectory: true)
                .appendingPathComponent("suggestions.json")
        }
        return Paths.appSupportDir.appendingPathComponent("suggestions.json")
    }

    /// 润色交付成功那一处调（主线程）。只数词对，**不记句子**，日志只记个数。
    /// **同步算**：返回的词对要挂到「换回原文」的记忆上（用户换回 = 这一句的改动不算数，见 retract）。
    /// 比对有 600 字的上限（maxAlignedLength），36 万格的 LCS 在主线程上是毫秒级；落盘仍在后台
    @discardableResult
    func observe(raw: String, polished: String) -> [(wrong: String, right: String)] {
        let pairs = VocabularySuggestions.candidates(raw: raw, polished: polished,
                                                     vocabulary: Settings.shared.customVocabulary)
        guard !pairs.isEmpty else { return [] }
        observeNow(pairs)
        Log.info("Vocab suggestion candidates=\(pairs.count)")
        return pairs
    }

    /// 用户把这一句换回了原文：它贡献的那几票撤回（润色改错了，不该拿来当"识别总在错"的证据）
    func retract(_ pairs: [(wrong: String, right: String)]) {
        guard !pairs.isEmpty else { return }
        var next = ledger
        next.retract(pairs)
        commit(next)
        Log.info("Vocab suggestion retracted=\(pairs.count)")
    }

    /// 同步版（单测用：不经过后台队列）
    func observeNow(_ pairs: [(wrong: String, right: String)], now: Date = Date()) {
        var next = ledger
        next.observe(pairs, now: now)
        commit(next)
    }

    func pending(vocabulary: String) -> (wrong: String, right: String)? {
        ledger.pending(vocabulary: vocabulary)
    }

    /// 「加入」：词汇表末尾追加一行「错写=正写」，计数清掉
    func accept(_ pair: (wrong: String, right: String)) {
        let settings = Settings.shared
        settings.customVocabulary = VocabularySuggestions.appending(pair, to: settings.customVocabulary)
        var next = ledger
        next.accept(pair)
        commit(next)
        Log.info("Vocab suggestion accepted")
    }

    /// 「忽略」：永不再提
    func ignore(_ pair: (wrong: String, right: String)) {
        var next = ledger
        next.ignore(pair)
        commit(next)
        Log.info("Vocab suggestion ignored")
    }

    /// 清空（只给快照 / 单测用）
    func resetForTesting(_ ledger: VocabularySuggestionLedger = VocabularySuggestionLedger()) {
        self.ledger = ledger
        workQueue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// 等后台写完（只给单测用）
    func waitForPendingWrites() {
        workQueue.sync { }
    }

    private func commit(_ next: VocabularySuggestionLedger) {
        ledger = next
        let url = fileURL
        workQueue.async {
            do {
                try Self.save(next, to: url)
            } catch {
                // 记不进去绝不打断听写：只留一行不含内容的 WARN
                Log.warn("Suggestions save failed: \(error.localizedDescription)")
            }
        }
    }

    static func save(_ ledger: VocabularySuggestionLedger, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(ledger).write(to: url, options: .atomic)
    }

    /// 读不出来（没有文件 / 手改坏了）就当一张空表：少几次计数，好过设置页打不开
    static func load(from url: URL) -> VocabularySuggestionLedger {
        guard let data = try? Data(contentsOf: url) else { return VocabularySuggestionLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(VocabularySuggestionLedger.self, from: data)) ?? VocabularySuggestionLedger()
    }
}
