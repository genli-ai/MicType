import Foundation
import Combine

// MARK: - 一次会话的耗时快照

/// 一轮听写/指令各阶段的耗时（P20 性能指标）。
/// 纪律：**只记数字，绝不记任何文本**——这些行会原样出现在「复制诊断信息」里，
/// 用户会把那段文字贴进邮件或 issue，里面就不能有他说过的话。
struct SessionMetric: Codable, Equatable {

    /// 这一轮是轻点（纯听写）还是按住（指令）。两种手势的耗时构成完全不同，
    /// 混在一起算中位数会让"识别慢"和"指令模型慢"互相掩盖。
    enum Mode: String, Codable {
        case dictation
        case command
    }

    let date: Date
    let mode: Mode
    let asrMs: Int
    /// 大模型那一段往返的耗时：轻点是润色，按住是指令模型（两种手势的等待都压在这一段上，
    /// 所以共用一格，是哪一种看 mode）。
    /// nil = 这一轮压根没走大模型（档位关着 / 没配 Key / 纯识别）。
    /// 记成 0 会把中位数拉垮，所以"没发生"必须和"耗时 0"分开。
    let polishMs: Int?
    let insertMs: Int
    let audioSeconds: Double
    let partialCount: Int
    let cold: Bool
    /// 这一轮大模型请求命中的 prompt 缓存 token 数（Responses 的 usage.input_tokens_details.cached_tokens）。
    /// nil = 没走大模型，或这个端点压根不报缓存。**恒为 0 就说明前缀不到 1024 token，
    /// 那就如实显示 0，绝不为了折扣把提示词灌水**。
    let cachedTokens: Int?
    /// 服务商**实际**给这一趟用的档位（响应里的 service_tier）。勾了 Fast 也可能被降回 default，
    /// 不回显的话用户只会以为"多付的钱买到了低延迟"。nil = 没走大模型或端点不报这个字段。
    let serviceTier: String?

    /// 显式写出来（而不是用编译器合成的逐成员构造器）：cachedTokens / serviceTier 是 v4.0 才加的字段，
    /// 给它们默认值，老的调用点与单测不必为诊断字段全部改签名。
    init(date: Date, mode: Mode, asrMs: Int, polishMs: Int?, insertMs: Int,
         audioSeconds: Double, partialCount: Int, cold: Bool, cachedTokens: Int? = nil,
         serviceTier: String? = nil) {
        self.date = date
        self.mode = mode
        self.asrMs = asrMs
        self.polishMs = polishMs
        self.insertMs = insertMs
        self.audioSeconds = audioSeconds
        self.partialCount = partialCount
        self.cold = cold
        self.cachedTokens = cachedTokens
        self.serviceTier = serviceTier
    }
}

// MARK: - 大模型用量的沉淀点

/// 一次大模型往返顺带回来的东西：缓存命中、实际档位、联网来源。
struct LLMUsage: Equatable {
    var cachedTokens: Int?
    var serviceTier: String?
    /// 联网搜索的来源。只有开着搜索开关的指令调用才可能非空。
    var citations: [Citation] = []
}

/// 最近一次大模型往返的用量沉淀点。
/// 为什么用一个"取走即清空"的沉淀点，而不是把 usage 顺着回调传回去：这些东西要穿过
/// PolishService 与三条技能路共用的 (String?, String?) 回调——为它们改四处签名不值当。
/// take() 取走即清空，保证上一轮的数字不会被记到下一轮头上；只在主线程读写
/// （LLMClient 在主线程回调前写，DictationController 在回调里读）。
final class LLMUsageSink {
    static let shared = LLMUsageSink()
    private var usage: LLMUsage?

    func record(_ usage: LLMUsage) {
        self.usage = usage
    }

    /// 取走并清空
    func take() -> LLMUsage? {
        defer { usage = nil }
        return usage
    }
}

/// 一轮进行中的草稿：各阶段算完填一格，投递完成时 finished() 封口成 SessionMetric。
/// 录音结束时就能定下的字段（时长、预览遍数、冷启动）用 let，后面各阶段填的用 var。
struct SessionMetricDraft {
    let mode: SessionMetric.Mode
    let audioSeconds: Double
    let partialCount: Int
    let cold: Bool
    var asrMs: Int = 0
    /// 大模型往返（润色 or 指令）。指令那三条路各自要在回调里填它，
    /// 不填的话按住手势提交的行里最慢的那一段是空的——排障时等于什么都没记。
    var polishMs: Int?
    /// 这一轮的 prompt 缓存命中（从 LLMUsageSink 取走），没走大模型时保持 nil
    var cachedTokens: Int?
    /// 这一轮服务商实际用的档位（同上）
    var serviceTier: String?

    /// 把沉淀点里的用量收进这一轮。nil（没走大模型 / 端点什么都不报）时一个字段都不动——
    /// "没发生"和"值为 0"在这张表里一直是两回事。
    mutating func absorb(_ usage: LLMUsage?) {
        guard let usage = usage else { return }
        cachedTokens = usage.cachedTokens
        serviceTier = usage.serviceTier
    }

    func finished(insertMs: Int) -> SessionMetric {
        SessionMetric(date: Date(), mode: mode, asrMs: asrMs, polishMs: polishMs,
                      insertMs: insertMs, audioSeconds: audioSeconds,
                      partialCount: partialCount, cold: cold, cachedTokens: cachedTokens,
                      serviceTier: serviceTier)
    }
}

// MARK: - 最近 30 轮的环形缓冲

