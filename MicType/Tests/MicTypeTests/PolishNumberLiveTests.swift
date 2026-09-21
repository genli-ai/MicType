import XCTest
@testable import MicType

// MARK: - 真·联网验收：数字写法（4.1.6）
//
// 这一条回答的是单测回答不了的那个问题：**模型真的会照第 7 条把汉字数字写成阿拉伯数字吗，
// 而保真校验放不放行？** 提示词改了没人验，等于没改；归一化写对了但模型不配合，
// 用户看到的还是「一百零一人民币」。
//
// 默认**不跑**（LLM 输出有随机性，门禁不该绑在它上面），要两个条件：
//   • 环境变量 MICTYPE_LIVE_POLISH=1
//   • Key：MICTYPE_QWEN_TEST_KEY 或 ~/.config/mictype/qwen_test_key（**永远不 print**）
//
// 跑法（xcodebuild 要用 TEST_RUNNER_ 前缀把环境变量传进测试进程）：
//   TEST_RUNNER_MICTYPE_LIVE_POLISH=1 xcodebuild test -scheme MicType \
//     -destination 'platform=macOS,arch=arm64' -derivedDataPath .xcbuild \
//     -only-testing:MicTypeTests/PolishNumberLiveTests
//
// 代价：7 次 qwen3.8-flash 的短请求，合计不到一分钱。
final class PolishNumberLiveTests: XCTestCase {

    /// 阿里云国际站的兼容模式接口——润色走的就是这条路
    private static let endpoint = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
    private static let model = "qwen3.8-flash"

    /// 拿到那把 Key。**永远不 print、不写日志、不落盘**
    private var liveKey: String? {
        let env = (ProcessInfo.processInfo.environment["MICTYPE_QWEN_TEST_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !env.isEmpty { return env }
        let path = NSHomeDirectory() + "/.config/mictype/qwen_test_key"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 发一次真的润色请求，返回模型吐出来的成品文本
    private func polish(_ raw: String, key: String) throws -> String {
        var request = URLRequest(url: try XCTUnwrap(URL(string: Self.endpoint)))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 系统提示词取**线上那一份**（PolishService.systemPrompt），原文照样用定界块包住，
        // 与 PolishService.polish 逐字一致；qwen3.5–3.8 默认开思考，润色必须关掉
        let body: [String: Any] = [
            "model": Self.model,
            "enable_thinking": false,
            "messages": [
                ["role": "system", "content": PolishService.systemPrompt(for: .smart)],
                ["role": "user", "content": "<<<原文>>>\n" + raw + "\n<<<结束>>>"],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var output = ""
        var failure: String?
        let waiter = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { waiter.signal() }
            if let error = error { failure = error.localizedDescription; return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data = data else { failure = "HTTP \(status)"; return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                failure = "unparseable response"
                return
            }
            output = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }.resume()
        _ = waiter.wait(timeout: .now() + 70)
        if let failure = failure { throw MTError(failure) }
        return output
    }

    /// 七句实测语料：左边是本机识别模型真会吐出来的样子（汉字数字），
    /// 右边是这一版必须在成品里看到的阿拉伯数字（nil = 这一句本来就不该出现数字）
    func testPolishWritesArabicNumeralsAndTheGuardLetsThemThrough() throws {
        guard ProcessInfo.processInfo.environment["MICTYPE_LIVE_POLISH"] == "1" else {
            throw XCTSkip("需要 MICTYPE_LIVE_POLISH=1 才跑（会真的调用模型、真的花钱）")
        }
        guard let key = liveKey else {
            throw XCTSkip("需要 MICTYPE_QWEN_TEST_KEY 或 ~/.config/mictype/qwen_test_key")
        }

        let cases: [(raw: String, expect: String?)] = [
            ("一共是一百零一人民币然后运费另外算十二块五", "101"),
            ("我是二零一一年毕业的然后二零一九年三月十五号来的", "2011"),
            ("下午三点半开会大概两三个人参加十分重要你们千万别迟到", "3点半"),
            ("增长了百分之二十左右大概有一万二千个用户其中三分之一是付费的", "20%"),
            ("电话是幺三八零零幺三八零零零房间号是二零一八", "13800138000"),
            ("第一次来万一迟到了你先等我一下我们一起走", nil),
            ("版本四点一点六修了三个问题跑了七百三十二个测试", "732"),
        ]

        for (raw, expect) in cases {
            let polished = try polish(raw, key: key)
            print("live polish:\n  raw      = \(raw)\n  polished = \(polished)")
            if let expect = expect {
                XCTAssertTrue(polished.contains(expect),
                              "成品里应该出现「\(expect)」：\(polished)")
            }
            // 这才是重点：模型照做之后，保真校验必须放行——4.1.5 会把每一句都判成 digits changed
            XCTAssertNil(TextPostProcessor.polishDriftCheck(raw: raw, polished: polished),
                         "保真校验不该拦这一句：\(polished)")
        }
    }
}
