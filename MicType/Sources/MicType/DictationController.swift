import AppKit

/// 「直接落字」通道：MicType 自己的界面（目前只有引导窗的「试一下」那一页）开着时，
/// 最终文字不走"写剪贴板 + 模拟 ⌘V"，而是直接交给那个界面写进自己的输入框。
///
/// 为什么非要这一条路（4.0.1 用户在另一台 Mac 上实测）：试一下那一页靠 ⌘V 落字，
/// 而 ⌘V 永远打向"此刻的键盘焦点"——翻页动画刚结束 TextEditor 还没进响应链、
/// 或者用户中途点过别处，这一下就落到别的地方去了。用户看到的是
/// 「悬浮窗一切正常，框里一个字都没有」，还查不出所以然。
/// 引导页是我们自己的视图，压根不需要模拟按键：把字给它自己 append 就行。
///
/// 两条纪律：
///   • 没人注册时行为和从前**逐字一致**（isReady 恒 false，一律走 TextInserter）；
///   • accept 返回 false（窗口刚关掉 / 刚翻页）时调用方必须退回粘贴那条路——
///     绝不允许文字掉在地上。
/// 只在主线程读写。
enum TranscriptSink {

    /// 现在接得住吗（引导窗开着、且停在「试一下」那一页）
    private(set) static var isReady: () -> Bool = { false }
    /// 引导窗**开着**吗（停在哪一页都算）。和 isReady 的区别正是"接不住"的那几页：
    /// 那时候 MicType 自己在前台，一下 ⌘V 会打进引导自己的控件里（「怎么用」那一屏的
    /// Key 输入框首当其冲：一段识别结果被当成 Key 拿去验证，还留在框里）。
    private(set) static var isRegistered = false
    /// 把这段最终文字交给它；返回 false = 这一刻没接住
    private(set) static var accept: (String) -> Bool = { _ in false }

    static func register(isReady: @escaping () -> Bool, accept: @escaping (String) -> Bool) {
        Self.isReady = isReady
        Self.accept = accept
        Self.isRegistered = true
        Log.info("Transcript sink registered")
    }

