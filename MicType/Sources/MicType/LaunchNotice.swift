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
    }

    /// - updatedTo: 上一次自更新真的装好了的版本号（没升级就是 nil）
    /// - onboardingShowing: 这次启动把引导窗口弹出来了。
    ///   引导自己就是一份完整的说明书，底下再飘一句提示只会抢它的戏——
    ///   那一句改由引导**关掉**的时候补（见 OnboardingWindowController.windowWillClose）。
    static func decide(updatedTo: String?, onboardingShowing: Bool) -> Kind {
        guard !onboardingShowing else { return .none }
        if let version = updatedTo?.trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            return .updated(version: version)
        }
        return .running
    }

    /// 闪的内容。nil = 不闪。
    /// - freedBytes: 5.0.0 的一次性清理释放了多少磁盘（0 = 没删过 / 没删出空间）。
    ///   只挂在"刚升完级"那一句上：平常启动说这个毫无意义。
    static func copy(for kind: Kind, freedBytes: Int64 = 0) -> String? {
        switch kind {
        case .none:
            return nil
        case .running:
            // 4.3.5 起不再说"在菜单栏"：Dock 图标和菜单栏图标两个都一直在，
            // 单点其中一个反而把人往一个地方引（用户 2026-09-22 拍板常驻 Dock）
            return tr("MicType 已在运行 · ", "MicType is running · ") + tapHint
        case .updated(let version):
            // 升级那半句与「关于」页、与自更新提示同一处出处，不另写一份
            return UpdateChecker.installedNoticeCopy(version: version)
                + freedSuffix(freedBytes) + " · " + tapHint
        }
    }

    /// 「· 本地识别已移除，释放 1.2 GB」。5.0.0 把本机模型整条链路删了，而用户对这件事
    /// 唯一能感知到的就是磁盘——不说的话，他只会发现"识别变成联网的了"，
    /// 却不知道自己换回了几百 MB 空间。释放不出空间（早就删过 / 本来就没下过）就一个字不说。
    private static func freedSuffix(_ bytes: Int64) -> String {
        let size = LocalModelCleanup.gigabytesLabel(bytes)
        guard !size.isEmpty else { return "" }
        return tr(" · 本地识别已移除，释放 \(size)",
                  " · on-device recognition removed, \(size) freed")
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
        }
    }

    /// 真去闪那一下。**两个调用方**：启动（AppDelegate）与引导关窗（OnboardingWindowController）。
    /// - delay: 启动那次要等一等（引导 / 权限 / 模型预加载都在抢主线程，立刻闪会被盖掉）；
    ///   引导关窗那次只等窗口收完动画。
    static func flash(_ kind: Kind, freedBytes: Int64 = 0, after delay: TimeInterval) {
        guard let text = copy(for: kind, freedBytes: freedBytes) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 这几秒里人可能已经开口说话了——那时候这句提示会把「正在听…」顶掉
            guard !AppDelegate.isDictationBusy else {
                Log.info("Launch notice skipped: dictation in progress")
                return
            }
            Log.info("Launch notice shown kind=\(logName(for: kind))")
            AppDelegate.sharedOverlay?.flashInfo(text, duration: UpdateChecker.installedNoticeDuration)
        }
    }

    /// 引导关掉之后补的那一下。窗口收起来要一点时间，太快闪会被它盖住
    static let afterOnboardingDelay: TimeInterval = 0.6
}
