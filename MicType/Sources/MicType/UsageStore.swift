import Foundation
import Combine

// MARK: - 本周用量（设置状态卡右半边，5.3.0）

/// 一句话交付完的那一刻记一行：什么时候、录了几秒、最后打出多少字、是不是指令。
/// **只有这四样，一个字的内容都没有**——和 Metrics 同一条纪律。
struct UsageEntry: Codable, Equatable {
    let date: Date
    /// 这一句的录音时长（秒）。识别按它计费
    let seconds: Double
    /// 交付出去的字数（不数空白，与悬浮窗上的字数计数同一把尺子：OverlayCopy.countCharacters）
    let chars: Int
    /// 按住说的指令（true）还是轻点听写（false）
    let command: Bool
    /// 5.4.0：这一行不是一句话，而是一次「换回原文」（悬浮窗「原文 → 润色」那一行被点了、
    /// 原文真的贴回去了）。这种行 seconds / chars 都是 0，**不算进分钟 / 字数 / 句数 / 费用**，
    /// 只给「写作偏好」那一行数"本周换回原文 N 次"。旧账本没有这个字段，读作 false。
    var revert: Bool = false

    init(date: Date, seconds: Double, chars: Int, command: Bool, revert: Bool = false) {
        self.date = date
        self.seconds = seconds
        self.chars = chars
        self.command = command
        self.revert = revert
    }

    private enum CodingKeys: String, CodingKey {
        case date, seconds, chars, command, revert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        seconds = try c.decode(Double.self, forKey: .seconds)
        chars = try c.decode(Int.self, forKey: .chars)
        command = try c.decode(Bool.self, forKey: .command)
        // 5.3.0 写的行没有这个字段
        revert = try c.decodeIfPresent(Bool.self, forKey: .revert) ?? false
    }

    /// revert 只在为真时写：普通的一句话仍然只有四样（UsageStoreTests 钉着"只有这四个键"），
    /// 账本不为一个几乎总是 false 的字段每行多背十几个字节
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(seconds, forKey: .seconds)
        try c.encode(chars, forKey: .chars)
        try c.encode(command, forKey: .command)
        if revert { try c.encode(true, forKey: .revert) }
    }
}

/// 汇总哪一周：本周（设置状态卡）或上周（每周第一次启动闪的那一句）
enum UsageWeekSpan {
    case current
    case previous
}

/// 设置状态卡上那三格：分钟 / 字数 / 约多少美元
struct UsageWeek: Equatable {
    let seconds: Double
    let chars: Int
    let sentences: Int
    let costUSD: Double
    /// 这周点了几次「换回原文」（不是句子，不进上面四个数）
    var reverts: Int = 0

    static let empty = UsageWeek(seconds: 0, chars: 0, sentences: 0, costUSD: 0)

    /// 这周一句都还没说过 → 三格都显示「—」（显示 0 分钟 / 0 字 / $0 像是在报一个坏消息）
    var isEmpty: Bool { sentences == 0 }
}

