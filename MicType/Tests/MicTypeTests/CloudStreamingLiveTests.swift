import XCTest
@testable import MicType

// MARK: - 真·联网测试：云端实时识别（没有 Key 就跳过）
//
// 为什么非有不可（与 QwenLiveEndpointTests 同一条理由）：假 socket 能把状态机跑通，
// 却**永远证明不了协议本身是对的**——`?model=` 拼错不报错只换模型、`session.update`
// 发第二次就断连、语言参数会触发静默翻译，这几件事都是拿真 Key 撞出来的。
// 所以这一条走完整条链路：真探测主机 → 真连 WebSocket → 按真实语速推真语料 → 等真终稿。
//
// Key 从哪儿来（两条，都不进仓库、不进日志、不 print）：
//   • 环境变量 MICTYPE_QWEN_TEST_KEY
//   • 文件 ~/.config/mictype/qwen_test_key
// 两条都没有就 XCTSkip —— CI 与日常 `xcodebuild test` 因此一分钱都不会花。
//
// 只跑这一条：
//   xcodebuild test -scheme MicType -destination 'platform=macOS,arch=arm64' \
//     -derivedDataPath .xcbuild -only-testing:MicTypeTests/CloudStreamingLiveTests
//
// 代价：约 48 秒音频的计费（约 $0.0017），外加一次 max_tokens=1 的 chat（主机探测那一趟）。
final class CloudStreamingLiveTests: XCTestCase {

    /// 那把 Key。**永远不 print、不写日志、不落盘**。
    private var liveKey: String? {
        let env = ProcessInfo.processInfo.environment["MICTYPE_QWEN_TEST_KEY"] ?? ""
        let fromEnv = env.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromEnv.isEmpty { return fromEnv }
        let path = NSHomeDirectory() + "/.config/mictype/qwen_test_key"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 语料（say 合成，16 kHz 单声道，与录音链路同一格式）

    private func synthesize(_ text: String) throws -> [Float] {
        let path = NSTemporaryDirectory() + "mictype-live-\(UUID().uuidString).wav"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Tingting", "--file-format=WAVE",
                             "--data-format=LEI16@16000", "-o", path, text]
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard process.terminationStatus == 0,
              let data = FileManager.default.contents(atPath: path) else { return [] }
        return Self.pcmFloats(wav: data)
    }

