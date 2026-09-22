import XCTest
@testable import MicType

/// 云端实时识别（WebSocket）：协议层与接线层的单测。**一个字节都不上网**——
/// socket 是注入的假实现，整条状态机在假 socket 上跑完。
///
/// 为什么这些用例值得存在（每一条都对应一次真金白银的实测教训，
/// 见 docs/阿里云实时识别-协议实测_260921.md）：
///   • `?model=` 拼错不会报错，只会被**静默换成更贵的模型** → 回显必须核对；
///   • `session.update` 发第二次直接 1007 断连 → 只能发一次；
///   • 单帧超 262144 字节 1009、发送超 2560 KB/s 1007 → 分帧与节流都要有；
///   • `usage.duration` 是**整条会话的累计值** → 只能取最后一条，绝不能相加；
///   • `COMMON_ERROR` 不断连也不给终稿 → 收到即判失败，不能傻等超时。
final class CloudStreamingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CloudStreamingAvailability.resetForTesting()
    }

    override func tearDown() {
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
        var finishes: [String] { sent.filter { $0.contains("\"session.finish\"") } }
        /// OpenAI 那边的收尾（那边没有 session.finish）
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
                            configure: ((inout AlibabaRealtimeClient.Config) -> Void)? = nil)
        -> AlibabaRealtimeClient {
        var config = AlibabaRealtimeClient.Config(host: "dashscope-intl.aliyuncs.com",
                                                  apiKey: "sk-unit-test")
        configure?(&config)
        return AlibabaRealtimeClient(config: config, makeSocket: { _, _ in socket })
    }

    /// 连到"可以送音频了"那一刻
    private func bringUp(_ client: AlibabaRealtimeClient, _ socket: FakeSocket,
                         model: String = AlibabaRealtimeClient.model) {
        client.start()
        client.drainForTesting()
        socket.open()
        client.drainForTesting()
        socket.receive(Self.sessionCreated(model: model))
        client.drainForTesting()
        socket.receive(#"{"type":"session.updated"}"#)
        client.drainForTesting()
    }

    private static func sessionCreated(model: String) -> String {
        // 2026-09-21 实测的真实形状（连字段顺序都照抄）
        """
        {"event_id":"event_x","type":"session.created","session":{"object":"realtime.session",\
        "model":"\(model)","modalities":["text"],"input_audio_format":"pcm","sample_rate":16000,\
        "input_audio_transcription":{"model":"\(model)"},\
        "turn_detection":{"type":"server_vad","threshold":0.2,"silence_duration_ms":800},\
        "id":"sess_x"}}
        """
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

    // MARK: - 纯函数

    func testEndpointCarriesTheModelQuery() {
        let url = AlibabaRealtimeClient.endpoint(host: "dashscope-intl.aliyuncs.com")
        XCTAssertEqual(url?.absoluteString,
                       "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime")
        XCTAssertNil(AlibabaRealtimeClient.endpoint(host: ""))
        XCTAssertNil(AlibabaRealtimeClient.endpoint(host: "https://host.example.com/api"))
    }

    /// session.update 的四个字段一个都不能少，而且**绝不许出现 language**：
    /// 中文音频配 language:"en" 会被静默翻译成英文（违反「禁止翻译」铁律）
    func testSessionUpdateHasNoLanguageAndDisablesServerVAD() throws {
        let text = AlibabaRealtimeClient.sessionUpdateMessage(sampleRate: 16000)
        XCTAssertFalse(text.contains("language"), text)
        let json = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                                    as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "session.update")
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        XCTAssertEqual(session["modalities"] as? [String], ["text"])
        XCTAssertEqual(session["input_audio_format"] as? String, "pcm")
        XCTAssertEqual(session["sample_rate"] as? Int, 16000)
        // 不显式关掉的话默认是 server VAD，实测会截掉句尾
        XCTAssertTrue(session["turn_detection"] is NSNull)
        XCTAssertEqual((session["input_audio_transcription"] as? [String: Any])?.count, 0)
    }

    func testPCM16IsLittleEndianAndClamps() {
        let data = RealtimeAudio.pcm16LE([0, 1.0, -1.0, 9.0, .nan])
        XCTAssertEqual(data.count, 10)
        XCTAssertEqual(Array(data[0..<2]), [0, 0])
        XCTAssertEqual(Array(data[2..<4]), [0xFF, 0x7F], "1.0 → 32767，小端")
        XCTAssertEqual(Array(data[4..<6]), [0x01, 0x80], "-1.0 → -32767")
        XCTAssertEqual(Array(data[6..<8]), [0xFF, 0x7F], "越界要截断而不是溢出")
        XCTAssertEqual(Array(data[8..<10]), [0, 0], "NaN 当静音")
    }

    /// 草稿 = 稳定前缀 + 未定尾巴。开头六七秒 text 是空的、内容全在 stash 里，
    /// 只显示 text 的话屏幕上前几秒什么都没有
    func testDraftJoinsTextAndStash() {
        XCTAssertEqual(AlibabaRealtimeClient.draft(text: "今天天气", stash: "不错"), "今天天气不错")
        XCTAssertEqual(AlibabaRealtimeClient.draft(text: "", stash: "今天天"), "今天天")
        XCTAssertEqual(AlibabaRealtimeClient.draft(text: "全定了", stash: ""), "全定了")
    }

    /// 一帧的原始 PCM 上限换算成真正发出去的那条消息，必须还在 262144 字节以内（超了 1009）
    func testOneFrameStaysUnderTheWireLimit() {
        let pcm = Data(repeating: 0x41, count: AlibabaRealtimeClient.maxRawFrameBytes)
        let message = AlibabaRealtimeClient.appendMessage(base64: pcm.base64EncodedString())
        XCTAssertLessThanOrEqual(message.utf8.count, AlibabaRealtimeClient.frameByteLimit,
                                 "一帧 \(message.utf8.count) 字节，超了 1009 的硬限")
        XCTAssertLessThanOrEqual(Double(AlibabaRealtimeClient.maxRawFrameBytes) / 32000.0, 3.0,
                                 "单次 append 的原始 PCM 不该超过 3 秒")
    }

    /// 节流：任何时刻"已发 + 还能发"都不许超过 `20× 实时 + 桶容量`，
    /// 而且任何一秒窗口都远在服务端 2560 KB/s 的硬限以下
    func testThrottleNeverExceedsTwentyTimesRealtime() {
        let bytesPerSecond = 32000.0
        let maxSpeed = 20.0
        let burst = 3.0
        for tick in 0...100 {
            let elapsed = Double(tick) / 10.0
            let allowed = RealtimeAudio.sendableBytes(elapsed: elapsed, sentBytes: 0,
                                                              bytesPerSecond: bytesPerSecond,
                                                              maxSpeed: maxSpeed,
                                                              burstSeconds: burst)
            let audioSeconds = Double(allowed) / bytesPerSecond
            XCTAssertLessThanOrEqual(audioSeconds, elapsed * maxSpeed + burst + 0.001,
                                     "t=\(elapsed)s 时允许发 \(audioSeconds)s 音频，超了 20× + 桶")
        }
        // 一秒窗口最多 (20 + 3) × 32000 = 736 KB，只有服务端硬限 2560 KB/s 的三成
        let oneSecond = RealtimeAudio.sendableBytes(elapsed: 1, sentBytes: 0,
                                                            bytesPerSecond: bytesPerSecond,
                                                            maxSpeed: maxSpeed, burstSeconds: burst)
        XCTAssertLessThan(oneSecond, 2_560 * 1024)
        // 发过的字节数照扣
        XCTAssertEqual(RealtimeAudio.sendableBytes(elapsed: 1, sentBytes: oneSecond,
                                                           bytesPerSecond: bytesPerSecond,
                                                           maxSpeed: maxSpeed, burstSeconds: burst), 0)
    }

    /// 松手时还没连上：**不能把 8 秒的建连预算原样花完**——那一刻用户盯着悬浮窗干等
    func testRemainingSetupBudgetIsCappedAfterRelease() {
        // 刚按下就松手：只肯再等宽限值那么久，而不是整整 8 秒
        XCTAssertEqual(RealtimeAudio.remainingSetupBudget(elapsed: 0.2, setupTimeout: 8,
                                                                  releaseGrace: 2.5), 2.5)
        // 已经等了 7 秒：剩下的建连预算更短，就按它
        XCTAssertEqual(RealtimeAudio.remainingSetupBudget(elapsed: 7, setupTimeout: 8,
                                                                  releaseGrace: 2.5), 1,
                       accuracy: 0.001)
        // 预算早就花完了：一秒都不再等
        XCTAssertEqual(RealtimeAudio.remainingSetupBudget(elapsed: 9, setupTimeout: 8,
                                                                  releaseGrace: 2.5), 0)
    }

    /// 握手挂住 + 用户松手：在宽限值内收口，上层才能早点去走本机那条路
    func testFinishWhileStillConnectingGivesUpWithinTheGrace() {
        let socket = FakeSocket()
        let client = makeClient(socket) {
            $0.setupTimeout = 30          // 建连预算故意留得很长
            $0.releaseSetupGrace = 0.2    // 松手之后只肯再等这么久
        }
        let done = expectation(description: "failed")
        var failure: AlibabaRealtimeClient.Failure?
        client.onFinish = { result in
            if case .failure(let value) = result { failure = value }
            done.fulfill()
        }
        client.start()
        client.drainForTesting()
        client.append(samples: tone(seconds: 0.5))
        client.finish(audioSeconds: 0.5)
        // 30 秒的建连预算还远没到；2 秒内就该收口，靠的是松手后的那条宽限
        wait(for: [done], timeout: 2)
        XCTAssertEqual(failure, .transport("setup timeout after release"))
        XCTAssertEqual(failure?.disablesStreaming, false, "握手挂住只是偶发，不该把这台主机判死")
    }

    /// 终稿超时按录音长度分两档：长录音的尾巴服务端要多收一会儿
    func testFinalTimeoutRelaxesForLongTakes() {
        XCTAssertEqual(RealtimeAudio.finalTimeout(audioSeconds: 10, short: 3, long: 5,
                                                          longTakeSeconds: 60), 3)
        XCTAssertEqual(RealtimeAudio.finalTimeout(audioSeconds: 120, short: 3, long: 5,
                                                          longTakeSeconds: 60), 5)
    }

    /// 事件解码：每一种都从 2026-09-21 实测抄来的真形状
    func testEventDecoding() {
        XCTAssertEqual(RealtimeEvent.parse(Self.sessionCreated(model: "qwen3-asr-flash-realtime")),
                       .sessionCreated(model: "qwen3-asr-flash-realtime"))
        XCTAssertEqual(RealtimeEvent.parse(#"{"type":"session.updated"}"#), .sessionUpdated)
        XCTAssertEqual(
            RealtimeEvent.parse(#"{"type":"conversation.item.input_audio_transcription.text","text":"今天天气","stash":"不错","language":"zh"}"#),
            .partial(text: "今天天气", stash: "不错"))
        XCTAssertEqual(
            RealtimeEvent.parse(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"你好","language":"zh","usage":{"duration":22}}"#),
            .completed(transcript: "你好", billedSeconds: 22, language: "zh"))
        // 1 秒纯音调的实测回包：transcript 与 language 都是空串
        XCTAssertEqual(
            RealtimeEvent.parse(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"","language":"","emotion":"","usage":{"duration":1}}"#),
            .completed(transcript: "", billedSeconds: 1, language: nil))
        XCTAssertEqual(RealtimeEvent.parse(#"{"type":"session.finished"}"#), .sessionFinished)
        XCTAssertEqual(RealtimeEvent.parse(#"{"type":"error","error":{"code":"COMMON_ERROR","message":"<400> x"}}"#),
                       .failed(code: "COMMON_ERROR", message: "<400> x"))
        XCTAssertEqual(RealtimeEvent.parse(#"{"type":"conversation.item.created"}"#), .ignored)
        XCTAssertEqual(RealtimeEvent.parse("not json"), .ignored)
    }

    /// 失败分类：哪几种值得把"这台主机的实时"整个关掉
    func testFailureClassification() {
        XCTAssertTrue(AlibabaRealtimeClient.Failure.handshakeRejected(status: 401).disablesStreaming)
        XCTAssertTrue(AlibabaRealtimeClient.Failure.handshakeRejected(status: 403).disablesStreaming)
        XCTAssertTrue(AlibabaRealtimeClient.Failure.modelMismatch(reported: "x").disablesStreaming)
        XCTAssertTrue(AlibabaRealtimeClient.Failure.modelUnavailable.disablesStreaming)
        // 偶发那几种绝不能把整台主机判死：网络抖一下就再也不用实时了，那是最糟的一种"记住"
        XCTAssertFalse(AlibabaRealtimeClient.Failure.transport("x").disablesStreaming)
        XCTAssertFalse(AlibabaRealtimeClient.Failure.finalTimeout.disablesStreaming)
        XCTAssertFalse(AlibabaRealtimeClient.Failure
                        .serverError(code: "COMMON_ERROR", message: nil).disablesStreaming)
        // 日志那一句只有状态码 / 关闭码 / 错误码，一个字用户内容都没有
        XCTAssertEqual(AlibabaRealtimeClient.Failure.handshakeRejected(status: 403).logReason,
                       "handshake status=403")
        XCTAssertEqual(AlibabaRealtimeClient.Failure.modelUnavailable.logReason, "model unavailable")
    }

    // MARK: - 状态机（假 socket）

    func testHappyPathFromHandshakeToFinalTranscript() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        var drafts: [String] = []
        client.onPartial = { drafts.append($0) }
        let done = expectation(description: "final")
        var transcript: AlibabaRealtimeClient.Transcript?
        client.onFinish = { result in
            if case .success(let value) = result { transcript = value }
            done.fulfill()
        }

        bringUp(client, socket)
        XCTAssertEqual(socket.updates.count, 1, "session.update 只能发一次")

        client.append(samples: tone(seconds: 1))
        client.drainForTesting()
        XCTAssertEqual(socket.appendedPCMBytes(), 32000, "1 秒音频 = 32000 字节 PCM16")

        socket.receive(#"{"type":"conversation.item.input_audio_transcription.text","text":"今天","stash":"天气"}"#)
        client.drainForTesting()

        client.finish(audioSeconds: 1)
        client.drainForTesting()
        XCTAssertEqual(socket.finishes.count, 1, "松手只发一条 session.finish（隐式 flush）")

        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"今天天气不错","usage":{"duration":1}}"#)
        wait(for: [done], timeout: 2)

        XCTAssertEqual(transcript?.text, "今天天气不错")
        XCTAssertEqual(transcript?.billedSeconds, 1)
        XCTAssertEqual(drafts, ["今天天气"], "草稿是 text + stash 拼起来的")
        XCTAssertTrue(socket.cancelled, "终稿到手就把 socket 收了")
    }

    /// 音频开始之后再发一条 session.update → 服务端 1007 断连。所以哪怕
    /// session.created 来两遍（重连 / 服务端重发），也只能发一次
    func testSessionUpdateIsSentOnlyOnce() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        client.onFinish = { _ in }
        bringUp(client, socket)
        socket.receive(Self.sessionCreated(model: AlibabaRealtimeClient.model))
        client.drainForTesting()
        XCTAssertEqual(socket.updates.count, 1)
    }

    /// **回显对不上就当场断开**：`?model=` 拼错不会报错，只会被静默换成更贵的 omni 模型
    func testModelEchoMismatchDisablesStreaming() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let done = expectation(description: "failed")
        var failure: AlibabaRealtimeClient.Failure?
        client.onFinish = { result in
            if case .failure(let value) = result { failure = value }
            done.fulfill()
        }
        client.start()
        client.drainForTesting()
        socket.open()
        client.drainForTesting()
        socket.receive(Self.sessionCreated(model: "qwen-omni-turbo-realtime"))
        wait(for: [done], timeout: 2)

        XCTAssertEqual(failure, .modelMismatch(reported: "qwen-omni-turbo-realtime"))
        XCTAssertEqual(failure?.disablesStreaming, true)
        XCTAssertTrue(socket.updates.isEmpty, "对不上就一条配置都不发")
        XCTAssertTrue(socket.cancelled)
    }

    /// 回显里根本没有那个字段：同样按"对不上"处理。
    /// 判错的代价不对称——放过去就是在用十倍价钱的模型，判死只是退回整段上传。
    func testMissingModelEchoIsTreatedAsMismatch() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let done = expectation(description: "failed")
        var failure: AlibabaRealtimeClient.Failure?
        client.onFinish = { result in
            if case .failure(let value) = result { failure = value }
            done.fulfill()
        }
        client.start()
        client.drainForTesting()
        socket.open()
        client.drainForTesting()
        socket.receive(#"{"type":"session.created","session":{"id":"sess_x"}}"#)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(failure, .modelMismatch(reported: nil))
    }

    /// 握手被拒：401 = 这把 Key，403 = 这台主机。两种都判"这台主机的实时用不了"。
    /// 而**拿不到状态码**的那种（离线）只是偶发——不能因为一次断网就再也不用实时了。
    func testHandshakeRejectionIsClassifiedByStatus() {
        for status in [401, 403, 404] {
            let socket = FakeSocket()
            let client = makeClient(socket)
            let done = expectation(description: "failed \(status)")
            var failure: AlibabaRealtimeClient.Failure?
            client.onFinish = { result in
                if case .failure(let value) = result { failure = value }
                done.fulfill()
            }
            client.start()
            client.drainForTesting()
            socket.close(status: status, code: nil, detail: "NSURLErrorDomain -1011")
            wait(for: [done], timeout: 2)
            XCTAssertEqual(failure, .handshakeRejected(status: status))
            XCTAssertEqual(failure?.disablesStreaming, true)
        }
    }

    func testHandshakeWithoutAStatusIsOnlyTransient() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let done = expectation(description: "failed")
        var failure: AlibabaRealtimeClient.Failure?
        client.onFinish = { result in
            if case .failure(let value) = result { failure = value }
            done.fulfill()
        }
        client.start()
        client.drainForTesting()
        socket.close(status: nil, code: nil, detail: "NSURLErrorDomain -1009")
        wait(for: [done], timeout: 2)
        XCTAssertEqual(failure?.disablesStreaming, false, "离线一次不该把这台主机判死")
    }

    /// close 1011 = 这台主机上没有这个模型
    func testCloseCode1011DisablesStreaming() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let done = expectation(description: "failed")
        var failure: AlibabaRealtimeClient.Failure?
        client.onFinish = { result in
            if case .failure(let value) = result { failure = value }
            done.fulfill()
        }
        bringUp(client, socket)
        socket.close(status: nil, code: 1011, detail: nil)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(failure, .modelUnavailable)
        XCTAssertEqual(failure?.disablesStreaming, true)
    }

    /// `COMMON_ERROR`（推理级）**不断连、也不会有终稿** → 收到即判失败，不能傻等超时
    func testCommonErrorFailsImmediatelyWithoutWaitingForTheTimeout() {
        let socket = FakeSocket()
        let client = makeClient(socket) { $0.finalTimeout = 30 }
        let done = expectation(description: "failed")
        var failure: AlibabaRealtimeClient.Failure?
        client.onFinish = { result in
            if case .failure(let value) = result { failure = value }
            done.fulfill()
        }
        bringUp(client, socket)
        client.append(samples: tone(seconds: 0.5))
        client.finish(audioSeconds: 0.5)
        client.drainForTesting()
        socket.receive(#"{"type":"error","error":{"code":"COMMON_ERROR","message":"<400> boom"}}"#)
        // 终稿超时是 30 秒；2 秒内就该收口，靠的是错误事件本身
        wait(for: [done], timeout: 2)
        XCTAssertEqual(failure, .serverError(code: "COMMON_ERROR", message: "<400> boom"))
        XCTAssertEqual(failure?.disablesStreaming, false)
    }

    func testFinalTimeoutAfterFinish() {
        let socket = FakeSocket()
        let client = makeClient(socket) { $0.finalTimeout = 0.2 }
        let done = expectation(description: "failed")
        var failure: AlibabaRealtimeClient.Failure?
        client.onFinish = { result in
            if case .failure(let value) = result { failure = value }
            done.fulfill()
        }
        bringUp(client, socket)
        client.append(samples: tone(seconds: 0.5))
        client.finish(audioSeconds: 0.5)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(failure, .finalTimeout)
    }

    /// `usage.duration` 是**整条会话的累计值**（45, 90, 135…）：取最后一条，绝不能相加
    func testBilledSecondsTakesTheLastUsageNotTheSum() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let done = expectation(description: "final")
        var transcript: AlibabaRealtimeClient.Transcript?
        client.onFinish = { result in
            if case .success(let value) = result { transcript = value }
            done.fulfill()
        }
        bringUp(client, socket)
        // 极少见，但真出现过：finish 之前已经吐过一条 completed
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"前半段","usage":{"duration":45}}"#)
        client.drainForTesting()
        client.finish(audioSeconds: 90)
        client.drainForTesting()
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"后半段","usage":{"duration":90}}"#)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(transcript?.billedSeconds, 90, "累计值只能取最后一条，不是 45+90")
        XCTAssertEqual(transcript?.text, "前半段后半段", "已经出过的文字一个字都不许丢")
    }

    /// Esc：直接掐 socket，**不发 finish**，而且之后一条回调都不来
    func testCancelSendsNoFinishAndCallsNothingBack() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        client.onFinish = { _ in XCTFail("取消之后不许再回调") }
        client.onPartial = { _ in XCTFail("取消之后不许再回调") }
        bringUp(client, socket)
        client.append(samples: tone(seconds: 1))
        client.drainForTesting()
        client.cancel()
        client.drainForTesting()
        XCTAssertTrue(socket.cancelled)
        XCTAssertTrue(socket.finishes.isEmpty, "取消就是不要这一段了，绝不能发 finish")
        // 掐完之后服务端还在路上的事件也一律不算数
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"迟到的终稿"}"#)
        client.drainForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    /// 握手那 0.3 秒里录到的音频先留在缓冲里，连上之后补发——一个采样都不能丢
    func testAudioBufferedBeforeHandshakeIsSentAfterwards() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        client.onFinish = { _ in }
        client.start()
        client.drainForTesting()
        client.append(samples: tone(seconds: 0.5))
        client.drainForTesting()
        XCTAssertTrue(socket.appends.isEmpty, "还没握手完就不该有音频出去")
        socket.open()
        client.drainForTesting()
        socket.receive(Self.sessionCreated(model: AlibabaRealtimeClient.model))
        client.drainForTesting()
        socket.receive(#"{"type":"session.updated"}"#)
        client.drainForTesting()
        XCTAssertEqual(socket.appendedPCMBytes(), 16000, "0.5 秒音频照样补上去")
    }

    /// 补发积压：分帧不超硬限、整体不超 20× 实时
    func testBacklogIsFramedAndThrottled() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        client.onFinish = { _ in }
        bringUp(client, socket)
        let seconds = 10.0
        let startedAt = Date()
        client.append(samples: tone(seconds: seconds))
        let expected = Int(seconds * 32000)
        XCTAssertTrue(waitUntil(5) { socket.appendedPCMBytes() >= expected },
                      "积压没发完：\(socket.appendedPCMBytes()) / \(expected)")
        let elapsed = Date().timeIntervalSince(startedAt)
        for message in socket.appends {
            XCTAssertLessThanOrEqual(message.utf8.count, AlibabaRealtimeClient.frameByteLimit)
        }
        XCTAssertGreaterThan(socket.appends.count, 1, "10 秒音频必须分成多帧")
        // 桶容量 3 秒 + 20× 实时 → 10 秒音频最快也要 (10−3)/20 ≈ 0.35 秒
        XCTAssertGreaterThan(elapsed, 0.2, "一口气全推出去了，节流没生效")
    }

    // MARK: - 接线层

    private func streamingConfig(host: String = "dashscope-intl.aliyuncs.com") -> CloudASRConfig {
        CloudASRConfig(provider: .alibaba, host: host, apiKey: "sk-unit-test")
    }

    /// 整段上传那条路的替身：一个字节都不上网
    private func stubFallback(text: String = "整段上传的结果") -> CloudASREngine {
        let engine = CloudASREngine(config: streamingConfig())
        engine.sendSegment = { _, _, _, completion in
            completion(.success(CloudASRSegmentResult(text: text)))
        }
        return engine
    }

    /// 「这台主机的实时用不了」**只对那一台生效**：主机被重新探测换掉就自然失效
    func testUnsupportedMemoryIsPerHost() {
        let denied = "denied.example.com"
        let other = "other.example.com"
        CloudStreamingAvailability.markUnsupported(provider: .alibaba, host: denied,
                                                   reason: "handshake status=403")
        XCTAssertTrue(CloudStreamingAvailability.isUnsupported(provider: .alibaba, host: denied))
        XCTAssertFalse(CloudStreamingAvailability.isUnsupported(provider: .alibaba, host: other))
        XCTAssertNil(CloudStreamingSession.make(config: streamingConfig(host: denied),
                                                fallback: stubFallback()))
        XCTAssertNotNil(CloudStreamingSession.make(config: streamingConfig(host: other),
                                                   fallback: stubFallback()))
        // 真跑通过一次就把记忆清掉（把开关拨开那一下的探针会调它）
        CloudStreamingAvailability.markAvailable(provider: .alibaba, host: denied)
        XCTAssertFalse(CloudStreamingAvailability.isUnsupported(provider: .alibaba, host: denied))
    }

    /// 没有 Key、拼不出主机名、OpenAI 指着第三方网关：一律不开实时，照常整段上传。
    /// （4.2.2 起 OpenAI 官方接口**有**这条路，见 OpenAIRealtimeTests）
    func testStreamingDoesNotStartWithoutAUsableLink() {
        XCTAssertNil(CloudStreamingSession.make(
            config: CloudASRConfig(provider: .alibaba, apiKey: "  "), fallback: stubFallback()))
        XCTAssertNil(CloudStreamingSession.make(
            config: streamingConfig(host: "不是主机名"), fallback: stubFallback()))
        XCTAssertNil(CloudStreamingSession.make(
            config: CloudASRConfig(provider: .openai, apiKey: "sk-x"),
            fallback: stubFallback(), officialOpenAI: false))
    }

    /// 松手时发到的采样数必须**恰好等于**同步那条路会拿去识别的那一段，不多不少
    func testSessionSendsExactlyTheWholeTakeAndNoMore() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let session = CloudStreamingSession(config: streamingConfig(),
                                            fallback: stubFallback(), client: client)
        session.start()
        bringUp(client, socket)

        let take = tone(seconds: 3)
        // 录音中分两次喂（模拟电平回调），松手时把剩下的一截补上
        session.enqueue(Array(take[0..<16000]))
        session.enqueue(Array(take[16000..<24000]))
        client.drainForTesting()

        let done = expectation(description: "outcome")
        var outcome: TranscriptionOutcome?
        session.transcribe(samples: take, language: nil, previousText: "", onSegment: nil) {
            outcome = $0
            done.fulfill()
        }
        XCTAssertTrue(waitUntil(3) { socket.finishes.count == 1 })
        XCTAssertEqual(socket.appendedPCMBytes(), take.count * 2,
                       "发出去的音频必须正好是这一整段")
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"三秒的话","usage":{"duration":3}}"#)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcome?.text, "三秒的话")
        XCTAssertEqual(outcome?.isComplete, true)
    }

    /// 云端识别的**终稿**也要过一遍本地清理（4.3.3），中间结果（悬浮窗灰字）不清。
    ///
    /// 4.3.3 之前云端这条路一个字都没清过：本机档默认删掉的「嗯 / 那个 / um」在云端档
    /// 原样进输入框，润色再被保真校验拦下的话，用户看到的就是满屏语气词的识别原文
    /// （mini 上 2026-09-22 的 history.json 里那条「啊啊，这个接口……是是怎么回事啊」）。
    func testFinalTranscriptGetsTheSameLocalCleanupAsTheLocalEngine() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let session = CloudStreamingSession(config: streamingConfig(),
                                            fallback: stubFallback(), client: client)
        var drafts: [String] = []
        session.onDraft = { drafts.append($0) }
        session.start()
        bringUp(client, socket)
        let take = tone(seconds: 1)
        session.enqueue(take)
        client.drainForTesting()

        let done = expectation(description: "outcome")
        var outcome: TranscriptionOutcome?
        session.transcribe(samples: take, language: nil, previousText: "", onSegment: nil) {
            outcome = $0
            done.fulfill()
        }
        XCTAssertTrue(waitUntil(3) { socket.finishes.count == 1 })
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.text","text":"嗯，那个，我们明天","stash":"开会"}"#)
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"嗯，那个，我们明天开会。","usage":{"duration":1}}"#)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(outcome?.text, "我们明天开会。", "口水词该在交付之前就删掉")
        XCTAssertEqual(drafts.last, "嗯，那个，我们明天开会",
                       "草稿不清：它每 100 ms 重画一次，边说边删只会让字在眼前跳")
    }

    /// 静音门判「没说话」：不发 finish、直接掐掉，与今天的行为一致
    func testAbandonSendsNoFinish() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let session = CloudStreamingSession(config: streamingConfig(),
                                            fallback: stubFallback(), client: client)
        session.start()
        bringUp(client, socket)
        session.enqueue(tone(seconds: 1))
        client.drainForTesting()
        session.abandon()
        client.drainForTesting()
        XCTAssertTrue(socket.finishes.isEmpty)
        XCTAssertTrue(socket.cancelled)
        XCTAssertFalse(session.isLive)
    }

    /// 松手之前就断了，这一轮交给谁（纯函数）。用户 2026-09-21 定的两条分支：
    /// 「这台主机没有实时接口」→ 照常整段上传；「网断了」+ 本机模型在 → 直接回落本机
    func testLostRouteSendsTransientFailuresToTheLocalEngine() {
        typealias Failure = AlibabaRealtimeClient.Failure
        // 这台主机不支持实时：链路本身好好的，整段上传反而是对的
        for failure: Failure in [.handshakeRejected(status: 403), .modelUnavailable,
                                 .modelMismatch(reported: "x")] {
            XCTAssertEqual(CloudStreamingSession.route(afterLosing: failure,
                                                       localModelAvailable: true),
                           .uploadWholeTake)
            XCTAssertEqual(CloudStreamingSession.route(afterLosing: failure,
                                                       localModelAvailable: false),
                           .uploadWholeTake)
        }
        // 偶发断线：网多半本来就出了问题，再传一趟整段大概率也失败，而那条路超时 120 秒
        XCTAssertEqual(CloudStreamingSession.route(afterLosing: .transport("closed"),
                                                   localModelAvailable: true), .localEngine)
        XCTAssertEqual(CloudStreamingSession.route(afterLosing: .serverError(code: nil, message: nil),
                                                   localModelAvailable: true), .localEngine)
        // 没有本机模型可回落：那就只剩整段上传这一条路，试一次总比直接报错强
        XCTAssertEqual(CloudStreamingSession.route(afterLosing: .transport("closed"),
                                                   localModelAvailable: false), .uploadWholeTake)
        XCTAssertEqual(CloudStreamingSession.route(afterLosing: nil, localModelAvailable: true),
                       .uploadWholeTake)
    }

    /// 「这台主机不支持实时」→ 这一轮自己退回整段上传，用户什么都不该察觉
    func testStreamLostBeforeReleaseFallsBackToTheUploadPath() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let session = CloudStreamingSession(config: streamingConfig(),
                                            fallback: stubFallback(text: "整段上传的结果"),
                                            client: client)
        session.localModelAvailable = { true }
        let lost = expectation(description: "lost")
        session.onStreamingLost = { lost.fulfill() }
        session.start()
        client.drainForTesting()
        socket.close(status: 403, code: nil, detail: nil)
        wait(for: [lost], timeout: 2)
        XCTAssertFalse(session.isLive)
        XCTAssertTrue(CloudStreamingAvailability.isUnsupported(provider: .alibaba,
                                                 host: "dashscope-intl.aliyuncs.com"))

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

    /// 录音中途断线 + 本机模型在 → 报 failure 上去，让现有那条「云端失败 → 回落本机」接手整段
    func testStreamLostTransientlyHandsTheTakeToTheLocalEngine() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let session = CloudStreamingSession(config: streamingConfig(),
                                            fallback: stubFallback(text: "不该走到这里"),
                                            client: client)
        session.localModelAvailable = { true }
        let lost = expectation(description: "lost")
        session.onStreamingLost = { lost.fulfill() }
        session.start()
        bringUp(client, socket)
        session.enqueue(tone(seconds: 1))
        client.drainForTesting()
        // 录到一半网断了（没有 HTTP 状态码 = 偶发，不是"这台主机不支持"）
        socket.close(status: nil, code: 1006, detail: "NSURLErrorDomain -1005")
        wait(for: [lost], timeout: 2)
        XCTAssertFalse(CloudStreamingAvailability.isUnsupported(provider: .alibaba,
                                                 host: "dashscope-intl.aliyuncs.com"),
                       "一次断网不该把这台主机的实时判死")

        let done = expectation(description: "outcome")
        var outcome: TranscriptionOutcome?
        session.transcribe(samples: tone(seconds: 3), language: nil, previousText: "",
                           onSegment: nil) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(outcome?.failure, "要报上去，上层才会整段重跑本机")
        XCTAssertEqual(outcome?.text, "")
        XCTAssertEqual(outcome?.cancelled, false)
    }

    /// 同一次断线，但这台机器没有本机模型 → 只剩整段上传这一条路
    func testStreamLostTransientlyWithoutALocalModelStillUploads() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let session = CloudStreamingSession(config: streamingConfig(),
                                            fallback: stubFallback(text: "整段上传的结果"),
                                            client: client)
        session.localModelAvailable = { false }
        let lost = expectation(description: "lost")
        session.onStreamingLost = { lost.fulfill() }
        session.start()
        bringUp(client, socket)
        socket.close(status: nil, code: 1006, detail: nil)
        wait(for: [lost], timeout: 2)

        let done = expectation(description: "outcome")
        var outcome: TranscriptionOutcome?
        session.transcribe(samples: tone(seconds: 1), language: nil, previousText: "",
                           onSegment: nil) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(outcome?.text, "整段上传的结果")
        XCTAssertNil(outcome?.failure)
    }

    /// 偶发失败（终稿超时）交回给现有那条「云端失败 → 回落本机」的路：
    /// 报一个 failure 上去，整段音频还在调用方手上
    func testTransientFailureAfterFinishIsReportedSoTheLocalEngineCanRetry() {
        let socket = FakeSocket()
        let client = makeClient(socket) { $0.finalTimeout = 0.2 }
        let session = CloudStreamingSession(config: streamingConfig(),
                                            fallback: stubFallback(), client: client)
        session.start()
        bringUp(client, socket)
        let take = tone(seconds: 1)
        session.enqueue(take)
        client.drainForTesting()

        let done = expectation(description: "outcome")
        var outcome: TranscriptionOutcome?
        session.transcribe(samples: take, language: nil, previousText: "", onSegment: nil) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 4)
        XCTAssertNotNil(outcome?.failure, "偶发失败要报上去，上层才会整段重跑本机")
        XCTAssertEqual(outcome?.cancelled, false)
        XCTAssertEqual(outcome?.text, "")
        // 一次超时不该把这台主机的实时判死
        XCTAssertFalse(CloudStreamingAvailability.isUnsupported(provider: .alibaba,
                                                 host: "dashscope-intl.aliyuncs.com"))
    }
}
