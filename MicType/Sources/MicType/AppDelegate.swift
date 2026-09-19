import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let dictation = DictationController()
    private let hotkeys = HotkeyManager()
    private let menu = NSMenu()

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.startup()

        setupStatusItem()

        dictation.onPhaseChange = { [weak self] phase in
            self?.updateIcon(for: phase)
            // 录音中 *和* 处理中都要保持 Esc 拦截：处理中 Esc 是用户唯一的出口
            self?.hotkeys.setCancellable(phase != .idle)
        }
        // 模型缺失时的"去哪儿"：引导窗口的下载页比设置页更直接（有进度、有说明、下完自动继续）
        dictation.onNeedSettings = {
            if QwenEngine.shared.isModelAvailable {
                SettingsWindowController.shared.show()
            } else {
                OnboardingWindowController.shared.show(startAt: .model)
            }
        }

        // 悬浮窗上的「去配置」：直接落到设置窗口的 AI 页，不让用户自己去翻标签
        dictation.onNeedAISettings = {
            SettingsWindowController.shared.show(tab: .ai)
        }

        // 悬浮窗上的「去设置」：云端识别没填 Key / 区域配不出接入点时，落到识别页
        dictation.onNeedRecognitionSettings = {
            SettingsWindowController.shared.show(tab: .recognition)
        }

        // 云端识别的 Key 统一到润色那把（qwen_api_key）：开发期存过旧账号的搬过来再删
        KeychainHelper.migrateLegacyDashScopeKey()

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
        routeFirstLaunch()
        reportPreviousUpdateResult()
        // 模型目录：最多 24 小时查一次，查到更好的模型只在菜单栏和设置页里「摆出来」，
        // 绝不自动下载、绝不弹窗——启动这一刻用户想的是说话，不是换模型。
        ModelUpgrader.shared.refreshDecisionAtLaunch()
    }

    /// 自更新是"App 把自己换掉"：失败时本进程早就退了，界面上的失败回调永远不会触发，
    /// 而脚本有两条 abort 路径会把旧版重新打开——看起来和升级成功一模一样。
    /// 所以脚本留了张条子，这里启动时念一次（成功静默），顺手清掉临时目录里的安装残留。
    private func reportPreviousUpdateResult() {
        UpdateChecker.cleanupStaleStages()
        guard let message = UpdateChecker.consumePreviousInstallResult() else { return }
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
    }

    /// 首启动去哪儿：新用户走引导；已经配好的老用户一个字都不打扰。
    /// 判据用"当前这一档识别引擎就绪 + 辅助功能已授权"——这两项齐了说明他早就在用了，
    /// 弹引导只会像退步。**引擎按用户选的那一档判**：选了云端的人明确决定不下那 860MB，
    /// 每次启动还把他拽到下载页就是在跟他较劲。
    private func routeFirstLaunch() {
        let ready = RecognitionEngineReadiness.current().isReady && Permissions.isAccessibilityTrusted

        if !Settings.shared.onboardingCompleted {
            if ready {
                Settings.shared.onboardingCompleted = true
                Log.info("Onboarding skipped: already configured")
            } else {
                // 引导自己有权限页，这里不要抢先弹系统授权框（用户还没看清这是什么应用）
                OnboardingWindowController.shared.show()
                return
            }
        } else if RecognitionEngineReadiness.current() == .localModelMissing {
            // 走过引导但模型没了（换了模型 / 被删）：仍然带去下载页，而不是把人扔进设置页。
            // 只对本地档成立——云端档缺 Key 不抢启动，按下热键时悬浮窗上那个「去设置」胶囊接住他
            OnboardingWindowController.shared.show(startAt: .model)
            return
        }

        if !Permissions.isAccessibilityTrusted {
            Permissions.promptAccessibility()
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(for: .idle)
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateIcon(for phase: DictationController.Phase) {
        guard let button = statusItem.button else { return }
        switch phase {
        case .idle:
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "MicType")
            button.contentTintColor = nil
        case .recording:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: tr("录音中", "Recording"))
            button.contentTintColor = .systemRed
        case .processing:
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: tr("处理中", "Processing"))
            button.contentTintColor = .systemOrange
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hotkeyName = Settings.shared.hotkey.shortSymbol
        let modeHint = tr("轻点 ", "Tap ") + hotkeyName + tr(" 听写 · 按住说指令", " to dictate · hold for commands")
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
            menu.addItem(makeItem(tr("取消（Esc）", "Cancel (Esc)"), #selector(cancelDictation)))
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
        // 菜单栏应用是 .accessory，不激活的话弹窗可能落在别的窗口后面
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

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    /// 带去设置 → 识别：升级横幅在那里，按钮上写着这次要下多少
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
        SettingsWindowController.shared.show(tab: .ai)
    }

    @objc private func openLogsFolder() {
        Log.info("Open logs folder")
        NSWorkspace.shared.open(Log.logsDirectory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
