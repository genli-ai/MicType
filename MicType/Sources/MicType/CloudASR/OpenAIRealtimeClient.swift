import Foundation

// MARK: - OpenAI「实时转写」协议客户端（WebSocket）
//
// **只依赖 Foundation**（与 AlibabaRealtimeClient、RealtimeTransport 同一条纪律）：
// 不认识 Settings / Log / tr() / 任何单例，日志走注入的闭包，失败是共享的类型化 enum。
//
// 为什么单独写一个类而不是给阿里云那个加分支（用户 2026-09-21 拍板）：两家协议除了
// "都是 WebSocket" 之外几乎没有共同点，差异全在会踩死人的地方。这里逐条记下 2026-09-21
// 的实测（docs/OpenAI实时识别-协议实测_260921.md），每一条都换过真金白银：
//
//   • **握手永远 101**——错 Key 也 101，随后 `error{invalid_api_key}` + close 3000；
//     请求非法 close 4000。这边没有「握手状态码」这个概念（阿里云正相反）。
//   • **模型不进 query**（放了 → invalid_model + close 4000），放 `session.audio.input.transcription.model`。
//   • **绝不能发 `OpenAI-Beta: realtime=v1`**（→ beta_api_shape_disabled + close 4000）。
//   • **只认 24 kHz**（16000 / 48000 都报错）→ App 录的是 16 kHz，必须重采样（见 Resampler16kTo24k）。
//   • 模型名拼错不会静默降级，但**会话会停在默认配置（transcription:null）→ 零输出**。
//     所以 `session.update` 之后的任何 error 都当致命处理。
//   • **buffer 里有音频时再发 session.update 会把那段音频从终稿里整段吞掉**（不报错、
//     不断连，delta 流却是全的）——最阴险的坑。所以我们只在"还没送过音频"时发 update，
//     也因此 append 必须等到 session.updated 之后（见 start 那段注释）。
//   • 超过约 4× 实时会**静默丢音频**（没有任何错误）→ 补发按 ≤3× 节流。
//   • 收尾没有 session.finish：commit → completed → 自己关。usage **每个 item 独立，要相加**
//     （阿里云是整条会话累计、取最后一条，正好相反）。

// MARK: - 事件

enum OpenAIRealtimeEvent: Equatable {
    case sessionCreated
    case sessionUpdated
    /// 中间结果：**纯增量、只追加、不回撤**，concat(delta) == 终稿
    case delta(String)
    case completed(transcript: String, seconds: Double?)
    case failed(code: String?, message: String?, param: String?)
    /// 认识但用不上的（input_audio_buffer.committed / cleared / item.added …）
    case ignored

    static func parse(_ raw: String) -> OpenAIRealtimeEvent {
        guard let data = raw.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else { return .ignored }
        switch type {
        case "session.created":
            return .sessionCreated
        case "session.updated":
            return .sessionUpdated
        case "conversation.item.input_audio_transcription.delta":
            return .delta(json["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .completed(transcript: json["transcript"] as? String ?? "",
                              seconds: seconds(json["usage"] as? [String: Any]))
        case "error":
            let error = json["error"] as? [String: Any]
            return .failed(code: error?["code"] as? String,
                           message: error?["message"] as? String,
                           param: error?["param"] as? String)
        default:
            return .ignored
        }
    }

    /// `{"seconds":N,"type":"duration"}`，N = ceil(秒)。**每个 item 独立，多段要相加**
    static func seconds(_ usage: [String: Any]?) -> Double? {
        guard let usage = usage else { return nil }
        if let v = usage["seconds"] as? Double { return v }
        if let v = usage["seconds"] as? Int { return Double(v) }
        if let v = usage["seconds"] as? NSNumber { return v.doubleValue }
        return nil
    }
}

// MARK: - 客户端

final class OpenAIRealtimeClient: RealtimeTranscriptionClient, RealtimeSocketDelegate {

    // MARK: 常量

