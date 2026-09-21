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
                        hostPinned: Bool = false,
                        canWaitForResolve: Bool = true,
                        status: Int = 401,
                        code: String? = nil,
                        message: String? = nil,
                        urlErrorCode: Int? = nil,
                        attemptsLeft: Int = 1) -> AlibabaHostRecovery.Action {
        AlibabaHostRecovery.action(isAlibaba: isAlibaba, hostSettled: hostSettled,
                                   hostPinned: hostPinned,
                                   canWaitForResolve: canWaitForResolve, status: status,
                                   code: code, message: message,
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

    /// 4.0.1 迁移**种**下的那台主机（从没联过网）吃 401：这正是 2026-09-20 那份日志的起点——
    /// 出厂种下的是北京站、Key 属于新加坡工作空间。种子不算"试通过"，所以照常去试一圈。
    func testASeededHostIsNotSettledAndStillProbes() {
        let seeded = "ws-1234.cn-beijing.maas.aliyuncs.com"
        let settled = AlibabaEndpoint.hostLooksVerified(resolvedHost: seeded,
                                                        region: .beijing, workspaceID: "ws-1234")
        XCTAssertFalse(settled, "区域 + WorkspaceId 推得出这台，说明它是种下的，不是试出来的")
        XCTAssertEqual(action(hostSettled: settled, status: 401), .resolveAndRetry)
        XCTAssertEqual(action(hostSettled: settled, canWaitForResolve: false, status: 401),
                       .resolveInBackground)
    }

    /// 真的试通过的那台（推不出的主机名 / 压根没有老区域设置）：认它，别再试
    func testAProbedHostCountsAsVerified() {
        XCTAssertTrue(AlibabaEndpoint.hostLooksVerified(
            resolvedHost: "ws-1234.ap-southeast-1.maas.aliyuncs.com",
            region: .beijing, workspaceID: "ws-1234"), "和种子不是同一台，只能是试出来的")
        XCTAssertTrue(AlibabaEndpoint.hostLooksVerified(
            resolvedHost: "dashscope-intl.aliyuncs.com", region: .international, workspaceID: ""),
                      "国际站从来不种（legacyHostSeed 同一条判据），有值就是试出来的")
        XCTAssertFalse(AlibabaEndpoint.hostLooksVerified(resolvedHost: "", region: .beijing,
                                                         workspaceID: "ws-1234"),
                       "压根没有地址，谈不上验证过")
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
    /// 一律与接入地址无关。**不带 access_denied 的 403 也在此列**——那是"模型没开通"。
    func testOtherStatusesAreNotAHostProblem() {
        for status in [200, 400, 403, 404, 429, 500, 503] {
            XCTAssertEqual(action(status: status), .none, "HTTP \(status) 不是接入地址的问题")
        }
        XCTAssertEqual(action(status: 403, code: "Model.AccessDenied"), .none,
                       "模型没开通：换一台主机救不了")
    }

    // MARK: 端点访问被拒（4.1.5）

    /// 2026-09-20 实测：新建的工作空间 Key 在 {ws}.ap-southeast-1 上 /models 回 200、
    /// chat 与识别都回 403 access_denied，而同一把 Key 在 dashscope-intl 上一切正常。
    /// 这是**换一台主机就能解决**的 403，所以必须触发重新试一圈。
    func testEndpointAccessDeniedTriggersAProbe() {
        XCTAssertEqual(action(status: 403, code: "access_denied"), .resolveAndRetry)
        XCTAssertEqual(action(status: 403, code: "Endpoint.AccessDenied"), .resolveAndRetry)
        XCTAssertEqual(action(status: 403, message: "Workspace endpoint access denied."),
                       .resolveAndRetry)
        // 润色等不起那 30 秒：后台去试，这一趟照常交出识别原文
        XCTAssertEqual(action(canWaitForResolve: false, status: 403, code: "access_denied"),
                       .resolveInBackground)
    }

    /// "定下来了"这一位从哪儿来：用户填的那一台永远算数，自动试出来的那台要**真的试通过**。
    /// 这条测试碰真的 UserDefaults（Settings.shared），所以跑完把两项还原。
    func testPinnedHostAlwaysCountsAsSettled() {
        let s = Settings.shared
        let savedHost = s.qwenAPIHost
        let savedResolved = s.qwenResolvedHost
        let savedVerified = s.qwenHostVerified
        defer {
            s.qwenAPIHost = savedHost
            s.qwenResolvedHost = savedResolved
            s.qwenHostVerified = savedVerified
        }

        s.qwenAPIHost = ""
        s.qwenResolvedHost = ""
        s.qwenHostVerified = false
        XCTAssertFalse(LLMClient.alibabaHostSettled, "什么都没有：该去试")
        XCTAssertFalse(LLMClient.alibabaHostPinned)

        s.qwenAPIHost = "https://ws-abc.ap-southeast-1.maas.aliyuncs.com/api/v1"
        XCTAssertTrue(LLMClient.alibabaHostSettled, "他填了地址：一趟都不试")
        XCTAssertTrue(LLMClient.alibabaHostPinned)

        // 拼不出主机名的输入等同于没填（但它仍然原样留在设置里，不归这里管）
        s.qwenAPIHost = "我的主机"
        XCTAssertFalse(LLMClient.alibabaHostSettled)
        XCTAssertFalse(LLMClient.alibabaHostPinned)

        s.qwenAPIHost = ""
        s.qwenResolvedHost = "dashscope-intl.aliyuncs.com"
        s.qwenHostVerified = true
        XCTAssertTrue(LLMClient.alibabaHostSettled, "上一次真的试通过")
        XCTAssertFalse(LLMClient.alibabaHostPinned, "那是试出来的，不是他填的")
    }

    /// 用户自己填了接入地址：**一趟都不探测**（4.3.1，用户 2026-09-21 拍板）。
    /// 他给的是答案不是建议——背着他换一台，日志里发的主机就和他看到的设置对不上了。
    /// 这道闸要拦住每一档，包括 access-denied 那一条（它的全部意义就是"自动换一台"）。
    func testAPinnedHostIsNeverProbed() {
        XCTAssertEqual(action(hostPinned: true, status: 401), .none)
        XCTAssertEqual(action(hostPinned: true, status: 403, code: "access_denied"), .none)
        XCTAssertEqual(action(hostPinned: true, status: 0,
                              urlErrorCode: NSURLErrorCannotFindHost), .none)
    }

    /// **"已经定下来了"也要试**：那个"验证过"是 GET /models 挣来的，而这一版证明
    /// 它什么都不证明。不绕过这道闸的话，用户被永久钉死在一台什么都干不了的主机上。
    /// （只对**自动探测出来**的主机成立；他自己填的那一台见上面那条。）
    func testEndpointAccessDeniedIgnoresTheSettledFlag() {
        XCTAssertEqual(action(hostSettled: true, status: 403, code: "access_denied"),
                       .resolveAndRetry)
        // 别家服务商与"试过了"这两道闸仍然拦得住（不然会变成每句话一趟探测）
        XCTAssertEqual(action(isAlibaba: false, status: 403, code: "access_denied"), .none)
        XCTAssertEqual(action(status: 403, code: "access_denied", attemptsLeft: 0), .none)
    }

    /// 认这一档的判据本身（大小写、两种写法、只认 403）
    func testEndpointAccessDeniedRecognisesBothSpellings() {
        XCTAssertTrue(AlibabaEndpoint.deniesEndpointAccess(status: 403, code: "access_denied",
                                                            message: nil))
        XCTAssertTrue(AlibabaEndpoint.deniesEndpointAccess(status: 403, code: "Endpoint.AccessDenied",
                                                            message: nil))
        XCTAssertTrue(AlibabaEndpoint.deniesEndpointAccess(
            status: 403, code: nil, message: "Workspace Endpoint Access Denied."))
        XCTAssertFalse(AlibabaEndpoint.deniesEndpointAccess(status: 403, code: "Arrearage",
                                                             message: "arrears"))
        XCTAssertFalse(AlibabaEndpoint.deniesEndpointAccess(status: 401, code: "access_denied",
                                                            message: nil),
                       "只认 403：401 是另一回事（Key 不属于这台）")
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

    /// 长按说一段话 = 润色、指令前后脚各一趟。后到的那一趟要**搭上正在飞的**那次探测，
    /// 而不是当场收一个 false（那会被当成"主机没变"，报回一句"API Key 无效"）。
    func testASecondRequestJoinsTheProbeAlreadyInFlight() {
        var joined: Bool?
        XCTAssertEqual(AlibabaHostRecovery.claim({ _ in }), .start)
        XCTAssertEqual(AlibabaHostRecovery.claim({ joined = $0 }), .joined)
        XCTAssertNil(joined, "探测还没落地，搭车的那一趟先等着")
        AlibabaHostRecovery.endResolve()
    }

    /// 刚失败过那一分钟里不是"搭车"而是"别试"：那趟最长 30 秒，
    /// 每句话都走一遍等于给每句话加半分钟
    func testAJustFailedProbeRefusesInsteadOfQueueing() {
        let t0 = Date()
        XCTAssertEqual(AlibabaHostRecovery.claim({ _ in }, now: t0), .start)
        AlibabaHostRecovery.endResolve(failed: true, now: t0)
        XCTAssertEqual(AlibabaHostRecovery.claim({ _ in }, now: t0.addingTimeInterval(1)), .refused)
        XCTAssertEqual(AlibabaHostRecovery.claim({ _ in }, now: t0.addingTimeInterval(61)), .start)
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
