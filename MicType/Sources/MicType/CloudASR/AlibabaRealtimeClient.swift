import Foundation

// MARK: - 阿里云百炼「实时识别」协议客户端（WebSocket）
//
// **这个文件只依赖 Foundation**：不认识 Settings / Log / tr() / 任何单例。两条理由：
//   • 协议层没有产品决定可言——要不要用它、失败了怎么跟用户说，全在集成层
//     （CloudStreamingSession）。日志走注入的闭包，失败是类型化的 enum，由集成层翻成文案。
//   • iPhone 版会只读移植这一个文件；它一旦认识本 App 的任何单例就搬不过去。
// socket 也抽成一层协议：单测塞一个假 socket 就能把整条状态机跑完，不碰网络、一分钱不花。
//
// 为什么要有这条路（2026-09-21 实测，UAE → 新加坡）：整段 WAV 一次 POST 的那条同步路，
// 松手后的等待随录音长度线性涨（同一把 Key：4.5s → 1.2s，22s → 3.0s，71s → 8.6s），
// 任何情况下都比本机引擎慢；实时这条路**松手 → 终稿恒为 0.23–0.28 秒，与时长无关**。
//
// 协议事实全部来自那次实测（docs/阿里云实时识别-协议实测_260921.md），
// 每一条不显然的都在下面写了为什么。

// MARK: - 事件

/// 服务端事件。**解码是纯函数**，单测直接喂字符串。
enum RealtimeEvent: Equatable {
    /// 连上之后服务端主动发的第一条，带着它**实际**给我们挂的那个模型
    case sessionCreated(model: String?)
    case sessionUpdated
    /// 中间结果：text = 只增不改的稳定前缀，stash = 6–10 字的未定尾巴
    case partial(text: String, stash: String)
    case completed(transcript: String, billedSeconds: Double?, language: String?)
    case sessionFinished
    case failed(code: String?, message: String?)
    /// 认识但用不上的（conversation.item.created / input_audio_buffer.committed …）
    case ignored

