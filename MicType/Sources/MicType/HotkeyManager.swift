import AppKit

/// 全局热键监听。触发手势固定为（3.3 起「按下即录」）：
/// **按下**（空闲时）立刻开始采音，但此刻**完全不现身**——不响开始音、不弹悬浮窗、
/// 不碰选区也不碰剪贴板（把热键当修饰键用的那些次必须是隐形的，3.2.19 的保证）；
/// **0.6s 内松开** = 轻点：手势到此确认，这段录音才现身并留着当纯听写继续录，
/// 再轻点一次（或菜单/Esc）才结束；
/// **按住满 0.6s** = 指令模式：同一段录音就地升级并现身，开口的前 0.6 秒不再丢失，松开即结束；
/// 录音中再按：无论按多久，松开一律 = 停止并输出（3.2.11 定的规矩）；
/// 按住期间敲了别的键（把热键当修饰键用）= 候选作废，刚开始的那段录音一并静默丢弃；
/// 录音中 / 处理中按 Esc 取消。
final class HotkeyManager {

    var onTapToggle: (() -> Void)?
    /// 热键按下且当前空闲：立刻开始录音（还不知道这段归听写还是归指令）
    var onPressStart: (() -> Void)?
    /// 0.6s 内松开 = 轻点：手势确认成"纯听写"，按下时开的那段录音到这一刻才现身
    var onPressTapConfirm: (() -> Void)?
    /// 按住满 0.6s：把正在录的这一段就地升级为指令模式
    var onHoldPromote: (() -> Void)?
    /// 候选作废：把按下即录的那一段丢掉（用户只是拿热键当修饰键）
    var onPressAbort: (() -> Void)?
    var onSkillEnd: (() -> Void)?
    var onCancel: (() -> Void)?
    /// 处理中收到的手势（轻点由 onTapToggle 走控制器，按住走这里）：不能开新一轮，
    /// 但绝不静默吞掉——由控制器给用户看得见的反馈
    var onBusyGesture: (() -> Void)?
    /// 由控制器提供：当前是否正在录音
    var isRecording: (() -> Bool) = { false }
    /// 由控制器提供：当前是否在处理中（识别/润色/指令在飞）
    var isBusy: (() -> Bool) = { false }

    private var monitors: [Any] = []
    private var pressedAt: Date?
    var tapCandidate = false
    private var holdWorkItem: DispatchWorkItem?
    /// 本次按下是否由我们开了一段录音（决定松开时是"继续听写"还是"停止"）
    private var pressStartedRecording = false
    /// 本次按下是否已经升级成指令模式（松开 = 结束指令）
    private var skillActive = false

    // 录音期间的 Esc 拦截（CGEventTap，普通按键的全局监听在新版 macOS 上不可靠）
    private var escTap: CFMachPort?
    private var escRunLoopSource: CFRunLoopSource?

