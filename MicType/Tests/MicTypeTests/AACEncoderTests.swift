import XCTest
import AVFoundation
@testable import MicType

/// 整段上传的 m4a（AAC-LC 48 kbps，5.1.0）：编出来的东西真能解回原长度、码率对、`free` 填充去掉了，
/// multipart 里文件名与类型跟着换。不上网。
final class AACEncoderTests: XCTestCase {

    private func tone(seconds: Double) -> [Float] {
        let count = Int(seconds * 16_000)
        return (0..<count).map { i in
            let t = Double(i) / 16_000
            return Float(0.25 * sin(2 * .pi * (220 + 300 * t) * t) + 0.1 * sin(2 * .pi * 1_760 * t))
        }
    }

    /// 3 秒 → m4a → 用 AVAudioFile 解回来：长度 ±64 ms，16 kHz 单声道
    func testThreeSecondToneRoundTrips() throws {
        let samples = tone(seconds: 3)
        let data = try AACEncoder.m4aData(samples: samples)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aac-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        let frames = Double(file.length) * 16_000 / file.processingFormat.sampleRate
        XCTAssertEqual(frames, Double(samples.count), accuracy: 0.064 * 16_000,
                       "解回来的长度对不上（\(file.length) 帧）")
    }

    /// 48 kbps ≈ 6 KB/s 编码数据；`free` 填充去掉之后整个文件每秒 6–7 KB。
    /// 超出这个区间 = 码率不是 48（32 kbps 约 4 KB/s——绝不能退回那一档）或者填充没去掉。
    /// **用噪声不用正弦**：这个编码器是可变码率，纯音 10 秒只编出 ~1.7 KB/s（2026-09-28 实测），
    /// 量不出设定的码率；宽带噪声才把码率顶到设定值（实测 ~6.2 KB/s），语音落在两者之间。
    func testBitRateIsAbout48kbpsWithoutPadding() throws {
        let seconds = 10.0
        var state: UInt32 = 12_345   // 固定种子的线性同余：失败可复现
        let noise = (0..<Int(seconds * 16_000)).map { _ -> Float in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.6
        }
        let data = try AACEncoder.m4aData(samples: noise)
        let kbPerSecond = Double(data.count) / 1024 / seconds
        XCTAssertGreaterThan(kbPerSecond, 5.5, "\(kbPerSecond) KB/s")
        XCTAssertLessThan(kbPerSecond, 7.5, "\(kbPerSecond) KB/s")
        XCTAssertNil([UInt8](data).firstRange(of: Array("free".utf8)), "free 填充应该已经去掉了")
        // 约 WAV 的 1/5
        XCTAssertLessThan(data.count, WAVEncoder.encode(samples: noise).count / 4)
    }

    /// 编码成功 → m4a 那一套名字；这条路永远有东西可传
    func testUploadAudioPrefersM4A() {
        let upload = AACEncoder.uploadAudio(samples: tone(seconds: 1))
        XCTAssertEqual(upload.filename, "audio.m4a")
        XCTAssertEqual(upload.contentType, "audio/mp4")
        XCTAssertFalse(upload.data.isEmpty)
    }

    /// multipart 的文件那一段跟着上传体换名字与类型；WAV 那条老入口逐字节不变
    func testMultipartCarriesTheUploadType() throws {
        let client = OpenAITranscribeClient(apiKey: "sk-test")
        guard case .success(let m4aRequest) = client.makeRequest(audio: .m4a(Data([1, 2, 3])),
                                                                 seconds: 1, context: nil),
              case .success(let wavRequest) = client.makeRequest(wav: Data([1, 2, 3]),
                                                                 seconds: 1, context: nil) else {
            return XCTFail("有 Key 就该拼得出请求")
        }
        let m4a = String(decoding: try XCTUnwrap(m4aRequest.httpBody), as: UTF8.self)
        XCTAssertTrue(m4a.contains("filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n"), m4a)
        let wav = String(decoding: try XCTUnwrap(wavRequest.httpBody), as: UTF8.self)
        XCTAssertTrue(wav.contains("filename=\"seg.wav\"\r\nContent-Type: audio/wav\r\n"), wav)
    }
}
