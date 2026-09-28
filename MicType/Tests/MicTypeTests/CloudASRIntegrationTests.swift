import XCTest
@testable import MicType

/// 云端识别**接线层**的单测：设置怎么变成一份引擎配置、哪一档现在能不能开工、
/// 云端炸了这一轮往哪走。全是纯函数，不碰网络、不碰 UserDefaults、不碰钥匙串——
/// 这几条判据正是"音频会不会离开这台 Mac"的闸门，必须钉死。
///
/// 文案断言故意写成"中文 或 英文"的形式（或只断言结构），因为 tr() 取的是运行时界面语言。
final class CloudASRIntegrationTests: XCTestCase {

    // MARK: - 档位本身

    func testEngineChoiceRawValuesAreStable() {
        // rawValue 仍然出现在日志与诊断信息里，改一个字就对不上
        XCTAssertEqual(RecognitionEngineChoice.cloudOpenAI.rawValue, "cloudOpenAI")
        XCTAssertEqual(RecognitionEngineChoice.allCases, [.cloudOpenAI],
                       "5.0.0 起没有本机那一档，5.1.0 起没有阿里云那一档")
        // 老设置 / 老文件里的 cloudAlibaba 读出来也是这一档
        XCTAssertEqual(RecognitionEngineChoice.parse("cloudAlibaba"), .cloudOpenAI)
    }

    /// 识别永远是 OpenAI 那一档（5.1.0 起不是推导，是唯一的答案）
    func testEngineIsAlwaysOpenAI() {
        XCTAssertEqual(Settings.shared.recognitionEngine, .cloudOpenAI)
    }

    func testCloudProviderMapping() {
        XCTAssertEqual(RecognitionEngineChoice.cloudOpenAI.cloudProvider, .openai)
        XCTAssertTrue(RecognitionEngineChoice.cloudOpenAI.isCloud)
    }

    // MARK: - 语言提示

    /// 5.0.0 起没有「识别语言」这条设置了（云端不发语言提示），
    /// 只剩这一条：词表里中西夹杂才送 ["zh","en"]——那是用户自己的词表在说话。
    func testAutoOnlyHintsWhenVocabularyIsMixed() {
        XCTAssertEqual(CloudASRSettings.languageHints(vocabulary: []), [])
        XCTAssertEqual(CloudASRSettings.languageHints(vocabulary: ["捷文", "云术法"]), [],
                       "只有中文词条不等于只说中文，不替用户锁语言")
        XCTAssertEqual(CloudASRSettings.languageHints(vocabulary: ["Power BI"]), [])
        XCTAssertEqual(CloudASRSettings.languageHints(vocabulary: ["捷文", "Power BI"]), ["zh", "en"])
        XCTAssertEqual(CloudASRSettings.languageHints(vocabulary: ["MicType 捷文"]), ["zh", "en"],
                       "同一条词条里中西夹杂也算混合")
    }

    func testScriptDetectionHelpers() {
        XCTAssertTrue(CloudASRSettings.containsCJK("捷文"))
        XCTAssertTrue(CloudASRSettings.containsCJK("テスト"))
        XCTAssertFalse(CloudASRSettings.containsCJK("Power BI"))
        XCTAssertFalse(CloudASRSettings.containsCJK("مرحبا"), "阿拉伯语不是 CJK")
        XCTAssertTrue(CloudASRSettings.containsLatinLetter("Power BI"))
        XCTAssertFalse(CloudASRSettings.containsLatinLetter("捷文"))
        XCTAssertFalse(CloudASRSettings.containsLatinLetter("123"))
    }

    // MARK: - 组装配置

    func testConfigCarriesVocabularyAndHints() {
        let config = CloudASRSettings.config(vocabulary: ["捷文", "Power BI"], apiKey: "sk-test")
        XCTAssertEqual(config.provider, .openai)
        XCTAssertEqual(config.languageHints, ["zh", "en"], "词表中西夹杂 → 两个提示")
        XCTAssertEqual(config.vocabulary, ["捷文", "Power BI"], "词表原样交给客户端，过滤在那一层")
        XCTAssertEqual(config.apiKey, "sk-test")
    }

    /// 词表要真的变成 keywords[]——这是云端档下专有名词准确率的第一杠杆
    func testVocabularyReachesTheKeywordsField() {
        let config = CloudASRSettings.config(vocabulary: ["MicType", "捷文"], apiKey: "k")
        let body = OpenAITranscribeClient.multipartBody(boundary: "B", wav: Data(),
                                                        model: OpenAITranscribeClient.defaultModel,
                                                        languages: config.languageHints,
                                                        keywords: config.vocabulary, prompt: nil)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\nMicType"), text)
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\n捷文"), text)
    }