    /// 唯一同时满足「边说边出草稿 + 热词纠正专名 + 不翻译」的那一档（2026-09-21 选型）
    static let model = "gpt-live-transcribe"
    /// **intent 进 query，模型不进 query**
    static let endpointString = "wss://api.openai.com/v1/realtime?intent=transcription"
    /// 端点只认这一个采样率
    static let sampleRate = Resampler16kTo24k.outputRate
    /// 单次 commit 至少这么多音频；不够就别 commit（空 commit 是非致命错误，但也不会有终稿）
    static let minCommitSeconds = 0.1
    /// keywords 的条数与单条长度上限。**官方没有公布**，这两个数是保守值——
    /// 宁可少送几个热词，也不要因为一张长词表把整条配置搞成非法（那会让会话零输出）。
    static let keywordLimit = 100
    static let keywordMaxCharacters = 40
    /// 一帧最多塞多少原始 PCM。这边没有 256 KB 那种帧限（3.84 MB 照收），
    /// 3 秒只是为了让节流的粒度细一点
    static let maxRawFrameBytes = 144_000

    // MARK: 配置

    /// 会被服务端拒掉、且**摘掉还能用**的那几个可选字段。
    /// 它们都没有回显（"回显 = 被接受"那招在这边不成立），所以只能靠 error 事件认出来。
    enum OptionalField: String, CaseIterable {
        case keywords
        case languages
        case delay
    }

    struct Options: Equatable {
        /// 用户设置里有明确的识别语言就送。**这边传错也不会翻译**（实测中文音频配 ["en"]
        /// 仍出中文），所以送它是安全的——阿里云那边正相反，那边一个字都不许传。
        var languages: [String] = []
        /// 词汇表 → 热词。**这是 OpenAI 这一档最值钱的地方**：实测 MicType / Qwen 3.0 / Gen
        /// 五次里五次纠正，而阿里云那边任何手段都救不回「Gen」。
        var keywords: [String] = []
        /// 只影响草稿的提前量（低延迟档首个 delta 0.86 s vs 1.2 s），几乎不影响终稿延迟
        var delay: String? = "low"

        func dropping(_ field: OptionalField) -> Options {
            var out = self
            switch field {
            case .keywords: out.keywords = []
            case .languages: out.languages = []
            case .delay: out.delay = nil
            }
            return out
        }
    }

    struct Config {
        var apiKey: String
        var options = Options()
        /// 握手实测 0.73–1.01 s，再加一条 update 往返；10 秒是十倍余量
        var setupTimeout: TimeInterval = 10
        /// 松手之后还肯为建连等多久（与阿里云同一条纪律）
        var releaseSetupGrace: TimeInterval = 2.5
        /// commit 之后等终稿多久。实测 0.67–1.04 s
        var finalTimeout: TimeInterval = 3
        var longFinalTimeout: TimeInterval = 5
        var longTakeSeconds: Double = 60
        /// 发送速率上限（× 实时）。**超过约 4× 会静默丢音频**，没有任何错误——
        /// 看不见的故障比断连危险得多，所以这里留足余量
        var maxSpeed: Double = 3
        /// 令牌桶容量（秒音频）。握手 + 配置约一秒，这段时间录到的音频要能追上，
        /// 但 3 + 0.5 = 3.5× 仍在 4× 那条线以内
        var burstSeconds: Double = 0.5

        init(apiKey: String, options: Options = Options()) {
            self.apiKey = apiKey
            self.options = options
        }
    }

    typealias Failure = RealtimeFailure
    typealias Transcript = RealtimeTranscript

    // MARK: 状态机

    enum State: Equatable {
        case idle
        /// 已经发起握手，还没 101
        case connecting
        /// 握手通了，等 session.created
        case awaitingSession
        /// session.update 发出去了，等 session.updated。**这期间一个字节音频都不许送**
        case configuring
        /// 配置确认了，可以送音频
        case streaming
        /// 调用方已经要求收尾（剩余音频发完就 commit）
        case finishing
        case done
        case failed
    }

    // MARK: 成员

    private let config: Config
    private let makeSocket: (URL, [String: String]) -> RealtimeSocket
    private let callbackQueue: DispatchQueue
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "mictype.cloudasr.openai-realtime", qos: .userInitiated)

    private var socket: RealtimeSocket?
    private var state: State = .idle
    private var cancelled = false
    /// 这一趟实际在用的那份配置（被拒的字段会被摘掉重发，见 handleConfigurationError）
    private var options: Options
    /// 已经为哪些字段摘过一次了——同一个字段不试第二遍
    private var droppedFields: Set<OptionalField> = []
    private var finishRequested = false
    private var commitSent = false
    private var pumpScheduled = false

