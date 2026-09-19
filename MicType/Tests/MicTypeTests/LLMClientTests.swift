import XCTest
@testable import MicType

/// 大模型请求层的纯函数单测：请求体形状、Responses 响应解析、400 去参重试的判断。
/// 这一层没有网络、没有 UI——但形状错一个字段，用户看到的就是"润色一直失败"，
/// 而错误信息里只会写着一句模型的原话。
final class LLMClientTests: XCTestCase {

    // MARK: - 接口选择

    /// 官方域名才走 Responses
    func testOfficialOpenAIEndpointUsesResponses() {
        XCTAssertTrue(LLMClient.usesResponsesAPI(baseURL: "https://api.openai.com/v1"))
        XCTAssertTrue(LLMClient.usesResponsesAPI(baseURL: " https://api.openai.com/v1/ "))
    }

    /// 第三方兼容网关 / 本机模型只有 chat/completions：发 /responses 会 404，用户却以为是型号写错了
    func testCompatibleGatewaysStayOnChatCompletions() {
        for base in ["https://api.moonshot.ai/v1", "http://localhost:11434/v1",
                     "https://openrouter.ai/api/v1", "https://api.deepseek.com", ""] {
            XCTAssertFalse(LLMClient.usesResponsesAPI(baseURL: base), base)
        }
    }

    // MARK: - Responses 请求体