    // MARK: - 开录之前：这一档能不能用

    /// 5.0.0 起只剩两个闸门，而且**先问 Key**：没填 Key 的人就算这会儿断网，
    /// 他要做的第一件事也是去填 Key；反过来，Key 好好的人按不出字八成就是网没了。
    func testReadinessMatrix() {
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .cloudOpenAI,
                                                           hasCloudKey: true, online: true),
                       .ready)
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .cloudOpenAI,
                                                           hasCloudKey: false, online: true),
                       .cloudKeyMissing(.openai))
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .cloudOpenAI,
                                                           hasCloudKey: true, online: false),
                       .offline)
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .cloudOpenAI,
                                                           hasCloudKey: false, online: false),
                       .cloudKeyMissing(.openai), "没 Key 优先于没网")
    }

    /// 每一种"开不了工"都必须有一句话；缺 Key 那一档还要有可点的胶囊
    func testReadinessMessagesAndChips() {
        XCTAssertTrue(RecognitionEngineReadiness.ready.isReady)
        XCTAssertTrue(RecognitionEngineReadiness.ready.message.isEmpty)
        XCTAssertNil(RecognitionEngineReadiness.ready.settingsChipLabel)
        // 没网那一档不给胶囊：设置页上没有任何一个开关能把网接回来
        XCTAssertNil(RecognitionEngineReadiness.offline.settingsChipLabel)
        for state: RecognitionEngineReadiness in [.offline, .cloudKeyMissing(.openai)] {
            XCTAssertFalse(state.isReady)
            XCTAssertFalse(state.message.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        XCTAssertNotNil(RecognitionEngineReadiness.cloudKeyMissing(.openai).settingsChipLabel)
    }

    // MARK: - 云端炸了之后

    /// 5.0.0 没有本机模型可回落了：整段录音还在内存里，**先拿它再走一次同步接口**。
    /// 用户说过的话一个字都不该因为云端抽一下就丢。
    func testFallbackRetriesTheSyncEndpointOnce() {
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "", alreadyRetried: false),
                       .retryOnce)
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "前两段的字", alreadyRetried: false),
                       .retryOnce)
    }

    /// 已经重试过一次：有字就把已经转出来的段落交付出去，什么都没有才报错。
    /// **只重试一次**——再失败多半是 Key / 额度 / 网络本身的问题，第三趟只是让用户多等一轮。
    func testFallbackAfterTheRetry() {
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "前两段的字", alreadyRetried: true),
                       .deliverPartial)
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "", alreadyRetried: true),
                       .reportFailure)
    }

    func testRetryNoteNamesTheReasonAndStaysShort() {
        let note = CloudFallbackDecision.retryNote(reason: "429 Throttling")
        XCTAssertTrue(note.contains("429 Throttling"), "原因要原样摆出来：用户据此判断要不要重试")
        let long = CloudFallbackDecision.retryNote(reason: String(repeating: "x", count: 400))
        XCTAssertLessThan(long.count, 200, "悬浮窗一行放不下 400 个字符的云端原话")
    }

    /// 重试也没成那一句**不报技术细节**：他已经等了两趟，现在唯一有用的信息是"再说一次"
    func testRetryExhaustedCopyJustAsksToTryAgain() {
        XCTAssertFalse(CloudFallbackDecision.retryExhausted.isEmpty)
        XCTAssertFalse(CloudFallbackDecision.retryExhausted.contains("429"))
    }

    // MARK: - 探针（粘贴即验证 / 「测试识别」）

    func testProbeToneIsOneSecondOfAudibleSignal() {
        let tone = CloudASRProbe.toneSamples()
        XCTAssertEqual(tone.count, 16_000, "1 秒 @ 16kHz")
        XCTAssertTrue(tone.allSatisfy { abs($0) <= 0.5001 }, "半幅，不至于削顶")
        XCTAssertTrue(tone.contains { abs($0) > 0.4 }, "不能是一段静音——静音验不出 Key 好坏")
        XCTAssertEqual(CloudASRProbe.toneSamples(seconds: 0).count, 0)
    }

    /// HTTP 200 回来了、只是合成音没识别出字 —— 这正是探针的正常结果，必须算"通过"
    func testProbeAcceptsAnEmptyTranscriptButNotARealError() {
        let empty = CloudASRFailure("no text", code: CloudASRFailure.emptyTranscriptCode, status: 200)
        XCTAssertTrue(CloudASRProbe.isAcceptable(empty))
        XCTAssertFalse(CloudASRProbe.isAcceptable(
            OpenAITranscribeClient.failure(status: 401, code: "invalid_api_key", message: nil)))
        XCTAssertFalse(CloudASRProbe.isAcceptable(
            OpenAITranscribeClient.failure(status: 403, code: nil, message: nil)))
        XCTAssertFalse(CloudASRProbe.isAcceptable(CloudASRFailure("network down")),
                       "还没上网的失败（status 0）不能算通过")
    }

    /// 解析层要真的给出这个码，否则探针会把"通了但没字"当成失败
    func testParsersTagEmptyTranscriptsWithTheProbeCode() {
        guard case .failure(let openai) = OpenAITranscribeClient.parse(Data(#"{"foo":1}"#.utf8)) else {
            return XCTFail("没有 text 字段不能算成功")
        }
        XCTAssertEqual(openai.code, CloudASRFailure.emptyTranscriptCode)
    }

    /// 结果行必须写出"用的哪个型号"：不写出来用户就不知道自己到底在用什么
    func testProbeSuccessTextReportsRoundTripAndModel() {
        let text = CloudASRProbe.successText(
            CloudASRProbe.Outcome(milliseconds: 842, text: "", billedSeconds: 1,
                                  model: OpenAITranscribeClient.defaultModel))
        XCTAssertTrue(text.contains("842"))
        XCTAssertTrue(text.contains("✓"))
        XCTAssertTrue(text.contains("gpt-transcribe"))
    }

    // MARK: - SpeechEngine 桥接（不上网也测得到的那几条）

    /// 空音频：不上网、不报错，交付一段空文本（下游那句"没有听到内容"负责说话）
    func testSegmentedBridgeDeliversEmptyOutcomeForEmptyAudio() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .openai, apiKey: "sk-test"))
        let done = expectation(description: "completion")
        engine.transcribe(samples: [], onSegment: { _, _, _ in
            XCTFail("空音频不该报任何分段进度")
        }) { outcome in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(outcome.text, "")
            XCTAssertNil(outcome.failure)
            XCTAssertFalse(outcome.cancelled)
            XCTAssertFalse(outcome.isPartial)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// 没 Key：必须回一个带话的失败，而不是静默不回调（否则悬浮窗永远转圈）
    func testSegmentedBridgeFailsWithoutAKey() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .openai, apiKey: ""))
        let done = expectation(description: "completion")
        engine.transcribe(samples: [0.1, 0.2], onSegment: nil) { outcome in
            XCTAssertEqual(outcome.text, "")
            XCTAssertNotNil(outcome.failure)
            XCTAssertFalse(outcome.failure!.message.isEmpty)
            XCTAssertFalse(outcome.isComplete)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        // 没有 Key 的这一轮，重试过之后集成层按"什么都没有就报错"走
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "", alreadyRetried: true),
                       .reportFailure)
    }

    // 「语言提示送不送得到」那条测试随「识别语言」设置一起删掉（5.0.0）。

    // MARK: - 桥接层的取消语义（假发送器，不上网）

    /// 300 秒等能量音频：OpenAI 档（150 / 240 秒）切成 2 段（150 + 150），够跑完整条多段流程
    private func longAudio(seconds: Double = 300) -> [Float] {
        [Float](repeating: 0.05, count: Int(seconds * Double(WAVEncoder.defaultSampleRate)))
    }

    private func engineWithFakeSender(_ sender: FakeCloudSender,
                                      provider: CloudASRProvider = .openai) -> CloudASREngine {
        let engine = CloudASREngine(config: CloudASRConfig(provider: provider, apiKey: "sk-test"))
        engine.sendSegment = { request, client, handle, completion in
            sender.send(request, client, handle, completion)
        }
        return engine
    }

    /// Esc 必须**立刻**收口，而不是等在飞的那一段传完、转完（单段 150s 起步，
    /// 还可能退避重试一次；那段音频照常上传、照常计费）。
    /// 这条测试里第 2 段故意永远不回——修复之前它会超时变红。
    func testCancelDeliversWithoutWaitingForTheInflightSegment() {
        let sender = FakeCloudSender()
        sender.script(1, .success(CloudASRSegmentResult(text: "前面这一段已经转好了")))
        // 第 2 段不排结果 = 还在飞
        let engine = engineWithFakeSender(sender)

        let progressed = expectation(description: "第 1 段报上来")
        let finished = expectation(description: "交付")
        var delivered: TranscriptionOutcome?
        let handle = engine.transcribe(samples: longAudio(), language: nil, previousText: "",
                                       onSegment: { _, index, total in
            XCTAssertEqual(total, 2, "300 秒应该是 2 段")
            if index == 1 { progressed.fulfill() }
        }) { outcome in
            XCTAssertTrue(Thread.isMainThread)
            delivered = outcome
            finished.fulfill()
        }
        wait(for: [progressed], timeout: 20)
        // 第 2 段是在引擎自己的队列上排出去的，等它真的上路再按 Esc——
        // 要验的正是"在飞的那一段不必等它跑完"
        wait(for: [sender.expectRequest(2, self)], timeout: 20)

        handle.cancel()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(delivered?.text, "前面这一段已经转好了", "已经转好的段照常交付")
        XCTAssertEqual(delivered?.cancelled, true)
        XCTAssertNil(delivered?.failure, "用户自己停的，不是故障")
        XCTAssertEqual(delivered?.completedSegments, 1)
    }

    /// 取消**优先于**失败：Esc 之后在飞的那一段才超时/限流失败，不能报成"云端炸了"——
    /// 集成层的回落判据是 `usesCloud && failure != nil && !cancelled`，报错就会把整段音频
    /// 重新丢给本机引擎跑一遍（几十秒冷启动 + 整段插入），完全无视用户的停止。
    func testCancelledRunIsNeverReportedAsAFailure() {
        let sender = FakeCloudSender()
        sender.script(1, .success(CloudASRSegmentResult(text: "已经说完的前半段")))
        let engine = engineWithFakeSender(sender)

        let progressed = expectation(description: "第 1 段报上来")
        let finished = expectation(description: "交付")
        var outcomes: [TranscriptionOutcome] = []
        let handle = engine.transcribe(samples: longAudio(), language: nil, previousText: "",
                                       onSegment: { _, index, _ in
            if index == 1 { progressed.fulfill() }
        }) { outcome in
            outcomes.append(outcome)
            finished.fulfill()
        }
        wait(for: [progressed], timeout: 20)
        handle.cancel()
        wait(for: [finished], timeout: 5)

        // 在飞的第 2 段随后以失败收场（超时 + 退避重试也没过）
        sender.finishPending(.failure(CloudASRFailure("timeout", retryable: true)))
        drainMainQueue()

        XCTAssertEqual(outcomes.count, 1, "只许交付一次")
        XCTAssertEqual(outcomes.first?.cancelled, true)
        XCTAssertNil(outcomes.first?.failure, "取消之后的失败不是失败")
        XCTAssertEqual(outcomes.first?.text, "已经说完的前半段")
        // 这正是集成层"要不要回落本地"的判据：取消了就不许回落
        let outcome = outcomes.first
        XCTAssertFalse((outcome?.failure != nil) && !(outcome?.cancelled ?? false))
    }

    /// 段间上下文：第 2 段的请求里必须带着第 1 段的尾巴（帮云端接住被切开的句子）
    func testSegmentTailIsCarriedIntoTheNextRequest() {
        let sender = FakeCloudSender()
        sender.script(1, .success(CloudASRSegmentResult(text: "帮我把这段话记下来")))
        sender.script(2, .success(CloudASRSegmentResult(text: "然后发给张三")))
        let engine = engineWithFakeSender(sender)

        let finished = expectation(description: "交付")
        var delivered: TranscriptionOutcome?
        engine.transcribe(samples: longAudio(), language: nil, previousText: "",
                          onSegment: nil) { outcome in
            delivered = outcome
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)

        XCTAssertEqual(delivered?.text,
                       CloudTextJoiner.join(["帮我把这段话记下来", "然后发给张三"]))
        XCTAssertEqual(delivered?.completedSegments, 2)
        XCTAssertEqual(delivered?.cancelled, false)
        XCTAssertNil(delivered?.failure)
        XCTAssertEqual(sender.requestCount, 2)
        let body = sender.request(2)?.httpBody
        XCTAssertNotNil(body)
        XCTAssertNotNil(body?.range(of: Data("帮我把这段话记下来".utf8)),
                        "第 2 段必须带上第 1 段的尾巴当上下文")
        XCTAssertNil(sender.request(1)?.httpBody?.range(of: Data("然后发给张三".utf8)),
                     "第 1 段不该知道后面的事")
    }

    /// 云端识别的原文也要过一遍本地清理（4.3.3），位置与本机引擎一样：**按段做、拼接之前**。
    ///
    /// 4.3.3 之前云端这条路一个字都没清过：本机档默认删掉的「嗯 / 那个 / um」在云端档
    /// 原样进输入框，润色再被保真校验拦下的话（mini 上 39 次里拦了 6 次），用户看到的
    /// 就是满屏语气词的识别原文——他以为润色坏了，其实是润色被丢掉了。
    func testCloudTranscriptGetsTheSameLocalCleanupAsTheLocalEngine() {
        let sender = FakeCloudSender()
        sender.script(1, .success(CloudASRSegmentResult(text: "嗯，那个，我们明天开会。")))
        sender.script(2, .success(CloudASRSegmentResult(text: "um, let's start")))
        let engine = engineWithFakeSender(sender)

        let finished = expectation(description: "交付")
        var delivered: TranscriptionOutcome?
        engine.transcribe(samples: longAudio(), language: nil, previousText: "",
                          onSegment: nil) { outcome in
            delivered = outcome
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
        XCTAssertEqual(delivered?.text,
                       CloudTextJoiner.join(["我们明天开会。", "let's start"]),
                       "口水词该在交付之前就删掉，且清理按段做")
    }

    /// 让主队列上已经排好的块跑完（回调都投在主队列上）
    private func drainMainQueue() {
        let spin = expectation(description: "main queue drained")
        DispatchQueue.main.async { spin.fulfill() }
        wait(for: [spin], timeout: 2)
    }

    /// 取消之后**不回调**（与 LLMClient 同一约定）：用户按了 Esc 就是把自己放出来了，
    /// 不该再在悬浮窗上弹一句错误。这里用空音频走同一条收口，不碰网络。
    func testCancelledDetailedRequestNeverCallsBack() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .openai, apiKey: "sk-test"))
        var called = false
        let handle = engine.transcribeDetailed(samples: []) { _ in called = true }
        handle.cancel()
        // 让主队列把那个 async 块跑完
        let spin = expectation(description: "main queue drained")
        DispatchQueue.main.async { spin.fulfill() }
        wait(for: [spin], timeout: 2)
        XCTAssertFalse(called, "取消之后不该再回调")
    }
}