    /// 16 kHz → 24 kHz。**有状态**：块与块之间要保留滤波历史，否则每个接缝一声咔哒
    private let resampler = Resampler16kTo24k()
    /// 还没发出去的 24 kHz PCM16
    private var pending = Data()
    private var sentBytes = 0
    private var streamClock: Date?
    private var startedAt = Date()
    private var firstDeltaLogged = false
    private var commitSentAt: Date?
    /// 累加起来的 delta（草稿）；终稿到了以终稿为准
    private var draft = ""
    private var completedParts: [String] = []
    /// **每个 item 独立，要相加**
    private var billedSeconds: Double = 0
    private var audioSecondsSent: Double = 0

    var onPartial: ((String) -> Void)?
    var onFinish: ((Result<RealtimeTranscript, RealtimeFailure>) -> Void)?

    private var bytesPerSecond: Double { Double(Self.sampleRate) * 2 }

    init(config: Config,
         callbackQueue: DispatchQueue = .main,
         log: @escaping (String) -> Void = { _ in },
         makeSocket: @escaping (URL, [String: String]) -> RealtimeSocket = {
             URLSessionRealtimeSocket(url: $0, headers: $1)
         }) {
        self.config = config
        self.options = config.options
        self.callbackQueue = callbackQueue
        self.log = log
        self.makeSocket = makeSocket
    }

    // MARK: - 纯函数 · 消息体

    static func endpoint() -> URL? { URL(string: endpointString) }

