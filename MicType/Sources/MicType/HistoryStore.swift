import Foundation
import Combine

struct HistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let raw: String
    let polished: String

    init(id: UUID = UUID(), date: Date, raw: String, polished: String) {
        self.id = id
        self.date = date
        self.raw = raw
        self.polished = polished
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

    func add(raw: String, polished: String) {
        // 用户在设置里关掉了"保存听写历史"：这一条连内存都不进，更不写盘。
        // 已有的记录不动——替用户删掉他没要求删的东西，比不记录更糟。
        guard Settings.shared.keepHistory else { return }
        items.insert(HistoryItem(date: Date(), raw: raw, polished: polished), at: 0)
        if items.count > maxCount {
            items = Array(items.prefix(maxCount))
        }
        save()
    }

    /// **润色之前**先把识别原文落一条（brief §3.3「逐段落地」）。
    /// 为什么：润色要等一次网络往返，插入还要等切前台——这中间任何一步失败、被 Esc 掐断、
    /// 或者用户切走了窗口，在 3.3 之前都意味着刚说的那几分钟一个字都不剩。
    /// 先落 raw，之后 complete(id:polished:) 把同一条补全，用户那边看到的永远只有一条。
    /// 返回 nil = 用户关了历史记录（那就什么都别留，包括这条）。
    @discardableResult
    func addRaw(_ raw: String) -> UUID? {
        guard Settings.shared.keepHistory else { return nil }
        let item = HistoryItem(date: Date(), raw: raw, polished: raw)
        items.insert(item, at: 0)
        if items.count > maxCount {
            items = Array(items.prefix(maxCount))
        }
        save()
        return item.id
    }

    /// 把 addRaw 落下的那一条补成最终文字。条目已经被用户删掉 / 被 200 条上限挤掉就什么都不做。
    func complete(id: UUID, polished: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[index]
        guard old.polished != polished else { return }
        items[index] = HistoryItem(id: old.id, date: old.date, raw: old.raw, polished: polished)
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
