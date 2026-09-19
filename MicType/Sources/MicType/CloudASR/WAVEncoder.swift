import Foundation

// MARK: - WAV 编码（16kHz 单声道 PCM16）
//
// 为什么自己写：云端两家都只吃文件形式的音频（阿里云 3.0 模型的 format 枚举只列
// wav/mp3/opus），而 WAV 的全部内容就是 44 字节 RIFF 头 + 小端 PCM16——用
// AVFoundation 反而要落一个临时文件、还要管清理。这里是纯函数，不碰全局状态、可单测。

enum WAVEncoder {

    /// 16kHz 单声道：本项目录音链路的唯一采样率
    static let defaultSampleRate = 16_000
    /// PCM 无附加 chunk 时 RIFF/WAVE 头固定 44 字节
    static let headerBytes = 44
    private static let bitsPerSample = 16

    // MARK: 编码

    /// [Float]（-1…1，越界截断）→ 完整 WAV 文件字节
    static func encode(samples: [Float], sampleRate: Int = defaultSampleRate) -> Data {
        var data = Data(capacity: headerBytes + samples.count * 2)
        data.append(header(frameCount: samples.count, sampleRate: sampleRate))
        var pcm = [UInt8]()
        pcm.reserveCapacity(samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: pcm16(sample))
            pcm.append(UInt8(bits & 0x00FF))
            pcm.append(UInt8((bits >> 8) & 0x00FF))
        }
        data.append(contentsOf: pcm)
        return data
    }

    /// 一个采样点 → 小端 PCM16 的数值。
    /// 截断到 [-1, 1]；NaN / Inf 当静音处理——转换器出岔子时宁可写一段静音，
    /// 也不能把坏数据整段送到云端（那边只会回 400）。
    /// 两侧都按 32767 定标：正负都不会因为舍入越界。
    static func pcm16(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        let clipped = max(Float(-1.0), min(Float(1.0), sample))
        return Int16((clipped * 32767.0).rounded())
    }

    /// 44 字节头。frameCount = 采样点数（单声道时等于帧数）。
    static func header(frameCount: Int,
                       sampleRate: Int = defaultSampleRate,
                       channels: Int = 1) -> Data {
        let dataBytes = frameCount * channels * bitsPerSample / 8
        var d = Data(capacity: headerBytes)
        d.append(ascii("RIFF"))
        d.append(le32(UInt32(truncatingIfNeeded: 36 + dataBytes)))
        d.append(ascii("WAVE"))
        d.append(ascii("fmt "))
        d.append(le32(16))                                  // fmt chunk 长度
        d.append(le16(1))                                   // 1 = PCM
        d.append(le16(UInt16(channels)))
        d.append(le32(UInt32(sampleRate)))
        d.append(le32(UInt32(sampleRate * channels * bitsPerSample / 8)))   // byteRate
        d.append(le16(UInt16(channels * bitsPerSample / 8)))                // blockAlign
        d.append(le16(UInt16(bitsPerSample)))
        d.append(ascii("data"))
        d.append(le32(UInt32(truncatingIfNeeded: dataBytes)))
        return d
    }

    // MARK: base64 / data URI

    /// `data:audio/wav;base64,…` —— 阿里云 input_audio 要的形式
    static func dataURI(wav: Data, mime: String = "audio/wav") -> String {
        "data:" + mime + ";base64," + wav.base64EncodedString()
    }

    /// 只要 base64 正文：10MB 预校验算的就是这一段（不含 `data:` 前缀）
    static func base64(wav: Data) -> String { wav.base64EncodedString() }

    /// 不真的编码也能算出 base64 长度——预校验用，省一次 MB 级的字符串分配
    static func base64Length(forByteCount n: Int) -> Int { ((n + 2) / 3) * 4 }

    // MARK: 小工具

    private static func ascii(_ s: String) -> Data { Data(s.utf8) }
    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
}
