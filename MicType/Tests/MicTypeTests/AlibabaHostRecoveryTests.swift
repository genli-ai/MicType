import XCTest
@testable import MicType

/// 打在一台从没验证过的阿里云主机上、吃了 401 或 DNS 不通之后该做什么。
///
/// 来历（用户 2026-09-20 的测试日志）：Key 属于新加坡工作空间，出厂种下的却是北京站。
/// 按「验证」之前，润色往北京站发了两趟，各等 33 秒才超时——App 手上明明有一套
/// 30 秒内能把正确主机试出来的机制（AlibabaHostResolver），真实使用路径上却从不触发。
/// 按了验证之后探测一趟就找到了 ap-southeast-1 并记住，此后一切正常。
///
/// 这里钉的是那个"要不要去试"的判断本身：纯函数，不碰网络、不碰 UserDefaults。
final class AlibabaHostRecoveryTests: XCTestCase {

    private func action(isAlibaba: Bool = true,
                        hostSettled: Bool = false,
                        canWaitForResolve: Bool = true,
                        status: Int = 401,
                        urlErrorCode: Int? = nil,
                        attemptsLeft: Int = 1) -> AlibabaHostRecovery.Action {
        AlibabaHostRecovery.action(isAlibaba: isAlibaba, hostSettled: hostSettled,
                                   canWaitForResolve: canWaitForResolve, status: status,
                                   urlErrorCode: urlErrorCode, attemptsLeft: attemptsLeft)
    }

    // MARK: 该触发的

    /// 日志里的那一幕：地址还没试对，401 回来 → 去试，试出来再发一次
    func testFirst401OnAnUnverifiedHostResolvesAndRetries() {
        XCTAssertEqual(action(status: 401), .resolveAndRetry)
    }

    /// 工作空间 ID 猜错时连 DNS 都不通（status 0）——同样是"地址不对"，同样值得试
    func testDNSAndConnectFailuresAlsoTrigger() {
        for code in [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost] {
            XCTAssertEqual(action(status: 0, urlErrorCode: code), .resolveAndRetry,
                           "网络层错误码 \(code) 指向的是地址本身")
        }
    }

    /// 润色等不起那 30 秒：探测照跑（下一句话就对了），但这一趟当场失败、交出识别原文
    func testPolishResolvesInTheBackgroundInsteadOfWaiting() {
        XCTAssertEqual(action(canWaitForResolve: false, status: 401), .resolveInBackground)
        XCTAssertEqual(action(canWaitForResolve: false, status: 0,
                              urlErrorCode: NSURLErrorDNSLookupFailed), .resolveInBackground)
    }

    // MARK: 不该触发的

    /// 地址已经定下来了（用户粘过 / 上次试通过）：这时的 401 是 Key 的事，
    /// 再试一圈只会拿同一把 Key 把每台候选主机各撞一次 401
    func testSettledHostDoesNotProbeAgain() {
        XCTAssertEqual(action(hostSettled: true, status: 401), .none)
    }

    /// 只试一次。试完还不对说明问题不在地址上，第二圈纯属浪费用户的时间
    func testOnlyOneAttempt() {
        XCTAssertEqual(action(status: 401, attemptsLeft: 0), .none)
    }

    /// 别家服务商没有"主机要自己试"这回事
    func testOtherProvidersNeverProbe() {
        XCTAssertEqual(action(isAlibaba: false, status: 401), .none)
    }

    /// **超时不触发**：主机是存在的，只是链路慢（UAE 出海）。换一台解决不了，
    /// 白花 30 秒探测只会让等待更长——这正是 4.1.1 要消掉的那个毛病。
    func testTimeoutDoesNotTriggerAProbe() {
        XCTAssertEqual(action(status: 0, urlErrorCode: NSURLErrorTimedOut), .none)
        XCTAssertFalse(AlibabaHostRecovery.triggeringURLCodes.contains(NSURLErrorTimedOut))
    }

    /// 网络层错误但没有错误码（status 0、code 为 nil）：判不出是地址的事，不猜
    func testStatusZeroWithoutACodeDoesNotTrigger() {
        XCTAssertEqual(action(status: 0, urlErrorCode: nil), .none)
    }

    /// 其它状态码各有各的话要说（403 没开通、404 没这个模型、429 限流、5xx 服务端），
    /// 一律与接入地址无关
    func testOtherStatusesAreNotAHostProblem() {
        for status in [200, 400, 403, 404, 429, 500, 503] {
            XCTAssertEqual(action(status: status), .none, "HTTP \(status) 不是接入地址的问题")
        }
    }

    // MARK: 单飞闸

    override func setUp() {
        super.setUp()
        AlibabaHostRecovery.resetForTesting()
    }

    override func tearDown() {
        AlibabaHostRecovery.resetForTesting()
        super.tearDown()
    }

    /// 长按说一段话会连着触发润色与指令：两趟同时撞墙不该各起一趟逐台试的探测
    func testOnlyOneProbeRunsAtATime() {
        XCTAssertTrue(AlibabaHostRecovery.beginResolve())
        XCTAssertFalse(AlibabaHostRecovery.beginResolve(), "已经有一趟在飞了")
        AlibabaHostRecovery.endResolve()
        XCTAssertTrue(AlibabaHostRecovery.beginResolve(), "上一趟结束后又能领了")
        AlibabaHostRecovery.endResolve()
    }

    /// Key 本身是废的时候逐台试必然一台台全 401，那趟最长 30 秒。
    /// 每次指令都走一遍等于给每句话加半分钟——所以失败之后有一分钟的冷却。
    func testAFailedProbeCoolsDown() {
        let t0 = Date()
        XCTAssertTrue(AlibabaHostRecovery.beginResolve(now: t0))
        AlibabaHostRecovery.endResolve(failed: true, now: t0)
        XCTAssertFalse(AlibabaHostRecovery.beginResolve(now: t0.addingTimeInterval(1)),
                       "刚失败过，冷却期内不再试")
        XCTAssertFalse(AlibabaHostRecovery.beginResolve(now: t0.addingTimeInterval(59)))
        XCTAssertTrue(AlibabaHostRecovery.beginResolve(now: t0.addingTimeInterval(61)),
                      "一分钟之后可以再试一次")
        AlibabaHostRecovery.endResolve()
    }

    /// 成功之后冷却要清掉——虽然地址已经定了、正常不会再走到这里
    func testASuccessfulProbeClearsTheCooldown() {
        let t0 = Date()
        XCTAssertTrue(AlibabaHostRecovery.beginResolve(now: t0))
        AlibabaHostRecovery.endResolve(failed: true, now: t0)
        XCTAssertFalse(AlibabaHostRecovery.beginResolve(now: t0.addingTimeInterval(1)))

        XCTAssertTrue(AlibabaHostRecovery.beginResolve(now: t0.addingTimeInterval(61)))
        AlibabaHostRecovery.endResolve(failed: false, now: t0.addingTimeInterval(62))
        XCTAssertTrue(AlibabaHostRecovery.beginResolve(now: t0.addingTimeInterval(63)),
                      "上一趟成功了，冷却不该还挂着")
        AlibabaHostRecovery.endResolve()
    }
}
