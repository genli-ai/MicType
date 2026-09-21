import Foundation

// MARK: - 两家实时识别客户端的共享底座
//
// **这个文件只依赖 Foundation**（与两个客户端同一条纪律）：不认识 Settings / Log / tr()
// / 任何单例。iPhone 版会连同两个客户端一起只读移植它。
//
// 为什么不做「一个客户端两种方言」（用户 2026-09-21 拍板）：两家的协议除了"都是 WebSocket"
// 之外几乎没有共同点——
//   • 阿里云握手会给 401/403，OpenAI **永远 101**，错误在 error 事件 + close 3000/4000；
//   • 阿里云模型放 query 且会静默降级，OpenAI 模型放 session 体、拼错会报错但会话变成空配置；
//   • 阿里云 16 kHz、OpenAI **只认 24 kHz**；
//   • 阿里云 usage 是整条会话累计（取最后一条），OpenAI 每个 item 独立（要相加）；
//   • 阿里云收尾是 session.finish，OpenAI 是 commit 之后自己关。
// 一个类里塞两套，每个 if 都是一次踩错的机会。所以：两个客户端各写各的，
// 共享的只有下面这些——socket、失败分类、终稿形状、以及几条与协议无关的纯函数。

// MARK: - socket 抽象

protocol RealtimeSocketDelegate: AnyObject {
    /// 握手成功（HTTP 101）
    func realtimeSocketDidOpen()
    /// 收到一条文本帧
    func realtimeSocketDidReceive(_ text: String)
    /// 这条连接结束了（握手失败 / 中途断线 / 正常关闭 / 发送失败）。
    /// - status: 握手拿到的 HTTP 状态码（101 之外才有意义；拿不到就是 nil）
    /// - closeCode: WebSocket 关闭码
    /// - detail: 网络层错误的一句话（只给日志，**不含任何用户内容**）
    func realtimeSocketDidClose(status: Int?, closeCode: Int?, detail: String?)
}

protocol RealtimeSocket: AnyObject {
    func resume(delegate: RealtimeSocketDelegate)
    func send(_ text: String)
    /// 立刻断开。断开之后一条回调都不许再来（Esc 那条路指望的就是这一点）。
    func cancel()
}

// MARK: - 终稿与失败

/// 一次实时会话的终稿（两家同一个形状）
struct RealtimeTranscript: Equatable {
    var text: String
    /// 云端回报的计费秒数。**两家的口径相反**：阿里云是整条会话的累计值（取最后一条），
    /// OpenAI 是每个 item 独立（要相加）。算清楚是各自客户端的事，这里只存结果。
    var billedSeconds: Double?
    var language: String?

    init(text: String, billedSeconds: Double? = nil, language: String? = nil) {
        self.text = text
        self.billedSeconds = billedSeconds
        self.language = language
    }
}

/// 两家共用的失败分类。
///
/// 分两类**行为完全不同**（用户 2026-09-21 拍板）：
///   • `disablesStreaming` = 这条链路压根不支持实时（或这把 Key 不让用）→ 本次运行内记住，
///     之后一律走整段上传，不打扰用户——同步那条路能用就不算错误；
///   • 其余 = 偶发 → 本句有本机模型就整段回落本机，否则退到整段上传。
enum RealtimeFailure: Error, Equatable {
    /// 握手被拒（阿里云才会：401 = 这把 Key，403 = 这台主机）。OpenAI 永远 101，用不到这一档。
    case handshakeRejected(status: Int)
    /// 回显的模型不是我们点的那个（阿里云：继续下去就是在用十倍价钱的模型）
    case modelMismatch(reported: String?)
    /// 这条链路上没有这个模型 / 这把 Key 没有权限用它
    /// （阿里云 close 1011；OpenAI invalid_model、无权限、close 4000）
    case modelUnavailable
    /// 鉴权不通过（OpenAI：error invalid_api_key + close 3000）
    case unauthorized(code: String?)
    /// 连不上 / 中途断线 / 超时 / 发送失败（只记一句话，不含用户内容）
    case transport(String)
    /// 服务端的 error 事件（会话已经跑起来之后的那种）
    case serverError(code: String?, message: String?)
    /// 收尾发出去了，终稿没来
    case finalTimeout

