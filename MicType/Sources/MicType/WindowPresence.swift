import AppKit

// MARK: - Dock 图标跟着窗口走

/// MicType 是纯菜单栏应用（`LSUIElement` + `.accessory`），**任何时候都不在 Dock 里**——
/// 连引导和设置窗口开着的时候也不在。2026-09-22 的新用户反馈："打开后找不到它"：
/// 窗口被别的应用一盖就再也切不回来（⌘Tab 里也没有它，因为 `.accessory` 不参与切换）。
///
/// 4.3.4 起：自家窗口（引导 / 设置 / 历史）**有一扇开着就进 Dock**，全关了再退回菜单栏。
/// 配置期间找得到、⌘Tab 切得回来；平时仍然不占 Dock 一格（用户 2026-09-19 定的
/// 菜单栏定位没变）。
///
/// 为什么是计数而不是每扇窗各自设策略：三扇窗可以同时开着，谁先关谁后关不确定——
/// 各设各的，先关的那一扇会把还开着的那两扇一起从 Dock 里抹掉。
/// **只在主线程调**（三扇窗的 show / windowWillClose 都在主线程；改激活策略本来也只能在主线程）。
/// 不加 `@MainActor` 标注是跟着这份代码库的惯例走——其余几个窗口控制器同样是这么约定的。
final class WindowPresence {
    static let shared = WindowPresence()

    /// 会把 App 带进 Dock 的那三扇窗
    enum Window: String, CaseIterable {
        case onboarding
        case settings
        case history
    }

    /// 此刻开着的那几扇。**用集合而不是一个整数**：同一扇窗 `show()` 两次
    /// （深链、菜单栏点两下、最小化后再打开）不许把计数加两次，否则关掉它之后
    /// 计数停在 1，Dock 图标永远撤不下来。
    private(set) var open: Set<Window> = []

    /// 真正去改激活策略的那一下。留成可替换的，只为让单测能钉住计数规则
    /// 而不去动跑测试的这个进程自己的 Dock 图标。
    var apply: (NSApplication.ActivationPolicy) -> Void = WindowPresence.applyToNSApp

    private init() {}

    /// 窗口露面了（在 `makeKeyAndOrderFront` **之前**调）
    func enter(_ window: Window) {
        guard !open.contains(window) else { return }
        let wasEmpty = open.isEmpty
        open.insert(window)
        guard wasEmpty else { return }
        Log.info("Dock icon shown for \(window.rawValue)")
        apply(.regular)
    }

    /// 窗口关了（`windowWillClose`）
    func leave(_ window: Window) {
        guard open.remove(window) != nil else { return }
        guard open.isEmpty else { return }
        Log.info("Dock icon hidden after \(window.rawValue)")
        apply(.accessory)
    }

    /// 从 `.accessory` 切到 `.regular` 之后，窗口**不一定在最前**（切换那一下相当于
    /// App 刚刚"变成"一个普通应用，系统不会顺手把它激活）。所以切完必须自己激活一次；
    /// 调用方紧接着还会 `makeKeyAndOrderFront`，两步缺一不可。
    private static func applyToNSApp(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
        guard policy == .regular else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 单测用：把计数和替身恢复原样
    func resetForTesting() {
        open.removeAll()
        apply = WindowPresence.applyToNSApp
    }
}
