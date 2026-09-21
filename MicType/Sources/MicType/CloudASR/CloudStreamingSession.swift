import Foundation

// MARK: - 云端实时识别的接线层（两家客户端 ↔ DictationController）
//
// 协议客户端什么都不决定（见 RealtimeTransport.swift 顶部那段）。这里才是做决定的地方：
// 这一轮开不开实时、用哪一家、草稿往哪送、松手时发到第几个采样、断了之后谁接手。
//
// 一句话说清这条路在干什么：**按下热键就把 socket 连上，录音期间边说边把新采样传上去，
// 松手只剩"把最后一截发完 + 一条收尾"**。实测松手到终稿：阿里云 0.23–0.28 秒、
// OpenAI 0.67–1.04 秒，都与录音长度无关；而整段上传那条路上同一把 Key 是
// 4.5s→1.2s、22s→3.0s、71s→8.6s。

// MARK: - 「这条链路的实时用不了」的记忆

/// **内存态，键是「服务商 + 主机」**（4.2.2 起加上服务商：两家是两条完全独立的链路，
/// 阿里云那台主机不支持实时，跟 OpenAI 支不支持毫无关系）。
///
/// 为什么不落盘：阿里云那台主机本来就是 MicType 自己试出来的（AlibabaHostResolver），它一换
/// 这条记忆就该失效；而"服务商那边什么时候给这把 Key 开通实时"我们无从得知——
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

    /// 日志里的主机：阿里云那台的第一段是工作空间编号，要打码；OpenAI 是固定的官方域名，照写
    static func loggable(provider: CloudASRProvider, host: String) -> String {
        provider == .alibaba ? AlibabaEndpoint.redacted(host) : host
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
                 + "host=\(loggable(provider: provider, host: host)) reason=\(reason)")
    }

    /// 刚刚真的跑通过一次（把开关拨开那一下的探针）：把旧记忆清掉
    static func markAvailable(provider: CloudASRProvider, host: String) {
        lock.lock()
        let removed = unsupported.remove(key(provider: provider, host: host)) != nil
        lock.unlock()
        if removed {
            Log.info("CloudASR streaming available again provider=\(provider.rawValue) "
                     + "host=\(loggable(provider: provider, host: host))")
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
/// 于是下游（交付、历史、云端失败回落本机、Esc 部分交付）一行都不用改，
/// 整条链路仍然只有一套。两家客户端也只有这一个接口（RealtimeTranscriptionClient），
/// 所以下面这些代码一个 if provider 都没有。
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

    /// 本机模型文件在不在。写成闭包只为单测能钉死两条分支——
    /// 真跑起来就是 QwenEngine.shared.isModelAvailable（与 CloudFallbackDecision 同一口径）。
    var localModelAvailable: () -> Bool = { QwenEngine.shared.isModelAvailable }

    // MARK: 建

    /// 这一档实时链路的"地址"——记忆的键，也是日志里那个 host。
    /// 阿里云是试出来的那台主机；OpenAI 是固定的官方域名（那边没有"选主机"这回事）。
    static func streamHost(for config: CloudASRConfig) -> String? {
        switch config.provider {
        case .alibaba: return AlibabaEndpoint.normalizeHost(config.host)
        case .openai: return "api.openai.com"
        }
    }

    /// 这一档实时用的是哪个模型（日志与界面都读它）
    static func streamModel(for provider: CloudASRProvider) -> String {
        switch provider {
        case .alibaba: return AlibabaRealtimeClient.model
        case .openai: return OpenAIRealtimeClient.model
        }
    }

    /// 这一轮开不开实时。四道闸门，缺一不可：
    ///   1. 钥匙串里有 Key；
    ///   2. OpenAI 那一档必须是**官方接口**——把 Base URL 指向第三方网关的人没有这条路
    ///      （判据与 PrivacyCopy 的留存那句同源：LLMClient.usesResponsesAPI）；
    ///   3. 地址拼得出来；
    ///   4. 这条链路这次运行里还没被判过「实时不可用」。
    /// 任何一道不过就返回 nil —— 调用方照常走整段上传。
    static func make(config: CloudASRConfig, fallback: CloudASREngine,
                     officialOpenAI: Bool = CloudASRSettings.openAIUsesOfficialEndpoint)
        -> CloudStreamingSession? {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if config.provider == .openai, !officialOpenAI { return nil }
        guard let host = streamHost(for: config) else { return nil }
        guard !CloudStreamingAvailability.isUnsupported(provider: config.provider,
                                                        host: host) else { return nil }
        var normalized = config
        normalized.host = host
        return CloudStreamingSession(config: normalized, fallback: fallback)
    }

    /// 按服务商挑客户端。**这是全文件唯一一处 switch provider**——再往下所有动作两家同形。
    static func makeClient(config: CloudASRConfig) -> RealtimeTranscriptionClient {
        let prefix = "CloudASR stream provider=\(config.provider.rawValue) "
        switch config.provider {
        case .alibaba:
            return AlibabaRealtimeClient(
                config: AlibabaRealtimeClient.Config(host: config.host, apiKey: config.apiKey),
                log: { Log.info(prefix + $0) })
        case .openai:
            var options = OpenAIRealtimeClient.Options()
            // 用户设置里有明确的识别语言就送（这边传错不会翻译，所以是安全的；
            // 阿里云那边正相反，一个字都不许传）
            options.languages = config.languageHints
            // **词汇表在这一档真的管用**：实测专名五次里五次纠正
            options.keywords = OpenAIRealtimeClient.keywords(from: config.vocabulary)
            return OpenAIRealtimeClient(
                config: OpenAIRealtimeClient.Config(apiKey: config.apiKey, options: options),
                log: { Log.info(prefix + $0) })
        }
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
    /// 握手阿里云约 0.3 秒、OpenAI 约 0.8 秒，等到有音频再连等于把它原样加在用户的等待上。
    func start() {
        let host = CloudStreamingAvailability.loggable(provider: config.provider, host: config.host)
        Log.info("CloudASR stream start provider=\(config.provider.rawValue) "
                 + "model=\(Self.streamModel(for: config.provider)) host=\(host)")
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
        if case .failure(let failure) = result, failure.disablesStreaming,
           let host = Self.streamHost(for: config) {
            CloudStreamingAvailability.markUnsupported(provider: config.provider, host: host,
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

    // MARK: - 松手之前就断了，这一轮交给谁

    /// 两条路（**纯函数**，单测钉死）。
    ///
    /// 为什么偶发断线优先本机，而不是再传一趟整段（用户 2026-09-21 拍板）：
    /// 断线多半是网络本身出了问题，这时候再发一趟整段上传大概率也失败，而同步那条路的
    /// 超时是 120 秒——用户要对着悬浮窗干等很久才轮到本机。本机模型在引导里是必装项，
    /// 绝大多数人都有，一秒左右就出字。
    /// 「这条链路不支持实时」是另一回事：链路好好的，只是没有实时接口，照常整段上传
    /// （行为与 4.1.6 完全一致），本机反而是没必要的降级。
    enum LostRoute: Equatable {
        /// 现有的整段上传
        case uploadWholeTake
        /// 直接回落本机识别整段（由上层那条既有的「云端失败 → 回落本机」接手）
        case localEngine
    }

    static func route(afterLosing failure: RealtimeFailure?,
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
        // 只剩"交给谁"这一个问题——判据是纯函数，见 route(afterLosing:)
        guard isLive else {
            switch Self.route(afterLosing: lostFailure,
                              localModelAvailable: localModelAvailable()) {
            case .uploadWholeTake:
                return forward(samples: samples, language: language, previousText: previousText,
                               onSegment: onSegment, outer: outer, deliver: deliver)
            case .localEngine:
                let reason = Self.message(for: lostFailure ?? .transport("stream lost"),
                                          provider: config.provider)
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
                // 「这条链路不支持实时」不是一次故障：本句改走整段上传，
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
                                             failure: MTError(Self.message(for: failure,
                                                                           provider: self.config.provider)),
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
    static func message(for failure: RealtimeFailure, provider: CloudASRProvider) -> String {
        let name = provider == .alibaba ? tr("阿里云", "Alibaba Cloud") : "OpenAI"
        switch failure {
        case .finalTimeout:
            return tr("云端识别没有按时返回结果，请再说一次",
                      "The cloud transcript did not come back in time - please say it again")
        case .serverError(let code, _):
            return tr("云端识别报错", "Cloud recognition reported an error")
                + (code.map { " (" + $0 + ")" } ?? "")
        case .transport:
            return tr("到\(name)的实时连接中断了，请再说一次",
                      "The realtime connection to \(name) dropped - please say it again")
        case .handshakeRejected(let status):
            return tr("\(name)拒绝了实时连接", "\(name) refused the realtime connection")
                + " (\(status))"
        case .unauthorized:
            return tr("\(name)不接受这把 Key（实时识别）",
                      "\(name) did not accept this key for realtime recognition")
        case .modelMismatch, .modelUnavailable:
            return tr("这条链路上没有实时识别模型",
                      "This endpoint has no realtime speech model")
        }
    }
}

// MARK: - 把开关拨开那一下的实时探针

/// 「识别也用云端」拨开时，除了现有那趟同步探针，**再试一次实时这条链路**。
///
/// 为什么值得多花这一秒的钱：开着的开关必须意味着"它真的能用"，而实时与同步是两条不同的
/// 链路（阿里云实测里工作空间主机在 HTTP 侧 200、在 WebSocket 侧 403）。用户在这一刻是最该
/// 知道"我按下去之后会是什么体验"的——是松手就有结果，还是录完再传。
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

    /// 发 1 秒合成音走一遍完整的实时流程（OpenAI 那一档顺带把 16→24 kHz 重采样也走一遍）。
    /// completion 在主线程。代价：1 秒音频的计费（阿里云约 $0.000035，OpenAI 约 $0.0003）。
    static func run(config: CloudASRConfig,
                    officialOpenAI: Bool = CloudASRSettings.openAIUsesOfficialEndpoint,
                    completion: @escaping (Outcome) -> Void) {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              config.provider != .openai || officialOpenAI,
              let host = CloudStreamingSession.streamHost(for: config) else {
            DispatchQueue.main.async { completion(.inconclusive) }
            return
        }
        var probed = config
        probed.host = host
        let provider = config.provider
        let client = CloudStreamingSession.makeClient(config: probed)
        // client 由这个闭包持有到收口为止；deliver 时客户端自己把 onFinish 置空，环就断了
        client.onFinish = { result in
            let outcome: Outcome
            switch result {
            case .success:
                outcome = .live
            case .failure(let failure):
                Log.warn("CloudASR stream probe failed provider=\(provider.rawValue) "
                         + "host=\(CloudStreamingAvailability.loggable(provider: provider, host: host)) "
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
