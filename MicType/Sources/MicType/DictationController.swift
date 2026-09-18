import AppKit

/// 听写主流程：录音 → 本地识别 → AI 润色 → 插入光标处
final class DictationController {

    enum Phase {
        case idle
        case recording
        case processing
    }

    private(set) var phase: Phase = .idle {
        didSet { onPhaseChange?(phase) }
    }

    /// 状态变化回调（主线程），用于菜单栏图标
    var onPhaseChange: ((Phase) -> Void)?
    /// 需要打开设置窗口时的回调
    var onNeedSettings: (() -> Void)?

    private let recorder = AudioRecorder()
    let overlay = OverlayController()
    private var didPromptAccessibility = false
    /// 录音开始时的前台应用（文字将粘贴到这个应用）
    private var targetBundleID = ""
    /// 录音开始时的选中文本（V3 语音技能用；读不到为 nil）
    private var targetSelection: String?
    /// 本次录音是否为"指令模式"（按住快捷键触发）
    private var skillSession = false
    /// 录音途中音频链路断掉（换设备后重装 tap 失败）的原因，收尾时附到结果提示里，
    /// 让用户知道这段是"半句"而不是自己没说清楚
    private var audioFaultNote: String?
    /// 会话代数：每开一轮、每取消一次都自增。所有异步回调（ASR / 润色 / 指令 / 选区兜底）
    /// 都带着发起时的代数回来，对不上就整条丢弃——取消之后绝不能再往光标里插入任何东西。
    private var generation = 0
    /// 当前在飞的 LLM 请求，Esc 取消时直接掐断（省下最坏几十秒的干等）
    private var inflightRequest: LLMRequestHandle?

    /// 无障碍接口残缺、读选区需要 ⌘C 兜底的应用
    private static let poorAXApps: Set<String> = [
        "com.tencent.xinWeChat", "com.tencent.qq",
    ]

    // MARK: - 入口

    func toggle() {
        switch phase {
        case .idle: startRecording()
        case .recording: finishRecording()
        case .processing: gestureWhileBusy()
        }
    }

    /// 处理中收到轻点/按住：不能开新一轮，但绝不静默吞掉手势——
    /// 明确告诉用户在忙，以及出口在哪（Esc）。
    func gestureWhileBusy() {
        guard phase == .processing else { return }
        Log.info("Gesture ignored while processing")
        overlay.flashOverProcessing(tr("处理中… 按 Esc 取消", "Processing… press Esc to cancel"))
        Sounds.playError()
    }

    /// 指令模式：按住快捷键触发
    func skillHoldStart() {
        guard phase == .idle else { return }
        startRecording(skill: true)
    }

    func skillHoldEnd() {
        if phase == .recording { finishRecording() }
    }

    func cancel() {
        switch phase {
        case .idle:
            return
        case .recording:
            Log.info("Recording cancelled by user")
            _ = recorder.stop()
            endSession()
            overlay.hide()
            Sounds.playCancel()
        case .processing:
            // 处理中取消：掐断在飞的 LLM 请求，并把会话代数推进一格——
            // 已经在路上的 ASR/润色/指令结果回来时会被代数挡掉，一个字都不会插入。
            Log.info("Processing cancelled by user")
            endSession()
            overlay.flashNotice(tr("已取消", "Cancelled"))
            Sounds.playCancel()
        }
    }

    /// 结束当前一轮：作废所有在途回调 + 掐断网络请求 + 清掉本轮上下文，状态回 idle
    private func endSession() {
        generation &+= 1
        inflightRequest?.cancel()
        inflightRequest = nil
        skillSession = false
        targetSelection = nil
        audioFaultNote = nil
        phase = .idle
    }

    /// 异步回调回来时核对：还是发起它的那一轮吗？
    private func isCurrent(_ g: Int) -> Bool { generation == g }

    /// 录音期间音频链路断了（换设备后重装 tap 失败）：绝不干等一个不会再来数据的录音，
    /// 立刻拿已经录到的部分走正常收尾（太短/无声仍由 finishRecording 的既有闸门处理）。
    /// AudioRecorder 在主线程回调。
    private func handleAudioFault(_ message: String) {
        guard phase == .recording else { return }
        Log.error("Audio fault while recording: \(message)")
        audioFaultNote = message
        finishRecording()
    }

