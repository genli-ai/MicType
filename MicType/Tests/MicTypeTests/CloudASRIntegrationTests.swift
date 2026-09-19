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
        // rawValue 存在 UserDefaults 里，改一个字就等于把所有老用户的设置作废
        XCTAssertEqual(RecognitionEngineChoice.local.rawValue, "local")
        XCTAssertEqual(RecognitionEngineChoice.cloudAlibaba.rawValue, "cloudAlibaba")
        XCTAssertEqual(RecognitionEngineChoice.cloudOpenAI.rawValue, "cloudOpenAI")
        XCTAssertEqual(RecognitionEngineChoice.allCases.count, 3)
    }

    /// 脏值、空值、别的分支写进来的值——一律回落本地。默认档永远是"音频不出机"那一档。
    func testUnknownEngineFallsBackToLocal() {
        XCTAssertEqual(RecognitionEngineChoice.parse(""), .local)
        XCTAssertEqual(RecognitionEngineChoice.parse("cloud"), .local)
        XCTAssertEqual(RecognitionEngineChoice.parse("CLOUDALIBABA"), .local)
        XCTAssertEqual(RecognitionEngineChoice.parse(" cloudOpenAI "), .cloudOpenAI, "两头的空白要容忍")
    }

    func testCloudProviderMapping() {
        XCTAssertNil(RecognitionEngineChoice.local.cloudProvider)
        XCTAssertFalse(RecognitionEngineChoice.local.isCloud)
        XCTAssertEqual(RecognitionEngineChoice.cloudAlibaba.cloudProvider, .alibaba)
        XCTAssertEqual(RecognitionEngineChoice.cloudOpenAI.cloudProvider, .openai)
        XCTAssertTrue(RecognitionEngineChoice.cloudOpenAI.isCloud)
    }

    // MARK: - 语言提示

    func testExplicitLanguageBecomesItsCode() {
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "zh", vocabulary: []), ["zh"])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "ar", vocabulary: []), ["ar"])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "YUE", vocabulary: []), ["yue"])
    }

    /// 云端不认识的语言（荷兰语、波斯语…本机模型有、云端列表里没有）→ 一个提示都不送，
    /// 让云端自己判。送一个它不认识的码只会被判 InvalidParameter，整段识别失败。
    func testLanguagesTheCloudDoesNotKnowSendNoHint() {
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "nl", vocabulary: []), [])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "fa", vocabulary: []), [])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "mk", vocabulary: []), [])
    }

    /// Auto 默认什么都不送；只有用户**自己的词表**证明这是一场中英夹杂的口述时才送两个提示
    func testAutoOnlyHintsWhenVocabularyIsMixed() {
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "", vocabulary: []), [])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "auto", vocabulary: []), [])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "", vocabulary: ["捷文", "云术法"]), [],
                       "只有中文词条不等于只说中文，不替用户锁语言")
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "", vocabulary: ["Power BI"]), [])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "",
                                                     vocabulary: ["捷文", "Power BI"]),
                       ["zh", "en"])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "auto",
                                                     vocabulary: ["MicType 捷文"]),
                       ["zh", "en"], "同一条词条里中西夹杂也算混合")
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

    // MARK: - 区域

    /// 一个区域设置管润色和识别两件事，但两边的主机表不一样：识别端只有新加坡 / 美国 / 北京。
    /// 对不上的区域必须返回 nil，**绝不悄悄换一个能连上的区域**（Key 是分区域的）。
    func testRegionMapping() {
        XCTAssertEqual(CloudASRSettings.alibabaRegion(for: .international), .international)
        XCTAssertEqual(CloudASRSettings.alibabaRegion(for: .singapore), .international)
        XCTAssertEqual(CloudASRSettings.alibabaRegion(for: .us), .us)
        XCTAssertEqual(CloudASRSettings.alibabaRegion(for: .beijing), .china)
        XCTAssertNil(CloudASRSettings.alibabaRegion(for: .tokyo))
        XCTAssertNil(CloudASRSettings.alibabaRegion(for: .hongkong))
    }

    func testRegionSupportOnlyConstrainsAlibaba() {
        XCTAssertTrue(CloudASRSettings.regionSupported(choice: .local, region: .tokyo))
        XCTAssertTrue(CloudASRSettings.regionSupported(choice: .cloudOpenAI, region: .tokyo),
                      "OpenAI 那一档没有区域概念")
        XCTAssertFalse(CloudASRSettings.regionSupported(choice: .cloudAlibaba, region: .tokyo))
        XCTAssertTrue(CloudASRSettings.regionSupported(choice: .cloudAlibaba, region: .international))
    }

    // MARK: - 组装配置

    func testConfigCarriesVocabularyHintsAndWorkspace() {
        let config = CloudASRSettings.config(provider: .alibaba,
                                             alibabaModel: .qwenAudio30Flash,
                                             region: .international,
                                             workspaceID: "  ws-123  ",
                                             recognitionLanguage: "zh",
                                             vocabulary: ["捷文", "Power BI"],
                                             apiKey: "sk-test")
        XCTAssertEqual(config.provider, .alibaba)
        XCTAssertEqual(config.alibabaModel, .qwenAudio30Flash)
        XCTAssertEqual(config.region, .international)
        XCTAssertEqual(config.workspaceId, "ws-123", "两头的空白要去掉：它会被拼进主机名")
        XCTAssertEqual(config.languageHints, ["zh"])
        XCTAssertEqual(config.vocabulary, ["捷文", "Power BI"], "词表原样交给客户端，权重与过滤在那一层")
        XCTAssertEqual(config.apiKey, "sk-test")
        XCTAssertFalse(config.enableITN, "ITN 一律关：MicType 自己有润色层")
    }

    func testEmptyWorkspaceBecomesNil() {
        let config = CloudASRSettings.config(provider: .alibaba,
                                             alibabaModel: .qwen3Flash,
                                             region: .china,
                                             workspaceID: "   ",
                                             recognitionLanguage: "",
                                             vocabulary: [],
                                             apiKey: "k")
        XCTAssertNil(config.workspaceId, "空 WorkspaceId = 走共享主机")
        // 配置真的落到了客户端上（端点由区域 + WorkspaceId 推出来）
        let url = AlibabaASRClient.endpoint(region: config.region, workspaceId: config.workspaceId)
        XCTAssertEqual(url?.host, "dashscope.aliyuncs.com")
    }

    /// 词表要真的变成热词参数（权重 4）——这是云端档下专有名词准确率的唯一杠杆
    func testVocabularyReachesTheHotwordParameter() {
        let config = CloudASRSettings.config(provider: .alibaba,
                                             alibabaModel: .qwenAudio30Flash,
                                             region: .international,
                                             workspaceID: "",
                                             recognitionLanguage: "",
                                             vocabulary: ["MicType", "捷文"],
                                             apiKey: "k")
        let vocab = AlibabaASRClient.vocabularyParameter(config.vocabulary)
        XCTAssertEqual(vocab["MicType"], 4)
        XCTAssertEqual(vocab["捷文"], 4)
    }

    // MARK: - 开录之前：这一档能不能用

    func testReadinessMatrix() {
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .local, localModelAvailable: true,
                                                           cloudRegionSupported: true, hasCloudKey: false),
                       .ready, "本地档不看云端 Key")
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .local, localModelAvailable: false,
                                                           cloudRegionSupported: true, hasCloudKey: true),
                       .localModelMissing)
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .cloudAlibaba, localModelAvailable: false,
                                                           cloudRegionSupported: true, hasCloudKey: true),
                       .ready, "云端档不需要本机模型")
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .cloudAlibaba, localModelAvailable: true,
                                                           cloudRegionSupported: true, hasCloudKey: false),
                       .cloudKeyMissing(.alibaba))
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .cloudAlibaba, localModelAvailable: true,
                                                           cloudRegionSupported: false, hasCloudKey: true),
                       .cloudRegionUnsupported, "区域配不出接入点比缺 Key 更先报")
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .cloudOpenAI, localModelAvailable: true,
                                                           cloudRegionSupported: true, hasCloudKey: false),
                       .cloudKeyMissing(.openai))
    }

    /// 每一种"开不了工"都必须有一句话和一个落点；云端那两档还要有可点的胶囊
    func testReadinessMessagesAndChips() {
        XCTAssertTrue(RecognitionEngineReadiness.ready.isReady)
        XCTAssertTrue(RecognitionEngineReadiness.ready.message.isEmpty)
        XCTAssertNil(RecognitionEngineReadiness.ready.settingsChipLabel)
        XCTAssertNil(RecognitionEngineReadiness.localModelMissing.settingsChipLabel,
                     "本地档走的是引导下载页，不用胶囊")
        for state: RecognitionEngineReadiness in [.localModelMissing, .cloudKeyMissing(.alibaba),
                                                  .cloudKeyMissing(.openai), .cloudRegionUnsupported] {
            XCTAssertFalse(state.isReady)
            XCTAssertFalse(state.message.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        XCTAssertNotNil(RecognitionEngineReadiness.cloudKeyMissing(.alibaba).settingsChipLabel)
        XCTAssertNotNil(RecognitionEngineReadiness.cloudRegionUnsupported.settingsChipLabel)
    }

    // MARK: - 云端炸了之后

    /// 本地模型在 = 永远先本地重跑一遍：用户说过的话一个字都不该因为云端抽风而丢
    func testFallbackPrefersTheLocalEngine() {
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "", localModelAvailable: true),
                       .retryLocally)
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "前两段的字", localModelAvailable: true),
                       .retryLocally)
    }

    /// 没有本地退路：有字就把已经转出来的段落交付出去，什么都没有才报错
    func testFallbackWithoutLocalModel() {
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "前两段的字", localModelAvailable: false),
                       .deliverPartial)
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "", localModelAvailable: false),
                       .reportFailure)
    }

    func testFallbackNoteNamesTheReasonAndStaysShort() {
        let note = CloudFallbackDecision.fallbackNote(reason: "429 Throttling")
        XCTAssertTrue(note.contains("429 Throttling"), "原因要原样摆出来：用户据此判断要不要重试")
        let long = CloudFallbackDecision.fallbackNote(reason: String(repeating: "x", count: 400))
        XCTAssertLessThan(long.count, 200, "悬浮窗一行放不下 400 个字符的云端原话")
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
            AlibabaASRClient.failure(status: 401, code: "InvalidApiKey", message: nil)))
        XCTAssertFalse(CloudASRProbe.isAcceptable(
            AlibabaASRClient.failure(status: 403, code: "AccessDenied", message: nil)))
        XCTAssertFalse(CloudASRProbe.isAcceptable(CloudASRFailure("network down")),
                       "还没上网的失败（status 0）不能算通过")
    }

    /// 解析层要真的给出这个码，否则探针会把"通了但没字"当成失败
    func testParsersTagEmptyTranscriptsWithTheProbeCode() {
        guard case .failure(let alibaba) = AlibabaASRClient.parse(Data(#"{"output":{}}"#.utf8),
                                                                 model: .qwenAudio30Flash) else {
            return XCTFail("没有文本字段不能算成功")
        }
        XCTAssertEqual(alibaba.code, CloudASRFailure.emptyTranscriptCode)
        XCTAssertEqual(alibaba.status, 200)

        guard case .failure(let openai) = OpenAITranscribeClient.parse(Data(#"{"foo":1}"#.utf8)) else {
            return XCTFail("没有 text 字段不能算成功")
        }
        XCTAssertEqual(openai.code, CloudASRFailure.emptyTranscriptCode)
    }

    func testProbeSuccessTextReportsRoundTrip() {
        let text = CloudASRProbe.successText(CloudASRProbe.Outcome(milliseconds: 842, text: "",
                                                                   billedSeconds: 1))
        XCTAssertTrue(text.contains("842"))
        XCTAssertTrue(text.contains("✓"))
    }

    // MARK: - SpeechEngine 桥接（不上网也测得到的那几条）

    /// 空音频：不上网、不报错，交付一段空文本（下游那句"没有听到内容"负责说话）
    func testSegmentedBridgeDeliversEmptyOutcomeForEmptyAudio() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .alibaba, apiKey: "sk-test"))
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

        // 没有 Key 的这一轮，集成层会按"没有本地退路就报错"走
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "", localModelAvailable: false),
                       .reportFailure)
    }

    // MARK: - 语言提示送不送得到（界面据此换文案）

    /// 云端的语言表比「识别语言」那张选单短：选了它不认识的码，提示根本送不出去。
    /// 设置页那句"选了具体语言就送过去"必须按这个判据分支，否则对小语种就是假话。
    func testCloudHintDeliveredMatchesWhatIsActuallySent() {
        XCTAssertTrue(CloudASRSettings.cloudHintDelivered(recognitionLanguage: "zh"))
        XCTAssertTrue(CloudASRSettings.cloudHintDelivered(recognitionLanguage: "ar"))
        XCTAssertTrue(CloudASRSettings.cloudHintDelivered(recognitionLanguage: " EN "))
        // 「自动」与空值：本来就不送提示，界面说的就是"交给云端判"，不算不一致
        XCTAssertTrue(CloudASRSettings.cloudHintDelivered(recognitionLanguage: ""))
        XCTAssertTrue(CloudASRSettings.cloudHintDelivered(recognitionLanguage: "auto"))
        // 选单里有、云端不认的那几种（荷兰语 / 波斯语 / 希腊语 / 罗马尼亚语 / 匈牙利语 / 马其顿语）
        for code in ["nl", "fa", "el", "ro", "hu", "mk"] {
            XCTAssertFalse(CloudASRSettings.cloudHintDelivered(recognitionLanguage: code),
                           "\(code) 不在云端语言表里，界面必须换一句话")
            XCTAssertTrue(CloudASRSettings.languageHints(recognitionLanguage: code, vocabulary: []).isEmpty,
                          "判据必须与真正送出去的 hints 同源")
        }
    }

    // MARK: - 桥接层的取消语义（假发送器，不上网）

    /// 200 秒等能量音频：阿里云档切成 2 段（120 + 80），够跑完整条多段流程
    private func longAudio(seconds: Double = 200) -> [Float] {
        [Float](repeating: 0.05, count: Int(seconds * Double(WAVEncoder.defaultSampleRate)))
    }

    private func engineWithFakeSender(_ sender: FakeCloudSender,
                                      provider: CloudASRProvider = .alibaba) -> CloudASREngine {
        let engine = CloudASREngine(config: CloudASRConfig(provider: provider, apiKey: "sk-test"))
        engine.sendSegment = { request, client, handle, completion in
            sender.send(request, client, handle, completion)
        }
        return engine
    }

    /// Esc 必须**立刻**收口，而不是等在飞的那一段传完、转完（阿里云单段 120s 起步，
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
            XCTAssertEqual(total, 2, "200 秒在阿里云档下应该是 2 段")
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

    /// 让主队列上已经排好的块跑完（回调都投在主队列上）
    private func drainMainQueue() {
        let spin = expectation(description: "main queue drained")
        DispatchQueue.main.async { spin.fulfill() }
        wait(for: [spin], timeout: 2)
    }

    /// 取消之后**不回调**（与 LLMClient 同一约定）：用户按了 Esc 就是把自己放出来了，
    /// 不该再在悬浮窗上弹一句错误。这里用空音频走同一条收口，不碰网络。
    func testCancelledDetailedRequestNeverCallsBack() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .alibaba, apiKey: "sk-test"))
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
