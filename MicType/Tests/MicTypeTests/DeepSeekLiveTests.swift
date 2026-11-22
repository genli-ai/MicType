import XCTest
@testable import MicType

// MARK: - 真·联网测试：DeepSeek 那一档（没有测试 Key 就跳过）
//
// 5.5.0 加回 DeepSeek。这一组走的是**生产路径**：识别走 CloudASREngine（DeepSeekTranscribeClient），
// 润色走 PolishService.polish，指令走 AgentService.freeform（含联网搜索的"没搜就兜底"）。
// Key 从 `~/.config/mictype/deepseek_test_key` 读（不进仓库、不 print、不写日志），没有就 XCTSkip——
// CI 与没有这个文件的机器一分钱都不花。钥匙串一个字节都不碰：KeychainHelper.lookupOverride 只对
// `deepseek_api_key` 这一个账户回这把 Key。
//
// 代价（2026-11-22 估）：识别 4 段共约 20 秒音频（¥0.78/小时 ≈ ¥0.005）+ 1 秒探针 + 一次润色 +
// 一条指令（可能再加一次直接搜索 ¥0.005 和一次作答），合计远低于 ¥0.1。
//
// 只跑这一组：
//   xcodebuild test -scheme MicType -destination 'platform=macOS,arch=arm64' \
//     -derivedDataPath .xcbuild -only-testing:MicTypeTests/DeepSeekLiveTests
final class DeepSeekLiveTests: XCTestCase {

    /// 那把 Key。**永远不 print、不写日志、不落盘**。
    private static var liveKey: String? {
        let path = NSHomeDirectory() + "/.config/mictype/deepseek_test_key"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let skipMessage = "需要 ~/.config/mictype/deepseek_test_key 才跑（会真的花钱）"

    private var savedProvider: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let key = Self.liveKey else { throw XCTSkip(Self.skipMessage) }
        savedProvider = UserDefaults.standard.object(forKey: SettingsKeys.llmProvider)
        // 只对 DeepSeek 那一个账户回 Key：其它账户一律"没有"，串槽的话请求会当场失败
        KeychainHelper.lookupOverride = { account in
            account == LLMProvider.deepseek.keychainAccount ? key : nil
        }
        UserDefaults.standard.set(LLMProvider.deepseek.rawValue, forKey: SettingsKeys.llmProvider)
    }