    /// 这一次失败值不值得把「这条链路的实时」整个关掉（纯函数，单测钉死）
    var disablesStreaming: Bool {
        switch self {
        case .handshakeRejected, .modelMismatch, .modelUnavailable, .unauthorized: return true
        case .transport, .serverError, .finalTimeout: return false
        }
    }

    /// 写进日志的那一句。**只有状态码 / 关闭码 / 服务端错误码**，一个字用户内容都没有。
    var logReason: String {
        switch self {
        case .handshakeRejected(let status): return "handshake status=\(status)"
        case .modelMismatch(let reported): return "model echoed=\(reported ?? "-")"
        case .modelUnavailable: return "model unavailable"
        case .unauthorized(let code): return "unauthorized code=\(code ?? "-")"
        case .transport(let detail): return "transport=\(detail)"
        case .serverError(let code, _): return "event error code=\(code ?? "-")"
        case .finalTimeout: return "final timeout"
        }
    }
}

// MARK: - 上层只认这一个协议

/// 接线层（CloudStreamingSession）看到的实时客户端。**两家实现同一套动作**，
/// 于是"按下热键建连 → 边说边送 → 松手收尾"这条主线只写一遍。
protocol RealtimeTranscriptionClient: AnyObject {
    /// 中间结果（已经拼成一整串草稿）。在客户端的 callbackQueue 上回调。
    var onPartial: ((String) -> Void)? { get set }
    /// 这条 socket 的结局。**只会来一次**，而且 cancel() 之后一次都不来。
    var onFinish: ((Result<RealtimeTranscript, RealtimeFailure>) -> Void)? { get set }

    /// 建连。按下热键那一刻就调（别等第一帧音频）。
    func start()
    /// 录音中每约 100 ms 喂一把 **16 kHz** 新样本进来（要不要重采样是各家自己的事）。
    func append(samples: [Float])
    /// 松手：把剩余样本发完 → 各家自己的收尾动作 → 等终稿。
    func finish(audioSeconds: Double)
    /// Esc / 静音门：直接掐掉，之后一条回调都不来。
    func cancel()
    /// 单测用：等这条客户端的串行队列上已经排好的活儿跑完。
    func drainForTesting()
}

// MARK: - 与协议无关的纯函数

enum RealtimeAudio {

    /// App 录音链路的采样率（AudioRecorder 固定输出 16 kHz 单声道 Float32）
    static let captureRate = 16_000

    /// Float32 → PCM16 小端。截断而不是溢出：越界的采样翻成反相的噪声比削顶难听得多。
    static func pcm16LE(_ samples: [Float]) -> Data {
        var out = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
            let value = Int16(clamped * 32_767)
            out.append(UInt8(truncatingIfNeeded: value))
            out.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return out
    }

    /// 到现在为止还能发多少字节（令牌桶，纯函数）。
    ///
    /// 为什么两家都要节流，只是数不同：
    ///   • 阿里云硬限 2560 KB/s（约 80× 实时），超了 **1007 断连**——看得见；
    ///   • OpenAI 超过约 4× 实时会**静默丢音频**（8× 起 usage.seconds 就对不上），
    ///     不报错、不断连——看不见，所以更要守。
    /// 桶的容量是 burstSeconds 秒音频，按 maxSpeed × 实时补充。
    static func sendableBytes(elapsed: TimeInterval, sentBytes: Int,
                              bytesPerSecond: Double, maxSpeed: Double,
                              burstSeconds: Double) -> Int {
        let allowance = (max(0, elapsed) * maxSpeed + burstSeconds) * bytesPerSecond
        return max(0, Int(allowance) - sentBytes)
    }

    /// 收尾之后等终稿多久。长录音的尾巴服务端要多收一会儿，放宽一档——
    /// 宁可多等两秒，也不要把一段十分钟的口述判成失败。
    static func finalTimeout(audioSeconds: Double, short: TimeInterval, long: TimeInterval,
                             longTakeSeconds: Double) -> TimeInterval {
        audioSeconds >= longTakeSeconds ? long : short
    }

