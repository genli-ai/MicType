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
    /// 录音开始时的前台应用（文字将粘贴到这个应用）
    private var targetBundleID = ""
    /// 录音开始时的选中文本（V3 语音技能用；读不到为 nil）
    private var targetSelection: String?
    /// 本次录音是否为"指令模式"（按住快捷键满 0.6s 后就地升级）
    private var skillSession = false
    /// 本次录音是否由热键按下触发（按下即录）。只有这种会话才可能升级成指令模式，
    /// 也只有它会在"被当成修饰键用"时被静默丢弃
    private var pressSession = false
    /// 「按下即录」的这一段是否已经对用户现身（开始音 + 悬浮窗 + 灰字预览）。
    /// 按下沿只开静音缓冲，手势确认（松手 = 轻点 / 满 0.6s = 指令）之后才现身——
    /// 否则把热键当修饰键用（右⌥+字母、⌘C/⌘V…）每按一次都要"叮"一声、闪一次悬浮窗。
    private var pressRevealed = false
    /// 按下沿发现的拦路问题：按下这一刻还不知道用户是要说话还是只把热键当修饰键用，
    /// 所以先记下来，等手势确认了再提示（3.3 之前每一次 ⌥+字母 都会响错误音并把引导窗抢到前台）
    private enum BlockedReason: String { case model, accessibility }
    private var pressBlockedReason: BlockedReason?
    /// 上一次「拦路问题」提示的时刻：同一类问题短时间内只提示一次，别让用户被连珠炮淹没
    private var lastBlockedPromptAt: Date?
    /// 指令模式下 ⌘C 兜底读选区所属的会话代数（nil = 没有在飞的兜底）。
    /// 兜底固定 0.35s 才回调，整段按住不到 ~0.95s 时它会晚于松手才回来，
    /// runSkillSession 必须等它，否则选区静默丢失、指令降级成"无选区自由指令"
    private var selectionProbeGeneration: Int?
    /// 等这次兜底回来才能继续的活儿（目前只有指令分发）
    private var selectionProbeWaiters: [() -> Void] = []
    /// 本轮录音的附注（设备变更提前结束 / 到了时长上限 / 静音自动停）：收尾时并进结果提示，
    /// 让用户知道这一段为什么是这样结束的。每条只提示一次，绝不泄漏到下一次录音
    private var sessionNotes: [String] = []
    /// 录音起点与电平闸门状态（全部只在主线程读写：闸门跑在录音电平回调里，
    /// 不给音频线程添任何负担）
    private var recordingStartedAt: Date?
    private var recordingLabel = ""
    private var softHintShown = false
    /// 自动收尾前 30 s 的预警是否已经给过（每轮一次）
    private var finishWarningShown = false
    /// 悬浮窗上那个计时器当前显示到第几秒：只有整秒变了才去动界面，
    /// 电平回调每 85ms 来一次，不挡一下等于每秒重排 12 次悬浮窗
    private var lastClockSecond = -1
    private var speechDetected = false
    private var lastLoudAt: Date?
    /// 开始音的回声闸门（到点时刻，nil = 没响过开始音）。Sounds.play 只是把声音排上队就返回，
    /// 而麦克风此刻已经在录，所以这一声"叮"必然被自己录进去。闸门内的电平一律不算"听到人声"——
    /// 否则用户还没开口，静音自动停就按"说完了"把录音收了；预览那道 speechDetected 闸门也会
    /// 被骗过去，拿一段近静音去解码（空音频最容易诱发热词复读）。
    private var levelGateUntil: Date?
    /// 开始音回声在**整段录音**里的采样区间（nil = 没响过开始音）。levelGateUntil 那道闸门只管
    /// 实时的 speechDetected 判定，对松手之后 SilenceGate 扫整段缓冲毫无作用——不把这段刨掉，
    /// 外放时判的就是 MicType 自己的"叮"而不是用户的声音。
    /// 用区间而不是"前 n 个采样"：「按下即录」那条路上开始音推迟到手势确认才响，落在整段中间。
    private var cueEchoRange: Range<Int>?
    /// 本次录音生效的静音自动停秒数（录音开始时取一次快照：录到一半改设置不该影响这一段）
    private var autoStopSilence: Double = 0
    /// 会话代数：每开一轮、每取消一次都自增。所有异步回调（ASR / 润色 / 指令 / 选区兜底）
    /// 都带着发起时的代数回来，对不上就整条丢弃——取消之后绝不能再往光标里插入任何东西。
    private var generation = 0
    /// 当前在飞的 LLM 请求，Esc 取消时直接掐断（省下最坏几十秒的干等）
    private var inflightRequest: LLMRequestHandle?
    /// 当前在飞的分段识别。Esc 按下时用它叫停**后续段落**（正在解码的那一段停不下来），
    /// 已经出来的段落照常交付 —— 长段口述最怕的就是"全没了"
    private var inflightTranscription: TranscriptionHandle?
    /// 润色之前先落进历史的那一条（见 HistoryStore.addRaw）：交付时补成最终文字，
    /// 交付不成也留着识别原文。nil = 这一轮还没落过（指令模式永远是 nil）
    private var pendingHistoryID: UUID?
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
    /// 本轮跑成功的预览解码遍数（进性能指标：预览跑得越多，最终识别越可能在排队等 GPU）
    private var partialCount = 0
    /// 本轮的耗时草稿（P20 性能指标）：识别/润色各阶段算完填一格，插入完成时提交进 Metrics。
    /// 只在主线程读写。取消 / 识别失败的那些轮不提交——它们没有完整的一条耗时可记。
    private var pendingMetric: SessionMetricDraft?

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

    /// 录音时长闸门：2 分钟起在悬浮窗上显示「已录 / 上限」的计时，10 分钟硬上限。
    /// 到上限是"自动收尾"而不是丢弃——用户对着麦克风说了十分钟，凭什么一个字都不给他。
    ///
    /// 上限从 5 分钟提到 10 分钟的依据（brief §3.3）：整段录音不再一次性喂给模型，
    /// 而是按 60 s 分段顺序识别（AudioSegmenter），峰值内存与单段成正比、和总长无关；
    /// 模型本身支持 1200 s，这里只用一半，留足余量。
    private static let softHintSeconds: Double = 120
    private static let maxRecordingSeconds: Double = 600
    /// 自动收尾前多久给预警：到点才知道有上限对用户毫无帮助，30 s 够说完一句话
    private static let preFinishWarningSeconds: Double = 30
    /// 静音判据的电平阈值（AudioRecorder 送来的是 min(1, rms*14)）。比"没听到内容"的
    /// 闸门宽松些：这里只是判断"还在说吗"，判错的代价只是提前收尾。
    private static let silenceLevelThreshold: Float = 0.08
    /// 开始音回声闸门的时长：自带提示音硬上限 200ms（scripts/generate_sounds.py），
    /// 留点余量按 0.35s 算——这段时间里用户几乎不可能已经说出第一个字。
    private static let startCueGateSeconds: Double = 0.35

    /// 伪流式预览的节奏：窗口最多 20s（再长解码就拖沓，且对预览毫无意义），
    /// 每段至少 1.5s 才值得跑一遍，基础间隔 1.5s，实测慢了就退到最多 5s 一次。
    private static let previewWindowSeconds: Double = 20
    private static let previewMinChunkSeconds: Double = 1.5
    private static let previewBaseInterval: Double = 1.5
    private static let previewMaxInterval: Double = 5.0
    /// 两遍预览之间的最小空闲间隙，以及"按实测耗时成比例"的那条下限（半个解码时长）
    private static let previewMinIdleSeconds: Double = 0.4
    private static let previewIdleLatencyRatio: Double = 0.5

    /// 「换回识别原文」的有效期：过了就忘掉。撤销依赖目标应用的 undo 栈，
    /// 时间一长用户早就编辑过别的东西了，那时候再 ⌘Z 会撤错东西。
    private static let revertWindowSeconds: Double = 60

    /// 「模型没下载 / 没有辅助功能权限」这类提示的节流窗口：用户拿热键当修饰键用时
    /// 一分钟能按几十次，每次都弹一遍等于把人堵死
    private static let blockedPromptThrottleSeconds: Double = 10

    // MARK: - 入口

    init() {
        // 点悬浮窗上的「⎋ 取消」＝按 Esc：出口只有一个实现，两条路进同一个 cancel()
        overlay.onCancelTapped = { [weak self] in self?.cancel() }
    }

    func toggle() {
        switch phase {
        case .idle: startRecording()
        case .recording: finishRecording()
        case .processing: gestureWhileBusy()
        }
    }

    /// 处理中/录音中收到按住手势：不能开新一轮，但绝不静默吞掉手势——
    /// 明确告诉用户在忙，以及出口在哪（Esc）。
    func gestureWhileBusy() {
        switch phase {
        case .processing:
            Log.info("Gesture ignored while processing")
            overlay.flashOverProcessing(tr("处理中… 按 Esc 取消", "Processing… press Esc to cancel"))
            Sounds.playError()
        case .recording:
            // 按下时是上一段录音、现在还在录：松开会走 release-stop，这里不该插嘴
            return
        case .idle:
            // 按下时在忙、0.6s 到点时那一轮恰好结束的竞态（约 600ms 的窗口）：
            // 这次按住没开录（现在补开也缺了开口的半秒），与其静默吞掉，不如叫用户重按一次
            Log.info("Hold gesture landed between rounds")
            overlay.flashNotice(tr("上一轮刚结束，请重新按一次",
                                   "Previous round just finished — press again"))
            Sounds.playCancel()
        }
    }

    /// 热键按下（此刻还不知道用户要听写还是要下指令）：立刻开录，但**什么都不表现出来**。
    /// 判定推迟到 0.6s——音频从按下那一刻就在采，指令模式不再丢开口的前半秒；
    /// 开始音 / 悬浮窗 / 灰字预览 / 读选区一律推迟到 revealPressSession()。
    func pressStart() {
        guard phase == .idle else { return }
        pressRevealed = false
        pressBlockedReason = nil
        // 模型与权限的提示同样推迟：按下这一刻用户很可能只是拿热键当修饰键用，
        // 这时候响错误音、把引导窗抢到前台，等于让他连字都打不成
        guard QwenEngine.shared.isModelAvailable else {
            pressBlockedReason = .model
            pressSession = true
            return
        }
        guard Permissions.isAccessibilityTrusted else {
            pressBlockedReason = .accessibility
            pressSession = true
            return
        }
        startRecording(fromPress: true)
    }

    /// 0.6s 内松开 = 轻点，手势确认成纯听写：这一段录音到这一刻才现身。
    func pressTapConfirm() {
        if let reason = pressBlockedReason {
            reportPressBlocked(reason)
            return
        }
        revealPressSession()
    }

    /// 让「按下即录」的这一段对用户现身：开始音 + 悬浮窗 + 灰字预览。
    private func revealPressSession() {
        guard phase == .recording, pressSession, !pressRevealed else { return }
        pressRevealed = true
        // 开始音只能放在这里。代价是它会被已经在录的麦克风收进去一小段（≤0.6s 处的一声"叮"）——
        // 比"每次把热键当修饰键用都响一声"可接受得多。紧接着的 armStartCueGate() 开一道闸门：
        // 这一声期间的电平既不算"听到人声"（实时判定），对应的采样区间也会在松手时
        // 从静音闸门的统计里刨掉（否则外放时判的是自己的提示音）。
        Sounds.playStart()
        armStartCueGate()
        overlay.showRecording(label: currentRecordingLabel())
        startLivePreview(generation: generation)
    }

    /// 开一道开始音回声闸门。提示音关着就不用开：没有声音就没有回声，
    /// 白白吞掉开头 0.35s 的人声判定没必要。
    private func armStartCueGate() {
        guard Settings.shared.playSounds else {
            levelGateUntil = nil
            cueEchoRange = nil
            return
        }
        let now = Date()
        levelGateUntil = now.addingTimeInterval(Self.startCueGateSeconds)
        // 同一道闸门换算成采样下标，留给 finishRecording 里的 SilenceGate 用
        guard let started = recordingStartedAt else { return }
        let from = max(0, now.timeIntervalSince(started))
        cueEchoRange = Int(from * 16000)..<Int((from + Self.startCueGateSeconds) * 16000)
    }

    /// 按下沿记下的拦路问题，等手势确认了才提示；同一问题 10 秒内只提示一次。
    private func reportPressBlocked(_ reason: BlockedReason) {
        pressBlockedReason = nil
        pressSession = false
        if let last = lastBlockedPromptAt,
           Date().timeIntervalSince(last) < Self.blockedPromptThrottleSeconds {
            Log.info("Press blocked (\(reason.rawValue)) — prompt throttled")
            return
        }
        lastBlockedPromptAt = Date()
        Log.info("Press blocked (\(reason.rawValue))")
        switch reason {
        case .model:
            // 文案要和实际落点一致：模型缺失时 onNeedSettings 打开的是引导向导的下载页
            // （标题「欢迎使用 MicType」），不是设置窗口——说"请在设置中下载"只会让用户
            // 以为弹错了窗口，去关掉它再自己找设置。
            overlay.flashError(tr("识别模型未下载——已为你打开下载页",
                                  "Speech model not downloaded — opening the download page"))
            Sounds.playError()
            onNeedSettings?()
        case .accessibility:
            promptAccessibilityNeeded()
        }
    }

    /// 没有辅助功能权限时的统一提示：说清在哪儿开，并把那一页直接打开。
    /// 不提"重启 MicType"——现在的 macOS 授权即时生效，让用户白重启一次只会更迷惑。
    private func promptAccessibilityNeeded() {
        Permissions.promptAccessibility()
        overlay.flashError(tr("请在 系统设置 → 隐私与安全性 → 辅助功能 中开启 MicType",
                              "Enable MicType in System Settings → Privacy & Security → Accessibility"))
        Sounds.playError()
        Permissions.openAccessibilitySettings()
    }

    /// 按住满 0.6s：把正在录的这一段就地升级为指令模式，并让它现身。
    /// 录音不中断、波形不重置，用户完全无感，只是标签是"正在听指令…"。
    func holdPromote() {
        if let reason = pressBlockedReason {
            reportPressBlocked(reason)
            return
        }
        guard phase == .recording, pressSession, !skillSession else { return }
        skillSession = true
        recordingLabel = tr("正在听指令…", "Listening for command…")
        if pressRevealed {
            overlay.updateRecordingLabel(currentRecordingLabel())
        } else {
            revealPressSession()
        }
        // 选区也推迟到这里才读：轻点是纯听写，根本用不到选区；而且按下沿做同步 AX 读取
        // 会被 Electron / 挂起的应用卡住主线程几百毫秒——把热键当修饰键用时每按一次卡一次。
        targetSelection = SelectionReader.readSelectedText()
        Log.info("Hold promoted to command mode selection=\(targetSelection == nil ? "none" : "ax")")
        // AX 读不到选区（浏览器/Gmail、VSCode 等 Electron、微信/QQ 都接口残缺）→ 现在才 ⌘C 兜底。
        // 判定成指令之后才做，纯听写路径一个字都不会碰用户的剪贴板。
        guard targetSelection == nil else { return }
        let generation = self.generation
        selectionProbeGeneration = generation
        SelectionReader.readSelectedTextWithClipboardFallback { [weak self] text in
            guard let self = self else { return }
            // 代数对不上说明这一轮已经被取消或换代了（endSession 会把它清空）
            guard self.selectionProbeGeneration == generation else { return }
            self.selectionProbeGeneration = nil
            // 这里绝不能再要求 phase == .recording：用户完全可能在升级后不到 0.35s 就松手，
            // 那时 phase 已是 .processing，结果被丢掉 → 选区静默丢失，指令降级成自由指令
            // （3.2.18 修过的那类失败）。代数已经挡住了取消和新一轮，phase 这一条多余且有害。
            if self.phase != .idle { self.targetSelection = text }
            let waiters = self.selectionProbeWaiters
            self.selectionProbeWaiters = []
            waiters.forEach { $0() }
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
            // 还卡在权限回调里没真正开录，或按下沿就被模型/权限拦下了：推进代数丢掉那次启动即可
            Log.info("Press-session discarded before recording began")
        }
        let wasRevealed = pressRevealed
        endSession()
        // 没现身过就没有属于自己的悬浮窗可关——这时候 hide() 只会把上一轮还在闪的
        // 「已输入」提示擦掉（把热键当修饰键用的那些次必须完全隐形）
        if wasRevealed { overlay.hide() }
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
            // 分段识别到一半按 Esc：已经识别出来的段落不跟着一起扔。叫停**后续段落**，
            // 让这一轮照常交付 1..k 段，并在提示里说清尾巴没转。owner 的原话是
            // "之前的语音都保留不下来"——一段三分钟的口述里前两分钟是真东西，不是垃圾。
            // 三条限制：必须已经出过至少一段（没有就是普通取消）、必须是纯听写
            // （半句指令绝不能拿去执行）、同一轮只认第一次（再按一次就是彻底取消）。
            if let handle = inflightTranscription, !handle.isCancelled,
               handle.completedSegments > 0, !skillSession {
                Log.info("Transcription stopped by user after \(handle.completedSegments) segment(s)")
                handle.cancel()
                overlay.updateProcessing(label: tr("收尾中…", "Wrapping up…"))
                Sounds.playCancel()
                return
            }
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
        // 彻底取消时连后续段落也别跑了：结果反正会被代数挡掉，白占 GPU
        inflightTranscription?.cancel()
        inflightTranscription = nil
        // 指针清掉，但**不动已经写进历史的那一条**——那正是"取消也不丢字"的落点
        pendingHistoryID = nil
        skillSession = false
        pressSession = false
        pressRevealed = false
        pressBlockedReason = nil
        selectionProbeGeneration = nil
        selectionProbeWaiters = []
        targetSelection = nil
        sessionNotes = []
        recordingStartedAt = nil
        levelGateUntil = nil
        // 取消掉的这一轮不该留下半条耗时草稿给下一轮捡走
        pendingMetric = nil
        partialCount = 0
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

    /// 录音中悬浮窗该显示的文案：基础标签（听写/指令）+ 过了 2 分钟之后的「已录 / 上限」计时。
    /// 计时而不是一句静态提示：只说"已录 2 分钟"等于什么都没说——用户看不出还能说多久、
    /// 到点会发生什么，直到被自动收尾才第一次知道有上限。
    private func currentRecordingLabel() -> String {
        guard softHintShown, let started = recordingStartedAt else { return recordingLabel }
        let clock = Self.recordingTimeLabel(elapsed: Date().timeIntervalSince(started),
                                            limit: Self.maxRecordingSeconds)
        // 预警只加一句"就要收尾了"，不说"丢失"——到点是照常识别并插入，什么都不会丢
        if finishWarningShown {
            return recordingLabel + tr("（\(clock) · 即将自动收尾）", " (\(clock) · wrapping up soon)")
        }
        return recordingLabel + tr("（\(clock)）", " (\(clock))")
    }

    /// 「8:30 / 10:00」。纯函数、可单测：这行字是用户判断"还能说多久"的唯一依据，
    /// 超过上限时钉死在上限上（10:01 / 10:00 只会让人以为程序算错了）。
    static func recordingTimeLabel(elapsed: Double, limit: Double) -> String {
        clockText(min(max(elapsed, 0), limit)) + " / " + clockText(limit)
    }

    static func clockText(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// 整秒变了才去动悬浮窗（电平回调每 85ms 来一次）
    private func updateRecordingClock(elapsed: Double) {
        let second = Int(elapsed)
        guard second != lastClockSecond else { return }
        lastClockSecond = second
        overlay.updateRecordingLabel(currentRecordingLabel())
    }

    /// 录音时长上限与静音自动停：复用录音电平回调（约每 85ms 一次）在主线程判断，
    /// 音频线程什么都不用多做。
    private func checkRecordingLimits(level: Float) {
        guard phase == .recording, let started = recordingStartedAt else { return }
        let now = Date()
        // 开始音会被自己的麦克风录进去：闸门内的电平一律不算人声（见 levelGateUntil）。
        // 只挡"听到人声"这一条判定，时长上限/软提示照常走。
        if let gate = levelGateUntil, now >= gate { levelGateUntil = nil }
        if levelGateUntil == nil, level >= Self.silenceLevelThreshold {
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
        }
        if softHintShown {
            if !finishWarningShown, elapsed >= Self.maxRecordingSeconds - Self.preFinishWarningSeconds {
                finishWarningShown = true
                Log.info("Recording pre-finish warning at \(Int(elapsed))s")
            }
            updateRecordingClock(elapsed: elapsed)
        }

        // 指令模式（按住说话）豁免静音自动停：那里"松开"才是用户明确的结束信号，
        // 中途停一两秒想措辞是常态。截断的话，半句指令照样会被送去执行，
        // 用户还按着键说的后半句全部丢失，松开时 skillHoldEnd 又因为 phase 已变而空转。
        guard !skillSession else { return }
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
        // 切片的尾巴钉死在窗口上限：缓冲永远比窗口多出"一个轮询间隔 + 上一遍耗时"，
        // 不钉的话这一窗实际解码的是 20s + 间隔 + 耗时（白多两三成 GPU 时间，松手时
        // 最终识别还得等它让出 actor）。截掉的是尾巴、留给下一窗，一个采样都不丢。
        let chunk = recorder.snapshot(fromSampleIndex: previewWindowStart,
                                      maxCount: Int(Self.previewWindowSeconds * 16000))
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
            self.partialCount += 1
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
            self.scheduleNextPartial(after: Self.previewIdleDelay(interval: self.previewInterval,
                                                                  latency: latency),
                                     generation: generation)
        }
        if previewTask == nil {
            // 模型在这期间被卸载/换掉了：安静收摊，这一轮不再重试
            previewEnabled = false
            Log.info("Live preview stopped (model no longer ready)")
        }
    }

    /// 两遍预览之间该空多久。规矩：空闲间隙**随实测耗时增长**，机器越慢草稿越稀疏。
    /// 之所以要单独算：previewInterval 是"周期"且被 previewMaxInterval 封顶，直接拿
    /// 「周期 − 耗时」当间隙的话，耗时一过 3.3s 间隙反而越来越短、到 4.6s 就钉死在下限——
    /// 最该节流的慢机器上节流正好失效。所以再加一条按耗时成比例的下限（半个解码时长）。
    static func previewIdleDelay(interval: Double, latency: Double) -> Double {
        let proportional = max(latency, 0) * previewIdleLatencyRatio
        return max(previewMinIdleSeconds, max(interval - latency, proportional))
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
        // 整条撤销链是异步的（拉前台最多约 1.2s + ⌘Z + 150ms + 插入自己的时序），
        // 期间必须占住 phase：HotkeyManager 的 isRecording/isBusy 和 Esc 拦截都只看 phase，
        // 停在 .idle 的话用户等得不耐烦按一下热键就会开新一轮录音，而已经在飞的那次
        // raw 插入照样粘出去 → 光标处叠出两段文字。占住 phase 也顺带让 Esc 能取消这一段。
        phase = .processing
        // 被 Esc 取消（endSession 会推进代数）或被新一轮顶掉之后，下面的回调一律作废
        let entryGeneration = generation
        overlay.showProcessing(tr("换回识别原文…", "Restoring raw transcript…"))
        TextInserter.bringToFront(candidate.bundleID) { [weak self] arrived in
            guard let self = self, self.isCurrent(entryGeneration) else { return }
            guard arrived else {
                Log.warn("Revert aborted: target app did not come to front")
                self.phase = .idle
                self.overlay.flashError(tr("没能切回原应用，撤销已取消",
                                           "Could not switch back to the target app — revert cancelled"))
                Sounds.playError()
                return
            }
            TextInserter.sendUndo {
                guard self.isCurrent(entryGeneration) else { return }
                Log.info("Revert step 1/2: undo sent to \(candidate.bundleID)")
                // 给目标应用 150ms 把撤销做完再插入：紧接着粘贴的话，有些应用会把
                // 这次粘贴和撤销合并处理，结果两段文字叠在一起
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard self.isCurrent(entryGeneration) else {
                        Log.info("Revert aborted before insert (cancelled or a new round started)")
                        return
                    }
                    TextInserter.insert(candidate.raw, targetBundleID: candidate.bundleID) { [weak self] outcome in
                        guard let self = self else { return }
                        Log.info("Revert step 2/2: raw inserted outcome="
                                 + (outcome == .pasted ? "pasted" : "clipboardOnly"))
                        // 这期间被取消 / 用户又按了热键开了新一轮：别去动它的 phase，
                        // 也别拿撤销的结果去盖掉录音中的悬浮窗
                        guard self.isCurrent(entryGeneration) else { return }
                        self.phase = .idle
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
            // 文案要和实际落点一致：模型缺失时 onNeedSettings 打开的是引导向导的下载页
            // （标题「欢迎使用 MicType」），不是设置窗口——说"请在设置中下载"只会让用户
            // 以为弹错了窗口，去关掉它再自己找设置。
            overlay.flashError(tr("识别模型未下载——已为你打开下载页",
                                  "Speech model not downloaded — opening the download page"))
            Sounds.playError()
            onNeedSettings?()
            return
        }
        // 检查辅助功能权限（粘贴需要）
        guard Permissions.isAccessibilityTrusted else {
            promptAccessibilityNeeded()
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
            // 开始音抢在 recorder.start() 之前起头，但别指望它能躲开麦克风：NSSound.play()
            // 只是把声音排上队就立刻返回（好处是不推迟录音起点），紧接着装上的 tap 照样会把
            // 这一声"叮"录进去。所以真正挡住"回声被当成人声"的是下面的 armStartCueGate()。
            // 代价：启动失败时用户已经听到了开始音，紧接着一声错误音——比丢字可接受得多。
            // 「按下即录」是唯一的例外：按下这一刻还不知道用户是要说话还是只把热键当修饰键用，
            // 所以开始音推迟到 revealPressSession()（手势确认之后）。
            if !fromPress { Sounds.playStart() }
            // 设置里的「测试麦克风」可能正开着另一路录音（两路 AVAudioEngine 抢同一只麦克风）。
            // 用户按热键就是要说话，自检让位
            if MicTest.yieldToDictation() {
                Log.info("Mic test stopped — dictation takes the microphone")
            }
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
            self.finishWarningShown = false
            self.lastClockSecond = -1
            self.speechDetected = false
            self.lastLoudAt = nil
            self.partialCount = 0
            self.pendingMetric = nil
            // 上面刚响过的开始音会被这只麦克风录进去 → 开一道回声闸门。
            // 「按下即录」的那一声推迟到 revealPressSession()，闸门也在那里开。
            self.levelGateUntil = nil
            self.cueEchoRange = nil
            if !fromPress { self.armStartCueGate() }
            self.autoStopSilence = Settings.shared.autoStopSilenceSeconds
            self.recordingLabel = tr("正在听…", "Listening…")
            Log.info("Recording start press=\(fromPress) target=\(self.targetBundleID)"
                     + " autoStopSilence=\(String(format: "%.0f", self.autoStopSilence))s")
            // 「按下即录」的这一段先不现身：悬浮窗、灰字预览、读选区全部等手势确认
            // （pressTapConfirm / holdPromote）。菜单等其它入口是用户的明确动作，立刻显示。
            guard !fromPress else { return }
            self.overlay.showRecording(label: self.recordingLabel)
            // 伪流式预览：录音期间每隔一会儿把"到目前为止"的音频解码一遍，灰字贴在波形下面。
            // 纯粹是给眼睛看的，永远不会插入到任何地方。
            self.startLivePreview(generation: self.generation)
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

        // 电平判据一趟算完，交给 SilenceGate 这条纯函数决定这段音频的去向（判据与理由见 SilenceGate）。
        // 开始音的回声先刨掉：那一声是 MicType 自己放的，外放时足以把"压根没开口"顶成 .faint
        let echo = cueEchoRange
        cueEchoRange = nil
        let level = SilenceGate.stats(samples, excluding: echo)
        let decision = SilenceGate.decide(peak: level.peak, rms: level.rms, duration: duration)
        let levelLog = "duration=\(String(format: "%.2f", duration))s"
            + " peak=\(String(format: "%.4f", level.peak)) rms=\(String(format: "%.4f", level.rms))"

        switch decision {
        case .tooShort:
            // 太短当作误触
            Log.info("Recording stop discarded \(levelLog) (<0.4s)")
            phase = .idle
            // 是设备变更把录音打断的就说清楚，别让用户以为是自己按错了
            if let fault = takeSessionNote() {
                overlay.flashError(fault)
                Sounds.playError()
            } else {
                overlay.hide()
            }
            return
        case .silent:
            // 几乎无声（误触或没说话）：不送识别——空音频会诱发模型把热词上下文"复读"成识别结果
            Log.info("Recording stop silence-gated \(levelLog)")
            phase = .idle
            // 有故障附注（设备被拔/切走、到最长时长自动收尾）＝真出了事，必须出声——
            // 眼睛不在屏幕底部的人只有这一声能提醒他这一轮被丢了。
            // 裸的"没有听到内容"（误触 / 没开口）继续保持安静：按下时已经响过开始音，
            // 为一次误触再吵一声不值当，这也是 3.2.2 起的既定约定（见 <0.4s 那条分支）。
            if let fault = takeSessionNote() {
                overlay.flashError(fault)
                Sounds.playError()
            } else {
                overlay.flashError(tr("没有听到内容", "Nothing heard"))
            }
            return
        case .faint, .normal:
            break
        }
        // 声音很小的那一档：照常识别，只是万一识别出来是空的，给的提示要能指路（挪近点 / 换麦克风），
        // 而不是笼统的"没有听到内容"——前者用户知道下一步做什么，后者只会让他再试一次同样的动作
        let faintAudio = (decision == .faint)

        Log.info("Recording stop \(levelLog) gate=\(decision.rawValue)")
        phase = .processing
        overlay.showProcessing(tr("识别中…", "Transcribing…"))
        let isColdStart = !QwenEngine.shared.isModelReady
        let tASR = DispatchTime.now()
        let generation = self.generation
        // 这一轮的耗时草稿从这里开始攒：模式在松手这一刻就定了（skillSession 还没被清），
        // 时长/预览遍数/冷启动也都已成定局，剩下三段耗时各自算完填进来
        pendingMetric = SessionMetricDraft(mode: skillSession ? .command : .dictation,
                                           audioSeconds: duration,
                                           partialCount: partialCount,
                                           cold: isColdStart)

        // 长音频一段一段来：每完成一段就把已识别的文字贴到悬浮窗上（用户看得见进度），
        // 失败或被叫停时前面的段落照常交付。单段识别（≤90s）的行为与分段之前完全一致。
        // 彻底取消仍然靠"丢结果"：正在解码的那一段停不下来，代数对不上就当这轮没发生过。
        inflightTranscription = QwenEngine.shared.transcribe(
            samples: samples,
            onSegment: { [weak self] draft, done, total in
                guard let self = self, self.isCurrent(generation), total > 1 else { return }
                self.overlay.updateProcessing(
                    label: tr("识别中…（第 \(done)/\(total) 段）",
                              "Transcribing… (part \(done) of \(total))"),
                    draft: draft)
            }) { [weak self] outcome in
            guard let self = self, self.isCurrent(generation) else { return }
            self.inflightTranscription = nil
            switch self.resolve(outcome) {
            case .failure(let error):
                Log.error("Transcription failed: \(error.message)")
                self.phase = .idle
                self.overlay.flashError(error.message)
                Sounds.playError()
            case .success(let transcribed):
                let asrMs = Log.ms(since: tASR)
                Log.info("Timing ASR=\(asrMs)ms cold=\(isColdStart) chars=\(transcribed.count)")
                self.pendingMetric?.asrMs = asrMs
                // 近静音那一档（.faint）是从电平闸门底下放过来的，而那道闸门正是 3.2.2 防
                // "空音频复读热词"的第一道防线。这里把下游那道兜底按同样的理由收严：默认口径
                // 要命中 ≥3 个词表词，词表只有一两条的用户（多数）一个都兜不住，用户没开口
                // 却会被粘上一个热词。只在 .faint 上放宽，正常音量那条路的口径一点不动。
                if faintAudio,
                   TextPostProcessor.isVocabEcho(transcribed,
                                                 terms: Settings.shared.vocabularyTerms,
                                                 minHits: 1) {
                    Log.info("Faint audio vocab echo discarded chars=\(transcribed.count)")
                    self.phase = .idle
                    self.overlay.flashError(tr("声音太小，请靠近麦克风再试",
                                               "Too quiet — move closer to the microphone and try again"))
                    Sounds.playError()
                    return
                }
                // 词汇表"错写=正写"硬替换：进入润色/指令之前先做确定性纠正
                let rawText = TextPostProcessor.applyVocabReplacements(transcribed)
                guard !rawText.isEmpty else {
                    self.phase = .idle
                    // 这里和静音闸门不同：音频过了电平闸门、识别也真跑过一遍，却什么都没出来
                    // ——这不是误触，是实打实的一次失败，和其它失败出口一样要出声。
                    self.overlay.flashError(
                        faintAudio
                            ? tr("声音太小，请靠近麦克风再试",
                                 "Too quiet — move closer to the microphone and try again")
                            : tr("没有听到内容", "Nothing heard"))
                    Sounds.playError()
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
                // **润色之前**先把识别原文落进历史（brief §3.3）：接下来是一次网络往返 +
                // 一次切前台粘贴，任何一步失败、被 Esc 掐断、或者用户切走了窗口，
                // 从前都意味着刚说的那几分钟一个字都不剩。交付时 deliver 会把同一条补全。
                self.pendingHistoryID = HistoryStore.shared.addRaw(rawText)
                let level = Settings.shared.polishLevel
                if level != .off, KeychainHelper.loadAPIKey() != nil {
                    self.overlay.showProcessing(tr("润色中…", "Polishing…"))
                    let tPolish = DispatchTime.now()
                    self.inflightRequest = PolishService.polish(rawText, level: level) { [weak self] polished, failure in
                        guard let self = self, self.isCurrent(generation) else { return }
                        self.inflightRequest = nil
                        let polishMs = Log.ms(since: tPolish)
                        Log.info("Timing polish=\(polishMs)ms model=\(Settings.shared.currentPolishModel) ok=\(polished != nil)")
                        // 润色失败那一次也要记：用户感觉到的等待是实打实的，
                        // 只记成功的话中位数会漂亮得不像话，排障时反而看不出问题
                        self.pendingMetric?.polishMs = polishMs
                        if let raw = polished {
                            // 词汇表硬替换在**每个产出点各做一次**（识别原文已在上面做过）。
                            // 不能放到 deliver 里做：那样纯听写路径会对同一串文本替换两趟，
                            // 「萍果=苹果」+「苹果=Apple」这种链式词表会被串起来（applyVocabReplacements
                            // 承诺的"单趟扫描不串链"只在一次调用内成立）。
                            let polished = TextPostProcessor.applyVocabReplacements(raw)
                            // 保真校验：数字被改 / 否定被吞 / 内容被砍掉 → 当作润色失败，输出识别原文。
                            // 纯机械比对，不花一次 LLM 往返；宁可少一次润色，也不让改错的稿子进输入框。
                            // 走这条回退的结果本身就是识别原文，所以不开放「换回识别原文」（没得换）。
                            if let reason = TextPostProcessor.polishDriftCheck(raw: rawText, polished: polished) {
                                Log.warn("Polish drift rejected: \(reason)")
                                self.deliver(raw: rawText, final: rawText,
                                             note: tr("润色结果与原文出入过大，已输出原文",
                                                      "Polished text drifted too far from the original — raw transcript inserted"),
                                             warning: true,
                                             coldStart: isColdStart)
                                return
                            }
                            // 唯一开放「换回识别原文」的路径：纯听写 + 润色真的动了字
                            self.deliver(raw: rawText, final: polished,
                                         note: tr("已输入", "Inserted"),
                                         coldStart: isColdStart,
                                         revertible: true)
                        } else {
                            self.deliver(raw: rawText, final: rawText,
                                         note: tr("润色失败（", "Polish failed (")
                                             + (failure ?? tr("未知", "unknown"))
                                             + tr("），已输出识别原文", ") — raw transcript inserted"),
                                         warning: true,
                                         coldStart: isColdStart)
                        }
                    }
                } else {
                    self.deliver(raw: rawText, final: rawText,
                                 note: tr("已输入", "Inserted"),
                                 coldStart: isColdStart)
                }
            }
        }
    }

    /// 分段识别的结果 → 这一轮该怎么走。
    ///
    /// 核心规矩：**尾巴没转完不等于这一轮作废**。第 3 段炸了、或者用户在第 2 段之后按了 Esc，
    /// 前面那些段是用户实打实说过的话，照常交付，只在提示里说清尾巴没转。
    /// 两个例外：一个字都没有（和从前一样按失败处理）；指令模式（半条指令绝不能拿去执行）。
    private func resolve(_ outcome: TranscriptionOutcome) -> Result<String, MTError> {
        if skillSession, !outcome.isComplete {
            return .failure(outcome.failure
                            ?? MTError(tr("指令没说完就停了，请重新按住说一次",
                                          "The command was cut short — hold the key and say it again")))
        }
        if outcome.text.isEmpty {
            if let failure = outcome.failure { return .failure(failure) }
            if outcome.cancelled { return .failure(MTError(tr("已取消", "Cancelled"))) }
            // 真的什么都没识别出来：交给下游那句"没有听到内容"，别在这里另起一套提示
            return .success("")
        }
        if !outcome.isComplete {
            let done = outcome.completedSegments
            let total = outcome.totalSegments
            Log.warn("Partial transcript delivered segments=\(done)/\(total)"
                     + " reason=\(outcome.cancelled ? "cancelled" : "failed")")
            addSessionNote(outcome.cancelled
                ? tr("已停在第 \(done)/\(total) 段，后面的没有转写",
                     "Stopped after part \(done) of \(total) — the rest was not transcribed")
                : tr("第 \(done + 1) 段识别失败，已输入前 \(done) 段",
                     "Part \(done + 1) failed to transcribe — parts 1-\(done) were inserted"))
        }
        return .success(outcome.text)
    }

    // MARK: - V3 语音技能（仅指令模式进入）

    /// 指令分发：显式说「帮我回复…」→ 直通草拟回复；有选区 → 模型自判意图（改写/回复/新写）；
    /// 没选区 → 自由指令
    private func runSkillSession(rawText: String, isColdStart: Bool, generation: Int) {
        // ⌘C 兜底还在飞（按住满 0.6s 升级后不到 0.35s 就松手，典型是"翻译"这种两三字的口令）：
        // 等它回来再分发。不等的话选区是 nil，指令被当成无选区自由指令跑，
        // 结果还会粘到光标处盖掉用户选中的那段字。
        if selectionProbeGeneration == generation {
            Log.info("Skill dispatch waiting for clipboard selection fallback")
            selectionProbeWaiters.append { [weak self] in
                guard let self = self, self.isCurrent(generation) else { return }
                self.runSkillSession(rawText: rawText, isColdStart: isColdStart,
                                     generation: generation)
            }
            return
        }
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

    /// 指令模式那一次模型往返的耗时。**三条指令路（自由指令 / 选区指令 / 帮我回复）都必须
    /// 在回调里调它一次**：按住手势的等待几乎全压在这一段上（UAE 这条链路尤其），不记的话
    /// 提交的那一行只有识别和插入，加起来几百毫秒，用户报"指令模式很慢"时对不上账。
    private func noteCommandLatency(since start: DispatchTime, ok: Bool) {
        let ms = Log.ms(since: start)
        Log.info("Timing command=\(ms)ms model=\(Settings.shared.currentCommandModel) ok=\(ok)")
        // 失败那一次也记：用户感觉到的等待是实打实的
        pendingMetric?.polishMs = ms
    }

    /// 技能：自由指令——指令模式下的"万能入口"
    private func runFreeform(instruction: String, raw: String, isColdStart: Bool, generation: Int) {
        overlay.showProcessing(tr("执行指令中…", "Running command…"))
        let tModel = DispatchTime.now()
        inflightRequest = AgentService.freeform(instruction: instruction) { [weak self] result, failure in
            guard let self = self, self.isCurrent(generation) else { return }
            self.inflightRequest = nil
            self.noteCommandLatency(since: tModel, ok: result != nil)
            if let result = result {
                // 词汇表硬替换在每个产出点各做一次；deliver 里不再做，否则同一串文本会被替换两趟
                let finalText = TextPostProcessor.applyVocabReplacements(result)
                self.deliver(raw: raw, final: finalText, note: tr("已输入指令结果", "Command result inserted"),
                             coldStart: isColdStart)
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
        let tModel = DispatchTime.now()
        inflightRequest = AgentService.runOnSelection(selection, instruction: instruction, chatContext: chatContext) { [weak self] action, result, failure in
            guard let self = self, self.isCurrent(generation) else { return }
            self.inflightRequest = nil
            self.noteCommandLatency(since: tModel, ok: result != nil)
            guard let result = result else {
                self.phase = .idle
                self.overlay.flashError(tr("指令执行失败（", "Command failed (") + (failure ?? tr("未知", "unknown")) + tr("）", ")"))
                Sounds.playError()
                return
            }
            // 词汇表硬替换在每个产出点各做一次；deliver / copyToClipboard 里不再做
            let finalText = TextPostProcessor.applyVocabReplacements(result)
            switch action {
            case .modify:
                self.deliver(raw: raw, final: finalText, note: tr("已替换选中文本", "Selection replaced"),
                             coldStart: isColdStart)
            case .new:
                self.deliver(raw: raw, final: finalText, note: tr("已输入指令结果", "Command result inserted"),
                             coldStart: isColdStart)
            case .reply:
                self.copyToClipboard(raw: raw, result: finalText,
                                     note: tr("回复草稿已复制——点到输入框按 ⌘V", "Reply draft copied — click the input field and press ⌘V"))
            case nil:
                // 意图行没解析出来：进剪贴板最安全，不碰选区
                self.copyToClipboard(raw: raw, result: finalText,
                                     note: tr("结果已复制到剪贴板——按 ⌘V 粘贴", "Result copied — press ⌘V to paste"))
            }
        }
    }

    /// 结果进剪贴板（不自动粘贴），记录历史并提示
    private func copyToClipboard(raw: String, result: String, note: String) {
        phase = .idle
        let tDeliver = DispatchTime.now()
        // 只做标点归一：词汇表硬替换已经在各产出点做过了。在这里再做一次的话，
        // 纯听写路径（final 就是已替换过的 rawText）会被替换两趟，链式词表串成链。
        let final = TextPostProcessor.fixMixedPunctuation(result)
        HistoryStore.shared.add(raw: raw, polished: final)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(final, forType: .string)
        // 这条路（回复草稿 / 意图没解析出来）不走 deliver，指标得在这里自己收口，否则整轮
        // 连一行记录都没有——而它恰恰是按住手势里最慢的那类。投递这一段照实计时（写剪贴板
        // 本来就快），不写 0：这份表里"没发生"和"零毫秒"一直是分开的两回事。
        if let metric = pendingMetric {
            Metrics.shared.record(metric.finished(insertMs: Log.ms(since: tDeliver)))
        }
        pendingMetric = nil
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
        let tModel = DispatchTime.now()
        inflightRequest = AgentService.replyDraft(context: context, instruction: instruction) { [weak self] result, failure in
            guard let self = self, self.isCurrent(generation) else { return }
            self.inflightRequest = nil
            self.noteCommandLatency(since: tModel, ok: result != nil)
            if let result = result {
                // 词汇表硬替换在每个产出点各做一次；copyToClipboard 里不再做
                let finalText = TextPostProcessor.applyVocabReplacements(result)
                self.copyToClipboard(raw: raw, result: finalText,
                                     note: tr("回复草稿已复制——点到输入框按 ⌘V", "Reply draft copied — click the input field and press ⌘V"))
            } else {
                self.phase = .idle
                self.overlay.flashError(tr("草拟失败（", "Draft failed (") + (failure ?? tr("未知", "unknown")) + tr("）", ")"))
                Sounds.playError()
            }
        }
    }

    /// revertible：这一次是不是"纯听写 + 润色"的结果——只有它值得提供「换回识别原文」。
    /// coldStart：模型这一轮还没热（启动预加载没跑完 / 刚「释放模型内存」/ 刚换过模型）。
    /// 它**只**决定粘贴时序（输入框可能还没准备好吃键，给足等待），和"要不要恢复剪贴板"
    /// 毫无关系。3.3 之前两者共用一个参数，于是冷启动那一次会静默忽略用户
    /// 「输入后恢复原剪贴板内容」的设置，把他的原剪贴板永久换成听写结果，界面上还不吭声。
    /// 恢复与否永远只听 Settings.restoreClipboard。
    private func deliver(raw: String, final text: String, note: String, warning: Bool = false,
                         coldStart: Bool = false, revertible: Bool = false) {
        // 只做标点归一：词汇表硬替换已经在各产出点做过了（识别原文 / 润色结果 / 各技能结果），
        // 这里再做一趟等于对同一串文本替换两次，「萍果=苹果」+「苹果=Apple」会被串成链
        let finalText = TextPostProcessor.fixMixedPunctuation(text)
        // 润色之前已经落过一条 raw（纯听写路径）就补全它，别再插一条新的——
        // 用户看到的应该是一条"识别原文 + 最终文字"，不是同一句话的两行记录
        if let id = pendingHistoryID {
            HistoryStore.shared.complete(id: id, polished: finalText)
            pendingHistoryID = nil
        } else {
            HistoryStore.shared.add(raw: raw, polished: finalText)
        }
        // 又插入了新东西 → 上一次的记忆立刻作废：⌘Z 撤的永远是"最后一次粘贴"，
        // 拿旧记忆去撤只会撤掉这一次的新文字
        revertCandidate = nil
        phase = .idle
        // 录音被设备变更提前掐断时，把原因并进结果提示：用户得知道这只是"半句"
        let note = takeSessionNote().map { $0 + tr("；", "; ") + note } ?? note
        // 目标应用在这里定格：回调回来时 targetBundleID 可能已经属于下一轮录音了
        let target = targetBundleID
        // 这一轮的代数也要定格：上面刚把 phase 置回 .idle，而插入回调最长要等到
        // 前台切换完成（≤1.2s）+ 保守时序，这期间用户完全可能已经按键开了下一轮
        let generation = self.generation
        Log.info("Deliver start chars=\(finalText.count) target=\(target)")
        // 插入这一段也计时：它包含切前台（最长 1.2s）+ 粘贴时序，是用户真实等待的一部分。
        // 草稿在这里定格成局部变量——回调最长要等一秒多，那时 pendingMetric 可能已经是下一轮的了。
        let tInsert = DispatchTime.now()
        let metric = pendingMetric
        pendingMetric = nil
        TextInserter.insert(finalText, targetBundleID: target,
                            allowClipboardRestore: true,
                            conservativePaste: coldStart) { [weak self] outcome in
            guard let self = self else { return }
            let insertMs = Log.ms(since: tInsert)
            Log.info("Timing insert=\(insertMs)ms outcome=\(outcome == .pasted ? "pasted" : "clipboardOnly")")
            // 先记指标再判代数：这一轮的耗时是既成事实，哪怕用户已经开了下一轮也照样算数
            if let metric = metric { Metrics.shared.record(metric.finished(insertMs: insertMs)) }
            // 对不上这一轮就到此为止：迟到的成功提示会把新一轮的录音悬浮窗盖成绿勾，
            // 1 秒后 flash 结束时整个面板被 orderOut（灰字预览和"正在听指令…"从此不再更新），
            // 成功音还会被新一轮的麦克风录进去。「换回识别原文」的记忆同理——
            // 那时候 ⌘Z 撤的已经不是这一次粘贴了。
            guard self.isCurrent(generation), self.phase == .idle else {
                Log.info("Deliver feedback suppressed (a new round already started)")
                return
            }
            // 只有"确实粘进去了"且"润色确实改了字"才记：没粘进去就无从 ⌘Z 撤起，
            // 一个字没改的话换回原文也是原地踏步
            if outcome == .pasted, revertible, finalText != raw, !target.isEmpty {
                self.revertCandidate = RevertCandidate(raw: raw, final: finalText,
                                                       bundleID: target, at: Date())
                Log.info("Revert available for \(Int(Self.revertWindowSeconds))s target=\(target)")
            }
            switch outcome {
            case .pasted:
                // warning = 这次投递有保留（润色失败 / 保真校验没过，输出的是识别原文）。
                // 这种时候绝不能打绿勾：用户会以为润色成功了，连检查都不检查一眼。
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
