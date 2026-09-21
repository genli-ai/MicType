import AppKit

// MARK: - 复制诊断信息（P20）

/// 把排障需要的环境、设置摘要、最近耗时和今天的日志尾巴凑成一段纯文本，一键进剪贴板。
///
/// 为什么要有它：用户报"突然变慢了 / 悬浮窗没出来"时，来回问版本、芯片、模型、档位要三五轮，
/// 而这些信息本来就都在本机。一次复制粘贴顶一整轮问答。
///
/// 三条不可违反的纪律：
/// 1. **绝不含 API Key**——只报"配没配"，Key 永远只在钥匙串里；
/// 2. **绝不含任何听写内容**——耗时行只有数字，日志本身也只记事件不记文本（见 Log）；
/// 3. **不带机器标识**——日志里的绝对路径带着账户短名，进正文前统一脱敏（见 redact）。
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
        // 识别引擎这一行是排障第一问：他的音频到底出没出这台 Mac。
        // 只报档位、接入地址、语言与"有没有 Key"——Key 本身一个字符都不出现。
        // 主机名里第一段是工作空间编号，抹掉再报（诊断信息是要被整段贴出来的）
        lines.append("Recognition: engine=\(s.recognitionEngine.rawValue)"
                     + " language=\(s.recognitionLanguage.isEmpty ? "auto" : s.recognitionLanguage)"
                     + " cloudModel=\(s.cloudAlibabaModel.rawValue)"
                     + " host=\(s.qwenResolvedHost.isEmpty ? "unresolved" : AlibabaEndpoint.redacted(s.qwenResolvedHost))"
                     + " pastedHost=\(s.qwenAPIHost.isEmpty ? "unset" : "set")"
                     + " cloudKey=\(CloudASRSettings.hasKey(for: s.recognitionEngine) ? "configured" : "absent")"
                     + " ready=\(RecognitionEngineReadiness.current().isReady)")
        lines.append("Hotkey: \(s.hotkey.rawValue)")
        lines.append("Polish: level=\(s.polishLevel.rawValue) model=\(s.currentPolishModel)"
                     + " command=\(s.currentCommandModel)")
        // 服务商与"配没配 Key"就是全部；顺带报端点主机名（自定义/本机档最容易出错的就是它，
        // 而主机名不是秘密——Key 本身一个字符都不出现在这里）
        lines.append("Provider: \(s.llmProvider.rawValue)"
                     + " apiKey=\(KeychainHelper.loadAPIKey() == nil ? "absent" : "configured")"
                     + " callable=\(LLMClient.isConfigured)"
                     + " host=\(URL(string: s.currentBaseURL)?.host ?? "unset")")
        // Fast 档 4.1.6 起不是设置，是一条规则（OpenAI 官方接口恒开）——所以这里报的是
        // **这一刻真会发生什么**：下一趟润色带不带 service_tier、上一趟服务商实际给了哪一档、
        // 这一轮有几个型号拒过它。报一条早就没人读的设置，等于把排障往错的方向指一整轮。
        // 回传的档位**原样报**（这份文字要能贴给任何人，不跟界面语言走），后面缀一句
        // "被降级了"——那正是回传值唯一有用的地方：请求问了 Fast，服务商给的是普通档
        let servedTier = Metrics.shared.items.compactMap(\.serviceTier).first
            .map { $0 + (LLMCatalog.servedPriorityTier($0) ? "" : " (downgraded)") }
            ?? "none reported"
        lines.append("Extras: fastTier=\(LLMClient.asksForFastTier(model: s.currentPolishModel))"
                     + " lastServedTier=\(servedTier)"
                     + " fastTierRefused=\(FastTierMemory.shared.models.count)"
                     + " webSearch=\(s.webSearchEnabled)"
                     + " searchStyle=\(s.webSearchStyle)")
        lines.append("Overlay: position=\(s.overlayPosition.rawValue) livePreview=\(s.livePreview)")

        let metrics = Array(Metrics.shared.items.prefix(10))
        lines.append("")
        lines.append("Last \(metrics.count) sessions:")
        if metrics.isEmpty {
            lines.append("  (none recorded yet)")
        } else {
            lines.append(contentsOf: metrics.map { "  " + $0.diagnosticRow })
        }

        let log = Log.recentLines(40).map(redact)
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

    /// 日志行脱敏：家目录换成 `~`（`/Users/<短名>/Library/…` 这类路径每次更新检查都会写一条），
    /// 账户全名/短名换成 `<user>`。About 页承诺这段文字可以放心贴给别人，那它就得为真。
    static func redact(_ line: String) -> String {
        var out = line.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        let full = NSFullUserName()
        if full.count >= 3 { out = out.replacingOccurrences(of: full, with: "<user>") }
        return redactWord(NSUserName(), in: out)
    }

    /// 短名（"gen"）只在独立成词时替换：整串替换会把 "generation" 这种词也咬掉一块，
    /// 日志反而读不懂了
    private static func redactWord(_ word: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard word.count >= 2,
              let regex = try? NSRegularExpression(
                pattern: "(?<![A-Za-z0-9_])" + escaped + "(?![A-Za-z0-9_])",
                options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text,
                                              range: NSRange(text.startIndex..., in: text),
                                              withTemplate: "<user>")
    }

    /// 构建号。关于页也要报它（版本 + 构建是用户唯一能报给我们的身份），所以不是 private
    static var buildNumber: String {
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
