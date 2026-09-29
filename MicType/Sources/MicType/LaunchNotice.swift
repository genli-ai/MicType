import Foundation

// MARK: - 启动时闪的那一句

/// 4.3.4 之前，一个配好了的用户双击 MicType 之后屏幕上**什么都不会发生**：
/// 没有窗口、没有 Dock 图标、菜单栏多了一枚和别人长得一样的麦克风。
/// 2026-09-22 的反馈原话是"打开后什么都没出现，不知道它在哪、也不知道接下来干什么"。
///
/// 所以每次启动都在悬浮窗上闪一句：**它在哪 + 下一步按什么**。升级后那一次把两句合成一条
/// （"已更新到 x.y.z · 轻点 … 开始听写"）——同一时刻闪两条只会互相盖掉。
///
/// 判断写成纯函数是因为它有三种结果、而每一种都只在某个真实场景里才走得到
/// （刚升级 / 引导要弹 / 平常启动），靠手工点三遍验不出来。
enum LaunchNotice {

    /// 这次启动该闪哪一句
    enum Kind: Equatable {
        /// 一个字都不闪
        case none
        /// 平常那一句："它已经在跑了，轻点这颗键开始听写"
        case running
        /// 刚升完级：版本号 + 同一句操作提示
        case updated(version: String)
        /// 5.4.0：每周第一次启动、上周有数据 →「上周说了 43 分钟，打出 6,200 字」
        case weekly(UsageWeek)
    }

    /// - updatedTo: 上一次自更新真的装好了的版本号（没升级就是 nil）
    /// - onboardingShowing: 这次启动把引导窗口弹出来了。
    ///   引导自己就是一份完整的说明书，底下再飘一句提示只会抢它的戏——
    ///   那一句改由引导**关掉**的时候补（见 OnboardingWindowController.windowWillClose）。
    /// - weekly: 这次启动该报的上周合计（见 weeklyDue；nil = 这周报过了 / 上周没数据）。
    ///   与「已更新到 X」撞在同一次启动时**只闪更新那句**：同一时刻闪两条只会互相盖掉，
    ///   而周报不标记为已报，下一次启动再闪（任务书 5.4.0）。
    ///   它顶替平常那句「已在运行 · 轻点…」：一个每周都在用的人早就知道按哪颗键了。
    static func decide(updatedTo: String?, onboardingShowing: Bool, weekly: UsageWeek? = nil) -> Kind {
        guard !onboardingShowing else { return .none }
        if let version = updatedTo?.trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            return .updated(version: version)
        }
        if let weekly = weekly, !weekly.isEmpty { return .weekly(weekly) }
        return .running
    }

    // MARK: 每周一句（纯函数）

    /// 某一刻所在那一周的键：本周一的日期（yyyy-MM-dd，本地时区，ISO 周——与 UsageStore 同一把尺子）
    static func weekKey(for date: Date, timeZone: TimeZone = .current) -> String {
        let start = UsageStore.weekStart(for: date, timeZone: timeZone)
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: start)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 上周至少说了这么多秒才报（主会话 2026-09-29 定）：说了几句、不到一分钟的一周，
    /// 报出来是「上周说了 1 分钟，打出 40 字」——那不是值得闪一次的消息
    static let weeklyMinimumSeconds: Double = 60

    /// 这次启动该不该报上周：这周还没报过（shownForWeek ≠ 本周一）且上周说了 ≥ 60 秒 → 上周合计；否则 nil
    /// （不够 60 秒时调用方什么都不闪、也不记已报——只有真闪出来才记，见 flash）
    static func weeklyDue(now: Date, shownForWeek: String?, entries: [UsageEntry],
                          timeZone: TimeZone = .current) -> UsageWeek? {
        guard shownForWeek != weekKey(for: now, timeZone: timeZone) else { return nil }
        let previous = UsageStore.summarize(entries, now: now, week: .previous, timeZone: timeZone)
        return previous.seconds >= weeklyMinimumSeconds ? previous : nil
    }

    /// 闪的内容。nil = 不闪。
    ///
    /// 5.0.1 去掉了「释放 X GB」那半句（用户 2026-09-22 拍板）：清理照做、只记日志。
    /// 这句提示的全部用意是"它在跑 + 按哪颗键"，磁盘数字是我们想说的，不是他想知道的。
    static func copy(for kind: Kind) -> String? {
        switch kind {
        case .none:
            return nil
        case .running:
            // 4.3.5 起不再说"在菜单栏"：Dock 图标和菜单栏图标两个都一直在，
            // 单点其中一个反而把人往一个地方引（用户 2026-09-22 拍板常驻 Dock）
            return tr("MicType 已在运行 · ", "MicType is running · ") + tapHint
        case .updated(let version):
            // 升级那半句与「关于」页、与自更新提示同一处出处，不另写一份
            return UpdateChecker.installedNoticeCopy(version: version) + " · " + tapHint
        case .weekly(let week):
            return UserMessage.weeklyRecap(week)
        }
    }

    /// 两句话共用的后半截。键名走 HotkeyChoice（只有右 Option 这一颗，见 Settings.hotkey），
    /// 绝不在这里手写一个键名——写死的那种迟早和设置页对不上
    private static var tapHint: String {
        let key = HotkeyChoice.rightOption.displayName
        return tr("轻点 \(key) 开始听写", "tap \(key) to dictate")
    }

    /// 日志里的短名（不含用户内容，只是三选一的档位）
    static func logName(for kind: Kind) -> String {
        switch kind {
        case .none: return "none"
        case .running: return "running"
        case .updated: return "updated"
        case .weekly: return "weekly"
        }
    }

    /// 真去闪那一下。**两个调用方**：启动（AppDelegate）与引导关窗（OnboardingWindowController）。
    /// - delay: 启动那次要等一等（引导 / 权限 / 模型预加载都在抢主线程，立刻闪会被盖掉）；
    ///   引导关窗那次只等窗口收完动画。
    static func flash(_ kind: Kind, after delay: TimeInterval) {
        guard let text = copy(for: kind) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 这几秒里人可能已经开口说话了——那时候这句提示会把「正在听…」顶掉
            guard !AppDelegate.isDictationBusy else {
                Log.info("Launch notice skipped: dictation in progress")
                return
            }
            Log.info("Launch notice shown kind=\(logName(for: kind))")
            // 周报**真闪出来了**才记这周已报：被正在进行的听写挡掉的那次，下次启动再报
            if case .weekly = kind {
                UserDefaults.standard.set(weekKey(for: Date()), forKey: SettingsKeys.weeklyNoticeShownForWeek)
            }
            AppDelegate.sharedOverlay?.flashInfo(text, duration: UpdateChecker.installedNoticeDuration)
        }
    }

    /// 引导关掉之后补的那一下。窗口收起来要一点时间，太快闪会被它盖住
    static let afterOnboardingDelay: TimeInterval = 0.6
}