    /// 取出并清空音频故障提示——每条只提示一次，绝不泄漏到下一次录音
    private func takeAudioFaultNote() -> String? {
        defer { audioFaultNote = nil }
        return audioFaultNote
    }

    var isRecording: Bool { phase == .recording }
    var isProcessing: Bool { phase == .processing }

    // MARK: - 流程

    private func startRecording(skill: Bool = false) {
        // 检查模型
        guard QwenEngine.shared.isModelAvailable else {
            overlay.flashError(tr("识别模型未下载，请在设置中下载",
                                  "Speech model not downloaded — see Settings"))
            Sounds.playError()
            onNeedSettings?()
            return
        }
        // 检查辅助功能权限（粘贴需要）。权限刚打开时 macOS 往往要重启 App 才完全生效。
        guard Permissions.isAccessibilityTrusted else {
            didPromptAccessibility = true
            Permissions.promptAccessibility()
            overlay.flashError(tr("请先开启辅助功能权限，然后重启 MicType",
                                  "Enable Accessibility permission, then restart MicType"))
            Sounds.playError()
            return
        }
        // 检查麦克风权限
        let alreadyAuthorized = Permissions.microphoneGranted
        Permissions.ensureMicrophone { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.overlay.flashError(tr("没有麦克风权限，请在 系统设置 → 隐私 中开启",
                                           "No microphone access — enable it in System Settings → Privacy"))
                Sounds.playError()
                Permissions.openMicrophoneSettings()
                return
            }
            // 首次授权会弹系统窗口并打断焦点，授权期间这一次输入不可靠；
            // 统一让用户再触发一次，避免"历史里有但没粘贴进输入框"。
            if !alreadyAuthorized {
                self.overlay.flashSuccess(tr("麦克风已授权，请再按一次开始",
                                             "Microphone granted — press once more to start"))
                Sounds.playSuccess()
                return
            }
            guard self.phase == .idle else { return }
            // 新一轮开始：把代数推进一格，上一轮任何还在路上的回调从此作废
            self.generation &+= 1
            let generation = self.generation
            self.inflightRequest = nil
            let frontmost = NSWorkspace.shared.frontmostApplication
            self.targetBundleID = frontmost?.bundleIdentifier ?? ""
            // 指令模式才读选区——普通输入完全不碰选区和剪贴板
            self.skillSession = skill
            self.targetSelection = skill ? SelectionReader.readSelectedText() : nil
            // AX 读不到选区（浏览器/Gmail、VSCode 等 Electron、微信/QQ 都接口残缺）→ ⌘C 兜底。
            // 异步不阻塞录音；保存并恢复剪贴板，非破坏性。AX 能直接读到的原生应用根本走不到这一步。
            if skill, self.targetSelection == nil {
                SelectionReader.readSelectedTextWithClipboardFallback { [weak self] text in
                    guard let self = self, self.isCurrent(generation),
                          self.phase == .recording else { return }
                    self.targetSelection = text
                }
            }
            // 用户说话期间把到 API 的 DNS+TLS 握手做完，润色/指令请求省下首包延迟
            LLMClient.prewarm()
            self.recorder.onLevel = { [weak self] level in
                DispatchQueue.main.async {
                    self?.overlay.state.pushLevel(level)
                }
            }
            // 录音中途设备变更且无法恢复时的出口（主线程回调）
            self.recorder.onError = { [weak self] error in
                self?.handleAudioFault(error.message)
            }
            self.audioFaultNote = nil
            do {
                try self.recorder.start()
            } catch {
                let message = (error as? MTError)?.message ?? error.localizedDescription
                self.overlay.flashError(message)
                Sounds.playError()
                return
            }
            self.phase = .recording
            Log.info("Recording start skill=\(skill) target=\(self.targetBundleID)")
            self.overlay.showRecording(label: skill ? tr("正在听指令…", "Listening for command…")
                                                    : tr("正在听…", "Listening…"))
            Sounds.playStart()
        }
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        let samples = recorder.stop()
        let duration = Double(samples.count) / 16000.0

