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
    /// nil = 这一轮没润色（档位关着 / 没配 Key / 走的是指令模型）。
    /// 记成 0 会把中位数拉垮，所以"没发生"必须和"耗时 0"分开。
    let polishMs: Int?
    let insertMs: Int
    let audioSeconds: Double
    let partialCount: Int
    let cold: Bool
}

/// 一轮进行中的草稿：各阶段算完填一格，投递完成时 finished() 封口成 SessionMetric。
/// 录音结束时就能定下的字段（时长、预览遍数、冷启动）用 let，后面各阶段填的用 var。
struct SessionMetricDraft {
    let mode: SessionMetric.Mode
    let audioSeconds: Double
    let partialCount: Int
    let cold: Bool
    var asrMs: Int = 0
    var polishMs: Int?

    func finished(insertMs: Int) -> SessionMetric {
        SessionMetric(date: Date(), mode: mode, asrMs: asrMs, polishMs: polishMs,
                      insertMs: insertMs, audioSeconds: audioSeconds,
                      partialCount: partialCount, cold: cold)
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
        /// 这批里一次润色都没有 → nil，界面上那一段就不显示
        let polishMs: Int?
        let insertMs: Int
    }

    /// 取最近 count 轮算中位数。一轮都没有返回 nil（界面改显示"还没有记录"）。
    static func digest(_ items: [SessionMetric], count: Int = 10) -> Digest? {
        let recent = Array(items.prefix(count))
        guard let asr = median(recent.map(\.asrMs)),
              let insert = median(recent.map(\.insertMs)) else { return nil }
        return Digest(sampleCount: recent.count,
                      asrMs: asr,
                      polishMs: median(recent.compactMap(\.polishMs)),
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

    /// 设置页里那一行：「识别 320 ms · 润色 1.8 s · 插入 90 ms（最近 10 次中位数）」
    static func summaryLine(_ digest: Digest) -> String {
        var parts = [tr("识别 ", "ASR ") + formatMs(digest.asrMs)]
        if let polish = digest.polishMs {
            parts.append(tr("润色 ", "Polish ") + formatMs(polish))
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
        return "\(f.string(from: date)) \(mode.rawValue)"
            + " asr=\(asrMs)ms polish=\(polishMs.map { "\($0)ms" } ?? "-")"
            + " insert=\(insertMs)ms audio=\(String(format: "%.1f", audioSeconds))s"
            + " partials=\(partialCount) cold=\(cold)"
    }
}
