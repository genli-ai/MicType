import XCTest
@testable import MicType

/// 伪流式预览的节流曲线单测。这条曲线的唯一职责是"机器越慢，草稿刷得越稀"——
/// 一旦在高耗时区反向（旧实现：周期被 5s 封顶，却拿「周期 − 耗时」当空闲间隙，
/// 耗时 ≥ 4.6s 时间隙钉死在 0.4s），最该让出 GPU 的慢机器上节流正好失效。
final class PreviewPacingTests: XCTestCase {

    /// 空闲间隙永远不低于下限（负数/零耗时这些边界也一样）
    func testIdleDelayNeverBelowFloor() {
        for latency in [0.0, 0.1, 1.0, 3.0, 6.0, 30.0] {
            XCTAssertGreaterThanOrEqual(
                DictationController.previewIdleDelay(interval: 1.5, latency: latency), 0.4)
        }
        XCTAssertGreaterThanOrEqual(
            DictationController.previewIdleDelay(interval: 1.5, latency: -1), 0.4)
    }

    /// 快机器仍按"周期 − 耗时"走：0.3s 解码 → 还剩 1.2s 空闲，草稿刷得勤
    func testFastDecodeKeepsShortGap() {
        XCTAssertEqual(DictationController.previewIdleDelay(interval: 1.5, latency: 0.3),
                       1.2, accuracy: 0.0001)
    }

    /// 慢机器上间隙必须随耗时长上去，而不是缩回下限（这条就是被修的那个反向）
    func testSlowDecodeGrowsGap() {
        XCTAssertEqual(DictationController.previewIdleDelay(interval: 5.0, latency: 6.0),
                       3.0, accuracy: 0.0001)
        XCTAssertEqual(DictationController.previewIdleDelay(interval: 5.0, latency: 12.0),
                       6.0, accuracy: 0.0001)
    }

    /// 单调性看"start→start 周期"（间隙 + 耗时）：耗时越大周期不减。
    /// 只看间隙不行——快机器那头周期被 1.5s 的基础间隔钉住，间隙本来就该随耗时缩短。
    func testCycleIsMonotonicInLatency() {
        var previous = 0.0
        for step in 0...80 {
            let latency = Double(step) * 0.25
            let interval = min(5.0, max(1.5, latency * 1.5))
            let cycle = DictationController.previewIdleDelay(interval: interval,
                                                             latency: latency) + latency
            XCTAssertGreaterThanOrEqual(cycle, previous - 0.0001,
                                        "latency=\(latency) cycle=\(cycle) previous=\(previous)")
            previous = cycle
        }
    }
}
