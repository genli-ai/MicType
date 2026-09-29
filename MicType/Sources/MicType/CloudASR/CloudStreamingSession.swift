import Foundation

// MARK: - 云端实时识别的接线层（OpenAI 实时客户端 ↔ DictationController）
//
// 协议客户端什么都不决定（见 RealtimeTransport.swift 顶部那段）。这里才是做决定的地方：
// 这一轮开不开实时、草稿往哪送、松手时发到第几个采样、断了之后谁接手。
//
// 一句话说清这条路在干什么：**按下热键就把 socket 连上，录音期间边说边把新采样传上去，
// 松手只剩"把最后一截发完 + 一条收尾"**。实测松手到终稿 OpenAI 0.67–1.04 秒，
// 与录音长度无关；而整段上传那条路上是 4.5s→1.2s、22s→3.0s、71s→8.6s（4.x 实测）。
// 5.1.0 起只有 OpenAI 一家（阿里云整档删除）；上面的结构留着——下一步要在它上面做混合转写。

// MARK: - 「这条链路的实时用不了」的记忆

/// **内存态，键是「服务商 + 主机」**（4.2.2 起；5.1.0 起只剩 OpenAI 官方那一台，
/// 键的形状留着不改，免得以后再接一条链路时重写这层）。
///
/// 为什么不落盘："服务商那边什么时候给这把 Key 开通实时"我们无从得知——
/// 落盘等于给用户留一条他看不见、也没地方清掉的坏设置。重启一次就重新试，代价只是一次握手。
///
/// 被记住之后，这条链路上的每一句话都走整段上传，**行为与 4.1.6 完全一致**，
/// 所以它只记一行 WARN，不打扰用户——同步那条路能用，就不算错误。
enum CloudStreamingAvailability {

    private static let lock = NSLock()
    private static var unsupported: Set<String> = []

    private static func key(provider: CloudASRProvider, host: String) -> String {
        provider.rawValue + "@" + host
    }

    static func isUnsupported(provider: CloudASRProvider, host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return unsupported.contains(key(provider: provider, host: host))
    }

    static func markUnsupported(provider: CloudASRProvider, host: String, reason: String) {
        lock.lock()
        let isNew = unsupported.insert(key(provider: provider, host: host)).inserted
        lock.unlock()
        guard isNew else { return }
        Log.warn("CloudASR streaming unavailable provider=\(provider.rawValue) "
                 + "host=\(host) reason=\(reason)")
    }

    /// 刚刚真的跑通过一次（把开关拨开那一下的探针）：把旧记忆清掉
    static func markAvailable(provider: CloudASRProvider, host: String) {
        lock.lock()
        let removed = unsupported.remove(key(provider: provider, host: host)) != nil
        lock.unlock()
        if removed {
            Log.info("CloudASR streaming available again provider=\(provider.rawValue) "
                     + "host=\(host)")
        }
    }

    static func resetForTesting() {
        lock.lock()
        unsupported = []
        lock.unlock()
    }
}

// MARK: - 一次实时会话

/// 一次听写的实时会话，**同时就是这一轮的 SpeechEngine**。
///
/// 为什么让它实现 SpeechEngine：松手之后 DictationController 照常调一次
/// `transcribe(samples:)`，这里只要把「还没发出去的那一截」补发完再收尾就行——
/// 于是下游（交付、历史、云端失败重试、Esc 部分交付）一行都不用改，
/// 整条链路仍然只有一套。客户端只经由 RealtimeTranscriptionClient 这一个接口被使用。
final class CloudStreamingSession: SpeechEngine {

    private let config: CloudASRConfig
    private let client: RealtimeTranscriptionClient
    /// 实时走不通时接手的那条路（现有的整段上传，行为与 4.1.6 完全一致）
    private let fallback: CloudASREngine

    /// 中间结果 → 悬浮窗灰字草稿（主线程）
    var onDraft: ((String) -> Void)?
    /// 实时这条路在**松手之前**就断了（主线程）：调用方据此把本机的灰字预览重新打开——
    /// 那条路本来就有草稿，别让这一段录音一个字都看不见
    var onStreamingLost: (() -> Void)?

    /// 已经交给实时会话的采样数。**只在主线程读写**（调用方按它从录音缓冲里切下一截）
    private(set) var queuedSampleCount = 0
    /// 实时这条路还活着吗（主线程）
    private(set) var isLive = true

