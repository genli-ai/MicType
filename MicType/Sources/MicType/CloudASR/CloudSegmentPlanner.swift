import Foundation

// MARK: - 云端分段规划
//
// 云端两家都有单请求上限（阿里云 ≤5 分钟且 base64 ≤10MB；OpenAI ≤25MB 原始文件），
// 长录音必须切开分别发。切哪儿很讲究：切在人说话中间会把一个词劈成两半，两段各错一次。
// 所以按 20ms 一帧算 RMS，在"名义边界 ±3s"里挑能量最低的那一帧下刀——那通常是句间停顿。
//
// 纯函数：输入采样（或已算好的 RMS 帧），输出采样下标区间，不碰 Settings、不碰网络。

/// 一段待发送的音频（采样下标区间）
struct CloudAudioSegment: Equatable {
    let start: Int          // 起始采样下标
    let count: Int          // 采样点数
    let sampleRate: Int

    var range: Range<Int> { start ..< (start + count) }
    var seconds: Double { Double(count) / Double(sampleRate) }
}

/// 一家供应商的分段上限。targetSeconds 是想要的段长，hardMaxSeconds 是绝不可越过的线。
struct CloudSegmentLimits: Equatable {
    /// 名义段长
    let targetSeconds: Double
    /// 硬上限：任何一段都不得超过（超了云端直接 400）
    let hardMaxSeconds: Double
    /// 在名义边界前后各找多久的静音
    let silenceSearchSeconds: Double
    /// 尾巴短于这个长度就并进上一段（免得为 3 秒话单独发一次请求，既贵又容易被截断）
    let minTailSeconds: Double

    init(targetSeconds: Double,
         hardMaxSeconds: Double,
         silenceSearchSeconds: Double = 3,
         minTailSeconds: Double = 10) {
        self.targetSeconds = targetSeconds
        self.hardMaxSeconds = hardMaxSeconds
        self.silenceSearchSeconds = silenceSearchSeconds
        self.minTailSeconds = minTailSeconds
    }

    /// 阿里云：10MB base64 ≈ 234s，且模型另有 5 分钟上限 → 120s / 180s（180s ≈ 7.68MB base64）
    static let alibaba = CloudSegmentLimits(targetSeconds: 120, hardMaxSeconds: 180)
    /// OpenAI：25MB 原始文件 ≈ 781s → 600s / 700s
    static let openai = CloudSegmentLimits(targetSeconds: 600, hardMaxSeconds: 700)
}

enum CloudSegmentPlanner {

    /// 一帧 20ms：足够细（切点误差 ≤20ms 听不出来），又足够粗（5 分钟录音只有 15000 帧）
    static let frameSeconds = 0.02

    // MARK: RMS

