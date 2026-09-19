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
