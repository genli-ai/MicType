import AppKit

/// 全局热键监听。触发手势固定为：
/// 轻点所选修饰键（按下到松开 < 0.6s 且期间没按其它键）= 开始/结束听写；
/// 按住 0.6s = 进入"指令模式"录音，松开结束（V3 语音技能）；
/// 录音中 / 处理中按 Esc 取消。
final class HotkeyManager {

    var onTapToggle: (() -> Void)?
    var onSkillStart: (() -> Void)?
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
                DispatchQueue.main.async { manager.tapCandidate = false }
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

    private func handleFlagsChanged(_ event: NSEvent) {
        let choice = Settings.shared.hotkey

        guard event.keyCode == choice.keyCode else {
            // 按了别的修饰键，取消"轻点"判定
            tapCandidate = false
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
                // 按住 0.6s 且当前空闲 → 进入指令模式录音
                holdWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self, self.tapCandidate else { return }
                    // 门槛是"空闲"而不是"没在录音"：处理中放行会让 onSkillStart 撞上
                    // guard phase == .idle 空转，用户按住说完一整句却零反馈（3.2.19 之前的 bug）
                    guard !self.isRecording(), !self.isBusy() else {
                        if self.isBusy() {
                            Log.info("Hotkey hold rejected (processing)")
                            self.onBusyGesture?()
                        }
                        return
                    }
                    self.skillActive = true
                    Log.info("Hotkey skill-start (hold)")
                    self.onSkillStart?()
                }
                holdWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            } else {
                tapCandidate = false
                holdWorkItem?.cancel()
            }
        } else {
            holdWorkItem?.cancel()
            if skillActive {
                skillActive = false
                Log.info("Hotkey skill-end")
                DispatchQueue.main.async { [weak self] in self?.onSkillEnd?() }
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
        // 修饰键按住期间敲了别的键（快捷键等）→ 不算轻点，也不进指令模式
        tapCandidate = false
        holdWorkItem?.cancel()
        // Esc 取消（录音中或处理中）
        if event.keyCode == 53, isRecording() || isBusy() {
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
        }
    }
}
