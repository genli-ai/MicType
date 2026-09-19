import Foundation
import Combine

struct HistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let raw: String
    let polished: String
    /// 这一条是联网搜索出来的话，模型给的来源。空数组 = 没联网（或那个端点不回传来源）。
    /// 存在历史里而不是只在悬浮窗上一闪：用户过后想核实"这个数字哪来的"，只能靠这里。
    let citations: [Citation]

    init(id: UUID = UUID(), date: Date, raw: String, polished: String,
         citations: [Citation] = []) {
        self.id = id
        self.date = date
        self.raw = raw
        self.polished = polished
        self.citations = citations
    }

    /// 键名写明白：这份 JSON 是落盘格式，字段名改一个字就读不回老记录了
    private enum CodingKeys: String, CodingKey {
        case id, date, raw, polished, citations
    }

    /// 自己写解码：citations 是 v4.0 才加的字段，老的 history.json 里压根没有这个键，
    /// 合成的解码器遇到缺键会整份文件解不出来——**200 条历史不该因为加了一个字段全没了**。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        raw = try c.decode(String.self, forKey: .raw)
        polished = try c.decode(String.self, forKey: .polished)
        citations = try c.decodeIfPresent([Citation].self, forKey: .citations) ?? []
    }

    /// raw 与 polished 明显不同才值得给用户看"识别原文"——只差首尾空白不算
    var rawDiffers: Bool {
        let a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && a != b
    }
}

/// 最近的听写记录（保留 200 条，持久化到 Application Support/history.json）
///
/// 为什么从 UserDefaults 换成 JSON 文件：200 条长文本塞进 UserDefaults 会让 plist 越来越大、
/// 每次改设置都要整份重写；历史是"数据"不是"偏好"，放文件里更合适，也方便以后导出。
/// 旧版的 UserDefaults 数组在首次启动时自动迁移进来，迁完即删，用户无感。
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private let legacyKey = "history"
    private let maxCount = 200
    /// 文件写入放后台队列：add() 发生在听写交付路径上，主线程一毫秒都不该浪费
    private let ioQueue = DispatchQueue(label: "com.mictype.history.io")

    @Published private(set) var items: [HistoryItem] = []

    private var fileURL: URL {
        Paths.appSupportDir.appendingPathComponent("history.json")
    }

    private init() {
        load()
    }

    func add(raw: String, polished: String, citations: [Citation] = []) {
        // 用户在设置里关掉了"保存听写历史"：这一条连内存都不进，更不写盘。
        // 已有的记录不动——替用户删掉他没要求删的东西，比不记录更糟。
        guard Settings.shared.keepHistory else { return }
        items.insert(HistoryItem(date: Date(), raw: raw, polished: polished,
                                 citations: citations), at: 0)
        if items.count > maxCount {
            items = Array(items.prefix(maxCount))
        }
        save()
    }

    /// 删掉单条。有了它，用户想抹掉一句含隐私内容的听写才不必把 200 条全清了。
    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        save()
    }

    func clear() {
        items = []
        save()
    }

    // MARK: - 持久化

    private func save() {
        let snapshot = items
        let url = fileURL
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            guard let data = try? encoder.encode(snapshot) else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Log.warn("History save failed: \(error.localizedDescription)")
            }
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = Array(decoded.prefix(maxCount))
            return
        }
        migrateFromUserDefaults()
    }

    /// 3.2.x 及更早版本把 20 条记录存在 UserDefaults["history"] 里，格式是 [[String: Any]]
    private func migrateFromUserDefaults() {
        guard let array = UserDefaults.standard.array(forKey: legacyKey) as? [[String: Any]] else { return }
        items = array.compactMap { dict in
            guard let t = dict["date"] as? Double,
                  let raw = dict["raw"] as? String,
                  let polished = dict["polished"] as? String else { return nil }
            return HistoryItem(date: Date(timeIntervalSince1970: t), raw: raw, polished: polished)
        }
        guard !items.isEmpty else { return }
        Log.info("History migrated from UserDefaults: \(items.count) items")
        save()
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
}