    /// 松手之后在等的那个收口（主线程）
    private var awaiting: ((Result<RealtimeTranscript, RealtimeFailure>) -> Void)?
    /// 松手**之前**就断掉的那次失败（主线程）：决定这一轮交给谁，见 route(afterLosing:)
    private var lostFailure: RealtimeFailure?

    /// 这一句松手时跑过整段上传那条通道（混合转写，见 runHybrid）。
    /// DictationController 据此不再做「失败 → 整段再传一次」：那一趟已经跑过、也已经失败了，
    /// 再传一遍只是让用户多等一轮、多付一次钱。
    private(set) var ranBatchLane = false

    // MARK: 建

    /// 实时链路的"地址"——记忆的键，也是日志里那个 host。OpenAI 是固定的官方域名
    /// （没有"选主机"这回事，所以日志里照写、不用打码）。
    static let streamHost = "api.openai.com"

    /// 实时用的是哪个模型（日志与界面都读它）
    static var streamModel: String { OpenAIRealtimeClient.model }

    /// 这一轮开不开实时。三道闸门，缺一不可：
    ///   1. 钥匙串里有 Key；
    ///   2. OpenAI 必须是**官方接口**——把 Base URL 指向第三方网关的人没有这条路
    ///      （判据与 PrivacyCopy 的留存那句同源：LLMClient.usesResponsesAPI）；
    ///   3. 这条链路这次运行里还没被判过「实时不可用」。
    /// 任何一道不过就返回 nil —— 调用方照常走整段上传。
    static func make(config: CloudASRConfig, fallback: CloudASREngine,
                     officialOpenAI: Bool = CloudASRSettings.openAIUsesOfficialEndpoint)
        -> CloudStreamingSession? {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard officialOpenAI else { return nil }
        guard !CloudStreamingAvailability.isUnsupported(provider: config.provider,
                                                        host: streamHost) else { return nil }
        return CloudStreamingSession(config: config, fallback: fallback)
    }

    /// 建实时客户端。**全文件唯一的构造点**：真会话与开关探针拿到的是同一份 session.update。
    static func makeClient(config: CloudASRConfig) -> RealtimeTranscriptionClient {
        let prefix = "CloudASR stream provider=\(config.provider.rawValue) "
        var options = OpenAIRealtimeClient.Options()
        // 语言提示（默认 [zh, en, ar]，见 CloudASRSettings.defaultLanguageHints）。
        // 这边传错不会翻译，所以是安全的；服务端不认这个字段时客户端会摘掉它重发（OptionalField.languages）
        options.languages = config.languageHints
        // **词汇表在这一档真的管用**：实测专名五次里五次纠正
        options.keywords = OpenAIRealtimeClient.keywords(from: config.vocabulary)
        return OpenAIRealtimeClient(
            config: OpenAIRealtimeClient.Config(apiKey: config.apiKey, options: options),
            log: { Log.info(prefix + $0) })
    }

    /// - client: 单测在这里塞一个装着假 socket 的客户端
    init(config: CloudASRConfig, fallback: CloudASREngine,
         client: RealtimeTranscriptionClient? = nil) {
        self.config = config
        self.fallback = fallback
        self.client = client ?? Self.makeClient(config: config)
    }

    // MARK: 录音期间

    /// 建连。**按下热键那一刻就调**（与 prewarm 同一时机），别等第一帧音频：
    /// 握手约 0.8 秒，等到有音频再连等于把它原样加在用户的等待上。
    func start() {
        Log.info("CloudASR stream start provider=\(config.provider.rawValue) "
                 + "model=\(Self.streamModel) host=\(Self.streamHost)")
        client.onPartial = { [weak self] draft in self?.onDraft?(draft) }
        client.onFinish = { [weak self] result in self?.settle(result) }
        client.start()
    }

    /// 录音中把新录到的这一截交上去（主线程，跟着录音电平回调走，约每 85 ms 一次）。
    /// 连上之前它先留在客户端的缓冲里，配置确认之后按各家的节流补发。
    /// **永远送 16 kHz**：要不要重采样（OpenAI 那边要 24 kHz）是客户端自己的事。
    func enqueue(_ samples: [Float]) {
        guard isLive, !samples.isEmpty else { return }
        queuedSampleCount += samples.count
        client.append(samples: samples)
    }

    /// Esc / 静音门判定「没说话」：**不收尾，直接掐掉**。
    /// 已经传出去的那几秒收不回来——这一点在隐私文案里当面写着。
    func abandon() {
        isLive = false
        awaiting = nil
        onDraft = nil
        onStreamingLost = nil
        client.cancel()
    }