/// 本机用量账本：`~/Library/Application Support/MicType/usage.jsonl`，一句一行，**永不上传**。
///
/// 为什么单独记一份而不是读 Metrics / 历史：
///   • Metrics 只留最近 30 轮（它是给排障看的中位数，不是账本）；
///   • 听写历史可以被用户关掉（「保存听写历史」），而且里面是原文——
///     为了数字去读用户说过的话，是把一件隐私上干净的事做脏了。
/// 所以用量自己一份：只有数字，按行追加，读的时候只关心最近这一周。
///
/// 设置窗口要的是"这周说了多少、花了多少"（UX 方案 §3 D，用户 2026-09-29 拍板显示费用估算）。
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    /// 落盘位置。跑在 XCTest 里时写到临时目录（Log.isUnderTest）：单测绝不碰用户真实的账本
    let fileURL: URL

    /// 最近这段时间的记录（只装往前 15 天的，够算本周与上周，又不会把一年的账都读进内存）
    @Published private(set) var recent: [UsageEntry] = []

    private let ioQueue = DispatchQueue(label: "com.mictype.usage.io", qos: .utility)

    init(fileURL: URL = UsageStore.defaultFileURL) {
        self.fileURL = fileURL
        recent = Self.load(from: fileURL, since: Self.loadCutoff(now: Date()))
    }

    static var defaultFileURL: URL {
        if Log.isUnderTest {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("MicTypeTestUsage", isDirectory: true)
                .appendingPathComponent("usage.jsonl")
        }
        return Paths.appSupportDir.appendingPathComponent("usage.jsonl")
    }

    // MARK: 写

    /// 记一句（**只在主线程调**：DictationController 交付成功那一处）。
    /// 文件追加放后台队列——交付路径上主线程一毫秒都不该浪费。
    func record(seconds: Double, chars: Int, command: Bool, date: Date = Date()) {
        append(UsageEntry(date: date, seconds: max(0, seconds), chars: max(0, chars), command: command))
    }

    /// 记一次「换回原文」（5.4.0，只在主线程调：revertToRaw 贴回原文成功那一处）
    func recordRevert(date: Date = Date()) {
        append(UsageEntry(date: date, seconds: 0, chars: 0, command: false, revert: true))
    }

    private func append(_ entry: UsageEntry) {
        recent.append(entry)
        guard let line = Self.encode(entry) else { return }
        let url = fileURL
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let data = Data((line + "\n").utf8)
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url)
                }
            } catch {
                // 记不进去绝不能打断听写：只留一行不含内容的 WARN
                Log.warn("Usage append failed: \(error.localizedDescription)")
            }
        }
    }

    /// 等后台队列把排队的写入做完（只给单测用）
    func waitForPendingWrites() {
        ioQueue.sync { }
    }

    /// 清空内存与文件（只给快照 / 单测用：它们要摆"有数据 / 没数据"两种状态）
    func resetForTesting(_ entries: [UsageEntry] = []) {
        ioQueue.sync { try? FileManager.default.removeItem(at: fileURL) }
        recent = entries
    }

    /// 本周这一刻的三格
    func thisWeek(now: Date = Date()) -> UsageWeek {
        Self.summarize(recent, now: now)
    }

    // MARK: 纯函数（UsageStoreTests 钉住）

    /// 周一 00:00（本地时区）。**ISO 周**：一周从周一开始，不跟系统"每周第一天"的设置走——
    /// 设置页那一格写着「本周」，用户心里的本周就是周一到周日（UAE 的工作周另说，那不是这一格要讲的事）
    static func weekStart(for date: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }

    /// 本周（周一起）的合计
    static func summarize(_ entries: [UsageEntry], now: Date, timeZone: TimeZone = .current) -> UsageWeek {
        summarize(entries, now: now, week: .current, timeZone: timeZone)
    }

    /// 某一周的合计。
    ///   • 本周 = 周一 00:00 到**这一刻**（未来时间不算：时钟被调过的那几行别混进来）；
    ///   • 上周 = 上周一 00:00 到本周一 00:00（不含）。
    /// 「换回原文」那几行只进 reverts，不进分钟 / 字数 / 句数 / 费用——它不是一次新的说话
    static func summarize(_ entries: [UsageEntry], now: Date, week span: UsageWeekSpan,
                          timeZone: TimeZone = .current) -> UsageWeek {
        let thisStart = weekStart(for: now, timeZone: timeZone)
        let range: (Date, Date, Bool)   // 起、止、止是否包含
        switch span {
        case .current:
            range = (thisStart, now, true)
        case .previous:
            let previousStart = weekStart(for: thisStart.addingTimeInterval(-3600), timeZone: timeZone)
            range = (previousStart, thisStart, false)
        }
        let inWeek = entries.filter {
            $0.date >= range.0 && (range.2 ? $0.date <= range.1 : $0.date < range.1)
        }
        let spoken = inWeek.filter { !$0.revert }
        let seconds = spoken.reduce(0) { $0 + $1.seconds }
        let chars = spoken.reduce(0) { $0 + $1.chars }
        return UsageWeek(seconds: seconds, chars: chars, sentences: spoken.count,
                         costUSD: estimatedCostUSD(seconds: seconds, sentences: spoken.count),
                         reverts: inWeek.count - spoken.count)
    }

    /// 上周这一刻看来的合计（每周第一次启动那一句用）
    func previousWeek(now: Date = Date()) -> UsageWeek {
        Self.summarize(recent, now: now, week: .previous)
    }

    /// **估算**的费用（美元）：识别按秒 + 每句一次润色。
    ///
    /// 单价全部来自 LLMCatalog（全 App 唯一的价格出处）：
    ///   • 识别 = 实时 $0.017/分钟 + 整段再传 $0.0045/分钟（asrHourlyUSD，官方价目页查过）；
    ///   • 润色 = polishHourlyUSD / sentencesPerHour，**本身就是估算**（见 LLMCatalog 那段注释）。
    /// 指令那一句按润色的单价算——它比润色贵（联网搜索、输出更长），所以这个数偏低，
    /// 界面上一律写「约」。绝不许把它说成账单。
    static func estimatedCostUSD(seconds: Double, sentences: Int) -> Double {
        let asrPerSecond = LLMCatalog.asrHourlyUSD(provider: .openai) / 3600
        let polishPerSentence = LLMCatalog.polishHourlyUSD(provider: .openai) / LLMCatalog.sentencesPerHour
        return max(0, seconds) * asrPerSecond + Double(max(0, sentences)) * polishPerSentence
    }

    /// 一行 JSON（ISO8601 时间）。nil = 编码失败（不会发生，但绝不为它崩）
    static func encode(_ entry: UsageEntry) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 读一行。坏行（半截写入、手改坏了）直接跳过——账本少一句，好过设置页打不开
    static func decode(_ line: String) -> UsageEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageEntry.self, from: Data(trimmed.utf8))
    }

    /// 启动时只装这一刻往前 15 天的：5.4.0 起还要算**上周**（周日晚上启动时，上周一在 13 天前），
    /// 多一天给时区与周一零点留余量。再早的账不进内存
    static func loadCutoff(now: Date) -> Date {
        now.addingTimeInterval(-15 * 24 * 3600)
    }

    static func load(from url: URL, since cutoff: Date) -> [UsageEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { decode(String($0)) }.filter { $0.date >= cutoff }
    }
}

