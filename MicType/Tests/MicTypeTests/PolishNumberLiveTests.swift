import XCTest
@testable import MicType

// MARK: - 真·联网验收：数字写法（4.1.6 起，4.2.1 扩到列表 / 时间 / 英文）
//
// 这一条回答的是单测回答不了的那个问题：**模型真的会照第 7 条把数字写成阿拉伯数字吗，
// 而保真校验放不放行？** 提示词改了没人验，等于没改；归一化写对了但模型不配合，
// 用户看到的还是「一百零一人民币」或者一句「润色结果与原文出入过大」。
//
// 默认**不跑**（LLM 输出有随机性，门禁不该绑在它上面），要两个条件：
//   • 环境变量 MICTYPE_LIVE_POLISH=1
//   • Key（**永远不 print**）：
//       阿里云 —— MICTYPE_QWEN_TEST_KEY 或 ~/.config/mictype/qwen_test_key
//       OpenAI —— MICTYPE_OPENAI_TEST_KEY 或 ~/.config/mictype/openai_test_key
//     OpenAI 那半边没有 Key 就单独跳过（用户实际在用的是 gpt-5.6-luna，有 Key 时最该跑的就是它）。
//
// 跑法（xcodebuild 要用 TEST_RUNNER_ 前缀把环境变量传进测试进程）：
//   TEST_RUNNER_MICTYPE_LIVE_POLISH=1 xcodebuild test -scheme MicType \
//     -destination 'platform=macOS,arch=arm64' -derivedDataPath .xcbuild \
//     -only-testing:MicTypeTests/PolishNumberLiveTests
//
// 代价：每个服务商 10 次短请求，合计几分钱。
final class PolishNumberLiveTests: XCTestCase {

    /// 阿里云国际站的兼容模式接口——润色走的就是这条路
    private static let qwenEndpoint = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
    private static let qwenModel = "qwen3.8-flash"
    /// OpenAI 官方端点 + 用户实际在用的型号（润色走 Responses）
    private static let openAIEndpoint = "https://api.openai.com/v1/responses"
    private static let openAIModel = "gpt-5.6-luna"

    /// 十句验收语料：左边是本机识别模型真会吐出来的样子，右边是成品里必须出现的东西
    /// （nil = 这一句本来就不该出现新数字，只验保真校验放行）
    private static let cases: [(raw: String, expect: String?)] = [
        ("一共是一百零一人民币然后运费另外算十二块五", "101"),
        ("我是二零一一年毕业的然后二零一九年三月十五号来的", "2011"),
        ("下午三点半开会大概两三个人参加十分重要你们千万别迟到", "3点半"),
        ("增长了百分之二十左右大概有一万二千个用户其中三分之一是付费的", "20%"),
        ("电话是幺三八零零幺三八零零零房间号是二零一八", "13800138000"),
        ("第一次来万一迟到了你先等我一下我们一起走", nil),
        ("版本四点一点六修了三个问题跑了七百三十二个测试", "732"),
        // 4.2.1 新增三条：编号列表 / 时间 / 英文数字——正是用户日志里回退的那三类
        ("这个项目现在有几个问题嗯首先是时间太紧我们原来定的是这个月底但是现在看起来肯定来不及"
         + "然后就是人手也不够本来说好的两个人现在只有一个人还有就是预算这块其实已经超了一些了"
         + "所以我的想法是要么我们把范围砍一砍要么就往后推一推大概就是这个意思你看一下", nil),
        ("明天下午一点开会三点十分结束后天下午三点半再碰一次", "1点"),
        ("it costs twenty five dollars we'll meet on March third and three people are coming", "25"),
    ]

    // MARK: - Key（永远不 print、不写日志、不落盘）

