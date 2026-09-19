import Foundation

// MARK: - 首次启动必须办完的三件事

/// 第一次打开 MicType，有三件事**办不完就不算走完引导**（用户 2026-09-20 拍板）：
/// 快捷键确认过、两项系统权限都给了、识别模型下好了。AI 不在其中——轻点听写不需要 Key。
///
/// 为什么非得拦：4.0.1 的引导四屏全都能一路「继续」点到底，于是"走完引导"和"能用"是两回事。
/// 真实后果是用户走完一遍，回到自己的文档里轻点，什么都没发生——他不会认为是权限没给，
/// 他会认为这个 App 坏了。而引导恰恰是唯一一次他愿意配合把这些办完的时刻。
///
/// 唯一的出口是一条明写代价的「先跳过」链接（`Settings.onboardingSkippedEssentials`）：
/// 我们不替用户做主，但也绝不让他在不知情的情况下走出一个不工作的配置。
///
/// 这里是**纯结构**：不读 UserDefaults、不碰权限 API，四个布尔进、两个结论出，所以能被单测钉住。
/// 当前这一刻的实际状态由 `current()` 现场采一次（它是唯一碰全局状态的地方）。
struct FirstRunEssentials: Equatable {
    /// 用户在第一屏确认过用哪颗键（默认右 Option，直接点「继续」也算确认）
    var hotkeyConfirmed: Bool
    var microphone: Bool
    var accessibility: Bool
    /// 当前这一档识别引擎真的能开工（本地档 = 模型下好了；云端档 = 有 Key）。
    /// **不是**"本机模型文件在不在"：明确选了云端识别的人不该被要求下那 860MB。
    var modelReady: Bool

    /// 两项系统权限都到手了。缺任何一项，热键和插入文字都不会工作
    var permissionsGranted: Bool { microphone && accessibility }

    /// 三件事都办完了 = 「完成」那颗按钮可以亮起来
    var canFinish: Bool { hotkeyConfirmed && permissionsGranted && modelReady }

    /// 第一件没办完的事落在哪一屏（办完了 = nil）。
    /// 顺序就是引导的顺序：欢迎（选键）→ 权限（顺带后台下模型）→ 试一下（模型要在这里就绪）。
    /// 「怎么用」那一屏永远不在这条链上——AI 是可选的，它不该成为任何人的断点。
    var firstIncompletePage: OnboardingPage? {
        if !hotkeyConfirmed { return .welcome }
        if !permissionsGranted { return .permissions }
        if !modelReady { return .tryIt }
        return nil
    }

    /// 下次启动把没走完的引导接在哪一屏。都办完了就落在最后一屏，让他把「完成」点掉
    /// ——那一下才是 onboardingCompleted 真正被写进去的时刻。
    var resumePage: OnboardingPage { firstIncompletePage ?? .tryIt }

    /// 这一刻的实际状态。只在引导与启动路由里调，判据本身全在上面那几个纯属性里。
    static func current() -> FirstRunEssentials {
        FirstRunEssentials(hotkeyConfirmed: Settings.shared.hotkeyConfirmed,
                           microphone: Permissions.microphoneGranted,
                           accessibility: Permissions.isAccessibilityTrusted,
                           modelReady: RecognitionEngineReadiness.current().isReady)
    }

    /// 只进日志，不上界面（日志里永远看不到用户说了什么，这几位也全是布尔）
    var logSummary: String {
        "hotkey=\(hotkeyConfirmed) mic=\(microphone) ax=\(accessibility) model=\(modelReady)"
    }
}