// MARK: - 三格怎么写（纯函数）

enum UsageFormat {
    /// 没数据时三格都是这一个符号
    static let placeholder = "—"

    /// 「43 分钟」/「43 min」。说过但不满半分钟的写 1：写 0 等于说"你这周什么都没说"
    static func minutes(_ week: UsageWeek) -> String {
        guard !week.isEmpty else { return placeholder }
        let minutes = max(1, Int((week.seconds / 60).rounded()))
        return tr("\(minutes) 分钟", "\(minutes) min")
    }

    /// 「6,200 字」/「6,200 chars」。千分位跟着界面语言走（不跟系统区域：那一格和旁边的字要是同一种语言）
    static func chars(_ week: UsageWeek) -> String {
        guard !week.isEmpty else { return placeholder }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        let text = formatter.string(from: NSNumber(value: week.chars)) ?? "\(week.chars)"
        return tr("\(text) 字", "\(text) chars")
    }

    /// 「约 $0.12」/「~$0.12」。不到一美分写「< $0.01」：「约 $0.00」读起来像是免费
    static func cost(_ week: UsageWeek) -> String {
        guard !week.isEmpty else { return placeholder }
        guard week.costUSD >= 0.005 else { return "< $0.01" }
        let text = String(format: "$%.2f", week.costUSD)
        return tr("约 \(text)", "~\(text)")
    }
}