        // 太短当作误触
        guard duration >= 0.4 else {
            Log.info("Recording stop discarded duration=\(String(format: "%.2f", duration))s (<0.4s)")
            phase = .idle
            // 是设备变更把录音打断的就说清楚，别让用户以为是自己按错了
            if let fault = takeAudioFaultNote() {
                overlay.flashError(fault)
                Sounds.playError()
            } else {
                overlay.hide()
            }
            return
        }

        // 几乎无声（误触或没说话）：不送识别——空音频会诱发模型把热词上下文"复读"成识别结果
        let peak = samples.reduce(0) { max($0, abs($1)) }
        guard peak >= 0.012 else {
            Log.info("Recording stop silence-gated duration=\(String(format: "%.2f", duration))s peak=\(String(format: "%.4f", peak))")
            phase = .idle
            overlay.flashError(takeAudioFaultNote() ?? tr("没有听到内容", "Nothing heard"))
            return
        }

        Log.info("Recording stop duration=\(String(format: "%.2f", duration))s peak=\(String(format: "%.4f", peak))")
        phase = .processing
        overlay.showProcessing(tr("识别中…", "Transcribing…"))
        let isColdStart = !QwenEngine.shared.isModelReady
        let tASR = DispatchTime.now()
        let generation = self.generation

