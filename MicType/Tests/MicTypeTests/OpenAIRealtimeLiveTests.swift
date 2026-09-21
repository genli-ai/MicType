import XCTest
@testable import MicType

// MARK: - 真·联网测试：OpenAI 实时转写（没有 Key 就跳过）
//
// 为什么非有不可（与阿里云那一条同一理由）：假 socket 能把状态机跑通，却**永远证明不了
// 协议本身是对的**——模型放 query 会被拒、OpenAI-Beta 头会让整条连接废掉、端点只认
// 24 kHz、buffer 里有音频时重发 update 会静默吞掉那段音频，这几件事全是拿真 Key 撞出来的。
// 所以这一条走完整条链路：真连 → 真的把 16 kHz 重采样成 24 kHz → 按真实语速推真语料 → 等真终稿。
//
// Key 从哪儿来（两条，都不进仓库、不进日志、不 print）：
//   • 环境变量 MICTYPE_OPENAI_TEST_KEY
//   • 文件 ~/.config/mictype/openai_test_key
// 两条都没有就 XCTSkip —— CI 与日常 `xcodebuild test` 因此一分钱都不会花。
//
// 只跑这一条：
//   xcodebuild test -scheme MicType -destination 'platform=macOS,arch=arm64' \
//     -derivedDataPath .xcbuild -only-testing:MicTypeTests/OpenAIRealtimeLiveTests
//
// 代价：约 50 秒音频 × $0.017/分钟 ≈ $0.015。
final class OpenAIRealtimeLiveTests: XCTestCase {

