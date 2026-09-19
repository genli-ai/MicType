import XCTest
@testable import MicType

/// 云端识别引擎的纯函数层单测：WAV 编码、分段规划、两家的请求体 / 响应解析 / 错误映射、分段拼接。
/// 全部不碰网络、不碰 Settings、不碰钥匙串——云端一秒钱都不用花就能回归。
///
/// 文案断言故意写成"中文 或 英文"：tr() 取的是运行时界面语言，不能让单测依赖它。
final class CloudASRTests: XCTestCase {

    // MARK: - WAV 编码

    private func u32(_ d: Data, _ offset: Int) -> UInt32 {
        UInt32(d[offset]) | UInt32(d[offset + 1]) << 8 | UInt32(d[offset + 2]) << 16 | UInt32(d[offset + 3]) << 24
    }
    private func u16(_ d: Data, _ offset: Int) -> UInt16 {
        UInt16(d[offset]) | UInt16(d[offset + 1]) << 8
    }
    private func ascii(_ d: Data, _ range: Range<Int>) -> String {
        String(decoding: d[range], as: UTF8.self)
    }

    func testWAVHeaderFieldsAndSize() {
        let wav = WAVEncoder.encode(samples: [0, 0.25, -0.25, 1])
        XCTAssertEqual(wav.count, 44 + 8, "44 字节头 + 4 个采样 × 2 字节")
        XCTAssertEqual(ascii(wav, 0..<4), "RIFF")
        XCTAssertEqual(u32(wav, 4), 36 + 8, "RIFF chunk 长度 = 36 + 数据字节")
        XCTAssertEqual(ascii(wav, 8..<12), "WAVE")
        XCTAssertEqual(ascii(wav, 12..<16), "fmt ")
        XCTAssertEqual(u32(wav, 16), 16)
        XCTAssertEqual(u16(wav, 20), 1, "1 = PCM")
        XCTAssertEqual(u16(wav, 22), 1, "单声道")
        XCTAssertEqual(u32(wav, 24), 16_000)
        XCTAssertEqual(u32(wav, 28), 32_000, "byteRate = 16000 × 1 × 2")
        XCTAssertEqual(u16(wav, 32), 2, "blockAlign")
        XCTAssertEqual(u16(wav, 34), 16, "bitsPerSample")
        XCTAssertEqual(ascii(wav, 36..<40), "data")
        XCTAssertEqual(u32(wav, 40), 8)
    }

    func testWAVEmptySamplesIsHeaderOnly() {
        let wav = WAVEncoder.encode(samples: [])
        XCTAssertEqual(wav.count, WAVEncoder.headerBytes)
        XCTAssertEqual(u32(wav, 40), 0)
    }

    /// 越界截断 + NaN 当静音：坏数据不能整段送到云端（那边只会回 400）
    func testPCM16ClipsAndSanitizes() {
        XCTAssertEqual(WAVEncoder.pcm16(0), 0)
        XCTAssertEqual(WAVEncoder.pcm16(1.0), 32_767)
        XCTAssertEqual(WAVEncoder.pcm16(-1.0), -32_767)
        XCTAssertEqual(WAVEncoder.pcm16(9.0), 32_767, "越界要截断而不是溢出")
        XCTAssertEqual(WAVEncoder.pcm16(-9.0), -32_767)
        XCTAssertEqual(WAVEncoder.pcm16(.nan), 0)
        XCTAssertEqual(WAVEncoder.pcm16(.infinity), 0)
    }

    func testWAVRoundTripsSamples() {
        let samples: [Float] = [0, 0.5, -0.5, 0.125, 2.0, -2.0]
        let expected: [Float] = [0, 0.5, -0.5, 0.125, 1.0, -1.0]
        let wav = WAVEncoder.encode(samples: samples)
        var decoded = [Float]()
        for i in 0 ..< samples.count {
            let raw = Int16(bitPattern: u16(wav, 44 + i * 2))
            decoded.append(Float(raw) / 32_767.0)
        }
        XCTAssertEqual(decoded.count, expected.count)
        for (got, want) in zip(decoded, expected) {
            XCTAssertEqual(got, want, accuracy: 1.0 / 32_767.0)
        }
    }

    func testDataURIAndBase64Length() {
        let wav = WAVEncoder.encode(samples: [0, 0.1, 0.2])
        let uri = WAVEncoder.dataURI(wav: wav)
        XCTAssertTrue(uri.hasPrefix("data:audio/wav;base64,"))
        let payload = String(uri.dropFirst("data:audio/wav;base64,".count))
        XCTAssertEqual(payload, WAVEncoder.base64(wav: wav))
        XCTAssertEqual(WAVEncoder.base64Length(forByteCount: wav.count), payload.count,
                       "预校验算的长度必须与真编码出来的一致")
    }

