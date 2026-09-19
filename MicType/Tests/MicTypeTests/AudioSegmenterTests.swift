import XCTest
@testable import MicType

/// 长音频切点规划的单测（brief §3.1–3.3）。
/// 切点错一次的代价是用户的一段话被从中间劈开、缝上多出或少掉几个字，
/// 而这类 bug 在真机上极难复现——所以边界全部钉死在这里。
final class AudioSegmenterTests: XCTestCase {

    private let rate = AudioSegmenter.sampleRate
    private let framesPerSecond = AudioSegmenter.sampleRate / AudioSegmenter.frameSamples  // 50

    /// 造一条 RMS 帧数组：整体是 speech 电平，silences 里的时间区间（秒）压成 0
    private func frames(seconds: Double, speech: Float = 0.3,
                        silences: [(Double, Double)] = []) -> [Float] {
        let count = Int(seconds * Double(framesPerSecond))
        var frames = [Float](repeating: speech, count: count)
        for (from, to) in silences {
            let lo = max(0, Int(from * Double(framesPerSecond)))
            let hi = min(count, Int(to * Double(framesPerSecond)))
            guard lo < hi else { continue }
            for index in lo..<hi { frames[index] = 0 }
        }
        return frames
    }

    private func samples(_ seconds: Double) -> Int { Int(seconds * Double(rate)) }

    /// 每一段都必须首尾相接、覆盖整段、非空、不超硬上限
    private func assertWellFormed(_ plan: [Range<Int>], total: Int,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(plan.isEmpty, file: file, line: line)
        XCTAssertEqual(plan.first?.lowerBound, 0, file: file, line: line)
        XCTAssertEqual(plan.last?.upperBound, total, file: file, line: line)
        let cap = Int(AudioSegmenter.hardCapSeconds * Double(rate))
        for (index, range) in plan.enumerated() {
            XCTAssertGreaterThan(range.count, 0, "segment \(index) is empty", file: file, line: line)
            XCTAssertLessThanOrEqual(range.count, cap, "segment \(index) over the hard cap",
                                     file: file, line: line)
            if index > 0 {
                XCTAssertEqual(plan[index - 1].upperBound, range.lowerBound,
                               "gap or overlap before segment \(index)", file: file, line: line)
            }
        }
    }

    // MARK: 触发阈值

    /// 90 s 以下一次过：分段的开销（每段一次 encoder）在这里赚不回来
    func testShortAudioIsNotSegmented() {
        let total = samples(45)
        XCTAssertEqual(AudioSegmenter.plan(frameRMS: frames(seconds: 45), totalSamples: total),
                       [0..<total])
    }

    /// **恰好 90 s 不切**：阈值是"超过 90 s"，边界归不切那边
    func testExactlyNinetySecondsIsOneSegment() {
        let total = samples(90)
        XCTAssertEqual(AudioSegmenter.plan(frameRMS: frames(seconds: 90), totalSamples: total),
                       [0..<total])
    }

    func testEmptyAudioPlansNothing() {
        XCTAssertEqual(AudioSegmenter.plan(frameRMS: [], totalSamples: 0), [])
    }

    // MARK: 有静音

