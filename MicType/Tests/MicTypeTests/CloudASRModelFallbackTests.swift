import XCTest
@testable import MicType

/// 「这个端点上没有这个识别模型」之后该怎么办。
///
/// 现场：4.0.0 的默认识别模型是 qwen-audio-3.0-asr-flash，而官方文档里同步端点
/// （/api/v1/services/aigc/multimodal-generation/generation）上只有 qwen3-asr-flash——
/// 3.0 属于「非实时语音识别」那条异步链路。于是任何人点「测试识别」都是一次 404。
/// 改默认值救得了新用户，救不了设置里存着旧值的老用户，所以还要有这条自动回落。
///
/// 这里不碰网络：假发送器直接回 404 / 200。
final class CloudASRModelFallbackTests: XCTestCase {

    private func config() -> CloudASRConfig {
        CloudASRConfig(provider: .alibaba, alibabaModel: .qwenAudio30Flash,
                       host: "ws-abc.cn-beijing.maas.aliyuncs.com", apiKey: "sk-ws-abc.zzz")
    }

    /// 模型名从请求体里读出来——回落到底换没换模型，只有这里看得见
    private func modelName(of request: URLRequest) -> String {
        guard let body = request.httpBody,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return "?" }
        return (json["model"] as? String) ?? "?"
    }

    /// 3.0 报 404 → 自动改用 qwen3-asr-flash，而且结果行要写出真正用的那个型号
    func testModelNotFoundFallsBackToQwen3AndReportsIt() {
        var asked = [String]()
        let done = expectation(description: "probe")
        CloudASRProbe.runTryingModels(
            config: config(),
            models: AlibabaASRModel.qwenAudio30Flash.fallbackOrder,
            sendSegment: { request, provider, _, completion in
                let model = self.modelName(of: request)
                asked.append(model)
                if model == AlibabaASRModel.qwen3Flash.rawValue {
                    completion(.success(CloudASRSegmentResult(text: "ok")))
                } else {
                    completion(.failure(provider.failure(
                        status: 404, data: Data(#"{"code":"ModelNotFound"}"#.utf8))))
                }
            }) { result in
            guard case .success(let outcome) = result else { return XCTFail("换了模型之后该通") }
            XCTAssertEqual(outcome.model, AlibabaASRModel.qwen3Flash.rawValue)
            XCTAssertTrue(CloudASRProbe.successText(outcome).contains("qwen3-asr-flash"),
                          "结果行要写出真正用的那个型号")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(asked, ["qwen-audio-3.0-asr-flash", "qwen3-asr-flash"],
                       "先试用户设的那个，404 了才换")
    }

    /// 401 / 403 / 限流换模型一点用都没有：立刻把真正的原因报出来，别多花一趟钱
    func testOnlyA404IsWorthAnotherModel() {
        for status in [401, 403, 429] {
            var calls = 0
            let done = expectation(description: "status \(status)")
            CloudASRProbe.runTryingModels(
                config: config(),
                models: AlibabaASRModel.qwenAudio30Flash.fallbackOrder,
                sendSegment: { _, provider, _, completion in
                    calls += 1
                    completion(.failure(provider.failure(status: status, data: nil)))
                }) { result in
                guard case .failure(let failure) = result else { return XCTFail("不该成功") }
                XCTAssertEqual(failure.status, status)
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
            // 429 在执行器里本来就会退避重试一次，所以只断言"没有第二个模型被试过"
            XCTAssertLessThanOrEqual(calls, status == 429 ? 2 : 1,
                                     "status \(status) 不该换模型再试一轮")
        }
    }

    /// 已经是 qwen3 了就没有下一个可试的：404 原样报出来，文案要指向「模型广场」
    func testQwen3AloneHasNowhereToFallBack() {
        var calls = 0
        let done = expectation(description: "probe")
        CloudASRProbe.runTryingModels(
            config: CloudASRConfig(provider: .alibaba, alibabaModel: .qwen3Flash,
                                   host: AlibabaEndpoint.defaultHost, apiKey: "k"),
            models: AlibabaASRModel.qwen3Flash.fallbackOrder,
            sendSegment: { _, provider, _, completion in
                calls += 1
                completion(.failure(provider.failure(
                    status: 404, data: Data(#"{"code":"ModelNotFound"}"#.utf8))))
            }) { result in
            guard case .failure(let failure) = result else { return XCTFail("不该成功") }
            XCTAssertEqual(failure.status, 404)
            XCTAssertTrue(failure.message.contains("模型广场") || failure.message.contains("Model Gallery"))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(calls, 1)
    }
}

// MARK: - 真·冒烟测试（默认跳过）

/// 真的打一次阿里云。**默认不跑**：它要花钱（1 秒音频）、要网络、要一把真 Key。
/// 开启方式：
///   MICTYPE_CLOUD_SMOKE=1 MICTYPE_CLOUD_KEY=sk-... xcodebuild test …
/// 可选 MICTYPE_CLOUD_HOST=<控制台的接入地址> 跳过主机探测。
/// Key 只从环境变量取，永不落盘、永不进日志、永不写进仓库。
final class CloudASRSmokeTests: XCTestCase {

    private var key: String? {
        let env = ProcessInfo.processInfo.environment
        guard env["MICTYPE_CLOUD_SMOKE"] == "1" else { return nil }
        let key = (env["MICTYPE_CLOUD_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    func testRealAlibabaEndpointResolvesAndTranscribes() throws {
        guard let key = key else {
            throw XCTSkip("需要 MICTYPE_CLOUD_SMOKE=1 与 MICTYPE_CLOUD_KEY 才跑（会真的花钱）")
        }
        let host = ProcessInfo.processInfo.environment["MICTYPE_CLOUD_HOST"] ?? ""
        let candidates = AlibabaEndpoint.candidates(pastedHost: host, apiKey: key)
        let done = expectation(description: "verify")
        CloudASRSetup.verifyAlibaba(
            apiKey: key,
            config: CloudASRConfig(provider: .alibaba, apiKey: key),
            candidates: candidates) { result in
            switch result {
            case .success(let success):
                // 主机名可能含工作空间编号，只报抹过的那版
                print("smoke ok host=\(AlibabaEndpoint.redacted(success.host)) "
                      + "model=\(success.model.rawValue) ms=\(success.outcome.milliseconds)")
            case .failure(let failure):
                XCTFail("云端没通：status=\(failure.status) code=\(failure.code ?? "-") \(failure.message)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 180)
    }
}