    override func tearDownWithError() throws {
        KeychainHelper.lookupOverride = nil
        if let value = savedProvider {
            UserDefaults.standard.set(value, forKey: SettingsKeys.llmProvider)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKeys.llmProvider)
        }
        try super.tearDownWithError()
    }

    // MARK: - 语料（say 合成，16 kHz 单声道 PCM16）

    private func synthesize(_ text: String, voice: String) throws -> [Float] {
        let path = NSTemporaryDirectory() + "mictype-ds-live-\(UUID().uuidString).wav"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "--file-format=WAVE",
                             "--data-format=LEI16@16000", "-o", path, text]
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard process.terminationStatus == 0,
              let data = FileManager.default.contents(atPath: path) else { return [] }
        return Self.pcmFloats(wav: data)
    }

    private static func pcmFloats(wav: Data) -> [Float] {
        var offset = 12
        while offset + 8 <= wav.count {
            let id = String(decoding: wav[wav.startIndex + offset ..< wav.startIndex + offset + 4], as: UTF8.self)
            let size = wav.subdata(in: (offset + 4)..<(offset + 8))
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if id == "data" {
                let end = min(wav.count, offset + 8 + Int(size))
                let body = wav.subdata(in: (offset + 8)..<end)
                var out = [Float]()
                out.reserveCapacity(body.count / 2)
                for i in stride(from: 0, to: body.count - 1, by: 2) {
                    let raw = Int16(bitPattern: UInt16(body[i]) | UInt16(body[i + 1]) << 8)
                    out.append(Float(raw) / 32_767.0)
                }
                return out
            }
            offset += 8 + Int(size) + (Int(size) % 2)
        }
        return []
    }

    /// 走生产那一套：CloudASRSettings.currentConfig()（生效服务商 = DeepSeek → DeepSeekTranscribeClient）
    private func transcribe(_ samples: [Float]) throws -> (text: String, ms: Int) {
        let config = CloudASRSettings.currentConfig()
        XCTAssertEqual(config.provider, .deepseek)
        let engine = CloudASREngine(config: config)
        let done = expectation(description: "transcribe")
        var outcome: Result<CloudASRTranscription, CloudASRFailure>?
        let started = Date()
        engine.transcribeDetailed(samples: samples) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch outcome {
        case .success(let transcription)?:
            return (transcription.text, ms)
        case .failure(let failure)?:
            XCTFail("DeepSeek 识别失败 status=\(failure.status) code=\(failure.code ?? "-") \(failure.message)")
            return ("", ms)
        case nil:
            XCTFail("没有回调")
            return ("", ms)
        }
    }

    // MARK: - ① 识别

    func testRecognizesChineseAndEnglish() throws {
        let zh = try synthesize("今天天气不错，我们下午三点在办公室开会，讨论下个月的预算。", voice: "Tingting")
        let en = try synthesize("Please send the quarterly report to the finance team by Friday afternoon.",
                                voice: "Samantha")
        guard zh.count > 16_000, en.count > 16_000 else {
            throw XCTSkip("say 合成不出语料（这台机器没装 Tingting / Samantha）")
        }
        let zhResult = try transcribe(zh)
        print("[deepseek-live] asr zh seconds=\(String(format: "%.1f", Double(zh.count) / 16_000)) "
              + "ms=\(zhResult.ms) text=\(zhResult.text)")
        XCTAssertFalse(zhResult.text.isEmpty)
        XCTAssertTrue(zhResult.text.contains("开会"), zhResult.text)

        let enResult = try transcribe(en)
        print("[deepseek-live] asr en seconds=\(String(format: "%.1f", Double(en.count) / 16_000)) "
              + "ms=\(enResult.ms) text=\(enResult.text)")
        XCTAssertFalse(enResult.text.isEmpty)
        XCTAssertTrue(enResult.text.lowercased().contains("report"), enResult.text)
    }

    /// 阿拉伯语：**只记录，不断言**（用户 2026-11-22：不等阿语结论）
    func testArabicIsRecordedOnly() throws {
        let ar = try synthesize("مرحبا، نلتقي غدا في الساعة الثالثة بعد الظهر في المكتب.", voice: "Majed")
        guard ar.count > 16_000 else { throw XCTSkip("say -v Majed 合成不出语料") }
        let config = CloudASRSettings.currentConfig()
        let engine = CloudASREngine(config: config)
        let done = expectation(description: "arabic")
        var line = "no callback"
        let started = Date()
        engine.transcribeDetailed(samples: ar) { result in
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch result {
            case .success(let t): line = "ms=\(ms) text=\(t.text)"
            case .failure(let f): line = "ms=\(ms) failed status=\(f.status) code=\(f.code ?? "-")"
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        print("[deepseek-live] asr ar seconds=\(String(format: "%.1f", Double(ar.count) / 16_000)) \(line)")
    }

    /// 粘贴即验证打的就是这一条：1 秒 440 Hz 正弦。要么转出字、要么 200 + 空文本（都算 Key 好）
    func testKeyProbeOnTheRecognitionEndpointPasses() throws {
        let key = try XCTUnwrap(Self.liveKey)
        var config = CloudASRSettings.config(provider: .deepseek, vocabulary: [], apiKey: "")
        config.apiKey = key
        let done = expectation(description: "probe")
        var outcome: Result<CloudASRProbe.Outcome, CloudASRFailure>?
        CloudASRProbe.run(config: config) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        switch outcome {
        case .success(let probe)?:
            print("[deepseek-live] probe ok ms=\(probe.milliseconds) textChars=\(probe.text.count)")
        case .failure(let failure)?:
            XCTFail("1 秒正弦探针被拒 status=\(failure.status) code=\(failure.code ?? "-")——"
                    + "按任务书要改用 chat 探针")
        case nil:
            XCTFail("没有回调")
        }
    }

    // MARK: - ② 润色

    func testPolishReturnsText() throws {
        let raw = "嗯那个就是我们明天下午呃三点开个会然后那个讨论一下预算"
        let done = expectation(description: "polish")
        var polished: String?
        var failure: String?
        let started = Date()
        PolishService.polish(raw) { text, error in
            polished = text
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("[deepseek-live] polish ms=\(ms) text=\(polished ?? "nil") failure=\(failure ?? "-")")
        XCTAssertNil(failure)
        XCTAssertFalse((polished ?? "").isEmpty)
    }

    // MARK: - ③ 需要联网的指令

    func testSearchCommandAnswers() throws {
        let done = expectation(description: "command")
        var answer: String?
        var failure: String?
        var usage: LLMUsage?
        let started = Date()
        _ = LLMUsageSink.shared.take()
        AgentService.freeform(instruction: "查一下今天北京天气") { text, error in
            answer = text
            failure = error
            usage = LLMUsageSink.shared.take()
            done.fulfill()
        }
        wait(for: [done], timeout: 90)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        // 走了兜底的那一趟：作答回包不挂工具（searchCount = nil），来源是直接搜索那几条
        let fellBack = usage?.searchCount == nil && !(usage?.citations.isEmpty ?? true)
        print("[deepseek-live] command ms=\(ms) toolSearch=\(usage?.searchCount.map(String.init) ?? "nil") "
              + "fallback=\(fellBack) citations=\(usage?.citations.count ?? 0) "
              + "answer=\(answer ?? "nil") failure=\(failure ?? "-")")
        XCTAssertNil(failure)
        XCTAssertFalse((answer ?? "").isEmpty)
    }

    /// 模型没搜时的那条兜底（直接搜索 → 拿结果作答）。模型这次搜不搜由不得我们，
    /// 所以直接把兜底那一段单独跑一遍：验 `/v1/tools/search` 的请求体与回包解析在真端点上成立
    func testDirectSearchFallbackAnswers() throws {
        let done = expectation(description: "fallback")
        var answer: String?
        var failure: String?
        var usage: LLMUsage?
        let started = Date()
        AgentService.directSearchFallback(instruction: "查一下今天迪拜的天气", input: "",
                                          model: LLMCatalog.commandDefault(for: .deepseek),
                                          maxTokens: LLMCatalog.commandMinOutputTokens,
                                          handle: LLMRequestHandle()) { text, error in
            answer = text
            failure = error
            usage = LLMUsageSink.shared.take()
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("[deepseek-live] fallback ms=\(ms) citations=\(usage?.citations.count ?? 0) "
              + "answer=\(answer ?? "nil") failure=\(failure ?? "-")")
        XCTAssertNil(failure)
        XCTAssertFalse((answer ?? "").isEmpty)
        XCTAssertFalse(usage?.citations.isEmpty ?? true, "来源应当来自直接搜索那几条")
    }
}
