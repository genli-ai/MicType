import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let dictation = DictationController()
    private let hotkeys = HotkeyManager()
    private let menu = NSMenu()
    /// 主菜单跟着界面语言重建。4.3.4 之前主菜单根本不存在、也从来不会被显示；
    /// 4.3.5 起 MicType 是普通应用（常驻 Dock），它成为前台时屏幕顶上摆着的就是这份菜单
    /// ——它必须和窗口里的语言一致
    private var menuLanguageObserver: AnyCancellable?

    /// 给其它窗口借用的悬浮提示层。历史窗口把文字留在剪贴板时要提示「按 ⌘V」，
    /// 但那一刻它已经让出前台、窗口也收起来了：窗口内的状态条既看不见，
    /// 把窗口拉回来又会从目标应用抢走焦点（用户的 ⌘V 会落进搜索框）。
    /// Overlay 是非激活浮窗，正好是这种提示该走的路。
    static var sharedOverlay: OverlayController? {
        (NSApp.delegate as? AppDelegate)?.dictation.overlay
    }

    /// 设置窗口里的「测试麦克风」要用：主流程正在录音 / 出结果时不能再开第二路录音，
    /// 否则两路抢同一只麦克风，用户看到的是自己正说着的话被一个自检打断
    static var isDictationBusy: Bool {
        guard let dictation = (NSApp.delegate as? AppDelegate)?.dictation else { return false }
        return dictation.isRecording || dictation.isProcessing
    }

    /// **4.3.5 起 MicType 是一个普通应用**（用户 2026-09-22 拍板，推翻 09-19 的纯菜单栏定位
    /// 和 4.3.4 那版「窗口开着才进 Dock」）：Dock 图标和菜单栏图标两个都一直在，和 Wispr Flow 一样。
    /// 所以这里既不设 `.accessory`，Info.plist 里也不再有 `LSUIElement`——
    /// "找不到它在哪"这条反馈的根子就是它从来不在 Dock 里。不给开关（用户点名不要）。
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.startup()

        // 主菜单：⌘C / ⌘V / ⌘A 的来路（用户 2026-09-22 反馈"Key 框不能粘贴"的根因，见 AppMenu）
        NSApp.mainMenu = AppMenu.build()
        // 切语言时重建。**下一轮 runloop 再建**：@Published 是在 willSet 时发出的，
        // 此刻 L10n.shared.language 还是旧值，当场重建会得到一份旧语言的菜单
        menuLanguageObserver = L10n.shared.$language.dropFirst().sink { _ in
            DispatchQueue.main.async { NSApp.mainMenu = AppMenu.build() }
        }

        setupStatusItem()

        dictation.onPhaseChange = { [weak self] phase in
            self?.updateIcon(for: phase)
            // 录音中 *和* 处理中都要保持 Esc 拦截：处理中 Esc 是用户唯一的出口
            self?.hotkeys.setCancellable(phase != .idle)
        }
        // 没别的可说时的"去哪儿"：设置窗口（5.0.0 起识别只有云端，不再有"模型没下载"这条路）
        dictation.onNeedSettings = {
            SettingsWindowController.shared.show()
        }

        // 缺系统权限时同样去引导（OWNER 规则 2026-09-20：三件必办的事都在引导里办完）。
        // 那一页两项权限各一行、各一颗按钮，勾上之后自己变绿并往下走
        dictation.onNeedPermissions = {
            OnboardingWindowController.shared.show(startAt: .permissions)
        }

        // 悬浮窗上的「去配置」/「去设置」：5.0.0 起设置就是一页，两条深链都落在它上面
        // （那一页第二行就是 API Key 输入框）
        dictation.onNeedAISettings = {
            SettingsWindowController.shared.show()
        }
        dictation.onNeedRecognitionSettings = {
            SettingsWindowController.shared.show()
        }

        // 云端识别的 Key 统一到润色那把（qwen_api_key）：开发期存过旧账号的搬过来再删
        KeychainHelper.migrateLegacyDashScopeKey()

        // 接入地址每周按**最快**重挑一次（见 AlibabaFastestHostRefresh）。界面上已经没有
        // 任何"重新探测"的按钮了，所以这件事只能自己做：选定的那台主机日常一句话都不复查，
        // 而它会随着用户换地方、服务商调链路而变旧。后台跑、不挡任何事，问不出结果就留到下次启动。
        // 放在后台队列上是因为它要读一次钥匙串——那件事不该坐在启动路径上。
        DispatchQueue.global(qos: .utility).async {
            AlibabaFastestHostRefresh.runAtLaunch()
        }

        // 识别引擎 5.0.0 起由生效服务商推出来，「识别停在旧档」那条边界状态不再可能出现。

        // 网络可达性：识别、润色、指令三件事全在云端，"没网"是按下热键那一刻就该说清的状态
        NetworkReachability.start()

        hotkeys.onTapToggle = { [weak self] in self?.dictation.toggle() }
        hotkeys.onPressStart = { [weak self] in self?.dictation.pressStart() }
        hotkeys.onPressTapConfirm = { [weak self] in self?.dictation.pressTapConfirm() }
        hotkeys.onHoldPromote = { [weak self] in self?.dictation.holdPromote() }
        hotkeys.onPressAbort = { [weak self] in self?.dictation.abortPressSession() }
        hotkeys.onSkillEnd = { [weak self] in self?.dictation.skillHoldEnd() }
        hotkeys.onCancel = { [weak self] in self?.dictation.cancel() }
        hotkeys.isRecording = { [weak self] in self?.dictation.isRecording ?? false }
        hotkeys.isBusy = { [weak self] in self?.dictation.isProcessing ?? false }
        hotkeys.onBusyGesture = { [weak self] in self?.dictation.gestureWhileBusy() }
        hotkeys.start()

        // 5.0.0 的一次性清理：本机模型目录整棵删掉。
        // 释放了多少 5.0.1 起**只进日志**——用户要知道的是"它在跑、按哪颗键"，不是磁盘数字
        LocalModelCleanup.runIfNeeded()
        let onboardingShowing = routeFirstLaunch()
        announceLaunch(onboardingShowing: onboardingShowing)
    }

    /// 每次启动都要交代的两件事：**上次升级成没成**，以及**它现在在哪、下一步按什么**。
    ///
    /// 自更新是"App 把自己换掉"：失败时本进程早就退了，界面上的失败回调永远不会触发，
    /// 而脚本有两条 abort 路径会把旧版重新打开——看起来和升级成功一模一样。
    /// 所以脚本留了张条子，这里启动时念一次，顺手清掉临时目录里的安装残留。
    ///
    /// 成功那一档不再单独闪："已更新到 x.y.z" 和 4.3.4 新加的那句"它在菜单栏里"合成一条
    /// （LaunchNotice）——同一时刻闪两条只会互相盖掉。
    private func announceLaunch(onboardingShowing: Bool) {
        UpdateChecker.cleanupStaleStages()
        var updatedTo: String?
        switch UpdateChecker.consumePreviousInstallResult() {
        case .none:
            break
        case .failed(let message):
            // 排在引导 / 权限那些窗口之后弹，别抢首启动的流程
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = tr("上次升级没有完成", "The last update didn't finish")
                alert.informativeText = message
                alert.addButton(withTitle: tr("好", "OK"))
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        case .installed:
            // 版本号取本 bundle（条子是上一个进程写的，回滚过的话两者会对不上）
            updatedTo = UpdateChecker.currentVersion
        }
        // flashInfo 而不是 flashNotice：.notice 那一档画的是一枚 ✗（「已取消」用它），
        // 摆在"已更新到 4.1.1"旁边正好把话说反
        LaunchNotice.flash(LaunchNotice.decide(updatedTo: updatedTo,
                                               onboardingShowing: onboardingShowing),
                           after: UpdateChecker.installedNoticeDelay)
    }

    /// 点 Dock 图标 / 在 Finder 里再打开一次已经在跑的 MicType。
    ///
    /// 4.3.4 之前这里什么都没实现：被"再打开一次"时屏幕上毫无反应，
    /// 于是用户会以为它没装上、再下一次（2026-09-22 的反馈就是这么来的）。
    /// 现在：引导没走完的接着走引导，走完了的打开设置概览——那三张卡片本身
    /// 就是"我现在是什么状态"的答案。4.3.5 起 Dock 图标一直都在，这条路因此是**常用路径**。
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // 自家已经有窗口开着：把它带到前台就够。
        // **问两个窗口控制器，不看系统给的 flag**：悬浮窗也是一扇窗，正在听写时
        // 它会让 flag 变成真，于是点 Dock 图标什么都不会发生。
        //（历史窗口 5.0.2 整个删掉了：听写记录照常写 history.json，界面不再有它的窗口。）
        let anyWindowOpen = OnboardingWindowController.shared.isOpen
            || SettingsWindowController.shared.isOpen
        guard !anyWindowOpen else {
            NSApp.activate(ignoringOtherApps: true)
            // 收进程序坞的窗口要自己弹回来：不然"点了 Dock 图标什么都没发生"照样成立，
            // 而那正是这次改动要消灭的那种死路
            NSApp.windows.first { $0.isMiniaturized }?.deminiaturize(nil)
            Log.info("Reopen: own window already showing")
            return true
        }
        // 和启动那条路**同一把尺子**（FirstRunEssentials）：权限齐了、引擎就绪了的人
        // 不该被再拽回引导，哪怕他当年没点过那颗「完成」
        let essentials = FirstRunEssentials.current()
        if !Settings.shared.onboardingCompleted, !essentials.canFinish {
            Log.info("Reopen: resuming onboarding at page=\(essentials.resumePage.rawValue)")
            OnboardingWindowController.shared.show(startAt: essentials.resumePage)
        } else {
            Log.info("Reopen: opening settings overview")
            openSettings()
        }
        return true
    }

    /// 首启动去哪儿：新用户走引导；已经配好的老用户一个字都不打扰。
    /// 判据用"当前这一档识别引擎就绪 + 辅助功能已授权"——这两项齐了说明他早就在用了，
    /// 弹引导只会像退步。**引擎按用户选的那一档判**：选了云端的人明确决定不下那 860MB，
    /// 每次启动还把他拽到下载页就是在跟他较劲。
    ///
    /// 没走完的引导会**接着走**（用户 2026-09-20 拍板）：落在第一件没办完的事那一屏，
    /// 而不是每次都从第一屏重来一遍。点过「先跳过」的人 onboardingCompleted 已经是真，
    /// 从此不再被拦——缺的那几项改由设置概览上的徽章提醒。
    /// - Returns: 这一次把引导窗口弹出来了没有（启动那句提示据此决定闪不闪，见 LaunchNotice）
    @discardableResult
    private func routeFirstLaunch() -> Bool {
        // 「他早就在用了」的判据和引导那颗「完成」按钮**同一把尺子**（FirstRunEssentials）。
        // 4.1.0 之前这里漏掉了麦克风：辅助功能勾了、麦克风还没给的人（在权限页给了一半就
        // 关掉窗口、模型在后台继续下）被判成"已经配好"，引导从此再也不出现，
        // 而他的第一次轻点撞上的是系统授权框 +「请再按一次」，不是那一页。
        let essentials = FirstRunEssentials.current()
        let alreadyUsable = essentials.permissionsGranted && essentials.modelReady

        if !Settings.shared.onboardingCompleted {
            if alreadyUsable {
                Settings.shared.onboardingCompleted = true
                Log.info("Onboarding skipped: already configured")
            } else {
                // 引导自己有权限页，这里不要抢先弹系统授权框（用户还没看清这是什么应用）
                Log.info("Onboarding resumes at page=\(essentials.resumePage.rawValue) "
                         + essentials.logSummary)
                OnboardingWindowController.shared.show(startAt: essentials.resumePage)
                return true
            }
        } else if case .cloudKeyMissing = RecognitionEngineReadiness.current(),
                  !Settings.shared.onboardingSkippedEssentials {
            // 走过引导、但这一刻**没有 Key**（5.0.0 把 DeepSeek / 自定义端点 / 本机大模型
            // 三档删掉了，用那几档的老用户升上来就落在这里）。识别也在云端，没有 Key
            // 连听写都不能用——所以把他接回引导第三屏，而不是让他按一次热键才发现。
            // 点过「先跳过」的人例外：他已经知道，每次启动再弹一遍就成了催促。
            Log.info("Onboarding reopened: no API key after the 5.0 upgrade")
            OnboardingWindowController.shared.show(startAt: .howYouUse)
            return true
        }

        if !Permissions.isAccessibilityTrusted {
            Permissions.promptAccessibility()
        }
        return false
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(for: .idle)
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 三态的图形全在 MenuBarIcon 里（4.3.4 起空闲 / 录音两态画的是 MicType 自己的标志，
    /// 不再是系统通用的 mic 符号——那枚谁都认不出是哪个应用）。
    /// 录音态那张自己带红色（非模板图），所以不再设 contentTintColor：
    /// 对非模板图它不起作用，留着只会让人以为颜色是从这里来的。
    private func updateIcon(for phase: DictationController.Phase) {
        guard let button = statusItem.button else { return }
        switch phase {
        case .idle:
            button.image = MenuBarIcon.image(.idle)
            button.contentTintColor = nil
        case .recording:
            button.image = MenuBarIcon.image(.recording)
            button.contentTintColor = nil
        case .processing:
            button.image = MenuBarIcon.image(.processing)
            button.contentTintColor = .systemOrange
        }
    }

    /// 菜单栏那份菜单 5.0.1 起**只有三项**（用户 2026-09-22 拍板）：设置 / 检查更新 / 退出。
    ///
    /// 砍掉的都是"在菜单里做事"的入口：顶行那句操作说明（引导第一屏已经把它教完了）、
    /// 「开始听写」（这个产品的全部意义就是不用去点菜单）、「最近记录」子菜单
    /// （**不再把听写内容列进菜单**——那是一条会当着别人的面展开的隐私）、
    /// 「写作偏好」「界面语言」「打开日志文件夹」（分别搬到设置底栏那排小字与「关于」页）。
    ///
    /// 这份菜单从此是静态的，所以也不再有随录音状态变化的那几项：录音中停止靠再轻点一次、
    /// 取消靠 Esc，两者都在引导里教过，而菜单要点开才看得见——正在说话的人不会去点它。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let settingsItem = makeItem(tr("设置…", "Settings…"), #selector(openSettings))
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)
        menu.addItem(makeItem(tr("检查更新…", "Check for Updates…"), #selector(openAppUpdate)))

        menu.addItem(.separator())

        let quitItem = makeItem(tr("退出 MicType", "Quit MicType"), #selector(quit))
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - 动作

    /// 主菜单里的「设置…」也走这里（AppMenu 用 #selector 指过来，所以不能是 private）
    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    /// 主菜单里的「关于 MicType」：设置窗口的「关于」页（版本 / 更新 / 隐私都在那儿）
    @objc func openAbout() {
        SettingsWindowController.shared.show(tab: .about)
    }

    /// 「检查更新…」：进关于页并当场开查（他点的就是这个动作）。
    /// 菜单栏那份菜单和主菜单的 App 菜单都指这里（AppMenu 用 #selector 指过来，不能是 private）
    @objc func openAppUpdate() {
        SettingsWindowController.shared.show(tab: .about, intent: .checkUpdate)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