    /// 目标点附近有一个 ≥500ms 的停顿 → 刀落在停顿正中间，而不是 60 s 那个整数点
    func testCutsAtTheSilenceNearestTheTarget() {
        let total = samples(120)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 120, silences: [(50.0, 50.8)]),
                                       totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan.count, 2)
        // 停顿 50.0–50.8 s 的正中间 = 50.4 s
        XCTAssertEqual(plan[0].upperBound, samples(50.4))
    }

    /// 窗口里有两个停顿时取离目标点近的那个（不是第一个）
    func testPrefersTheSilenceClosestToTheTarget() {
        let total = samples(120)
        let plan = AudioSegmenter.plan(
            frameRMS: frames(seconds: 120, silences: [(46.0, 46.8), (58.0, 58.8)]),
            totalSamples: total)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].upperBound, samples(58.4))
    }

    /// 太短的停顿（300ms，说话中的换气）不算下刀点
    func testIgnoresSilenceShorterThanTheMinimum() {
        let total = samples(120)
        let plan = AudioSegmenter.plan(
            frameRMS: frames(seconds: 120, silences: [(50.0, 50.3), (62.0, 62.9)]),
            totalSamples: total)
        XCTAssertEqual(plan.count, 2)
        // 62.0–62.9 s 这个停顿覆盖第 3100…3144 帧，正中间是第 3122 帧
        XCTAssertEqual(plan[0].upperBound, 3122 * AudioSegmenter.frameSamples)
    }

    // MARK: 全程无静音

    /// 一个停顿都没有（连续朗读、背景噪声很大）：退到目标点附近最安静的一帧；
    /// 电平完全均匀时那一帧就是目标点本身——行为可预期，不会莫名偏几秒
    func testNoSilenceAnywhereFallsBackToTheTarget() {
        let total = samples(120)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 120), totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].upperBound, samples(60))
    }

    /// 没有真正的停顿，但目标点 ±3 s 内有一帧明显更安静 → 切在那一帧
    func testFallsBackToTheQuietestFrameNearTheTarget() {
        var frameRMS = frames(seconds: 120)
        let quiet = Int(61.0 * Double(framesPerSecond))
        frameRMS[quiet] = 0.05                       // 比静音线高，够不上"停顿"，但是窗口里最安静的
        let total = samples(120)
        let plan = AudioSegmenter.plan(frameRMS: frameRMS, totalSamples: total)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].upperBound, samples(61))
    }

    // MARK: 长音频

    /// 恰好 120 s（硬上限段长）：切成两段，每段都在合理区间里
    func testExactlyOneHundredTwentySeconds() {
        let total = samples(120)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 120), totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].count, samples(60))
        XCTAssertEqual(plan[1].count, samples(60))
    }

    /// 8 分钟：段数与段长都必须可预期，且一个采样都不能丢
    func testEightMinutesSplitsIntoTargetSizedSegments() {
        let total = samples(480)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 480), totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan.count, 8)
        XCTAssertEqual(plan.reduce(0) { $0 + $1.count }, total)
        for range in plan {
            XCTAssertGreaterThanOrEqual(Double(range.count) / Double(rate), 10)
            XCTAssertLessThanOrEqual(Double(range.count) / Double(rate), 75)
        }
    }

    /// 尾巴永远不会短于 10 s：宁可最后一段长一点，也不要一个 2 秒的碎片单独跑一次 encoder
    func testTailIsNeverShorterThanTheMinimumSegment() {
        let total = samples(125)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 125), totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan.count, 2)
        XCTAssertGreaterThanOrEqual(Double(plan[1].count) / Double(rate),
                                    AudioSegmenter.minSegmentSeconds)
    }

    /// 10 分钟（新的录音上限）：段数有限、每段都在硬上限以内
    func testTenMinutesStaysWithinTheHardCap() {
        let total = samples(600)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 600), totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan.count, 10)
    }

    // MARK: RMS 帧

    /// 不足一帧的尾巴按实际长度算，不补零——补零会凭空造出一段"静音"，把刀引到错的地方
    func testFrameRMSDoesNotPadTheTail() {
        let samples = [Float](repeating: 0.5, count: AudioSegmenter.frameSamples + 10)
        let frames = AudioSegmenter.frameRMS(samples)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(frames[1], 0.5, accuracy: 1e-6)
    }

    func testFrameRMSOfEmptyAudio() {
        XCTAssertEqual(AudioSegmenter.frameRMS([]), [])
    }

    /// 静音线：安静的录音吃固定下限，响的录音按自己的中位数抬上去（房间底噪跟着增益走）
    func testSilenceThresholdIsTheLargerOfFixedAndRelative() {
        XCTAssertEqual(AudioSegmenter.silenceThreshold(frameRMS: [0.001, 0.002, 0.003]),
                       AudioSegmenter.silenceRMS, accuracy: 1e-6)
        XCTAssertEqual(AudioSegmenter.silenceThreshold(frameRMS: [0.4, 0.4, 0.4]),
                       0.4 * AudioSegmenter.silenceRelativeRatio, accuracy: 1e-6)
    }
}
