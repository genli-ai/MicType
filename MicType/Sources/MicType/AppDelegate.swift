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
        // 模型缺失时的"去哪儿"：引导窗口比设置页更直接（模型在那里后台下，有进度、下完自动继续）。
        // 4.0.1 的引导只剩四屏，下载挂在权限那一屏上，所以落点改成 .permissions
        dictation.onNeedSettings = {
            if QwenEngine.shared.isModelAvailable {
                SettingsWindowController.shared.show()
            } else {
                OnboardingWindowController.shared.show(startAt: .permissions)
            }
        }

        // 缺系统权限时同样去引导（OWNER 规则 2026-09-20：三件必办的事都在引导里办完）。
        // 那一页两项权限各一行、各一颗按钮，勾上之后自己变绿并往下走
        dictation.onNeedPermissions = {
            OnboardingWindowController.shared.show(startAt: .permissions)
        }

        // 悬浮窗上的「去配置」：直接落到「云端 AI」那一页，不让用户自己从概览点进去
        dictation.onNeedAISettings = {
            SettingsWindowController.shared.show(tab: .cloud)
        }

        // 悬浮窗上的「去设置」：云端识别没填 Key 时落到「云端 AI」页——云端识别的开关
        // 和那把 Key 都在那里（「本地识别」页只剩麦克风、语言、词汇表、本机模型）
        dictation.onNeedRecognitionSettings = {
            SettingsWindowController.shared.show(tab: .cloud)
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

        // 识别停在阿里云、服务商却已经不是阿里云：「云端 AI」页上那个开关这时根本不渲染。
        // **不替他改**（音频出不出这台 Mac 永远由用户自己点），但要留一行日志——
        // 那一页现在会当面说这件事，用户抄来问的时候日志里得找得到。
        if AISetup.showsStrandedAlibabaCloudNotice(engine: Settings.shared.recognitionEngine,
                                                   provider: Settings.shared.llmProvider) {
            Log.warn("Cloud recognition stranded: engine=cloudAlibaba provider="
                     + Settings.shared.llmProvider.rawValue)
        }

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

        if QwenEngine.shared.isModelAvailable {
            // 后台预加载模型，第一次听写不用等
            QwenEngine.shared.preload()
        }
        let onboardingShowing = routeFirstLaunch()
        announceLaunch(onboardingShowing: onboardingShowing)
        // 启动计数 +1。它只有一个用途：换过模型之后「至少重启过一次」才允许删旧模型
        // （顺带在这里问一次够不够条件删——上一轮换代的成功听写可能发生在上一次启动里）。
        ModelUpgrader.shared.noteAppLaunch()
        // 模型目录：最多 24 小时查一次，查到更好的模型只在菜单栏和设置页里「摆出来」，
        // 绝不自动下载、绝不弹窗——启动这一刻用户想的是说话，不是换模型。
        ModelUpgrader.shared.refreshDecisionAtLaunch()
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
        } else if RecognitionEngineReadiness.current() == .localModelMissing,
                  !Settings.shared.onboardingSkippedEssentials {
            // 走过引导但模型没了（换了模型 / 被删）：仍然带去下载页，而不是把人扔进设置页。
            // 只对本地档成立——云端档缺 Key 不抢启动，按下热键时悬浮窗上那个「去设置」胶囊接住他。
            // 点过「先跳过」的人例外：他已经知道模型没下，每次启动再弹一遍就成了催促
            OnboardingWindowController.shared.show(startAt: .permissions)
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

        // 润色档位
        let levelItem = NSMenuItem(title: tr("润色档位", "Polish Mode"), action: nil, keyEquivalent: "")
        let levelMenu = NSMenu()
        let current = Settings.shared.polishLevel
        for level in PolishLevel.allCases {
            let mi = NSMenuItem(title: level.displayName, action: #selector(setPolishLevel(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = level.rawValue
            mi.state = (level == current) ? .on : .off
            levelMenu.addItem(mi)
        }
        levelItem.submenu = levelMenu
        menu.addItem(levelItem)

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

        // 有更好的识别模型时在菜单栏摆一条。点它是「带我去看」，不是「立刻下载 800 MB」——
        // 那一下必须是设置页横幅上写着体量的那个按钮（菜单项点错的代价太大）。
        switch ModelUpgrader.shared.decision {
        case .none:
            break
        case .upgrade, .refresh:
            menu.addItem(makeItem(tr("升级识别模型…", "Upgrade speech model…"), #selector(openModelUpgrade)))
        case .needsAppUpdate:
            menu.addItem(makeItem(tr("新识别模型需要更新 MicType…", "New speech model needs a MicType update…"),
                                  #selector(openAppUpdate)))
        }

        if QwenEngine.shared.isModelLoaded {
            menu.addItem(makeItem(tr("释放模型内存", "Free Model Memory"), #selector(unloadModel)))
        }

        // 没配 AI 时给一条看得见的入口（配好就消失）。3.3 之前菜单栏对"AI 没配"
        // 一个字都不说，用户只有在按住说完话之后才在悬浮窗看到一句错误。
        // 本机模型那一档不需要 Key，isConfigured 已经替我们认下了。
        if !LLMClient.isConfigured {
            menu.addItem(makeItem(tr("配置 AI…", "Set up AI…"), #selector(openAISettings)))
        }

        let settingsItem = makeItem(tr("设置…", "Settings…"), #selector(openSettings))
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)
        menu.addItem(makeItem(tr("打开日志文件夹", "Open Logs Folder"), #selector(openLogsFolder)))

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

    @objc private func toggleDictation() {
        dictation.toggle()
    }

    @objc private func cancelDictation() {
        dictation.cancel()
    }

    @objc private func revertToRaw() {
        dictation.revertToRaw()
    }

    @objc private func setPolishLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let level = PolishLevel(rawValue: raw) else { return }
        Settings.shared.polishLevel = level
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

    @objc private func unloadModel() {
        QwenEngine.shared.unloadModel()
    }

    /// 主菜单里的「设置…」也走这里（AppMenu 用 #selector 指过来，所以不能是 private）
    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    /// 主菜单里的「关于 MicType」：设置窗口的「关于」页（版本 / 更新 / 隐私都在那儿）
    @objc func openAbout() {
        SettingsWindowController.shared.show(tab: .about)
    }

    /// 带去设置 → 本地识别：升级横幅在那里，按钮上写着这次要下多少
    @objc private func openModelUpgrade() {
        Log.info("Menu: open model upgrade banner")
        SettingsWindowController.shared.show(tab: .recognition)
    }

    /// 新模型要求更新的 App 版本：这条路只能先更新 MicType（关于页有「检查更新」）
    @objc private func openAppUpdate() {
        Log.info("Menu: model needs newer app, routing to Check for Updates")
        SettingsWindowController.shared.show(tab: .about)
    }

    @objc private func openAISettings() {
        SettingsWindowController.shared.show(tab: .cloud)
    }

    @objc private func openLogsFolder() {
        Log.info("Open logs folder")
        NSWorkspace.shared.open(Log.logsDirectory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