    static func parse(_ raw: String) -> RealtimeEvent {
        guard let data = raw.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else { return .ignored }
        switch type {
        case "session.created":
            // 2026-09-21 实测的回显形状：
            // {"type":"session.created","session":{…,"input_audio_transcription":{"model":"qwen3-asr-flash-realtime"}}}
            let session = json["session"] as? [String: Any]
            let transcription = session?["input_audio_transcription"] as? [String: Any]
            return .sessionCreated(model: transcription?["model"] as? String)
        case "session.updated":
            return .sessionUpdated
        case "conversation.item.input_audio_transcription.text":
            return .partial(text: json["text"] as? String ?? "",
                            stash: json["stash"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            let language = (json["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .completed(transcript: json["transcript"] as? String ?? "",
                              billedSeconds: billedSeconds(json["usage"] as? [String: Any]),
                              language: language)
        case "session.finished":
            return .sessionFinished
        case "error":
            let error = json["error"] as? [String: Any]
            return .failed(code: error?["code"] as? String, message: error?["message"] as? String)
        default:
            return .ignored
        }
    }

    /// `usage.duration`。**它是整条会话的累计值**（多次 commit 时 45, 90, 135…），
    /// 所以调用方只能取最后一条，绝不能相加（2026-09-21 实测）。
    static func billedSeconds(_ usage: [String: Any]?) -> Double? {
        guard let usage = usage else { return nil }
        if let v = usage["duration"] as? Double { return v }
        if let v = usage["duration"] as? Int { return Double(v) }
        if let v = usage["duration"] as? NSNumber { return v.doubleValue }
        return nil
    }
}

// MARK: - 客户端

final class AlibabaRealtimeClient: RealtimeTranscriptionClient, RealtimeSocketDelegate {

    // MARK: 常量

    /// **只能是它**。`?model=` 拼错或省掉都照样握手 101，只会被静默换成更贵的
    /// `qwen-omni-turbo-realtime`（2026-09-21 实测）——所以名字写死在这里，
    /// 而且 `session.created` 回来还要再核对一遍回显（见 sessionCreated 那一段）。
    static let model = "qwen3-asr-flash-realtime"
    static let path = "/api-ws/v1/realtime"

    /// 单帧硬限 262144 字节（超了服务端回 1009）。
    static let frameByteLimit = 262_144
    /// 一帧最多塞多少**原始 PCM**：3 秒 = 96000 字节 → base64 约 128000，
    /// 连 JSON 外壳一起也只有硬限的一半，留足余量。
    static let maxRawFrameBytes = 96_000

    // MARK: 配置

    struct Config {
        /// 裸主机名（与同步那条路同一台，见 CloudASRSettings.alibabaHost）
        var host: String
        var apiKey: String
        var sampleRate: Int = 16_000
        /// 握手 + session.updated 的总预算。答得出来的主机都是三四百毫秒，
        /// 8 秒还没动静基本就是连不上——再等下去只是让用户干等。
        var setupTimeout: TimeInterval = 8
        /// **松手之后**还肯为建连等多久。上面那 8 秒是"用户还在说话"时的预算，
        /// 松手之后他是盯着悬浮窗在等的——那一刻 8 秒不可接受（用户 2026-09-21 拍板）。
        var releaseSetupGrace: TimeInterval = 2.5
        /// 发出 session.finish 之后等终稿多久。实测恒为 0.23–0.28 秒，3 秒是十倍余量。
        var finalTimeout: TimeInterval = 3
        /// 长录音放宽到这个数（服务端要收的尾巴更长）
        var longFinalTimeout: TimeInterval = 5
        var longTakeSeconds: Double = 60
        /// 发送速率上限（× 实时）。服务端输入硬限 2560 KB/s ≈ 80× 实时，超了 1007 断连。
        var maxSpeed: Double = 20
        /// 令牌桶容量（秒音频）：握手那 0.3 秒里攒下的音频要能一口气补上。
        /// 20× + 3 秒桶 → 任何一秒窗口内最多 736 KB，仍然只有服务端硬限的三成。
        var burstSeconds: Double = 3

        init(host: String, apiKey: String) {
            self.host = host
            self.apiKey = apiKey
        }
    }

    // MARK: 失败与终稿（两家共用，见 RealtimeTransport.swift）

    /// 失败分类搬去了共享层：两个客户端对上层必须是同一套判据，
    /// 否则「这条链路不支持实时」这件事在两家会有两种含义。老调用点照常用 `Failure`。
    typealias Failure = RealtimeFailure
    typealias Transcript = RealtimeTranscript

    // MARK: 状态机

    enum State: Equatable {
        case idle
        /// 已经发起握手，还没 101
        case connecting
        /// 握手通了，在等 session.created / session.updated
        case awaitingSession
        /// 配置已被服务端确认，可以送音频了
        case streaming
        /// 调用方已经要求收尾（剩余音频发完就 session.finish）
        case finishing
        case done
        case failed
    }

    // MARK: 成员

    private let config: Config
    private let makeSocket: (URL, [String: String]) -> RealtimeSocket
    private let callbackQueue: DispatchQueue
    private let log: (String) -> Void
    /// 所有状态只在这条串行队列上读写（append 可以从任何线程调）
    private let queue = DispatchQueue(label: "mictype.cloudasr.realtime", qos: .userInitiated)

    private var socket: RealtimeSocket?
    private var state: State = .idle
    private var cancelled = false
    /// session.update **一辈子只能发一次**：音频开始之后再发一条，服务端直接 1007 断连
    private var sessionUpdateSent = false
    private var finishRequested = false
    private var finishSent = false
    private var pumpScheduled = false

    /// 还没发出去的 PCM16（小端）
    private var pending = Data()
    private var sentBytes = 0
    /// 第一帧真正发出去的时刻——节流的基准
    private var streamClock: Date?
    private var startedAt = Date()
    private var firstPartialLogged = false
    private var finishSentAt: Date?
    /// 收到过的每一条 completed 的文本（正常只有一条；多一条也不许丢）
    private var completedParts: [String] = []
    private var lastBilled: Double?
    private var lastLanguage: String?
    /// 这一趟一共送了多少秒音频（日志与终稿超时都要用）
    private var audioSecondsSent: Double = 0

    /// 中间结果（稳定前缀 + 未定尾巴已经拼好）。在 callbackQueue 上回调。
    var onPartial: ((String) -> Void)?
    /// 这条 socket 的结局。**只会来一次**，而且 cancel() 之后一次都不来。
    var onFinish: ((Result<Transcript, Failure>) -> Void)?

    private var bytesPerSecond: Double { Double(config.sampleRate) * 2 }

    /// - makeSocket: 单测在这里塞假 socket（URL 与请求头照样算出来，好断言）
    init(config: Config,
         callbackQueue: DispatchQueue = .main,
         log: @escaping (String) -> Void = { _ in },
         makeSocket: @escaping (URL, [String: String]) -> RealtimeSocket = {
             URLSessionRealtimeSocket(url: $0, headers: $1)
         }) {
        self.config = config
        self.callbackQueue = callbackQueue
        self.log = log
        self.makeSocket = makeSocket
    }

    // MARK: - 纯函数 · 地址与消息体

    /// 主机名**已经归一化过**才传进来（集成层走 AlibabaEndpoint.normalizeHost）。
    /// 这里只做一道"拼得出 URL 吗"的兜底：在这个文件里再实现一遍归一化，
    /// 等于让同一个事实有两个版本，而这个文件还要被 iPhone 版原样搬走。
    static func endpoint(host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 4, trimmed.contains("."),
              !trimmed.contains("/"), !trimmed.contains(" ") else { return nil }
        return URL(string: "wss://" + trimmed + path + "?model=" + model)
    }

    /// 最小可用的 session.update。四件事一件都不能少（2026-09-21 实测）：
    ///   • `turn_detection: null` —— **不发它的默认是 server VAD，会截掉句尾**；
    ///   • `input_audio_format: "pcm"` —— 只认 pcm / wav，写 pcm16 直接报错；
    ///   • `input_audio_transcription: {}` —— **里面绝不放 language**：中文音频配
    ///     `language:"en"` 会被**静默翻译**成英文（违反「禁止翻译」铁律），
    ///     而 `"auto"` / 数组会在推理时才 400 且不给终稿。省略 = 自动检测，中/英/阿实测都对。
    ///   • `modalities: ["text"]` —— 我们只要文字。
    static func sessionUpdateMessage(sampleRate: Int) -> String {
        let body: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "input_audio_format": "pcm",
                "sample_rate": sampleRate,
                "turn_detection": NSNull(),
                "input_audio_transcription": [String: Any](),
            ] as [String: Any],
        ]
        return json(body)
    }

    static func appendMessage(base64: String) -> String {
        json(["type": "input_audio_buffer.append", "audio": base64])
    }

    /// **只发 finish 就够**（隐式 flush）：约 0.25 秒后 completed → session.finished → 1000。
    static func finishMessage() -> String {
        json(["type": "session.finish"])
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// 灰字草稿：稳定前缀 + 未定尾巴。开头六七秒里 text 是空的、内容全在 stash 里，
    /// 所以两段必须拼起来看，只显示 text 的话前几秒屏幕上什么都没有。
    static func draft(text: String, stash: String) -> String { text + stash }

    // MARK: - 对外动作

    /// 建连。**按下热键那一刻就调**（与 prewarm 同一时机），别等第一帧音频：
    /// 握手约 0.3 秒，等到有音频再连就等于把这 0.3 秒加在用户的等待上。
    func start() {
        queue.async { [weak self] in
            guard let self = self, self.state == .idle, !self.cancelled else { return }
            guard let url = Self.endpoint(host: self.config.host) else {
                self.fail(.transport("bad host"))
                return
            }
            let key = self.config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                self.fail(.transport("no key"))
                return
            }
            self.state = .connecting
            self.startedAt = Date()
            let socket = self.makeSocket(url, ["Authorization": "Bearer " + key])
            self.socket = socket
            socket.resume(delegate: self)
            // 握手 + 配置确认的总预算。到点还没进 streaming 就别再让用户干等了
            self.queue.asyncAfter(deadline: .now() + self.config.setupTimeout) { [weak self] in
                guard let self = self else { return }
                guard self.state == .connecting || self.state == .awaitingSession else { return }
                self.fail(.transport("setup timeout"))
            }
        }
    }

    /// 录音中每约 100 ms 喂一把新样本进来。握手还没完成时先留在缓冲里，连上之后补发。
    func append(samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self, !self.cancelled else { return }
            guard self.state != .done, self.state != .failed else { return }
            self.pending.append(RealtimeAudio.pcm16LE(samples))
            self.pump()
        }
    }

