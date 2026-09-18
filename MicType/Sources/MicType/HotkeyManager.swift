import AppKit

/// 全局热键监听。触发手势固定为（3.3 起「按下即录」）：
/// **按下**（空闲时）立刻开始采音，悬浮窗先按"听写"显示，此刻不碰剪贴板；
/// **0.6s 内松开** = 轻点：这段录音留着当纯听写继续录，再轻点一次（或菜单/Esc）才结束；
/// **按住满 0.6s** = 指令模式：同一段录音就地升级，开口的前 0.6 秒不再丢失，松开即结束；
/// 录音中再按：无论按多久，松开一律 = 停止并输出（3.2.11 定的规矩）；
/// 按住期间敲了别的键（把热键当修饰键用）= 候选作废，刚开始的那段录音一并静默丢弃；
/// 录音中 / 处理中按 Esc 取消。
final class HotkeyManager {

    var onTapToggle: (() -> Void)?
    /// 热键按下且当前空闲：立刻开始录音（还不知道这段归听写还是归指令）
    var onPressStart: (() -> Void)?
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
        monitors = [m1, m2, m3, m4].compactMap { $0 }
    }

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
                    DispatchQueue.main.async {
                        if manager.isRecording() { manager.onCancel?() }
                    }
                    return nil  // 吃掉这次 Esc，不传给前台应用
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
        tapCandidate = false
        holdWorkItem?.cancel()
        guard pressStartedRecording, !skillActive else { return }
        pressStartedRecording = false
        Log.info("Hotkey press-session aborted (another key pressed)")
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
        let isDown = flags.contains(targetFlag)

        if isDown {
            // 必须是"只按了这一个修饰键"才算候选
            if flags == targetFlag {
                tapCandidate = true
                pressedAt = Date()
                skillActive = false
                pressStartedRecording = false
                holdWorkItem?.cancel()
                // 按下即录：空闲时立刻开始采音，先按"听写"显示。3.3 之前要按满 0.6s
                // 才 start，指令模式恒定丢掉开口的前 0.6 秒。
                if !isRecording(), !isBusy() {
                    pressStartedRecording = true
                    Log.info("Hotkey press-start (recording from key-down)")
                    onPressStart?()
                }
                // 按住 0.6s 判定归属：这段是听写还是指令
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.tapCandidate else { return }
                    if self.pressStartedRecording {
                        self.skillActive = true
                        Log.info("Hotkey hold-promote (command mode)")
                        self.onHoldPromote?()
                    } else if self.isBusy() {
                        // 处理中放行会让指令启动撞上 guard phase == .idle 空转，
                        // 用户按住说完一整句却零反馈（3.2.19 之前的 bug）
                        Log.info("Hotkey hold rejected (processing)")
                        self.onBusyGesture?()
                    }
                    // 按下时已经在录音：什么都不做，松开时统一走 release-stop（3.2.11）
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
                pressStartedRecording = false
                Log.info("Hotkey tap (dictation continues)")
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
