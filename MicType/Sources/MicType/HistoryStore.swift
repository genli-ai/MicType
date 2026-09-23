import Foundation

/// 听写历史：**按天一个纯文本文件，像日志那样追加**
/// （`~/Library/Logs/MicType/Transcripts/transcripts-yyyyMMdd.txt`）。
///
/// 5.0.5 之前它是 Application Support 里一个 200 条上限的 `history.json`：
/// 结构化、可解析、还带来源链接，但没有任何界面读它（历史窗口 5.0.2 就删了），
/// 于是那份 JSON 唯一的用途就是"用户自己打开来翻"——而那件事纯文本做得更好：
/// 按天分文件天然不会长成一个大文件，所以**没有条数上限**，也就不会再有"说得多了旧的被挤掉"。
/// 排错时它和日志躺在同一个目录下，翻记录和看日志是同一个动作的两半。
///
/// 目录选 Logs 而不是 Application Support：这是给人读的日志文件，不是 App 的数据。
/// 注意 `Log.cleanupOldLogs` 只扫日志目录**本级**、且只删 `mictype-` 开头的文件，
/// 所以 Transcripts 子目录不会被那条 7 天清理规则碰到（听写记录不该自己消失）。
final class HistoryStore {
    static let shared = HistoryStore()

    /// 落盘目录。默认跟着 `Log.logsDirectory` 走（跑在 XCTest 里时它已经是临时目录，
    /// 单测不会写进用户真实的 ~/Library/Logs/MicType）。测试里还可以再注入一个专属目录。
    let directory: URL

    /// 文件写入放后台队列：record() 发生在听写交付路径上，主线程一毫秒都不该浪费
    private let ioQueue = DispatchQueue(label: "com.mictype.history.io", qos: .utility)

    init(directory: URL = Log.logsDirectory.appendingPathComponent("Transcripts", isDirectory: true)) {
        self.directory = directory
    }

    /// 听写历史存在哪儿、出不出这台 Mac——**全 App 唯一出处**（「保存听写历史」那颗 ⓘ 渲染它）。
    static var storageNote: String {
        tr("听写历史以纯文本按天存在本机日志目录（Transcripts），从不上传。",
           "Transcripts are kept in plain text on this Mac, one file per day under the logs folder (Transcripts), and are never uploaded.")
    }

    // MARK: - 写入

    /// 记一条听写。**在交付成功之后调一次**（Esc 保底那条路例外，见 DictationController）。
    /// final 与 raw 相同（没润色 / 润色被丢弃 / 保底记录）时只写一行。
    func record(raw: String, final: String, date: Date = Date()) {
        // 用户在设置里关掉了"保存听写历史"：一个字都不落盘。
        // 已有的文件不动——替用户删掉他没要求删的东西，比不记录更糟。
        guard Settings.shared.keepHistory else { return }
        guard let entry = Self.entry(raw: raw, final: final, date: date) else { return }
        let url = directory.appendingPathComponent(Self.fileName(for: date))
        let dir = directory
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let data = Data(entry.utf8)
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url)
                }
            } catch {
                // 写不进去绝不能打断听写：只留一行不含内容的 WARN
                Log.warn("Transcript append failed: \(error.localizedDescription)")
            }
        }
    }

    /// 等后台队列把已排队的写入做完。**只给单测用**：它要读回文件核对格式。
    func waitForPendingWrites() {
        ioQueue.sync { }
    }

    // MARK: - 纯函数：一条记录长什么样

    /// 这一天的文件名。与日志同一个命名风格（`mictype-yyyyMMdd.log`）。
    static func fileName(for date: Date) -> String {
        // 故意每次新建 DateFormatter：它不是线程安全的，而这个函数既在调用线程上跑
        // （record 里算文件名）也在单测里直接被调。一次听写才建一个，开销无所谓。
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "transcripts-\(f.string(from: date)).txt"
    }

    /// 一条记录格式化成什么（含行尾换行）。nil = 这一条没有内容，不该写。
    ///
    /// 键名固定用英文 `raw:` / `final:`、时间戳 `[HH:mm:ss]`：这是给人读的日志文件，
    /// 不是界面，不跟界面语言走（跟着走的话同一个文件里会中英文混排，还没法 grep）。
    /// 成稿与原文相同就省略 `final:` 那一行——相同的话第二行不带任何信息，只是噪音。
    static func entry(raw: String, final: String, date: Date) -> String? {
        let rawText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = final.trimmingCharacters(in: .whitespacesAndNewlines)
        // 原文是空的（识别什么都没出来）就不记：一条只有时间戳的记录没有任何用处
        guard !rawText.isEmpty || !finalText.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let stamp = "[\(f.string(from: date))] "
        // 续行缩进到与第一行的键名对齐，多行文本读起来才是一段而不是一堆碎片
        let indent = String(repeating: " ", count: stamp.count)
        var lines = [stamp + "raw:   " + inline(rawText, indent: indent + "       ")]
        if !finalText.isEmpty, finalText != rawText {
            lines.append(indent + "final: " + inline(finalText, indent: indent + "       "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 文本里自带的换行会把"一条记录一段"的结构冲散（下一行看起来像新的一条）：
    /// 续行统一缩进对齐到键名后面。
    private static func inline(_ text: String, indent: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .joined(separator: "\n" + indent)
    }

    // MARK: - 旧格式清理

    /// 5.0.5 之前的 `Application Support/MicType/history.json`：**启动时一次性删掉**。
    /// 它是一份明文历史，新版本再也不读它，留着只是隐私负担（用户以为历史都在
    /// Transcripts 里，实际上另有一份 200 条的 JSON 谁也想不起来）。
    func removeLegacyJSONIfNeeded() {
        let legacy = Paths.appSupportDir.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacy)
            Log.info("Legacy history.json removed")
        } catch {
            Log.warn("Legacy history.json removal failed: \(error.localizedDescription)")
        }
    }
}
