import XCTest
@testable import MicType

// MARK: - 真·联网测试：云端实时识别的**接线层**（没有 Key 就跳过）
//
// OpenAIRealtimeLiveTests 验的是协议客户端本身；这一条验的是它上面那一层——
// CloudStreamingSession（按下就连、录音中边说边送、松手补发尾巴 + 收尾、交出 TranscriptionOutcome）
// 与「粘 Key 那一下」的实时探针（CloudStreamingProbe）。下一步的混合转写要搭在这一层上，
// 它和真服务端之间对不上账的地方，假 socket 永远测不出来。
//
// 5.1.0 之前这里跑的是阿里云（qwen_test_key）；那一档删掉之后改用 OpenAI 那把测试 Key。
//
// Key 从哪儿来（两条，都不进仓库、不进日志、不 print）：
//   • 环境变量 MICTYPE_OPENAI_TEST_KEY
//   • 文件 ~/.config/mictype/openai_test_key
// 两条都没有就 XCTSkip —— CI 与日常 `xcodebuild test` 因此一分钱都不会花。
//
// 只跑这一条：
//   xcodebuild test -scheme MicType -destination 'platform=macOS,arch=arm64' \
//     -derivedDataPath .xcbuild -only-testing:MicTypeTests/CloudStreamingLiveTests
//
// 代价：约 8 秒音频，实时 $0.017/分钟 + 整段 $0.0045/分钟，合计不到 $0.003。
final class CloudStreamingLiveTests: XCTestCase {

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

    private static let skipMessage =
        "需要 MICTYPE_OPENAI_TEST_KEY 或 ~/.config/mictype/openai_test_key 才跑（会真的花钱）"

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

    // MARK: - 整条接线层