    static func unregister() {
        Self.isReady = { false }
        Self.accept = { _ in false }
        Self.isRegistered = false
        Log.info("Transcript sink cleared")
    }
}

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
    /// 需要打开「设置 → 云端 AI」的回调（没配 Key 却按住说了指令时，悬浮窗上那个「去配置」胶囊）
    var onNeedAISettings: (() -> Void)?
    /// 需要打开「设置 → 云端 AI」的回调（开了云端识别却没填 Key 时的「去设置」胶囊）
    var onNeedRecognitionSettings: (() -> Void)?
    /// 缺系统权限时的回调：带去引导的权限页（那一页两颗按钮各管一项，授权后自己变绿往下走）。
    /// 4.0.1 这里是直接把系统设置甩到用户脸上——他还没看清这是什么应用，也不知道该勾哪一条
    var onNeedPermissions: (() -> Void)?

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
    private enum BlockedReason: Equatable {
        /// 当前这一档识别引擎开不了工（本地模型没下载 / 云端没 Key）
        case engine(RecognitionEngineReadiness)
        case accessibility

        /// 只进日志，不上界面
        var logName: String {
            switch self {
            case .engine(let readiness): return "engine:\(readiness)"
            case .accessibility: return "accessibility"
            }
        }
    }
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
    /// 云端识别引擎。**用到才建**：默认档的用户这辈子都不会创建它。
    /// 建一次就一直留着（内部只有一把锁和一条队列，不占资源），每轮开录前用 update(config:) 刷新配置。
    private var cloudEngine: CloudASREngine?
    /// 这一轮实际用的引擎与它是不是云端。都在**开录这一刻**定格：录到一半去设置里改引擎，
    /// 不该让正在录的这一段换一条链路（与 autoStopSilence 的快照同理）。
    private var sessionEngine: SpeechEngine = QwenEngine.shared
    private var sessionUsesCloud = false
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
    /// 录音中的预转写（progressive）状态，全部只在主线程读写。
    /// 一句话说清它在干什么：录满一段（AudioSegmenter.targetSeconds）就**立刻**把那一段转成
    /// 最终文字，松手时只剩最后一小截要转——3 分钟口述的等待从约 10 s 掉到约 1 s，
    /// 峰值内存永远只是"一段"。草稿归草稿（灰字预览），这里出来的是要进输入框的字。
    private var liveParts: [String] = []
    /// 已经交给预转写的采样数（下一段从这里开始）
    private var liveConsumed = 0
    /// 每 20 ms 一帧的电平（增量算，别每次都扫整条缓冲）与已经算成帧的采样数
    private var liveFrames: [Float] = []
    private var liveFramedSamples = 0
    /// 在飞的那一段预转写（可取消：松手/取消时立刻让出 GPU）
    private var liveTask: Task<Void, Never>?
    /// 第一段检测出的语言（语言锁）；用户显式选过语言时从一开始就是它
    private var liveLanguage: String?
    /// 预转写这一轮还作不作数。任何一段失败就置 false 并丢掉已转的部分——
    /// 松手后照老路子把整段重转一遍。宁可白跑一次 GPU，也不交付一段来路不明的拼接文本。
    private var liveActive = false
    /// 松手这一刻定格的"已经转好的前半段"（没开预转写就是空串）。留成字段只为一件事：
    /// Esc 那条部分交付的路要能就地把它落进历史（见 cancel()）——那几分钟的字在 resolve
    /// 回来之前没有任何持久化，用户再按一次 Esc 就全没了。
    private var committedText = ""
    /// 松手后那一遍识别**已经报上来的**最新草稿（onSegment 的全文快照）。同样只为 Esc 那条保底路：
    /// 云端那一档没有预转写，能救的就是这些已经转完的段落。
    private var deliveredDraft = ""
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
    /// 单次录音硬上限。internal 而不是 private：设置页那句说明必须**读这个常量**，
    /// 不许自己写一个数字（写死的数字改了这里就对不上，用户读到的就是假的）
    static let maxRecordingSeconds: Double = 600
    /// 自动收尾前多久给预警：到点才知道有上限对用户毫无帮助，30 s 够说完一句话
    static let preFinishWarningSeconds: Double = 30
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

    /// 预转写最早从什么时候开始：录音超过"该分段"的门槛（AudioSegmenter.segmentThresholdSeconds）
    /// 才动手。90 s 以内的录音行为与分段之前**完全一致**（一次过，一个字不差），
    /// 这条门槛就是那句承诺的实现方式。
    private static var liveSegmentAfterSeconds: Double { AudioSegmenter.segmentThresholdSeconds }

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
        let readiness = Self.engineReadiness()
        guard readiness.isReady else {
            pressBlockedReason = .engine(readiness)
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
            Log.info("Press blocked (\(reason.logName)) — prompt throttled")
            return
        }
        lastBlockedPromptAt = Date()
        Log.info("Press blocked (\(reason.logName))")
        switch reason {
        case .engine(let readiness):
            reportEngineNotReady(readiness)
        case .accessibility:
            promptAccessibilityNeeded()
        }
    }

    /// 当前这一档识别引擎能不能开工（判据本身是纯函数，可单测；这里只是取当前设置那一版）
    private static func engineReadiness() -> RecognitionEngineReadiness {
        RecognitionEngineReadiness.current()
    }

    /// 引擎没就绪时的统一出口：说清哪儿不对，并把该去的那一页直接打开。
    /// 本地档和云端档指向的是两个不同的落点，所以这里分两条路走。
    private func reportEngineNotReady(_ readiness: RecognitionEngineReadiness) {
        guard !readiness.isReady else { return }
        Sounds.playError()
        // 文案要和实际落点一致：模型缺失时 onNeedSettings 打开的是引导向导的下载页
        // （标题「欢迎使用 MicType」），不是设置窗口——说"请在设置中下载"只会让用户
        // 以为弹错了窗口，去关掉它再自己找设置。
        guard let chip = readiness.settingsChipLabel else {
            overlay.flashError(readiness.message)
            onNeedSettings?()
            return
        }
        // 云端那两档不自动抢窗口：用户可能只是临时没网/没充值，硬把设置页弹到脸上很烦。
        // 给一个可点的胶囊（与「去配置」同一套机制），要去的人一下就到。
        overlay.flashError(readiness.message, actionLabel: chip) { [weak self] in
            self?.onNeedRecognitionSettings?()
        }
    }

    /// 没有辅助功能权限时的统一提示：一行话说清怎么回事，然后把**引导的权限页**打开。
    ///
    /// 为什么不再直接弹系统设置（4.0.1 是那样做的）：辅助功能面板上是一长串应用和一排开关，
    /// 没人告诉他该勾哪一条、勾完要不要重启。引导那一页两项权限各一行、各一颗按钮，
    /// 勾上之后自己变绿并往下走——三件必办的事本来就都该在那里办（OWNER 规则 2026-09-20）。
    /// 不提"重启 MicType"：现在的 macOS 授权即时生效，让用户白重启一次只会更迷惑。
    private func promptAccessibilityNeeded() {
        Sounds.playError()
        overlay.flashError(tr("辅助功能还没授权——已为你打开引导",
                              "Accessibility is not granted - opening the guide"))
        onNeedPermissions?()
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
            // 「有东西可交付」有两种来源：这一遍已经转出来的段落，或者录音中预转写好的部分
            // （尾巴通常只有一段，handle.completedSegments 还是 0，但前面几分钟的字已经在手上了）
            if let handle = inflightTranscription, !handle.isCancelled,
               Self.escFinishesEarly(completedSegments: handle.completedSegments,
                                     hasLiveParts: !liveParts.isEmpty,
                                     isSkillSession: skillSession) {
                Log.info("Transcription stopped by user after \(handle.completedSegments) segment(s)"
                         + " live=\(liveParts.count)")
                handle.cancel()
                // 这一下之后再按 Esc 就是彻底丢弃了：胶囊得跟着改回「取消」
                overlay.setCancelFinishes(false)
                // 手上这些字**立刻**落一条历史保底。当前这一段停不下来（MLX 一次解码到底），
                // 「收尾中…」可能还要好几秒；用户以为没生效再按一次 Esc 就走 endSession()，
                // 结果被代数挡掉——在这之前它们没有任何持久化，几分钟口述会一个字不剩。
                // 落下的这一条随后由 resolve 那边补成完整原文（见 pendingHistoryID）。
                saveCancelSafetyHistory()
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

    /// 处理中按 Esc 到底是"收尾并输入"还是"彻底丢弃"——同一个键在这一刻有两个意思，
    /// 而用户看不见判据。纯函数抽出来只为一件事：cancel() 的行为和胶囊/菜单项上的字
    /// 由**同一个判据**决定，不会一边改了另一边没跟上（那正是"点了取消却被插入"的来源）。
    static func escFinishesEarly(completedSegments: Int, hasLiveParts: Bool,
                                 isSkillSession: Bool) -> Bool {
        // 半句指令绝不能拿去执行：指令会话一律走彻底取消
        guard !isSkillSession else { return false }
        return completedSegments > 0 || hasLiveParts
    }

    /// 菜单栏「处理中」那一项该写什么——与胶囊、与 cancel() 同一个判据，
    /// 不能菜单里写「取消」而点下去其实是插入（AppDelegate 读它）
    var escFinishesEarlyNow: Bool {
        guard phase == .processing, let handle = inflightTranscription, !handle.isCancelled else {
            return false
        }
        return Self.escFinishesEarly(completedSegments: handle.completedSegments,
                                     hasLiveParts: !liveParts.isEmpty,
                                     isSkillSession: skillSession)
    }

    /// 把上面那条判据推给悬浮窗（胶囊的字跟着它变）。在飞的那次识别没了 = 没什么可收尾的
    private func syncCancelAffordance() {
        let finishes = Self.escFinishesEarly(
            completedSegments: inflightTranscription?.completedSegments ?? 0,
            hasLiveParts: !liveParts.isEmpty,
            isSkillSession: skillSession)
        overlay.setCancelFinishes(finishes && !(inflightTranscription?.isCancelled ?? true))
    }

    /// Esc 部分交付那一刻的保底记录：把此刻手上的文字（预转写好的前半段 + 已经报上来的段落）
    /// 按纯听写的口径落进历史，并记住这一条的 id——之后 resolve 回来时就地补成完整原文，
    /// 同一轮口述永远只有一条记录。keepHistory 关着时 addRaw 返回 nil，那就什么都不做
    /// （用户明确不要历史，这里不是偷偷替他留一份的地方）。
    private func saveCancelSafetyHistory() {
        guard pendingHistoryID == nil else { return }
        let salvaged = TextPostProcessor.joinSegments([committedText, deliveredDraft])
        guard !salvaged.isEmpty else { return }
        pendingHistoryID = HistoryStore.shared.addRaw(
            TextPostProcessor.applyVocabReplacements(salvaged))
        Log.info("Cancel safety history saved chars=\(salvaged.count)"
                 + " kept=\(pendingHistoryID != nil)")
    }

    /// 这一轮用哪个识别引擎。默认档直接是本机的 QwenEngine；选了云端就把 Settings + 钥匙串
    /// 组装成一份配置交给 CloudASREngine（引擎自己永远不读设置）。
    /// 配不出配置（设置在这半秒里被改回本地档）时退回本机：走到这里说明 engineReadiness
    /// 已经放行过，宁可用本机跑一遍，也不能让这段录音掉在地上。
    private func prepareSessionEngine() {
        guard let config = CloudASRSettings.currentConfig() else {
            sessionEngine = QwenEngine.shared
            sessionUsesCloud = false
            return
        }
        let engine = cloudEngine ?? CloudASREngine(config: config)
        engine.update(config: config)
        // 「这台主机不让这把 Key 访问端点」（403）是换一台主机就能解决的失败，而那台主机
        // 偏偏是"验证过"的——那个验证靠的是 GET /models，4.1.5 的实测证明它什么都不证明。
        // 后台换掉它，本轮照常回落本机模型，用户一个字都不丢（判据是纯函数，见集成层）
        engine.onProviderFailure = { failure in
            CloudASRSettings.recoverIfEndpointDenied(failure)
        }
        cloudEngine = engine
        sessionEngine = engine
        sessionUsesCloud = true
        Log.info("Session engine=cloud provider=\(config.provider.rawValue) "
                 + "hints=\(config.languageHints.joined(separator: ","))")
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
        resetLiveSegments(active: false)
        // 云端那一路还要把在飞的 HTTP 请求真的掐掉（取消之后引擎不再回调，与 LLMClient 同约定）：
        // 只叫停"后续段落"的话，用户按了 Esc 还得等当前这一段传完、转完
        if sessionUsesCloud { cloudEngine?.cancel() }
        // 指针清掉，但**不动已经写进历史的那一条**——那正是"取消也不丢字"的落点
        pendingHistoryID = nil
        committedText = ""
        deliveredDraft = ""
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

    /// 设置 → 录音 里那句说明。**数字全部来自常量**：上限、预警提前量、分段长度改了，
    /// 这句话自己跟着变。这一条是被"界面上说 5 分钟、代码里其实是 10 分钟"坑出来的规矩
    /// （用户唯一能查到上限的地方就是这行字，它和代码对不上等于骗人）。
    /// 纯函数、可单测。
    /// 这一句里「边说边转」那半句只对本机引擎成立：录音中的预转写是 QwenEngine 在跑
    /// （resetLiveSegments(active: !sessionUsesCloud)），云端档要松手之后才分段上传。
    /// 所以按当前引擎给两个版本，别让只用云端的人去等一个永远不会出现的逐段进度。
    static var recordingLimitCopy: String {
        recordingLimitCopy(progressive: !Settings.shared.recognitionEngine.isCloud)
    }

    /// 纯函数版（单测直接喂 progressive，不碰 UserDefaults）
    static func recordingLimitCopy(progressive: Bool) -> String {
        let limit = minutesLabel(maxRecordingSeconds)
        let warn = secondsLabel(preFinishWarningSeconds)
        let segment = secondsLabel(AudioSegmenter.targetSeconds)
        // Plan C 的 ⓘ 预算（中文 ≤ 120 字）把这三句都压短了一轮：数字一个没少，
        // 少掉的是"悬浮窗会显示已录时长与上限"这类屏幕上自己看得见的话
        let head = tr("单次录音上限 \(limit)，到点前 \(warn) 提醒一次。",
                      "A take is capped at \(limit), with a warning \(warn) before the end. ")
        let segmenting = progressive
            ? tr("长段口述边说边转，每段约 \(segment)，转完一段显示一段；",
                 "Long dictation is transcribed while you speak, in segments of about \(segment); ")
            : tr("长段口述在松手后按每段约 \(segment) 上传识别，转完一段显示一段；",
                 "Long dictation is uploaded in segments of about \(segment) after you release the hotkey, "
                 + "each shown as soon as it is ready; ")
        let tail = tr("到上限自动收尾，说过的内容全部识别并插入。",
                      "at the cap MicType wraps up and inserts everything you have said.")
        return head + segmenting + tail
    }

    /// 一行版：只报上限本身。设置页的「录音」段只给一行（Plan C 的文案预算），
    /// 上面那句完整的（分段、预警、收尾）收进段头那颗 ⓘ 里。数字同样来自常量。
    static var recordingLimitShort: String {
        tr("单次录音上限 ", "A take is capped at ") + minutesLabel(maxRecordingSeconds)
    }

    /// 「10 分钟」/「10 minutes」。不足整分钟的按秒说（常量以后改成 90 s 也不会读成 2 分钟）
    static func minutesLabel(_ seconds: Double) -> String {
        guard seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 else {
            return secondsLabel(seconds)
        }
        let minutes = Int(seconds / 60)
        return tr("\(minutes) 分钟", "\(minutes) minutes")
    }

    /// 「30 秒」/「30s」
    static func secondsLabel(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return tr("\(whole) 秒", "\(whole)s")
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
        // 录音中的预转写：够一段就转一段（闸门都在 updateLiveSegments 里）
        updateLiveSegments()

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
        // 发起时的窗口起点。预览和预转写是两条各自在飞的任务：这一遍还没回来时，预转写落一段
        // 就会把 previewWindowStart / previewCommitted 换成权威文本，那之后这一遍算出来的
        // 「窗口往后滚 consumed」和「接在 previewCommitted 后面」都是按旧窗算的（滚过头会跳过
        // 一整窗草稿，拼接则让同一句话在灰字里出现两遍）。所以回来时先比对，对不上就只丢草稿。
        let startedAt = previewWindowStart
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
            // 这一遍在飞期间预转写落了段（窗口已经被权威文本重排）：草稿作废，
            // 窗口一动不动——下一遍预览会按新窗口重新解码，音频一个采样都不会丢。
            guard self.previewWindowStart == startedAt else {
                Log.info("Preview draft dropped (a live segment moved the window)")
                self.scheduleNextPartial(after: Self.previewIdleDelay(interval: self.previewInterval,
                                                                      latency: latency),
                                         generation: generation)
                return
            }
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

    // MARK: - 录音中的预转写（progressive）

    /// 每一轮录音开始时复位。是否真的会跑还要看 updateLiveSegments 里那三道闸门。
    private func resetLiveSegments(active: Bool) {
        liveTask?.cancel()
        liveTask = nil
        liveParts = []
        liveConsumed = 0
        liveFrames = []
        liveFramedSamples = 0
        // 用户显式选了语言就从第一段开始锁着它；"自动"那一档由第一段的检测结果来填
        liveLanguage = Settings.shared.recognitionModelLanguage
        liveActive = active
    }

    /// 预转写这一轮作废：已经转好的部分全部丢掉，松手后按老路子整段重转。
    private func abandonLiveSegments(_ reason: String) {
        guard liveActive || !liveParts.isEmpty else { return }
        Log.warn("Live segmentation abandoned (\(reason)) parts=\(liveParts.count)")
        liveTask?.cancel()
        liveTask = nil
        liveActive = false
        liveParts = []
        liveConsumed = 0
    }

    /// 录音电平回调里顺手调一次（主线程，约每 85 ms）。够一段就切一段送去转写。
    ///
    /// 三道闸门，缺一不可：
    ///   1. 这一轮开了预转写（本机引擎 + 纯听写 + 模型已就绪）；
    ///   2. 录音已经过了"该分段"的门槛——90 s 以内一次过，行为和分段之前一模一样；
    ///   3. 目标点之后的整个搜索窗口都已经录进来了（AudioSegmenter.nextLiveCut 判的就是这个），
    ///      所以切点永远落在不会再变的音频上。
    /// 同一时刻只允许一段在飞：GPU 由 Qwen3ASRSTT 这个 actor 串行，排队只会让松手等得更久。
    private func updateLiveSegments() {
        guard liveActive, phase == .recording, !skillSession, liveTask == nil else { return }
        guard recorder.recordedDuration >= Self.liveSegmentAfterSeconds else { return }
        // 帧电平照常增量累计（只算新录进来的那几帧，很便宜），模型一就绪就能立刻下刀。
        updateLiveFrames()
        // 第一道闸门里"模型已就绪"那一条。少了它，模型没加载时 transcribeLiveSegment 每次都
        // 返回 nil、liveConsumed 永不推进，于是每次电平回调（约 85 ms）都白做一遍
        // 45 s 片段的拷贝 + nextLiveCut 里的两次全量 sorted()，一直烧到松手为止。
        // 这里不动 liveActive：这是"还没开跑"，不是"跑失败了"（失败由 abandonLiveSegments 收口），
        // 模型加载完这一轮照样能接着切段。
        guard QwenEngine.shared.isModelReady else { return }
        guard let range = AudioSegmenter.nextLiveCut(frameRMS: liveFrames,
                                                     consumed: liveConsumed,
                                                     available: liveFramedSamples) else { return }
        let chunk = recorder.snapshot(fromSampleIndex: range.lowerBound, maxCount: range.count)
        guard chunk.count == range.count else { return }
        let generation = self.generation
        let previous = TextPostProcessor.joinSegments(liveParts)
        liveTask = QwenEngine.shared.transcribeLiveSegment(
            samples: chunk, language: liveLanguage, previousText: previous) { [weak self] text, detected in
            guard let self = self else { return }
            self.liveTask = nil
            guard self.liveActive, self.phase == .recording, self.isCurrent(generation) else { return }
            guard let text = text else {
                // 一段没转出来就整轮作废：拼接文本里少一段是用户看不见的丢字，
                // 比"松手后多等几秒重转一遍"严重得多
                self.abandonLiveSegments("segment failed")
                return
            }
            self.liveConsumed = range.upperBound
            self.liveParts.append(text)
            // 语言锁：第一段检测出什么，后面几段就按那个转（防漂移 → 翻译 → 复读）
            if self.liveLanguage == nil, let detected = detected {
                self.liveLanguage = detected
                Log.info("Live segmentation language locked to \(detected)")
            }
            Log.info("Live segment landed parts=\(self.liveParts.count)"
                     + " consumed=\(String(format: "%.0f", Double(self.liveConsumed) / 16000.0))s")
            // 灰字预览接着从这一段的末尾往后看，已定稿的部分换成预转写的权威文本，
            // 免得草稿把同一句话显示两遍。**关了草稿的人一个字都不该看到**：
            // 预转写是为了快，不是偷偷把他关掉的东西打开（previewEnabled 才是那个开关的结论）。
            guard self.previewEnabled else { return }
            self.previewWindowStart = self.liveConsumed
            self.previewCommitted = TextPostProcessor.joinSegments(self.liveParts)
            self.overlay.showDraft(self.previewCommitted)
        }
        // 模型还没加载好（或刚被换掉）：这一段等下一次电平回调再试。切点不会变（永远是
        // consumed + 目标段长），所以重试是幂等的；始终等不到就按老路子在松手后整段转。
    }

    /// 增量算帧电平：只对"新录进来的整帧"算一遍 RMS，绝不每次都扫整条缓冲
    /// （10 分钟录音有 960 万个采样，每 85 ms 扫一遍主线程就别想干别的了）。
    private func updateLiveFrames() {
        let available = recorder.recordedSampleCount
        let wholeFrames = (available - liveFramedSamples) / AudioSegmenter.frameSamples
        guard wholeFrames > 0 else { return }
        let count = wholeFrames * AudioSegmenter.frameSamples
        let chunk = recorder.snapshot(fromSampleIndex: liveFramedSamples, maxCount: count)
        guard chunk.count == count else { return }
        liveFrames.append(contentsOf: AudioSegmenter.frameRMS(chunk))
        liveFramedSamples += count
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
        // 检查这一档识别引擎（本地模型有没有下载 / 云端 Key 填了没有）
        let readiness = Self.engineReadiness()
        guard readiness.isReady else {
            reportEngineNotReady(readiness)
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
                // 走到这里说明系统不会再弹授权框了（拒过一次 / 被管控），只能人工去勾。
                // 和辅助功能同一个落点：引导的权限页，那里两项各一行、各一颗按钮，
                // 勾上之后自己变绿——比把一长串应用的系统面板甩给他强
                self.overlay.flashError(tr("麦克风还没授权——已为你打开引导",
                                           "Microphone is not granted - opening the guide"))
                Sounds.playError()
                self.onNeedPermissions?()
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
            // 这一轮用哪个引擎在开录这一刻定格（录到一半改设置不影响这一段）
            self.prepareSessionEngine()
            // 用户说话期间把到 API 的 DNS+TLS 握手做完，润色/指令请求省下首包延迟
            LLMClient.prewarm()
            // 云端识别同理：UAE → 云端这条链路上，预热能省下 0.5–1.5s 的首包延迟。
            // 与 LLMClient.prewarm 一样**不带 Key**，只热 DNS/TLS。
            if self.sessionUsesCloud { self.cloudEngine?.prewarm() }
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
            // 录音中的预转写：只给本机引擎开（云端那一路有它自己的分段与计费口径，
            // 录音中就开始上传会把"按秒计费"变成用户没预期的样子）。
            self.resetLiveSegments(active: !self.sessionUsesCloud)
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
        // 预转写同样就地封口：在飞的那一段作废（它的音频原样留在尾巴里，一个采样都不丢），
        // liveActive 立刻置 false，已经排到主队列上的回调据此安静退场。
        // **必须在下面那几条 early return 之前做**，否则一条迟到的回调会在 .idle 状态下
        // 往悬浮窗上画草稿、还把 liveConsumed 推到尾巴后面去。
        liveTask?.cancel()
        liveTask = nil
        let liveWasActive = liveActive
        liveActive = false
        recordingStartedAt = nil
        // 录音已结束，这一段再也不会被"当成修饰键用"而作废了
        pressSession = false
        // 上一轮的保底快照绝不带进这一轮（Esc 那条路会拿它们去落历史）
        committedText = ""
        deliveredDraft = ""
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
            resetLiveSegments(active: false)
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
            resetLiveSegments(active: false)
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
        overlay.showProcessing(Self.transcribingLabel(usesCloud: sessionUsesCloud))
        // 冷启动只对本机模型有意义（它决定粘贴时序要不要放宽）：云端那一档没有"模型还没加载"
        // 这回事，硬填 true 只会让每次插入都白等一段保守时序
        let isColdStart = sessionUsesCloud ? false : !QwenEngine.shared.isModelReady
        let tASR = DispatchTime.now()
        let generation = self.generation
        // 这一轮的耗时草稿从这里开始攒：模式在松手这一刻就定了（skillSession 还没被清），
        // 时长/预览遍数/冷启动也都已成定局，剩下三段耗时各自算完填进来
        pendingMetric = SessionMetricDraft(mode: skillSession ? .command : .dictation,
                                           audioSeconds: duration,
                                           partialCount: partialCount,
                                           cold: isColdStart)

        // 录音中已经转好的那些段落在这里收口：松手后只剩最后一小截要转。
        // 任何一环不对劲（预转写作废 / 下标越界）都退回"整段重转"，绝不交付来路不明的拼接。
        var pending = samples
        var committed = ""
        // 尾巴要显式按"预转写已经锁定的语言"转。这一截通常只有十几秒，是整条链路上最短、
        // 最容易被判错语言的一段，而前面几分钟已经锁在某个语言上了——接缝处断掉语言锁，
        // 模型就会从这里开始把口述"翻译"成另一种语言，再被复读截断收尾（3.3 之前的失败）。
        var tailLanguage: String?
        if liveWasActive, !liveParts.isEmpty, liveConsumed > 0, liveConsumed < samples.count {
            committed = TextPostProcessor.joinSegments(liveParts)
            pending = Array(samples[liveConsumed...])
            tailLanguage = liveLanguage
            Log.info("Live segmentation delivered parts=\(liveParts.count)"
                     + " tail=\(String(format: "%.1f", Double(pending.count) / 16000.0))s"
                     + " chars=\(committed.count) language=\(tailLanguage ?? "auto")")
        }
        // Esc 那条部分交付的路要能立刻把它落进历史（见 saveCancelSafetyHistory）
        committedText = committed

        startTranscription(engine: sessionEngine, usesCloud: sessionUsesCloud, samples: pending,
                           committed: committed, language: tailLanguage,
                           faintAudio: faintAudio, isColdStart: isColdStart,
                           tASR: tASR, generation: generation)
    }

    /// 悬浮窗上"处理中"那句话。云端那一档必须当面写明音频正在上传——
    /// 同一句"识别中…"既盖住本机也盖住云端的话，用户永远不知道自己刚才把录音发出去了。
    private static func transcribingLabel(usesCloud: Bool) -> String {
        usesCloud ? tr("云端识别中…", "Transcribing in the cloud…")
                  : tr("识别中…", "Transcribing…")
    }

    private static func segmentLabel(usesCloud: Bool, done: Int, total: Int) -> String {
        usesCloud ? tr("云端识别中…（第 \(done)/\(total) 段）",
                       "Transcribing in the cloud… (part \(done) of \(total))")
                  : tr("识别中…（第 \(done)/\(total) 段）",
                       "Transcribing… (part \(done) of \(total))")
    }

    /// 把这段音频交给某个引擎跑一遍。抽出来是为了云端失败之后能**原样再跑一遍本地引擎**
    /// （同一条交付链路、同一套提示），而不是在回调里复制一份下游逻辑。
    /// - committed: 录音中已经预转写好的前半段文字（没开预转写就是空串）。它有两个去处：
    ///   在这里与尾巴拼成完整文本（resolve 之后的所有下游——润色、指令、历史、插入——
    ///   拿到的都是全文），以及作为 previousText 给引擎当跨段上下文的种子（尾巴的第一段
    ///   因此不再是"从零开始的一句话"）。
    /// - language: 已经锁定的识别语言（英文全名）；nil = 按设置走。
    private func startTranscription(engine: SpeechEngine, usesCloud: Bool, samples: [Float],
                                    committed: String = "", language: String? = nil,
                                    faintAudio: Bool, isColdStart: Bool, tASR: DispatchTime,
                                    generation: Int) {
        // 长音频一段一段来：每完成一段就把已识别的文字贴到悬浮窗上（用户看得见进度），
        // 失败或被叫停时前面的段落照常交付。单段识别（≤90s）的行为与分段之前完全一致。
        // 彻底取消仍然靠"丢结果"：正在解码的那一段停不下来，代数对不上就当这轮没发生过。
        inflightTranscription = engine.transcribe(
            samples: samples,
            language: language,
            previousText: committed,
            onSegment: { [weak self] draft, done, total in
                guard let self = self, self.isCurrent(generation) else { return }
                // Esc 那条保底路要的是"到此为止已经转出来的字"，和进度条显不显示无关
                self.deliveredDraft = draft
                // 手上有段落可交付了：Esc 这会儿是"收尾并输入"，胶囊必须当场改口
                self.overlay.setCancelFinishes(
                    Self.escFinishesEarly(completedSegments: done,
                                          hasLiveParts: !self.liveParts.isEmpty,
                                          isSkillSession: self.skillSession))
                guard total > 1 else { return }
                self.overlay.updateProcessing(
                    label: Self.segmentLabel(usesCloud: usesCloud, done: done, total: total),
                    draft: draft)
            }) { [weak self] outcome in
            guard let self = self, self.isCurrent(generation) else { return }
            // 「用户已经按过 Esc」这件事必须在清指针**之前**取出来（清完再读永远是 nil）：
            // 它是下面那道回落判据的最后一道保险，见 userStopped
            let userStopped = self.inflightTranscription?.isCancelled ?? false
            self.inflightTranscription = nil
            // 识别这一段结束了，后面是润色/指令：那里按 Esc 是真取消，胶囊改回「取消」
            self.overlay.setCancelFinishes(false)
            // 云端炸了先想退路：本地模型在就整段重跑一遍本地识别，用户一个字都不丢。
            // 判据是纯函数（CloudFallbackDecision），引擎自己不做这个决定。
            // userStopped 让「用户停止」永远优先于「自动回落」：用户按了 Esc 之后在飞的那一段
            // 才超时失败的话，把整段音频再本地重跑一遍（几十秒冷启动 + 整段插入）完全是无视他。
            if usesCloud, let failure = outcome.failure, !outcome.cancelled, !userStopped {
                switch CloudFallbackDecision.decide(partialText: outcome.text,
                                                    localModelAvailable: QwenEngine.shared.isModelAvailable) {
                case .retryLocally:
                    Log.warn("Cloud transcription failed — retrying on the local engine")
                    // 原因挂进本轮附注，交付时会并进结果提示：用户得知道这一段是本地转的
                    self.addSessionNote(CloudFallbackDecision.fallbackNote(reason: failure.message))
                    self.overlay.showProcessing(Self.transcribingLabel(usesCloud: false))
                    self.startTranscription(engine: QwenEngine.shared, usesCloud: false,
                                            samples: samples, committed: committed,
                                            language: language,
                                            faintAudio: faintAudio,
                                            // 本地这一遍多半是冷的（云端用户不会预加载模型）
                                            isColdStart: !QwenEngine.shared.isModelReady,
                                            tASR: DispatchTime.now(), generation: generation)
                    return
                case .deliverPartial, .reportFailure:
                    // 没有本地退路：已经转出来的段落照常交付、什么都没有就报错——
                    // 这两件事 resolve() 本来就在做，不必在这里另起一套
                    break
                }
            }
            switch self.resolve(outcome, committed: committed) {
            case .failure(let error):
                Log.error("Transcription failed: \(error.message)")
                self.phase = .idle
                // Esc 那一刻可能已经落过一条保底记录：记录本身留着（那正是"取消也不丢字"），
                // 但指针到此为止——绝不能让下一轮口述去补全上一轮的那一条
                self.pendingHistoryID = nil
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
                    self.pendingHistoryID = nil
                    self.overlay.flashError(tr("声音太小，请靠近麦克风再试",
                                               "Too quiet — move closer to the microphone and try again"))
                    Sounds.playError()
                    return
                }
                // 词汇表"错写=正写"硬替换：进入润色/指令之前先做确定性纠正
                let rawText = TextPostProcessor.applyVocabReplacements(transcribed)
                guard !rawText.isEmpty else {
                    self.phase = .idle
                    self.pendingHistoryID = nil
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
                    // 本机模型（Ollama / LM Studio）那一档不需要 Key，照样能跑指令 → 判"配没配"
                    // 一律走 LLMClient.isConfigured，别再直接看钥匙串
                    if !LLMClient.isConfigured {
                        // 句子里的键名一律用 plainName（全名、不带括号里的符号）：
                        // 菜单栏和引导都这么写，这一条用 displayName 的话，英文那句里会冒出两对括号
                        let keyName = Settings.shared.hotkey.plainName
                        self.phase = .idle
                        // 提示里多一个可点的「去配置」：话还是那句"纯输入请轻点"，
                        // 但别让用户读完之后还得自己去菜单栏找设置页。
                        // 铁律不动：不做剪贴板兜底救字、不替他把这次长按当成轻点。
                        self.overlay.flashError(
                            tr("指令模式需配置 API Key；纯语音输入请「轻点」\(keyName)（而非长按）",
                               "Command mode needs an API key. For dictation, tap \(keyName) (don't hold)"),
                            actionLabel: tr("去配置", "Set up")) { [weak self] in
                                self?.onNeedAISettings?()
                            }
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
                // Esc 部分交付那一刻可能已经落过一条保底记录（saveCancelSafetyHistory）：
                // 那就把它就地改写成完整原文，别让同一轮口述在历史里占两行。
                if let id = self.pendingHistoryID {
                    HistoryStore.shared.replaceRaw(id: id, raw: rawText)
                } else {
                    self.pendingHistoryID = HistoryStore.shared.addRaw(rawText)
                }
                let level = Settings.shared.polishLevel
                if level != .off, LLMClient.isConfigured {
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
                        // 缓存命中 / 实际档位（Responses 才报）：取走即清空，绝不把上一轮的数记到这一轮。
                        // 润色永远不联网，所以这里不会有来源。
                        self.pendingMetric?.absorb(LLMUsageSink.shared.take())
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
        // 录音中已经预转写好几分钟的那种会话：句柄刚拿到手，第一次 Esc 就已经是
        // "收尾并输入"了（committed 不是空的）。胶囊得从一开始就写对
        syncCancelAffordance()
    }

    /// 分段识别的结果 → 这一轮该怎么走。
    ///
    /// 核心规矩：**尾巴没转完不等于这一轮作废**。第 3 段炸了、或者用户在第 2 段之后按了 Esc，
    /// 前面那些段是用户实打实说过的话，照常交付，只在提示里说清尾巴没转。
    /// 两个例外：一个字都没有（和从前一样按失败处理）；指令模式（半条指令绝不能拿去执行）。
    private func resolve(_ outcome: TranscriptionOutcome, committed: String = "") -> Result<String, MTError> {
        if skillSession, !outcome.isComplete {
            return .failure(outcome.failure
                            ?? MTError(tr("指令没说完就停了，请重新按住说一次",
                                          "The command was cut short — hold the key and say it again")))
        }
        // 录音中预转写好的前半段 + 松手后转的尾巴。拼接规则与引擎内部分段逐字同源。
        let text = TextPostProcessor.joinSegments([committed, outcome.text])
        if text.isEmpty {
            if let failure = outcome.failure { return .failure(failure) }
            if outcome.cancelled { return .failure(MTError(tr("已取消", "Cancelled"))) }
            // 真的什么都没识别出来：交给下游那句"没有听到内容"，别在这里另起一套提示
            return .success("")
        }
        if !outcome.isComplete {
            let done = outcome.completedSegments
            let total = outcome.totalSegments
            Log.warn("Partial transcript delivered segments=\(done)/\(total)"
                     + " committed=\(committed.count)chars"
                     + " reason=\(outcome.cancelled ? "cancelled" : "failed")")
            // 录音中已经转好了前面几段、只有尾巴没转出来：段号对用户毫无意义（他看到的是
            // 一整段口述），说清"结尾那一小截没转出来"就够了
            if !committed.isEmpty, done == 0 {
                addSessionNote(outcome.cancelled
                    ? tr("已停在结尾那一小段之前，最后一截没有转写",
                         "Stopped before the final part - the tail was not transcribed")
                    : tr("结尾那一小段识别失败，前面的内容已输入",
                         "The final part failed to transcribe - everything before it was inserted"))
                return .success(text)
            }
            addSessionNote(outcome.cancelled
                ? tr("已停在第 \(done)/\(total) 段，后面的没有转写",
                     "Stopped after part \(done) of \(total) — the rest was not transcribed")
                : tr("第 \(done + 1) 段识别失败，已输入前 \(done) 段",
                     "Part \(done + 1) failed to transcribe — parts 1-\(done) were inserted"))
        }
        return .success(text)
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
    /// 悬浮窗那句话后面挂上「已联网 · 3 来源」。联网是**花了钱**的动作，
    /// 用户必须当场看见它发生了，而不是只能事后翻历史。
    static func noteWithSources(_ note: String, _ usage: LLMUsage?) -> String {
        guard let usage = usage, !usage.citations.isEmpty else { return note }
        return note + tr("；", "; ") + LLMCatalog.webSearchNote(citationCount: usage.citations.count)
    }

    /// 返回这一趟顺带回来的用量（含联网来源）——沉淀点只能取一次，所以由这里统一取走再交给调用方，
    /// 谁都不许再去 take() 第二回（第二次拿到的是 nil，来源会凭空消失）。
    @discardableResult
    private func noteCommandLatency(since start: DispatchTime, ok: Bool) -> LLMUsage? {
        let ms = Log.ms(since: start)
        Log.info("Timing command=\(ms)ms model=\(Settings.shared.currentCommandModel) ok=\(ok)")
        // 失败那一次也记：用户感觉到的等待是实打实的
        pendingMetric?.polishMs = ms
        let usage = LLMUsageSink.shared.take()
        pendingMetric?.absorb(usage)
        if let count = usage?.citations.count, count > 0 {
            Log.info("Command web search returned \(count) sources")
        }
        return usage
    }

    /// 技能：自由指令——指令模式下的"万能入口"
    private func runFreeform(instruction: String, raw: String, isColdStart: Bool, generation: Int) {
        overlay.showProcessing(tr("执行指令中…", "Running command…"))
        let tModel = DispatchTime.now()
        inflightRequest = AgentService.freeform(instruction: instruction) { [weak self] result, failure in
            guard let self = self, self.isCurrent(generation) else { return }
            self.inflightRequest = nil
            let usage = self.noteCommandLatency(since: tModel, ok: result != nil)
            if let result = result {
                // 词汇表硬替换在每个产出点各做一次；deliver 里不再做，否则同一串文本会被替换两趟
                let finalText = TextPostProcessor.applyVocabReplacements(result)
                self.deliver(raw: raw, final: finalText,
                             note: Self.noteWithSources(tr("已输入指令结果", "Command result inserted"), usage),
                             coldStart: isColdStart, citations: usage?.citations ?? [])
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
            let usage = self.noteCommandLatency(since: tModel, ok: result != nil)
            guard let result = result else {
                self.phase = .idle
                self.overlay.flashError(tr("指令执行失败（", "Command failed (") + (failure ?? tr("未知", "unknown")) + tr("）", ")"))
                Sounds.playError()
                return
            }
            // 词汇表硬替换在每个产出点各做一次；deliver / copyToClipboard 里不再做
            let finalText = TextPostProcessor.applyVocabReplacements(result)
            let citations = usage?.citations ?? []
            switch action {
            case .modify:
                self.deliver(raw: raw, final: finalText,
                             note: Self.noteWithSources(tr("已替换选中文本", "Selection replaced"), usage),
                             coldStart: isColdStart, citations: citations)
            case .new:
                self.deliver(raw: raw, final: finalText,
                             note: Self.noteWithSources(tr("已输入指令结果", "Command result inserted"), usage),
                             coldStart: isColdStart, citations: citations)
            case .reply:
                self.copyToClipboard(raw: raw, result: finalText,
                                     note: Self.noteWithSources(tr("回复草稿已复制——点到输入框按 ⌘V", "Reply draft copied — click the input field and press ⌘V"), usage),
                                     citations: citations)
            case nil:
                // 意图行没解析出来：进剪贴板最安全，不碰选区
                self.copyToClipboard(raw: raw, result: finalText,
                                     note: Self.noteWithSources(tr("结果已复制到剪贴板——按 ⌘V 粘贴", "Result copied — press ⌘V to paste"), usage),
                                     citations: citations)
            }
        }
    }

    /// 结果进剪贴板（不自动粘贴），记录历史并提示
    private func copyToClipboard(raw: String, result: String, note: String,
                                 citations: [Citation] = []) {
        phase = .idle
        let tDeliver = DispatchTime.now()
        // 只做标点归一：词汇表硬替换已经在各产出点做过了。在这里再做一次的话，
        // 纯听写路径（final 就是已替换过的 rawText）会被替换两趟，链式词表串成链。
        let final = TextPostProcessor.fixMixedPunctuation(result)
        HistoryStore.shared.add(raw: raw, polished: final, citations: citations)
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
            let usage = self.noteCommandLatency(since: tModel, ok: result != nil)
            if let result = result {
                // 词汇表硬替换在每个产出点各做一次；copyToClipboard 里不再做
                let finalText = TextPostProcessor.applyVocabReplacements(result)
                self.copyToClipboard(raw: raw, result: finalText,
                                     note: Self.noteWithSources(tr("回复草稿已复制——点到输入框按 ⌘V", "Reply draft copied — click the input field and press ⌘V"), usage),
                                     citations: usage?.citations ?? [])
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
    /// 这一段文字往哪儿送。纯函数、可单测：判据只有一条——
    /// 引导窗开着且停在「试一下」那一页就直接落字，其余一律走剪贴板 + ⌘V。
    /// 抽出来是因为"走错路"的代价是用户一个字都看不到，而那是查不出来的静默失败。
    enum DeliveryRoute: String {
        /// 直接写进我们自己的输入框（TranscriptSink）
        case sink
        /// 直接写进自家 key window 的 first responder（OwnWindowInserter）：
        /// 开录时人就在 MicType 自己的窗口里，而引导窗根本没开（设置窗口的「自定义规则」
        /// 「词汇表」这些框）。**这条路不能走 ⌘V**——MicType 从没装过带 Edit 的主菜单，
        /// Edit → Paste 这个 key equivalent 没有接收者，那一下按键谁都不接（4.1.5 bug）。
        case ownWindow = "own-window"
        /// 只写剪贴板，**不**模拟 ⌘V：开录时人就在 MicType 自己的窗口里，而这段字接不住
        /// （引导开着但停在别的页）。⌘V 永远打向"此刻的键盘焦点"，那一刻的焦点是我们自己的
        /// 控件——粘进去比不粘进去糟得多。
        case clipboard
        /// 常规：写剪贴板 + 模拟 ⌘V 打到光标处（TextInserter）
        case inserter
    }

    /// - sinkReady: 引导窗开着、且正停在「试一下」那一页
    /// - sinkRegistered: 引导窗开着（停在哪一页都算）
    /// - targetIsSelf: 开录那一刻的前台应用就是 MicType 自己（认不出来也算，行为与从前一致）
    /// - targetIsKnown: 那一刻真的读到了前台应用的 bundle id
    ///
    /// 第一条判据是**开录时人在哪个应用**，不是引导窗开没开：引导留在后台、人在备忘录里
    /// 轻点的那一段，字必须落在备忘录的光标处——4.1.0 之前只看 isReady()，那一段会被
    /// 悄悄追加进后面那扇引导窗的框里，备忘录一个字都没有，还没有剪贴板可退。
    ///
    /// 人在自家窗口、引导又没开时走 `.ownWindow`（4.1.5 之前是 `.inserter`）：那条路会
    /// 发一下合成 ⌘V，而 ⌘V 在 MicType 自己的窗口里从来就没有接收者——用户在设置的
    /// 「自定义规则」里说了一句，日志写着 `outcome=pasted`，框里一个字都没有。
    static func deliveryRoute(sinkReady: Bool, sinkRegistered: Bool,
                              targetIsSelf: Bool, targetIsKnown: Bool = true) -> DeliveryRoute {
        guard targetIsSelf else { return .inserter }
        if sinkReady { return .sink }
        if sinkRegistered { return .clipboard }
        // 认不出前台应用那一档（targetBundleID 为空）继续走老路：那一刻 key window 多半是 nil，
        // 人也未必在我们的窗口里，往当前焦点盲粘一下仍然是最合理的猜测
        return targetIsKnown ? .ownWindow : .inserter
    }

    /// 这段字最后**落在哪儿**。路由是"打算走哪条"，这一层是"问过输入框之后真正走成了哪条"。
    /// 两者不是一回事：挑中了 .sink，而那一刻框接不住（窗口刚被关掉、刚翻到别的页），
    /// 字必须退到剪贴板——**绝不能掉在地上**，也绝不能改去 ⌘V（这条路的前提就是开录时
    /// 人在 MicType 自己的窗口里，一下 ⌘V 只会打进我们自己的控件）。
    ///
    /// 为什么也抽成纯函数：这半步过去只活在 deliver() 里（private、TextInserter 是静态的、
    /// 都注入不进来），把它写成"接不住就 return"——字静默消失——572 个测试一个都不会红。
    enum DeliveryOutcome: String {
        /// 直接落进了「试一下」那个框
        case sink
        /// 直接落进了自家窗口里那个输入框
        case ownWindow = "own-window"
        /// 只留在剪贴板上，等用户自己按 ⌘V
        case clipboard
        /// 常规：剪贴板 + 模拟 ⌘V 打到光标处
        case inserter
    }

    /// - sinkAccepted: 这一刻真的问过 TranscriptSink，它说接住了（route != .sink 时恒为 false）
    /// - ownWindowInserted: 这一刻真的往自家输入框写过，而且**回读确认**写进去了
    ///   （route != .ownWindow 时恒为 false）
    ///
    /// 两条"自家"路的失败都退到剪贴板，绝不退成 ⌘V：这两条路的前提就是开录时人在
    /// MicType 自己的窗口里，那一下 ⌘V 要么打进我们自己的控件、要么（多数时候）
    /// 根本没人接——两种结果都比留在剪贴板糟。
    static func deliveryOutcome(route: DeliveryRoute, sinkAccepted: Bool,
                                ownWindowInserted: Bool = false) -> DeliveryOutcome {
        switch route {
        case .sink: return sinkAccepted ? .sink : .clipboard
        case .ownWindow: return ownWindowInserted ? .ownWindow : .clipboard
        case .clipboard: return .clipboard
        case .inserter: return .inserter
        }
    }

    private func deliver(raw: String, final text: String, note: String, warning: Bool = false,
                         coldStart: Bool = false, revertible: Bool = false,
                         citations: [Citation] = []) {
        // 只做标点归一：词汇表硬替换已经在各产出点做过了（识别原文 / 润色结果 / 各技能结果），
        // 这里再做一趟等于对同一串文本替换两次，「萍果=苹果」+「苹果=Apple」会被串成链
        let finalText = TextPostProcessor.fixMixedPunctuation(text)
        // 润色之前已经落过一条 raw（纯听写路径）就补全它，别再插一条新的——
        // 用户看到的应该是一条"识别原文 + 最终文字"，不是同一句话的两行记录。
        // 联网来源（自由指令 / 改选区那条路才有）跟着补全一起写进去，别在这里掉字。
        if let id = pendingHistoryID {
            HistoryStore.shared.complete(id: id, polished: finalText, citations: citations)
            pendingHistoryID = nil
        } else {
            HistoryStore.shared.add(raw: raw, polished: finalText, citations: citations)
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
        // 目标应用、走了哪条路、结果如何——每一次交付都把这三样写进日志。
        // 4.0.1 那次「试一下不落字」之所以只能靠猜，就是因为日志里这三样一样都没有。
        let logTarget = target.isEmpty ? "unknown" : target
        // 开录那一刻人在不在 MicType 自己的窗口里——两条"不走常规粘贴"的路都以它为前提
        let targetIsSelf = target.isEmpty || target == (Bundle.main.bundleIdentifier ?? "")
        let route = Self.deliveryRoute(sinkReady: TranscriptSink.isReady(),
                                       sinkRegistered: TranscriptSink.isRegistered,
                                       targetIsSelf: targetIsSelf,
                                       targetIsKnown: !target.isEmpty)
        Log.info("Deliver start chars=\(finalText.count) target=\(logTarget) route=\(route.rawValue)")
        // 插入这一段也计时：它包含切前台（最长 1.2s）+ 粘贴时序，是用户真实等待的一部分。
        // 草稿在这里定格成局部变量——回调最长要等一秒多，那时 pendingMetric 可能已经是下一轮的了。
        let tInsert = DispatchTime.now()
        let metric = pendingMetric
        pendingMetric = nil
        // accept 有副作用（接住了就写进框里），所以只有挑中 .sink 才问得出口
        let accepted = route == .sink && TranscriptSink.accept(finalText)
        if route == .sink, !accepted {
            // 注册着却没接住（窗口刚被关掉、或刚翻到别的页）：退到剪贴板那条路。
            // 不退回粘贴是因为这一路的前提就是"开录时人在 MicType 自己的窗口里"，
            // 一下 ⌘V 只会打进我们自己的控件
            Log.warn("Deliver sink declined the text - leaving it on the clipboard")
        }
        // 自家窗口那条路同理：问过才算数。写不进去（没有可写的框 / 是密码框）就照实说，
        // 绝不像 4.1.5 那样报一次 pasted 了事
        let ownWindow = route == .ownWindow ? OwnWindowInserter.insert(finalText)
                                            : OwnWindowInserter.Outcome.noTarget
        switch Self.deliveryOutcome(route: route, sinkAccepted: accepted,
                                    ownWindowInserted: ownWindow == .inserted) {
        case .sink:
            let insertMs = Log.ms(since: tInsert)
            Log.info("Deliver done target=\(logTarget) path=sink outcome=accepted insert=\(insertMs)ms")
            // 指标照记：这一轮的耗时是既成事实，和走哪条路无关
            if let metric = metric { Metrics.shared.record(metric.finished(insertMs: insertMs)) }
            // 这条路**不**开放「换回识别原文」：撤销是对目标应用发一次 ⌘Z，
            // 而这段字根本不是粘进去的，⌘Z 只会撤掉用户在别处的编辑。
            // 提示与声音和粘贴那条路逐字一致（warning 时绝不打绿勾）。
            if warning {
                overlay.flashError(note)
            } else {
                overlay.flashSuccess(note)
            }
            Sounds.playSuccess()
            return
        case .ownWindow:
            let insertMs = Log.ms(since: tInsert)
            Log.info("Deliver done target=\(logTarget) path=own-window outcome=inserted"
                     + " insert=\(insertMs)ms")
            if let metric = metric { Metrics.shared.record(metric.finished(insertMs: insertMs)) }
            // 和 .sink 同理，这条路也**不**开放「换回识别原文」：撤销是对目标应用发一次 ⌘Z，
            // 而 ⌘Z 和 ⌘V 一样在我们自己的窗口里没有接收者。用户就在那个框里，
            // 要改自己改就是了（insertText 走的是标准编辑通道，框自己的 ⌘Z 照样能撤）。
            if warning {
                overlay.flashError(note)
            } else {
                overlay.flashSuccess(note)
            }
            Sounds.playSuccess()
            return
        case .clipboard:
            let insertMs = Log.ms(since: tInsert)
            TextInserter.copyForManualPaste(finalText)
            if route == .ownWindow {
                Log.warn("Deliver done target=\(logTarget) path=own-window"
                         + " outcome=\(ownWindow.rawValue) insert=\(insertMs)ms"
                         + " - text left on the clipboard")
            } else {
                Log.info("Deliver done target=\(logTarget) path=clipboard outcome=copied"
                         + " insert=\(insertMs)ms")
            }
            if let metric = metric { Metrics.shared.record(metric.finished(insertMs: insertMs)) }
            // 绝不打绿勾：这段字**没有**落到任何输入框里。三种情形三句话——
            // 「这里没框可输入」那句尤其不能写成"按 ⌘V"：⌘V 在我们自己的窗口里没人接，
            // 让用户在这儿按一辈子也没用（这正是 4.1.5 那个 bug 的根因）
            switch (route, ownWindow) {
            case (.ownWindow, .secureField):
                overlay.flashError(tr("密码框里不能听写——文字已复制到剪贴板",
                                      "Can't dictate into a password field — text copied to clipboard"))
            case (.ownWindow, _):
                overlay.flashError(tr("这里没有可以输入文字的框——文字已复制到剪贴板",
                                      "No text field to type into here — text copied to clipboard"))
            default:
                overlay.flashError(tr("MicType 自己的窗口在前台——文字已复制到剪贴板，按 ⌘V 粘贴",
                                      "MicType's own window is frontmost - text copied to clipboard, press ⌘V to paste"))
            }
            Sounds.playError()
            return
        case .inserter:
            break
        }
        TextInserter.insert(finalText, targetBundleID: target,
                            allowClipboardRestore: true,
                            conservativePaste: coldStart) { [weak self] outcome in
            guard let self = self else { return }
            let insertMs = Log.ms(since: tInsert)
            Log.info("Deliver done target=\(logTarget) path=inserter"
                     + " outcome=\(outcome == .pasted ? "pasted" : "clipboard-only") insert=\(insertMs)ms")
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