    private func liveKey(env: String, file: String) -> String? {
        let fromEnv = (ProcessInfo.processInfo.environment[env] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromEnv.isEmpty { return fromEnv }
        let path = NSHomeDirectory() + "/.config/mictype/" + file
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func requireLiveRun() throws {
        guard ProcessInfo.processInfo.environment["MICTYPE_LIVE_POLISH"] == "1" else {
            throw XCTSkip("需要 MICTYPE_LIVE_POLISH=1 才跑（会真的调用模型、真的花钱）")
        }
    }

    // MARK: - 两条真实链路

    /// 阿里云：chat/completions。系统提示词取**线上那一份**，原文照样用定界块包住
    private func polishWithQwen(_ raw: String, key: String) throws -> String {
        let body: [String: Any] = [
            "model": Self.qwenModel,
            // qwen3.5–3.8 默认开思考，润色必须关掉（4.1.2 踩过）
            "enable_thinking": false,
            "messages": [
                ["role": "system", "content": PolishService.systemPrompt(for: .smart)],
                ["role": "user", "content": "<<<原文>>>\n" + raw + "\n<<<结束>>>"],
            ],
        ]
        let json = try post(Self.qwenEndpoint, body: body, key: key)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MTError("unparseable qwen response")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// OpenAI：Responses。请求体直接用 App 自己那份 `LLMClient.responsesBody`——
    /// 复制一份到测试里的话，线上改了参数这条验收照样绿，那就白验了
    private func polishWithOpenAI(_ raw: String, key: String) throws -> String {
        let body = LLMClient.responsesBody(
            model: Self.openAIModel,
            system: PolishService.systemPrompt(for: .smart),
            user: "<<<原文>>>\n" + raw + "\n<<<结束>>>",
            purpose: .polish,
            temperature: nil,
            maxOutputTokens: LLMCatalog.maxOutputTokens(inputCharacters: raw.count,
                                                        minimum: LLMCatalog.polishMinOutputTokens))
        let json = try post(Self.openAIEndpoint, body: body, key: key)
        let payload = LLMClient.parseResponsesPayload(json)
        guard let text = payload.text else { throw MTError("unparseable openai response") }
        return text
    }

    private func post(_ endpoint: String, body: [String: Any], key: String) throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: endpoint)))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var parsed: [String: Any] = [:]
        var failure: String?
        let waiter = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { waiter.signal() }
            if let error = error { failure = error.localizedDescription; return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data = data else { failure = "HTTP \(status)"; return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                failure = "unparseable response"
                return
            }
            parsed = json
        }.resume()
        _ = waiter.wait(timeout: .now() + 100)
        if let failure = failure { throw MTError(failure) }
        return parsed
    }

    // MARK: - 验收

    /// 这条验收要钉的是**校验与模型的配合**，不是"模型每次都听话"。
    ///
    /// 4.2.2 之前它把两件事混成一条：期望的数字串没出现就算失败，然后**不管有没有出现**
    /// 都要求校验放行——于是模型真的把数改错的那一次（2026-09-21：luna 把 13800138000
    /// 写成 138013800，校验按 missing=2 拦下）被判成红灯，而那恰恰是校验**做对了**的一次。
    /// 那是真阳性，不是回归。
    ///
    /// 所以改成按实际产出分两支：
    ///   • 数字照做了 → 校验**必须放行**（不许误伤听话的模型）；
    ///   • 数字没照做 → 校验**必须拦下**（改了数就不能放进输入框）。
    /// 两支都红不了，才说明这条链路是对的。
    private func check(_ label: String, polish: (String) throws -> String) rethrows {
        for (raw, expect) in Self.cases {
            let polished = try polish(raw)
            let drift = TextPostProcessor.polishDriftCheck(raw: raw, polished: polished)
            print("live polish [\(label)]:\n  raw      = \(raw)\n  polished = \(polished)"
                  + "\n  guard    = \(drift ?? "passed")")
            guard let expect = expect else {
                // 没有期望数字串的用例（纯文字那几条）：校验照样不该拦
                XCTAssertNil(drift, "保真校验不该拦这一句：\(polished)")
                continue
            }
            if polished.contains(expect) {
                XCTAssertNil(drift, "模型照做了，保真校验不该拦这一句：\(polished)")
            } else {
                XCTAssertNotNil(drift, """
                    模型没有写出「\(expect)」，而保真校验放行了——**这才是真正的故障**：
                    一句数字被改过的稿子会就这么进用户的输入框。
                    成品：\(polished)
                    """)
            }
        }
    }

    func testQwenWritesArabicNumeralsAndTheGuardLetsThemThrough() throws {
        try requireLiveRun()
        guard let key = liveKey(env: "MICTYPE_QWEN_TEST_KEY", file: "qwen_test_key") else {
            throw XCTSkip("需要 MICTYPE_QWEN_TEST_KEY 或 ~/.config/mictype/qwen_test_key")
        }
        try check("qwen") { try polishWithQwen($0, key: key) }
    }

    /// 用户实际在用的那一档。没有 Key 就干净地跳过——这个文件现在还不存在
    func testOpenAIWritesArabicNumeralsAndTheGuardLetsThemThrough() throws {
        try requireLiveRun()
        guard let key = liveKey(env: "MICTYPE_OPENAI_TEST_KEY", file: "openai_test_key") else {
            throw XCTSkip("需要 MICTYPE_OPENAI_TEST_KEY 或 ~/.config/mictype/openai_test_key")
        }
        try check("openai") { try polishWithOpenAI($0, key: key) }
    }
}