    /// 与 DictationController 同一个用法：make → start → 录音中按 ~100 ms 一把 enqueue →
    /// 松手 transcribe（只补发还没送出去的那一截）→ 终稿。只截一部分音频在"录音中"送，
    /// 剩下的留给 transcribe 去补——"发送到的采样数恰好等于这一段"正是这一层的职责。
    func testSessionStreamsAndDeliversTheFinalTranscript() throws {
        guard let key = liveKey else { throw XCTSkip(Self.skipMessage) }
        let clip = try synthesize("今天天气不错，我们下午三点在办公室开会。")
        guard clip.count > 16_000 else {
            throw XCTSkip("say -v Tingting 合成不出语料（这台机器没装中文语音）")
        }
        CloudStreamingAvailability.resetForTesting()
        defer { CloudStreamingAvailability.resetForTesting() }

        let config = CloudASRSettings.config(vocabulary: [], apiKey: key)
        let session = try XCTUnwrap(CloudStreamingSession.make(config: config,
                                                               fallback: CloudASREngine(config: config),
                                                               officialOpenAI: true),
                                    "有 Key、官方接口、没被判过实时不可用——三道闸都该放行")
        var drafts = 0
        session.onDraft = { _ in drafts += 1 }
        session.start()

        // "录音中"：按真实语速送前 80%，主线程照常跑 run loop（草稿要能边说边到）
        let chunk = 1600                                    // 100 ms
        let liveEnd = clip.count * 4 / 5
        var offset = 0
        while offset < liveEnd {
            let end = min(offset + chunk, liveEnd)
            session.enqueue(Array(clip[offset..<end]))
            offset = end
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(session.queuedSampleCount, liveEnd)

        // "松手"：剩下那 20% 由 transcribe 自己补发
        let released = Date()
        var outcome: TranscriptionOutcome?
        let done = expectation(description: "final")
        session.transcribe(samples: clip, language: nil, previousText: "", onSegment: nil) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        let releaseToFinal = Int(Date().timeIntervalSince(released) * 1000)
        print("live-rt: session audio=\(String(format: "%.1f", Double(clip.count) / 16000))s "
              + "drafts=\(drafts) release→final=\(releaseToFinal)ms "
              + "chars=\(outcome?.text.count ?? 0) failure=\(outcome?.failure?.message ?? "-")")

        let result = try XCTUnwrap(outcome)
        XCTAssertNil(result.failure, result.failure?.message ?? "")
        XCTAssertFalse(result.cancelled)
        XCTAssertFalse(result.text.isEmpty, "终稿是空的")
        XCTAssertEqual(session.queuedSampleCount, clip.count, "松手时要把尾巴一个采样不差地补发完")
        // 松手到终稿：实测 0.67–1.04 秒；超过客户端的收尾超时（短录音 3 秒）本身就会判失败。
        // 5.1.0 起这一句是混合转写（≤ 60 秒）：还要再等整段那一条最多一个窗口（~0.9 秒）
        XCTAssertLessThan(releaseToFinal, 6000)
        XCTAssertTrue(session.ranBatchLane, "4.5 秒的句子该跑混合转写")
        // 把这一句的混合转写那一行（与整段上传的编码那一行）原样打出来：日志里只有毫秒数与字节数
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))   // 迟到的整段也记一行
        for line in Log.recentLines(200)
        where line.contains("CloudASR hybrid") || line.contains("CloudASR upload") {
            print("live-rt: log " + line)
        }
    }

    /// 整段上传那一条改发 m4a（AAC-LC 48 kbps）之后，OpenAI 真的收、真的转得出字。
    /// 代价：3 秒音频 × $0.0045/分钟 ≈ $0.0002
    func testBatchUploadOfAAC48IsTranscribed() throws {
        guard let key = liveKey else { throw XCTSkip(Self.skipMessage) }
        let clip = try synthesize("我们下午三点开会。")
        guard clip.count > 16_000 else {
            throw XCTSkip("say -v Tingting 合成不出语料（这台机器没装中文语音）")
        }
        let upload = AACEncoder.uploadAudio(samples: clip)
        XCTAssertEqual(upload.contentType, "audio/mp4", "这一趟必须真的是 m4a")
        let client = OpenAITranscribeClient(apiKey: key)
        guard case .success(let request) = client.makeRequest(
            audio: upload, seconds: Double(clip.count) / 16_000, context: nil) else {
            return XCTFail("拼不出请求")
        }
        var result: Result<CloudASRSegmentResult, CloudASRFailure>?
        let done = expectation(description: "batch")
        let started = Date()
        CloudASRExecutor.send(request: request, provider: client, handle: CloudASRHandle()) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        let text = (try? result?.get())?.text ?? ""
        print("live-rt: aac48 bytes=\(upload.data.count) audio=\(String(format: "%.1f", Double(clip.count) / 16_000))s "
              + "ms=\(Int(Date().timeIntervalSince(started) * 1000)) chars=\(text.count)")
        if case .failure(let failure) = result { XCTFail("整段上传失败：\(failure.message)") }
        XCTAssertFalse(text.isEmpty, "m4a 整段上传转不出字")
    }

    /// 粘 Key 那一下会跑的那趟实时探针（1 秒合成音）：通了才敢说"松手就有结果"
    func testStreamingProbeReportsLive() throws {
        guard let key = liveKey else { throw XCTSkip(Self.skipMessage) }
        CloudStreamingAvailability.resetForTesting()
        defer { CloudStreamingAvailability.resetForTesting() }
        let config = CloudASRSettings.config(vocabulary: [], apiKey: key)
        var outcome: CloudStreamingProbe.Outcome?
        let done = expectation(description: "probe")
        let startedAt = Date()
        CloudStreamingProbe.run(config: config, officialOpenAI: true) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        print("live-rt: probe=\(outcome.map { "\($0)" } ?? "-") "
              + "ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        XCTAssertEqual(outcome, .live)
        XCTAssertFalse(CloudStreamingAvailability.isUnsupported(provider: .openai,
                                                                host: CloudStreamingSession.streamHost))
    }
}
