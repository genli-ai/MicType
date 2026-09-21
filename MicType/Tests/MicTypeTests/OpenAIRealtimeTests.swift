import XCTest
@testable import MicType

/// OpenAI 实时转写：协议层与重采样的单测。**一个字节都不上网**——socket 是注入的假实现。
///
/// 为什么这些用例值得存在（每一条都对应一次真金白银的实测教训，
/// 见 docs/OpenAI实时识别-协议实测_260921.md）：
///   • **握手永远 101**，错 Key 也是——真正的原因在 error 事件与 close 3000/4000 里；
///   • `session.update` 之后的任何 error = 配置没生效 = **零输出**，必须当致命处理；
///   • **buffer 里有音频时再发 update 会把那段音频整段吞掉**（不报错、不断连）→
///     所以 append 必须等到 `session.updated`，重发 update 也只能发生在那之前；
///   • 端点**只认 24 kHz**，而 App 录的是 16 kHz；
///   • 超过约 4× 实时会**静默丢音频**（没有任何错误）→ 节流按 ≤3×。
final class OpenAIRealtimeTests: XCTestCase {

    private typealias FakeSocket = CloudStreamingTests.FakeSocket

    override func setUp() {
        super.setUp()
        CloudStreamingAvailability.resetForTesting()
    }

    override func tearDown() {
        CloudStreamingAvailability.resetForTesting()
        super.tearDown()
    }

    // MARK: - 小工具

    private func makeClient(_ socket: FakeSocket,
                            options: OpenAIRealtimeClient.Options = .init(),
                            configure: ((inout OpenAIRealtimeClient.Config) -> Void)? = nil)
        -> OpenAIRealtimeClient {
        var config = OpenAIRealtimeClient.Config(apiKey: "sk-unit-test", options: options)
        configure?(&config)
        return OpenAIRealtimeClient(config: config, makeSocket: { _, _ in socket })
    }

    /// 连到"可以送音频了"那一刻
    private func bringUp(_ client: OpenAIRealtimeClient, _ socket: FakeSocket) {
        client.start()
        client.drainForTesting()
        socket.open()
        client.drainForTesting()
        socket.receive(#"{"type":"session.created","session":{"id":"sess_x"}}"#)
        client.drainForTesting()
        socket.receive(#"{"type":"session.updated","session":{"id":"sess_x"}}"#)
        client.drainForTesting()
    }

    private func tone(seconds: Double, rate: Int = 16000, frequency: Double = 440,
                      amplitude: Double = 0.4) -> [Float] {
        let count = Int(seconds * Double(rate))
        return (0..<count).map {
            Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / Double(rate)))
        }
    }

    @discardableResult
    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    // MARK: - 纯函数 · 消息体

    /// 地址、模型位置、头——三件事各错一次都够让整条路废掉
    func testEndpointPutsIntentInQueryAndNotTheModel() throws {
        let url = try XCTUnwrap(OpenAIRealtimeClient.endpoint())
        XCTAssertEqual(url.absoluteString,
                       "wss://api.openai.com/v1/realtime?intent=transcription")
        // 模型放 query → invalid_model + close 4000
        XCTAssertFalse(url.absoluteString.contains("model="))
    }

