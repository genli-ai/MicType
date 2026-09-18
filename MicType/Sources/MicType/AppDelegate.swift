import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let dictation = DictationController()
    private let hotkeys = HotkeyManager()
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.startup()

        setupStatusItem()

        dictation.onPhaseChange = { [weak self] phase in
            self?.updateIcon(for: phase)
            // 录音中 *和* 处理中都要保持 Esc 拦截：处理中 Esc 是用户唯一的出口
            self?.hotkeys.setCancellable(phase != .idle)
        }
        dictation.onNeedSettings = {
            SettingsWindowController.shared.show()
        }

        hotkeys.onTapToggle = { [weak self] in self?.dictation.toggle() }
        hotkeys.onSkillStart = { [weak self] in self?.dictation.skillHoldStart() }
        hotkeys.onSkillEnd = { [weak self] in self?.dictation.skillHoldEnd() }
        hotkeys.onCancel = { [weak self] in self?.dictation.cancel() }
        hotkeys.isRecording = { [weak self] in self?.dictation.isRecording ?? false }
        hotkeys.isBusy = { [weak self] in self?.dictation.isProcessing ?? false }
        hotkeys.onBusyGesture = { [weak self] in self?.dictation.gestureWhileBusy() }
        hotkeys.start()

        // 首次启动：申请辅助功能权限；模型缺失则打开设置引导下载
        if !Permissions.isAccessibilityTrusted {
            Permissions.promptAccessibility()
        }
        if QwenEngine.shared.isModelAvailable {
            // 后台预加载模型，第一次听写不用等
            QwenEngine.shared.preload()
        } else {
            SettingsWindowController.shared.show()
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

        // 历史记录
        let historyItem = NSMenuItem(title: tr("最近记录", "Recent Transcripts"), action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        let items = HistoryStore.shared.items
        if items.isEmpty {
            let empty = NSMenuItem(title: tr("（暂无）", "(empty)"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
        } else {
            for item in items.prefix(10) {
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
            historyMenu.addItem(.separator())
            historyMenu.addItem(makeItem(tr("清空记录", "Clear History"), #selector(clearHistory)))
        }
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(.separator())

        if QwenEngine.shared.isModelLoaded {
            menu.addItem(makeItem(tr("释放模型内存", "Free Model Memory"), #selector(unloadModel)))
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
    }

    @objc private func clearHistory() {
        HistoryStore.shared.clear()
    }

    @objc private func unloadModel() {
        QwenEngine.shared.unloadModel()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openLogsFolder() {
        Log.info("Open logs folder")
        NSWorkspace.shared.open(Log.logsDirectory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
