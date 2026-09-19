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

    /// 目标点（45 s）附近有一个 ≥500ms 的停顿 → 刀落在停顿正中间，而不是 45 s 那个整数点
    func testCutsAtTheSilenceNearestTheTarget() {
        let total = samples(120)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 120, silences: [(44.0, 44.8)]),
                                       totalSamples: total)
        assertWellFormed(plan, total: total)
        // 停顿 44.0–44.8 s 的正中间 = 44.4 s
        XCTAssertEqual(plan[0].upperBound, samples(44.4))
    }

    /// 窗口里有两个停顿时取离目标点近的那个（不是第一个）
    func testPrefersTheSilenceClosestToTheTarget() {
        let total = samples(120)
        let plan = AudioSegmenter.plan(
            frameRMS: frames(seconds: 120, silences: [(42.2, 43.0), (44.6, 45.4)]),
            totalSamples: total)
        XCTAssertEqual(plan[0].upperBound, samples(45.0))
    }

    /// 太短的停顿（300ms，说话中的换气）不算下刀点
    func testIgnoresSilenceShorterThanTheMinimum() {
        let total = samples(120)
        let plan = AudioSegmenter.plan(
            frameRMS: frames(seconds: 120, silences: [(44.0, 44.3), (46.0, 46.9)]),
            totalSamples: total)
        // 46.0–46.9 s 这个停顿覆盖第 2300…2344 帧，正中间是第 2322 帧
        XCTAssertEqual(plan[0].upperBound, 2322 * AudioSegmenter.frameSamples)
    }

    /// 搜索窗口就是 ±3 s：窗口外的停顿（哪怕很长）一律不用，段长才可预期
    func testSilenceOutsideTheSearchWindowIsIgnored() {
        let total = samples(120)
        let plan = AudioSegmenter.plan(
            frameRMS: frames(seconds: 120, silences: [(30.0, 32.0)]),
            totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan[0].upperBound, samples(AudioSegmenter.targetSeconds))
    }

    // MARK: 全程无静音

    /// 一个停顿都没有（连续朗读、背景噪声很大）：退到目标点附近最安静的一帧；
    /// 电平完全均匀时那一帧就是目标点本身——行为可预期，不会莫名偏几秒
    func testNoSilenceAnywhereFallsBackToTheTarget() {
        let total = samples(120)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 120), totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan[0].upperBound, samples(AudioSegmenter.targetSeconds))
    }

    /// 没有真正的停顿，但目标点 ±3 s 内有一帧**真的**安静（低于中位电平的 2%）→ 切在那一帧
    func testFallsBackToTheQuietestFrameNearTheTarget() {
        var frameRMS = frames(seconds: 120)
        let quiet = Int(46.0 * Double(framesPerSecond))
        frameRMS[quiet] = 0.001                      // 中位 0.3 的 0.33%：够安静，但不成"一个停顿"
        let total = samples(120)
        let plan = AudioSegmenter.plan(frameRMS: frameRMS, totalSamples: total)
        XCTAssertEqual(plan[0].upperBound, samples(46))
    }

    /// "最安静的一帧"只是稍微小声（高于中位电平的 2%）→ 这一带整片都在说话，切目标点。
    /// 探针的原话：切在一个 RMS 3750 的"较安静帧"和硬切没有区别，段长可预期更值钱。
    func testQuietFrameThatIsStillSpeechFallsBackToTheNominalPoint() {
        var frameRMS = frames(seconds: 120)
        frameRMS[Int(46.0 * Double(framesPerSecond))] = 0.05   // 中位 0.3 的 16%
        let total = samples(120)
        let plan = AudioSegmenter.plan(frameRMS: frameRMS, totalSamples: total)
        XCTAssertEqual(plan[0].upperBound, samples(AudioSegmenter.targetSeconds))
    }

    // MARK: 长音频

    /// 目标段长 45 s（探针实测的平坦最优区间中点）——改了它就要重新跑一遍探针
    func testTargetSegmentLengthIsFortyFiveSeconds() {
        XCTAssertEqual(AudioSegmenter.targetSeconds, 45)
        XCTAssertEqual(AudioSegmenter.searchWindowSeconds, 3)
        XCTAssertEqual(AudioSegmenter.minSegmentSeconds, 10)
    }

    /// 120 s：按 45 s 切，最后一段并掉了不足 10 s 的尾巴
    func testTwoMinutesSplitsIntoTargetSizedSegments() {
        let total = samples(120)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 120), totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan[0].count, samples(45))
        XCTAssertEqual(plan[1].count, samples(45))
        XCTAssertEqual(plan[2].count, samples(30))
    }

    /// 8 分钟：段数与段长都必须可预期，且一个采样都不能丢
    func testEightMinutesSplitsIntoTargetSizedSegments() {
        let total = samples(480)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 480), totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan.reduce(0) { $0 + $1.count }, total)
        for range in plan {
            XCTAssertGreaterThanOrEqual(Double(range.count) / Double(rate),
                                        AudioSegmenter.minSegmentSeconds)
            XCTAssertLessThanOrEqual(Double(range.count) / Double(rate),
                                     AudioSegmenter.hardCapSeconds)
        }
    }

    /// 尾巴永远不会短于 10 s：宁可最后一段长一点，也不要一个 2 秒的碎片单独跑一次 encoder
    func testTailIsNeverShorterThanTheMinimumSegment() {
        let total = samples(100)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 100), totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan.count, 2)
        XCTAssertGreaterThanOrEqual(Double(plan[1].count) / Double(rate),
                                    AudioSegmenter.minSegmentSeconds)
    }

    /// 10 分钟（录音上限）：每段都在硬上限以内，总长一个采样不差
    func testTenMinutesStaysWithinTheHardCap() {
        let total = samples(600)
        let plan = AudioSegmenter.plan(frameRMS: frames(seconds: 600), totalSamples: total)
        assertWellFormed(plan, total: total)
        XCTAssertEqual(plan.reduce(0) { $0 + $1.count }, total)
    }

    // MARK: 录音中的预转写切点

    /// 录够"目标段长 + 搜索窗口"才切：切点必须落在不会再变的音频上
    func testLiveCutWaitsForTheWholeSearchWindow() {
        let available = samples(47)
        XCTAssertNil(AudioSegmenter.nextLiveCut(frameRMS: frames(seconds: 47),
                                                consumed: 0, available: available))
        let enough = samples(48)
        XCTAssertNotNil(AudioSegmenter.nextLiveCut(frameRMS: frames(seconds: 48),
                                                   consumed: 0, available: enough))
    }

    /// 切点规则与 plan() 同源：附近有停顿就切停顿正中间
    func testLiveCutUsesTheSilenceNearTheTarget() {
        let range = AudioSegmenter.nextLiveCut(
            frameRMS: frames(seconds: 60, silences: [(44.0, 44.8)]),
            consumed: 0, available: samples(60))
        XCTAssertEqual(range, 0..<samples(44.4))
    }

    /// 第二段从上一段的末尾接着来，中间一个采样都不漏
    func testLiveCutsAreContiguous() {
        let framesRMS = frames(seconds: 200)
        var consumed = 0
        var cuts: [Range<Int>] = []
        while let range = AudioSegmenter.nextLiveCut(frameRMS: framesRMS, consumed: consumed,
                                                     available: samples(200)) {
            XCTAssertEqual(range.lowerBound, consumed)
            cuts.append(range)
            consumed = range.upperBound
        }
        XCTAssertEqual(cuts.count, 4)                      // 45 × 4 = 180，剩下 20 s 是尾巴
        XCTAssertEqual(consumed, samples(180))
        XCTAssertEqual(samples(200) - consumed, samples(20))
    }

    func testLiveCutRejectsNonsenseInput() {
        XCTAssertNil(AudioSegmenter.nextLiveCut(frameRMS: [], consumed: 0, available: 0))
        XCTAssertNil(AudioSegmenter.nextLiveCut(frameRMS: frames(seconds: 60),
                                                consumed: samples(60), available: samples(60)))
        XCTAssertNil(AudioSegmenter.nextLiveCut(frameRMS: frames(seconds: 60),
                                                consumed: -5, available: samples(60)))
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
