import Foundation

// MARK: - 首次启动必须办完的三件事

/// 第一次打开 MicType，有三件事**办不完就不算走完引导**（用户 2026-09-20 拍板）：
/// 麦克风、辅助功能、一把验证过的 OpenAI Key。
///
/// 5.3.0 确认：「识别模型下好了」那一件**已经不存在**——5.0.0 起识别只在云端，
/// 本机没有模型可下。原来那一位（modelReady）其实早就在判"这一档识别引擎能不能开工"，
/// 而云端这一档能开工的唯一条件就是那把 Key，所以这一版把它照实改名成 keyReady。
/// 快捷键从前也在这张表上，4.1.0 把它拿掉了：只剩右 Option 一颗键之后，
/// "确认用哪颗键"已经不是一件他能做错、也不是一件他需要做的事。
///
/// 为什么非得拦：4.0.1 的引导四屏全都能一路「继续」点到底，于是"走完引导"和"能用"是两回事。
/// 真实后果是用户走完一遍，回到自己的文档里轻点，什么都没发生——他不会认为是权限没给，
/// 他会认为这个 App 坏了。而引导恰恰是唯一一次他愿意配合把这些办完的时刻。
///
/// 唯一的出口是一条明写代价的「先跳过」（`Settings.onboardingSkippedEssentials`）：
/// 我们不替用户做主，但也绝不让他在不知情的情况下走出一个不工作的配置。
///
/// 「在 ③ 真落过一次字」不在这张表上：它是引导那一屏自己的事（OnboardingModel.tryItLanded），
/// 不是"这台 Mac 能不能听写"的判据——启动路由、点 Dock 图标问的都只是这三件。
///
/// 这里是**纯结构**：不读 UserDefaults、不碰权限 API，三个布尔进、两个结论出，所以能被单测钉住。
/// 当前这一刻的实际状态由 `current()` 现场采一次（它是唯一碰全局状态的地方）。
struct FirstRunEssentials: Equatable {
    var microphone: Bool
    var accessibility: Bool
    /// 钥匙串里有一把 OpenAI Key（验证通过才会进钥匙串，见 KeyVerifier）。
    /// 识别、润色、指令三件事全在云端，没有它一件都做不了。
    var keyReady: Bool

    /// 两项系统权限都到手了。缺任何一项，热键和插入文字都不会工作
    var permissionsGranted: Bool { microphone && accessibility }

    /// 三件事都办完了 = 这台 Mac 能听写了
    var canFinish: Bool { permissionsGranted && keyReady }

    /// 第一件没办完的事落在哪一屏（办完了 = nil）。顺序就是引导的顺序：
    /// ① 按住右 Option 说话（两项权限在这一屏）→ ② 贴上 Key。
    var firstIncompletePage: OnboardingPage? {
        if !permissionsGranted { return .hold }
        if !keyReady { return .key }
        return nil
    }

    /// 下次启动把没走完的引导接在哪一屏。都办完了就落在「试一下」，让他真落一次字
    /// 再点「开始使用」——那一下才是 onboardingCompleted 真正被写进去的时刻。
    var resumePage: OnboardingPage { firstIncompletePage ?? .tryIt }

    /// 这一刻的实际状态。只在引导与启动路由里调，判据本身全在上面那几个纯属性里。
    static func current() -> FirstRunEssentials {
        FirstRunEssentials(microphone: Permissions.microphoneGranted,
                           accessibility: Permissions.isAccessibilityTrusted,
                           keyReady: RecognitionEngineReadiness.current().hasKey)
    }

    /// 只进日志，不上界面（日志里永远看不到用户说了什么，这几位也全是布尔）
    var logSummary: String {
        "mic=\(microphone) ax=\(accessibility) key=\(keyReady)"
    }
}
