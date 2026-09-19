import AppKit

/// 轻量文件日志：~/Library/Logs/MicType/mictype-yyyyMMdd.log
/// 用于排查偶发问题（悬浮窗不可见、手势异常等）——只记事件与状态，不记录任何转写内容和密钥。
enum Log {

    static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MicType", isDirectory: true)
    }

    private static let queue = DispatchQueue(label: "mictype.log", qos: .utility)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERROR", message) }

    /// 单调时钟毫秒差，用于给各阶段（识别/润色/插入）计时——埋点排查"慢"用
    static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }

    /// 今天这份日志文件。**故意每次新建一个 DateFormatter**：上面那个 dayFormatter 只在
    /// 串行日志队列里用，DateFormatter 不是线程安全的，从主线程（诊断信息）再碰一次就有风险。
    /// 一次复制诊断信息才建一个，这点开销无所谓。
    static var todayLogFile: URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return logsDirectory.appendingPathComponent("mictype-\(f.string(from: Date())).log")
    }

    /// 今天日志的最后 n 行，供「复制诊断信息」取用。
    /// 读不到（今天还没写过日志 / 文件被删）就返回空数组——诊断信息宁可少一段，
    /// 也绝不能因为没有日志文件就失败。
    static func recentLines(_ n: Int) -> [String] {
        guard n > 0, let text = try? String(contentsOf: todayLogFile, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(n))
    }

    /// 启动时调用：版本、系统、每块屏幕的几何与缩放（直接服务悬浮窗排障）、设置摘要
    static func startup() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        info("Startup version=\(version) macOS=\(os)")
        let s = Settings.shared
        info("Settings hotkey=\(s.hotkey.rawValue) polish=\(s.polishLevel.rawValue) provider=\(s.llmProvider.rawValue) "
             + "vocabTerms=\(s.vocabularyTerms.count) replacements=\(s.vocabularyReplacements.count)")
        for (i, screen) in NSScreen.screens.enumerated() {
            info("Display \(i) name=\(screen.localizedName) frame=\(rect(screen.frame)) "
                 + "visible=\(rect(screen.visibleFrame)) scale=\(screen.backingScaleFactor) "
                 + "isMain=\(screen == NSScreen.main)")
        }
        cleanupOldLogs()
    }

    /// 悬浮窗显示后回读真实状态——"调了显示但没显示出来"在这里现形
    static func overlayShown(context: String, panel: NSPanel) {
        let screenName = panel.screen?.localizedName ?? "nil"
        info("Overlay \(context) frame=\(rect(panel.frame)) screen=\(screenName) "
             + "visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace)")
    }

    private static func rect(_ r: CGRect) -> String {
        "(\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height)))"
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(timeFormatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            let dir = logsDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("mictype-\(dayFormatter.string(from: Date())).log")
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
        }
    }

    /// 只保留最近 7 天
    private static func cleanupOldLogs() {
        queue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: logsDirectory,
                                                          includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
            for f in files where f.lastPathComponent.hasPrefix("mictype-") {
                if let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   date < cutoff {
                    try? fm.removeItem(at: f)
                }
            }
        }
    }
}
