import XCTest
@testable import MicType

/// 5.5.0 加回 DeepSeek（用户 2026-11-22 拍板）：一个决定、一把 Key，识别 / 润色 / 指令 / 联网搜索全走那一家。
/// 全部是纯函数，不联网、不碰钥匙串（迁移那几条用一次性的 UserDefaults suite + 记账闭包）。
/// 真 Key 那一组在 DeepSeekLiveTests。
final class DeepSeekProviderTests: XCTestCase {

    private var savedLanguage: AppLanguage = .zh

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
    }

    override func tearDown() {
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: - 服务商本身

    func testDeepSeekUsesItsOwnKeychainAccountAndFixedRoot() {
        // 沿用 4.x 的账户名（v4.3.6 Settings.swift 查过）：老用户钥匙串里那一条照用
        XCTAssertEqual(LLMProvider.deepseek.keychainAccount, "deepseek_api_key")
        XCTAssertEqual(LLMProvider.openai.keychainAccount, "openai_api_key")
        XCTAssertNotEqual(CloudASRProvider.deepseek.keychainAccount, CloudASRProvider.openai.keychainAccount)
        XCTAssertEqual(CloudASRProvider.deepseek.keychainAccount, LLMProvider.deepseek.keychainAccount)
        XCTAssertEqual(LLMProvider.deepseek.defaultBaseURL, "https://api.deepseek.com")
        XCTAssertEqual(Settings.shared.baseURL(for: .deepseek), "https://api.deepseek.com")
    }

    func testRecognitionFollowsTheProvider() {
        XCTAssertEqual(RecognitionEngineChoice.forProvider(.openai), .cloudOpenAI)
        XCTAssertEqual(RecognitionEngineChoice.forProvider(.deepseek), .cloudDeepSeek)
        XCTAssertEqual(RecognitionEngineChoice.cloudDeepSeek.cloudProvider, .deepseek)
        XCTAssertEqual(RecognitionEngineChoice.parse("cloudDeepSeek"), .cloudDeepSeek)
        XCTAssertEqual(RecognitionEngineChoice.parse("cloudAlibaba"), .cloudOpenAI)
        XCTAssertEqual(CloudASRProvider.deepseek.llmProvider, .deepseek)
    }

    func testModelsAreDeepSeekFlashForBothPurposes() {
        XCTAssertEqual(LLMCatalog.polishDefault(for: .deepseek), "deepseek-flash")
        XCTAssertEqual(LLMCatalog.commandDefault(for: .deepseek), "deepseek-flash")
        // OpenAI 那一档一个字都不变
        XCTAssertEqual(LLMCatalog.polishDefault(for: .openai), "gpt-5.6-terra")
        XCTAssertEqual(LLMCatalog.commandDefault(for: .openai), "gpt-5.6-luna")
        XCTAssertFalse(LLMCatalog.rejectsCustomTemperature("deepseek-flash"))
    }

    func testAdoptionOnlyWithAKey() {
        XCTAssertTrue(AISetup.adoptsProvider(current: .openai, next: .deepseek, hasKey: true))
        XCTAssertFalse(AISetup.adoptsProvider(current: .openai, next: .deepseek, hasKey: false))
        XCTAssertFalse(AISetup.adoptsProvider(current: .deepseek, next: .deepseek, hasKey: true))
        XCTAssertTrue(AISetup.adoptsProvider(current: .deepseek, next: .openai, hasKey: true))
    }

    func testKeyCheckProbesTheRecognitionEndpointOfThatProvider() {
        XCTAssertEqual(KeyVerifier.Probe.keyCheck(for: .openai), .cloudASR(.openai))
        XCTAssertEqual(KeyVerifier.Probe.keyCheck(for: .deepseek), .cloudASR(.deepseek))
    }

    // MARK: - 识别：/v1/tools/asr

    func testTranscriptionRequestIsOneFileFieldAndNothingElse() throws {
        let wav = WAVEncoder.encode(samples: [Float](repeating: 0.1, count: 16_000))
        let client = DeepSeekTranscribeClient(apiKey: "sk-test")
        let request = try client.makeRequest(audio: .wav(wav), seconds: 1, context: "上文：这句不该发出去").get()
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/tools/asr")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?
            .hasPrefix("multipart/form-data; boundary=") ?? false)
        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        // 只有一个 file 字段：没有 model、语言、关键词、上下文
        XCTAssertEqual(text.components(separatedBy: "Content-Disposition: form-data;").count - 1, 1)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
        for absent in ["name=\"model\"", "languages", "keywords", "prompt", "上文"] {
            XCTAssertFalse(text.contains(absent), absent)
        }
        // 16 位 PCM WAV 原样在体里
        XCTAssertNotNil(body.range(of: wav))
        XCTAssertEqual(request.timeoutInterval, 12)
    }

    func testDeepSeekUploadIsAlwaysWAV() {
        let samples = [Float](repeating: 0.05, count: 16_000)
        let audio = CloudASRConfig.uploadAudio(samples: samples, provider: .deepseek)
        XCTAssertEqual(audio.contentType, "audio/wav")
        XCTAssertEqual(audio.data.prefix(4), Data("RIFF".utf8))
    }

    func testTimeoutFormula() {
        XCTAssertEqual(DeepSeekTranscribeClient.timeout(forSeconds: 1), 12)
        XCTAssertEqual(DeepSeekTranscribeClient.timeout(forSeconds: 16), 12)
        XCTAssertEqual(DeepSeekTranscribeClient.timeout(forSeconds: 60), 23)
        XCTAssertEqual(DeepSeekTranscribeClient.timeout(forSeconds: 110), 35.5)
        XCTAssertEqual(DeepSeekTranscribeClient.timeout(forSeconds: 200), 40)
    }

    func testOversizedSegmentIsRejectedLocally() {
        let client = DeepSeekTranscribeClient(apiKey: "sk-test")
        let big = Data(count: 8 * 1024 * 1024 + 1)
        guard case .failure(let failure) = client.makeRequest(audio: .wav(big), seconds: 100, context: nil) else {
            return XCTFail("8 MiB 以上不该发出去")
        }
        XCTAssertEqual(failure.status, 0)
        guard case .failure(let missing) = DeepSeekTranscribeClient(apiKey: " ")
            .makeRequest(audio: .wav(Data(count: 44)), seconds: 1, context: nil) else {
            return XCTFail("没 Key 不该发出去")
        }
        XCTAssertEqual(missing.error.action, .openSettings)
    }

    func testParseReply() throws {
        let ok = Data(#"{"request_id":"r1","text":"  明天下午三点开会。 ","duration_ms":2500}"#.utf8)
        let result = try DeepSeekTranscribeClient.parse(ok).get()
        XCTAssertEqual(result.text, "明天下午三点开会。")
        XCTAssertEqual(result.billedSeconds ?? 0, 2.5, accuracy: 0.0001)
        XCTAssertNil(result.detectedLanguage)

        guard case .failure(let empty) = DeepSeekTranscribeClient.parse(Data(#"{"request_id":"r2"}"#.utf8)) else {
            return XCTFail()
        }
        // 与 OpenAI 那条路同一个码：粘贴即验证据此判"Key 是好的"
        XCTAssertEqual(empty.code, CloudASRFailure.emptyTranscriptCode)
        XCTAssertTrue(CloudASRProbe.isAcceptable(empty))

        guard case .failure = DeepSeekTranscribeClient.parse(Data("not json".utf8)) else { return XCTFail() }
    }

    func testErrorMapping() {
        L10n.shared.language = .zh
        let key = DeepSeekTranscribeClient.failure(status: 401, code: "authentication_error", message: nil)
        XCTAssertEqual(key.error.action, .openSettings)
        XCTAssertFalse(key.retryable)
        let broke = DeepSeekTranscribeClient.failure(status: 402, code: nil, message: "Insufficient Balance")
        XCTAssertEqual(broke.error.action, .addCredit)
        XCTAssertEqual(broke.message, UserMessage.outOfCredit(402))
        let busy = DeepSeekTranscribeClient.failure(status: 429, code: nil, message: nil)
        XCTAssertTrue(busy.retryable)
        XCTAssertEqual(busy.error.action, .dismiss)
        let tooLong = DeepSeekTranscribeClient.failure(status: 400, code: nil,
                                                       message: "audio duration 132460 ms exceeds 120 s")
        XCTAssertFalse(tooLong.retryable)
        XCTAssertTrue(DeepSeekTranscribeClient.failure(status: 503, code: nil, message: nil).retryable)
    }

    func testDeepSeekConfigCarriesNoHintsOrVocabulary() {
        let config = CloudASRSettings.config(provider: .deepseek, vocabulary: ["捷文"], apiKey: "sk-x")
        XCTAssertEqual(config.provider, .deepseek)
        XCTAssertTrue(config.languageHints.isEmpty)
        XCTAssertTrue(config.vocabulary.isEmpty)
        XCTAssertTrue(config.makeClient() is DeepSeekTranscribeClient)
        let openai = CloudASRSettings.config(provider: .openai, vocabulary: ["捷文"], apiKey: "sk-x")
        XCTAssertEqual(openai.vocabulary, ["捷文"])
        XCTAssertTrue(openai.makeClient() is OpenAITranscribeClient)
    }

    func testNoRealtimeSessionForDeepSeek() {
        XCTAssertFalse(CloudASRProvider.deepseek.supportsRealtime)
        XCTAssertTrue(CloudASRProvider.openai.supportsRealtime)
        let config = CloudASRSettings.config(provider: .deepseek, vocabulary: [], apiKey: "sk-x")
        XCTAssertNil(CloudStreamingSession.make(config: config, fallback: CloudASREngine(config: config),
                                                officialOpenAI: true))
    }

    // MARK: - 分段：110 秒

    func testSegmentLimitsStayUnderTheEndpointCap() {
        let limits = CloudASRProvider.deepseek.segmentLimits
        XCTAssertEqual(limits, .deepseek)
        XCTAssertEqual(limits.hardMaxSeconds, 110)
        XCTAssertLessThan(limits.hardMaxSeconds, 120)
        XCTAssertLessThanOrEqual(limits.targetSeconds + limits.silenceSearchSeconds, limits.hardMaxSeconds)
        // 110 秒的 16 kHz PCM16 WAV 远在 8 MiB 之内
        XCTAssertLessThan(Int(limits.hardMaxSeconds) * 16_000 * 2 + 44, DeepSeekTranscribeClient.maxFileBytes)
    }

    func testLongTakeIsCutIntoSegmentsUnder110Seconds() {
        let rate = WAVEncoder.defaultSampleRate
        // 250 秒，每 7 秒一段 0.4 秒静音（模拟句间停顿）
        var samples = [Float](repeating: 0.2, count: 250 * rate)
        var t = 7 * rate
        while t < samples.count {
            for i in t ..< min(t + rate * 2 / 5, samples.count) { samples[i] = 0 }
            t += 7 * rate
        }
        let segments = CloudSegmentPlanner.plan(samples: samples, limits: .deepseek)
        XCTAssertGreaterThanOrEqual(segments.count, 3)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.count }, samples.count, "每个采样恰好一次")
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.seconds, 110.0001, "\(segment.seconds)")
        }
        // 不超过 110 秒的一段不切
        XCTAssertEqual(CloudSegmentPlanner.plan(samples: [Float](repeating: 0.2, count: 109 * rate),
                                                limits: .deepseek).count, 1)
    }

    // MARK: - 对话请求体

    func testChatBodyTurnsThinkingOffAndNeverAsksForFastTier() {
        let messages = [["role": "system", "content": "s"], ["role": "user", "content": "u"]]
        for purpose in [LLMClient.Purpose.polish, .command] {
            let body = LLMClient.chatBody(model: "deepseek-flash", messages: messages, temperature: 0.3,
                                          purpose: purpose, provider: .deepseek, maxOutputTokens: 2048,
                                          fastTier: LLMClient.asksForFastTier(
                                              provider: .deepseek, baseURL: "https://api.deepseek.com",
                                              model: "deepseek-flash", refusedModels: []),
                                          searchStyle: LLMCatalog.searchStyle(provider: .deepseek,
                                                                              baseURL: "https://api.deepseek.com"))
            XCTAssertEqual(body["thinking"] as? [String: String], ["type": "disabled"])
            XCTAssertNil(body["service_tier"])
            XCTAssertNil(body["tool_choice"], "DeepSeek 的搜索工具不能强制（400）")
            XCTAssertEqual(body["temperature"] as? Double, 0.3)
            XCTAssertEqual(body["max_tokens"] as? Int, 2048)
            let tools = body["tools"] as? [[String: String]]
            if purpose == .command {
                XCTAssertEqual(tools ?? [], [["type": "deepseek_web_search"]])
            } else {
                XCTAssertNil(tools, "润色永不联网")
            }
        }
        // OpenAI 档走 chat 时不带 thinking（那是 DeepSeek 的字段）
        let openai = LLMClient.chatBody(model: "x", messages: messages, temperature: nil,
                                        purpose: .polish, provider: .openai)
        XCTAssertNil(openai["thinking"])
    }

    func testEmptyMessagesGetThePlaceholderOnlyForDeepSeek() {
        let messages = [["role": "system", "content": "s"], ["role": "user", "content": "  \n"]]
        let body = LLMClient.chatBody(model: "deepseek-flash", messages: messages, temperature: nil,
                                      purpose: .command, provider: .deepseek)
        let sent = body["messages"] as? [[String: String]]
        XCTAssertEqual(sent?.last?["content"], "（无待处理文字）")
        XCTAssertEqual(sent?.first?["content"], "s")
        let openai = LLMClient.chatBody(model: "x", messages: messages, temperature: nil,
                                        purpose: .command, provider: .openai)
        XCTAssertEqual((openai["messages"] as? [[String: String]])?.last?["content"], "  \n")
    }

    func testSearchStyleAndPrice() {
        XCTAssertEqual(LLMCatalog.searchStyle(provider: .deepseek, baseURL: "https://api.deepseek.com"),
                       .deepseekTool)
        L10n.shared.language = .zh
        XCTAssertEqual(LLMCatalog.webSearchPriceNote(style: .deepseekTool),
                       "搜索结果按 token 计费；模型没搜时 App 直接搜一次，每次约 ¥0.005。")
        L10n.shared.language = .en
        XCTAssertEqual(LLMCatalog.webSearchPriceNote(style: .deepseekTool),
                       "Search results bill as tokens; when the model skips searching, the app searches once at about ¥0.005.")
    }

    func testChatPayloadReadsToolSearchCount() {
        let json: [String: Any] = [
            "choices": [["message": ["content": "北京今天晴"], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "server_tool_use": ["tool_search": 2]],
        ]
        let payload = LLMClient.parseChatPayload(json)
        XCTAssertEqual(payload.text, "北京今天晴")
        XCTAssertEqual(payload.searchCount, 2)
        XCTAssertNil(LLMClient.parseChatPayload(["choices": [["message": ["content": "x"]]]]).searchCount)
    }

    // MARK: - 联网搜索：搜了没有、要不要兜底

    func testDecision() {
        XCTAssertEqual(DeepSeekWebSearch.decide(searchCount: 1, instruction: "查一下今天北京天气", hasTarget: false),
                       .accept)
        XCTAssertEqual(DeepSeekWebSearch.decide(searchCount: 0, instruction: "查一下今天北京天气", hasTarget: false),
                       .directSearch)
        XCTAssertEqual(DeepSeekWebSearch.decide(searchCount: nil, instruction: "搜一下 iPhone 18 的价格",
                                                hasTarget: false), .directSearch)
        // 没明说要查：不搜是对的，不兜底（否则每条指令都多付一次搜索钱）
        XCTAssertEqual(DeepSeekWebSearch.decide(searchCount: 0, instruction: "把这段翻成英文", hasTarget: true),
                       .accept)
        XCTAssertEqual(DeepSeekWebSearch.decide(searchCount: nil, instruction: "写一封请假邮件", hasTarget: false),
                       .accept)
    }

    func testWantsSearch() {
        XCTAssertTrue(DeepSeekWebSearch.wantsSearch("查北京天气", hasTarget: false))
        XCTAssertTrue(DeepSeekWebSearch.wantsSearch("帮我联网搜一下汇率", hasTarget: true))
        XCTAssertTrue(DeepSeekWebSearch.wantsSearch("look up the exchange rate", hasTarget: false))
        XCTAssertTrue(DeepSeekWebSearch.wantsSearch("Search today's news", hasTarget: false))
        // 名词与"检查"不算
        XCTAssertFalse(DeepSeekWebSearch.wantsSearch("把这段关于互联网的话改正式一点", hasTarget: true))
        XCTAssertFalse(DeepSeekWebSearch.wantsSearch("写一段介绍搜索引擎的话", hasTarget: false))
        XCTAssertFalse(DeepSeekWebSearch.wantsSearch("查一下这段有没有错别字", hasTarget: true))
        XCTAssertFalse(DeepSeekWebSearch.wantsSearch("检查一下语法", hasTarget: false))
        XCTAssertFalse(DeepSeekWebSearch.wantsSearch("write about research", hasTarget: false))
    }

    func testSearchCountParsing() {
        XCTAssertEqual(DeepSeekWebSearch.searchCount(in: ["usage": ["server_tool_use": ["tool_search": 3]]]), 3)
        XCTAssertNil(DeepSeekWebSearch.searchCount(in: ["usage": ["prompt_tokens": 3]]))
        XCTAssertNil(DeepSeekWebSearch.searchCount(in: [:]))
    }

    func testDirectSearchRequestAndBody() throws {
        XCTAssertEqual(DeepSeekWebSearch.searchQuery(from: "请帮我查一下北京明天的天气"), "北京明天的天气")
        XCTAssertEqual(DeepSeekWebSearch.searchQuery(from: "搜索"), "搜索")
        let body = DeepSeekWebSearch.directSearchBody(query: "北京天气", question: "查一下北京天气")
        XCTAssertEqual(body["query"] as? String, "北京天气")
        XCTAssertEqual(body["ori_question"] as? String, "查一下北京天气")
        XCTAssertEqual(body["count"] as? Int, 8)
        let long = String(repeating: "长", count: 300)
        XCTAssertEqual((DeepSeekWebSearch.directSearchBody(query: long, question: long)["query"] as? String)?.count,
                       128)
        let request = try XCTUnwrap(LLMClient.directSearchRequest(provider: .deepseek, apiKey: "sk-x",
                                                                  query: "a", question: "b"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/tools/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-x")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertNil(LLMClient.directSearchRequest(provider: .deepseek, apiKey: "", query: "a", question: "b"))
    }

    func testParseSearchResultsAndFallbackPrompt() throws {
        let data = Data(#"""
        {"results":[{"title":"北京天气","url":"https://weather.example/bj","site_name":"天气网",
          "date":"2026-11-21T16:00:00+00:00","summary":"晴，3 到 12 度"},
          {"title":"","snippet":""},"junk"]}
        """#.utf8)
        let results = try XCTUnwrap(DeepSeekWebSearch.parseSearchResults(data))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].siteName, "天气网")
        XCTAssertNil(DeepSeekWebSearch.parseSearchResults(Data("{}".utf8)))
        XCTAssertEqual(DeepSeekWebSearch.parseSearchResults(Data(#"{"results":[]}"#.utf8)), [])

        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let now = ISO8601DateFormatter().date(from: "2026-11-22T02:00:00Z")!
        let block = DeepSeekWebSearch.resultsBlock(results, timeZone: tz)
        XCTAssertTrue(block.contains("[1] 北京天气"))
        XCTAssertTrue(block.contains("发布于 2026 年 11 月 22 日"))
        XCTAssertFalse(block.contains("https://"), "结果块里不许有网址")
        let messages = DeepSeekWebSearch.fallbackMessages(instruction: "查北京天气", input: "",
                                                          results: results, now: now, timeZone: tz)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0]["content"]?.contains("今天是 2026 年 11 月 22 日，星期日") ?? false)
        XCTAssertEqual(messages[1]["content"], "查北京天气")
        XCTAssertEqual(DeepSeekWebSearch.citations(from: results).map(\.url), ["https://weather.example/bj"])
    }

    func testCommandDateSuffix() {
        let tz = TimeZone(identifier: "Asia/Dubai")!
        let now = ISO8601DateFormatter().date(from: "2026-11-22T06:00:00Z")!
        XCTAssertEqual(DeepSeekWebSearch.commandDateSuffix(now: now, timeZone: tz),
                       "\n今天是 2026 年 11 月 22 日，星期日。")
    }

    // MARK: - 错误话术

    func testHTTPErrorsForDeepSeek() {
        L10n.shared.language = .zh
        let key = LLMCatalog.describeHTTPError(status: 401, provider: .deepseek, code: nil, message: nil)
        XCTAssertEqual(key.action, .openSettings)
        let broke = LLMCatalog.describeHTTPError(status: 402, provider: .deepseek, code: nil,
                                                 message: "Insufficient Balance")
        XCTAssertEqual(broke.action, .addCredit)
        XCTAssertEqual(broke.actionURL, "https://platform.deepseek.com/top_up")
        let limited = LLMCatalog.describeHTTPError(status: 429, provider: .deepseek, code: nil,
                                                   message: "Rate limit reached")
        XCTAssertEqual(limited.action, .dismiss)
        XCTAssertEqual(limited.text, UserMessage.rateLimited(429))
        // OpenAI 那一档的充值页不变
        let openaiBroke = LLMCatalog.describeHTTPError(status: 429, provider: .openai,
                                                       code: "insufficient_quota", message: nil)
        XCTAssertEqual(openaiBroke.actionURL, "https://platform.openai.com/settings/organization/billing")
        XCTAssertEqual(LLMCatalog.billingURL(for: .deepseek), "https://platform.deepseek.com/top_up")
    }

    func testKeyMissingNamesTheProvider() {
        L10n.shared.language = .zh
        XCTAssertEqual(UserMessage.keyMissing(for: .deepseek), "还没填 DeepSeek Key")
        L10n.shared.language = .en
        XCTAssertEqual(UserMessage.keyMissing(for: .deepseek), "No DeepSeek key yet.")
        XCTAssertEqual(RecognitionEngineReadiness.cloudKeyMissing(.deepseek).message, "No DeepSeek key yet.")
    }

    // MARK: - 申请 Key 的三步

    func testConsoleStepsForDeepSeek() {
        for language in AppLanguage.allCases {
            L10n.shared.language = language
            let steps = LLMCatalog.consoleSteps(for: .deepseek)
            XCTAssertEqual(steps.count, 3)
            for step in steps {
                XCTAssertFalse(step.text.isEmpty)
                for link in step.links {
                    XCTAssertTrue(link.url.hasPrefix("https://platform.deepseek.com/"), link.url)
                }
            }
            XCTAssertEqual(steps.last?.links.first?.url, "https://platform.deepseek.com/api_keys")
        }
        XCTAssertEqual(LLMCatalog.apiKeyConsoleURL(for: .deepseek), "https://platform.deepseek.com/api_keys")
    }

    func testProviderCardLines() {
        L10n.shared.language = .zh
        let openai = LLMCatalog.providerCardLine(provider: .openai)
        let deepseek = LLMCatalog.providerCardLine(provider: .deepseek)
        XCTAssertTrue(openai.contains("$"), openai)
        XCTAssertTrue(deepseek.contains("¥"), deepseek)
        XCTAssertEqual(openai, "约 $1.7/小时 · 美元计费")
        // 数字由常量算：识别 ¥0.78 + 润色 ¥1.5 = ¥2.28 → 一位小数
        XCTAssertEqual(deepseek, "约 ¥2.3/小时 · 人民币计费")
        for line in [openai, deepseek] {
            XCTAssertFalse(line.contains("国内") || line.contains("国际"), line)
            XCTAssertFalse(line.contains("支付宝") || line.contains("信用卡"), line)
        }
        L10n.shared.language = .en
        for provider in LLMProvider.allCases {
            XCTAssertFalse(CJKSourceScanner.containsFlagged(LLMCatalog.providerCardLine(provider: provider)))
        }
    }

    // MARK: - 迁移

    func testMigrationRule() {
        XCTAssertNil(DeepSeekProviderMigration.resolve(stored: "deepseek", hasDeepSeekKey: true))
        XCTAssertEqual(DeepSeekProviderMigration.resolve(stored: "deepseek", hasDeepSeekKey: false), .openai)
        XCTAssertNil(DeepSeekProviderMigration.resolve(stored: "openai", hasDeepSeekKey: false))
        XCTAssertNil(DeepSeekProviderMigration.resolve(stored: "qwen", hasDeepSeekKey: false))
        XCTAssertNil(DeepSeekProviderMigration.resolve(stored: "", hasDeepSeekKey: true))
    }

    func testMigrationRunsOnceAndOnlyAsksTheDeepSeekAccount() {
        let suite = "mictype.tests.deepseek-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("deepseek", forKey: SettingsKeys.llmProvider)
        var asked: [String] = []
        XCTAssertEqual(DeepSeekProviderMigration.run(defaults: defaults) { asked.append($0); return false },
                       .openai)
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.llmProvider), "openai")
        XCTAssertEqual(asked, ["deepseek_api_key"])
        // 只跑一次
        defaults.set("deepseek", forKey: SettingsKeys.llmProvider)
        XCTAssertNil(DeepSeekProviderMigration.run(defaults: defaults) { _ in false })
        XCTAssertEqual(defaults.string(forKey: SettingsKeys.llmProvider), "deepseek")

        let suite2 = "mictype.tests.deepseek-migration.\(UUID().uuidString)"
        let kept = UserDefaults(suiteName: suite2)!
        defer { kept.removePersistentDomain(forName: suite2) }
        kept.set("deepseek", forKey: SettingsKeys.llmProvider)
        XCTAssertEqual(DeepSeekProviderMigration.run(defaults: kept) { _ in true }, .deepseek)
        XCTAssertEqual(kept.string(forKey: SettingsKeys.llmProvider), "deepseek")
    }

    func testImportAcceptsDeepSeek() throws {
        let saved = Settings.shared.llmProvider
        defer { Settings.shared.llmProvider = saved }
        Settings.shared.llmProvider = .openai
        let document: [String: Any] = [
            "schemaVersion": 1,
            "settings": [SettingsBackup.Key.llmProvider: "deepseek"],
        ]
        let summary = try SettingsBackup.apply(document: document)
        XCTAssertEqual(Settings.shared.llmProvider, .deepseek)
        XCTAssertTrue(summary.updatedKeys.contains(SettingsBackup.Key.llmProvider))
        XCTAssertTrue(summary.notableChanges.contains("llmProvider = deepseek"), "\(summary.notableChanges)")
        XCTAssertEqual(Settings.shared.recognitionEngine, .cloudDeepSeek)
    }

    // MARK: - 文案

    func testPrivacyLineIsTruthfulForDeepSeek() {
        L10n.shared.language = .zh
        let line = PrivacyCopy.audioGoesToProvider(provider: .deepseek)
        XCTAssertTrue(line.contains("DeepSeek"))
        XCTAssertFalse(line.contains("说话的同时"), "DeepSeek 没有实时识别，不许说边说边传")
        L10n.shared.language = .en
        XCTAssertFalse(CJKSourceScanner.containsFlagged(PrivacyCopy.audioGoesToProvider(provider: .deepseek)))
    }

    func testStatusCardNamesTheProvider() {
        L10n.shared.language = .zh
        XCTAssertEqual(SettingsStatusCard.connectionLine(connected: true, provider: .deepseek), "DeepSeek · 已连接")
        L10n.shared.language = .en
        XCTAssertEqual(SettingsStatusCard.connectionLine(connected: false, provider: .deepseek),
                       "DeepSeek · Not connected")
        XCTAssertEqual(SettingsStatusCard.connectionLine(connected: true), "OpenAI · Connected")
    }

    // MARK: - 本周用量：按币种分开累计

    func testUsageCostIsAccumulatedPerCurrency() {
        let now = Date()
        let entries = [
            UsageEntry(date: now.addingTimeInterval(-60), seconds: 60, chars: 30, command: false),
            UsageEntry(date: now.addingTimeInterval(-50), seconds: 60, chars: 30, command: false,
                       provider: .deepseek),
            UsageEntry(date: now.addingTimeInterval(-40), seconds: 0, chars: 0, command: false,
                       revert: true, provider: .deepseek),
        ]
        let week = UsageStore.summarize(entries, now: now)
        XCTAssertEqual(week.sentences, 2)
        XCTAssertEqual(week.seconds, 120)
        XCTAssertEqual(week.reverts, 1)
        XCTAssertEqual(week.costUSD, UsageStore.estimatedCost(seconds: 60, sentences: 1, provider: .openai),
                       accuracy: 1e-9)
        XCTAssertEqual(week.costCNY, UsageStore.estimatedCost(seconds: 60, sentences: 1, provider: .deepseek),
                       accuracy: 1e-9)
        // DeepSeek：一小时 360 句 = 识别 ¥0.78 + 润色估算
        XCTAssertEqual(UsageStore.estimatedCost(seconds: 3600, sentences: 360, provider: .deepseek),
                       LLMCatalog.hourly(provider: .deepseek), accuracy: 1e-9)
    }

    func testUsageCostFormatting() {
        L10n.shared.language = .zh
        XCTAssertEqual(UsageFormat.cost(UsageWeek(seconds: 60, chars: 1, sentences: 1, costUSD: 0.1234)),
                       "约 $0.12")
        XCTAssertEqual(UsageFormat.cost(UsageWeek(seconds: 60, chars: 1, sentences: 1, costUSD: 0,
                                                  costCNY: 0.3)), "约 ¥0.30")
        XCTAssertEqual(UsageFormat.cost(UsageWeek(seconds: 60, chars: 1, sentences: 2, costUSD: 0.12,
                                                  costCNY: 0.3)), "约 $0.12 · ¥0.30")
        XCTAssertEqual(UsageFormat.cost(UsageWeek(seconds: 1, chars: 1, sentences: 1, costUSD: 0,
                                                  costCNY: 0.001)), "< ¥0.01")
        L10n.shared.language = .en
        XCTAssertEqual(UsageFormat.cost(UsageWeek(seconds: 60, chars: 1, sentences: 2, costUSD: 0.12,
                                                  costCNY: 0.3)), "~$0.12 · ¥0.30")
    }

    func testUsageLedgerWritesProviderOnlyForDeepSeek() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let openai = try XCTUnwrap(UsageStore.encode(UsageEntry(date: date, seconds: 1, chars: 1, command: false)))
        XCTAssertFalse(openai.contains("provider"), "OpenAI 那一行一个字节都不变：\(openai)")
        let deepseek = try XCTUnwrap(UsageStore.encode(UsageEntry(date: date, seconds: 1, chars: 1,
                                                                  command: false, provider: .deepseek)))
        XCTAssertTrue(deepseek.contains("\"provider\":\"deepseek\""), deepseek)
        XCTAssertEqual(UsageStore.decode(deepseek)?.provider, .deepseek)
        // 5.4.x 写的老行没有这个字段 → OpenAI
        XCTAssertEqual(UsageStore.decode(openai)?.provider, .openai)
    }
}