    /// 客户端的结局落地（主线程）。两种时机，行为完全不同：
    ///   • 松手之后（有人在等）→ 直接把结果交给它；
    ///   • 还在录音（没人等）→ 本轮另找出路，并把本机预览重新打开。
    private func settle(_ result: Result<RealtimeTranscript, RealtimeFailure>) {
        isLive = false
        // 5.3.0 起屏幕上只说一句话（UX 方案 §3 H），服务端的错误码 / 断线原因只在这一行里
        if case .failure(let failure) = result {
            Log.warn("CloudASR realtime failed reason=\(failure.logReason)")
        }
        if case .failure(let failure) = result, failure.disablesStreaming {
            CloudStreamingAvailability.markUnsupported(provider: config.provider, host: Self.streamHost,
                                                       reason: failure.logReason)
        }
        if let waiter = awaiting {
            awaiting = nil
            waiter(result)
            return
        }
        if case .failure(let failure) = result {
            // 松手之前就断了：记下**为什么**断的——是"这条链路没有实时接口"还是"网断了"，
            // 决定这一轮该交给谁（见 route(afterLosing:)）
            lostFailure = failure
            onStreamingLost?()
        }
    }

    // 「松手之前断了交给谁」5.0.0 只剩一条路：**整段上传同一家的同步接口**
    // （LostRoute / route(afterLosing:) 一起删掉）。4.x 里偶发断线优先回落本机模型，
    // 而本机模型已经没有了——音频一个采样都没丢，同步那条路是唯一也是正确的退路。

    // MARK: - SpeechEngine

    var engineName: String { fallback.engineName }
    /// 云端没有"模型文件"概念，可用 = 有 Key（与 CloudASREngine 同一口径）
    var isModelAvailable: Bool { fallback.isModelAvailable }
    var isModelLoaded: Bool { false }
    func preload() {}
    func unloadModel() {}

    /// 松手之后的那一步：把还没发出去的尾巴补发完 → 收尾 → 等终稿。
    ///
    /// - samples: 这一整段录音（云端这一路没有录音中的预转写，所以它就是全部音频）。
    ///   **发送到的采样数必须恰好等于这一段**，不多不少——多发一截就是把上一轮的尾巴
    ///   混进这一句，少发一截就是用户眼睁睁看着最后几个字消失。
    @discardableResult
    func transcribe(samples: [Float], language: String?, previousText: String,
                    onSegment: ((String, Int, Int) -> Void)?,
                    completion: @escaping (TranscriptionOutcome) -> Void) -> TranscriptionHandle {
        let outer = TranscriptionHandle()
        var delivered = false
        func deliver(_ outcome: TranscriptionOutcome) {
            guard !delivered else { return }
            delivered = true
            completion(outcome)
        }

        // 实时这条路在松手之前就断了（没连上 / 录音中掉线）：音频一个采样都没丢，
        // 整段交给同一家的同步接口重传一遍
        guard isLive else {
            if lostFailure != nil {
                Log.warn("CloudASR stream lost before release — uploading the whole take instead")
            }
            return forward(samples: samples, language: language, previousText: previousText,
                           onSegment: onSegment, outer: outer, deliver: deliver)
        }

        outer.setCancelHandler { [weak self] in
            self?.abandon()
            // 交付不能同步做：cancel() 是在 DictationController.cancel() 里调的，
            // 同步收口会抢在它落保底历史、改悬浮窗文案之前跑完（与 CloudASREngine 同一条）
            DispatchQueue.main.async {
                deliver(TranscriptionOutcome(text: "", completedSegments: 0, totalSegments: 1,
                                             failure: nil, cancelled: true))
            }
        }

        if queuedSampleCount < samples.count {
            let tail = Array(samples[queuedSampleCount...])
            queuedSampleCount += tail.count
            client.append(samples: tail)
        }
        let seconds = Double(queuedSampleCount) / Double(WAVEncoder.defaultSampleRate)
        // 整段为准、实时兜底（5.1.0）：不超过 60 秒的句子，实时收尾的同时把整段再传一次，
        // 谁的字进输入框由 HybridSelection 说了算。更长的句子照旧只等实时（整段只作失败退路）
        if seconds <= HybridSelection.maxAudioSeconds {
            return runHybrid(samples: samples, language: language, previousText: previousText,
                             audioSeconds: seconds, outer: outer, deliver: deliver)
        }
        awaiting = { [weak self] result in
            guard let self = self else { return }
            guard !outer.isCancelled else {
                deliver(TranscriptionOutcome(text: "", completedSegments: 0, totalSegments: 1,
                                             failure: nil, cancelled: true))
                return
            }
            switch result {
            case .success(let transcript):
                // 只清**终稿**：中间结果是悬浮窗上的灰字草稿，它每 100 ms 就重画一次，
                // 边说边删口水词只会让草稿在眼前跳。清理的口径与本机引擎逐字同源
                // （TextPostProcessor.cleanTranscript）——4.3.3 之前云端这条路一个字都没清过。
                deliver(TranscriptionOutcome(text: TextPostProcessor.cleanTranscript(transcript.text),
                                             completedSegments: 1,
                                             totalSegments: 1, failure: nil, cancelled: false))
            case .failure(let failure):
                // 「这条链路不支持实时」不是一次故障：本句改走整段上传，
                // 行为与 4.1.6 完全一致，用户不该为此看到任何东西
                guard !failure.disablesStreaming else {
                    _ = self.forward(samples: samples, language: language,
                                     previousText: previousText, onSegment: onSegment,
                                     outer: outer, deliver: deliver)
                    return
                }
                // 偶发失败（断线 / 报错 / 终稿超时）：交给上层那条「云端失败 → 同步接口重试一次」，
                // 整段音频还在调用方手上，一个字都不会丢
                deliver(TranscriptionOutcome(text: "", completedSegments: 0, totalSegments: 1,
                                             failure: MTError(Self.message(for: failure),
                                                              action: Self.action(for: failure)),
                                             cancelled: false))
            }
        }
        client.finish(audioSeconds: seconds)
        return outer
    }

