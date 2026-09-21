import Foundation

// MARK: - 云端实时识别的接线层（AlibabaRealtimeClient ↔ DictationController）
//
// 协议客户端什么都不决定（见 AlibabaRealtimeClient 顶部那三条）。这里才是做决定的地方：
// 这一轮开不开实时、草稿往哪送、松手时发到第几个采样、断了之后谁接手。
//
// 一句话说清这条路在干什么：**按下热键就把 socket 连上，录音期间边说边把新采样传上去，
// 松手只剩"把最后一截发完 + 一条 finish"**——实测松手到终稿恒为 0.23–0.28 秒，与录音长度无关。
// 而整段上传那条路上，同一把 Key 的等待是 4.5s→1.2s、22s→3.0s、71s→8.6s。

// MARK: - 「这台主机的实时用不了」的记忆

/// **内存态、按主机名**（用户 2026-09-21 拍板）。
///
/// 为什么不落盘：主机本来就是 MicType 自己试出来的（AlibabaHostResolver），它一换，
/// 这条记忆就该跟着失效；而"阿里云那边什么时候给这把 Key 开通实时"我们无从得知——
/// 落盘等于给用户留一条他看不见、也没地方清掉的坏设置。重启一次就重新试，代价只是一次握手。
///
/// 被记住之后，这台主机上的每一句话都走现有的整段上传，**行为与 4.1.6 完全一致**，
/// 所以它只记一行 WARN，不打扰用户——同步那条路能用，就不算错误。
enum CloudStreamingAvailability {

    private static let lock = NSLock()
    private static var unsupported: Set<String> = []

    static func isUnsupported(host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return unsupported.contains(host)
    }

    static func markUnsupported(host: String, reason: String) {
        lock.lock()
        let isNew = unsupported.insert(host).inserted
        lock.unlock()
        guard isNew else { return }
        Log.warn("CloudASR streaming unavailable on host=\(AlibabaEndpoint.redacted(host)) "
                 + "reason=\(reason)")
    }

