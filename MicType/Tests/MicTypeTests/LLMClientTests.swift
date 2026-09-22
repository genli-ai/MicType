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

    // DeepSeek 的 `thinking: disabled` 那两条测试随那一档服务商一起删掉（5.0.0）。

    /// 思考开关是 DeepSeek 专有字段，别的兼容端点收到会 400
    func testThinkingIsNeverSentToOpenAI() {
        let body = LLMClient.chatBody(model: "gpt-4o-mini",
                                      messages: [["role": "user", "content": "hi"]],
                                      temperature: 0.5, purpose: .polish, provider: .openai)
        XCTAssertNil(body["thinking"])
        XCTAssertEqual(body["temperature"] as? Double, 0.5)
    }

    /// 阿里云 3.5 线起默认开思考：4.1.1 的日志里 qwen3.8-max 润色 ~25 个字要 3889ms / 8730ms，
    /// 更长的直接撞满 12 s 超时 → 润色这一路必须显式关掉（兼容模式的字段名是 enable_thinking）
    func testQwenPolishDisablesThinking() {
        let body = LLMClient.chatBody(model: "qwen3.8-max",
                                      messages: [["role": "user", "content": "hi"]],
                                      temperature: 0.5, purpose: .polish, provider: .qwen)
        XCTAssertEqual(body["enable_thinking"] as? Bool, false)
        // DeepSeek 的那个字段名不通用，别顺手一起发
        XCTAssertNil(body["thinking"])
    }

    /// 指令也关：人盯着悬浮窗等的一次调用，等不到的质量等于没有质量（DeepSeek 那条政策不照搬）
    func testQwenCommandDisablesThinkingToo() {
        // 4.1.2 给指令留着思考 → 十几个字的指令两次等满 25 s 超时（服务端平均 ~17 s）。
        // 带着联网搜索的那一趟同样要关：搜索结果一进来，思考的 token 只会更多。
        for style in [LLMCatalog.WebSearchStyle.qwenEnableSearch, .unsupported] {
            let body = LLMClient.chatBody(model: "qwen3.8-max",
                                          messages: [["role": "user", "content": "hi"]],
                                          temperature: nil, purpose: .command, provider: .qwen,
                                          searchStyle: style)
            XCTAssertEqual(body["enable_thinking"] as? Bool, false, "style=\(style)")
        }
    }

    /// enable_thinking 是 DashScope 专有字段：别的端点收到只会多一个它不认识的键（有的直接 400）
    func testQwenThinkingSwitchNeverGoesToOtherProviders() {
        let body = LLMClient.chatBody(model: "m", messages: [], temperature: nil,
                                      purpose: .polish, provider: .openai)
        XCTAssertNil(body["enable_thinking"])
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

    /// DashScope 把两个词粘在一起（`InvalidParameter`），中间一个空格都没有。
    /// 4.1.1 把联网搜索改成默认开之后，enable_search / search_options 正是阿里云那一档
    /// 最可能被端点拒掉的字段——认不出参数名就没有"摘掉重发"，整条指令白掉。
    func testDashScopeCamelCaseInvalidParameterIsRecognised() {
        XCTAssertEqual(LLMClient.unsupportedParameterName(
            in: "<400> InternalError.Algo.InvalidParameter: enable_search is not supported"),
                       "enable_search")
        XCTAssertEqual(LLMClient.unsupportedParameterName(
            in: "InvalidParameter: search_options.search_strategy"), "search_options.search_strategy")
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

    /// 4.1.1 的真实回包：一个参数名都没点，通用正则认不出来 → 只能按话题摘。
    /// 这一条是这次 bug 的复现：认不出就不重发，用户那条语音指令整个白掉。
    func testQwenExtrasFallbackDropsBothSearchFields() {
        let body: [String: Any] = ["model": "qwen3.8-max", "enable_search": true,
                                   "search_options": ["search_strategy": "agent"]]
        let fallback = LLMClient.qwenExtrasFallback(
            message: "The current model does not support the \"agent\" search strategy", body: body)
        XCTAssertNil(fallback?.body["enable_search"])
        XCTAssertNil(fallback?.body["search_options"])
        XCTAssertEqual(fallback?.dropped.sorted(), ["enable_search", "search_options"])
        XCTAssertEqual(fallback?.body["model"] as? String, "qwen3.8-max")
    }

    /// 思考开关被拒也是同一回事：摘掉它重发，别让整次润色白掉
    func testQwenExtrasFallbackDropsThinkingSwitch() {
        let body: [String: Any] = ["model": "qwen3.8-max", "enable_thinking": false]
        let fallback = LLMClient.qwenExtrasFallback(
            message: "parameter.enable_thinking is not supported: thinking cannot be disabled",
            body: body)
        XCTAssertEqual(fallback?.dropped, ["enable_thinking"])
        XCTAssertNil(fallback?.body["enable_thinking"])
        // 报错没提搜索 → 搜索字段一个都不动（这一趟只摘被点到的那件事）
        let both: [String: Any] = ["enable_search": true, "enable_thinking": false]
        let onlyThinking = LLMClient.qwenExtrasFallback(message: "thinking is not supported",
                                                        body: both)
        XCTAssertEqual(onlyThinking?.body["enable_search"] as? Bool, true)
    }

    /// 看不懂的 400、或者体里压根没有这些字段 → nil = 不重发（UAE 链路每个往返都贵）
    func testQwenExtrasFallbackReturnsNilWhenNothingToDrop() {
        XCTAssertNil(LLMClient.qwenExtrasFallback(
            message: "The current model does not support the \"agent\" search strategy",
            body: ["model": "qwen3.8-max"]))
        XCTAssertNil(LLMClient.qwenExtrasFallback(
            message: "Range of input length should be [1, 129024]",
            body: ["model": "qwen3.8-max", "enable_search": true, "enable_thinking": false]))
        XCTAssertNil(LLMClient.qwenExtrasFallback(message: "", body: ["enable_search": true]))
    }

    // MARK: - 用量沉淀点

    /// 取走即清空：上一轮的缓存命中 / 来源绝不能被记到下一轮头上
    func testUsageSinkIsConsumedOnce() {
        LLMUsageSink.shared.record(LLMUsage(cachedTokens: 1024, serviceTier: "fast"))
        let taken = LLMUsageSink.shared.take()
        XCTAssertEqual(taken?.cachedTokens, 1024)
        XCTAssertEqual(taken?.serviceTier, "fast")
        XCTAssertNil(LLMUsageSink.shared.take())
    }

    /// 草稿只在真有用量时才被填——"没走大模型"和"值为 0"在这张表里是两回事
    func testDraftAbsorbsUsageOnlyWhenPresent() {
        var draft = SessionMetricDraft(mode: .command, audioSeconds: 1, partialCount: 0, cold: false)
        draft.absorb(nil)
        XCTAssertNil(draft.cachedTokens)
        XCTAssertNil(draft.serviceTier)
        draft.absorb(LLMUsage(cachedTokens: 0, serviceTier: "default"))
        XCTAssertEqual(draft.cachedTokens, 0)
        XCTAssertEqual(draft.serviceTier, "default")
    }

    /// 勾了 fast 却被降回 default 必须看得见：诊断行里要有 tier=
    func testDiagnosticRowShowsActualServiceTier() {
        let metric = SessionMetric(date: Date(), mode: .command, asrMs: 10, polishMs: 20,
                                   insertMs: 30, audioSeconds: 1, partialCount: 0, cold: false,
                                   cachedTokens: nil, serviceTier: "default")
        XCTAssertTrue(metric.diagnosticRow.contains("tier=default"))
        let plain = SessionMetric(date: Date(), mode: .command, asrMs: 10, polishMs: 20,
                                  insertMs: 30, audioSeconds: 1, partialCount: 0, cold: false)
        XCTAssertFalse(plain.diagnosticRow.contains("tier="))
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

    // MARK: - Fast 档与联网搜索（B7 / B8 / B11）

    /// 这一趟该不该问 Fast 档。4.1.6 起它不是一条设置，是一条规则——**规则就得有测试**，
    /// 否则"哪些请求会贵一倍"这件事在代码里没有任何一处说得死。
    func testFastTierGoesOnlyToTheOfficialOpenAIEndpoint() {
        // 官方域名 + OpenAI 档：发
        XCTAssertTrue(LLMClient.asksForFastTier(provider: .openai,
                                                baseURL: "https://api.openai.com/v1",
                                                model: "gpt-5.6-sol", refusedModels: []))
        // 同一档但地址指向第三方网关：**一个字都不发**。发了的结果是每句话先白挨一个 400，
        // 再摘掉参数重发——UAE 这条链路上那就是每句话多等半秒到一秒五
        XCTAssertFalse(LLMClient.asksForFastTier(provider: .openai,
                                                 baseURL: "https://gateway.example.com/v1",
                                                 model: "gpt-5.6-sol", refusedModels: []))
        // 别家一律不发（service_tier 是 OpenAI 的字段）
        XCTAssertFalse(LLMClient.asksForFastTier(provider: .qwen,
                                                 baseURL: "https://api.openai.com/v1",
                                                 model: "m", refusedModels: []))
        // 判据必须和"走不走 Responses"是同一条：两处分家的那天，这条断言会先红
        for url in ["https://api.openai.com/v1", "https://gateway.example.com/v1",
                    "http://localhost:11434/v1", ""] {
            XCTAssertEqual(LLMClient.asksForFastTier(provider: .openai, baseURL: url,
                                                     model: "gpt-5.6-sol", refusedModels: []),
                           LLMClient.usesResponsesAPI(baseURL: url), url)
        }
    }

    /// 这一轮拒过的型号不再问。大小写与空白不该算成两个型号
    func testFastTierIsNotAskedAgainForARefusedModel() {
        XCTAssertFalse(LLMClient.asksForFastTier(provider: .openai,
                                                 baseURL: "https://api.openai.com/v1",
                                                 model: "gpt-5.6-sol",
                                                 refusedModels: ["gpt-5.6-sol"]))
        XCTAssertFalse(LLMClient.asksForFastTier(provider: .openai,
                                                 baseURL: "https://api.openai.com/v1",
                                                 model: "  GPT-5.6-Sol ",
                                                 refusedModels: ["gpt-5.6-sol"]))
        // 拒的是那一个型号，不是整档：换个型号照常问
        XCTAssertTrue(LLMClient.asksForFastTier(provider: .openai,
                                                baseURL: "https://api.openai.com/v1",
                                                model: "gpt-5.6-luna",
                                                refusedModels: ["gpt-5.6-sol"]))
    }

    /// 400 点名的参数是不是"这个型号不吃 Fast 档"。点路径式的写法只认最后那一段
    func testRefusalIsRecognizedFromTheStrippedParameterName() {
        XCTAssertTrue(LLMClient.refusesFastTier(parameter: "service_tier"))
        XCTAssertTrue(LLMClient.refusesFastTier(parameter: " SERVICE_TIER "))
        XCTAssertTrue(LLMClient.refusesFastTier(parameter: "body.service_tier"))
        for other in ["temperature", "text.verbosity", "reasoning.effort", "enable_search", ""] {
            XCTAssertFalse(LLMClient.refusesFastTier(parameter: other), other)
        }
    }

    /// 记忆本身：只记一次（调用方靠返回值决定记不记日志），空型号名不占位置
    func testFastTierMemoryRemembersEachModelOnce() {
        let memory = FastTierMemory.shared
        memory.forgetAll()
        defer { memory.forgetAll() }
        XCTAssertTrue(memory.remember(model: "gpt-5.6-sol"))
        XCTAssertFalse(memory.remember(model: "gpt-5.6-sol"))
        XCTAssertFalse(memory.remember(model: " GPT-5.6-SOL "))
        XCTAssertFalse(memory.remember(model: "   "))
        XCTAssertEqual(memory.models, ["gpt-5.6-sol"])
        XCTAssertFalse(LLMClient.asksForFastTier(provider: .openai,
                                                 baseURL: "https://api.openai.com/v1",
                                                 model: "gpt-5.6-sol",
                                                 refusedModels: memory.models))
    }

    /// 传 true 才发 service_tier（请求体这一层的形状没变，变的是谁来决定那个 true）
    func testFastTierIsOptInOnly() {
        let plain = LLMClient.responsesBody(model: "gpt-5.6-luna", system: "S", user: "U",
                                            purpose: .polish, temperature: nil, maxOutputTokens: 2048)
        XCTAssertNil(plain["service_tier"])
        let fast = LLMClient.responsesBody(model: "gpt-5.6-luna", system: "S", user: "U",
                                           purpose: .polish, temperature: nil, maxOutputTokens: 2048,
                                           fastTier: true)
        XCTAssertEqual(fast["service_tier"] as? String, "fast")
    }

    /// service_tier 是 OpenAI 的字段：别的服务商收到只会多一个它不认识的键
    func testFastTierOnlyGoesToOpenAIOnChatCompletions() {
        let qwen = LLMClient.chatBody(model: "qwen3.8-flash", messages: [], temperature: nil,
                                      purpose: .polish, provider: .qwen, fastTier: true)
        XCTAssertNil(qwen["service_tier"])
        let openai = LLMClient.chatBody(model: "gpt-5.6-luna", messages: [], temperature: nil,
                                        purpose: .polish, provider: .openai, fastTier: true)
        XCTAssertEqual(openai["service_tier"] as? String, "fast")
    }

    /// 开着搜索开关的指令调用：工具与 tool_choice 一个都不能少
    func testCommandWebSearchToolShape() {
        let body = LLMClient.responsesBody(model: "gpt-5.6-terra", system: "S", user: "U",
                                           purpose: .command, temperature: nil, maxOutputTokens: 4096,
                                           searchStyle: .openaiResponsesTool,
                                           userLocation: ["type": "approximate", "country": "AE",
                                                          "timezone": "Asia/Dubai"])
        let tools = body["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["type"] as? String, "web_search")
        XCTAssertEqual(tools?.first?["search_context_size"] as? String, "low")
        XCTAssertEqual((tools?.first?["user_location"] as? [String: String])?["country"], "AE")
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        // include: web_search_call.action.sources **故意不发**：那是"搜索工具打开过的页面"，
        // 与 annotations 的"模型引用的来源"不是一回事，解析器也只认后者。
        // 发了等于每次回包都大一截却没人读（要改成显示"搜索过的页面"再单独加字段）。
        XCTAssertNil(body["include"])
    }

    /// 关着搜索时请求体里连 tools 这个键都没有（B8 的验收标准）
    func testWebSearchOffMeansNoToolsAtAll() {
        let body = LLMClient.responsesBody(model: "gpt-5.6-terra", system: "S", user: "U",
                                           purpose: .command, temperature: nil, maxOutputTokens: 4096)
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["include"])
    }

    /// **铁律**：润色路径永不联网。就算调用方把搜索写法传进来，润色的请求体里也不许出现工具——
    /// 润色是"改写我刚说的话"，联网既没用又按次花钱。
    func testPolishNeverGetsSearchTools() {
        let body = LLMClient.responsesBody(model: "gpt-5.6-luna", system: "S", user: "U",
                                           purpose: .polish, temperature: nil, maxOutputTokens: 2048,
                                           searchStyle: .openaiResponsesTool)
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["include"])
    }

    /// 同一条铁律在入口那一层也钉住：润色永远拿不到 .unsupported 以外的写法
    func testSearchStyleForPolishIsAlwaysUnsupported() {
        // 5.0.0 起联网搜索永远开着（没有开关），所以这条铁律只剩"润色那一路不发"这一半
        XCTAssertEqual(LLMClient.searchStyle(for: .polish), .unsupported)
    }

    /// Qwen 走 body 字段，OpenRouter 走 plugins，不支持的那一档什么都没有
    func testChatWebSearchShapesPerProvider() {
        let qwen = LLMClient.chatBody(model: "qwen3.8-max", messages: [], temperature: nil,
                                      purpose: .command, provider: .qwen,
                                      searchStyle: .qwenEnableSearch)
        XCTAssertEqual(qwen["enable_search"] as? Bool, true)
        // search_options **一个字都不发**：4.1.1 硬写 search_strategy=agent，qwen3.8-max 直接 400
        //（`The current model does not support the "agent" search strategy`）→ 整条指令白掉。
        // 默认的 turbo 每条模型线都认，agent 式搜索只在 DashScope 的 Responses API 上有。
        XCTAssertNil(qwen["search_options"])
        XCTAssertNil(qwen["plugins"])

        let router = LLMClient.chatBody(model: "anything", messages: [], temperature: nil,
                                        purpose: .command, provider: .openai,
                                        searchStyle: .openrouterPlugin)
        XCTAssertEqual((router["plugins"] as? [[String: String]])?.first?["id"], "web")
        XCTAssertNil(router["enable_search"])

        let none = LLMClient.chatBody(model: "gpt-5.6-luna", messages: [], temperature: nil,
                                      purpose: .command, provider: .openai,
                                      searchStyle: .unsupported)
        XCTAssertNil(none["enable_search"])
        XCTAssertNil(none["plugins"])
    }

    // MARK: - chat/completions 的输出上限与截断

    /// 这条路也必须发输出上限：不发就跑服务商自己的默认额度，而 v4.0 的长口述（最长 600 s）
    /// 润色出来的文本轻松越过那条线——这边没有 Responses 的 status=incomplete 可以兜底
    func testChatBodyCarriesMaxTokens() {
        let body = LLMClient.chatBody(model: "qwen3.8-flash", messages: [], temperature: nil,
                                      purpose: .polish, provider: .qwen, maxOutputTokens: 8192)
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        let bare = LLMClient.chatBody(model: "qwen3.8-flash", messages: [], temperature: nil,
                                      purpose: .polish, provider: .qwen)
        XCTAssertNil(bare["max_tokens"])
    }

    /// finish_reason == "length" 与 Responses 的 status == "incomplete" 是同一件事：
    /// 半截文本绝不能当成功交付（以前这条路只看 content，截断的润色被直接插进用户文档）
    func testChatTruncationIsDetected() {
        let json: [String: Any] = [
            "choices": [["finish_reason": "length",
                         "message": ["role": "assistant", "content": "只写到一半的邮件"]]],
        ]
        let payload = LLMClient.parseChatPayload(json)
        XCTAssertTrue(payload.truncated)
        XCTAssertEqual(payload.text, "只写到一半的邮件")
        XCTAssertFalse(payload.unparsable)
    }

    /// 正常收尾的回包照常交付，并把档位与来源一起带出来
    func testChatPayloadCarriesTextTierAndCitations() {
        let json: [String: Any] = [
            "service_tier": "default",
            "choices": [["finish_reason": "stop",
                         "message": ["content": "  答案  ",
                                     "annotations": [["type": "url_citation",
                                                      "url": "https://src.example/1",
                                                      "title": "来源一"]]]]],
        ]
        let payload = LLMClient.parseChatPayload(json)
        XCTAssertEqual(payload.text, "答案")
        XCTAssertFalse(payload.truncated)
        XCTAssertEqual(payload.serviceTier, "default")
        XCTAssertEqual(payload.citations.first?.url, "https://src.example/1")
    }

    /// 「回了个空串」和「压根解析不出来」是两种毛病，话术不同，所以解析层就要分开
    func testChatEmptyContentAndUnparsableAreDifferent() {
        let empty = LLMClient.parseChatPayload([
            "choices": [["finish_reason": "stop", "message": ["content": "   "]]],
        ])
        XCTAssertNil(empty.text)
        XCTAssertFalse(empty.unparsable)

        let broken = LLMClient.parseChatPayload(["choices": [["finish_reason": "stop"]]])
        XCTAssertNil(broken.text)
        XCTAssertTrue(broken.unparsable)
    }

    // MARK: - 来源解析

    /// 两种形状都要认（扁平的和套一层 url_citation 的），并且按 url 去重
    func testURLCitationsAreParsedAndDeduplicated() {
        let annotations: [[String: Any]] = [
            ["type": "url_citation", "url": "https://a.example/x", "title": "A"],
            ["type": "url_citation", "url_citation": ["url": "https://b.example/y", "title": "B"]],
            ["type": "url_citation", "url": "https://a.example/x", "title": "A again"],
            ["type": "file_citation", "url": "https://c.example/z"],
        ]
        let citations = LLMClient.parseURLCitations(annotations)
        XCTAssertEqual(citations.map(\.url), ["https://a.example/x", "https://b.example/y"])
        XCTAssertEqual(citations.first?.title, "A")
    }

    /// 标题为空时拿域名顶上（列表里一行空白比域名难用得多）；非 http 一律不做成可点链接
    func testCitationDisplayTitleAndClickability() {
        XCTAssertEqual(Citation(title: "  ", url: "https://news.example/a").displayTitle, "news.example")
        XCTAssertNotNil(Citation(title: "t", url: "https://news.example/a").clickableURL)
        XCTAssertNil(Citation(title: "t", url: "javascript:alert(1)").clickableURL)
    }

    /// 完整回包：正文在 message 里，来源在 output_text 的 annotations 上，档位在顶层
    func testResponsesPayloadCarriesCitationsAndServiceTier() {
        let json: [String: Any] = [
            "status": "completed",
            "service_tier": "default",
            "output": [
                ["type": "web_search_call", "action": ["type": "search"]],
                ["type": "message", "content": [
                    ["type": "output_text", "text": "答案",
                     "annotations": [["type": "url_citation",
                                      "url": "https://src.example/1", "title": "来源一"]]],
                ]],
            ],
        ]
        let payload = LLMClient.parseResponsesPayload(json)
        XCTAssertEqual(payload.text, "答案")
        XCTAssertEqual(payload.serviceTier, "default")
        XCTAssertEqual(payload.citations.count, 1)
        XCTAssertEqual(payload.citations.first?.url, "https://src.example/1")
    }

    /// 没联网的普通回包不该凭空长出来源
    func testPlainResponseHasNoCitations() {
        let json: [String: Any] = [
            "output": [["type": "message", "content": [["type": "output_text", "text": "hi"]]]],
        ]
        let payload = LLMClient.parseResponsesPayload(json)
        XCTAssertTrue(payload.citations.isEmpty)
        XCTAssertNil(payload.serviceTier)
    }

    /// OpenRouter 的来源挂在 chat 的 message.annotations 上（同一个解析器要能兼容）
    func testChatMessageAnnotationsUseTheSameParser() {
        let annotations: [[String: Any]] = [["type": "url_citation",
                                             "url": "https://r.example/1", "title": "R"]]
        XCTAssertEqual(LLMClient.parseURLCitations(annotations).count, 1)
    }

    // MARK: - 历史里的来源

    /// 老的 history.json 没有 citations 这个键：解不出来就等于 200 条历史全丢了
    func testHistoryItemDecodesOldRecordsWithoutCitations() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","date":0,"raw":"a","polished":"b"}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(HistoryItem.self, from: legacy)
        XCTAssertEqual(item.polished, "b")
        XCTAssertTrue(item.citations.isEmpty)
    }

    /// 新记录编码后再解回来，来源一条不少
    func testHistoryItemRoundTripsCitations() throws {
        let item = HistoryItem(date: Date(timeIntervalSince1970: 0), raw: "a", polished: "b",
                               citations: [Citation(title: "T", url: "https://x.example/1")])
        let data = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(HistoryItem.self, from: data)
        XCTAssertEqual(back.citations, item.citations)
    }
}