/// 最近 30 轮的耗时，存在 UserDefaults 里（一行几十字节，整份不过几 KB）。
/// 为什么不像历史那样进 JSON 文件：这里存的是纯数字、量恒定，且设置界面每次打开就要读，
/// 放偏好域里最省事；也不必担心隐私——里面没有一个字是用户说的。
/// 只在主线程读写（所有计时点都在主线程回调里）。
final class Metrics: ObservableObject {

    static let shared = Metrics()
    /// 留 30 轮：够算最近 10 次的中位数，也够看出"今天是不是突然变慢了"
    static let maxCount = 30

    private let key = "sessionMetrics"
    private let d = UserDefaults.standard

    /// 新的在前
    @Published private(set) var items: [SessionMetric] = []

    private init() {
        if let data = d.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SessionMetric].self, from: data) {
            items = Array(decoded.prefix(Self.maxCount))
        }
    }

    func record(_ metric: SessionMetric) {
        items.insert(metric, at: 0)
        if items.count > Self.maxCount {
            items = Array(items.prefix(Self.maxCount))
        }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        d.set(data, forKey: key)
    }
}

// MARK: - 统计与格式化（纯函数，单测钉在 MetricsTests）

extension Metrics {

    /// 最近若干轮的中位数摘要
    struct Digest: Equatable {
        /// 实际参与统计的轮数（不足 count 时如实报，别骗用户说"最近 10 次"）
        let sampleCount: Int
        let asrMs: Int
        /// 这批里一次大模型往返都没有 → nil，界面上那一段就不显示
        let polishMs: Int?
        /// 真正参与这一段中位数的轮数。关着润色、没配 Key、纯识别的轮次一格都不填，
        /// 所以它可能远小于 sampleCount——拿一个"最近 10 次"盖住三段数字就是在骗人：
        /// 10 轮里只有 1 轮走过大模型时，那一次网络抽风会被当成"最近 10 次的中位数"摆出来，
        /// 而中位数本来就是为了挡掉这种离群值才选的。
        let polishSampleCount: Int
        let insertMs: Int
    }

    /// 取最近 count 轮算中位数。一轮都没有返回 nil（界面改显示"还没有记录"）。
    static func digest(_ items: [SessionMetric], count: Int = 10) -> Digest? {
        let recent = Array(items.prefix(count))
        guard let asr = median(recent.map(\.asrMs)),
              let insert = median(recent.map(\.insertMs)) else { return nil }
        let polishValues = recent.compactMap(\.polishMs)
        return Digest(sampleCount: recent.count,
                      asrMs: asr,
                      polishMs: median(polishValues),
                      polishSampleCount: polishValues.count,
                      insertMs: insert)
    }

    /// 中位数（偶数个取中间两个的整数平均）。
    /// 用中位数不用均值：样本只有十来个，一次冷启动（识别慢五六倍）就能把均值拉到完全没有
    /// 参考价值的地方，而用户想知道的是"平常多快"。
    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// 毫秒的人话写法：1 秒以内按整毫秒（"320 ms"），到秒就保留一位小数（"1.8 s"）。
    /// 单位 ms / s 中英通用，所以这是一条不含 tr() 的纯函数，单测能直接钉死。
    static func formatMs(_ ms: Int) -> String {
        guard ms >= 1000 else { return "\(ms) ms" }
        return String(format: "%.1f s", Double(ms) / 1000)
    }

    /// 设置页里那一行：「识别 320 ms · 模型 1.8 s（3 次）· 插入 90 ms（最近 10 次中位数）」。
    /// 模型那一段自带次数：识别和插入每轮都有，它却只有真的走过大模型的那几轮，
    /// 两个样本量不一样，不能让句尾那个"最近 N 次"替它背书。
    static func summaryLine(_ digest: Digest) -> String {
        var parts = [tr("识别 ", "ASR ") + formatMs(digest.asrMs)]
        if let polish = digest.polishMs {
            parts.append(tr("模型 ", "Model ") + formatMs(polish)
                         + tr("（\(digest.polishSampleCount) 次）",
                              " (\(digest.polishSampleCount))"))
        }
        parts.append(tr("插入 ", "Insert ") + formatMs(digest.insertMs))
        return parts.joined(separator: " · ")
            + tr("（最近 \(digest.sampleCount) 次中位数）",
                 " (median of last \(digest.sampleCount))")
    }
}

extension SessionMetric {

    /// 诊断信息里的一行。固定英文、固定字段顺序——这段文字是贴给别人看的，
    /// 不跟界面语言走，免得收到的人拿到一半中文一半英文的表格。
    var diagnosticRow: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        // 字段名跟着手势走：轻点那一段是润色，按住那一段是指令模型，写死成 polish 会误导读的人
        let modelField = mode == .command ? "model" : "polish"
        // 缓存命中只在真的走过大模型时才有意义，没有就不占一格（老记录也不会凭空多出字段）
        let cacheField = cachedTokens.map { " cached=\($0)" } ?? ""
        // 实际档位同理。勾了 fast 却写着 tier=default 就是"被降级了"，一眼能看出来
        let tierField = serviceTier.map { " tier=\($0)" } ?? ""
        return "\(f.string(from: date)) \(mode.rawValue)"
            + " asr=\(asrMs)ms \(modelField)=\(polishMs.map { "\($0)ms" } ?? "-")"
            + " insert=\(insertMs)ms audio=\(String(format: "%.1f", audioSeconds))s"
            + " partials=\(partialCount) cold=\(cold)" + cacheField + tierField
    }
}