    /// 松手这一刻**还没连上**时，还肯为建连等多久（纯函数）。
    ///
    /// 为什么不能原样花完建连预算：那几秒是"用户还在说话"时的预算，他什么都没在等；
    /// 松手之后他盯着悬浮窗，一段空白之后再回落本机，是这条路上最糟的一种体验。
    static func remainingSetupBudget(elapsed: TimeInterval, setupTimeout: TimeInterval,
                                     releaseGrace: TimeInterval) -> TimeInterval {
        max(0, min(setupTimeout - max(0, elapsed), max(0, releaseGrace)))
    }
}

// MARK: - 16 kHz → 24 kHz 重采样（2:3 多相 FIR）

/// OpenAI 的实时端点 **只认 24 kHz**（16000 / 48000 都报错），而 App 录的是 16 kHz——
/// 所以这条路上必须重采样。写成一个有状态的对象而不是一个纯函数，是因为它要**流式安全**：
/// 录音每 85 ms 喂一小块进来，块与块之间必须保留滤波器历史，否则每个接缝都是一声咔哒。
///
/// 做法是教科书式的 L=3 / M=2 多相：先在 16 kHz 之间插两个零（升到 48 kHz），
/// 过一个截止 8 kHz 的加窗 sinc 低通把镜像滤掉，再隔一个取一个（降到 24 kHz）。
/// 零值样本不必真的乘进去——每个输出只用到 16 个输入抽头（相位 p 那一组系数）。
final class Resampler16kTo24k {

    /// 每个相位多少抽头。16 抽头（总长 48）在 16→24 这一档上通带纹波已经看不见，
    /// 而每秒也就一百多万次乘加，完全不占分量。
    static let tapsPerPhase = 16
    private static let phases = 3          // L：升采样倍数
    private static let decimation = 2      // M：降采样倍数

    /// 原型低通的系数，按相位切好：`coefficients[p][i]`。
    /// 截止取 8 kHz（= 16 kHz 输入的奈奎斯特）：输入本来就不含更高的成分，
    /// 要滤掉的只有升采样带进来的镜像。
    private static let coefficients: [[Float]] = {
        let total = phases * tapsPerPhase
        let center = Double(total - 1) / 2
        let cutoff = 1.0 / 6.0             // 8000 / 48000，按 48 kHz 中间速率归一
        var prototype = [Double](repeating: 0, count: total)
        for n in 0..<total {
            let x = Double(n) - center
            let sinc = x == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * x) / (Double.pi * x)
            // 汉明窗：旁瓣压到 −43 dB，对这一档足够，而且系数写死好复算
            let window = 0.54 - 0.46 * cos(2 * Double.pi * Double(n) / Double(total - 1))
            // 升采样 L 倍要把幅度乘回 L，否则输出整体小三倍
            prototype[n] = sinc * window * Double(phases)
        }
        var out = [[Float]](repeating: [], count: phases)
        for p in 0..<phases {
            out[p] = (0..<tapsPerPhase).map { Float(prototype[p + $0 * phases]) }
        }
        return out
    }()

    /// 最近 tapsPerPhase 个输入采样的环形缓冲（history(0) = 刚写进去的那个）
    private var ring = [Float](repeating: 0, count: tapsPerPhase)
    private var head = 0
    /// 已经收下多少个输入采样
    private var consumed = 0
    /// 下一个要产出的"升采样下标"。每产一个输出 +2（M=2）。
    private var nextIndex = 0

    /// 输出采样率
    static let outputRate = 24_000

    /// 16 kHz 进，24 kHz 出。可以一小块一小块地喂，结果与整段喂**逐字一致**（单测钉死）。
    func resample(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var out = [Float]()
        out.reserveCapacity(samples.count * 3 / 2 + 2)
        for sample in samples {
            ring[head] = sample
            head = (head + 1) % Self.tapsPerPhase
            consumed += 1
            // u[k] 要用到 x[k/3]，所以 k/3 必须已经收进来了
            while nextIndex / Self.phases <= consumed - 1 {
                out.append(sampleAt(nextIndex))
                nextIndex += Self.decimation
            }
        }
        return out
    }

    /// 升采样序列的第 k 个点。相位 p = k % 3，用到的输入是 x[k/3], x[k/3 − 1], …
    private func sampleAt(_ index: Int) -> Float {
        let phase = index % Self.phases
        let newest = index / Self.phases                  // 这个输出对齐到哪个输入采样
        let back = (consumed - 1) - newest                // 它离"最新那个输入"有多远
        let taps = Self.coefficients[phase]
        var sum: Float = 0
        for i in 0..<Self.tapsPerPhase {
            sum += taps[i] * history(back + i)
        }
        return sum
    }

    /// x[最新 − i]；越界（开头那几个）按 0 算
    private func history(_ i: Int) -> Float {
        guard i >= 0, i < Self.tapsPerPhase, i < consumed else { return 0 }
        let index = (head - 1 - i + Self.tapsPerPhase * 2) % Self.tapsPerPhase
        return ring[index]
    }

    /// 一整段一次过（单测与探针用；与分块喂结果一致）
    static func resampleWhole(_ samples: [Float]) -> [Float] {
        Resampler16kTo24k().resample(samples)
    }
}