    /// 松手：把剩余样本发完 → session.finish → 等终稿。
    /// - audioSeconds: 这一趟一共送出去多少秒音频（只用来挑终稿超时的档位）
    func finish(audioSeconds: Double) {
        queue.async { [weak self] in
            guard let self = self, !self.cancelled else { return }
            guard self.state != .done, self.state != .failed else { return }
            self.audioSecondsSent = audioSeconds
            self.finishRequested = true
            if self.state == .streaming { self.state = .finishing }
            // 还没连上就松手了（极短的一次听写，或者握手挂住了）：把剩下的建连预算压到
            // releaseSetupGrace 以内。到点还没进 streaming 就按偶发失败收口，
            // 让上层早点去走本机那条路——用户此刻是在干等
            if self.state == .connecting || self.state == .awaitingSession {
                let remaining = RealtimeAudio.remainingSetupBudget(
                    elapsed: Date().timeIntervalSince(self.startedAt),
                    setupTimeout: self.config.setupTimeout,
                    releaseGrace: self.config.releaseSetupGrace)
                self.queue.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    guard let self = self else { return }
                    guard self.state == .connecting || self.state == .awaitingSession else { return }
                    self.fail(.transport("setup timeout after release"))
                }
            }
            self.pump()
        }
    }

    /// Esc / 静音门 / 收口：直接掐掉，**之后一条回调都不来**。
    func cancel() {
        queue.async { [weak self] in
            guard let self = self, !self.cancelled else { return }
            self.cancelled = true
            self.state = .failed
            self.socket?.cancel()
            self.socket = nil
        }
    }

    /// 单测用：等这条串行队列上已经排好的活儿跑完。
    /// 状态机整个跑在自己的队列上，不给一个同步点的话，单测只能靠 sleep 猜。
    func drainForTesting() { queue.sync {} }

    // MARK: - 发送

    private func pump() {
        guard !cancelled, state == .streaming || state == .finishing else { return }
        guard !pending.isEmpty else {
            if state == .finishing, !finishSent { sendFinish() }
            return
        }
        let now = Date()
        if streamClock == nil { streamClock = now }
        let elapsed = now.timeIntervalSince(streamClock ?? now)
        let allowed = RealtimeAudio.sendableBytes(elapsed: elapsed, sentBytes: sentBytes,
                                         bytesPerSecond: bytesPerSecond,
                                         maxSpeed: config.maxSpeed,
                                         burstSeconds: config.burstSeconds)
        // 桶空了：等它攒一会儿再来。50 ms 一次足够——20× 实时下这一等就是 1 秒音频的额度
        guard allowed >= 2 else {
            schedulePump(after: 0.05)
            return
        }
        // 一次只发一帧：帧长同时受"桶里还有多少"和"单帧硬限"两条线约束，
        // 并且按 2 字节对齐（PCM16 切一半就是一串噪声）
        let take = min(pending.count, min(allowed, Self.maxRawFrameBytes)) & ~1
        guard take >= 2 else {
            schedulePump(after: 0.05)
            return
        }
        let frame = pending.prefix(take)
        pending.removeFirst(take)
        sentBytes += take
        socket?.send(Self.appendMessage(base64: frame.base64EncodedString()))
        if !pending.isEmpty {
            schedulePump(after: 0.01)
        } else if state == .finishing, !finishSent {
            sendFinish()
        }
    }

    private func schedulePump(after delay: TimeInterval) {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.pumpScheduled = false
            self.pump()
        }
    }

    private func sendFinish() {
        guard !finishSent else { return }
        finishSent = true
        finishSentAt = Date()
        socket?.send(Self.finishMessage())
        log("finish sent audioSeconds=\(String(format: "%.1f", audioSecondsSent))")
        let timeout = RealtimeAudio.finalTimeout(audioSeconds: audioSecondsSent,
                                        short: config.finalTimeout,
                                        long: config.longFinalTimeout,
                                        longTakeSeconds: config.longTakeSeconds)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self, self.state == .finishing else { return }
            self.fail(.finalTimeout)
        }
    }

    // MARK: - 收口

    private func fail(_ failure: Failure) {
        guard !cancelled, state != .done, state != .failed else { return }
        state = .failed
        socket?.cancel()
        socket = nil
        log("failed " + failure.logReason)
        deliver(.failure(failure))
    }

    private func succeed() {
        guard !cancelled, state != .done, state != .failed else { return }
        state = .done
        let text = completedParts.joined()
        let finishToFinal = finishSentAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        log("done chars=\(text.count) "
            + "billedSeconds=\(lastBilled.map { String(format: "%.0f", $0) } ?? "?") "
            + "finishToFinalMs=\(finishToFinal.map(String.init) ?? "-")")
        socket?.cancel()
        socket = nil
        deliver(.success(Transcript(text: text, billedSeconds: lastBilled, language: lastLanguage)))
    }

    private func deliver(_ result: Result<Transcript, Failure>) {
        let callback = onFinish
        onFinish = nil
        onPartial = nil
        guard let callback = callback else { return }
        callbackQueue.async { callback(result) }
    }

    // MARK: - RealtimeSocketDelegate（回调都在 socket 自己的线程上，先转回自己的队列）

    func realtimeSocketDidOpen() {
        queue.async { [weak self] in
            guard let self = self, self.state == .connecting else { return }
            self.state = .awaitingSession
            self.log("connected ms=\(Int(Date().timeIntervalSince(self.startedAt) * 1000))")
        }
    }

    func realtimeSocketDidReceive(_ text: String) {
        queue.async { [weak self] in
            self?.handle(RealtimeEvent.parse(text))
        }
    }

    func realtimeSocketDidClose(status: Int?, closeCode: Int?, detail: String?) {
        queue.async { [weak self] in
            guard let self = self, !self.cancelled else { return }
            // 已经收口了（succeed 之后我们自己 cancel 过一次）：这条关闭无关紧要
            guard self.state != .done, self.state != .failed else { return }
            // 握手没成：URLSession 只给一个 -1011，真正的答案在 HTTP 状态码里
            //（401 = 这把 Key，403 = 这台主机）。**拿不到状态码的不算"被拒"**——
            // 那多半只是这一刻连不上网，不该因此把这台主机的实时整个关掉。
            if self.state == .connecting {
                if let status = status, status != 101 {
                    self.fail(.handshakeRejected(status: status))
                } else {
                    self.fail(.transport("handshake \(detail ?? "closed")"))
                }
                return
            }
            // 1011 = 这台主机上没有这个模型；其余关闭码都按偶发断线处理
            if closeCode == 1011 {
                self.fail(.modelUnavailable)
            } else {
                self.fail(.transport("closed code=\(closeCode.map(String.init) ?? "-") "
                                     + (detail ?? "")))
            }
        }
    }

    // MARK: - 事件处理

    private func handle(_ event: RealtimeEvent) {
        guard !cancelled, state != .done, state != .failed else { return }
        switch event {
        case .sessionCreated(let model):
            // **必须核对**：?model= 拼错不会报错，只会被静默换成更贵的 omni 模型。
            // 回显对不上就当场断开并按「这台主机的实时不可用」处理——继续下去是在花冤枉钱。
            guard model == Self.model else {
                fail(.modelMismatch(reported: model))
                return
            }
            guard !sessionUpdateSent else { return }
            sessionUpdateSent = true
            socket?.send(Self.sessionUpdateMessage(sampleRate: config.sampleRate))
        case .sessionUpdated:
            guard state == .awaitingSession else { return }
            state = finishRequested ? .finishing : .streaming
            pump()
        case .partial(let text, let stash):
            if !firstPartialLogged {
                firstPartialLogged = true
                log("first partial ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            }
            let draft = Self.draft(text: text, stash: stash)
            guard !draft.isEmpty, let onPartial = onPartial else { return }
            callbackQueue.async { onPartial(draft) }
        case .completed(let transcript, let billed, let language):
            completedParts.append(transcript)
            // usage.duration 是**整条会话的累计值**，取最后一条，绝不能相加
            if let billed = billed { lastBilled = billed }
            if let language = language { lastLanguage = language }
            // 终稿到手就收工，不等 session.finished（实测两者同一毫秒，早一步少一步风险）
            if state == .finishing { succeed() }
        case .sessionFinished:
            if state == .finishing { succeed() }
        case .failed(let code, let message):
            // `COMMON_ERROR`（推理级）**不断连、也不会有终稿**——收到即判失败，别傻等超时
            fail(.serverError(code: code, message: message))
        case .ignored:
            break
        }
    }
}