    /// WAV → 16 kHz Float32（只认 PCM16 单声道，正是 say 那条命令写出来的）
    private static func pcmFloats(wav: Data) -> [Float] {
        var offset = 12
        while offset + 8 <= wav.count {
            let id = String(decoding: wav[wav.startIndex + offset ..< wav.startIndex + offset + 4],
                            as: UTF8.self)
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

    // MARK: - 一次真实的流式会话

    private struct Report {
        var connectMs: Int?
        var firstPartialMs: Int?
        var finishToFinalMs: Int?
        var partials = 0
        var text = ""
        var billedSeconds: Double?
        var pushSeconds: Double = 0
        /// 「松手」到终稿的墙钟毫秒数——这就是用户真正感觉到的那一段等待
        var releaseToFinalMs = 0
        var failure: String?
    }

    /// 推流跑在后台线程、回调回主线程，所以这一份统计只能上锁共享
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var report = Report()
        private var lines: [String] = []
        private var releasedAt = Date()

        func edit(_ body: (inout Report) -> Void) {
            lock.lock(); body(&report); lock.unlock()
        }
        func note(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        func markReleased() { lock.lock(); releasedAt = Date(); lock.unlock() }
        var sinceRelease: Int {
            lock.lock(); defer { lock.unlock() }
            return Int(Date().timeIntervalSince(releasedAt) * 1000)
        }
        /// 客户端那几行日志本身就是这次改动要交付的东西之一，顺手拿它当数据源
        var finished: Report {
            lock.lock(); defer { lock.unlock() }
            var out = report
            for line in lines {
                if line.hasPrefix("connected ms=") {
                    out.connectMs = Int(line.dropFirst("connected ms=".count))
                }
                if line.hasPrefix("first partial ms=") {
                    out.firstPartialMs = Int(line.dropFirst("first partial ms=".count))
                }
                if line.hasPrefix("done "), let range = line.range(of: "finishToFinalMs=") {
                    out.finishToFinalMs = Int(line[range.upperBound...])
                }
            }
            return out
        }
    }

    /// - speed: 1.0 = 按真实语速边说边传；20 = 补发积压那一档
    private func stream(samples: [Float], speed: Double, host: String, key: String,
                        label: String) -> Report {
        let ledger = Ledger()
        let client = AlibabaRealtimeClient(
            config: AlibabaRealtimeClient.Config(host: host, apiKey: key),
            log: { ledger.note($0) })

        let finished = expectation(description: "final \(label)")
        client.onPartial = { _ in ledger.edit { $0.partials += 1 } }
        client.onFinish = { result in
            let elapsed = ledger.sinceRelease
            ledger.edit { report in
                report.releaseToFinalMs = elapsed
                switch result {
                case .success(let transcript):
                    report.text = transcript.text
                    report.billedSeconds = transcript.billedSeconds
                case .failure(let failure):
                    report.failure = failure.logReason
                }
            }
            finished.fulfill()
        }
        client.start()

        // 推流放后台，主线程留着跑 run loop —— 中间结果才是"边说边到"，而不是最后一起涌进来
        let pushStarted = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let chunk = 1600                                  // 100 ms
            var offset = 0
            var index = 0
            while offset < samples.count {
                let end = min(offset + chunk, samples.count)
                client.append(samples: Array(samples[offset..<end]))
                offset = end
                index += 1
                let target = pushStarted.addingTimeInterval(Double(index) * 0.1 / speed)
                let sleepFor = target.timeIntervalSinceNow
                if sleepFor > 0 { Thread.sleep(forTimeInterval: sleepFor) }
            }
            let pushed = Date().timeIntervalSince(pushStarted)
            ledger.edit { $0.pushSeconds = pushed }
            ledger.markReleased()
            client.finish(audioSeconds: Double(samples.count) / 16000.0)
        }

        wait(for: [finished], timeout: Double(samples.count) / 16000.0 / speed + 30)
        client.cancel()
        return ledger.finished
    }

    private func describe(_ label: String, _ report: Report, audioSeconds: Double) {
        print("live-rt: \(label) audio=\(String(format: "%.1f", audioSeconds))s "
              + "push=\(String(format: "%.1f", report.pushSeconds))s "
              + "connect=\(report.connectMs.map(String.init) ?? "-")ms "
              + "firstPartial=\(report.firstPartialMs.map(String.init) ?? "-")ms "
              + "partials=\(report.partials) "
              + "finish→final=\(report.finishToFinalMs.map(String.init) ?? "-")ms "
              + "release→final=\(report.releaseToFinalMs)ms "
              + "chars=\(report.text.count) "
              + "billed=\(report.billedSeconds.map { String(format: "%.0f", $0) } ?? "-")s "
              + "failure=\(report.failure ?? "-")")
    }

    // MARK: - 整条链路

    /// 一趟跑完三件事（合起来约 35 秒，留得住默认闸门）：
    ///   ① 4.5 秒语料按真实语速 → 松手到终稿必须 < 1.5 秒；
    ///   ② 22 秒语料按真实语速 → 同一条线，**与录音长度无关**才是这一版的全部理由；
    ///   ③ 22 秒语料 20× 补发 → 节流没算错、服务端也没因为限速把我们踢掉（1007）。
    func testRealtimeStreamingAcrossClipLengths() throws {
        guard let key = liveKey else {
            throw XCTSkip("需要 MICTYPE_QWEN_TEST_KEY 或 ~/.config/mictype/qwen_test_key 才跑（会真的花钱）")
        }
        let short = try synthesize("今天天气不错，我们下午三点在办公室开会。")
        let long = try synthesize("我用的是 MicType 这个语音输入法，识别引擎是通义千问。"
                                  + "我现在人在阿布扎比，今天是二零二六年九月二十一号。"
                                  + "刚才那顿饭一共花了一百零一块，另外还有两千三百五十六块的机票钱。"
                                  + "请把这段话整理一下，然后发给同事。")
        guard short.count > 16_000, long.count > 16_000 else {
            throw XCTSkip("say -v Tingting 合成不出语料（这台机器没装中文语音）")
        }

        // 真探测一趟接入地址：日常听写用的就是它（测试 Key 会落在 dashscope-intl）
        var resolved: String?
        let done = expectation(description: "resolve")
        AlibabaHostResolver.resolve(apiKey: key,
                                    candidates: AlibabaEndpoint.candidates(apiKey: key),
                                    confirmModel: LLMCatalog.qwenDefaultModel) { result in
            switch result {
            case .success(let host): resolved = host
            case .failure(let failure):
                XCTFail("一台都没试出来：status=\(failure.status) \(failure.message)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        let host = try XCTUnwrap(resolved)
        print("live-rt: host=\(AlibabaEndpoint.redacted(host))")

        let shortSeconds = Double(short.count) / 16000.0
        let longSeconds = Double(long.count) / 16000.0

        // ① 短录音，真实语速
        let first = stream(samples: short, speed: 1, host: host, key: key, label: "short×1")
        describe("short×1", first, audioSeconds: shortSeconds)
        XCTAssertNil(first.failure, "短录音那一趟就失败了：\(first.failure ?? "")")
        XCTAssertFalse(first.text.isEmpty, "终稿是空的")
        XCTAssertGreaterThan(first.partials, 0, "一条中间结果都没收到，灰字草稿就是空的")
        XCTAssertLessThan(try XCTUnwrap(first.finishToFinalMs), 1500,
                          "松手到终稿超过 1.5 秒，这条路就没有存在的意义了")

        // ② 长录音，真实语速——**同一条线**才说明它与时长无关
        let second = stream(samples: long, speed: 1, host: host, key: key, label: "long×1")
        describe("long×1", second, audioSeconds: longSeconds)
        XCTAssertNil(second.failure, "长录音那一趟失败了：\(second.failure ?? "")")
        XCTAssertFalse(second.text.isEmpty)
        XCTAssertGreaterThan(second.partials, 0)
        XCTAssertLessThan(try XCTUnwrap(second.finishToFinalMs), 1500,
                          "\(String(format: "%.0f", longSeconds)) 秒的录音也必须是同一个数")
        XCTAssertEqual(second.billedSeconds ?? 0, longSeconds, accuracy: 3,
                       "计费秒数该与音频长度对得上（累计值取最后一条，不是相加）")

        // ③ 20× 补发：节流算对了、服务端也没因为限速把我们踢掉（1007）
        let third = stream(samples: long, speed: 20, host: host, key: key, label: "long×20")
        describe("long×20", third, audioSeconds: longSeconds)
        XCTAssertNil(third.failure, "20× 补发被服务端拒了：\(third.failure ?? "")")
        XCTAssertFalse(third.text.isEmpty)
        XCTAssertLessThan(third.pushSeconds, longSeconds / 2,
                          "20× 补发比实时慢了一半以上，节流参数不对")
    }

    /// 把「识别也用云端」拨开那一下会跑的那趟实时探针（1 秒合成音）。
    /// 状态行上那句"边说边传，松手就有结果"必须真的验证过才敢写。
    func testStreamingProbeReportsLive() throws {
        guard let key = liveKey else {
            throw XCTSkip("需要 MICTYPE_QWEN_TEST_KEY 或 ~/.config/mictype/qwen_test_key 才跑（会真的花钱）")
        }
        CloudStreamingAvailability.resetForTesting()
        defer { CloudStreamingAvailability.resetForTesting() }
        let config = CloudASRConfig(provider: .alibaba,
                                    host: AlibabaEndpoint.sharedInternationalHost,
                                    apiKey: key)
        var outcome: CloudStreamingProbe.Outcome?
        let done = expectation(description: "probe")
        let startedAt = Date()
        CloudStreamingProbe.run(config: config) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        print("live-rt: probe=\(outcome.map { "\($0)" } ?? "-") "
              + "ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        XCTAssertEqual(outcome, .live)
        XCTAssertFalse(CloudStreamingAvailability
                        .isUnsupported(provider: .alibaba,
                                       host: AlibabaEndpoint.sharedInternationalHost))
    }
}