    /// 手动模式下实测可用的最小体。四件事一件都不能少：
    ///   • `session.type = "transcription"`——每条 update 都要带；
    ///   • `format.rate = 24000`——只认这一个；
    ///   • `turn_detection: null`——必须显式关掉；
    ///   • `transcription.model`——**模型放在这里，不放 query**。
    static func sessionUpdateMessage(model: String, rate: Int, options: Options) -> String {
        var transcription: [String: Any] = ["model": model]
        if !options.languages.isEmpty { transcription["languages"] = options.languages }
        if !options.keywords.isEmpty { transcription["keywords"] = options.keywords }
        if let delay = options.delay { transcription["delay"] = delay }
        let body: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": rate] as [String: Any],
                    "transcription": transcription,
                    "turn_detection": NSNull(),
                ] as [String: Any]] as [String: Any],
            ] as [String: Any],
        ]
        return json(body)
    }

    static func appendMessage(base64: String) -> String {
        json(["type": "input_audio_buffer.append", "audio": base64])
    }

    /// 收尾：**没有 session.finish**，commit 就是全部
    static func commitMessage() -> String { json(["type": "input_audio_buffer.commit"]) }

    /// Esc / 静音门：先把服务端 buffer 里那段清掉再关，别留一段没人要的音频在那儿
    static func clearMessage() -> String { json(["type": "input_audio_buffer.clear"]) }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// 词汇表 → keywords（纯函数）。去重、去空、单条 ≤40 字符、总数 ≤100。
    /// 上限官方没公布，这两个数是保守值：宁可少送几个热词，也不要因为一张长词表
    /// 把整条配置搞成非法——那不是少纠正几个专名，是**整个会话零输出**。
    static func keywords(from terms: [String],
                         limit: Int = keywordLimit,
                         maxCharacters: Int = keywordMaxCharacters) -> [String] {
        var out = [String]()
        var seen = Set<String>()
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= maxCharacters, !seen.contains(term) else { continue }
            seen.insert(term)
            out.append(term)
            if out.count >= limit { break }
        }
        return out
    }

    /// 这条 error 点名的是哪个**可以摘掉重试**的字段（纯函数）。
    /// 服务端把字段名放在 `param` 里（`session.audio.input.transcription.keywords`），
    /// 偶尔只在 message 里提——两处都看。认不出来就返回 nil = 这条错误没救。
    static func rejectedField(code: String?, message: String?, param: String?) -> OptionalField? {
        let hay = ((param ?? "") + " " + (message ?? "") + " " + (code ?? "")).lowercased()
        for field in OptionalField.allCases where hay.contains(field.rawValue) {
            return field
        }
        return nil
    }

    /// 这条 error 是不是"这把 Key 不能用"（纯函数）
    static func isUnauthorized(code: String?, message: String?) -> Bool {
        let hay = ((code ?? "") + " " + (message ?? "")).lowercased()
        return hay.contains("invalid_api_key") || hay.contains("invalid api key")
            || hay.contains("incorrect api key")
    }

    // MARK: - 对外动作

    func start() {
        queue.async { [weak self] in
            guard let self = self, self.state == .idle, !self.cancelled else { return }
            guard let url = Self.endpoint() else {
                self.fail(.transport("bad endpoint"))
                return
            }
            let key = self.config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                self.fail(.unauthorized(code: "no key"))
                return
            }
            self.state = .connecting
            self.startedAt = Date()
            // **只有 Authorization**：OpenAI-Beta 会让整条连接被拒（beta_api_shape_disabled）
            let socket = self.makeSocket(url, ["Authorization": "Bearer " + key])
            self.socket = socket
            socket.resume(delegate: self)
            self.queue.asyncAfter(deadline: .now() + self.config.setupTimeout) { [weak self] in
                guard let self = self, self.isSettingUp else { return }
                self.fail(.transport("setup timeout"))
            }
        }
    }

    /// 录音中喂 **16 kHz** 样本。重采样与分帧都在这条队列上做；
    /// `session.updated` 之前一个字节都不发出去（见文件头那条"吞音频"的坑）。
    func append(samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self, !self.cancelled else { return }
            guard self.state != .done, self.state != .failed else { return }
            self.pending.append(RealtimeAudio.pcm16LE(self.resampler.resample(samples)))
            self.pump()
        }
    }

    func finish(audioSeconds: Double) {
        queue.async { [weak self] in
            guard let self = self, !self.cancelled else { return }
            guard self.state != .done, self.state != .failed else { return }
            self.audioSecondsSent = audioSeconds
            self.finishRequested = true
            if self.state == .streaming { self.state = .finishing }
            if self.isSettingUp {
                let remaining = RealtimeAudio.remainingSetupBudget(
                    elapsed: Date().timeIntervalSince(self.startedAt),
                    setupTimeout: self.config.setupTimeout,
                    releaseGrace: self.config.releaseSetupGrace)
                self.queue.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    guard let self = self, self.isSettingUp else { return }
                    self.fail(.transport("setup timeout after release"))
                }
            }
            self.pump()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self = self, !self.cancelled else { return }
            self.cancelled = true
            // 服务端 buffer 里那段没人要了：先 clear 再关，别把它留在那儿
            if self.state == .streaming || self.state == .finishing, self.sentBytes > 0 {
                self.socket?.send(Self.clearMessage())
            }
            self.state = .failed
            self.socket?.cancel()
            self.socket = nil
        }
    }

    func drainForTesting() { queue.sync {} }

    private var isSettingUp: Bool {
        state == .connecting || state == .awaitingSession || state == .configuring
    }

    // MARK: - 发送

    private func pump() {
        guard !cancelled, state == .streaming || state == .finishing else { return }
        guard !pending.isEmpty else {
            if state == .finishing, !commitSent { sendCommit() }
            return
        }
        let now = Date()
        if streamClock == nil { streamClock = now }
        let elapsed = now.timeIntervalSince(streamClock ?? now)
        let allowed = RealtimeAudio.sendableBytes(elapsed: elapsed, sentBytes: sentBytes,
                                                  bytesPerSecond: bytesPerSecond,
                                                  maxSpeed: config.maxSpeed,
                                                  burstSeconds: config.burstSeconds)
        guard allowed >= 2 else {
            schedulePump(after: 0.05)
            return
        }
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
        } else if state == .finishing, !commitSent {
            sendCommit()
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

    private func sendCommit() {
        guard !commitSent else { return }
        // 不到 100 ms 的音频不 commit：服务端判非致命错误、也不会有终稿，
        // 而这一段本来就是静音门该扔掉的那种。当成"什么都没听到"交出去
        let seconds = Double(sentBytes) / bytesPerSecond
        guard seconds >= Self.minCommitSeconds else {
            log("commit skipped audioSeconds=\(String(format: "%.2f", seconds)) (under 100ms)")
            socket?.send(Self.clearMessage())
            state = .finishing
            succeed()
            return
        }
        commitSent = true
        commitSentAt = Date()
        socket?.send(Self.commitMessage())
        log("commit sent audioSeconds=\(String(format: "%.1f", audioSecondsSent))")
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

    private func fail(_ failure: RealtimeFailure) {
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
        // **终稿到了以终稿为准**；一条都没来就只能交累加的 delta（中途被掐那一档）
        let text = completedParts.isEmpty ? draft : completedParts.joined()
        let commitToFinal = commitSentAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        log("done chars=\(text.count) "
            + "billedSeconds=\(String(format: "%.0f", billedSeconds)) "
            + "finishToFinalMs=\(commitToFinal.map(String.init) ?? "-")")
        socket?.cancel()
        socket = nil
        deliver(.success(RealtimeTranscript(text: text,
                                            billedSeconds: billedSeconds > 0 ? billedSeconds : nil)))
    }

    private func deliver(_ result: Result<RealtimeTranscript, RealtimeFailure>) {
        let callback = onFinish
        onFinish = nil
        onPartial = nil
        guard let callback = callback else { return }
        callbackQueue.async { callback(result) }
    }

    // MARK: - RealtimeSocketDelegate

    func realtimeSocketDidOpen() {
        queue.async { [weak self] in
            guard let self = self, self.state == .connecting else { return }
            self.state = .awaitingSession
            self.log("connected ms=\(Int(Date().timeIntervalSince(self.startedAt) * 1000))")
        }
    }

    func realtimeSocketDidReceive(_ text: String) {
        queue.async { [weak self] in
            self?.handle(OpenAIRealtimeEvent.parse(text))
        }
    }

    func realtimeSocketDidClose(status: Int?, closeCode: Int?, detail: String?) {
        queue.async { [weak self] in
            guard let self = self, !self.cancelled else { return }
            guard self.state != .done, self.state != .failed else { return }
            // 这边**没有握手状态码**这回事（错 Key 也 101）：真正的原因全在关闭码里
            switch closeCode {
            case 3000:
                self.fail(.unauthorized(code: "close 3000"))
            case 4000:
                // 请求本身非法（模型名、beta 头、query 里放了 model…）：换一次也还是这样
                self.fail(.modelUnavailable)
            default:
                self.fail(.transport("closed code=\(closeCode.map(String.init) ?? "-") "
                                     + (detail ?? "")))
            }
        }
    }

    // MARK: - 事件处理

    private func handle(_ event: OpenAIRealtimeEvent) {
        guard !cancelled, state != .done, state != .failed else { return }
        switch event {
        case .sessionCreated:
            guard state == .awaitingSession else { return }
            state = .configuring
            sendSessionUpdate()
        case .sessionUpdated:
            guard state == .configuring else { return }
            state = finishRequested ? .finishing : .streaming
            pump()
        case .delta(let piece):
            guard !piece.isEmpty else { return }
            if !firstDeltaLogged {
                firstDeltaLogged = true
                log("first partial ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
            }
            draft += piece
            let snapshot = draft
            guard let onPartial = onPartial else { return }
            callbackQueue.async { onPartial(snapshot) }
        case .completed(let transcript, let seconds):
            completedParts.append(transcript)
            // **相加**（每个 item 独立报自己的秒数）
            if let seconds = seconds { billedSeconds += seconds }
            if state == .finishing { succeed() }
        case .failed(let code, let message, let param):
            handleError(code: code, message: message, param: param)
        case .ignored:
            break
        }
    }

    private func sendSessionUpdate() {
        socket?.send(Self.sessionUpdateMessage(model: Self.model, rate: Self.sampleRate,
                                               options: options))
    }

    /// error 事件。三档：
    ///   • Key 不能用 → 鉴权失败，记住"这条链路的实时用不了"；
    ///   • **还在配置阶段** → 配置没生效就等于零输出，必须当致命处理。点名的是可摘的字段
    ///     （keywords / languages / delay）就摘掉重发一次——此刻 buffer 一定是空的（我们
    ///     还没送过音频），所以重发 update 是安全的；认不出来就判"这条链路不支持"；
    ///   • 会话已经跑起来了 → 当偶发错误报上去。
    private func handleError(code: String?, message: String?, param: String?) {
        if Self.isUnauthorized(code: code, message: message) {
            fail(.unauthorized(code: code))
            return
        }
        guard state == .configuring else {
            fail(.serverError(code: code, message: message))
            return
        }
        handleConfigurationError(code: code, message: message, param: param)
    }

    private func handleConfigurationError(code: String?, message: String?, param: String?) {
        guard let field = Self.rejectedField(code: code, message: message, param: param),
              !droppedFields.contains(field) else {
            // 点名的是模型、或者压根认不出来：换一次配置也没用
            fail(.modelUnavailable)
            return
        }
        droppedFields.insert(field)
        options = options.dropping(field)
        log("session.update rejected field=\(field.rawValue) code=\(code ?? "-") — retrying without it")
        // buffer 里没有音频（append 要等 session.updated），所以现在重发 update 是安全的
        sendSessionUpdate()
    }
}