/// 假发送器：把 CloudASREngine 的发送缝接管过来，按脚本回结果。
/// 不碰网络、不花钱，却能把多段流程真的跑起来——桥接层的取消语义只有这样才验得到。
final class FakeCloudSender: @unchecked Sendable {

    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var scripted: [Int: Result<CloudASRSegmentResult, CloudASRFailure>] = [:]
    /// 没排结果的那几次 = "还在飞"，完成回调先攒着，等测试自己决定什么时候落地
    private var pending: [(Result<CloudASRSegmentResult, CloudASRFailure>) -> Void] = []

    private var waiters: [Int: XCTestExpectation] = [:]

    /// 第 index 次请求（从 1 起）回什么
    func script(_ index: Int, _ result: Result<CloudASRSegmentResult, CloudASRFailure>) {
        lock.lock()
        scripted[index] = result
        lock.unlock()
    }

    /// 等第 index 次请求真的发出去（段与段之间要过一趟引擎队列，不是同步的）
    func expectRequest(_ index: Int, _ test: XCTestCase) -> XCTestExpectation {
        let waiting = test.expectation(description: "第 \(index) 次请求发出")
        lock.lock()
        let already = requests.count >= index
        if !already { waiters[index] = waiting }
        lock.unlock()
        if already { waiting.fulfill() }
        return waiting
    }

    func send(_ request: URLRequest,
              _ provider: CloudTranscriptionProviding,
              _ handle: CloudASRHandle,
              _ completion: @escaping (Result<CloudASRSegmentResult, CloudASRFailure>) -> Void) {
        lock.lock()
        requests.append(request)
        let planned = scripted[requests.count]
        let waiting = waiters.removeValue(forKey: requests.count)
        if planned == nil { pending.append(completion) }
        lock.unlock()
        waiting?.fulfill()
        if let planned = planned { completion(planned) }
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    /// 第 index 次请求（从 1 起）
    func request(_ index: Int) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        guard index >= 1, index <= requests.count else { return nil }
        return requests[index - 1]
    }

    /// 在飞的那几次到此为止（模拟超时/限流最终落地）
    func finishPending(_ result: Result<CloudASRSegmentResult, CloudASRFailure>) {
        lock.lock()
        let waiting = pending
        pending = []
        lock.unlock()
        waiting.forEach { $0(result) }
    }
}
