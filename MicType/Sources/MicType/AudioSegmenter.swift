import Foundation

/// 长音频分段规划（brief §3.1–3.3）。
///
/// 为什么要分段：Qwen3-ASR 模型本身支持 1200 s，真正的成本在 mlx-swift-asr 这个 Swift 端口里
/// 是**二次的**——`createBlockAttentionMask` 在 CPU 循环里物化一个 seqLen×seqLen 的 dense mask，
/// 而 audio token ≈ 13/秒。实测：180 s → 22 MB、300 s → 58 MB、550 s → 195 MB、1100 s → 780 MB，
/// rtf 从 0.033 涨到 0.13，RSS 从 1.02 GB 涨到 2.68 GB。注意力本身是 8 秒块对角的，
/// **跨段根本没有长程上下文**，所以切开不损失质量，只省下那条二次曲线。
///
/// 这里只做"在哪儿切"这一件事，而且是纯函数（RMS 帧数组 + 采样总数 → 若干采样区间），
/// 不碰音频、不碰设置、不碰 UI —— 切点是整条长音频链路里最容易出微妙 bug 的一环，
/// 必须能被单测钉死。
enum AudioSegmenter {

    /// 识别链路固定 16kHz 单声道
    static let sampleRate = 16_000
    /// 一帧 20 ms：和官方 VAD 配方的时间分辨率同量级，30000 帧就能覆盖 10 分钟
    static let frameSamples = 320

    /// 低于这个总时长一次过更快（一次 encoder 的固定开销大于分段省下的 mask 成本）
    static let segmentThresholdSeconds: Double = 90
    /// 目标段长。官方 Qwen3-ASR-Toolkit 用 120 s，那是给云 API 的；我们的成本是 CPU 建
    /// seqLen² mask，砍半换交互延迟。探针实测 30–60 s 是平坦最优（219 s 音频：分段 7.1 s
    /// vs 整段 9.7 s），60 s 落在这一区间的上沿
    static let targetSeconds: Double = 60
    /// 硬上限段长（对应官方 180 s 的同比例）：任何一段都不许超过它
    static let hardCapSeconds: Double = 120
    /// 切点搜索窗口：目标点前后各 15 s（官方 fallback 同形）
    static let searchWindowSeconds: Double = 15
    /// 多长的低电平才算"一个可以下刀的停顿"，与官方 `min_silence_duration_ms=500` 一致
    static let minSilenceSeconds: Double = 0.5
    /// 任何一段（含最后那截尾巴）都不短于它。探针实测：不足 10 s 的尾巴并进上一段更划算
    static let minSegmentSeconds: Double = 10
    /// 窗口里一个够长的停顿都没有时的退路半径：在目标点 ±3 s 里挑**最安静的那一帧**。
    /// 探针实测这比"闭着眼睛按目标点硬切"好得多（选中帧 RMS ≈ 1，固定切点 ≈ 3750）
    static let quietFallbackSeconds: Double = 3

    /// "静音"的绝对下限。直接复用录音侧已有的静音判据：AudioRecorder 送给电平回调的是
    /// `min(1, rms*14)`，DictationController 用 0.08 判"还在说吗"，换算回 RMS 就是这个数。
    /// 一处判据两处用，别让同一个"静音"在两个文件里是两个意思。
    static let silenceRMS: Float = 0.08 / 14
    /// 自适应部分：录得响的那一段，停顿本身也比固定下限响（房间底噪跟着增益一起放大）。
    /// 所以再取"整段 RMS 中位数的 5%"做一条相对线，两者取大。
    static let silenceRelativeRatio: Float = 0.05

    /// 每 20 ms 一帧的 RMS。不足一帧的尾巴按实际长度算，不补零——补零会凭空造出一段"静音"。
    static func frameRMS(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var frames: [Float] = []
        frames.reserveCapacity(samples.count / frameSamples + 1)
        var index = 0
        while index < samples.count {
            let upper = min(index + frameSamples, samples.count)
            var sum: Double = 0
            for i in index..<upper {
                let v = Double(samples[i])
                sum += v * v
            }
            frames.append(Float((sum / Double(upper - index)).squareRoot()))
            index = upper
        }
        return frames
    }

    /// 这一段录音的静音线：固定下限与"中位数的 5%"取大（见两个常量的注释）
    static func silenceThreshold(frameRMS frames: [Float]) -> Float {
        guard !frames.isEmpty else { return silenceRMS }
        let sorted = frames.sorted()
        let median = sorted[sorted.count / 2]
        return max(silenceRMS, median * silenceRelativeRatio)
    }