    // MARK: - 分段规划

    private let sr = WAVEncoder.defaultSampleRate

    /// 按秒生成 RMS 帧：silences 里的秒数附近给近零能量
    private func rmsFrames(seconds: Double, loud: Float = 0.2, silentAt: [Double] = []) -> [Float] {
        let count = Int(seconds / CloudSegmentPlanner.frameSeconds)
        var frames = [Float](repeating: loud, count: count)
        for s in silentAt {
            let idx = Int(s / CloudSegmentPlanner.frameSeconds)
            for f in max(0, idx - 2) ... min(count - 1, idx + 2) { frames[f] = 0.0001 }
        }
        return frames
    }

    private func samples(seconds: Double) -> Int { Int(seconds * Double(sr)) }

    func testRMSFramesCountAndValue() {
        let one = [Float](repeating: 0.5, count: 16_000)
        let frames = CloudSegmentPlanner.rmsFrames(samples: one)
        XCTAssertEqual(frames.count, 50, "1 秒 = 50 帧（20ms 一帧）")
        XCTAssertEqual(frames[10], 0.5, accuracy: 0.001)
    }

    func testShortClipIsASingleSegment() {
        let clip = [Float](repeating: 0.1, count: samples(seconds: 3))
        let segments = CloudSegmentPlanner.plan(samples: clip, limits: .alibaba)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.first?.count, clip.count)
    }

    func testLongClipCutsAtSilenceWithinHardMax() {
        let total = 400.0
        let frames = rmsFrames(seconds: total, silentAt: [110, 118, 238, 358])
        let segments = CloudSegmentPlanner.plan(rmsFrames: frames,
                                               totalSamples: samples(seconds: total),
                                               limits: .alibaba)
        XCTAssertTrue((3...4).contains(segments.count), "400 秒应切成 3–4 段，实际 \(segments.count)")
        for seg in segments {
            XCTAssertLessThanOrEqual(seg.seconds, CloudSegmentLimits.alibaba.hardMaxSeconds + 0.001)
            XCTAssertGreaterThan(seg.count, 0)
        }
        // 覆盖完整、首尾相接，一个采样都不丢
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.count }, samples(seconds: total))
        for i in 1 ..< segments.count {
            XCTAssertEqual(segments[i].start, segments[i - 1].start + segments[i - 1].count)
        }
        // 第一刀落在 118s 的静音上（±3s 窗口内），而不是窗口外的 110s
        XCTAssertEqual(segments[0].seconds, 118, accuracy: 0.05)
    }

    func testNoSilenceCutsAtNominalBoundaries() {
        let total = 400.0
        let frames = rmsFrames(seconds: total)      // 全程等能量：没有静音可挑
        let segments = CloudSegmentPlanner.plan(rmsFrames: frames,
                                               totalSamples: samples(seconds: total),
                                               limits: .alibaba)
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0].seconds, 120, accuracy: 0.001, "平局要归名义边界")
        XCTAssertEqual(segments[1].seconds, 120, accuracy: 0.001)
        XCTAssertEqual(segments[2].seconds, 120, accuracy: 0.001)
        XCTAssertEqual(segments[3].seconds, 40, accuracy: 0.001)
    }

    func testShortTailMergesIntoPreviousSegment() {
        let total = 245.0                            // 120 + 120 + 5：尾巴只有 5 秒
        let frames = rmsFrames(seconds: total)
        let segments = CloudSegmentPlanner.plan(rmsFrames: frames,
                                               totalSamples: samples(seconds: total),
                                               limits: .alibaba)
        XCTAssertEqual(segments.count, 2, "短尾巴要并进上一段，而不是为 5 秒话单独发一次请求")
        XCTAssertEqual(segments[0].seconds, 120, accuracy: 0.001)
        XCTAssertEqual(segments[1].seconds, 125, accuracy: 0.001)
        XCTAssertLessThanOrEqual(segments[1].seconds, CloudSegmentLimits.alibaba.hardMaxSeconds)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.count }, samples(seconds: total))
    }

    func testOpenAIPresetKeepsSegmentsUnderItsHardMax() {
        let total = 1600.0
        let frames = rmsFrames(seconds: total, silentAt: [598, 1195])
        let segments = CloudSegmentPlanner.plan(rmsFrames: frames,
                                               totalSamples: samples(seconds: total),
                                               limits: .openai)
        XCTAssertGreaterThanOrEqual(segments.count, 2)
        for seg in segments {
            XCTAssertLessThanOrEqual(seg.seconds, CloudSegmentLimits.openai.hardMaxSeconds + 0.001)
        }
        XCTAssertEqual(segments.reduce(0) { $0 + $1.count }, samples(seconds: total))
    }

    func testEmptyAudioPlansNothing() {
        XCTAssertTrue(CloudSegmentPlanner.plan(samples: [], limits: .alibaba).isEmpty)
    }

    // MARK: - 阿里云：端点

    func testAlibabaEndpointsPerRegion() {
        XCTAssertEqual(AlibabaASRClient.endpoint(region: .international, workspaceId: nil)?.absoluteString,
                       "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        XCTAssertEqual(AlibabaASRClient.endpoint(region: .china, workspaceId: nil)?.host,
                       "dashscope.aliyuncs.com")
        XCTAssertEqual(AlibabaASRClient.endpoint(region: .international, workspaceId: "llm-abc")?.host,
                       "llm-abc.ap-southeast-1.maas.aliyuncs.com")
        XCTAssertEqual(AlibabaASRClient.endpoint(region: .us, workspaceId: "llm-abc")?.host,
                       "llm-abc.us-east-1.maas.aliyuncs.com")
        XCTAssertEqual(AlibabaASRClient.endpoint(region: .china, workspaceId: "llm-abc")?.host,
                       "llm-abc.cn-beijing.maas.aliyuncs.com")
        // 空白 WorkspaceId 等于没填，不能拼出 " .ap-southeast-1…" 这种主机
        XCTAssertEqual(AlibabaASRClient.endpoint(region: .international, workspaceId: "  ")?.host,
                       "dashscope-intl.aliyuncs.com")
    }

    // MARK: - 阿里云：词表过滤与语言提示

    func testVocabularyFilteringFollowsDocumentedRules() {
        let terms = [
            "MicType",                              // 纯 ASCII 单段 → 留
            "Model Context Protocol",               // 3 段 → 留
            "a b c d e f g h",                      // 8 段 → 丢（上限 7）
            "云术法",                                // 非 ASCII 3 字 → 留
            "这是一个非常非常非常长的中文热词条目",      // 非 ASCII 超 15 字 → 丢
            "  Rappel  ",                           // 去首尾空白后留
            "MicType",                              // 重复 → 去重
            "",                                     // 空 → 丢
        ]
        let kept = AlibabaASRClient.filteredTerms(terms)
        XCTAssertEqual(kept, ["MicType", "Model Context Protocol", "云术法", "Rappel"])
        let param = AlibabaASRClient.vocabularyParameter(terms)
        XCTAssertEqual(param.count, 4)
        XCTAssertEqual(param["MicType"], 4, "权重统一用推荐值 4")
        XCTAssertNil(param["a b c d e f g h"])
    }

    func testVocabularyIsCappedAt2000() {
        let many = (0 ..< 2500).map { "term\($0)" }
        XCTAssertEqual(AlibabaASRClient.filteredTerms(many).count, 2000)
        XCTAssertEqual(AlibabaASRClient.vocabularyParameter(many).count, 2000)
    }

    func testLanguageHintsAreSanitizedAndCappedAtFour() {
        let hints = CloudASRLanguage.sanitize(hints: ["zh", "ZH", "en", "xx", "ja", "ko", "ru"])
        XCTAssertEqual(hints, ["zh", "en", "ja", "ko"], "小写去重、丢掉不认识的码、最多 4 个")
        XCTAssertTrue(CloudASRLanguage.sanitize(hints: []).isEmpty)
        XCTAssertEqual(CloudASRLanguage.sanitize(hints: ["ar"]), ["ar"], "阿拉伯语只有 ar，没有方言码")
    }

    func testLanguageNameFallsBackToCode() {
        XCTAssertEqual(CloudASRLanguage.code(forName: "English"), "en")
        XCTAssertEqual(CloudASRLanguage.code(forName: "chinese"), "zh")
        XCTAssertEqual(CloudASRLanguage.code(forName: "zh"), "zh")
        XCTAssertEqual(CloudASRLanguage.code(forName: "klingon"), "klingon", "认不出就原样返回，不瞎猜")
    }

    // MARK: - 阿里云：请求体

    private func body30(context: String?) -> [String: Any] {
        AlibabaASRClient.requestBody(model: .qwenAudio30Flash,
                                     audioDataURI: "data:audio/wav;base64,AAAA",
                                     vocabulary: ["MicType", "云术法"],
                                     languageHints: ["zh", "en", "xx"],
                                     context: context,
                                     enableITN: false)
    }

    func testAudio30RequestBodyShape() {
        let body = body30(context: "上文：你好")
        XCTAssertEqual(body["model"] as? String, "qwen-audio-3.0-asr-flash")
        let input = body["input"] as? [String: Any]
        let messages = input?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 3, "input_text 上下文 turn + 空 assistant turn + input_audio turn")
        XCTAssertEqual(messages?[0]["role"] as? String, "user")
        let firstContent = messages?[0]["content"] as? [[String: Any]]
        XCTAssertEqual(firstContent?.first?["type"] as? String, "input_text")
        XCTAssertEqual(firstContent?.first?["text"] as? String, "上文：你好")
        XCTAssertEqual(messages?[1]["role"] as? String, "assistant")
        let assistantContent = messages?[1]["content"] as? [[String: Any]]
        XCTAssertEqual(assistantContent?.first?["type"] as? String, "text")
        XCTAssertEqual(assistantContent?.first?["text"] as? String, "")
        let audioContent = messages?[2]["content"] as? [[String: Any]]
        XCTAssertEqual(audioContent?.first?["type"] as? String, "input_audio")
        let audio = audioContent?.first?["input_audio"] as? [String: Any]
        XCTAssertEqual(audio?["data"] as? String, "data:audio/wav;base64,AAAA")

        let parameters = body["parameters"] as? [String: Any]
        XCTAssertEqual(parameters?["format"] as? String, "wav")
        XCTAssertEqual(parameters?["sample_rate"] as? String, "16000", "sample_rate 是字符串，不是数字")
        XCTAssertEqual(parameters?["vocabulary"] as? [String: Int], ["MicType": 4, "云术法": 4])
        XCTAssertEqual(parameters?["language_hints"] as? [String], ["zh", "en"], "不认识的 xx 要被丢掉")
    }

    func testAudio30RequestBodyOmitsEmptyContextTurns() {
        let body = body30(context: nil)
        let messages = (body["input"] as? [String: Any])?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1, "没有上下文就只发音频那一条，不发空 text turn")
        let content = messages?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "input_audio")

        let blank = body30(context: "   ")
        let blankMessages = (blank["input"] as? [String: Any])?["messages"] as? [[String: Any]]
        XCTAssertEqual(blankMessages?.count, 1, "全是空白的上下文等于没有")
    }

    func testAudio30OmitsEmptyVocabularyAndHints() {
        let body = AlibabaASRClient.requestBody(model: .qwenAudio30Flash,
                                                audioDataURI: "data:audio/wav;base64,AAAA",
                                                vocabulary: [],
                                                languageHints: [],
                                                context: nil,
                                                enableITN: false)
        let parameters = body["parameters"] as? [String: Any]
        XCTAssertNil(parameters?["vocabulary"])
        XCTAssertNil(parameters?["language_hints"])
    }

    func testQwen3RequestBodyShape() {
        let body = AlibabaASRClient.requestBody(model: .qwen3Flash,
                                                audioDataURI: "data:audio/wav;base64,AAAA",
                                                vocabulary: ["MicType"],
                                                languageHints: ["zh"],
                                                context: "常用词汇：MicType",
                                                enableITN: false)
        XCTAssertEqual(body["model"] as? String, "qwen3-asr-flash")
        let messages = (body["input"] as? [String: Any])?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"] as? String, "system")
        let systemContent = messages?[0]["content"] as? [[String: Any]]
        XCTAssertEqual(systemContent?.first?["text"] as? String, "常用词汇：MicType")
        XCTAssertNil(systemContent?.first?["type"], "qwen3 的 system content 只有 text 字段")
        let options = (body["parameters"] as? [String: Any])?["asr_options"] as? [String: Any]
        XCTAssertEqual(options?["language"] as? String, "zh")
        XCTAssertEqual(options?["enable_itn"] as? Bool, false)
        // qwen3 没有 parameters.vocabulary
        XCTAssertNil((body["parameters"] as? [String: Any])?["vocabulary"])
    }

    func testQwen3ITNOnlyForChineseAndEnglish() {
        func itn(_ hints: [String]) -> Bool? {
            let body = AlibabaASRClient.requestBody(model: .qwen3Flash,
                                                    audioDataURI: "x",
                                                    vocabulary: [],
                                                    languageHints: hints,
                                                    context: nil,
                                                    enableITN: true)
            let options = (body["parameters"] as? [String: Any])?["asr_options"] as? [String: Any]
            return options?["enable_itn"] as? Bool
        }
        XCTAssertEqual(itn(["en"]), true)
        XCTAssertEqual(itn(["zh"]), true)
        XCTAssertEqual(itn(["ar"]), false, "ITN 只对中英有效")
        XCTAssertEqual(itn([]), false, "没指定语言时不开 ITN")
    }

    func testAlibabaRequestHeadersAndPrecheck() {
        let client = AlibabaASRClient(apiKey: "sk-test", region: .international)
        let wav = WAVEncoder.encode(samples: [Float](repeating: 0, count: 16_000))
        guard case .success(let request) = client.makeRequest(wav: wav, seconds: 1, context: nil) else {
            return XCTFail("正常大小的音频应该能建出请求")
        }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-SSE"), "disable",
                       "非流式必须显式关掉 SSE")
        XCTAssertNotNil(request.httpBody)

        // 没 Key 不上网
        let noKey = AlibabaASRClient(apiKey: "  ")
        guard case .failure = noKey.makeRequest(wav: wav, seconds: 1, context: nil) else {
            return XCTFail("没有 Key 时必须在本地就失败")
        }
    }

    func testAlibabaPrecheckRejectsOverLimitAudio() {
        XCTAssertNotNil(AlibabaASRClient.precheck(base64Length: 1000, seconds: 301), "超 5 分钟要本地拦下")
        XCTAssertNil(AlibabaASRClient.precheck(base64Length: 1000, seconds: 300))
        XCTAssertNotNil(AlibabaASRClient.precheck(base64Length: 10 * 1024 * 1024 + 1, seconds: 10),
                        "base64 超 10MB 要本地拦下")
        XCTAssertNil(AlibabaASRClient.precheck(base64Length: 10 * 1024 * 1024, seconds: 10))
    }

    // MARK: - 阿里云：响应解析

    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testParseAudio30OutputText() {
        let data = json(#"{"output":{"text":"今天天气不错"},"usage":{"duration":12.5}}"#)
        guard case .success(let result) = AlibabaASRClient.parse(data, model: .qwenAudio30Flash) else {
            return XCTFail("应该解析成功")
        }
        XCTAssertEqual(result.text, "今天天气不错")
        XCTAssertEqual(result.billedSeconds, 12.5)
        XCTAssertNil(result.detectedLanguage, "3.0 不返回识别语言")
    }

    func testParseAudio30SentenceFallback() {
        let data = json(#"{"output":{"sentence":{"text":"备用形状"}},"usage":{"duration":3}}"#)
        guard case .success(let result) = AlibabaASRClient.parse(data, model: .qwenAudio30Flash) else {
            return XCTFail("output.sentence.text 也要认")
        }
        XCTAssertEqual(result.text, "备用形状")
        XCTAssertEqual(result.billedSeconds, 3)
    }

    func testParseQwen3ChoicesAndAnnotations() {
        let data = json("""
        {"output":{"choices":[{"message":{"content":[{"text":"hello there"}],
          "annotations":[{"type":"audio_info","language":"en"}]}}]},"usage":{"seconds":8}}
        """)
        guard case .success(let result) = AlibabaASRClient.parse(data, model: .qwen3Flash) else {
            return XCTFail("应该解析成功")
        }
        XCTAssertEqual(result.text, "hello there")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.billedSeconds, 8)
    }

    func testParseRejectsMissingTextAndBodyLevelErrorCode() {
        if case .success = AlibabaASRClient.parse(json(#"{"output":{}}"#), model: .qwenAudio30Flash) {
            XCTFail("没有文本字段不能算成功")
        }
        if case .success = AlibabaASRClient.parse(json("not json"), model: .qwenAudio30Flash) {
            XCTFail("坏 JSON 不能算成功")
        }
        // HTTP 200 但 body 里报错的情况（DashScope 有这种返回）
        let data = json(#"{"code":"DataInspectionFailed","message":"blocked"}"#)
        guard case .failure(let failure) = AlibabaASRClient.parse(data, model: .qwenAudio30Flash) else {
            return XCTFail("body 里带 code 就是失败")
        }
        XCTAssertEqual(failure.code, "DataInspectionFailed")
    }

    // MARK: - 阿里云：错误映射

    func testAlibabaErrorMapping() {
        let unauthorized = AlibabaASRClient.failure(status: 401, code: "InvalidApiKey", message: "bad key")
        XCTAssertFalse(unauthorized.retryable)
        XCTAssertEqual(unauthorized.status, 401)
        XCTAssertEqual(unauthorized.code, "InvalidApiKey")
        XCTAssertTrue(unauthorized.message.contains("401"))
        XCTAssertTrue(unauthorized.message.contains("区域") || unauthorized.message.contains("region"),
                      "401 必须提醒区域与 Key 不匹配这个坑")

        let denied = AlibabaASRClient.failure(status: 403, code: "Model.AccessDenied", message: nil)
        XCTAssertFalse(denied.retryable)
        XCTAssertTrue(denied.message.contains("模型广场") || denied.message.contains("Model Gallery"),
                      "403 要告诉用户去控制台开通模型")

        let arrear = AlibabaASRClient.failure(status: 403, code: "Arrearage", message: nil)
        XCTAssertTrue(arrear.message.contains("充值") || arrear.message.contains("Top it up"))

        let notFound = AlibabaASRClient.failure(status: 404, code: "ModelNotFound", message: nil)
        XCTAssertFalse(notFound.retryable)

        let throttled = AlibabaASRClient.failure(status: 429, code: "Throttling.RateQuota", message: nil)
        XCTAssertTrue(throttled.retryable, "限流值得退避重试一次")

        let allocation = AlibabaASRClient.failure(status: 429, code: "Throttling.AllocationQuota", message: nil)
        XCTAssertFalse(allocation.retryable, "额度用完重试也没用")

        let inspection = AlibabaASRClient.failure(status: 400, code: "DataInspectionFailed", message: nil)
        XCTAssertFalse(inspection.retryable)
        XCTAssertTrue(inspection.message.contains("审核") || inspection.message.contains("content filter"),
                      "内容审核拦截要说明白，不能含糊成'参数错误'")

        let badParam = AlibabaASRClient.failure(status: 400, code: "InvalidParameter", message: "too long")
        XCTAssertFalse(badParam.retryable)
        XCTAssertTrue(badParam.message.contains("too long"), "云端原文要带上，方便排查")

        let serverError = AlibabaASRClient.failure(status: 500, code: "InternalError", message: nil)
        XCTAssertTrue(serverError.retryable)
        XCTAssertTrue(AlibabaASRClient.failure(status: 503, code: nil, message: nil).retryable)

        let weird = AlibabaASRClient.failure(status: 418, code: nil, message: nil)
        XCTAssertFalse(weird.retryable)
        XCTAssertNil(weird.code)
    }

    func testAlibabaErrorMappingReadsResponseBody() {
        let client = AlibabaASRClient(apiKey: "sk")
        let failure = client.failure(status: 429,
                                     data: json(#"{"code":"Throttling","message":"slow down"}"#))
        XCTAssertEqual(failure.code, "Throttling")
        XCTAssertTrue(failure.retryable)
        XCTAssertTrue(failure.message.contains("slow down"))
    }

    // MARK: - OpenAI：multipart

    func testOpenAIMultipartBodyLayout() {
        let wav = WAVEncoder.encode(samples: [0, 0, 0, 0])
        let body = OpenAITranscribeClient.multipartBody(boundary: "BDY",
                                                        wav: wav,
                                                        model: "gpt-transcribe",
                                                        languages: ["en", "xx", "zh"],
                                                        keywords: ["MicType", "a b c d e f g h"],
                                                        prompt: "previous tail")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--BDY\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n"),
                      "第一段必须是 model 字段，CRLF 一个不能少")
        XCTAssertTrue(text.contains("--BDY\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n"))
        XCTAssertTrue(text.contains("name=\"languages[]\"\r\n\r\nen\r\n"))
        XCTAssertTrue(text.contains("name=\"languages[]\"\r\n\r\nzh\r\n"))
        XCTAssertFalse(text.contains("xx"), "不认识的语言码不该进 body")
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\nMicType\r\n"))
        XCTAssertFalse(text.contains("a b c d e f g h"), "keywords 也要过词表长度规则")
        XCTAssertTrue(text.contains("name=\"prompt\"\r\n\r\nprevious tail\r\n"))
        XCTAssertTrue(text.contains("--BDY\r\nContent-Disposition: form-data; name=\"file\"; filename=\"seg.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF"),
                      "文件段的头与 WAV 字节之间只隔一个空行")
        XCTAssertTrue(text.hasSuffix("\r\n--BDY--\r\n"), "结尾要有收尾分界线")
        XCTAssertTrue(body.count > wav.count, "WAV 字节要真的在 body 里")
    }

    func testOpenAIMultipartOmitsEmptyPrompt() {
        let body = OpenAITranscribeClient.multipartBody(boundary: "BDY",
                                                        wav: Data(),
                                                        model: "gpt-transcribe",
                                                        languages: [],
                                                        keywords: [],
                                                        prompt: "   ")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("name=\"prompt\""))
        XCTAssertFalse(text.contains("languages[]"))
    }

    func testOpenAIRequestAndPrecheck() {
        let client = OpenAITranscribeClient(apiKey: "sk-openai")
        guard case .success(let request) = client.makeRequest(wav: Data([1, 2, 3]), seconds: 1, context: nil) else {
            return XCTFail("应该能建出请求")
        }
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-openai")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?
            .hasPrefix("multipart/form-data; boundary=") == true)

        XCTAssertNil(OpenAITranscribeClient.precheck(fileBytes: 25 * 1024 * 1024))
        XCTAssertNotNil(OpenAITranscribeClient.precheck(fileBytes: 25 * 1024 * 1024 + 1))
    }

    // MARK: - OpenAI：解析与错误

    func testParseOpenAIJSON() {
        let data = json(#"{"text":"Hello there","languages":[{"code":"en","probability":0.99}]}"#)
        guard case .success(let result) = OpenAITranscribeClient.parse(data) else {
            return XCTFail("应该解析成功")
        }
        XCTAssertEqual(result.text, "Hello there")
        XCTAssertEqual(result.detectedLanguage, "en")
    }

    func testParseOpenAIFallsBackToLanguageName() {
        let data = json(#"{"text":"مرحبا","language":"arabic"}"#)
        guard case .success(let result) = OpenAITranscribeClient.parse(data) else {
            return XCTFail("应该解析成功")
        }
        XCTAssertEqual(result.text, "مرحبا")
        XCTAssertEqual(result.detectedLanguage, "ar", "老格式给全名，要折回代码")
    }

    func testParseOpenAIErrorShapes() {
        if case .success = OpenAITranscribeClient.parse(json(#"{"foo":1}"#)) {
            XCTFail("没有 text 字段不能算成功")
        }
        guard case .failure(let failure) = OpenAITranscribeClient
            .parse(json(#"{"error":{"code":"insufficient_quota","message":"no credit"}}"#)) else {
            return XCTFail("body 里带 error 就是失败")
        }
        XCTAssertEqual(failure.code, "insufficient_quota")
    }

    func testOpenAIErrorMapping() {
        let unauthorized = OpenAITranscribeClient.failure(status: 401, code: "invalid_api_key", message: nil)
        XCTAssertFalse(unauthorized.retryable)
        XCTAssertTrue(unauthorized.message.contains("401"))

        let rateLimited = OpenAITranscribeClient.failure(status: 429, code: "rate_limit_exceeded", message: nil)
        XCTAssertTrue(rateLimited.retryable)

        let quota = OpenAITranscribeClient.failure(status: 429, code: "insufficient_quota", message: nil)
        XCTAssertFalse(quota.retryable, "额度不足重试也没用")
        XCTAssertTrue(quota.message.contains("充值") || quota.message.contains("credit"))

        let badRequest = OpenAITranscribeClient.failure(status: 400, code: "invalid_request_error",
                                                        message: "file too large")
        XCTAssertFalse(badRequest.retryable)
        XCTAssertTrue(badRequest.message.contains("25MB"))
        XCTAssertTrue(badRequest.message.contains("file too large"))

        XCTAssertTrue(OpenAITranscribeClient.failure(status: 503, code: nil, message: nil).retryable)
        XCTAssertFalse(OpenAITranscribeClient.failure(status: 404, code: nil, message: nil).retryable)

        let client = OpenAITranscribeClient(apiKey: "sk")
        let fromBody = client.failure(status: 429,
                                      data: json(#"{"error":{"type":"insufficient_quota","message":"x"}}"#))
        XCTAssertEqual(fromBody.code, "insufficient_quota")
        XCTAssertFalse(fromBody.retryable)
    }

    // MARK: - 分段文本拼接

    func testJoinerCJKNeighboursGetNoSeparator() {
        XCTAssertEqual(CloudTextJoiner.join(["今天天气", "不错啊"]), "今天天气不错啊")
        XCTAssertEqual(CloudTextJoiner.join(["これは", "テスト"]), "これはテスト")
        XCTAssertEqual(CloudTextJoiner.join(["안녕", "하세요"]), "안녕하세요")
        XCTAssertEqual(CloudTextJoiner.join(["结尾有句号。", "下一段"]), "结尾有句号。下一段")
    }

    func testJoinerLatinNeighboursGetOneSpace() {
        XCTAssertEqual(CloudTextJoiner.join(["hello world", "and then some"]), "hello world and then some")
        XCTAssertEqual(CloudTextJoiner.join(["one", "two", "three"]), "one two three")
    }

    func testJoinerMixedScriptsPreferNoSpace() {
        XCTAssertEqual(CloudTextJoiner.join(["中文结尾", "English start"]), "中文结尾English start")
        XCTAssertEqual(CloudTextJoiner.join(["English end", "中文开头"]), "English end中文开头")
    }

    func testJoinerArabicNeighboursGetNoSeparator() {
        XCTAssertEqual(CloudTextJoiner.join(["مرحبا", "بالعالم"]), "مرحبابالعالم")
    }

    func testJoinerDropsEmptyPartsAndTrims() {
        XCTAssertEqual(CloudTextJoiner.join([]), "")
        XCTAssertEqual(CloudTextJoiner.join(["", "  ", "\n"]), "")
        XCTAssertEqual(CloudTextJoiner.join(["  hello  ", "", " world "]), "hello world")
        XCTAssertEqual(CloudTextJoiner.join(["only one"]), "only one")
    }

    func testJoinerDoesNotSpaceBeforeTrailingPunctuation() {
        XCTAssertEqual(CloudTextJoiner.join(["hello", ", world"]), "hello, world")
        XCTAssertEqual(CloudTextJoiner.join(["done", "."]), "done.")
    }

    func testJoinerScriptDetection() {
        XCTAssertTrue(CloudTextJoiner.isNoSpaceScript("中"))
        XCTAssertTrue(CloudTextJoiner.isNoSpaceScript("。"))
        XCTAssertTrue(CloudTextJoiner.isNoSpaceScript("ア"))
        XCTAssertTrue(CloudTextJoiner.isNoSpaceScript("م"))
        XCTAssertFalse(CloudTextJoiner.isNoSpaceScript("a"))
        XCTAssertFalse(CloudTextJoiner.isNoSpaceScript("é"))
        XCTAssertFalse(CloudTextJoiner.isNoSpaceScript("1"))
    }

    // MARK: - 上下文

    func testContextBuilderLimitsAndSkipsEmpty() {
        XCTAssertNil(CloudASRContext.text(vocabulary: [], previousTail: nil, includeVocabulary: true))
        XCTAssertNil(CloudASRContext.text(vocabulary: ["MicType"], previousTail: nil, includeVocabulary: false),
                     "词表走参数时，没有上文就不发这个 turn")
        let withVocab = CloudASRContext.text(vocabulary: ["MicType"], previousTail: "上一段结尾",
                                             includeVocabulary: true)
        XCTAssertEqual(withVocab?.contains("MicType"), true)
        XCTAssertEqual(withVocab?.contains("上一段结尾"), true)
        let long = CloudASRContext.text(vocabulary: [String(repeating: "词", count: 900)],
                                        previousTail: nil, includeVocabulary: true)
        XCTAssertEqual(long?.count, CloudASRContext.charLimit, "上下文一 turn 不得超过 400 字")
        XCTAssertNil(CloudASRContext.tail(of: "  \n  "))
        XCTAssertEqual(CloudASRContext.tail(of: "abcdef", chars: 3), "def")
    }

    // MARK: - 配置与引擎外壳

    func testConfigBuildsMatchingClient() {
        let alibaba = CloudASRConfig(provider: .alibaba, apiKey: "k")
        XCTAssertTrue(alibaba.makeClient() is AlibabaASRClient)
        XCTAssertEqual(alibaba.makeClient().provider, .alibaba)
        XCTAssertEqual(alibaba.makeClient().segmentLimits, .alibaba)

        let openai = CloudASRConfig(provider: .openai, apiKey: "k")
        XCTAssertTrue(openai.makeClient() is OpenAITranscribeClient)
        XCTAssertEqual(openai.makeClient().segmentLimits, .openai)
    }

    func testEngineNameAndAvailability() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .alibaba, apiKey: ""))
        XCTAssertEqual(engine.engineName, "Cloud · Alibaba")
        XCTAssertFalse(engine.isModelAvailable, "没 Key 就等于引擎不可用")
        XCTAssertFalse(engine.isModelLoaded, "云端永远不占本机内存")

        engine.update(config: CloudASRConfig(provider: .openai, apiKey: "sk-test"))
        XCTAssertEqual(engine.engineName, "Cloud · OpenAI")
        XCTAssertTrue(engine.isModelAvailable)
        XCTAssertEqual(engine.currentConfig.provider, .openai)
    }

    /// 没 Key 时必须在主线程回一个明确的错误，而不是静默不回调（否则悬浮窗会永远转圈）
    func testEngineFailsFastWithoutCredentials() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .alibaba, apiKey: ""))
        let done = expectation(description: "completion")
        engine.transcribe(samples: [0.1, 0.2]) { result in
            XCTAssertTrue(Thread.isMainThread, "completion 必须回主线程")
            if case .success = result { XCTFail("没有 Key 不该成功") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testEngineReturnsEmptyForEmptyAudio() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .alibaba, apiKey: "sk-test"))
        let done = expectation(description: "completion")
        engine.transcribe(samples: []) { result in
            XCTAssertEqual(try? result.get(), "", "空音频不上网，直接回空文本")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// 两家云端都**复用润色那一档的 Key**：同一个控制台里的同一把 Key，分两处存
    /// 只会存出两个不一致的值（改了一处、另一处还是旧的，表现是随机 401）
    func testCloudKeychainAccountNames() {
        XCTAssertEqual(KeychainHelper.dashScopeAccount, "qwen_api_key")
        XCTAssertEqual(CloudASRProvider.alibaba.keychainAccount, "qwen_api_key",
                       "阿里云识别与 Qwen 润色共用一把百炼 Key")
        XCTAssertEqual(CloudASRProvider.alibaba.keychainAccount, LLMProvider.qwen.keychainAccount)
        XCTAssertEqual(CloudASRProvider.openai.keychainAccount, "openai_api_key",
                       "OpenAI 云端识别复用润色那把 Key")
        XCTAssertEqual(CloudASRProvider.openai.keychainAccount, LLMProvider.openai.keychainAccount)
        XCTAssertNotEqual(KeychainHelper.legacyDashScopeAccount, KeychainHelper.dashScopeAccount,
                          "旧账号名留着只为迁移，不能和统一账号同名")
    }
}