        // 识别本身停不下来（MLX 一次解码到底），取消靠"丢结果"：代数对不上就当这轮没发生过
        QwenEngine.shared.transcribe(samples: samples) { [weak self] result in
            guard let self = self, self.isCurrent(generation) else { return }
            switch result {
            case .failure(let error):
                Log.error("Transcription failed: \(error.message)")
                self.phase = .idle
                self.overlay.flashError(error.message)
                Sounds.playError()
            case .success(let transcribed):
                Log.info("Timing ASR=\(Log.ms(since: tASR))ms cold=\(isColdStart) chars=\(transcribed.count)")
                // 词汇表"错写=正写"硬替换：进入润色/指令之前先做确定性纠正
                let rawText = TextPostProcessor.applyVocabReplacements(transcribed)
                guard !rawText.isEmpty else {
                    self.phase = .idle
                    self.overlay.flashError(tr("没有听到内容", "Nothing heard"))
                    return
                }
                // 指令模式：这次说的话就是命令。普通输入永远不做指令解析。
                if self.skillSession {
                    self.skillSession = false
                    // 指令模式要跑 LLM。没配 API Key 时，明确提示用户「轻点」做纯语音输入（无需 Key），
                    // 而不是长按——长按进的是需要 Key 的指令模式。教用户用对手势，不做剪贴板兜底。
                    if KeychainHelper.loadAPIKey() == nil {
                        let keyName = Settings.shared.hotkey.displayName
                        self.phase = .idle
                        self.overlay.flashError(
                            tr("指令模式需配置 API Key；纯语音输入请「轻点」\(keyName)（而非长按）",
                               "Command mode needs an API key. For dictation, tap \(keyName) (don't hold)"))
                        Sounds.playError()
                        return
                    }
                    self.runSkillSession(rawText: rawText, isColdStart: isColdStart,
                                         generation: generation)
                    return
                }
                let level = Settings.shared.polishLevel
                if level != .off, KeychainHelper.loadAPIKey() != nil {
                    self.overlay.showProcessing(tr("润色中…", "Polishing…"))
                    let tPolish = DispatchTime.now()
                    self.inflightRequest = PolishService.polish(rawText, level: level) { [weak self] polished, failure in
                        guard let self = self, self.isCurrent(generation) else { return }
                        self.inflightRequest = nil
                        Log.info("Timing polish=\(Log.ms(since: tPolish))ms model=\(Settings.shared.currentPolishModel) ok=\(polished != nil)")
                        if let polished = polished {
                            self.deliver(raw: rawText, final: polished,
                                         note: tr("已输入", "Inserted"),
                                         allowClipboardRestore: !isColdStart)
                        } else {
                            self.deliver(raw: rawText, final: rawText,
                                         note: tr("润色失败（", "Polish failed (")
                                             + (failure ?? tr("未知", "unknown"))
                                             + tr("），已输出识别原文", ") — raw transcript inserted"),
                                         warning: true,
                                         allowClipboardRestore: !isColdStart)
                        }
                    }
                } else {
                    self.deliver(raw: rawText, final: rawText,
                                 note: tr("已输入", "Inserted"),
                                 allowClipboardRestore: !isColdStart)
                }
            }
        }
    }

    // MARK: - V3 语音技能（仅指令模式进入）

    /// 指令分发：显式说「帮我回复…」→ 直通草拟回复；有选区 → 模型自判意图（改写/回复/新写）；
    /// 没选区 → 自由指令
    private func runSkillSession(rawText: String, isColdStart: Bool, generation: Int) {
        Log.info("Skill dispatch selection=\(targetSelection.map { "\($0.count)chars" } ?? "nil") app=\(targetBundleID)")
        if SkillRouter.isReplyTrigger(rawText) {
            runReplyDraft(instruction: rawText, raw: rawText, generation: generation)
            return
        }
        if let selection = targetSelection {
            runSelectionCommand(selection: selection, instruction: rawText, raw: rawText,
                                isColdStart: isColdStart, generation: generation)
            return
        }
        // 没选区：当作自由指令——口述任务（草拟邮件/翻译/提问…），结果粘贴到光标处
        runFreeform(instruction: rawText, raw: rawText, isColdStart: isColdStart,
                    generation: generation)
    }

    /// 技能：自由指令——指令模式下的"万能入口"
    private func runFreeform(instruction: String, raw: String, isColdStart: Bool, generation: Int) {
        overlay.showProcessing(tr("执行指令中…", "Running command…"))
        inflightRequest = AgentService.freeform(instruction: instruction) { [weak self] result, failure in
            guard let self = self, self.isCurrent(generation) else { return }
            self.inflightRequest = nil
            if let result = result {
                self.deliver(raw: raw, final: result, note: tr("已输入指令结果", "Command result inserted"),
                             allowClipboardRestore: !isColdStart)
            } else {
                self.phase = .idle
                self.overlay.flashError(tr("指令执行失败（", "Command failed (") + (failure ?? tr("未知", "unknown")) + tr("）", ")"))
                Sounds.playError()
            }
        }
    }

    /// 技能：有选区的指令——模型自判意图后按意图投递：
    /// 改写 → 粘贴替换选区；回复 → 草稿进剪贴板；新写 → 粘贴到光标处；
    /// 意图解析失败 → 结果进剪贴板（绝不误覆盖选区）
    private func runSelectionCommand(selection: String, instruction: String, raw: String,
                                     isColdStart: Bool, generation: Int) {
        overlay.showProcessing(tr("执行指令中…", "Running command…"))
        // 微信/QQ 的选区是消息记录（对方的话），物理上不存在"原地改写"——把这个事实告诉模型
        let chatContext = Self.poorAXApps.contains(targetBundleID)
        inflightRequest = AgentService.runOnSelection(selection, instruction: instruction, chatContext: chatContext) { [weak self] action, result, failure in
            guard let self = self, self.isCurrent(generation) else { return }
            self.inflightRequest = nil
            guard let result = result else {
                self.phase = .idle
                self.overlay.flashError(tr("指令执行失败（", "Command failed (") + (failure ?? tr("未知", "unknown")) + tr("）", ")"))
                Sounds.playError()
                return
            }
            switch action {
            case .modify:
                self.deliver(raw: raw, final: result, note: tr("已替换选中文本", "Selection replaced"),
                             allowClipboardRestore: !isColdStart)
            case .new:
                self.deliver(raw: raw, final: result, note: tr("已输入指令结果", "Command result inserted"),
                             allowClipboardRestore: !isColdStart)
            case .reply:
                self.copyToClipboard(raw: raw, result: result,
                                     note: tr("回复草稿已复制——点到输入框按 ⌘V", "Reply draft copied — click the input field and press ⌘V"))
            case nil:
                // 意图行没解析出来：进剪贴板最安全，不碰选区
                self.copyToClipboard(raw: raw, result: result,
                                     note: tr("结果已复制到剪贴板——按 ⌘V 粘贴", "Result copied — press ⌘V to paste"))
            }
        }
    }

    /// 结果进剪贴板（不自动粘贴），记录历史并提示
    private func copyToClipboard(raw: String, result: String, note: String) {
        phase = .idle
        let final = TextPostProcessor.applyVocabReplacements(TextPostProcessor.fixMixedPunctuation(result))
        HistoryStore.shared.add(raw: raw, polished: final)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(final, forType: .string)
        overlay.flashSuccess(takeAudioFaultNote().map { $0 + tr("；", "; ") + note } ?? note)
        Sounds.playSuccess()
    }

    /// 技能：帮我回复——基于选中的对方消息草拟回复。
    /// 安全策略：不自动粘贴（焦点通常在消息区而非输入框），复制到剪贴板由用户 ⌘V。
    private func runReplyDraft(instruction: String, raw: String, generation: Int) {
        if let context = targetSelection {
            executeReplyDraft(context: context, instruction: instruction, raw: raw,
                              generation: generation)
            return
        }
        // AX 没读到：此刻焦点仍在目标应用、选区还在，用 ⌘C 兜底再试一次
        overlay.showProcessing(tr("读取选中内容…", "Reading selection…"))
        SelectionReader.readSelectedTextWithClipboardFallback { [weak self] context in
            guard let self = self, self.isCurrent(generation) else { return }
            guard let context = context else {
                self.phase = .idle
                self.overlay.flashError(tr("读不到选中内容：请重新选中要回复的消息再试", "Could not read selection — reselect the message and try again"))
                Sounds.playError()
                return
            }
            self.executeReplyDraft(context: context, instruction: instruction, raw: raw,
                                   generation: generation)
        }
    }

    private func executeReplyDraft(context: String, instruction: String, raw: String,
                                   generation: Int) {
        overlay.showProcessing(tr("草拟回复中…", "Drafting reply…"))
        inflightRequest = AgentService.replyDraft(context: context, instruction: instruction) { [weak self] result, failure in
            guard let self = self, self.isCurrent(generation) else { return }
            self.inflightRequest = nil
            if let result = result {
                self.copyToClipboard(raw: raw, result: result,
                                     note: tr("回复草稿已复制——点到输入框按 ⌘V", "Reply draft copied — click the input field and press ⌘V"))
            } else {
                self.phase = .idle
                self.overlay.flashError(tr("草拟失败（", "Draft failed (") + (failure ?? tr("未知", "unknown")) + tr("）", ")"))
                Sounds.playError()
            }
        }
    }

    private func deliver(raw: String, final text: String, note: String, warning: Bool = false,
                         allowClipboardRestore: Bool = true) {
        let finalText = TextPostProcessor.applyVocabReplacements(TextPostProcessor.fixMixedPunctuation(text))
        HistoryStore.shared.add(raw: raw, polished: finalText)
        phase = .idle
        // 录音被设备变更提前掐断时，把原因并进结果提示：用户得知道这只是"半句"
        let note = takeAudioFaultNote().map { $0 + tr("；", "; ") + note } ?? note
        Log.info("Deliver start chars=\(finalText.count) target=\(targetBundleID)")
        TextInserter.insert(finalText, targetBundleID: targetBundleID,
                            allowClipboardRestore: allowClipboardRestore,
                            conservativePaste: !allowClipboardRestore) { [weak self] outcome in
            guard let self = self else { return }
            Log.info("Deliver outcome=\(outcome == .pasted ? "pasted" : "clipboardOnly")")
            switch outcome {
            case .pasted:
                if warning {
                    self.overlay.flashError(note)
                } else {
                    self.overlay.flashSuccess(note)
                }
                Sounds.playSuccess()
            case .clipboardOnly:
                self.overlay.flashError(tr("窗口已切换，文本已复制到剪贴板——按 ⌘V 粘贴", "Window changed — text copied to clipboard, press ⌘V to paste"))
                Sounds.playError()
            }
        }
    }

}
