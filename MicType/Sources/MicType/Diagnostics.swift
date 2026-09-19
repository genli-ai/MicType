import AppKit

// MARK: - 复制诊断信息（P20）

/// 把排障需要的环境、设置摘要、最近耗时和今天的日志尾巴凑成一段纯文本，一键进剪贴板。
///
/// 为什么要有它：用户报"突然变慢了 / 悬浮窗没出来"时，来回问版本、芯片、模型、档位要三五轮，
/// 而这些信息本来就都在本机。一次复制粘贴顶一整轮问答。
///
/// 两条不可违反的纪律：
/// 1. **绝不含 API Key**——只报"配没配"，Key 永远只在钥匙串里；
/// 2. **绝不含任何听写内容**——耗时行只有数字，日志本身也只记事件不记文本（见 Log）。
/// 用户会把这段文字贴进邮件、issue、群聊，它必须是可以随手公开的。
enum Diagnostics {

    /// 诊断正文。内容固定英文：收到这段文字的人不一定和用户用同一种界面语言。
    static func report() -> String {
        let s = Settings.shared
        var lines: [String] = []

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ssZZZZZ"
        stamp.locale = Locale(identifier: "en_US_POSIX")

        lines.append("MicType diagnostics — \(stamp.string(from: Date()))")
        lines.append("App: \(UpdateChecker.currentVersion) (build \(buildNumber))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Chip: \(chip)")
        lines.append("Speech model: \(s.qwenModelRepo)"
                     + " downloaded=\(QwenEngine.shared.isModelAvailable)"
                     + " loaded=\(QwenEngine.shared.isModelReady)")
        lines.append("Hotkey: \(s.hotkey.rawValue)")
        lines.append("Polish: level=\(s.polishLevel.rawValue) model=\(s.currentPolishModel)"
                     + " command=\(s.currentCommandModel)")
        // 服务商与"配没配 Key"就是全部：Key 本身一个字符都不出现在这里
        lines.append("Provider: \(s.llmProvider.rawValue)"
                     + " apiKey=\(KeychainHelper.loadAPIKey() == nil ? "absent" : "configured")")
        lines.append("Overlay: position=\(s.overlayPosition.rawValue) livePreview=\(s.livePreview)")

        let metrics = Array(Metrics.shared.items.prefix(10))
        lines.append("")
        lines.append("Last \(metrics.count) sessions:")
        if metrics.isEmpty {
            lines.append("  (none recorded yet)")
        } else {
            lines.append(contentsOf: metrics.map { "  " + $0.diagnosticRow })
        }

        let log = Log.recentLines(40)
        lines.append("")
        lines.append("Last \(log.count) log lines (today):")
        if log.isEmpty {
            lines.append("  (no log file for today)")
        } else {
            lines.append(contentsOf: log.map { "  " + $0 })
        }

        return lines.joined(separator: "\n")
    }

    /// 直接写系统剪贴板，**不走 TextInserter**：这里要的就是"放进剪贴板"本身，
    /// 而 TextInserter 会切前台应用、模拟 ⌘V、再按设置把剪贴板还原回去——
    /// 那套时序是为"插入到光标处"设计的，用在这里会把刚复制的诊断信息又还原掉。
    static func copyToPasteboard() {
        let text = report()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Log.info("Diagnostics copied (\(text.count) chars)")
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// 芯片型号（"Apple M1 Pro" 之类）——本机识别快慢头一个要看的就是它
    private static var chip: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: buffer)
    }
}