    // MARK: - 混合转写（整段为准、实时兜底）

    /// 一句话的两条通道到这一刻的样子。只在主线程读写（两条通道的回调都回主线程）。
    private final class HybridRace {
        enum Winner { case batch, realtime, none }

        let released = Date()
        let audioSeconds: Double
        var realtime: HybridSelection.Lane = .pending
        var batch: HybridSelection.Lane = .pending
        var realtimeText = ""
        var batchText = ""
        var realtimeFailure: MTError?
        var batchFailure: MTError?
        var realtimeAt: Date?
        var batchAt: Date?
        var winner: Winner?
        var timer: DispatchWorkItem?
        var batchHandle: TranscriptionHandle?

        init(audioSeconds: Double) { self.audioSeconds = audioSeconds }

        /// 某条通道落地时距松手多少毫秒；没落地是「-」（日志用）
        func ms(_ at: Date?) -> String {
            at.map { String(Int($0.timeIntervalSince(released) * 1000)) } ?? "-"
        }
    }

    /// 松手这一刻两条通道同时出发：实时收尾 + 整段上传（同一个 fallback 引擎，已经是 m4a）。
    /// 两条落地的文字都过同一套本地清理（实时那条在这里清，整段那条引擎按段清过了）。
    private func runHybrid(samples: [Float], language: String?, previousText: String,
                           audioSeconds: Double, outer: TranscriptionHandle,
                           deliver: @escaping (TranscriptionOutcome) -> Void) -> TranscriptionHandle {
        ranBatchLane = true
        let race = HybridRace(audioSeconds: audioSeconds)

        outer.setCancelHandler { [weak self] in
            // Esc：两条都掐掉，谁都不再进输入框
            race.timer?.cancel()
            race.winner = race.winner ?? HybridRace.Winner.none
            race.batchHandle?.cancel()
            self?.abandon()
            // 交付不能同步做（理由同上面那一支）
            DispatchQueue.main.async {
                deliver(TranscriptionOutcome(text: "", completedSegments: 0, totalSegments: 1,
                                             failure: nil, cancelled: true))
            }
        }

        race.batchHandle = fallback.transcribe(samples: samples, language: language,
                                               previousText: previousText,
                                               onSegment: nil) { [weak self] outcome in
            guard !outcome.cancelled else { return }   // 只有我们自己掐的才会是取消
            race.batchAt = Date()
            if let failure = outcome.failure {
                race.batch = .failed
                race.batchFailure = failure
            } else {
                race.batchText = outcome.text
                race.batch = Self.lane(for: outcome.text)
            }
            if race.winner != nil {
                // 实时已经赢了（窗口过了）：迟到的整段只记一行，丢掉
                if race.winner == .realtime {
                    Log.info("CloudASR hybrid batch arrived late batch=\(race.ms(race.batchAt))ms "
                             + "lane=\(race.batch) (discarded)")
                }
                return
            }
            self?.decideHybrid(race, outer: outer, deliver: deliver)
        }

        awaiting = { [weak self] result in
            race.realtimeAt = Date()
            switch result {
            case .success(let transcript):
                // 只清**终稿**（草稿不清，理由同上）
                race.realtimeText = TextPostProcessor.cleanTranscript(transcript.text)
                race.realtime = Self.lane(for: race.realtimeText)
            case .failure(let failure):
                // 「这条链路不支持实时」在 settle 里已经记住了；这一句整段本来就在路上
                race.realtime = .failed
                race.realtimeFailure = MTError(Self.message(for: failure),
                                               action: Self.action(for: failure))
            }
            guard race.winner == nil, !outer.isCancelled else { return }
            self?.decideHybrid(race, outer: outer, deliver: deliver)
        }
        client.finish(audioSeconds: audioSeconds)
        return outer
    }

