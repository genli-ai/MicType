import XCTest
@testable import MicType

/// 静音闸门（路线图 bug 9）的判据单测。这条闸门管着"整段录音要不要送识别"——
/// 判严了用户白说一段，判松了空音频会诱发热词复读，所以三档的边界必须钉死。
final class SilenceGateTests: XCTestCase {

    // MARK: 时长

    /// 太短一律先判 tooShort：不管音量多大，0.3s 的"啊"就是误触碰到了热键
    func testTooShortWinsOverLevel() {
        XCTAssertEqual(SilenceGate.decide(peak: 0.9, rms: 0.4, duration: 0.39), .tooShort)
        XCTAssertEqual(SilenceGate.decide(peak: 0.0, rms: 0.0, duration: 0.0), .tooShort)
        // 刚好到线要放行（边界归正常那边，否则"说得快"的用户会莫名丢一段）
        XCTAssertEqual(SilenceGate.decide(peak: 0.9, rms: 0.4, duration: 0.4), .normal)
    }

    // MARK: 静音档

    func testDigitalSilenceIsGated() {
        XCTAssertEqual(SilenceGate.decide(peak: 0.0, rms: 0.0, duration: 3), .silent)
        XCTAssertEqual(SilenceGate.decide(peak: 0.0059, rms: 0.0001, duration: 3), .silent)
    }

    /// NaN（转换器出岔子时可能出现）必须落在安全侧：不送识别，而不是把坏数据喂给模型
    func testNaNIsTreatedAsSilence() {
        XCTAssertEqual(SilenceGate.decide(peak: .nan, rms: .nan, duration: 3), .silent)
    }

    // MARK: 小声档（这次改动的核心）

    /// 老实现里 peak=0.01 整段被丢掉、只说一句"没有听到内容"；现在必须照样送识别
    func testQuietSpeechIsStillTranscribed() {
        let decision = SilenceGate.decide(peak: 0.01, rms: 0.002, duration: 3)
        XCTAssertEqual(decision, .faint)
        XCTAssertNotEqual(decision, .silent, "小声说话绝不能被当成没开口丢掉")
    }

    /// 峰值小但 RMS 不小 = 整段都有能量（近处小声连续说），按正常走，不给"声音太小"的提示
    func testLowPeakWithRealEnergyIsNormal() {
        XCTAssertEqual(SilenceGate.decide(peak: 0.015, rms: 0.01, duration: 3), .normal)
    }

    /// 峰值过了 faint 线就是正常档，哪怕 RMS 很小（句子之间有停顿很常见）
    func testLoudPeakWithTinyRMSIsNormal() {
        XCTAssertEqual(SilenceGate.decide(peak: 0.05, rms: 0.0005, duration: 3), .normal)
    }

    /// 三档的边界逐点核对
    func testThresholdBoundaries() {
        XCTAssertEqual(SilenceGate.decide(peak: SilenceGate.silentPeak - 0.0001,
                                          rms: 0.0001, duration: 3), .silent)
        XCTAssertEqual(SilenceGate.decide(peak: SilenceGate.silentPeak,
                                          rms: 0.0001, duration: 3), .faint)
        XCTAssertEqual(SilenceGate.decide(peak: SilenceGate.faintPeak - 0.0001,
                                          rms: 0.0001, duration: 3), .faint)
        XCTAssertEqual(SilenceGate.decide(peak: SilenceGate.faintPeak,
                                          rms: 0.0001, duration: 3), .normal)
        XCTAssertEqual(SilenceGate.decide(peak: 0.01, rms: SilenceGate.faintRMS,
                                          duration: 3), .normal)
    }

    /// 档位只会越来越宽松：峰值变大，判定不可能反过来变严
    func testDecisionIsMonotonicInPeak() {
        let order: [SilenceGate.Decision: Int] = [.silent: 0, .faint: 1, .normal: 2]
        var previous = -1
        for step in 0...400 {
            let peak = Float(step) * 0.0001
            let decision = SilenceGate.decide(peak: peak, rms: 0.0001, duration: 3)
            let rank = order[decision] ?? -1
            XCTAssertGreaterThanOrEqual(rank, previous, "peak=\(peak) decision=\(decision)")
            previous = rank
        }
    }

    // MARK: 统计

    func testStatsOnEmptyInput() {
        let stats = SilenceGate.stats([])
        XCTAssertEqual(stats.peak, 0)
        XCTAssertEqual(stats.rms, 0)
        XCTAssertEqual(SilenceGate.decide(peak: stats.peak, rms: stats.rms, duration: 3), .silent)
    }

    /// 峰值取绝对值（负半周同样是声音），RMS 是整段的均方根
    func testStatsPeakAndRMS() {
        let stats = SilenceGate.stats([0.1, -0.5, 0.2, -0.3])
        XCTAssertEqual(stats.peak, 0.5, accuracy: 1e-6)
        let expected = ((0.01 + 0.25 + 0.04 + 0.09) / 4.0 as Double).squareRoot()
        XCTAssertEqual(Double(stats.rms), expected, accuracy: 1e-6)
    }

    /// 一声咳嗽（单个大样本）淹在长段静音里：峰值很高但 RMS 极低——正是 peak 单独判不出来的情况
    func testStatsOnSpikeInSilence() {
        var samples = [Float](repeating: 0, count: 16_000)
        samples[800] = 0.6
        let stats = SilenceGate.stats(samples)
        XCTAssertEqual(stats.peak, 0.6, accuracy: 1e-6)
        XCTAssertLessThan(stats.rms, 0.01)
    }

    /// RMS 用 Double 累加：几百万个小平方项用 Float 累加会被吃掉，静音判据会跟着跑偏
    func testStatsAccumulatesWithoutPrecisionLoss() {
        let samples = [Float](repeating: 0.001, count: 2_000_000)
        let stats = SilenceGate.stats(samples)
        XCTAssertEqual(Double(stats.rms), 0.001, accuracy: 1e-6)
    }
}
