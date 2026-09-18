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
    /// 本次录音是否为"指令模式"（按住快捷键满 0.6s 后就地升级）
    private var skillSession = false
    /// 本次录音是否由热键按下触发（按下即录）。只有这种会话才可能升级成指令模式，
    /// 也只有它会在"被当成修饰键用"时被静默丢弃
    private var pressSession = false
    /// 本轮录音的附注（设备变更提前结束 / 到了时长上限 / 静音自动停）：收尾时并进结果提示，
    /// 让用户知道这一段为什么是这样结束的。每条只提示一次，绝不泄漏到下一次录音
    private var sessionNotes: [String] = []
    /// 录音起点与电平闸门状态（全部只在主线程读写：闸门跑在录音电平回调里，
    /// 不给音频线程添任何负担）
    private var recordingStartedAt: Date?
    private var recordingLabel = ""
    private var softHintShown = false
    private var speechDetected = false
    private var lastLoudAt: Date?
    /// 本次录音生效的静音自动停秒数（录音开始时取一次快照：录到一半改设置不该影响这一段）
    private var autoStopSilence: Double = 0
    /// 会话代数：每开一轮、每取消一次都自增。所有异步回调（ASR / 润色 / 指令 / 选区兜底）
    /// 都带着发起时的代数回来，对不上就整条丢弃——取消之后绝不能再往光标里插入任何东西。
    private var generation = 0
    /// 当前在飞的 LLM 请求，Esc 取消时直接掐断（省下最坏几十秒的干等）
    private var inflightRequest: LLMRequestHandle?
    /// 伪流式预览（P13）的状态，全部只在主线程读写。
    /// 纪律：草稿只进悬浮窗，永远不进目标应用；最终文字永远来自松手后那一遍完整识别。
    private var previewEnabled = false
    /// 在飞的那一遍预览解码（可取消：松手时立刻让出 GPU 给最终识别）
    private var previewTask: Task<Void, Never>?
    /// 下一次预览的最小间隔：按上一次实测耗时自适应，慢机器/长音频自动放慢，绝不堆积
    private var previewInterval: Double = 1.5
    /// 当前预览窗口在整段录音里的起始采样下标（窗口满了就往后滚，已定稿的文字留在 previewCommitted）
    private var previewWindowStart = 0
    private var previewCommitted = ""

    /// 「换回识别原文」的记忆（P9）：只记"纯听写 + 润色确实改了字 + 确实粘进去了"的那一次。
    /// 指令模式不记——那里的 raw 是用户的口令（"翻译成英文"），拿它覆盖结果毫无意义。
    private struct RevertCandidate {
        let raw: String
        let final: String
        let bundleID: String
        let at: Date
    }
    /// 菜单要问「现在能不能换回原文」，答案分三档：没得撤 / 有但用户切走了 / 可以撤
    struct RevertOffer {
        /// 前台仍是当时那个应用 → 菜单项可点
        let ready: Bool
        /// 目标应用名，灰着的时候告诉用户该切回哪儿
        let appName: String
    }
    private var revertCandidate: RevertCandidate?

    /// 无障碍接口残缺、读选区需要 ⌘C 兜底的应用
    private static let poorAXApps: Set<String> = [
        "com.tencent.xinWeChat", "com.tencent.qq",
    ]

    /// 录音时长闸门：2 分钟给一句软提示，5 分钟硬上限。到上限是"自动收尾"而不是丢弃——
    /// 用户对着麦克风说了五分钟，凭什么一个字都不给他。
    private static let softHintSeconds: Double = 120
    private static let maxRecordingSeconds: Double = 300
    /// 静音判据的电平阈值（AudioRecorder 送来的是 min(1, rms*14)）。比"没听到内容"的
    /// 闸门宽松些：这里只是判断"还在说吗"，判错的代价只是提前收尾。
    private static let silenceLevelThreshold: Float = 0.08

    /// 伪流式预览的节奏：窗口最多 20s（再长解码就拖沓，且对预览毫无意义），
    /// 每段至少 1.5s 才值得跑一遍，基础间隔 1.5s，实测慢了就退到最多 5s 一次。
    private static let previewWindowSeconds: Double = 20
    private static let previewMinChunkSeconds: Double = 1.5
    private static let previewBaseInterval: Double = 1.5
    private static let previewMaxInterval: Double = 5.0

    /// 「换回识别原文」的有效期：过了就忘掉。撤销依赖目标应用的 undo 栈，
    /// 时间一长用户早就编辑过别的东西了，那时候再 ⌘Z 会撤错东西。
    private static let revertWindowSeconds: Double = 60

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

    /// 热键按下（此刻还不知道用户要听写还是要下指令）：立刻开录。
    /// 判定推迟到 0.6s——但音频从按下那一刻就在采，指令模式不再丢开口的前半秒。
    func pressStart() {
        guard phase == .idle else { return }
        startRecording(fromPress: true)
    }

    /// 按住满 0.6s：把正在录的这一段就地升级为指令模式。
    /// 录音不中断、波形不重置，用户完全无感，只是标签换成"正在听指令…"。
    func holdPromote() {
        guard phase == .recording, pressSession, !skillSession else { return }
        skillSession = true
        recordingLabel = tr("正在听指令…", "Listening for command…")
        overlay.updateRecordingLabel(currentRecordingLabel())
        Log.info("Hold promoted to command mode selection=\(targetSelection == nil ? "none" : "ax")")
        // AX 读不到选区（浏览器/Gmail、VSCode 等 Electron、微信/QQ 都接口残缺）→ 现在才 ⌘C 兜底。
        // 判定成指令之后才做，纯听写路径一个字都不会碰用户的剪贴板。
        guard targetSelection == nil else { return }
        let generation = self.generation
        SelectionReader.readSelectedTextWithClipboardFallback { [weak self] text in
            guard let self = self, self.isCurrent(generation),
                  self.phase == .recording else { return }
            self.targetSelection = text
        }
    }

    func skillHoldEnd() {
        if phase == .recording { finishRecording() }
    }

    /// 热键被当成普通修饰键用了（按住期间敲了别的键）：按下即录的那一段必须作废。
    /// 静默丢弃——用户本来就没打算录音，这时候再响一次取消音只是噪音。
    func abortPressSession() {
        guard pressSession else { return }
        if phase == .recording {
            Log.info("Press-session discarded (hotkey used as a modifier) "
                     + "duration=\(String(format: "%.2f", recorder.recordedDuration))s")
            _ = recorder.stop()
        } else {
            // 还卡在权限回调里没真正开录：推进代数把那次启动丢掉即可
            Log.info("Press-session discarded before recording began")
        }
        endSession()
        overlay.hide()
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
        stopLivePreview()
        inflightRequest?.cancel()
        inflightRequest = nil
        skillSession = false
        pressSession = false
        targetSelection = nil
        sessionNotes = []
        recordingStartedAt = nil
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
        addSessionNote(message)
        finishRecording()
    }

    private func addSessionNote(_ note: String) {
        guard !sessionNotes.contains(note) else { return }
        sessionNotes.append(note)
    }

    /// 取出并清空本轮附注——每条只提示一次，绝不泄漏到下一次录音
    private func takeSessionNote() -> String? {
        defer { sessionNotes = [] }
        return sessionNotes.isEmpty ? nil : sessionNotes.joined(separator: tr("；", "; "))
    }

    /// 录音中悬浮窗该显示的文案：基础标签（听写/指令）+ 超过 2 分钟时的软提示
    private func currentRecordingLabel() -> String {
        softHintShown ? recordingLabel + tr("（已录 2 分钟）", " (2 min recorded)")
                      : recordingLabel
    }

    /// 录音时长上限与静音自动停：复用录音电平回调（约每 85ms 一次）在主线程判断，
    /// 音频线程什么都不用多做。
    private func checkRecordingLimits(level: Float) {
        guard phase == .recording, let started = recordingStartedAt else { return }
        let now = Date()
        if level >= Self.silenceLevelThreshold {
            speechDetected = true
            lastLoudAt = now
        }
        let elapsed = now.timeIntervalSince(started)

        if elapsed >= Self.maxRecordingSeconds {
            Log.warn("Recording auto-finish: max duration \(Int(Self.maxRecordingSeconds))s reached")
            addSessionNote(tr("已到最长录音时长，自动收尾", "Maximum recording length reached — wrapped up"))
            finishRecording()
            return
        }

        if !softHintShown, elapsed >= Self.softHintSeconds {
            softHintShown = true
            Log.info("Recording soft hint shown at \(Int(elapsed))s")
            overlay.updateRecordingLabel(currentRecordingLabel())
        }

        // 静音自动停：默认关闭（0）。开了也要先真的听到过人声才算数——
        // 否则"还没开口"会被当成"说完了"，一按就停。
        guard autoStopSilence > 0, speechDetected, let loud = lastLoudAt else { return }
        let quiet = now.timeIntervalSince(loud)
        guard quiet >= autoStopSilence else { return }
        Log.info("Recording auto-finish: silent for \(String(format: "%.1f", quiet))s"
                 + " (limit \(String(format: "%.1f", autoStopSilence))s)")
        addSessionNote(tr("检测到静音，已自动结束录音", "Silence detected — recording finished"))
        finishRecording()
    }

    // MARK: - 伪流式预览（录音中的灰字草稿）

    /// 录音一开始就起的预览循环。三道闸门：用户开关、模型已就绪、录够 1.5s。
    /// 任何一道不过就整轮不开——预览是锦上添花，绝不能拖慢或搅乱主流程。
    private func startLivePreview(generation: Int) {
        previewEnabled = false
        previewTask = nil
        previewInterval = Self.previewBaseInterval
        previewWindowStart = 0
        previewCommitted = ""
        guard Settings.shared.livePreview else { return }
        // 模型还在加载（或刚换过模型）时不开：预览绝不能替用户去等十几秒的加载，
        // 更不能和加载抢 GPU。这一轮就安静地按老样子走。
        guard QwenEngine.shared.isModelReady else {
            Log.info("Live preview skipped (model not ready)")
            return
        }
        previewEnabled = true
        scheduleNextPartial(after: Self.previewMinChunkSeconds, generation: generation)
    }

    /// 松手 / 取消 / 作废时都要调：先取消在飞的那一遍，最终识别才不用排在它后面。
    private func stopLivePreview() {
        guard previewEnabled || previewTask != nil else { return }
        previewEnabled = false
        // 解码循环里有 Task.checkCancellation()，取消后它会尽快让出 Qwen3ASRSTT 这个 actor
        previewTask?.cancel()
        previewTask = nil
        previewWindowStart = 0
        previewCommitted = ""
    }

    private func scheduleNextPartial(after delay: Double, generation: Int) {
        guard previewEnabled, phase == .recording, isCurrent(generation) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runPartial(generation: generation)
        }
    }

    /// 跑一遍预览解码。同一时刻只允许一遍在飞（previewTask != nil 就直接跳过），
    /// 下一遍永远在上一遍回来之后才排——预览之间不会互相排队，也不会和最终识别并发。
    private func runPartial(generation: Int) {
        guard previewEnabled, phase == .recording, isCurrent(generation), previewTask == nil else { return }
        // 还没听到过人声就别解码：对纯静音跑识别既浪费 GPU，又容易把热词上下文"复读"出来
        guard speechDetected else {
            scheduleNextPartial(after: Self.previewBaseInterval, generation: generation)
            return
        }
        let chunk = recorder.snapshot(fromSampleIndex: previewWindowStart)
        let chunkSeconds = Double(chunk.count) / 16000.0
        guard chunkSeconds >= Self.previewMinChunkSeconds else {
            scheduleNextPartial(after: Self.previewMinChunkSeconds - chunkSeconds + 0.1,
                                generation: generation)
            return
        }
        let consumed = chunk.count
        let windowFull = chunkSeconds >= Self.previewWindowSeconds
        previewTask = QwenEngine.shared.transcribePartial(samples: chunk) { [weak self] text, ms in
            guard let self = self else { return }
            self.previewTask = nil
            guard self.previewEnabled, self.phase == .recording, self.isCurrent(generation) else { return }
            Log.info("Timing partial=\(ms)ms audio=\(String(format: "%.1f", chunkSeconds))s"
                     + " ok=\(text != nil) chars=\(text?.count ?? 0)")
            // 这一遍占了多少 GPU 时间，下一遍就等多久（1.5 倍）：机器忙/音频长时自动放慢刷新，
            // 宁可草稿更新得稀疏，也不能让预览拖慢松手后的最终识别。
            let latency = Double(ms) / 1000.0
            self.previewInterval = min(Self.previewMaxInterval,
                                       max(Self.previewBaseInterval, latency * 1.5))
            if let text = text, !text.isEmpty {
                let draft = self.joinDraft(self.previewCommitted, text)
                self.overlay.showDraft(draft)
                if windowFull { self.previewCommitted = draft }
            }
            if windowFull {
                // 窗口满 20s：这一窗的文字（能拿到就）定稿成前缀，音频从这一窗的末尾接着往下看，
                // 既不重复解码也不丢音频。拿不到文字也照样往前滚，免得窗口无限变长。
                self.previewWindowStart += consumed
                Log.info("Preview window rolled at \(String(format: "%.0f", chunkSeconds))s")
            }
            self.scheduleNextPartial(after: max(0.4, self.previewInterval - latency),
                                     generation: generation)
        }
        if previewTask == nil {
            // 模型在这期间被卸载/换掉了：安静收摊，这一轮不再重试
            previewEnabled = false
            Log.info("Live preview stopped (model no longer ready)")
        }
    }

    /// 拼接已定稿前缀与新一窗的草稿：中文直接接，英文之间补一个空格
    private func joinDraft(_ prefix: String, _ text: String) -> String {
        guard !prefix.isEmpty else { return text }
        let needsSpace = (prefix.last?.isLetter == true && prefix.last?.isASCII == true)
            && (text.first?.isLetter == true && text.first?.isASCII == true)
        return prefix + (needsSpace ? " " : "") + text
    }

    // MARK: - 换回识别原文（P9）

    /// 取当前仍然有效的记忆；过期就地忘掉（菜单每次打开都会问一遍，等于顺手做了清理）
    private func freshRevertCandidate() -> RevertCandidate? {
        guard let candidate = revertCandidate else { return nil }
        guard Date().timeIntervalSince(candidate.at) <= Self.revertWindowSeconds else {
            revertCandidate = nil
            Log.info("Revert candidate expired after \(Int(Self.revertWindowSeconds))s")
            return nil
        }
        return candidate
    }

    /// 菜单问「现在能不能换回识别原文」。nil = 没得撤，菜单里这一项干脆不出现。
    func revertOffer() -> RevertOffer? {
        guard phase == .idle, let candidate = freshRevertCandidate(),
              !candidate.bundleID.isEmpty else { return nil }
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        // 打开状态栏菜单这个动作本身可能把 MicType 自己变成前台应用，那不算"用户切走了"；
        // 真要撤的时候 revertToRaw() 会先把目标应用拉回前台再按键。
        let ready = frontID == candidate.bundleID || frontID == Bundle.main.bundleIdentifier
        let name = NSRunningApplication
            .runningApplications(withBundleIdentifier: candidate.bundleID)
            .first?.localizedName ?? candidate.bundleID
        return RevertOffer(ready: ready, appName: name)
    }

    /// 用识别原文换掉刚刚插入的润色结果。两步：给目标应用发**一次** ⌘Z 撤掉那次粘贴，
    /// 等 150ms 让它把撤销做完，再把 raw 按正常路径插一遍（目标已在前台 → 走 fast 时序）。
    /// 只按一次 ⌘Z 是刻意的：撤销粒度各家不同，连发很容易吃掉用户自己之前的编辑。
    func revertToRaw() {
        guard phase == .idle, let candidate = freshRevertCandidate() else { return }
        // 用掉就忘：连点两次会变成"再撤一步"，那一步撤的是用户自己的东西
        revertCandidate = nil
        guard Permissions.isAccessibilityTrusted else {
            overlay.flashError(tr("请先开启辅助功能权限", "Enable Accessibility permission first"))
            Sounds.playError()
            return
        }
        Log.info("Revert to raw requested target=\(candidate.bundleID)"
                 + " raw=\(candidate.raw.count)chars polished=\(candidate.final.count)chars")
        TextInserter.bringToFront(candidate.bundleID) { [weak self] arrived in
            guard let self = self else { return }
            guard arrived else {
                Log.warn("Revert aborted: target app did not come to front")
                self.overlay.flashError(tr("没能切回原应用，撤销已取消",
                                           "Could not switch back to the target app — revert cancelled"))
                Sounds.playError()
                return
            }
            self.overlay.showProcessing(tr("换回识别原文…", "Restoring raw transcript…"))
            TextInserter.sendUndo {
                Log.info("Revert step 1/2: undo sent to \(candidate.bundleID)")
                // 给目标应用 150ms 把撤销做完再插入：紧接着粘贴的话，有些应用会把
                // 这次粘贴和撤销合并处理，结果两段文字叠在一起
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    TextInserter.insert(candidate.raw, targetBundleID: candidate.bundleID) { [weak self] outcome in
                        guard let self = self else { return }
                        Log.info("Revert step 2/2: raw inserted outcome="
                                 + (outcome == .pasted ? "pasted" : "clipboardOnly"))
                        // 这期间用户又按了热键的话，别去盖掉录音/处理中的悬浮窗
                        guard self.phase == .idle else { return }
                        switch outcome {
                        case .pasted:
                            self.overlay.flashSuccess(tr("已换回识别原文", "Raw transcript restored"))
                            Sounds.playSuccess()
                        case .clipboardOnly:
                            self.overlay.flashError(tr("识别原文已复制到剪贴板——按 ⌘V 粘贴",
                                                       "Raw transcript copied — press ⌘V to paste"))
                            Sounds.playError()
                        }
                    }
                }
            }
        }
    }

    var isRecording: Bool { phase == .recording }
    var isProcessing: Bool { phase == .processing }

    // MARK: - 流程

    /// 录音起点。fromPress = 由热键按下触发（按下即录，这一刻还没判定听写还是指令）；
    /// 菜单等其它入口触发的一律是纯听写，永远不读选区、不碰剪贴板。
    private func startRecording(fromPress: Bool = false) {
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
        // 授权回调期间这一轮可能已经被作废（按住时敲了别的键 → abortPressSession）
        let entryGeneration = generation
        pressSession = fromPress
        Permissions.ensureMicrophone { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.pressSession = false
                self.overlay.flashError(tr("没有麦克风权限，请在 系统设置 → 隐私 中开启",
                                           "No microphone access — enable it in System Settings → Privacy"))
                Sounds.playError()
                Permissions.openMicrophoneSettings()
                return
            }
            // 首次授权会弹系统窗口并打断焦点，授权期间这一次输入不可靠；
            // 统一让用户再触发一次，避免"历史里有但没粘贴进输入框"。
            if !alreadyAuthorized {
                self.pressSession = false
                self.overlay.flashSuccess(tr("麦克风已授权，请再按一次开始",
                                             "Microphone granted — press once more to start"))
                Sounds.playSuccess()
                return
            }
            guard self.phase == .idle, self.isCurrent(entryGeneration) else { return }
            // 新一轮开始：把代数推进一格，上一轮任何还在路上的回调从此作废
            self.generation &+= 1
            self.inflightRequest = nil
            let frontmost = NSWorkspace.shared.frontmostApplication
            self.targetBundleID = frontmost?.bundleIdentifier ?? ""
            // 按下这一刻永远先当听写：满 0.6s 才由 holdPromote 就地升级成指令模式
            self.skillSession = false
            self.targetSelection = nil
            self.sessionNotes = []
            // 用户说话期间把到 API 的 DNS+TLS 握手做完，润色/指令请求省下首包延迟
            LLMClient.prewarm()
            self.recorder.onLevel = { [weak self] level in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.overlay.state.pushLevel(level)
                    self.checkRecordingLimits(level: level)
                }
            }
            // 录音中途设备变更且无法恢复时的出口（主线程回调）
            self.recorder.onError = { [weak self] error in
                self?.handleAudioFault(error.message)
            }
            // 开始音必须在 recorder.start() 之前起头：反过来的话这一声会被自己的麦克风录进去，
            // 既污染识别（开头多出一段"叮"），也会骗过静音门。NSSound.play() 是异步的，
            // 它只是把声音排上队就立刻返回，所以这里不会推迟录音起点。
            // 代价：启动失败时用户已经听到了开始音，紧接着一声错误音——比丢字可接受得多。
            Sounds.playStart()
            do {
                try self.recorder.start()
            } catch {
                self.pressSession = false
                let message = (error as? MTError)?.message ?? error.localizedDescription
                self.overlay.flashError(message)
                Sounds.playError()
                return
            }
            self.phase = .recording
            self.recordingStartedAt = Date()
            self.softHintShown = false
            self.speechDetected = false
            self.lastLoudAt = nil
            self.autoStopSilence = Settings.shared.autoStopSilenceSeconds
            self.recordingLabel = tr("正在听…", "Listening…")
            Log.info("Recording start press=\(fromPress) target=\(self.targetBundleID)"
                     + " autoStopSilence=\(String(format: "%.0f", self.autoStopSilence))s")
            self.overlay.showRecording(label: self.recordingLabel)
            // 伪流式预览：录音期间每隔一会儿把"到目前为止"的音频解码一遍，灰字贴在波形下面。
            // 纯粹是给眼睛看的，永远不会插入到任何地方。
            self.startLivePreview(generation: self.generation)
            // 选区必须在录音起点快照（用户随后可能切走焦点）。这里只走 AX：纯读、非破坏性，
            // 绝不发 ⌘C——按下的时候还不知道这是不是指令，纯听写路径永远不该碰剪贴板。
            // 放在 recorder.start() 之后：目标应用的无障碍接口卡住时，至少音频已经在录了。
            if fromPress {
                self.targetSelection = SelectionReader.readSelectedText()
            }
        }
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        let samples = recorder.stop()
        // 先掐预览再往下走：最终那一遍识别要用的 GPU（actor）就在预览手上，
        // 越早取消，用户松手后等得越短
        stopLivePreview()
        recordingStartedAt = nil
        // 录音已结束，这一段再也不会被"当成修饰键用"而作废了
        pressSession = false
        let duration = Double(samples.count) / 16000.0

        // 太短当作误触
        guard duration >= 0.4 else {
            Log.info("Recording stop discarded duration=\(String(format: "%.2f", duration))s (<0.4s)")
            phase = .idle
            // 是设备变更把录音打断的就说清楚，别让用户以为是自己按错了
            if let fault = takeSessionNote() {
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
            overlay.flashError(takeSessionNote() ?? tr("没有听到内容", "Nothing heard"))
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
                            // 唯一开放「换回识别原文」的路径：纯听写 + 润色真的动了字
                            self.deliver(raw: rawText, final: polished,
                                         note: tr("已输入", "Inserted"),
                                         allowClipboardRestore: !isColdStart,
                                         revertible: true)
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
        overlay.flashSuccess(takeSessionNote().map { $0 + tr("；", "; ") + note } ?? note)
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

    /// revertible：这一次是不是"纯听写 + 润色"的结果——只有它值得提供「换回识别原文」。
    private func deliver(raw: String, final text: String, note: String, warning: Bool = false,
                         allowClipboardRestore: Bool = true, revertible: Bool = false) {
        let finalText = TextPostProcessor.applyVocabReplacements(TextPostProcessor.fixMixedPunctuation(text))
        HistoryStore.shared.add(raw: raw, polished: finalText)
        // 又插入了新东西 → 上一次的记忆立刻作废：⌘Z 撤的永远是"最后一次粘贴"，
        // 拿旧记忆去撤只会撤掉这一次的新文字
        revertCandidate = nil
        phase = .idle
        // 录音被设备变更提前掐断时，把原因并进结果提示：用户得知道这只是"半句"
        let note = takeSessionNote().map { $0 + tr("；", "; ") + note } ?? note
        // 目标应用在这里定格：回调回来时 targetBundleID 可能已经属于下一轮录音了
        let target = targetBundleID
        Log.info("Deliver start chars=\(finalText.count) target=\(target)")
        TextInserter.insert(finalText, targetBundleID: target,
                            allowClipboardRestore: allowClipboardRestore,
                            conservativePaste: !allowClipboardRestore) { [weak self] outcome in
            guard let self = self else { return }
            Log.info("Deliver outcome=\(outcome == .pasted ? "pasted" : "clipboardOnly")")
            // 只有"确实粘进去了"且"润色确实改了字"才记：没粘进去就无从 ⌘Z 撤起，
            // 一个字没改的话换回原文也是原地踏步
            if outcome == .pasted, revertible, finalText != raw, !target.isEmpty {
                self.revertCandidate = RevertCandidate(raw: raw, final: finalText,
                                                       bundleID: target, at: Date())
                Log.info("Revert available for \(Int(Self.revertWindowSeconds))s target=\(target)")
            }
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
