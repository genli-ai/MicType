import AppKit

/// 轻量文件日志：~/Library/Logs/MicType/mictype-yyyyMMdd.log
/// 用于排查偶发问题（悬浮窗不可见、手势异常等）——只记事件与状态，不记录任何转写内容和密钥。
enum Log {

    /// 现在跑在 XCTest 里吗。
    ///
    /// 为什么要认这件事：单测里有一批"假的云端会话"（CloudASRTests 用假发送器跑完整条
    /// 分段流程），它们照样走 Log.info——于是用户真实的 ~/Library/Logs/MicType/ 里塞满了
    /// 从没发生过的 200 响应。2026-09-19 排查「测试识别 404 却查不到日志」时就是被这堆
    /// 假记录带偏的：真正的失败一行都没有，假的倒有两百行。
    /// 所以测试期间整份日志改写到临时目录，用户的日志只记用户真的做过的事。
    static let isUnderTest: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || env["XCTestBundlePath"] != nil
    }()

    static var logsDirectory: URL {
        if isUnderTest {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("MicTypeTestLogs", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
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
        // 只记序号与几何，不记 localizedName：AirPlay / 随航目标的"名字"就是用户的设备名
        //（"Gen 的 iPad"），而日志尾巴会被「复制诊断信息」整段贴出去。排悬浮窗的问题
        // 靠的是几何和缩放，名字本来就用不上。
        for (i, screen) in NSScreen.screens.enumerated() {
            info("Display \(i) frame=\(rect(screen.frame)) "
                 + "visible=\(rect(screen.visibleFrame)) scale=\(screen.backingScaleFactor) "
                 + "isMain=\(screen == NSScreen.main)")
        }
        cleanupOldLogs()
    }

    /// 悬浮窗显示后回读真实状态——"调了显示但没显示出来"在这里现形
    static func overlayShown(context: String, panel: NSPanel) {
        // 同样只记序号（见 startup）。这一行每次听写都要写一遍，必然落在诊断信息的尾巴里
        let index = panel.screen.flatMap { NSScreen.screens.firstIndex(of: $0) }
        let screenTag = index.map { "#\($0)" } ?? "nil"
        info("Overlay \(context) frame=\(rect(panel.frame)) screen=\(screenTag) "
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