    /// 从采样直接规划（产品路径）
    static func plan(samples: [Float]) -> [Range<Int>] {
        plan(frameRMS: frameRMS(samples), totalSamples: samples.count)
    }

    /// 切点规划。返回连续、无重叠、覆盖整段的采样区间；总时长 ≤ 90 s 时只有一段。
    ///
    /// overlap 恒为 0：官方配方也没有 overlap——正确性来自"在静音处下刀"，
    /// 而不是来自缝合逻辑；有 overlap 又不去重恰恰是边界文本被转两遍的根源。
    static func plan(frameRMS frames: [Float], totalSamples: Int) -> [Range<Int>] {
        guard totalSamples > 0 else { return [] }
        let totalSeconds = Double(totalSamples) / Double(sampleRate)
        guard totalSeconds > segmentThresholdSeconds else { return [0..<totalSamples] }

        let threshold = silenceThreshold(frameRMS: frames)
        let target = seconds(targetSeconds)
        let window = seconds(searchWindowSeconds)
        let cap = seconds(hardCapSeconds)
        let minSeg = seconds(minSegmentSeconds)

        var result: [Range<Int>] = []
        var start = 0
        // 剩下的比"一段目标 + 一截够长的尾巴"还长才继续切；否则整条尾巴自成一段
        // （这就是"不足 10 s 的尾巴并进上一段"那条规则的实现方式：压根不会切出这种尾巴）
        while totalSamples - start > target + minSeg {
            let nominal = start + target
            let lo = max(start + minSeg, nominal - window)
            // 上界同时受三条约束：硬上限段长、搜索窗口、以及"给尾巴留够 minSeg"
            let hi = min(min(start + cap, nominal + window), totalSamples - minSeg)
            guard hi > lo else { break }
            let cut = bestCut(frames: frames, threshold: threshold, nominal: nominal, lo: lo, hi: hi)
            result.append(start..<cut)
            start = cut
        }
        result.append(start..<totalSamples)
        return result
    }

    // MARK: - 内部

    private static func seconds(_ value: Double) -> Int {
        Int(value * Double(sampleRate))
    }

    /// 在 [lo, hi) 里选一个下刀点：优先"离目标点最近的、够长的停顿的正中间"，
    /// 没有停顿就退到"目标点 ±3 s 里最安静的那一帧"，再不行才按目标点硬切。
    private static func bestCut(frames: [Float], threshold: Float,
                                nominal: Int, lo: Int, hi: Int) -> Int {
        let frameLo = max(0, (lo + frameSamples - 1) / frameSamples)
        let frameHi = min(frames.count, hi / frameSamples)
        guard frameHi > frameLo else { return nominal }
        let minRun = max(1, Int(minSilenceSeconds * Double(sampleRate)) / frameSamples)

        // 1) 够长的停顿。窗口边缘被截断的那半截也照算：它在窗口内的部分够长就够用
        var best: (cut: Int, distance: Int)?
        var runStart = -1
        for index in frameLo...frameHi {
            let isQuiet = index < frameHi && frames[index] < threshold
            if isQuiet {
                if runStart < 0 { runStart = index }
                continue
            }
            if runStart >= 0 {
                if index - runStart >= minRun {
                    let cut = clamp((runStart + index) / 2 * frameSamples, lo: lo, hi: hi)
                    let distance = abs(cut - nominal)
                    if best == nil || distance < best!.distance { best = (cut, distance) }
                }
                runStart = -1
            }
        }
        if let best = best { return best.cut }

        // 2) 退路：目标点附近最安静的一帧。平手时取离目标点更近的那一帧——
        //    整段电平完全均匀（合成音频、纯噪声）时这条保证切点恰好落在目标点上，行为可预期
        let fallbackRadius = seconds(quietFallbackSeconds)
        let quietLo = max(frameLo, (max(lo, nominal - fallbackRadius) + frameSamples - 1) / frameSamples)
        let quietHi = min(frameHi, min(hi, nominal + fallbackRadius) / frameSamples)
        guard quietHi > quietLo else { return clamp(nominal, lo: lo, hi: hi) }
        var quietest = quietLo
        var quietestLevel = frames[quietLo]
        var quietestDistance = abs(quietLo * frameSamples - nominal)
        for index in (quietLo + 1)..<quietHi {
            let level = frames[index]
            let distance = abs(index * frameSamples - nominal)
            if level < quietestLevel || (level == quietestLevel && distance < quietestDistance) {
                quietest = index
                quietestLevel = level
                quietestDistance = distance
            }
        }
        return clamp(quietest * frameSamples, lo: lo, hi: hi)
    }

    private static func clamp(_ value: Int, lo: Int, hi: Int) -> Int {
        min(max(value, lo), hi)
    }
}