    func testPolishBodyIsTheFastestShape() {
        let body = LLMClient.responsesBody(model: "gpt-5.6-luna", system: "SYS", user: "USER",
                                           purpose: .polish, temperature: 0.5,
                                           maxOutputTokens: 2048)
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        // system 进 instructions、转写进 input：不变的前缀在前，才有命中 prompt 缓存的可能
        XCTAssertEqual(body["instructions"] as? String, "SYS")
        XCTAssertEqual(body["input"] as? String, "USER")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
        XCTAssertEqual((body["text"] as? [String: Any])?["verbosity"] as? String, "low")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["prompt_cache_key"] as? String, "mictype-polish-v1")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2048)
        // 推理系模型收到 temperature 直接 400 —— 一次都不许发出去
        XCTAssertNil(body["temperature"])
    }

    func testCommandBodyUsesLowEffortAndItsOwnCacheKey() {
        let body = LLMClient.responsesBody(model: "gpt-5.6-terra", system: "SYS", user: "USER",
                                           purpose: .command, temperature: 1.0,
                                           maxOutputTokens: 4096)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(body["prompt_cache_key"] as? String, "mictype-command-v1")
        // 指令要的是自然的成品文本，不压 verbosity
        XCTAssertNil(body["text"])
        XCTAssertNil(body["temperature"])
    }

    /// gpt-6-astra 不支持 effort none：发了就 400，必须自动退到 low
    func testAstraFallsBackToLowEffortForPolish() {
        let body = LLMClient.responsesBody(model: "gpt-6-astra", system: "SYS", user: "USER",
                                           purpose: .polish, temperature: nil,
                                           maxOutputTokens: 2048)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
    }

    /// 非推理型号（自建网关上的老模型）还是要把用户设的温度发出去
    func testNonReasoningModelKeepsTemperature() {
        let body = LLMClient.responsesBody(model: "gpt-4.1-mini", system: "SYS", user: "USER",
                                           purpose: .polish, temperature: 0.5,
                                           maxOutputTokens: 2048)
        XCTAssertEqual(body["temperature"] as? Double, 0.5)
    }

    // MARK: - chat/completions 请求体

    /// DeepSeek 默认开思考且 effort=high：润色只是改写，白等几秒 → 显式关掉
    func testDeepSeekPolishDisablesThinking() {
        let body = LLMClient.chatBody(model: "deepseek-flash",
                                      messages: [["role": "user", "content": "hi"]],
                                      temperature: 0.5, purpose: .polish, provider: .deepseek)
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual(body["temperature"] as? Double, 0.5)
    }

    /// 指令低频、要质量 → 不碰思考开关，保留服务商默认
    func testDeepSeekCommandLeavesThinkingAlone() {
        let body = LLMClient.chatBody(model: "deepseek-v4-pro",
                                      messages: [["role": "user", "content": "hi"]],
                                      temperature: 1.0, purpose: .command, provider: .deepseek)
        XCTAssertNil(body["thinking"])
        // deepseek-v4-pro 是思考档，同样忽略自定义温度 → 不发
        XCTAssertNil(body["temperature"])
    }

    /// 思考开关是 DeepSeek 专有字段，别的兼容端点收到会 400
    func testThinkingIsNeverSentToOpenAI() {
        let body = LLMClient.chatBody(model: "gpt-4o-mini",
                                      messages: [["role": "user", "content": "hi"]],
                                      temperature: 0.5, purpose: .polish, provider: .openai)
        XCTAssertNil(body["thinking"])
        XCTAssertEqual(body["temperature"] as? Double, 0.5)
    }

    // MARK: - Responses 响应解析

    /// 官方明确警告不要假设 output[0]：推理条目排在 message 前面是常态
    func testOutputTextIsFoundWhenMessageIsNotFirst() {
        let json: [String: Any] = [
            "status": "completed",
            "output": [
                ["type": "reasoning", "summary": []],
                ["type": "web_search_call", "status": "completed"],
                ["type": "message",
                 "content": [["type": "refusal", "refusal": "no"],
                             ["type": "output_text", "text": "  润色后的文本  "]]],
            ],
        ]
        let parsed = LLMClient.parseResponsesPayload(json)
        XCTAssertEqual(parsed.text, "润色后的文本")
        XCTAssertFalse(parsed.truncated)
        XCTAssertNil(parsed.cachedTokens)
    }

    func testMultipleOutputTextPartsAreJoined() {
        let json: [String: Any] = [
            "output": [["type": "message",
                        "content": [["type": "output_text", "text": "前半"],
                                    ["type": "output_text", "text": "后半"]]]],
        ]
        XCTAssertEqual(LLMClient.parseResponsesPayload(json).text, "前半后半")
    }

    func testCachedTokensAreReadFromUsage() {
        let json: [String: Any] = [
            "output": [["type": "message", "content": [["type": "output_text", "text": "ok"]]]],
            "usage": ["input_tokens": 1500,
                      "input_tokens_details": ["cached_tokens": 1024]],
        ]
        XCTAssertEqual(LLMClient.parseResponsesPayload(json).cachedTokens, 1024)
    }

    /// 撞上 max_output_tokens 的半截文本不能当成功交付（会把用户的话截成半句插进去）
    func testTruncatedResponseIsFlagged() {
        let json: [String: Any] = [
            "status": "incomplete",
            "incomplete_details": ["reason": "max_output_tokens"],
            "output": [["type": "message", "content": [["type": "output_text", "text": "半截"]]]],
        ]
        let parsed = LLMClient.parseResponsesPayload(json)
        XCTAssertTrue(parsed.truncated)
        XCTAssertEqual(parsed.text, "半截")
    }

    func testEmptyOrToolOnlyOutputYieldsNoText() {
        XCTAssertNil(LLMClient.parseResponsesPayload(["output": []]).text)
        XCTAssertNil(LLMClient.parseResponsesPayload([:]).text)
        let refusalOnly: [String: Any] = [
            "output": [["type": "message", "content": [["type": "refusal", "refusal": "no"]]]],
        ]
        XCTAssertNil(LLMClient.parseResponsesPayload(refusalOnly).text)
    }

    // MARK: - 400 去参重试

    func testUnsupportedParameterNameIsExtractedFromTheUsualWordings() {
        XCTAssertEqual(LLMClient.unsupportedParameterName(
            in: "Unknown parameter: 'text.verbosity'."), "text.verbosity")
        XCTAssertEqual(LLMClient.unsupportedParameterName(
            in: "Unrecognized request argument supplied: prompt_cache_key"), "prompt_cache_key")
        XCTAssertEqual(LLMClient.unsupportedParameterName(
            in: "Unsupported value: 'reasoning.effort' does not support 'none' with this model."),
                       "reasoning.effort")
        XCTAssertEqual(LLMClient.unsupportedParameterName(
            in: "Invalid parameter: \"thinking\" is not allowed here"), "thinking")
    }

    /// 推理模型拒温度的措辞五花八门，认关键词兜底（3.2.5 起就靠这条）
    func testTemperatureIsRecognisedWithoutAParameterPrefix() {
        XCTAssertEqual(LLMClient.unsupportedParameterName(
            in: "temperature does not support 0.5 with this model"), "temperature")
    }

    /// 看不懂的报错就别再发一趟（UAE 链路每个往返都贵）
    func testUnrelatedErrorMessageYieldsNoParameter() {
        XCTAssertNil(LLMClient.unsupportedParameterName(in: "The server had an error"))
        XCTAssertNil(LLMClient.unsupportedParameterName(in: ""))
    }

    func testStrippingRemovesTopLevelParameter() {
        let body: [String: Any] = ["model": "m", "temperature": 0.5]
        let stripped = LLMClient.stripping(parameter: "temperature", from: body)
        XCTAssertNotNil(stripped)
        XCTAssertNil(stripped?["temperature"])
        XCTAssertEqual(stripped?["model"] as? String, "m")
    }

    /// 点路径：父对象被掏空就连父一起删（留一个空的 "text": {} 有些端点照样 400）
    func testStrippingRemovesNestedParameterAndEmptyParent() {
        let body: [String: Any] = ["model": "m", "text": ["verbosity": "low"]]
        let stripped = LLMClient.stripping(parameter: "text.verbosity", from: body)
        XCTAssertNotNil(stripped)
        XCTAssertNil(stripped?["text"])
    }

    func testStrippingKeepsSiblingsInsideTheParent() {
        let body: [String: Any] = ["reasoning": ["effort": "none", "summary": "auto"]]
        let stripped = LLMClient.stripping(parameter: "reasoning.effort", from: body)
        let reasoning = stripped?["reasoning"] as? [String: Any]
        XCTAssertNil(reasoning?["effort"])
        XCTAssertEqual(reasoning?["summary"] as? String, "auto")
    }

    /// 体里根本没有这个参数 → 返回 nil，调用方就不该重试
    func testStrippingAbsentParameterReturnsNil() {
        XCTAssertNil(LLMClient.stripping(parameter: "temperature", from: ["model": "m"]))
        XCTAssertNil(LLMClient.stripping(parameter: "text.verbosity", from: ["model": "m"]))
        XCTAssertNil(LLMClient.stripping(parameter: "model.nested", from: ["model": "m"]))
    }

    // MARK: - 用量沉淀点

    /// 取走即清空：上一轮的缓存命中绝不能被记到下一轮头上
    func testUsageSinkIsConsumedOnce() {
        LLMUsageSink.shared.record(cachedTokens: 1024)
        XCTAssertEqual(LLMUsageSink.shared.take(), 1024)
        XCTAssertNil(LLMUsageSink.shared.take())
        LLMUsageSink.shared.record(cachedTokens: nil)
        XCTAssertNil(LLMUsageSink.shared.take())
    }

    /// 诊断行里多出的那一格只在真有缓存数字时出现（老记录不会凭空长出字段）
    func testDiagnosticRowShowsCachedTokensOnlyWhenPresent() {
        let withCache = SessionMetric(date: Date(), mode: .dictation, asrMs: 10, polishMs: 20,
                                      insertMs: 30, audioSeconds: 1, partialCount: 0, cold: false,
                                      cachedTokens: 1024)
        XCTAssertTrue(withCache.diagnosticRow.hasSuffix("cached=1024"))
        let without = SessionMetric(date: Date(), mode: .dictation, asrMs: 10, polishMs: 20,
                                    insertMs: 30, audioSeconds: 1, partialCount: 0, cold: false)
        XCTAssertFalse(without.diagnosticRow.contains("cached="))
    }
}