    private let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]

    func start() {
        stop()
        let m1 = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // 本地监听这一条不是可有可无的备份：MicType 自己是前台应用时（引导窗的「试一下」、
        // 设置窗口），全局监听按设计**不会**收到事件，热键全靠它。本地监听在事件进入
        // 响应链之前就跑，所以引导页那个 TextEditor 吃不掉修饰键——轻点照常开录。
        let m2 = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        let m3 = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        let m4 = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
        // 鼠标 / 滚轮 / 亮度音量键也要能作废按下会话：⌥-拖拽复制、⌘-点击开新标签页、
        // ⌥-横向滚动这些手势一个 keyDown 都不产生，只看键盘的话按下时开的那段录音
        // 没人认领，会一直录到硬上限（10 分钟）再被识别、润色、粘贴出去。
        let m5 = NSEvent.addGlobalMonitorForEvents(matching: Self.abortingEvents) { [weak self] _ in
            self?.abortCandidate()
        }
        let m6 = NSEvent.addLocalMonitorForEvents(matching: Self.abortingEvents) { [weak self] event in
            self?.abortCandidate()
            return event
        }
        monitors = [m1, m2, m3, m4, m5, m6].compactMap { $0 }
    }

    /// 除键盘外也算"用户在干别的事"的事件：鼠标按下、滚轮、以及走 NSSystemDefined 的
    /// 亮度/音量/播放键
    private static let abortingEvents: NSEvent.EventTypeMask =
        [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .systemDefined]

    func stop() {
        for m in monitors {
            NSEvent.removeMonitor(m)
        }
        monitors = []
        stopEscTap()
    }

    /// 状态变化时由外部调用：只要这一轮还能被取消（录音中 *或* 处理中）就保持 Esc 拦截。
    /// 3.2.19 之前它在离开 .recording 的瞬间就被拆掉，于是处理中按 Esc 毫无反应。
    func setCancellable(_ active: Bool) {
        if active {
            startEscTap()
        } else {
            stopEscTap()
        }
    }

    private func startEscTap() {
        guard escTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { manager.reenableEscTap() }
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if keyCode == 53 {
                    // 这个回调跑在主线程（source 挂在 CFRunLoopGetMain），所以在这里
                    // **同步**判断这一轮到底能不能取消——放进 DispatchQueue.main.async
                    // 里判断就晚了，返回值那时早已定死。
                    // 判据必须和 NSEvent 那条兜底一致（录音中 *或* 处理中）：只认 isRecording()
                    // 的话，处理中按 Esc 既不取消、又因为 headInsert tap 返回 nil 把事件删掉，
                    // 前台应用也收不到——「处理中可取消」整个功能形同虚设。
                    if manager.isRecording() || manager.isBusy() {
                        DispatchQueue.main.async { manager.onCancel?() }
                        return nil  // 真的由我们接管了这次 Esc，才吃掉它
                    }
                    // 这一轮没什么可取消（phase 回 idle 与 stopEscTap 之间有个短窗口）→ 原样放行
                    return Unmanaged.passUnretained(event)
                }
                DispatchQueue.main.async { manager.abortCandidate() }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: refcon) else {
            return  // 创建失败（权限不足）时退回 NSEvent 监听
        }
        escTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        escRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func reenableEscTap() {
        if let tap = escTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func stopEscTap() {
        if let tap = escTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = escRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        escTap = nil
        escRunLoopSource = nil
    }

    /// 候选作废：按住期间又按了别的键 / 别的修饰键，说明用户是拿热键当修饰键用。
    /// 3.3 起按下即录，所以"作废"不能只是不触发手势——那段已经开始的录音必须一起丢掉，
    /// 否则 ⌥+C 这类快捷键会在后台悄悄留下一段没人要的录音。
    /// 已经升级成指令模式的会话不在此列：用户正在说指令，途中误触别的键不该把话吞掉。
    private func abortCandidate() {
        // 没有候选就什么都不用做。鼠标/滚轮监听每秒能来几十条，这一行让它们几乎零成本。
        guard tapCandidate || pressStartedRecording else { return }
        tapCandidate = false
        holdWorkItem?.cancel()
        guard pressStartedRecording, !skillActive else { return }
        pressStartedRecording = false
        // 日志只留控制器那一行（带录音时长）：作废是高频路径，两头都记就成了刷屏
        onPressAbort?()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let choice = Settings.shared.hotkey

        guard event.keyCode == choice.keyCode else {
            // 按了别的修饰键，取消"轻点"判定（按下即录的那段也跟着作废）
            abortCandidate()
            return
        }

        let flags = event.modifierFlags.intersection(relevantFlags)
        let targetFlag = NSEvent.ModifierFlags(rawValue: choice.flagMask)
        // 按下/松开沿必须判"这一颗键自己"。合并位（.option / .command / …）不分左右：
        // 另一侧的同名键还按着时，热键松开事件里这一位仍然是 1，松开会被当成又一次按下，
        // 松开分支永远不执行——录音停不下来，只能靠再按一次 / Esc / 时长上限收场。
        // 所以优先读 rawValue 里左右分开的设备相关位；只有这台机器/这条事件根本不报
        // 设备位（Fn 就没有，它也没有"另一侧"）时才退回合并位。
        let raw = event.modifierFlags.rawValue
        let isDown: Bool
        if choice.deviceMask != 0, raw & choice.deviceMaskPair != 0 {
            isDown = raw & choice.deviceMask != 0
        } else {
            isDown = flags.contains(targetFlag)
        }

        if isDown {
            // 必须是"只按了这一个修饰键"才算候选
            if flags == targetFlag {
                tapCandidate = true
                pressedAt = Date()
                skillActive = false
                pressStartedRecording = false
                holdWorkItem?.cancel()
                // 按下即录：空闲时立刻开始采音，但只开静音缓冲——现身（开始音/悬浮窗/预览）
                // 等手势确认。3.3 之前要按满 0.6s 才 start，指令模式恒定丢掉开口的前 0.6 秒。
                if !isRecording(), !isBusy() {
                    pressStartedRecording = true
                    // 这里不记日志：把热键当修饰键用是每天几十上百次的路径，
                    // 控制器那边的 "Recording start press=true" 已经说明了一切
                    onPressStart?()
                }
                // 按住 0.6s 判定归属：这段是听写还是指令
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.tapCandidate else { return }
                    if self.pressStartedRecording {
                        self.skillActive = true
                        Log.info("Hotkey hold-promote (command mode)")
                        self.onHoldPromote?()
                    } else if self.isRecording() {
                        // 按下时已经在录音、现在还在录：什么都不做，
                        // 松开时统一走 release-stop（3.2.11）
                    } else {
                        // 按下时在忙（或在录音），所以这一段没开录。到点时那一轮可能刚好结束
                        // ——这 600ms 的竞态窗口里若什么都不做，用户按住说完一整句会零反馈
                        // （3.2.19 之前的那类 bug）。一律通知控制器，由它按当下的 phase 给反馈。
                        Log.info("Hotkey hold rejected (busy at press time)")
                        self.onBusyGesture?()
                    }
                }
                holdWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            } else {
                abortCandidate()
            }
        } else {
            holdWorkItem?.cancel()
            if skillActive {
                skillActive = false
                pressStartedRecording = false
                Log.info("Hotkey skill-end")
                DispatchQueue.main.async { [weak self] in self?.onSkillEnd?() }
            } else if pressStartedRecording {
                // 0.6s 内松开 = 轻点：按下时开的那段录音留着当纯听写继续录。
                // 绝不能在这里停——那就变成"按住说话"了。
                // 手势到这一刻才确认，所以控制器现在才让这段录音现身（开始音 + 悬浮窗 + 灰字预览）。
                pressStartedRecording = false
                Log.info("Hotkey tap (dictation continues)")
                DispatchQueue.main.async { [weak self] in self?.onPressTapConfirm?() }
            } else if tapCandidate, isRecording() {
                // 录音中无论按了多久，松开一律=停止（否则长按≥0.6s 松开会"没反应"）
                Log.info("Hotkey release-stop (recording)")
                DispatchQueue.main.async { [weak self] in self?.onTapToggle?() }
            } else if tapCandidate, let t = pressedAt, Date().timeIntervalSince(t) < 0.6 {
                Log.info("Hotkey tap")
                DispatchQueue.main.async { [weak self] in self?.onTapToggle?() }
            }
            tapCandidate = false
            pressedAt = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Esc 取消（录音中或处理中）：先于作废处理——这一轮由控制器正经取消（有提示音和提示），
        // 不该被静默作废的路径抢走
        if event.keyCode == 53, isRecording() || isBusy() {
            tapCandidate = false
            holdWorkItem?.cancel()
            pressStartedRecording = false
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            return
        }
        // 修饰键按住期间敲了别的键（快捷键等）→ 不算轻点，也不进指令模式
        abortCandidate()
    }
}