    /// 清理之后有没有字
    private static func lane(for text: String) -> HybridSelection.Lane {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .usable
    }

    /// 每当一条通道落地、或者规则 2 的窗口到点，问一次 HybridSelection：用谁、还是再等。
    private func decideHybrid(_ race: HybridRace, outer: TranscriptionHandle,
                              deliver: @escaping (TranscriptionOutcome) -> Void) {
        guard race.winner == nil, !outer.isCancelled else { return }
        let since = race.realtimeAt.map { Date().timeIntervalSince($0) }
        let differ = race.realtime == .usable && race.batch == .usable
            && HybridSelection.scriptsDiffer(race.realtimeText, race.batchText)
        let step = HybridSelection.next(realtime: race.realtime, batch: race.batch,
                                        sinceRealtimeFinal: since, audioSeconds: race.audioSeconds,
                                        scriptsDiffer: differ)
        switch step {
        case .useBatch:
            if differ {
                // 只记文字系统的名字，不记任何文字
                Log.info("CloudASR hybrid scripts differ "
                         + "rt=\(HybridSelection.dominantScript(race.realtimeText).map { "\($0)" } ?? "-") "
                         + "batch=\(HybridSelection.dominantScript(race.batchText).map { "\($0)" } ?? "-") → batch")
            }
            finishHybrid(race, winner: .batch, deliver: deliver,
                         outcome: TranscriptionOutcome(text: race.batchText, completedSegments: 1,
                                                       totalSegments: 1, failure: nil, cancelled: false))
        case .useRealtime:
            finishHybrid(race, winner: .realtime, deliver: deliver,
                         outcome: TranscriptionOutcome(text: race.realtimeText, completedSegments: 1,
                                                       totalSegments: 1, failure: nil, cancelled: false))
        case .waitForEither, .waitForRealtime, .waitForBatch(window: nil):
            break
        case .waitForBatch(window: let rest?):
            race.timer?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.decideHybrid(race, outer: outer, deliver: deliver)
            }
            race.timer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + rest, execute: work)
        case .noSpeech:
            // 服务商回了、没字：交出空文本，下游那句「没有听到内容」负责说话（与改动前同一条路）
            finishHybrid(race, winner: .none, deliver: deliver,
                         outcome: TranscriptionOutcome(text: "", completedSegments: 1, totalSegments: 1,
                                                       failure: nil, cancelled: false))
        case .failure:
            // 两条都失败：报整段那条的原因（它更可能是 Key / 额度这类用户能处理的话），没有就报实时那条
            let failure = race.batchFailure ?? race.realtimeFailure
                ?? MTError(CloudFallbackDecision.retryExhausted)
            finishHybrid(race, winner: .none, deliver: deliver,
                         outcome: TranscriptionOutcome(text: "", completedSegments: 0, totalSegments: 1,
                                                       failure: failure, cancelled: false))
        }
    }

    private func finishHybrid(_ race: HybridRace, winner: HybridRace.Winner,
                              deliver: @escaping (TranscriptionOutcome) -> Void,
                              outcome: TranscriptionOutcome) {
        race.winner = winner
        race.timer?.cancel()
        race.timer = nil
        // 整段赢了而实时还没收尾：掐掉它（commit 之前掐掉 = 这一句不计实时的钱）
        if winner == .batch, race.realtime == .pending {
            awaiting = nil
            isLive = false
            client.cancel()
        }
        let label: String
        switch winner {
        case .batch: label = "batch"
        case .realtime: label = "realtime"
        case .none: label = "none"
        }
        let window = Int(HybridSelection.window(audioSeconds: race.audioSeconds) * 1000)
        Log.info("CloudASR hybrid final=\(label) rt=\(race.ms(race.realtimeAt)) "
                 + "batch=\(race.ms(race.batchAt)) window=\(window) "
                 + "audio=\(String(format: "%.1f", race.audioSeconds))")
        deliver(outcome)
    }

    /// 交给整段上传那条路，并把取消与分段进度原样转接过去
    @discardableResult
    private func forward(samples: [Float], language: String?, previousText: String,
                         onSegment: ((String, Int, Int) -> Void)?,
                         outer: TranscriptionHandle,
                         deliver: @escaping (TranscriptionOutcome) -> Void) -> TranscriptionHandle {
        let inner = fallback.transcribe(samples: samples, language: language,
                                        previousText: previousText,
                                        onSegment: { text, done, total in
            outer.noteSegmentCompleted()
            onSegment?(text, done, total)
        }, completion: deliver)
        outer.setCancelHandler { inner.cancel() }
        return outer
    }

    /// 实时那条路的失败 → 给用户看的一句话（纯函数）。
    ///
    /// 它只有在同步那条退路**也**没成的时候才会真的出现在屏幕上：
    /// DictationController 会先拿整段音频再走一次同步接口（见 CloudFallbackDecision）。
    static func message(for failure: RealtimeFailure) -> String {
        switch failure {
        case .finalTimeout:
            return UserMessage.recognitionTimedOut
        case .serverError:
            // 服务端的错误码在客户端那一层的日志里（见 settle），屏幕上一句话
            return UserMessage.recognitionError
        case .transport:
            return UserMessage.connectionDropped
        case .unauthorized:
            return UserMessage.keyRejectedRealtime
        case .modelUnavailable:
            return UserMessage.noRealtimeModel
        }
    }

    /// 实时失败 → 悬浮窗按钮（纯函数）：只有 Key 被拒能在设置里修
    static func action(for failure: RealtimeFailure) -> OverlayErrorAction {
        if case .unauthorized = failure { return .openSettings }
        return .dismiss
    }

}

