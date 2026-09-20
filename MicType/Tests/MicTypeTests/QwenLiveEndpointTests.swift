import XCTest
@testable import MicType

// MARK: - 真·联网测试（没有 Key 就跳过）
//
// 为什么非有不可（4.1.5 的来由）：4.1.4 的接入地址探测只问了 `GET /models`，单测全绿、
// 假发送器全绿，而第一次拿真 Key 跑就崩了——新建的工作空间 Key 在那台主机上
// /models 回 200、chat 与识别都回 403。**假发送器永远测不出"这台主机肯不肯干活"**，
// 只有真的发一次才知道。所以这一条走完整条链路：试出主机 → 真发一次 chat → 真发一次识别。
//
// Key 从哪儿来（两条，都不进仓库、不进日志、不 print）：
//   • 环境变量 MICTYPE_QWEN_TEST_KEY
//   • 文件 ~/.config/mictype/qwen_test_key（整个文件就是一把 Key，首尾空白会被去掉）
// 两条都没有就 XCTSkip——CI 与日常 `xcodebuild test` 因此一分钱都不会花。
//
// 只跑这一条：
//   xcodebuild test -scheme MicType -destination 'platform=macOS,arch=arm64' \
//     -derivedDataPath .xcbuild -only-testing:MicTypeTests/QwenLiveEndpointTests
//
// 代价：一次 max_tokens=1 的 chat（几个 token）+ 1 秒合成音的识别（约 $0.000035）。
final class QwenLiveEndpointTests: XCTestCase {

    /// 拿到那把 Key。**永远不 print、不写日志、不落盘**——这里只把它当参数传出去。
    private var liveKey: String? {
        let env = ProcessInfo.processInfo.environment["MICTYPE_QWEN_TEST_KEY"] ?? ""
        let fromEnv = env.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromEnv.isEmpty { return fromEnv }
        let path = NSHomeDirectory() + "/.config/mictype/qwen_test_key"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 同步发一次请求，只取状态码与服务端错误码（与 defaultSend 同一套解析，
    /// 但这里要等结果，所以自己转一次信号量）
    private func send(_ request: URLRequest, timeout: TimeInterval = 30) -> (status: Int, code: String?) {
        var out: (Int, String?) = (0, nil)
        let waiter = DispatchSemaphore(value: 0)
        AlibabaHostResolver.defaultSend(request) { status, code, _ in
            out = (status, code)
            waiter.signal()
        }
        _ = waiter.wait(timeout: .now() + timeout)
        return out
    }

    /// 整条链路：试出主机（含确认那一轮）→ 真发一次 chat → 真发一次识别。
    ///
    /// 断言的核心就一句：**试出来的那台主机真的能干活**。4.1.4 的洞正是"能被试出来"
    /// 与"能干活"是两件事，而只有这一条测试站在能发现它的位置上。
    func testResolvedHostActuallyServesChatAndSpeech() throws {
        guard let key = liveKey else {
            throw XCTSkip("需要 MICTYPE_QWEN_TEST_KEY 或 ~/.config/mictype/qwen_test_key 才跑（会真的花钱）")
        }
        let candidates = AlibabaEndpoint.candidates(apiKey: key)
        print("live: candidates=\(candidates.map(AlibabaEndpoint.redacted).joined(separator: ", "))")

        // 1) 试出接入地址（并发 /models + 按排名逐台确认）。
        // 自己包一层 defaultSend 只为**把每一趟都打印出来**：Log 在 xcodebuild 里写进
        // 测试运行器的临时目录，翻起来费劲，而"哪台通过了 /models、哪台确认时被拒"
        // 正是这条测试唯一值得看的东西。请求本身一趟都没多发。
        var resolved: String?
        let done = expectation(description: "resolve")
        AlibabaHostResolver.resolve(
            apiKey: key, candidates: candidates,
            confirmModel: LLMCatalog.qwenDefaultModel,
            send: { request, completion in
                let host = AlibabaEndpoint.redacted(request.url?.host ?? "?")
                let stage = request.url?.path.hasSuffix("/models") == true ? "try" : "confirm"
                let sentAt = DispatchTime.now()
                AlibabaHostResolver.defaultSend(request) { status, code, _ in
                    print("live: \(stage) host=\(host) status=\(status) "
                          + "code=\(code ?? "-") ms=\(Log.ms(since: sentAt))")
                    completion(status, code, nil)
                }
            }) { result in
            switch result {
            case .success(let host):
                resolved = host
            case .failure(let failure):
                XCTFail("一台都没试出来：status=\(failure.status) code=\(failure.code ?? "-") "
                        + failure.message)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        let host = try XCTUnwrap(resolved)
        print("live: resolved host=\(AlibabaEndpoint.redacted(host))")

        // 2) 真发一次 chat——这就是润色与指令走的那条路
        var chat = URLRequest(url: try XCTUnwrap(AlibabaEndpoint.chatCompletionsURL(host: host)))
        chat.httpMethod = "POST"
        chat.timeoutInterval = 30
        chat.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
        chat.httpBody = try JSONSerialization.data(
            withJSONObject: AlibabaHostResolver.confirmBody(model: LLMCatalog.qwenDefaultModel))
        let chatResult = send(chat)
        print("live: chat host=\(AlibabaEndpoint.redacted(host)) status=\(chatResult.status) "
              + "code=\(chatResult.code ?? "-")")
        XCTAssertEqual(chatResult.status, 200,
                       "试出来的主机必须真的能干活——这正是 4.1.4 漏掉的那一步")

        // 3) 真发一次识别（1 秒合成音；模型 404 时自动换 qwen3-asr-flash 那条路也一起走了）
        let config = CloudASRConfig(provider: .alibaba, host: host, apiKey: key)
        let asrDone = expectation(description: "asr")
        CloudASRProbe.runTryingModels(config: config,
                                      models: config.alibabaModel.fallbackOrder) { result in
            switch result {
            case .success(let outcome):
                print("live: asr host=\(AlibabaEndpoint.redacted(host)) "
                      + "model=\(outcome.model ?? "-") ms=\(outcome.milliseconds)")
            case .failure(let failure):
                XCTFail("识别端点不通：status=\(failure.status) code=\(failure.code ?? "-") "
                        + failure.message)
            }
            asrDone.fulfill()
        }
        wait(for: [asrDone], timeout: 120)
    }
}
