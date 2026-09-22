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

        // 5.0.0 的一次性清理：本机模型目录整棵删掉，并把释放了多少空间记下来
        // （那个数会出现在这一次启动的悬浮窗提示里）
        let freedBytes = LocalModelCleanup.runIfNeeded()
        let onboardingShowing = routeFirstLaunch()
        announceLaunch(onboardingShowing: onboardingShowing, freedBytes: freedBytes)
    }

    /// 每次启动都要交代的两件事：**上次升级成没成**，以及**它现在在哪、下一步按什么**。
    ///
    /// 自更新是"App 把自己换掉"：失败时本进程早就退了，界面上的失败回调永远不会触发，
    /// 而脚本有两条 abort 路径会把旧版重新打开——看起来和升级成功一模一样。
    /// 所以脚本留了张条子，这里启动时念一次，顺手清掉临时目录里的安装残留。
    ///
    /// 成功那一档不再单独闪："已更新到 x.y.z" 和 4.3.4 新加的那句"它在菜单栏里"合成一条
    /// （LaunchNotice）——同一时刻闪两条只会互相盖掉。
    private func announceLaunch(onboardingShowing: Bool, freedBytes: Int64 = 0) {
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
                           freedBytes: freedBytes,
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
        // **问三个窗口控制器，不看系统给的 flag**：悬浮窗也是一扇窗，正在听写时
        // 它会让 flag 变成真，于是点 Dock 图标什么都不会发生
        let anyWindowOpen = OnboardingWindowController.shared.isOpen
            || SettingsWindowController.shared.isOpen
            || HistoryWindowController.shared.isOpen
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 键名写全（「轻点 右 Option 听写」）：菜单栏第一行是很多人唯一会读的说明书，
        // 4.0.0 那里写的是 R⌥ —— 用户实测反馈没人看得懂那是哪颗键
        let hotkeyName = Settings.shared.hotkey.plainName
        let modeHint = tr("轻点 ", "Tap ") + hotkeyName + tr(" 听写 · 按住说指令", " to dictate · hold to command")
        let titleItem = NSMenuItem(title: modeHint, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        switch dictation.phase {
        case .idle:
            menu.addItem(makeItem(tr("开始听写", "Start Dictation"), #selector(toggleDictation)))
        case .recording:
            menu.addItem(makeItem(tr("停止并输出", "Stop & Insert"), #selector(toggleDictation)))
            menu.addItem(makeItem(tr("取消录音（Esc）", "Cancel Recording (Esc)"), #selector(cancelDictation)))
        case .processing:
            let item = NSMenuItem(title: tr("处理中…", "Processing…"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            // 分段识别到一半时这一项其实是"停掉后面、把已经转好的插入"——写成「取消」
            // 就是在骗人（点它会往文档里打字）。判据与悬浮窗胶囊、与 cancel() 同源。
            menu.addItem(makeItem(
                dictation.escFinishesEarlyNow
                    ? tr("收尾并输入（Esc）", "Finish & Insert (Esc)")
                    : tr("取消（Esc）", "Cancel (Esc)"),
                #selector(cancelDictation)))
        }

        // 「换回识别原文」（P9）：只在刚插入过一次被润色改动的听写、且还在 60 秒内时出现。
        // 目标应用不在前台就灰着并说清要切回哪儿——不自作主张替用户切窗口去撤销。
        if let offer = dictation.revertOffer() {
            let item = makeItem(tr("换回识别原文（撤销润色）", "Use raw transcript instead"),
                                #selector(revertToRaw))
            if !offer.ready {
                // NSMenu 默认自动启用：去掉 action 才是真的灰掉
                item.action = nil
                item.isEnabled = false
                item.toolTip = tr("请先切回 ", "Switch back to ") + offer.appName
                    + tr(" 再撤销", " first")
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // 「润色档位」子菜单 5.0.0 删掉：润色永远开着，那个菜单里没有第二个答案可选。

        // 历史记录：菜单里只留最近 5 条速览（复制），完整的搜索/原文对照/重新插入在历史窗口里
        let historyItem = NSMenuItem(title: tr("最近记录", "Recent Transcripts"), action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        let items = HistoryStore.shared.items
        if items.isEmpty {
            let empty = NSMenuItem(title: tr("（暂无）", "(empty)"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
        } else {
            for item in items.prefix(5) {
                var title = item.polished.replacingOccurrences(of: "\n", with: " ")
                if title.count > 36 {
                    title = String(title.prefix(36)) + "…"
                }
                let mi = NSMenuItem(title: title, action: #selector(copyHistory(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = item.polished
                mi.toolTip = tr("点击复制全文", "Click to copy")
                historyMenu.addItem(mi)
            }
        }
        historyMenu.addItem(.separator())
        let openHistoryItem = makeItem(tr("打开历史记录…", "Open History…"), #selector(openHistory))
        openHistoryItem.keyEquivalent = "y"
        openHistoryItem.keyEquivalentModifierMask = .command
        historyMenu.addItem(openHistoryItem)
        if !items.isEmpty {
            historyMenu.addItem(makeItem(tr("清空记录", "Clear History"), #selector(clearHistory)))
        }
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(.separator())

        // 「升级识别模型」与「释放模型内存」5.0.0 一并删掉：没有本机模型了。

        // 没配 Key 时给一条看得见的入口（配好就消失）。3.3 之前菜单栏对"AI 没配"
        // 一个字都不说，用户只有在按住说完话之后才在悬浮窗看到一句错误。
        // 5.0.0 起没有 Key 连听写都不能用，所以这一条比从前更该在。
        if !LLMClient.isConfigured {
            menu.addItem(makeItem(tr("配置 AI…", "Set up AI…"), #selector(openAISettings)))
        }

        let settingsItem = makeItem(tr("设置…", "Settings…"), #selector(openSettings))
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)
        // 「写作偏好…」直接摆在菜单里（5.0.0）：它是设置窗口底部那排小字里的一页，
        // 而往词汇表里补一个听错的名字，是这个产品第二常做的事——不该要两次点击
        menu.addItem(makeItem(tr("写作偏好…", "Writing Preferences…"),
                              #selector(openWritingPreferences)))
        // 界面语言：设计文档第 1 节写的是"界面语言跟系统，菜单栏可切"——设置页上没有
        // 这一项了（一辈子点一次的东西不该占那一页），但它必须还够得着
        menu.addItem(languageItem())
        menu.addItem(makeItem(tr("检查更新…", "Check for Updates…"), #selector(openAppUpdate)))
        menu.addItem(makeItem(tr("打开日志文件夹", "Open Logs Folder"), #selector(openLogsFolder)))

        menu.addItem(.separator())

        let quitItem = makeItem(tr("退出 MicType", "Quit MicType"), #selector(quit))
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
    }

    /// 界面语言子菜单。当前那一档打勾——不打勾的话，两项并排看不出现在是哪一种
    /// （尤其界面正是他看不懂的那一种语言时）
    private func languageItem() -> NSMenuItem {
        let item = NSMenuItem(title: tr("界面语言", "Language"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for language in AppLanguage.allCases {
            let mi = NSMenuItem(title: language.displayName, action: #selector(setLanguage(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = language.rawValue
            mi.state = (language == L10n.shared.language) ? .on : .off
            submenu.addItem(mi)
        }
        item.submenu = submenu
        return item
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - 动作

    @objc private func toggleDictation() {
        dictation.toggle()
    }

    @objc private func cancelDictation() {
        dictation.cancel()
    }

    @objc private func revertToRaw() {
        dictation.revertToRaw()
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        L10n.shared.language = language
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // 复制完菜单一收，屏幕上什么都没变，用户只能靠再点一次来确认——所以给一句和
        // 历史窗口「已复制」一致的反馈。但绝不能抢占录音/处理中的悬浮窗：
        // flash() 会 endProcessing() 并清掉草稿，等于把「正在听…」或计时擦了（见 Overlay.swift）。
        switch dictation.phase {
        case .idle:
            dictation.overlay.flashSuccess(tr("已复制", "Copied"))
        case .processing:
            dictation.overlay.flashOverProcessing(tr("已复制", "Copied"))
        case .recording:
            // 录音中只记日志：波形比这句提示重要得多，也不该在录音里插一声提示音
            Log.info("History copied while recording — overlay left untouched")
        }
    }

    @objc private func clearHistory() {
        let count = HistoryStore.shared.items.count
        guard count > 0 else { return }
        // 破坏性且不可逆：clear() 立刻覆盖 history.json，没有撤销、也不在设置导出的备份里。
        // 单条删除走历史窗口，这里问一次是最后一道闸。
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("清空 \(count) 条记录？", "Clear \(count) transcripts?")
        alert.informativeText = tr("此操作无法撤销，历史文件会被立即覆盖。想只删其中一条，请在历史记录窗口里删。",
                                   "This cannot be undone — the history file is overwritten immediately. To remove a single entry, use the History window.")
        let clearButton = alert.addButton(withTitle: tr("清空", "Clear"))
        clearButton.hasDestructiveAction = true
        alert.addButton(withTitle: tr("取消", "Cancel"))
        // 这条路是从菜单栏那份菜单点进来的，MicType 多半不在前台：不激活的话
        // 弹窗可能落在别的窗口后面
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            Log.info("Clear history cancelled by user")
            return
        }
        Log.info("History cleared count=\(count)")
        HistoryStore.shared.clear()
    }

    @objc private func openHistory() {
        HistoryWindowController.shared.show()
    }

    /// 主菜单里的「设置…」也走这里（AppMenu 用 #selector 指过来，所以不能是 private）
    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    /// 主菜单里的「关于 MicType」：设置窗口的「关于」页（版本 / 更新 / 隐私都在那儿）
    @objc func openAbout() {
        SettingsWindowController.shared.show(tab: .about)
    }

    @objc private func openAISettings() {
        SettingsWindowController.shared.show()
    }

    /// 菜单栏的「写作偏好…」：直接落到那一页，不必先开设置再点底下那排小字
    @objc private func openWritingPreferences() {
        SettingsWindowController.shared.show(tab: .writing)
    }

    /// 菜单栏的「检查更新…」：进关于页并当场开查（他点的就是这个动作）
    @objc private func openAppUpdate() {
        SettingsWindowController.shared.show(tab: .about, intent: .checkUpdate)
    }

    @objc private func openLogsFolder() {
        Log.info("Open logs folder")
        NSWorkspace.shared.open(Log.logsDirectory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