// MARK: - 把开关拨开那一下的实时探针

/// 「识别也用云端」拨开时，除了现有那趟同步探针，**再试一次实时这条链路**。
///
/// 为什么值得多花这一秒的钱：实时与同步是两条不同的链路，一边通不代表另一边通。
/// 用户在这一刻是最该知道"我按下去之后会是什么体验"的——是松手就有结果，还是录完再传。
enum CloudStreamingProbe {

    enum Outcome: Equatable {
        /// 实时可用
        case live
        /// 这条链路 / 这把 Key 不支持实时——云端识别仍然能用，只是录完再传
        case unsupported
        /// 这一趟没问出结论（网络抖了 / 超时）。状态行**什么都不多说**：
        /// 把一次网络抖动写成"这把 Key 不支持实时"，比不说更糟
        case inconclusive
    }

    /// 发 1 秒合成音走一遍完整的实时流程（顺带把 16→24 kHz 重采样也走一遍）。
    /// completion 在主线程。代价：1 秒音频的计费（OpenAI 约 $0.0003）。
    static func run(config: CloudASRConfig,
                    officialOpenAI: Bool = CloudASRSettings.openAIUsesOfficialEndpoint,
                    completion: @escaping (Outcome) -> Void) {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              officialOpenAI else {
            DispatchQueue.main.async { completion(.inconclusive) }
            return
        }
        let host = CloudStreamingSession.streamHost
        let provider = config.provider
        let client = CloudStreamingSession.makeClient(config: config)
        // client 由这个闭包持有到收口为止；deliver 时客户端自己把 onFinish 置空，环就断了
        client.onFinish = { result in
            let outcome: Outcome
            switch result {
            case .success:
                outcome = .live
            case .failure(let failure):
                Log.warn("CloudASR stream probe failed provider=\(provider.rawValue) "
                         + "host=\(host) "
                         + failure.logReason)
                outcome = failure.disablesStreaming ? .unsupported : .inconclusive
            }
            switch outcome {
            case .live:
                CloudStreamingAvailability.markAvailable(provider: provider, host: host)
            case .unsupported:
                CloudStreamingAvailability.markUnsupported(provider: provider, host: host,
                                                           reason: "probe")
            case .inconclusive:
                break
            }
            client.cancel()
            completion(outcome)
        }
        client.start()
        let tone = CloudASRProbe.toneSamples()
        client.append(samples: tone)
        client.finish(audioSeconds: Double(tone.count) / Double(WAVEncoder.defaultSampleRate))
    }
}