    /// 每 20ms 一个 RMS 值。末尾不足一帧的余量也算一帧（不然最后一点采样没法参与找切点）。
    static func rmsFrames(samples: [Float], sampleRate: Int = WAVEncoder.defaultSampleRate) -> [Float] {
        let frameLength = max(1, Int((Double(sampleRate) * frameSeconds).rounded()))
        guard !samples.isEmpty else { return [] }
        var out = [Float]()
        out.reserveCapacity(samples.count / frameLength + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + frameLength, samples.count)
            var sum: Double = 0
            for k in i ..< end {
                let v = samples[k]
                // NaN 当最大能量看待：绝不会被选成切点（坏数据不该决定切哪儿）
                sum += v.isFinite ? Double(v) * Double(v) : 1.0
            }
            out.append(Float((sum / Double(end - i)).squareRoot()))
            i = end
        }
        return out
    }

    // MARK: 规划

    /// 从原始采样直接规划（内部先算 RMS）
    static func plan(samples: [Float],
                     sampleRate: Int = WAVEncoder.defaultSampleRate,
                     limits: CloudSegmentLimits) -> [CloudAudioSegment] {
        plan(rmsFrames: rmsFrames(samples: samples, sampleRate: sampleRate),
             totalSamples: samples.count,
             sampleRate: sampleRate,
             limits: limits)
    }

    /// 从已算好的 RMS 帧规划（录音时可以边录边算，这里就不用再扫一遍几百万个采样）
    static func plan(rmsFrames rms: [Float],
                     totalSamples: Int,
                     sampleRate: Int = WAVEncoder.defaultSampleRate,
                     limits: CloudSegmentLimits) -> [CloudAudioSegment] {
        guard totalSamples > 0 else { return [] }
        let framesPerSecond = 1.0 / frameSeconds
        let samplesPerFrame = max(1, Int((Double(sampleRate) * frameSeconds).rounded()))
        let totalSeconds = Double(totalSamples) / Double(sampleRate)

        // 一次就能发完：不切
        if totalSeconds <= limits.hardMaxSeconds {
            return [CloudAudioSegment(start: 0, count: totalSamples, sampleRate: sampleRate)]
        }

        let targetFrames = max(1, Int((limits.targetSeconds * framesPerSecond).rounded()))
        let hardMaxFrames = max(1, Int((limits.hardMaxSeconds * framesPerSecond).rounded()))
        let searchFrames = max(0, Int((limits.silenceSearchSeconds * framesPerSecond).rounded()))
        let totalFrames = max(1, Int(ceil(Double(totalSamples) / Double(samplesPerFrame))))

        // 一直切到"剩下的不超过名义段长"为止。
        // 为什么按 target 而不是 hardMax 收尾：按 hardMax 收尾时最后一段永远比
        // (hardMax - target) 长，"尾巴短于 10s 就并进上一段"这条规则永远轮不到；
        // 按 target 收尾则每段都在 target 上下，尾巴该短就短、该并就并。
        var cuts = [Int]()          // 切点（帧下标）
        var startFrame = 0
        while totalFrames - startFrame > targetFrames {
            let nominal = startFrame + targetFrames
            // 窗口必须落在 (startFrame, startFrame + hardMaxFrames] 之内，且留得下后面的帧
            let lower = max(startFrame + 1, nominal - searchFrames)
            let upper = min(min(startFrame + hardMaxFrames, nominal + searchFrames), totalFrames - 1)
            var cut: Int
            if lower > upper {
                // 窗口被挤空（target 比 hardMax 还大之类的配置）→ 直接切在硬上限
                cut = min(startFrame + hardMaxFrames, totalFrames - 1)
            } else {
                // 平局归名义边界：完全没有静音的音频就应该切在整齐的 target 上
                cut = min(max(nominal, lower), upper)
                var best = rms.indices.contains(cut) ? rms[cut] : Float.greatestFiniteMagnitude
                for f in lower ... upper where rms.indices.contains(f) {
                    if rms[f] < best {
                        best = rms[f]
                        cut = f
                    }
                }
            }
            guard cut > startFrame else { break }   // 防御：永远不允许不前进
            cuts.append(cut)
            startFrame = cut
        }

        // 帧切点 → 采样区间
        var bounds = [0]
        bounds.append(contentsOf: cuts.map { min($0 * samplesPerFrame, totalSamples) })
        bounds.append(totalSamples)
        var segments = [CloudAudioSegment]()
        for i in 0 ..< (bounds.count - 1) where bounds[i + 1] > bounds[i] {
            segments.append(CloudAudioSegment(start: bounds[i],
                                              count: bounds[i + 1] - bounds[i],
                                              sampleRate: sampleRate))
        }

        // 尾巴太短 → 并进上一段（前提是并完不超硬上限）
        if segments.count >= 2, let tail = segments.last, tail.seconds < limits.minTailSeconds {
            let prev = segments[segments.count - 2]
            let mergedCount = prev.count + tail.count
            if Double(mergedCount) / Double(sampleRate) <= limits.hardMaxSeconds {
                segments.removeLast(2)
                segments.append(CloudAudioSegment(start: prev.start,
                                                  count: mergedCount,
                                                  sampleRate: sampleRate))
            }
        }
        return segments
    }
}
