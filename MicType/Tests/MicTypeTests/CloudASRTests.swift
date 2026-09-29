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

    // MARK: - 分段规划

    private let sr = WAVEncoder.defaultSampleRate

    /// 规划算法本身的用例用一组固定的 120 / 180 秒上限（5.1.0 之前就是阿里云那一档的数；
    /// 那一档删掉之后这组数只为让算法断言保持原样——它们验的是"怎么切"，不是哪一家）
    private static let limits120 = CloudSegmentLimits(targetSeconds: 120, hardMaxSeconds: 180)

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
        let segments = CloudSegmentPlanner.plan(samples: clip, limits: Self.limits120)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.first?.count, clip.count)
    }

    func testLongClipCutsAtSilenceWithinHardMax() {
        let total = 400.0
        let frames = rmsFrames(seconds: total, silentAt: [110, 118, 238, 358])
        let segments = CloudSegmentPlanner.plan(rmsFrames: frames,
                                               totalSamples: samples(seconds: total),
                                               limits: Self.limits120)
        XCTAssertTrue((3...4).contains(segments.count), "400 秒应切成 3–4 段，实际 \(segments.count)")
        for seg in segments {
            XCTAssertLessThanOrEqual(seg.seconds, Self.limits120.hardMaxSeconds + 0.001)
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
                                               limits: Self.limits120)
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
                                               limits: Self.limits120)
        XCTAssertEqual(segments.count, 2, "短尾巴要并进上一段，而不是为 5 秒话单独发一次请求")
        XCTAssertEqual(segments[0].seconds, 120, accuracy: 0.001)
        XCTAssertEqual(segments[1].seconds, 125, accuracy: 0.001)
        XCTAssertLessThanOrEqual(segments[1].seconds, Self.limits120.hardMaxSeconds)
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

    /// **不变式**：任何供应商的单段硬上限都必须显著小于录音硬上限。
    /// 否则 planner 的"一次就能发完"提前返回会对**每一次**录音都命中，那一档永远只有 1 段：
    /// 分段进度（onSegment 只在收尾时回一次、total==1）、失败的部分交付、Esc 保字
    /// 三件事同时失效——v4.0 的 OpenAI 档（600/700）正是这么废的。
    func testEveryProviderSegmentsAFullLengthRecording() {
        let maxRecording = DictationController.maxRecordingSeconds
        for provider in CloudASRProvider.allCases {
            let limits = provider.segmentLimits
            XCTAssertLessThanOrEqual(limits.hardMaxSeconds, maxRecording / 2,
                                     "\(provider.rawValue)：单段硬上限必须 ≤ 录音上限的一半，满长度录音才切得开")
            XCTAssertLessThan(limits.targetSeconds, limits.hardMaxSeconds)
            let full = CloudSegmentPlanner.plan(rmsFrames: rmsFrames(seconds: maxRecording),
                                                totalSamples: samples(seconds: maxRecording),
                                                limits: limits)
            XCTAssertGreaterThanOrEqual(full.count, 2,
                                        "\(provider.rawValue)：满长度录音必须切成多段，否则没有进度、没有部分交付")
            for seg in full {
                XCTAssertLessThanOrEqual(seg.seconds, limits.hardMaxSeconds + 0.001)
            }
            XCTAssertEqual(full.reduce(0) { $0 + $1.count }, samples(seconds: maxRecording))
        }
    }

    func testEmptyAudioPlansNothing() {
        XCTAssertTrue(CloudSegmentPlanner.plan(samples: [], limits: Self.limits120).isEmpty)
    }

    // MARK: - 词表过滤（OpenAI 的 keywords[]）与语言提示

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
        XCTAssertEqual(OpenAITranscribeClient.filteredTerms(terms),
                       ["MicType", "Model Context Protocol", "云术法", "Rappel"])
    }

    func testVocabularyIsCappedAt2000() {
        let many = (0 ..< 2500).map { "term\($0)" }
        XCTAssertEqual(OpenAITranscribeClient.filteredTerms(many).count, 2000)
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

    // 阿里云那一档的用例（端点、模型回落、请求体、响应解析、错误映射、200 裹着的错误码）
    // 5.1.0 随 AlibabaASRClient 一起删掉。

    private func json(_ s: String) -> Data { Data(s.utf8) }

    /// 5.3.0 起服务商的原话与错误码**不上屏**（UX 方案 §3 H：细节进日志）：
    /// 屏幕上只有集中表里那一句，错误码仍留在 failure.code 里给探针与日志用。
    func testProviderDetailStaysOffScreen() {
        let openai = OpenAITranscribeClient.failure(status: 401, code: "invalid_api_key",
                                                   message: "Incorrect API key provided: sk-***")
        XCTAssertEqual(openai.message, UserMessage.keyRejected, "实际是：\(openai.message)")
        XCTAssertFalse(openai.message.contains("Incorrect"))
        XCTAssertFalse(openai.message.contains("sk-"))
        XCTAssertEqual(openai.code, "invalid_api_key")
        XCTAssertEqual(openai.error.action, .openSettings)
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
        XCTAssertTrue(quota.message.contains("余额") || quota.message.contains("credit"))
        XCTAssertEqual(quota.error.action, .addCredit)

        let badRequest = OpenAITranscribeClient.failure(status: 400, code: "invalid_request_error",
                                                        message: "file too large")
        XCTAssertFalse(badRequest.retryable)
        XCTAssertTrue(badRequest.message.contains("400"))
        XCTAssertFalse(badRequest.message.contains("file too large"), "服务商原话只进日志")

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

    /// 只有"两侧都是中日韩"不加分隔符；中英混缝要一个空格，否则两个词会粘住
    func testJoinerMixedScriptsGetOneSpace() {
        XCTAssertEqual(CloudTextJoiner.join(["中文结尾", "English start"]), "中文结尾 English start")
        XCTAssertEqual(CloudTextJoiner.join(["English end", "中文开头"]), "English end 中文开头")
    }

    /// 阿语靠空格断词：阿|阿、阿|西 都是一个空格（老实现把它当成"不加空格"的文字，
    /// 会把两个阿语词粘成一个不存在的词）
    func testJoinerArabicNeighboursGetOneSpace() {
        XCTAssertEqual(CloudTextJoiner.join(["مرحبا", "بالعالم"]), "مرحبا بالعالم")
        XCTAssertEqual(CloudTextJoiner.join(["الاجتماع", "Power BI"]), "الاجتماع Power BI")
    }

    /// 云端与本地两条链路必须拼出**逐字相同**的文本：云端失败会退回本地重跑一遍，
    /// 同一段录音在两条路上拼法不同的话，用户会看到"重试之后空格变了"
    func testJoinerMatchesTheLocalPipeline() {
        let parts = ["الاجتماع غدا", "Power BI", "今天下午", "三点开会。", "done", ", and then"]
        XCTAssertEqual(CloudTextJoiner.join(parts), TextPostProcessor.joinSegments(parts))
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
        XCTAssertFalse(TextPostProcessor.needsSegmentSpace(after: "中", before: "文"))
        XCTAssertFalse(TextPostProcessor.needsSegmentSpace(after: "。", before: "下"))
        XCTAssertFalse(TextPostProcessor.needsSegmentSpace(after: "ア", before: "イ"))
        XCTAssertTrue(TextPostProcessor.needsSegmentSpace(after: "م", before: "ب"))
        XCTAssertTrue(TextPostProcessor.needsSegmentSpace(after: "a", before: "b"))
        XCTAssertTrue(TextPostProcessor.needsSegmentSpace(after: "é", before: "a"))
        XCTAssertTrue(TextPostProcessor.needsSegmentSpace(after: "1", before: "2"))
    }

    // MARK: - 上下文

    func testContextBuilderLimitsAndSkipsEmpty() {
        XCTAssertNil(CloudASRContext.text(previousTail: nil), "没有上文就不发 prompt")
        XCTAssertNil(CloudASRContext.text(previousTail: "  \n "))
        XCTAssertEqual(CloudASRContext.text(previousTail: "上一段结尾"), "上文：上一段结尾")
        let long = CloudASRContext.text(previousTail: String(repeating: "词", count: 900))
        XCTAssertEqual(long?.count, CloudASRContext.charLimit, "上下文不得超过 400 字")
        XCTAssertNil(CloudASRContext.tail(of: "  \n  "))
        XCTAssertEqual(CloudASRContext.tail(of: "abcdef", chars: 3), "def")
    }

    // MARK: - 配置与引擎外壳

    func testConfigBuildsMatchingClient() {
        let openai = CloudASRConfig(provider: .openai, apiKey: "k")
        XCTAssertTrue(openai.makeClient() is OpenAITranscribeClient)
        XCTAssertEqual(openai.makeClient().segmentLimits, .openai)
    }

    func testEngineNameAndAvailability() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .openai, apiKey: ""))
        XCTAssertEqual(engine.engineName, "Cloud · OpenAI")
        XCTAssertFalse(engine.isModelAvailable, "没 Key 就等于引擎不可用")
        XCTAssertFalse(engine.isModelLoaded, "云端永远不占本机内存")

        engine.update(config: CloudASRConfig(provider: .openai, apiKey: "sk-test"))
        XCTAssertEqual(engine.engineName, "Cloud · OpenAI")
        XCTAssertTrue(engine.isModelAvailable)
        XCTAssertEqual(engine.currentConfig.provider, .openai)
    }

    /// 没 Key 时必须在主线程回一个明确的错误，而不是静默不回调（否则悬浮窗会永远转圈）
    func testEngineFailsFastWithoutCredentials() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .openai, apiKey: ""))
        let done = expectation(description: "completion")
        engine.transcribe(samples: [0.1, 0.2]) { result in
            XCTAssertTrue(Thread.isMainThread, "completion 必须回主线程")
            if case .success = result { XCTFail("没有 Key 不该成功") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testEngineReturnsEmptyForEmptyAudio() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .openai, apiKey: "sk-test"))
        let done = expectation(description: "completion")
        engine.transcribe(samples: []) { result in
            XCTAssertEqual(try? result.get(), "", "空音频不上网，直接回空文本")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// 云端识别**复用润色那一档的 Key**：同一个控制台里的同一把 Key，分两处存
    /// 只会存出两个不一致的值（改了一处、另一处还是旧的，表现是随机 401）
    func testCloudKeychainAccountNames() {
        XCTAssertEqual(CloudASRProvider.openai.keychainAccount, "openai_api_key",
                       "OpenAI 云端识别复用润色那把 Key")
        XCTAssertEqual(CloudASRProvider.openai.keychainAccount, LLMProvider.openai.keychainAccount)
        XCTAssertEqual(KeychainHelper.openAIAccount, LLMProvider.openai.keychainAccount)
    }
}