    /// 那把 Key。**永远不 print、不写日志、不落盘**。
    private var liveKey: String? {
        let env = ProcessInfo.processInfo.environment["MICTYPE_OPENAI_TEST_KEY"] ?? ""
        let fromEnv = env.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromEnv.isEmpty { return fromEnv }
        let path = NSHomeDirectory() + "/.config/mictype/openai_test_key"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 语料（say 合成，16 kHz 单声道——与录音链路同一格式，重采样由客户端自己做）

    private func synthesize(_ text: String) throws -> [Float] {
        let path = NSTemporaryDirectory() + "mictype-openai-live-\(UUID().uuidString).wav"
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
        var firstDeltaMs: Int?
        var commitToFinalMs: Int?
        var deltas = 0
        var text = ""
        var billedSeconds: Double?
        var pushSeconds: Double = 0
        /// 「松手」到终稿的墙钟毫秒数——用户真正感觉到的那一段等待
        var releaseToFinalMs = 0
        var failure: String?
    }

    /// 推流跑在后台线程、回调回主线程，所以这一份统计只能上锁共享
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var report = Report()
        private var lines: [String] = []
        private var releasedAt = Date()

        func edit(_ body: (inout Report) -> Void) { lock.lock(); body(&report); lock.unlock() }
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
                    out.firstDeltaMs = Int(line.dropFirst("first partial ms=".count))
                }
                if line.hasPrefix("done "), let range = line.range(of: "finishToFinalMs=") {
                    out.commitToFinalMs = Int(line[range.upperBound...])
                }
            }
            return out
        }
    }

    private func stream(samples: [Float], key: String, keywords: [String] = [],
                        label: String) -> Report {
        let ledger = Ledger()
        var options = OpenAIRealtimeClient.Options()
        options.keywords = OpenAIRealtimeClient.keywords(from: keywords)
        let client = OpenAIRealtimeClient(
            config: OpenAIRealtimeClient.Config(apiKey: key, options: options),
            log: { ledger.note($0) })

        let finished = expectation(description: "final \(label)")
        client.onPartial = { _ in ledger.edit { $0.deltas += 1 } }
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

        // 推流放后台，主线程留着跑 run loop —— 中间结果才是"边说边到"
        let pushStarted = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let chunk = 1600                                  // 100 ms @ 16 kHz
            var offset = 0
            var index = 0
            while offset < samples.count {
                let end = min(offset + chunk, samples.count)
                client.append(samples: Array(samples[offset..<end]))
                offset = end
                index += 1
                let target = pushStarted.addingTimeInterval(Double(index) * 0.1)
                let sleepFor = target.timeIntervalSinceNow
                if sleepFor > 0 { Thread.sleep(forTimeInterval: sleepFor) }
            }
            let pushed = Date().timeIntervalSince(pushStarted)
            ledger.edit { $0.pushSeconds = pushed }
            ledger.markReleased()
            client.finish(audioSeconds: Double(samples.count) / 16000.0)
        }

        wait(for: [finished], timeout: Double(samples.count) / 16000.0 + 40)
        client.cancel()
        return ledger.finished
    }

    private func describe(_ label: String, _ report: Report, audioSeconds: Double) {
        print("live-oai: \(label) audio=\(String(format: "%.1f", audioSeconds))s "
              + "push=\(String(format: "%.1f", report.pushSeconds))s "
              + "connect=\(report.connectMs.map(String.init) ?? "-")ms "
              + "firstDelta=\(report.firstDeltaMs.map(String.init) ?? "-")ms "
              + "deltas=\(report.deltas) "
              + "commit→final=\(report.commitToFinalMs.map(String.init) ?? "-")ms "
              + "release→final=\(report.releaseToFinalMs)ms "
              + "chars=\(report.text.count) "
              + "billed=\(report.billedSeconds.map { String(format: "%.0f", $0) } ?? "-")s "
              + "failure=\(report.failure ?? "-")")
    }

    // MARK: - 整条链路

    /// 一趟跑完三件事（合起来约 40 秒）：
    ///   ① 4.5 秒语料按真实语速 → 松手到终稿必须 < 2.5 秒（实测 0.67–1.04 s）；
    ///   ② 22 秒语料按真实语速 → 同一条线，**与录音长度无关**；`usage.seconds` 要对得上时长；
    ///   ③ 带 keywords 的那一条 → 只打印结果不硬断言（合成音不稳定，但专名该被纠正）。
    func testRealtimeStreamingAcrossClipLengths() throws {
        guard let key = liveKey else {
            throw XCTSkip("需要 MICTYPE_OPENAI_TEST_KEY 或 ~/.config/mictype/openai_test_key 才跑（会真的花钱）")
        }
        let short = try synthesize("今天天气不错，我们下午三点在办公室开会。")
        let long = try synthesize("我用的是语音输入法，现在人在阿布扎比，今天是二零二六年九月二十一号。"
                                  + "刚才那顿饭一共花了一百零一块，另外还有两千三百五十六块的机票钱。"
                                  + "请把这段话整理一下，然后发给同事，谢谢你。")
        guard short.count > 16_000, long.count > 16_000 else {
            throw XCTSkip("say -v Tingting 合成不出语料（这台机器没装中文语音）")
        }
        let shortSeconds = Double(short.count) / 16000.0
        let longSeconds = Double(long.count) / 16000.0

        // ① 短录音
        let first = stream(samples: short, key: key, label: "short")
        describe("short", first, audioSeconds: shortSeconds)
        XCTAssertNil(first.failure, "短录音那一趟就失败了：\(first.failure ?? "")")
        XCTAssertFalse(first.text.isEmpty, "终稿是空的")
        XCTAssertGreaterThan(first.deltas, 0, "一条中间结果都没收到，灰字草稿就是空的")
        XCTAssertLessThan(try XCTUnwrap(first.commitToFinalMs), 2500,
                          "松手到终稿超过 2.5 秒，这条路就没有存在的意义了")

        // ② 长录音——**同一条线**才说明它与时长无关
        let second = stream(samples: long, key: key, label: "long")
        describe("long", second, audioSeconds: longSeconds)
        XCTAssertNil(second.failure, "长录音那一趟失败了：\(second.failure ?? "")")
        XCTAssertFalse(second.text.isEmpty)
        XCTAssertGreaterThan(second.deltas, 0)
        XCTAssertLessThan(try XCTUnwrap(second.commitToFinalMs), 2500,
                          "\(String(format: "%.0f", longSeconds)) 秒的录音也必须是同一个数")
        // usage.seconds 是 ceil(秒) 且每个 item 相加：对得上音频时长才说明没有丢音频
        XCTAssertEqual(try XCTUnwrap(second.billedSeconds), longSeconds, accuracy: 1.5,
                       "计费秒数与音频时长对不上——多半是送得太快被静默丢了")
    }

    /// 词汇表热词：**这是 OpenAI 这一档最值钱的地方**（阿里云那边任何手段都救不回专名）。
    /// 合成音不稳定，所以只打印、不硬断言；真正要证明的是「带上 keywords 之后这条链路仍然通」。
    func testKeywordsAreAcceptedAndThePathStillWorks() throws {
        guard let key = liveKey else {
            throw XCTSkip("需要 MICTYPE_OPENAI_TEST_KEY 或 ~/.config/mictype/openai_test_key 才跑（会真的花钱）")
        }
        let clip = try synthesize("我正在用 MicType 这个语音输入法，识别引擎是通义千问。")
        guard clip.count > 16_000 else { throw XCTSkip("合成不出语料") }
        let report = stream(samples: clip, key: key, keywords: ["MicType", "通义千问"],
                            label: "keywords")
        describe("keywords", report, audioSeconds: Double(clip.count) / 16000.0)
        print("live-oai: keywords transcript = \(report.text)")
        XCTAssertNil(report.failure, "带 keywords 之后这条链路必须照样通：\(report.failure ?? "")")
        XCTAssertFalse(report.text.isEmpty)
    }
}
