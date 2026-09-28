import XCTest
@testable import MicType

/// 云端实时识别的**接线层**（CloudStreamingSession）与共享底座（RealtimeTransport）的单测。
/// **一个字节都不上网**——socket 是注入的假实现，整条状态机在假 socket 上跑完。
///
/// 协议客户端本身（OpenAI 的 update / commit / 重采样 / 节流）由 OpenAIRealtimeTests 钉着；
/// 这里钉的是它上面那一层——下一步的混合转写要搭在这一层上：
///   • 松手时发到的采样数**恰好等于**这一段录音，不多不少；
///   • 终稿过本地清理、草稿不清；
///   • 实时在松手前断了 → 这一轮自己退回整段上传，用户察觉不到；
///   • 「这条链路不支持实时」只记在内存里、只对那一条链路生效。
///
/// 5.1.0 之前这个文件的大半是阿里云实时协议的用例；那一档删掉之后，
/// 接线层的用例改在 OpenAI 客户端上跑（同一个 RealtimeTranscriptionClient 接口）。
final class CloudStreamingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CloudStreamingAvailability.resetForTesting()
    }

    /// 用例期间要活着的对象（见 releaseHybrid）
    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        keepAlive = []
        CloudStreamingAvailability.resetForTesting()
        super.tearDown()
    }

    // MARK: - 假 socket

    /// 测试驱动的 socket：发出去的每一条都留着好断言，收什么由用例自己喂
    final class FakeSocket: RealtimeSocket, @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        private var cancelledFlag = false
        private weak var delegate: RealtimeSocketDelegate?

        var sent: [String] {
            lock.lock(); defer { lock.unlock() }
            return messages
        }
        var cancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelledFlag
        }
        var appends: [String] { sent.filter { $0.contains("input_audio_buffer.append") } }
        var updates: [String] { sent.filter { $0.contains("\"session.update\"") } }
        /// 5.1.0 之前阿里云那边的收尾；OpenAI 没有这一条（留着好断言"一条都没有"）
        var finishes: [String] { sent.filter { $0.contains("\"session.finish\"") } }
        /// OpenAI 的收尾
        var commits: [String] { sent.filter { $0.contains("input_audio_buffer.commit") } }
        var clears: [String] { sent.filter { $0.contains("input_audio_buffer.clear") } }

        func resume(delegate: RealtimeSocketDelegate) { self.delegate = delegate }

        func send(_ text: String) {
            lock.lock(); messages.append(text); lock.unlock()
        }

        func cancel() {
            lock.lock(); cancelledFlag = true; lock.unlock()
        }

        // 驱动
        func open() { delegate?.realtimeSocketDidOpen() }
        func receive(_ text: String) { delegate?.realtimeSocketDidReceive(text) }
        func close(status: Int? = nil, code: Int? = nil, detail: String? = nil) {
            delegate?.realtimeSocketDidClose(status: status, closeCode: code, detail: detail)
        }

        /// 所有 append 帧解出来的原始 PCM 总字节数（对账"发了多少音频"用）
        func appendedPCMBytes() -> Int {
            appends.reduce(0) { total, message in
                guard let data = message.data(using: .utf8),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let base64 = json["audio"] as? String,
                      let pcm = Data(base64Encoded: base64) else { return total }
                return total + pcm.count
            }
        }
    }

    // MARK: - 小工具

    private func makeClient(_ socket: FakeSocket,
                            configure: ((inout OpenAIRealtimeClient.Config) -> Void)? = nil)
        -> OpenAIRealtimeClient {
        var config = OpenAIRealtimeClient.Config(apiKey: "sk-unit-test")
        configure?(&config)
        return OpenAIRealtimeClient(config: config, makeSocket: { _, _ in socket })
    }

    /// 连到"可以送音频了"那一刻
    private func bringUp(_ client: OpenAIRealtimeClient, _ socket: FakeSocket) {
        client.drainForTesting()
        socket.open()
        client.drainForTesting()
        socket.receive(#"{"type":"session.created","session":{"id":"sess_x"}}"#)
        client.drainForTesting()
        socket.receive(#"{"type":"session.updated","session":{"id":"sess_x"}}"#)
        client.drainForTesting()
    }

    private func tone(seconds: Double) -> [Float] {
        let count = Int(seconds * 16000)
        return (0..<count).map { Float(0.4 * sin(2 * Double.pi * 440 * Double($0) / 16000)) }
    }

    /// 轮询等一个条件成立（状态机是异步的，asyncAfter 排的活儿 drain 不到）
    @discardableResult
    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    private func streamingConfig(apiKey: String = "sk-unit-test") -> CloudASRConfig {
        CloudASRConfig(provider: .openai, apiKey: apiKey)
    }

    /// 整段上传那条路的替身：一个字节都不上网
    private func stubFallback(text: String = "整段上传的结果") -> CloudASREngine {
        let engine = CloudASREngine(config: streamingConfig())
        engine.sendSegment = { _, _, _, completion in
            completion(.success(CloudASRSegmentResult(text: text)))
        }
        return engine
    }

    /// 整段那条通道的替身：回什么、什么时候回由用例自己决定（FakeCloudSender，见
    /// CloudASRIntegrationTests）。不排结果 = 一直在飞，`finishPending` 才落地。
    private func controlledFallback() -> (CloudASREngine, FakeCloudSender) {
        let sender = FakeCloudSender()
        let engine = CloudASREngine(config: streamingConfig())
        engine.sendSegment = { request, client, handle, completion in
            sender.send(request, client, handle, completion)
        }
        return (engine, sender)
    }

    /// 实时那条的终稿（OpenAI 形状）
    private static func completed(_ text: String, seconds: Int = 1) -> String {
        #"{"type":"conversation.item.input_audio_transcription.completed","transcript":""#
            + text + #"","usage":{"seconds":"# + String(seconds) + "}}"
    }

    /// 一个装着假 socket 的会话，已经连到"可以送音频了"
    private func liveSession(_ socket: FakeSocket,
                             fallback: CloudASREngine? = nil,
                             configure: ((inout OpenAIRealtimeClient.Config) -> Void)? = nil)
        -> (CloudStreamingSession, OpenAIRealtimeClient) {
        let client = makeClient(socket, configure: configure)
        let session = CloudStreamingSession(config: streamingConfig(),
                                            fallback: fallback ?? stubFallback(), client: client)
        session.start()
        bringUp(client, socket)
        return (session, client)
    }

    // MARK: - 共享底座的纯函数

    func testPCM16IsLittleEndianAndClamps() {
        let data = RealtimeAudio.pcm16LE([0, 1.0, -1.0, 9.0, .nan])
        XCTAssertEqual(data.count, 10)
        XCTAssertEqual(Array(data[0..<2]), [0, 0])
        XCTAssertEqual(Array(data[2..<4]), [0xFF, 0x7F], "1.0 → 32767，小端")
        XCTAssertEqual(Array(data[4..<6]), [0x01, 0x80], "-1.0 → -32767")
        XCTAssertEqual(Array(data[6..<8]), [0xFF, 0x7F], "越界要截断而不是溢出")
        XCTAssertEqual(Array(data[8..<10]), [0, 0], "NaN 当静音")
    }

    /// 节流（令牌桶）：任何时刻"已发 + 还能发"都不许超过 `maxSpeed × 实时 + 桶容量`。
    /// 数字取 OpenAI 那一档（3× + 0.5 秒）：超过约 4× 会**静默丢音频**
    func testThrottleNeverExceedsTheConfiguredSpeed() {
        let bytesPerSecond = 48000.0
        let maxSpeed = 3.0
        let burst = 0.5
        for tick in 0...100 {
            let elapsed = Double(tick) / 10.0
            let allowed = RealtimeAudio.sendableBytes(elapsed: elapsed, sentBytes: 0,
                                                      bytesPerSecond: bytesPerSecond,
                                                      maxSpeed: maxSpeed, burstSeconds: burst)
            let audioSeconds = Double(allowed) / bytesPerSecond
            XCTAssertLessThanOrEqual(audioSeconds, elapsed * maxSpeed + burst + 0.001,
                                     "t=\(elapsed)s 时允许发 \(audioSeconds)s 音频，超了 3× + 桶")
        }
        // 发过的字节数照扣
        let oneSecond = RealtimeAudio.sendableBytes(elapsed: 1, sentBytes: 0,
                                                    bytesPerSecond: bytesPerSecond,
                                                    maxSpeed: maxSpeed, burstSeconds: burst)
        XCTAssertEqual(RealtimeAudio.sendableBytes(elapsed: 1, sentBytes: oneSecond,
                                                   bytesPerSecond: bytesPerSecond,
                                                   maxSpeed: maxSpeed, burstSeconds: burst), 0)
    }

    /// 松手时还没连上：**不能把建连预算原样花完**——那一刻用户盯着悬浮窗干等
    func testRemainingSetupBudgetIsCappedAfterRelease() {
        XCTAssertEqual(RealtimeAudio.remainingSetupBudget(elapsed: 0.2, setupTimeout: 8,
                                                          releaseGrace: 2.5), 2.5)
        XCTAssertEqual(RealtimeAudio.remainingSetupBudget(elapsed: 7, setupTimeout: 8,
                                                          releaseGrace: 2.5), 1,
                       accuracy: 0.001)
        XCTAssertEqual(RealtimeAudio.remainingSetupBudget(elapsed: 9, setupTimeout: 8,
                                                          releaseGrace: 2.5), 0)
    }

    /// 终稿超时按录音长度分两档：长录音的尾巴服务端要多收一会儿
    func testFinalTimeoutRelaxesForLongTakes() {
        XCTAssertEqual(RealtimeAudio.finalTimeout(audioSeconds: 10, short: 3, long: 5,
                                                  longTakeSeconds: 60), 3)
        XCTAssertEqual(RealtimeAudio.finalTimeout(audioSeconds: 120, short: 3, long: 5,
                                                  longTakeSeconds: 60), 5)
    }

    /// 失败分类：哪几种值得把"这条链路的实时"整个关掉
    func testFailureClassification() {
        XCTAssertTrue(RealtimeFailure.modelUnavailable.disablesStreaming)
        XCTAssertTrue(RealtimeFailure.unauthorized(code: "close 3000").disablesStreaming)
        // 偶发那几种绝不能把整条链路判死：网络抖一下就再也不用实时了，那是最糟的一种"记住"
        XCTAssertFalse(RealtimeFailure.transport("x").disablesStreaming)
        XCTAssertFalse(RealtimeFailure.finalTimeout.disablesStreaming)
        XCTAssertFalse(RealtimeFailure.serverError(code: "server_error", message: nil).disablesStreaming)
        // 日志那一句只有关闭码 / 错误码，一个字用户内容都没有
        XCTAssertEqual(RealtimeFailure.modelUnavailable.logReason, "model unavailable")
        XCTAssertEqual(RealtimeFailure.unauthorized(code: "close 3000").logReason,
                       "unauthorized code=close 3000")
    }

    // MARK: - 接线层

    /// 「这条链路的实时用不了」**只对那一条生效**；真跑通过一次就把记忆清掉
    func testUnsupportedMemoryIsPerHostAndCanBeCleared() {
        let host = CloudStreamingSession.streamHost
        CloudStreamingAvailability.markUnsupported(provider: .openai, host: host,
                                                   reason: "close 4000")
        XCTAssertTrue(CloudStreamingAvailability.isUnsupported(provider: .openai, host: host))
        XCTAssertFalse(CloudStreamingAvailability.isUnsupported(provider: .openai,
                                                                host: "other.example.com"))
        XCTAssertNil(CloudStreamingSession.make(config: streamingConfig(), fallback: stubFallback(),
                                                officialOpenAI: true))
        CloudStreamingAvailability.markAvailable(provider: .openai, host: host)
        XCTAssertFalse(CloudStreamingAvailability.isUnsupported(provider: .openai, host: host))
        XCTAssertNotNil(CloudStreamingSession.make(config: streamingConfig(), fallback: stubFallback(),
                                                   officialOpenAI: true))
    }

    /// 没有 Key、OpenAI 指着第三方网关：一律不开实时，照常整段上传
    func testStreamingDoesNotStartWithoutAUsableLink() {
        XCTAssertNil(CloudStreamingSession.make(config: streamingConfig(apiKey: "  "),
                                                fallback: stubFallback(), officialOpenAI: true))
        XCTAssertNil(CloudStreamingSession.make(config: streamingConfig(),
                                                fallback: stubFallback(), officialOpenAI: false))
    }

    /// 松手时发到的采样数必须**恰好等于**同步那条路会拿去识别的那一段，不多不少
    func testSessionSendsExactlyTheWholeTakeAndNoMore() {
        let socket = FakeSocket()
        // 整段那条一直不回：窗口到点之后实时那条的字交出去（这条用例验的是实时通道本身）
        let (fallback, _) = controlledFallback()
        let (session, client) = liveSession(socket, fallback: fallback)

        let take = tone(seconds: 3)
        // 录音中分两次喂（模拟电平回调），松手时把剩下的一截补上
        session.enqueue(Array(take[0..<16000]))
        session.enqueue(Array(take[16000..<24000]))
        client.drainForTesting()
        XCTAssertEqual(session.queuedSampleCount, 24000)

        let done = expectation(description: "outcome")
        var outcome: TranscriptionOutcome?
        session.transcribe(samples: take, language: nil, previousText: "", onSegment: nil) {
            outcome = $0
            done.fulfill()
        }
        XCTAssertEqual(session.queuedSampleCount, take.count)
        XCTAssertTrue(waitUntil(4) { socket.commits.count == 1 })
        // 3 秒 16 kHz → 3 秒 24 kHz = 144000 字节 PCM16
        XCTAssertEqual(socket.appendedPCMBytes(), take.count * 3,
                       "发出去的音频必须正好是这一整段（重采样到 24 kHz 之后）")
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"三秒的话","usage":{"seconds":3}}"#)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcome?.text, "三秒的话")
        XCTAssertEqual(outcome?.isComplete, true)
    }

    /// 云端识别的**终稿**也要过一遍本地清理（4.3.3），中间结果（悬浮窗灰字）不清。
    ///
    /// 4.3.3 之前云端这条路一个字都没清过：本机档默认删掉的「嗯 / 那个 / um」在云端档
    /// 原样进输入框，润色再被保真校验拦下的话，用户看到的就是满屏语气词的识别原文。
    func testFinalTranscriptGetsTheSameLocalCleanupAsTheLocalEngine() {
        let socket = FakeSocket()
        let (fallback, _) = controlledFallback()
        let (session, client) = liveSession(socket, fallback: fallback)
        var drafts: [String] = []
        session.onDraft = { drafts.append($0) }
        let take = tone(seconds: 1)
        session.enqueue(take)
        client.drainForTesting()
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"嗯，那个，我们明天"}"#)
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"开会"}"#)
        client.drainForTesting()

        let done = expectation(description: "outcome")
        var outcome: TranscriptionOutcome?
        session.transcribe(samples: take, language: nil, previousText: "", onSegment: nil) {
            outcome = $0
            done.fulfill()
        }
        XCTAssertTrue(waitUntil(3) { socket.commits.count == 1 })
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"嗯，那个，我们明天开会。","usage":{"seconds":1}}"#)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcome?.text, "我们明天开会。", "口水词该在交付之前就删掉")
        XCTAssertEqual(drafts.last, "嗯，那个，我们明天开会",
                       "草稿不清：它每 100 ms 重画一次，边说边删只会让字在眼前跳")
    }

    /// 静音门判「没说话」 / Esc：不收尾、直接掐掉——一个 commit 都不发
    func testAbandonCommitsNothing() {
        let socket = FakeSocket()
        let (session, client) = liveSession(socket)
        session.enqueue(tone(seconds: 1))
        client.drainForTesting()
        session.abandon()
        client.drainForTesting()
        XCTAssertTrue(socket.commits.isEmpty)
        XCTAssertTrue(socket.cancelled)
        XCTAssertFalse(session.isLive)
    }

    /// 「这把 Key 不让用实时」（close 3000）→ 记住这条链路，这一轮自己退回整段上传，
    /// 用户什么都不该察觉（同步那条路能用就不算错误）
    func testStreamLostBeforeReleaseFallsBackToTheUploadPath() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let session = CloudStreamingSession(config: streamingConfig(),
                                            fallback: stubFallback(text: "整段上传的结果"),
                                            client: client)
        let lost = expectation(description: "lost")
        session.onStreamingLost = { lost.fulfill() }
        session.start()
        client.drainForTesting()
        socket.close(status: nil, code: 3000, detail: nil)
        wait(for: [lost], timeout: 2)
        XCTAssertFalse(session.isLive)
        XCTAssertTrue(CloudStreamingAvailability.isUnsupported(provider: .openai,
                                                               host: CloudStreamingSession.streamHost))

        let done = expectation(description: "outcome")
        var outcome: TranscriptionOutcome?
        session.transcribe(samples: tone(seconds: 1), language: nil, previousText: "",
                           onSegment: nil) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outcome?.text, "整段上传的结果")
        XCTAssertNil(outcome?.failure, "同步那条路能用就不算错误")
    }

    /// 录音中途偶发断线 → 这一轮整段走同步接口。音频一个采样都没丢，用户最多只是多等一趟上传。
    func testStreamLostTransientlyUploadsTheWholeTake() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let session = CloudStreamingSession(config: streamingConfig(),
                                            fallback: stubFallback(text: "整段上传的结果"),
                                            client: client)
        let lost = expectation(description: "lost")
        session.onStreamingLost = { lost.fulfill() }
        session.start()
        bringUp(client, socket)
        session.enqueue(tone(seconds: 1))
        client.drainForTesting()
        // 录到一半网断了（不是 3000 / 4000 = 偶发，不是"这条链路不支持"）
        socket.close(status: nil, code: 1006, detail: "NSURLErrorDomain -1005")
        wait(for: [lost], timeout: 2)
        XCTAssertFalse(CloudStreamingAvailability.isUnsupported(provider: .openai,
                                                                host: CloudStreamingSession.streamHost),
                       "一次断网不该把实时判死")

        let done = expectation(description: "outcome")
        var outcome: TranscriptionOutcome?
        session.transcribe(samples: tone(seconds: 3), language: nil, previousText: "",
                           onSegment: nil) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outcome?.text, "整段上传的结果")
        XCTAssertNil(outcome?.failure, "同步那条路能用就不算错误")
        XCTAssertEqual(outcome?.cancelled, false)
    }

    // MARK: - 混合转写：整段为准、实时兜底（5.1.0）

    /// 松手开跑一句 1 秒的话，返回 (会话, socket, 整段替身, 取交付结果的闭包, 交付的期望)
    private func releaseHybrid(seconds: Double = 1,
                               configure: ((inout OpenAIRealtimeClient.Config) -> Void)? = nil)
        -> (CloudStreamingSession, FakeSocket, FakeCloudSender, () -> [TranscriptionOutcome],
            XCTestExpectation, TranscriptionHandle) {
        let socket = FakeSocket()
        let (fallback, sender) = controlledFallback()
        let (session, client) = liveSession(socket, fallback: fallback, configure: configure)
        // 用例里常常用 `_` 丢掉会话——真实的调用方（DictationController）会一直拿着它，
        // 这里也得拿着，否则整段那条通道的引擎跟着会话一起被释放
        keepAlive.append(session)
        let take = tone(seconds: seconds)
        session.enqueue(take)
        client.drainForTesting()
        let done = expectation(description: "outcome")
        var outcomes: [TranscriptionOutcome] = []
        let handle = session.transcribe(samples: take, language: nil, previousText: "", onSegment: nil) {
            outcomes.append($0)
            done.fulfill()
        }
        return (session, socket, sender, { outcomes }, done, handle)
    }

    /// 实时终稿先到、整段在窗口里到 → **整段赢**（它更准：字错率 6.2% vs 9.0%）
    func testHybridBatchInsideTheWindowWins() {
        let (session, socket, sender, outcomes, done, _) = releaseHybrid()
        XCTAssertTrue(session.ranBatchLane)
        XCTAssertTrue(waitUntil(3) { socket.commits.count == 1 && sender.requestCount == 1 })
        socket.receive(Self.completed("实时的字"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))   // 窗口 0.825 秒之内
        XCTAssertTrue(outcomes().isEmpty, "窗口还没到，不该先交实时的字")
        sender.finishPending(.success(CloudASRSegmentResult(text: "整段的字")))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcomes().map(\.text), ["整段的字"])
        XCTAssertNil(outcomes().first?.failure)
    }

    /// 整段先到且有字 → 立刻用它，不等实时；实时那条当场掐掉（commit 之前掐掉就不计实时的钱）
    func testHybridBatchFirstWinsAtOnceAndCancelsTheRealtimeLane() {
        let (_, socket, sender, outcomes, done, _) = releaseHybrid()
        XCTAssertTrue(waitUntil(3) { sender.requestCount == 1 })
        sender.finishPending(.success(CloudASRSegmentResult(text: "整段的字")))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcomes().map(\.text), ["整段的字"])
        XCTAssertTrue(socket.cancelled, "整段赢了，实时那条要当场掐掉")
        // 实时终稿这时才到：一个字都不许再交付
        socket.receive(Self.completed("迟到的实时"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(outcomes().count, 1)
    }

    /// 窗口过了整段还没到 → **实时赢**；整段随后迟到，只记一行日志、丢掉
    func testHybridLateBatchLosesToTheRealtimeText() {
        let (_, socket, sender, outcomes, done, _) = releaseHybrid()
        XCTAssertTrue(waitUntil(3) { socket.commits.count == 1 })
        socket.receive(Self.completed("实时的字"))
        wait(for: [done], timeout: 3)   // 窗口 0.825 秒后自己收口
        XCTAssertEqual(outcomes().map(\.text), ["实时的字"])
        sender.finishPending(.success(CloudASRSegmentResult(text: "迟到的整段")))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(outcomes().count, 1, "迟到的整段不许再交付第二次")
    }

    /// 实时失败（终稿超时）→ 等整段到底，整段的字交出去，**不报失败**
    func testHybridRealtimeFailureFallsBackToTheBatch() {
        let (_, _, sender, outcomes, done, _) = releaseHybrid(configure: { $0.finalTimeout = 0.2 })
        XCTAssertTrue(waitUntil(3) { sender.requestCount == 1 })
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))   // 实时终稿超时
        XCTAssertTrue(outcomes().isEmpty, "实时失败了也要等整段，不能先报失败")
        sender.finishPending(.success(CloudASRSegmentResult(text: "整段的字")))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcomes().map(\.text), ["整段的字"])
        XCTAssertNil(outcomes().first?.failure)
    }

    /// 两条都失败 → 报失败（DictationController 看到 ranBatchLane 就不再整段重传一遍）
    func testHybridBothLanesFailingIsAFailure() {
        let (session, _, sender, outcomes, done, _) = releaseHybrid(configure: { $0.finalTimeout = 0.2 })
        XCTAssertTrue(waitUntil(3) { sender.requestCount == 1 })
        sender.finishPending(.failure(CloudASRFailure("upload failed", status: 500)))
        wait(for: [done], timeout: 3)
        XCTAssertNotNil(outcomes().first?.failure)
        XCTAssertEqual(outcomes().first?.cancelled, false)
        XCTAssertEqual(outcomes().first?.text, "")
        XCTAssertTrue(session.ranBatchLane)
    }

    /// 两条都回了、都没字 → 交出空文本（下游说「没听清」），不是失败
    func testHybridBothEmptyIsNoSpeech() {
        let (_, socket, sender, outcomes, done, _) = releaseHybrid()
        XCTAssertTrue(waitUntil(3) { socket.commits.count == 1 && sender.requestCount == 1 })
        socket.receive(Self.completed(""))
        sender.finishPending(.success(CloudASRSegmentResult(text: "  ")))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcomes().first?.text, "")
        XCTAssertNil(outcomes().first?.failure)
    }

    /// Esc：两条都掐掉，只交付一次「取消」，之后谁落地都不再交付
    func testHybridCancelStopsBothLanes() {
        let (_, socket, sender, outcomes, done, handle) = releaseHybrid()
        XCTAssertTrue(waitUntil(3) { sender.requestCount == 1 })
        handle.cancel()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcomes().first?.cancelled, true)
        XCTAssertTrue(socket.cancelled)
        sender.finishPending(.success(CloudASRSegmentResult(text: "整段的字")))
        socket.receive(Self.completed("实时的字"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(outcomes().count, 1)
    }

    /// **阿拉伯语永远不算"不能用"**（用户在 UAE）：两条都是阿语 → 规则照常（窗口里的整段赢）
    func testHybridArabicIsNeverRejected() {
        let (_, socket, sender, outcomes, done, _) = releaseHybrid()
        XCTAssertTrue(waitUntil(3) { socket.commits.count == 1 && sender.requestCount == 1 })
        socket.receive(Self.completed("مرحبا كيف حالك اليوم"))
        sender.finishPending(.success(CloudASRSegmentResult(text: "مرحباً، كيف حالك اليوم؟")))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcomes().map(\.text), ["مرحباً، كيف حالك اليوم؟"])
    }

    /// 阿语实时有字、整段失败 → 实时那条阿语照常交出去
    func testHybridArabicRealtimeSurvivesABatchFailure() {
        let (_, socket, sender, outcomes, done, _) = releaseHybrid()
        XCTAssertTrue(waitUntil(3) { socket.commits.count == 1 && sender.requestCount == 1 })
        sender.finishPending(.failure(CloudASRFailure("upload failed", status: 500)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        socket.receive(Self.completed("مرحبا كيف حالك اليوم"))
        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcomes().map(\.text), ["مرحبا كيف حالك اليوم"])
    }

    /// 超过 60 秒的句子不跑混合：没有整段那条通道（照旧只等实时）
    func testHybridIsSkippedForTakesOverSixtySeconds() {
        let socket = FakeSocket()
        let (fallback, sender) = controlledFallback()
        let (session, client) = liveSession(socket, fallback: fallback)
        let take = tone(seconds: 61)
        client.drainForTesting()
        let handle = session.transcribe(samples: take, language: nil, previousText: "", onSegment: nil) { _ in }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(session.ranBatchLane)
        XCTAssertEqual(sender.requestCount, 0, "超过 60 秒不该把整段再传一次")
        handle.cancel()
    }

    /// 实时那条路的失败 → 给用户看的一句话：点名 OpenAI，英文侧不漏中文
    func testRealtimeFailureMessageNamesOpenAI() {
        let saved = L10n.shared.language
        defer { L10n.shared.language = saved }
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            for failure: RealtimeFailure in [.transport("x"), .unauthorized(code: nil),
                                             .modelUnavailable, .finalTimeout,
                                             .serverError(code: "e", message: nil)] {
                let text = CloudStreamingSession.message(for: failure)
                XCTAssertFalse(text.isEmpty)
                if language == .en {
                    XCTAssertFalse(CJKSourceScanner.containsFlagged(text), text)
                }
            }
            XCTAssertTrue(CloudStreamingSession.message(for: .transport("x")).contains("OpenAI"))
        }
    }
}