    /// 刚刚真的跑通过一次（把开关拨开那一下的探针）：把旧记忆清掉
    static func markAvailable(host: String) {
        lock.lock()
        let removed = unsupported.remove(host) != nil
        lock.unlock()
        if removed {
            Log.info("CloudASR streaming available again on host=\(AlibabaEndpoint.redacted(host))")
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
/// `transcribe(samples:)`，这里只要把「还没发出去的那一截」补发完再 finish 就行——
/// 于是下游（交付、历史、云端失败回落本机、Esc 部分交付）一行都不用改，
/// 整条链路仍然只有一套。
///
/// 实时走不通时**本轮自己退回整段上传**（fallback: CloudASREngine），
/// 而不是报一个失败让上层回落本机：同步那条路能用就不算错误，用户什么都不该察觉。
final class CloudStreamingSession: SpeechEngine {

    private let config: CloudASRConfig
    private let client: AlibabaRealtimeClient
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
    private var awaiting: ((Result<AlibabaRealtimeClient.Transcript,
                                   AlibabaRealtimeClient.Failure>) -> Void)?
    /// 松手**之前**就断掉的那次失败（主线程）：决定这一轮交给谁，见 route(afterLosing:)
    private var lostFailure: AlibabaRealtimeClient.Failure?

    /// 本机模型文件在不在。写成闭包只为单测能钉死两条分支——
    /// 真跑起来就是 QwenEngine.shared.isModelAvailable（与 CloudFallbackDecision 同一口径）。
    var localModelAvailable: () -> Bool = { QwenEngine.shared.isModelAvailable }

    // MARK: 建

    /// 这一轮开不开实时。四道闸门，缺一不可：
    ///   1. 阿里云那一档（只有它有这个接口）；
    ///   2. 钥匙串里有 Key；
    ///   3. 主机名拼得出来；
    ///   4. 这台主机这次运行里还没被判过「实时不可用」。
    /// 任何一道不过就返回 nil —— 调用方照常走整段上传。
    static func make(config: CloudASRConfig, fallback: CloudASREngine) -> CloudStreamingSession? {
        guard config.provider == .alibaba else { return nil }
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let host = AlibabaEndpoint.normalizeHost(config.host) else { return nil }
        guard !CloudStreamingAvailability.isUnsupported(host: host) else { return nil }
        var normalized = config
        normalized.host = host
        return CloudStreamingSession(config: normalized, fallback: fallback)
    }

    /// - client: 单测在这里塞一个装着假 socket 的客户端
    init(config: CloudASRConfig, fallback: CloudASREngine,
         client: AlibabaRealtimeClient? = nil) {
        self.config = config
        self.fallback = fallback
        self.client = client
            ?? AlibabaRealtimeClient(
                config: AlibabaRealtimeClient.Config(host: config.host, apiKey: config.apiKey),
                log: { Log.info("CloudASR stream " + $0) })
    }

    // MARK: 录音期间

    /// 建连。**按下热键那一刻就调**（与 prewarm 同一时机），别等第一帧音频：
    /// 握手约 0.3 秒，等到有音频再连等于把这 0.3 秒原样加在用户的等待上。
    func start() {
        Log.info("CloudASR stream start host=\(AlibabaEndpoint.redacted(config.host)) "
                 + "model=\(AlibabaRealtimeClient.model)")
        client.onPartial = { [weak self] draft in self?.onDraft?(draft) }
        client.onFinish = { [weak self] result in self?.settle(result) }
        client.start()
    }

    /// 录音中把新录到的这一截交上去（主线程，跟着录音电平回调走，约每 85 ms 一次）。
    /// 握手还没完成时它先留在客户端的缓冲里，连上之后按 ≤20× 实时补发。
    func enqueue(_ samples: [Float]) {
        guard isLive, !samples.isEmpty else { return }
        queuedSampleCount += samples.count
        client.append(samples: samples)
    }

    /// Esc / 静音门判定「没说话」：**不发 finish，直接掐掉**。
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
    ///   • 还在录音（没人等）→ 本轮退回整段上传，并把本机预览重新打开。
    private func settle(_ result: Result<AlibabaRealtimeClient.Transcript,
                                         AlibabaRealtimeClient.Failure>) {
        isLive = false
        if case .failure(let failure) = result, failure.disablesStreaming {
            CloudStreamingAvailability.markUnsupported(host: config.host,
                                                       reason: failure.logReason)
        }
        if let waiter = awaiting {
            awaiting = nil
            waiter(result)
            return
        }
        if case .failure(let failure) = result {
            // 松手之前就断了：记下**为什么**断的——是"这台主机没有实时接口"还是"网断了"，
            // 决定这一轮该交给谁（见 route(afterLosing:)）
            lostFailure = failure
            onStreamingLost?()
        }
    }

    // MARK: - 松手之前就断了，这一轮交给谁

    /// 两条路（**纯函数**，单测钉死）。
    ///
    /// 为什么偶发断线优先本机，而不是再传一趟整段（用户 2026-09-21 拍板）：
    /// 断线多半是网络本身出了问题，这时候再发一趟整段上传大概率也失败，而同步那条路的
    /// 超时是 120 秒——用户要对着悬浮窗干等很久才轮到本机。本机模型在引导里是必装项，
    /// 绝大多数人都有，一秒左右就出字。
    /// 「这台主机不支持实时」是另一回事：那条链路好好的，只是没有实时接口，照常整段上传
    /// （行为与 4.1.6 完全一致），本机反而是没必要的降级。
    enum LostRoute: Equatable {
        /// 现有的整段上传
        case uploadWholeTake
        /// 直接回落本机识别整段（由上层那条既有的「云端失败 → 回落本机」接手）
        case localEngine
    }

    static func route(afterLosing failure: AlibabaRealtimeClient.Failure?,
                      localModelAvailable: Bool) -> LostRoute {
        guard let failure = failure, !failure.disablesStreaming else { return .uploadWholeTake }
        return localModelAvailable ? .localEngine : .uploadWholeTake
    }

    // MARK: - SpeechEngine

    var engineName: String { fallback.engineName }
    /// 云端没有"模型文件"概念，可用 = 有 Key（与 CloudASREngine 同一口径）
    var isModelAvailable: Bool { fallback.isModelAvailable }
    var isModelLoaded: Bool { false }
    func preload() {}
    func unloadModel() {}

    /// 松手之后的那一步：把还没发出去的尾巴补发完 → session.finish → 等终稿。
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

        // 实时这条路在松手之前就断了（握手没成 / 录音中掉线）：音频一个采样都没丢，
        // 只剩"交给谁"这一个问题——判据是纯函数，见 route(afterLosing:)
        guard isLive else {
            switch Self.route(afterLosing: lostFailure,
                              localModelAvailable: localModelAvailable()) {
            case .uploadWholeTake:
                return forward(samples: samples, language: language, previousText: previousText,
                               onSegment: onSegment, outer: outer, deliver: deliver)
            case .localEngine:
                let reason = Self.message(for: lostFailure ?? .transport("stream lost"))
                Log.warn("CloudASR stream lost before release — handing the take to the local engine")
                // **不能同步交付**：调用方还在用返回值给 inflightTranscription 赋值，
                // 同步收口会把刚清掉的那个指针又写成这一轮的句柄（与 CloudASREngine 同一条）
                DispatchQueue.main.async {
                    deliver(TranscriptionOutcome(text: "", completedSegments: 0, totalSegments: 1,
                                                 failure: MTError(reason), cancelled: false))
                }
                return outer
            }
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
        awaiting = { [weak self] result in
            guard let self = self else { return }
            guard !outer.isCancelled else {
                deliver(TranscriptionOutcome(text: "", completedSegments: 0, totalSegments: 1,
                                             failure: nil, cancelled: true))
                return
            }
            switch result {
            case .success(let transcript):
                deliver(TranscriptionOutcome(text: transcript.text, completedSegments: 1,
                                             totalSegments: 1, failure: nil, cancelled: false))
            case .failure(let failure):
                // 「这台主机 / 这把 Key 不支持实时」不是一次故障：本句改走整段上传，
                // 行为与 4.1.6 完全一致，用户不该为此看到任何东西
                guard !failure.disablesStreaming else {
                    _ = self.forward(samples: samples, language: language,
                                     previousText: previousText, onSegment: onSegment,
                                     outer: outer, deliver: deliver)
                    return
                }
                // 偶发失败（断线 / 报错 / 终稿超时）：交给现有那条「云端失败 → 回落本机」的路，
                // 整段音频还在调用方手上，一个字都不会丢
                deliver(TranscriptionOutcome(text: "", completedSegments: 0, totalSegments: 1,
                                             failure: MTError(Self.message(for: failure)),
                                             cancelled: false))
            }
        }
        client.finish(audioSeconds: seconds)
        return outer
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
    /// 它只有在**没有本机模型可回落**时才会真的出现在屏幕上：有本机模型的话，
    /// DictationController 会整段重跑一遍本机，这句话进的是那条「已改用本地识别（…）」的附注。
    static func message(for failure: AlibabaRealtimeClient.Failure) -> String {
        switch failure {
        case .finalTimeout:
            return tr("云端识别没有按时返回结果，请再说一次",
                      "The cloud transcript did not come back in time - please say it again")
        case .serverError(let code, _):
            return tr("云端识别报错", "Cloud recognition reported an error")
                + (code.map { " (" + $0 + ")" } ?? "")
        case .transport:
            return tr("到阿里云的实时连接中断了，请再说一次",
                      "The realtime connection to Alibaba Cloud dropped - please say it again")
        case .handshakeRejected(let status):
            return tr("阿里云拒绝了实时连接", "Alibaba Cloud refused the realtime connection")
                + " (\(status))"
        case .modelMismatch, .modelUnavailable:
            return tr("这个接入地址上没有实时识别模型",
                      "This endpoint has no realtime speech model")
        }
    }
}

// MARK: - 把开关拨开那一下的实时探针

/// 「识别也用云端」拨开时，除了现有那趟同步探针，**再试一次实时这条链路**。
///
/// 为什么值得多花这一秒的钱：开着的开关必须意味着"它真的能用"，而实时与同步是两条不同的
/// 链路（实测里工作空间主机在 HTTP 侧 200、在 WebSocket 侧 403）。用户在这一刻是最该知道
/// "我按下去之后会是什么体验"的——是松手就有结果，还是录完再传。
enum CloudStreamingProbe {

    enum Outcome: Equatable {
        /// 实时可用
        case live
        /// 这台主机 / 这把 Key 不支持实时——云端识别仍然能用，只是录完再传
        case unsupported
        /// 这一趟没问出结论（网络抖了 / 超时）。状态行**什么都不多说**：
        /// 把一次网络抖动写成"这把 Key 不支持实时"，比不说更糟
        case inconclusive
    }

    /// 发 1 秒合成音走一遍完整的实时流程。completion 在主线程。
    /// 代价：1 秒音频的计费（约 $0.000035），与同步那趟探针同一量级。
    static func run(config: CloudASRConfig, completion: @escaping (Outcome) -> Void) {
        guard config.provider == .alibaba,
              let host = AlibabaEndpoint.normalizeHost(config.host),
              !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DispatchQueue.main.async { completion(.inconclusive) }
            return
        }
        let client = AlibabaRealtimeClient(
            config: AlibabaRealtimeClient.Config(host: host, apiKey: config.apiKey),
            log: { Log.info("CloudASR stream probe " + $0) })
        // client 由这个闭包持有到收口为止；deliver 时客户端自己把 onFinish 置空，环就断了
        client.onFinish = { result in
            let outcome: Outcome
            switch result {
            case .success:
                outcome = .live
            case .failure(let failure):
                Log.warn("CloudASR stream probe failed host=\(AlibabaEndpoint.redacted(host)) "
                         + failure.logReason)
                outcome = failure.disablesStreaming ? .unsupported : .inconclusive
            }
            switch outcome {
            case .live: CloudStreamingAvailability.markAvailable(host: host)
            case .unsupported: CloudStreamingAvailability.markUnsupported(host: host,
                                                                         reason: "probe")
            case .inconclusive: break
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