// MARK: - socket 的真实现（URLSessionWebSocketTask）

/// 两处坑（2026-09-21 实测）：
///   • 阿里云握手失败时 URLSession 只给 `NSURLErrorDomain -1011`，**状态码要从
///     `task.response as? HTTPURLResponse` 取**（401 = 这把 Key，403 = 这台主机），错误体拿不到；
///     OpenAI 那边永远 101，真正的原因在 error 事件与关闭码里。
///   • URLSession 会强引用 delegate 直到 invalidate——所以 cancel() 必须 invalidateAndCancel()，
///     否则每次听写都漏一个 session 和一条连接。
final class URLSessionRealtimeSocket: NSObject, RealtimeSocket, URLSessionWebSocketDelegate {

    private let request: URLRequest
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private weak var delegate: RealtimeSocketDelegate?
    private let lock = NSLock()
    private var finished = false

    init(url: URL, headers: [String: String]) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        self.request = request
        super.init()
    }

    func resume(delegate: RealtimeSocketDelegate) {
        self.delegate = delegate
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive()
    }

    func send(_ text: String) {
        task?.send(.string(text)) { [weak self] error in
            guard let self = self, let error = error else { return }
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            self.close(status: nil, closeCode: nil, detail: "send failed \(nsError.code)")
        }
    }

    func cancel() {
        lock.lock()
        finished = true
        lock.unlock()
        delegate = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.delegate?.realtimeSocketDidReceive(text)
                }
                self.receive()
            case .failure(let error):
                let nsError = error as NSError
                guard nsError.code != NSURLErrorCancelled else { return }
                self.close(status: (self.task?.response as? HTTPURLResponse)?.statusCode,
                           closeCode: self.task?.closeCode.rawValue,
                           detail: "\(nsError.domain) \(nsError.code)")
            }
        }
    }

    /// 收口只允许一次：didClose 与 didComplete 完全可能前后脚各来一遍
    private func close(status: Int?, closeCode: Int?, detail: String?) {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        let code = (closeCode == 0) ? nil : closeCode
        delegate?.realtimeSocketDidClose(status: status, closeCode: code, detail: detail)
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        delegate?.realtimeSocketDidOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        close(status: (webSocketTask.response as? HTTPURLResponse)?.statusCode,
              closeCode: closeCode.rawValue, detail: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let nsError = error as NSError?
        if let nsError = nsError, nsError.code == NSURLErrorCancelled { return }
        close(status: (task.response as? HTTPURLResponse)?.statusCode,
              closeCode: (task as? URLSessionWebSocketTask)?.closeCode.rawValue,
              detail: nsError.map { "\($0.domain) \($0.code)" })
    }
}
