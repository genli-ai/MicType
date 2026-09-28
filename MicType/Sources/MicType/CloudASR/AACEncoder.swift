import Foundation
import AVFoundation

// MARK: - 整段上传的音频：AAC-LC 48 kbps m4a（失败退 WAV）
//
// 5.1.0 起整段上传（OpenAI `/audio/transcriptions`，gpt-transcribe）不再发 WAV，改发
// 16 kHz 单声道 AAC-LC 48 kbps 的 m4a（用户 2026-09-28 拍板，与 iOS DECISIONS L39 补记同一个决定）。
//
// 依据（docs/from-ios-260928/ASR-UPLOAD-CODEC-BENCH_260928.md，1242 段公开中文 / 中英混说语料
// 过 gpt-transcribe）：48 kbps 对无损 WAV 字错率 +0.10 个百分点、95% 置信区间跨 0（测不出差别），
// 字节只有约 1/5（WAV 32 KB/s → 约 6 KB/s）。**绝不能降到 32 kbps**：同一轮评测里它测得出地更差
// （合计 +0.44，1.2–3 秒短句 +0.83）。48 也是上限：Apple 的 AAC-LC 编码器在 16 kHz 单声道下
// 拒绝 56 / 64 kbps（'!dat'）。
//
// 为什么要这一步：混合转写（CloudStreamingSession）每句话松手都要把整段再传一次，
// WAV 在 UAE 的上行链路上是一句话里最慢的那一截。
//
// 三条纪律：
//   • **编码失败绝不丢这句话**：任何一步 throw 都退回原来的 WAV（WAVEncoder），并记一行日志；
//   • 只记字节数、秒数与错误描述，永不记音频本身；
//   • AVAudioFile 必须落一个临时文件（它不能写内存），读回来之后立刻删掉。
enum AACEncoder {

    /// 编码参数（与 iOS `SpeechTranscription.m4a48k16kMonoData` 逐项相同）
    static let sampleRate: Double = 16_000
    static let bitRate = 48_000

    enum EncodeError: Error, CustomStringConvertible {
        case formatInit
        case bufferInit
        var description: String {
            switch self {
            case .formatInit: return "cannot build the 16 kHz mono float format"
            case .bufferInit: return "cannot allocate the PCM buffer"
            }
        }
    }

    /// 16 kHz 单声道 [Float] → m4a（AAC-LC 48 kbps），`free` 填充已去掉。任何一步失败都 throw。
    static func m4aData(samples: [Float]) throws -> Data {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false) else {
            throw EncodeError.formatInit
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mictype-up-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer = try AVAudioFile(forWriting: tmp,
                                     settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                AVSampleRateKey: sampleRate,
                                                AVNumberOfChannelsKey: 1,
                                                AVEncoderBitRateKey: bitRate],
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        // 分块写：一次 16384 帧（约 1 秒），十分钟的录音也不用一次性再拷一份
        let chunk = 16_384
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else {
                throw EncodeError.bufferInit
            }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { src in
                for i in 0..<count {
                    let v = src[offset + i]
                    // 与 WAVEncoder.pcm16 同一条：NaN / Inf 当静音，越界截断
                    channel[i] = v.isFinite ? max(-1, min(1, v)) : 0
                }
            }
            try writer.write(from: buffer)
            offset += count
        }
        writer.close()   // 把 AAC 容器写完整再读回来
        let encoded = try Data(contentsOf: tmp)
        return MP4Trim.stripFreeBoxes(encoded)   // 认不出布局就原样返回
    }

    /// 一次上传要发的那一份音频：先试 m4a，失败退 WAV（绝不因为编码问题丢一句话）
    static func uploadAudio(samples: [Float]) -> CloudUploadAudio {
        let seconds = Double(samples.count) / sampleRate
        do {
            let data = try m4aData(samples: samples)
            Log.info("CloudASR upload aac48 \(data.count / 1024)KB audio=\(String(format: "%.1f", seconds))s")
            return .m4a(data)
        } catch {
            Log.warn("CloudASR upload wav (aac failed: \(error))")
            return .wav(WAVEncoder.encode(samples: samples))
        }
    }
}

/// 一次上传的音频体：字节 + 文件名 + Content-Type（multipart 那一段按它写）
struct CloudUploadAudio: Equatable {
    let data: Data
    let filename: String
    let contentType: String

    static func wav(_ data: Data) -> CloudUploadAudio {
        CloudUploadAudio(data: data, filename: "seg.wav", contentType: "audio/wav")
    }

    static func m4a(_ data: Data) -> CloudUploadAudio {
        CloudUploadAudio(data: data, filename: "audio.m4a", contentType: "audio/mp4")
    }
}