    func testSessionUpdateBodyMatchesTheMeasuredMinimum() throws {
        var options = OpenAIRealtimeClient.Options()
        options.languages = ["zh", "en"]
        options.keywords = ["MicType"]
        let text = OpenAIRealtimeClient.sessionUpdateMessage(
            model: OpenAIRealtimeClient.model, rate: 24000, options: options)
        let json = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(text.utf8)))
                                    as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "session.update")
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        // 每条 update 都要带 type，不带 = 零输出
        XCTAssertEqual(session["type"] as? String, "transcription")
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        // **只能是 24000**（16000 / 48000 都报错）
        XCTAssertEqual(format["rate"] as? Int, 24000)
        // 必须显式关掉，否则走 server VAD
        XCTAssertTrue(input["turn_detection"] is NSNull)
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        // **模型放这里，不放 query**
        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription["languages"] as? [String], ["zh", "en"])
        XCTAssertEqual(transcription["keywords"] as? [String], ["MicType"])
        XCTAssertEqual(transcription["delay"] as? String, "low")
    }

    /// 空的可选字段一个都不许出现在请求体里：送一个空数组是在试服务端的脾气
    func testEmptyOptionalsAreOmitted() throws {
        let text = OpenAIRealtimeClient.sessionUpdateMessage(
            model: OpenAIRealtimeClient.model, rate: 24000,
            options: OpenAIRealtimeClient.Options(languages: [], keywords: [], delay: nil))
        XCTAssertFalse(text.contains("languages"), text)
        XCTAssertFalse(text.contains("keywords"), text)
        XCTAssertFalse(text.contains("delay"), text)
    }

    /// 词汇表 → keywords：去重、去空、单条 ≤40 字符、总数 ≤100（上限官方没公布，保守值）
    func testKeywordsAreDedupedAndCapped() {
        let terms = ["MicType", "  Qwen  ", "MicType", "", String(repeating: "长", count: 41)]
        XCTAssertEqual(OpenAIRealtimeClient.keywords(from: terms), ["MicType", "Qwen"])
        let many = (0..<250).map { "term\($0)" }
        XCTAssertEqual(OpenAIRealtimeClient.keywords(from: many).count,
                       OpenAIRealtimeClient.keywordLimit)
        XCTAssertEqual(OpenAIRealtimeClient.keywords(from: ["ok"], limit: 5, maxCharacters: 1), [])
    }

    /// 被拒的是哪个可摘字段：服务端把名字放 param，偶尔只在 message 里提，两处都看
    func testRejectedFieldIsFoundInParamOrMessage() {
        XCTAssertEqual(OpenAIRealtimeClient.rejectedField(
            code: "invalid_value", message: nil,
            param: "session.audio.input.transcription.keywords"), .keywords)
        XCTAssertEqual(OpenAIRealtimeClient.rejectedField(
            code: "invalid_value", message: "Unknown parameter: delay", param: nil), .delay)
        XCTAssertEqual(OpenAIRealtimeClient.rejectedField(
            code: nil, message: "invalid languages code", param: nil), .languages)
        // 模型那一条摘不掉——没有它整条路就不存在
        XCTAssertNil(OpenAIRealtimeClient.rejectedField(
            code: "invalid_value", message: "invalid model name",
            param: "session.audio.input.transcription.model"))
    }

    func testUnauthorizedDetection() {
        XCTAssertTrue(OpenAIRealtimeClient.isUnauthorized(code: "invalid_api_key", message: nil))
        XCTAssertTrue(OpenAIRealtimeClient.isUnauthorized(
            code: nil, message: "Incorrect API key provided"))
        XCTAssertFalse(OpenAIRealtimeClient.isUnauthorized(code: "invalid_value", message: nil))
    }

    func testEventDecoding() {
        XCTAssertEqual(OpenAIRealtimeEvent.parse(#"{"type":"session.created"}"#), .sessionCreated)
        XCTAssertEqual(OpenAIRealtimeEvent.parse(#"{"type":"session.updated"}"#), .sessionUpdated)
        XCTAssertEqual(
            OpenAIRealtimeEvent.parse(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"今天"}"#),
            .delta("今天"))
        XCTAssertEqual(
            OpenAIRealtimeEvent.parse(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"今天天气不错","usage":{"seconds":5,"type":"duration"}}"#),
            .completed(transcript: "今天天气不错", seconds: 5))
        XCTAssertEqual(
            OpenAIRealtimeEvent.parse(#"{"type":"error","error":{"code":"invalid_api_key","message":"nope","param":null}}"#),
            .failed(code: "invalid_api_key", message: "nope", param: nil))
        XCTAssertEqual(OpenAIRealtimeEvent.parse(#"{"type":"input_audio_buffer.committed"}"#), .ignored)
        XCTAssertEqual(OpenAIRealtimeEvent.parse("not json"), .ignored)
    }

    // MARK: - 状态机

    /// **`session.updated` 之前一个字节都不许送**：buffer 里有音频时重发 update
    /// 会把那段音频从终稿里整段吞掉（不报错、不断连），这是这条路上最阴险的坑
    func testNoAudioLeavesBeforeTheSessionIsConfirmed() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        client.onFinish = { _ in }
        client.start()
        client.drainForTesting()
        socket.open()
        client.drainForTesting()
        client.append(samples: tone(seconds: 1))
        client.drainForTesting()
        XCTAssertTrue(socket.appends.isEmpty, "session.created 都还没到就送音频了")
        socket.receive(#"{"type":"session.created"}"#)
        client.drainForTesting()
        XCTAssertEqual(socket.updates.count, 1)
        XCTAssertTrue(socket.appends.isEmpty, "session.updated 之前不许送音频")
        socket.receive(#"{"type":"session.updated"}"#)
        XCTAssertTrue(waitUntil(3) { !socket.appends.isEmpty }, "确认之后才补发")
    }

    func testHappyPathAccumulatesDeltasAndTakesTheFinalTranscript() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        var drafts: [String] = []
        client.onPartial = { drafts.append($0) }
        let done = expectation(description: "final")
        var transcript: RealtimeTranscript?
        client.onFinish = { result in
            if case .success(let value) = result { transcript = value }
            done.fulfill()
        }
        bringUp(client, socket)
        client.append(samples: tone(seconds: 1))
        // 1 秒 16 kHz → 1 秒 24 kHz = 48000 字节 PCM16。**要等**：令牌桶一次只放 0.5 秒出去
        XCTAssertTrue(waitUntil(3) { socket.appendedPCMBytes() == 48000 },
                      "实际发了 \(socket.appendedPCMBytes()) 字节")

        socket.receive(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"今天"}"#)
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"天气"}"#)
        client.drainForTesting()

        client.finish(audioSeconds: 1)
        // **没有 session.finish**：commit 就是全部
        XCTAssertTrue(waitUntil(3) { socket.commits.count == 1 })
        XCTAssertTrue(socket.finishes.isEmpty, "OpenAI 这边没有 session.finish 这回事")

        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"今天天气不错","usage":{"seconds":1}}"#)
        wait(for: [done], timeout: 2)
        // delta 纯增量、只追加 → 草稿是累加出来的
        XCTAssertEqual(drafts, ["今天", "今天天气"])
        // 终稿到了以终稿为准
        XCTAssertEqual(transcript?.text, "今天天气不错")
        XCTAssertEqual(transcript?.billedSeconds, 1)
        XCTAssertTrue(socket.cancelled)
    }

    /// usage **每个 item 独立，要相加**（阿里云是整条会话累计、取最后一条，正好相反）
    func testUsageSecondsAreSummedAcrossItems() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let done = expectation(description: "final")
        var transcript: RealtimeTranscript?
        client.onFinish = { result in
            if case .success(let value) = result { transcript = value }
            done.fulfill()
        }
        bringUp(client, socket)
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"前半","usage":{"seconds":20}}"#)
        client.drainForTesting()
        client.append(samples: tone(seconds: 0.5))
        client.finish(audioSeconds: 40)
        XCTAssertTrue(waitUntil(3) { socket.commits.count == 1 })
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"后半","usage":{"seconds":20}}"#)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(transcript?.billedSeconds, 40, "两个 item 要相加，不是取最后一条")
        XCTAssertEqual(transcript?.text, "前半后半")
    }

    /// update 被拒且点名的是可摘字段 → 摘掉**重发一次**。
    /// 此刻 buffer 一定是空的（还没送过音频），所以重发是安全的——这正是"不抢跑"的理由。
    func testRejectedKeywordsAreDroppedAndTheUpdateIsResent() {
        let socket = FakeSocket()
        var options = OpenAIRealtimeClient.Options()
        options.keywords = ["MicType"]
        let client = makeClient(socket, options: options)
        client.onFinish = { _ in XCTFail("摘掉重发之后不该失败") }
        client.start()
        client.drainForTesting()
        socket.open()
        client.drainForTesting()
        socket.receive(#"{"type":"session.created"}"#)
        client.drainForTesting()
        XCTAssertEqual(socket.updates.count, 1)
        XCTAssertTrue(socket.updates[0].contains("keywords"))

        socket.receive(#"{"type":"error","error":{"code":"invalid_value","param":"session.audio.input.transcription.keywords","message":"unknown"}}"#)
        client.drainForTesting()
        XCTAssertEqual(socket.updates.count, 2, "摘掉那个字段之后要重发一次")
        XCTAssertFalse(socket.updates[1].contains("keywords"), "重发的那条不该还带着它")
        XCTAssertFalse(socket.cancelled, "这不是致命错误")
        XCTAssertTrue(socket.appends.isEmpty, "重发 update 的时候 buffer 必须是空的")
    }

    /// 同一个字段不试第二遍，模型那一条压根不试：**配置没生效 = 零输出**，必须当致命处理
    func testFatalConfigurationErrorDisablesStreaming() {
        for payload in [
            #"{"type":"error","error":{"code":"invalid_value","param":"session.audio.input.transcription.model","message":"invalid model"}}"#,
            #"{"type":"error","error":{"code":"beta_api_shape_disabled","message":"nope"}}"#,
        ] {
            let socket = FakeSocket()
            let client = makeClient(socket)
            let done = expectation(description: "failed")
            var failure: RealtimeFailure?
            client.onFinish = { result in
                if case .failure(let value) = result { failure = value }
                done.fulfill()
            }
            client.start()
            client.drainForTesting()
            socket.open()
            client.drainForTesting()
            socket.receive(#"{"type":"session.created"}"#)
            client.drainForTesting()
            socket.receive(payload)
            wait(for: [done], timeout: 2)
            XCTAssertEqual(failure, .modelUnavailable, payload)
            XCTAssertEqual(failure?.disablesStreaming, true)
        }
    }

    func testInvalidApiKeyIsUnauthorized() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let done = expectation(description: "failed")
        var failure: RealtimeFailure?
        client.onFinish = { result in
            if case .failure(let value) = result { failure = value }
            done.fulfill()
        }
        client.start()
        client.drainForTesting()
        socket.open()               // **错 Key 也是 101**
        client.drainForTesting()
        socket.receive(#"{"type":"error","error":{"code":"invalid_api_key","message":"nope"}}"#)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(failure, .unauthorized(code: "invalid_api_key"))
        XCTAssertEqual(failure?.disablesStreaming, true)
    }

    /// 关闭码就是这边的"握手状态码"：3000 = Key，4000 = 请求非法，其余按偶发断线
    func testCloseCodeClassification() {
        let cases: [(Int?, RealtimeFailure)] = [
            (3000, .unauthorized(code: "close 3000")),
            (4000, .modelUnavailable),
            (1000, .transport("closed code=1000 ")),
        ]
        for (code, expected) in cases {
            let socket = FakeSocket()
            let client = makeClient(socket)
            let done = expectation(description: "failed \(code ?? -1)")
            var failure: RealtimeFailure?
            client.onFinish = { result in
                if case .failure(let value) = result { failure = value }
                done.fulfill()
            }
            bringUp(client, socket)
            socket.close(status: nil, code: code, detail: nil)
            wait(for: [done], timeout: 2)
            XCTAssertEqual(failure, expected)
        }
        XCTAssertEqual(RealtimeFailure.unauthorized(code: "close 3000").disablesStreaming, true)
        XCTAssertEqual(RealtimeFailure.transport("closed code=1000 ").disablesStreaming, false)
    }

    /// 不到 100 ms 的音频不 commit（服务端判非致命错误、也不会有终稿）：
    /// 当成"什么都没听到"交出去，交给静音门那条既有的路
    func testTooShortTakeIsNotCommitted() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        let done = expectation(description: "final")
        var transcript: RealtimeTranscript?
        client.onFinish = { result in
            if case .success(let value) = result { transcript = value }
            done.fulfill()
        }
        bringUp(client, socket)
        client.append(samples: tone(seconds: 0.05))
        client.finish(audioSeconds: 0.05)
        wait(for: [done], timeout: 3)
        XCTAssertTrue(socket.commits.isEmpty, "不到 100 ms 不许 commit")
        XCTAssertEqual(socket.clears.count, 1, "服务端 buffer 里那一小段要清掉")
        XCTAssertEqual(transcript?.text, "")
    }

    /// Esc：先 clear 再关，**不 commit**，而且之后一条回调都不来
    func testCancelClearsTheBufferAndCallsNothingBack() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        client.onFinish = { _ in XCTFail("取消之后不许再回调") }
        client.onPartial = { _ in XCTFail("取消之后不许再回调") }
        bringUp(client, socket)
        client.append(samples: tone(seconds: 1))
        client.drainForTesting()
        client.cancel()
        client.drainForTesting()
        XCTAssertEqual(socket.clears.count, 1)
        XCTAssertTrue(socket.commits.isEmpty)
        XCTAssertTrue(socket.cancelled)
        socket.receive(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"迟到的终稿"}"#)
        client.drainForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    /// 节流：**超过约 4× 实时会静默丢音频**（没有任何错误），所以补发按 ≤3× 走
    func testBacklogIsThrottledUnderThreeTimesRealtime() {
        let socket = FakeSocket()
        let client = makeClient(socket)
        client.onFinish = { _ in }
        bringUp(client, socket)
        let seconds = 6.0
        let startedAt = Date()
        client.append(samples: tone(seconds: seconds))
        let expected = Int(seconds * 48000)        // 24 kHz × 2 字节
        XCTAssertTrue(waitUntil(6) { socket.appendedPCMBytes() >= expected },
                      "积压没发完：\(socket.appendedPCMBytes()) / \(expected)")
        let elapsed = Date().timeIntervalSince(startedAt)
        // 桶容量 0.5 秒 + 3× 实时 → 6 秒音频最快也要 (6−0.5)/3 ≈ 1.8 秒
        XCTAssertGreaterThan(elapsed, 1.2, "一口气全推出去了，节流没生效（会被静默丢音频）")
        XCTAssertGreaterThan(socket.appends.count, 1)
    }

    /// 松手时还没连上：压到宽限值内收口，别让用户对着悬浮窗干等整个建连预算
    func testFinishWhileStillConnectingGivesUpWithinTheGrace() {
        let socket = FakeSocket()
        let client = makeClient(socket) {
            $0.setupTimeout = 30
            $0.releaseSetupGrace = 0.2
        }
        let done = expectation(description: "failed")
        var failure: RealtimeFailure?
        client.onFinish = { result in
            if case .failure(let value) = result { failure = value }
            done.fulfill()
        }
        client.start()
        client.drainForTesting()
        client.append(samples: tone(seconds: 0.5))
        client.finish(audioSeconds: 0.5)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(failure, .transport("setup timeout after release"))
        XCTAssertEqual(failure?.disablesStreaming, false)
    }

    // MARK: - 16 kHz → 24 kHz 重采样

    /// 长度：每 2 个输入出 3 个输出
    func testResamplerOutputLengthIsOneAndAHalfTimesTheInput() {
        for seconds in [0.1, 1.0, 3.3] {
            let input = tone(seconds: seconds)
            let output = Resampler16kTo24k.resampleWhole(input)
            XCTAssertLessThanOrEqual(abs(output.count - input.count * 3 / 2), 1,
                                     "\(seconds)s: \(output.count) vs \(input.count)")
        }
        // 1 秒 16 kHz → 正好 24000 个采样
        XCTAssertEqual(Resampler16kTo24k.resampleWhole(tone(seconds: 1)).count, 24000)
    }

    /// 1 kHz 正弦重采样之后**主频仍然是 1 kHz**——这条不过就说明滤波器或相位算错了，
    /// 而那听起来是变调或一片嗡嗡声
    func testResamplerKeepsTheToneAtOneKilohertz() {
        let input = tone(seconds: 0.5, frequency: 1000, amplitude: 0.8)
        let output = Resampler16kTo24k.resampleWhole(input)
        // 掐掉头尾的滤波器瞬态再量
        let body = Array(output[600..<(output.count - 600)])
        func magnitude(_ hz: Double) -> Double {
            var re = 0.0, im = 0.0
            for (i, v) in body.enumerated() {
                let phase = 2 * Double.pi * hz * Double(i) / 24000
                re += Double(v) * cos(phase)
                im -= Double(v) * sin(phase)
            }
            return (re * re + im * im).squareRoot() / Double(body.count)
        }
        let target = magnitude(1000)
        for other in [500.0, 2000, 3000, 5000, 7000, 11000] {
            XCTAssertGreaterThan(target, magnitude(other) * 20,
                                 "1 kHz 没有压倒 \(other) Hz：主频跑掉了")
        }
    }

    /// 幅度不溢出：0.8 的正弦重采样之后仍然在 1.0 以内（超了就是削顶失真）
    func testResamplerDoesNotOvershoot() {
        let output = Resampler16kTo24k.resampleWhole(tone(seconds: 0.5, frequency: 1000,
                                                          amplitude: 0.8))
        let peak = output.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, 1.0, "重采样把幅度顶出去了：\(peak)")
        XCTAssertGreaterThan(peak, 0.7, "幅度掉了一大截：\(peak)")
    }

    /// **流式安全**：一小块一小块地喂，结果必须与整段喂逐字一致。
    /// 不成立就意味着每个块的接缝上有一声咔哒，而录音是每 85 ms 喂一次的
    func testResamplerIsChunkInvariant() {
        let input = tone(seconds: 1, frequency: 1000, amplitude: 0.8)
        let whole = Resampler16kTo24k.resampleWhole(input)
        let streaming = Resampler16kTo24k()
        var chunked = [Float]()
        var offset = 0
        // 故意用不整齐、不重复的块长（100 ms / 37 个采样 / 1 个采样都要对得上）
        let sizes = [1600, 37, 1, 4000, 999]
        var index = 0
        while offset < input.count {
            let size = sizes[index % sizes.count]
            index += 1
            let end = min(offset + size, input.count)
            chunked.append(contentsOf: streaming.resample(Array(input[offset..<end])))
            offset = end
        }
        XCTAssertEqual(chunked.count, whole.count)
        for (a, b) in zip(chunked, whole) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }

    // MARK: - 接线层：哪些档位有实时这条路

    /// OpenAI 档指着第三方网关时**没有实时这条路**：那个地址是写死的官方域名，
    /// 音频会绕过用户自己的网关直接去 OpenAI——既不是他要的，也可能根本没额度
    func testGatewayOpenAIGetsNoStreaming() {
        let config = CloudASRConfig(provider: .openai, apiKey: "sk-x")
        let fallback = CloudASREngine(config: config)
        XCTAssertNil(CloudStreamingSession.make(config: config, fallback: fallback,
                                                officialOpenAI: false))
        XCTAssertNotNil(CloudStreamingSession.make(config: config, fallback: fallback,
                                                   officialOpenAI: true))
    }

    /// 「这条链路的实时用不了」的记忆键是**服务商 + 主机**：两家互不影响
    func testUnsupportedMemoryIsPerProvider() {
        CloudStreamingAvailability.markUnsupported(provider: .openai, host: "api.openai.com",
                                                   reason: "close 4000")
        XCTAssertTrue(CloudStreamingAvailability.isUnsupported(provider: .openai,
                                                               host: "api.openai.com"))
        XCTAssertFalse(CloudStreamingAvailability.isUnsupported(provider: .alibaba,
                                                                host: "api.openai.com"))
        let openAI = CloudASRConfig(provider: .openai, apiKey: "sk-x")
        XCTAssertNil(CloudStreamingSession.make(config: openAI,
                                                fallback: CloudASREngine(config: openAI),
                                                officialOpenAI: true))
        // 阿里云那一档照样开得起来
        let alibaba = CloudASRConfig(provider: .alibaba, host: "dashscope-intl.aliyuncs.com",
                                     apiKey: "sk-x")
        XCTAssertNotNil(CloudStreamingSession.make(config: alibaba,
                                                   fallback: CloudASREngine(config: alibaba)))
    }

    /// 两家的实时模型名不一样，界面上那行字读的就是它
    func testStreamModelPerProvider() {
        XCTAssertEqual(CloudStreamingSession.streamModel(for: .alibaba),
                       "qwen3-asr-flash-realtime")
        XCTAssertEqual(CloudStreamingSession.streamModel(for: .openai), "gpt-live-transcribe")
        XCTAssertEqual(CloudStreamingSession.streamHost(for:
            CloudASRConfig(provider: .openai, apiKey: "k")), "api.openai.com")
    }
}
