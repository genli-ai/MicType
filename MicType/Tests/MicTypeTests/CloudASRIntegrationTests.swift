import XCTest
@testable import MicType

/// 云端识别**接线层**的单测：设置怎么变成一份引擎配置、哪一档现在能不能开工、
/// 云端炸了这一轮往哪走。全是纯函数，不碰网络、不碰 UserDefaults、不碰钥匙串——
/// 这几条判据正是"音频会不会离开这台 Mac"的闸门，必须钉死。
///
/// 文案断言故意写成"中文 或 英文"的形式（或只断言结构），因为 tr() 取的是运行时界面语言。
final class CloudASRIntegrationTests: XCTestCase {

    // MARK: - 档位本身

    func testEngineChoiceRawValuesAreStable() {
        // rawValue 存在 UserDefaults 里，改一个字就等于把所有老用户的设置作废
        XCTAssertEqual(RecognitionEngineChoice.local.rawValue, "local")
        XCTAssertEqual(RecognitionEngineChoice.cloudAlibaba.rawValue, "cloudAlibaba")
        XCTAssertEqual(RecognitionEngineChoice.cloudOpenAI.rawValue, "cloudOpenAI")
        XCTAssertEqual(RecognitionEngineChoice.allCases.count, 3)
    }

    /// 脏值、空值、别的分支写进来的值——一律回落本地。默认档永远是"音频不出机"那一档。
    func testUnknownEngineFallsBackToLocal() {
        XCTAssertEqual(RecognitionEngineChoice.parse(""), .local)
        XCTAssertEqual(RecognitionEngineChoice.parse("cloud"), .local)
        XCTAssertEqual(RecognitionEngineChoice.parse("CLOUDALIBABA"), .local)
        XCTAssertEqual(RecognitionEngineChoice.parse(" cloudOpenAI "), .cloudOpenAI, "两头的空白要容忍")
    }

    func testCloudProviderMapping() {
        XCTAssertNil(RecognitionEngineChoice.local.cloudProvider)
        XCTAssertFalse(RecognitionEngineChoice.local.isCloud)
        XCTAssertEqual(RecognitionEngineChoice.cloudAlibaba.cloudProvider, .alibaba)
        XCTAssertEqual(RecognitionEngineChoice.cloudOpenAI.cloudProvider, .openai)
        XCTAssertTrue(RecognitionEngineChoice.cloudOpenAI.isCloud)
    }

    // MARK: - 语言提示

    func testExplicitLanguageBecomesItsCode() {
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "zh", vocabulary: []), ["zh"])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "ar", vocabulary: []), ["ar"])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "YUE", vocabulary: []), ["yue"])
    }

    /// 云端不认识的语言（荷兰语、波斯语…本机模型有、云端列表里没有）→ 一个提示都不送，
    /// 让云端自己判。送一个它不认识的码只会被判 InvalidParameter，整段识别失败。
    func testLanguagesTheCloudDoesNotKnowSendNoHint() {
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "nl", vocabulary: []), [])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "fa", vocabulary: []), [])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "mk", vocabulary: []), [])
    }

    /// Auto 默认什么都不送；只有用户**自己的词表**证明这是一场中英夹杂的口述时才送两个提示
    func testAutoOnlyHintsWhenVocabularyIsMixed() {
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "", vocabulary: []), [])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "auto", vocabulary: []), [])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "", vocabulary: ["捷文", "云术法"]), [],
                       "只有中文词条不等于只说中文，不替用户锁语言")
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "", vocabulary: ["Power BI"]), [])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "",
                                                     vocabulary: ["捷文", "Power BI"]),
                       ["zh", "en"])
        XCTAssertEqual(CloudASRSettings.languageHints(recognitionLanguage: "auto",
                                                     vocabulary: ["MicType 捷文"]),
                       ["zh", "en"], "同一条词条里中西夹杂也算混合")
    }

    func testScriptDetectionHelpers() {
        XCTAssertTrue(CloudASRSettings.containsCJK("捷文"))
        XCTAssertTrue(CloudASRSettings.containsCJK("テスト"))
        XCTAssertFalse(CloudASRSettings.containsCJK("Power BI"))
        XCTAssertFalse(CloudASRSettings.containsCJK("مرحبا"), "阿拉伯语不是 CJK")
        XCTAssertTrue(CloudASRSettings.containsLatinLetter("Power BI"))
        XCTAssertFalse(CloudASRSettings.containsLatinLetter("捷文"))
        XCTAssertFalse(CloudASRSettings.containsLatinLetter("123"))
    }

    // MARK: - 接入地址（没有"区域"这个概念了）

    /// 控制台会给三种串（apiHost / dashScope URL / openAiCompatible URL），三种都要认——
    /// 让用户自己从 URL 里抠主机名，抠错的表现又是"鉴权失败"
    func testHostNormalizationAcceptsEverythingTheConsoleGives() {
        let host = "ws-e9548i71rc13pul7.cn-beijing.maas.aliyuncs.com"
        XCTAssertEqual(AlibabaEndpoint.normalizeHost(host), host)
        XCTAssertEqual(AlibabaEndpoint.normalizeHost("https://" + host), host)
        XCTAssertEqual(AlibabaEndpoint.normalizeHost("https://" + host + "/api/v1"), host)
        XCTAssertEqual(AlibabaEndpoint.normalizeHost("https://" + host + "/compatible-mode/v1"), host)
        XCTAssertEqual(AlibabaEndpoint.normalizeHost("  HTTPS://" + host.uppercased() + "/  "), host)
        XCTAssertEqual(AlibabaEndpoint.normalizeHost(host + ":443"), host)
    }

    func testHostNormalizationRejectsJunk() {
        XCTAssertNil(AlibabaEndpoint.normalizeHost(""))
        XCTAssertNil(AlibabaEndpoint.normalizeHost("   "))
        XCTAssertNil(AlibabaEndpoint.normalizeHost("localhost"), "没有点的不算主机名")
        XCTAssertNil(AlibabaEndpoint.normalizeHost("我的 主机.com"), "带空格/中文的一律不要")
        XCTAssertNil(AlibabaEndpoint.normalizeHost("-bad.example.com"))
        XCTAssertNil(AlibabaEndpoint.normalizeHost("a..b.com"))
    }

    /// 工作空间的 Key 长成 sk-ws-xxxx.<密文>，前半段就是主机名第一段：
    /// 认出它就省掉用户去控制台抄 WorkspaceId
    func testWorkspaceIDIsRecognisedFromTheKeyShape() {
        XCTAssertEqual(AlibabaEndpoint.workspaceID(fromKey: "sk-ws-e9548i71rc13pul7.abcdef123456"),
                       "ws-e9548i71rc13pul7")
        XCTAssertEqual(AlibabaEndpoint.workspaceID(fromKey: "  SK-WS-ABC123.zzz  "), "ws-abc123")
        XCTAssertNil(AlibabaEndpoint.workspaceID(fromKey: "sk-proj-abcdef"), "普通 Key 里没有工作空间")
        XCTAssertNil(AlibabaEndpoint.workspaceID(fromKey: ""))
    }

    /// 用户自己粘了接入地址 = 他把答案给了：**只用它**，不拿他的 Key 去试别的主机
    func testPastedHostWinsAndStopsTheSearch() {
        let candidates = AlibabaEndpoint.candidates(
            pastedHost: "https://ws-abc.cn-beijing.maas.aliyuncs.com/api/v1",
            resolvedHost: "dashscope.aliyuncs.com",
            workspace: "ws-abc",
            legacyRegionSlug: "cn-beijing",
            apiKey: "sk-ws-abc.zzz")
        XCTAssertEqual(candidates, ["ws-abc.cn-beijing.maas.aliyuncs.com"])
    }

    /// 北京站 + 工作空间的用户（正是 4.0.0 报 404 的那一位）：第一台就该是他的专属主机
    func testWorkspaceHostComesBeforeTheSharedHosts() {
        let candidates = AlibabaEndpoint.candidates(workspace: "ws-e9548i71rc13pul7",
                                                    legacyRegionSlug: "cn-beijing")
        XCTAssertEqual(candidates.first, "ws-e9548i71rc13pul7.cn-beijing.maas.aliyuncs.com")
        XCTAssertTrue(candidates.contains("dashscope-intl.aliyuncs.com"))
        XCTAssertTrue(candidates.contains("dashscope.aliyuncs.com"))
        XCTAssertEqual(candidates.count, Set(candidates).count, "候选表不能有重复，重复就是白跑一趟")
    }

    /// 上一次试出来的那台排第一：正常听写时候选表实际上只用得到它（一句话都不探测）
    func testResolvedHostIsTriedFirst() {
        let candidates = AlibabaEndpoint.candidates(resolvedHost: "dashscope.aliyuncs.com",
                                                    workspace: "ws-abc")
        XCTAssertEqual(candidates.first, "dashscope.aliyuncs.com")
    }

    /// 整表探测时它**不占表头**（4.1.4）：钉在第一位会让它在"快得分不出高下"时白捡一个胜出，
    /// 而那正是要消掉的那一幕（缓存里种着北京 → 新加坡永远没机会）。仍然要在表里。
    func testFullProbeDoesNotPinTheResolvedHostFirst() {
        let candidates = AlibabaEndpoint.candidates(resolvedHost: "ws-abc.cn-beijing.maas.aliyuncs.com",
                                                    workspace: "ws-abc",
                                                    pinsResolvedFirst: false)
        XCTAssertEqual(candidates.first, "ws-abc.ap-southeast-1.maas.aliyuncs.com")
        XCTAssertTrue(candidates.contains("ws-abc.cn-beijing.maas.aliyuncs.com"))
        XCTAssertEqual(candidates.count, Set(candidates).count)
    }

    /// 上一次那台不在拼得出来的那几台里（比如它本来是粘进来的）：整表探测也不能把它丢掉
    func testFullProbeStillKeepsAnUnrelatedResolvedHost() {
        let candidates = AlibabaEndpoint.candidates(resolvedHost: "gateway.example.com",
                                                    workspace: "ws-abc",
                                                    pinsResolvedFirst: false)
        XCTAssertTrue(candidates.contains("gateway.example.com"))
        XCTAssertNotEqual(candidates.first, "gateway.example.com")
    }

    /// 新加坡排在北京前面（用户 2026-09-20 拍板）。顺序只在"平手"时起作用，
    /// 但平手恰恰是最容易出错的那一档；国际站共享主机同样排在中国站前面。
    func testSingaporeComesBeforeBeijing() {
        let suffixes = AlibabaEndpoint.workspaceSuffixes
        guard let sg = suffixes.firstIndex(where: { $0.hasPrefix("ap-southeast-1.") }),
              let bj = suffixes.firstIndex(where: { $0.hasPrefix("cn-beijing.") }) else {
            return XCTFail("这两档一个都不能少")
        }
        XCTAssertEqual(sg, 0, "新加坡必须是第一项")
        XCTAssertLessThan(sg, bj)
        XCTAssertEqual(suffixes.count, 5, "4.0.0 能选的每一档都必须还在（少一条就有人再也试不到）")

        let shared = AlibabaEndpoint.candidates()
        XCTAssertEqual(shared, [AlibabaEndpoint.sharedInternationalHost,
                                AlibabaEndpoint.sharedChinaHost])
    }

    /// 存着的那条接入地址只有**死透了**才丢：401（不认这把 Key）与 status 0（连不上）。
    /// 403/404/限流说明主机本身是对的，丢掉它等于把用户送去一台他没指定的主机。
    func testPastedHostIsDroppedOnlyWhenItIsReallyDead() {
        let host = "ws-abc.cn-beijing.maas.aliyuncs.com"
        XCTAssertTrue(AlibabaEndpoint.dropsPastedHost(pastedHost: host, status: 401))
        XCTAssertTrue(AlibabaEndpoint.dropsPastedHost(pastedHost: host, status: 0))
        for status in [200, 403, 404, 429, 500] {
            XCTAssertFalse(AlibabaEndpoint.dropsPastedHost(pastedHost: host, status: status),
                           "HTTP \(status) 说明这台主机是对的")
        }
        XCTAssertFalse(AlibabaEndpoint.dropsPastedHost(pastedHost: "", status: 401),
                       "压根没存过就没什么可丢的")
    }

    /// 拼不出主机名的脏值：**任何状态码下都该丢**，而且不必等它失败一次。
    /// 4.1.4 起界面上没有这个输入框了——留着它只会让候选表少一台、让错误信息
    /// 指向一个用户根本碰不到的东西。
    func testJunkStoredHostIsAlwaysDropped() {
        for junk in ["我的主机", "接入地址：xxx", "not a host", "-bad.example.com"] {
            XCTAssertTrue(AlibabaEndpoint.storedHostIsJunk(junk), junk)
            for status in [200, 401, 403, 404, 0] {
                XCTAssertTrue(AlibabaEndpoint.dropsPastedHost(pastedHost: junk, status: status),
                              "\(junk) / HTTP \(status)")
            }
        }
        XCTAssertFalse(AlibabaEndpoint.storedHostIsJunk(""), "空着是常态，不是脏值")
        XCTAssertFalse(AlibabaEndpoint.storedHostIsJunk("   "))
        XCTAssertFalse(AlibabaEndpoint.storedHostIsJunk("https://dashscope-intl.aliyuncs.com/api/v1"),
                       "整条 URL 归一得出主机名，是好值")
    }

    // MARK: - 每周按"最快"复查一次接入地址（4.1.4）

    /// 为什么是周期而不是一次性：选定的那台主机日常一句话都不复查，而它会变旧
    ///（用户换地方、服务商调链路）。界面上又没有任何"重新探测"的按钮可按，
    /// 所以只能自己每周问一遍。
    func testHostRefreshRunsWhenItHasNeverRunOrIsAWeekOld() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func should(_ last: Date?, hasKey: Bool = true, pastedHost: String = "") -> Bool {
            AlibabaFastestHostRefresh.shouldRun(lastProbe: last, now: now,
                                                hasKey: hasKey, pastedHost: pastedHost)
        }
        XCTAssertTrue(should(nil), "从来没问过：这次就问")
        XCTAssertFalse(should(now.addingTimeInterval(-6 * 24 * 3600)), "6 天前刚问过，别天天发 Key")
        XCTAssertTrue(should(now.addingTimeInterval(-8 * 24 * 3600)), "8 天前那次该过期了")
        XCTAssertTrue(should(now.addingTimeInterval(-AlibabaFastestHostRefresh.interval)),
                      "整整一周，边界上算过期")
        XCTAssertFalse(should(nil, hasKey: false), "没有 Key 连问都问不出来")
        XCTAssertFalse(should(nil, pastedHost: "https://ws-abc.cn-beijing.maas.aliyuncs.com/api/v1"),
                       "设置文件给了答案：不该被我们按'更快'换掉")
        XCTAssertTrue(should(nil, pastedHost: "  我的主机  "),
                      "拼不出主机名的脏值等于没填（它会被单独丢掉）")
    }

    /// 什么线索都没有时也必须给得出候选表（共享主机两台）
    func testCandidatesAreNeverEmpty() {
        XCTAssertFalse(AlibabaEndpoint.candidates().isEmpty)
        XCTAssertEqual(AlibabaEndpoint.candidates().first, AlibabaEndpoint.sharedInternationalHost)
    }

    /// 识别与润色必须落在**同一台主机**上：一处试通，两边都对
    func testBothPathsDeriveFromOneHost() {
        let host = "ws-abc.cn-beijing.maas.aliyuncs.com"
        XCTAssertEqual(AlibabaEndpoint.asrURL(host: host)?.absoluteString,
                       "https://" + host + "/api/v1/services/aigc/multimodal-generation/generation")
        XCTAssertEqual(AlibabaEndpoint.compatibleBaseURL(host: host),
                       "https://" + host + "/compatible-mode/v1")
        XCTAssertEqual(AlibabaEndpoint.modelsURL(host: host)?.absoluteString,
                       "https://" + host + "/compatible-mode/v1/models")
    }

    /// 主机名第一段就是工作空间编号，进日志 / 诊断信息之前必须抹掉
    func testRedactionHidesTheWorkspaceID() {
        let redacted = AlibabaEndpoint.redacted("ws-e9548i71rc13pul7.cn-beijing.maas.aliyuncs.com")
        XCTAssertFalse(redacted.contains("e9548i71rc13pul7"))
        XCTAssertTrue(redacted.hasSuffix("cn-beijing.maas.aliyuncs.com"))
        XCTAssertEqual(AlibabaEndpoint.redacted("dashscope.aliyuncs.com"), "dashscope.aliyuncs.com",
                       "共享主机里没有工作空间编号，原样报出来更有用")
    }

    // MARK: - 并发试一圈、挑最快的那台

    /// 200 = 就是它；403 也算——鉴权已经过了（Key 属于这台），换一台解决不了
    func testResolverStopRules() {
        XCTAssertTrue(AlibabaHostResolver.accepts(status: 200))
        XCTAssertTrue(AlibabaHostResolver.accepts(status: 403))
        XCTAssertFalse(AlibabaHostResolver.accepts(status: 401))
        XCTAssertTrue(AlibabaHostResolver.keepsTrying(status: 401), "Key 不属于这台")
        XCTAssertTrue(AlibabaHostResolver.keepsTrying(status: 404))
        XCTAssertTrue(AlibabaHostResolver.keepsTrying(status: 0), "DNS 都不通 = 这台主机不存在")
        XCTAssertFalse(AlibabaHostResolver.keepsTrying(status: 429), "限流跟主机无关，换一台也一样")
    }

    private func attempt(_ host: String, _ status: Int, _ ms: Int,
                         _ code: String? = nil) -> AlibabaHostResolver.Attempt {
        AlibabaHostResolver.Attempt(host: host, status: status, code: code, milliseconds: ms)
    }

    /// 认这把 Key 的有好几台时选**最快**的——哪怕它排在表的最后。
    /// 这就是 4.1.4 这一版的全部理由：北京与新加坡都回 200，而从 UAE 过去差了一个数量级。
    func testDecidePicksTheFastestAcceptedHost() {
        let hosts = ["beijing.example.com", "singapore.example.com", "tokyo.example.com"]
        let decision = AlibabaHostResolver.decide(candidates: hosts, attempts: [
            attempt("beijing.example.com", 200, 1800),
            attempt("singapore.example.com", 200, 240),
            attempt("tokyo.example.com", 401, 300, "InvalidApiKey"),
        ])
        guard case .chosen(let winner, let accepted) = decision else {
            return XCTFail("有人认了这把 Key：\(decision)")
        }
        XCTAssertEqual(winner.host, "singapore.example.com")
        XCTAssertEqual(accepted, 2, "北京也认这把 Key——正是它先答应过一次才有这一版")
    }

    /// 403 也算"认了"：鉴权过了，只是模型没开通——换一台主机解决不了这件事
    func testDecideCountsForbiddenAsAccepted() {
        let hosts = ["a.example.com", "b.example.com"]
        let decision = AlibabaHostResolver.decide(candidates: hosts, attempts: [
            attempt("a.example.com", 401, 50, "InvalidApiKey"),
            attempt("b.example.com", 403, 900, "Arrearage"),
        ])
        guard case .chosen(let winner, _) = decision else { return XCTFail("403 = 就是这一台") }
        XCTAssertEqual(winner.host, "b.example.com")
    }

    /// 快得分不出高下（150 ms 以内）：按候选表的顺序选，也就是新加坡胜出。
    /// 一次探测的抖动本来就有几十毫秒，拿它当"更快"是在赌骰子。
    func testDecideBreaksNearTiesByCandidateOrder() {
        let hosts = ["singapore.example.com", "beijing.example.com"]
        let nearTie = AlibabaHostResolver.decide(candidates: hosts, attempts: [
            attempt("beijing.example.com", 200, 300),
            attempt("singapore.example.com", 200, 380),
        ])
        guard case .chosen(let winner, _) = nearTie else { return XCTFail("\(nearTie)") }
        XCTAssertEqual(winner.host, "singapore.example.com", "差 80 ms 算平手 → 表里靠前的赢")

        // 差得够多就认数字，顺序让位
        let clear = AlibabaHostResolver.decide(candidates: hosts, attempts: [
            attempt("beijing.example.com", 200, 300),
            attempt("singapore.example.com", 200, 900),
        ])
        guard case .chosen(let fast, _) = clear else { return XCTFail("\(clear)") }
        XCTAssertEqual(fast.host, "beijing.example.com", "差 600 ms 不是平手")
    }

    /// 一台都不认：报**最有用**的那一条。
    /// 401（"这把 Key 哪台都不属于"）比 status 0（连 DNS 都没通，多半是工作空间编号猜错了）
    /// 有信息量得多；而限流 / 5xx 跟主机根本没关系，最该原样报出去。
    func testDecidePrefersTheMostInformativeFailure() {
        let hosts = ["guess.example.com", "shared.example.com"]
        let keyRejected = AlibabaHostResolver.decide(candidates: hosts, attempts: [
            attempt("guess.example.com", 0, 6000),
            attempt("shared.example.com", 401, 120, "InvalidApiKey"),
        ])
        guard case .rejected(let reported) = keyRejected else { return XCTFail("\(keyRejected)") }
        XCTAssertEqual(reported.status, 401)
        XCTAssertEqual(reported.code, "InvalidApiKey")

        let throttled = AlibabaHostResolver.decide(candidates: hosts, attempts: [
            attempt("guess.example.com", 401, 100, "InvalidApiKey"),
            attempt("shared.example.com", 429, 100, "Throttling.RateQuota"),
        ])
        guard case .rejected(let rate) = throttled else { return XCTFail("\(throttled)") }
        XCTAssertEqual(rate.status, 429, "限流跟主机无关，换一台也一样——这句话最该说")

        // 404 比"连不上"有用，但比 401 没用
        let notFound = AlibabaHostResolver.decide(candidates: hosts, attempts: [
            attempt("guess.example.com", 0, 100),
            attempt("shared.example.com", 404, 100, "ModelNotFound"),
        ])
        guard case .rejected(let missing) = notFound else { return XCTFail("\(notFound)") }
        XCTAssertEqual(missing.status, 404)
    }

    /// 一条结论都没回来（整趟超时）：仍然要给得出一个失败，而不是永远等下去
    func testDecideFallsBackWhenNothingCameBack() {
        let decision = AlibabaHostResolver.decide(candidates: ["a.example.com"], attempts: [])
        guard case .rejected(let reported) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(reported.status, 0)
        XCTAssertEqual(reported.host, "a.example.com")
    }

    /// 每一台都要试到（不碰网络：假发送器），而且不是试到第一台答应就停
    func testResolverProbesEveryCandidateAndTakesTheFastest() {
        var tried = [String]()
        let done = expectation(description: "resolved")
        AlibabaHostResolver.resolve(apiKey: "sk-ws-abc.zzz",
                                    candidates: ["a.example.com", "b.example.com", "c.example.com"],
                                    send: { request, completion in
            let host = request.url?.host ?? "?"
            tried.append(host)
            // a 与 c 都认这把 Key；a 慢得多，所以答案必须是 c
            switch host {
            case "a.example.com":
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { completion(200, nil, nil) }
            case "c.example.com":
                completion(200, nil, nil)
            default:
                completion(401, "InvalidApiKey", nil)
            }
        }) { result in
            guard case .success(let host) = result else { return XCTFail("有两台认了这把 Key") }
            XCTAssertEqual(host, "c.example.com", "a 也答应了，但它慢 400 ms")
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(Set(tried), ["a.example.com", "b.example.com", "c.example.com"],
                       "每一台都要问一遍，才谈得上挑最快的")
    }

    /// 全试完都不认：报那条最有用的原因（而不是"最后回来的那一条"）
    func testResolverReportsTheMostUsefulReasonWhenNothingWorks() {
        let done = expectation(description: "failed")
        AlibabaHostResolver.resolve(apiKey: "sk-test",
                                    candidates: ["a.example.com", "b.example.com"],
                                    send: { _, completion in completion(401, "InvalidApiKey", nil) }) { result in
            guard case .failure(let failure) = result else { return XCTFail("不该成功") }
            XCTAssertEqual(failure.status, 401)
            XCTAssertEqual(failure.code, "InvalidApiKey")
            // 4.1.4 起这句话**不再指路"去粘接入地址"**（那个框已经没有了），
            // 改成说我们真正知道的那件事：每一台都试过，没有一台认这把 Key
            XCTAssertTrue(failure.message.contains("Key") || failure.message.contains("key"),
                          failure.message)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// 限流这种"跟主机没关系"的失败仍然要当面报出来。
    /// 4.1.4 起并发发，所以每一台都会被问一遍（串行那一版是"撞上就立刻停"）——
    /// 换来的是墙钟时间从"逐台 × 每台 6 秒"降到"最慢那一台"。
    func testResolverStillReportsAnUnrelatedFailure() {
        var calls = 0
        let done = expectation(description: "failed")
        AlibabaHostResolver.resolve(apiKey: "sk-test",
                                    candidates: ["a.example.com", "b.example.com"],
                                    send: { _, completion in
            calls += 1
            completion(429, "Throttling.RateQuota", nil)
        }) { result in
            guard case .failure(let failure) = result else { return XCTFail("不该成功") }
            XCTAssertEqual(failure.status, 429)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(calls, 2)
    }

    func testResolverRefusesToProbeWithoutAKey() {
        let done = expectation(description: "failed")
        AlibabaHostResolver.resolve(apiKey: "  ", candidates: ["a.example.com"],
                                    send: { _, _ in XCTFail("没有 Key 就不该上网") }) { result in
            guard case .failure = result else { return XCTFail("不该成功") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    // MARK: - 组装配置

    func testConfigCarriesVocabularyHintsAndHost() {
        let config = CloudASRSettings.config(provider: .alibaba,
                                             alibabaModel: .qwen3Flash,
                                             host: "  https://ws-123.cn-beijing.maas.aliyuncs.com/api/v1  ",
                                             recognitionLanguage: "zh",
                                             vocabulary: ["捷文", "Power BI"],
                                             apiKey: "sk-test")
        XCTAssertEqual(config.provider, .alibaba)
        XCTAssertEqual(config.alibabaModel, .qwen3Flash)
        XCTAssertEqual(config.host, "ws-123.cn-beijing.maas.aliyuncs.com",
                       "整条 URL 也要能直接粘进来，归一成裸主机名")
        XCTAssertEqual(config.languageHints, ["zh"])
        XCTAssertEqual(config.vocabulary, ["捷文", "Power BI"], "词表原样交给客户端，权重与过滤在那一层")
        XCTAssertEqual(config.apiKey, "sk-test")
        XCTAssertFalse(config.enableITN, "ITN 一律关：MicType 自己有润色层")
    }

    /// 主机名读不出来也绝不能配出一个拼不出 URL 的引擎：退回共享主机，
    /// 至于对不对由 AlibabaHostResolver 下一次试出来
    func testUnusableHostFallsBackToADefault() {
        let config = CloudASRSettings.config(provider: .alibaba,
                                             alibabaModel: .qwen3Flash,
                                             host: "   ",
                                             recognitionLanguage: "",
                                             vocabulary: [],
                                             apiKey: "k")
        XCTAssertEqual(config.host, AlibabaEndpoint.defaultHost)
        XCTAssertNotNil(AlibabaASRClient.endpoint(host: config.host))
    }

    /// 词表要真的变成热词参数（权重 4）——这是云端档下专有名词准确率的唯一杠杆
    func testVocabularyReachesTheHotwordParameter() {
        let config = CloudASRSettings.config(provider: .alibaba,
                                             alibabaModel: .qwen3Flash,
                                             host: AlibabaEndpoint.defaultHost,
                                             recognitionLanguage: "",
                                             vocabulary: ["MicType", "捷文"],
                                             apiKey: "k")
        let vocab = AlibabaASRClient.vocabularyParameter(config.vocabulary)
        XCTAssertEqual(vocab["MicType"], 4)
        XCTAssertEqual(vocab["捷文"], 4)
    }

    // MARK: - 开录之前：这一档能不能用

    /// 4.0.1 起只剩两个闸门：本地档看模型，云端档看 Key。
    /// 「这个区域没有接入点」那一档随区域选择器一起没了——地址现在是试出来的。
    func testReadinessMatrix() {
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .local, localModelAvailable: true,
                                                           hasCloudKey: false),
                       .ready, "本地档不看云端 Key")
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .local, localModelAvailable: false,
                                                           hasCloudKey: true),
                       .localModelMissing)
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .cloudAlibaba, localModelAvailable: false,
                                                           hasCloudKey: true),
                       .ready, "云端档不需要本机模型")
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .cloudAlibaba, localModelAvailable: true,
                                                           hasCloudKey: false),
                       .cloudKeyMissing(.alibaba))
        XCTAssertEqual(RecognitionEngineReadiness.evaluate(choice: .cloudOpenAI, localModelAvailable: true,
                                                           hasCloudKey: false),
                       .cloudKeyMissing(.openai))
    }

    /// 每一种"开不了工"都必须有一句话和一个落点；云端那两档还要有可点的胶囊
    func testReadinessMessagesAndChips() {
        XCTAssertTrue(RecognitionEngineReadiness.ready.isReady)
        XCTAssertTrue(RecognitionEngineReadiness.ready.message.isEmpty)
        XCTAssertNil(RecognitionEngineReadiness.ready.settingsChipLabel)
        XCTAssertNil(RecognitionEngineReadiness.localModelMissing.settingsChipLabel,
                     "本地档走的是引导下载页，不用胶囊")
        for state: RecognitionEngineReadiness in [.localModelMissing, .cloudKeyMissing(.alibaba),
                                                  .cloudKeyMissing(.openai)] {
            XCTAssertFalse(state.isReady)
            XCTAssertFalse(state.message.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        XCTAssertNotNil(RecognitionEngineReadiness.cloudKeyMissing(.alibaba).settingsChipLabel)
    }

    // MARK: - 云端炸了之后

    /// 本地模型在 = 永远先本地重跑一遍：用户说过的话一个字都不该因为云端抽风而丢
    func testFallbackPrefersTheLocalEngine() {
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "", localModelAvailable: true),
                       .retryLocally)
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "前两段的字", localModelAvailable: true),
                       .retryLocally)
    }

    /// 没有本地退路：有字就把已经转出来的段落交付出去，什么都没有才报错
    func testFallbackWithoutLocalModel() {
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "前两段的字", localModelAvailable: false),
                       .deliverPartial)
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "", localModelAvailable: false),
                       .reportFailure)
    }

    func testFallbackNoteNamesTheReasonAndStaysShort() {
        let note = CloudFallbackDecision.fallbackNote(reason: "429 Throttling")
        XCTAssertTrue(note.contains("429 Throttling"), "原因要原样摆出来：用户据此判断要不要重试")
        let long = CloudFallbackDecision.fallbackNote(reason: String(repeating: "x", count: 400))
        XCTAssertLessThan(long.count, 200, "悬浮窗一行放不下 400 个字符的云端原话")
    }

    // MARK: - 探针（粘贴即验证 / 「测试识别」）

    func testProbeToneIsOneSecondOfAudibleSignal() {
        let tone = CloudASRProbe.toneSamples()
        XCTAssertEqual(tone.count, 16_000, "1 秒 @ 16kHz")
        XCTAssertTrue(tone.allSatisfy { abs($0) <= 0.5001 }, "半幅，不至于削顶")
        XCTAssertTrue(tone.contains { abs($0) > 0.4 }, "不能是一段静音——静音验不出 Key 好坏")
        XCTAssertEqual(CloudASRProbe.toneSamples(seconds: 0).count, 0)
    }

    /// HTTP 200 回来了、只是合成音没识别出字 —— 这正是探针的正常结果，必须算"通过"
    func testProbeAcceptsAnEmptyTranscriptButNotARealError() {
        let empty = CloudASRFailure("no text", code: CloudASRFailure.emptyTranscriptCode, status: 200)
        XCTAssertTrue(CloudASRProbe.isAcceptable(empty))
        XCTAssertFalse(CloudASRProbe.isAcceptable(
            AlibabaASRClient.failure(status: 401, code: "InvalidApiKey", message: nil)))
        XCTAssertFalse(CloudASRProbe.isAcceptable(
            AlibabaASRClient.failure(status: 403, code: "AccessDenied", message: nil)))
        XCTAssertFalse(CloudASRProbe.isAcceptable(CloudASRFailure("network down")),
                       "还没上网的失败（status 0）不能算通过")
    }

    /// 解析层要真的给出这个码，否则探针会把"通了但没字"当成失败
    func testParsersTagEmptyTranscriptsWithTheProbeCode() {
        guard case .failure(let alibaba) = AlibabaASRClient.parse(Data(#"{"output":{}}"#.utf8),
                                                                 model: .qwen3Flash) else {
            return XCTFail("没有文本字段不能算成功")
        }
        XCTAssertEqual(alibaba.code, CloudASRFailure.emptyTranscriptCode)
        XCTAssertEqual(alibaba.status, 200)

        guard case .failure(let openai) = OpenAITranscribeClient.parse(Data(#"{"foo":1}"#.utf8)) else {
            return XCTFail("没有 text 字段不能算成功")
        }
        XCTAssertEqual(openai.code, CloudASRFailure.emptyTranscriptCode)
    }

    /// 结果行必须写出"用的哪个型号"：识别模型会被 404 回落悄悄换掉，
    /// 不写出来用户就不知道自己到底在用什么（也就查不出账单为什么变了）
    func testProbeSuccessTextReportsRoundTripAndModel() {
        let text = CloudASRProbe.successText(
            CloudASRProbe.Outcome(milliseconds: 842, text: "", billedSeconds: 1,
                                  model: AlibabaASRModel.qwen3Flash.rawValue))
        XCTAssertTrue(text.contains("842"))
        XCTAssertTrue(text.contains("✓"))
        XCTAssertTrue(text.contains("qwen3-asr-flash"))
    }

    // MARK: - SpeechEngine 桥接（不上网也测得到的那几条）

    /// 空音频：不上网、不报错，交付一段空文本（下游那句"没有听到内容"负责说话）
    func testSegmentedBridgeDeliversEmptyOutcomeForEmptyAudio() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .alibaba, apiKey: "sk-test"))
        let done = expectation(description: "completion")
        engine.transcribe(samples: [], onSegment: { _, _, _ in
            XCTFail("空音频不该报任何分段进度")
        }) { outcome in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(outcome.text, "")
            XCTAssertNil(outcome.failure)
            XCTAssertFalse(outcome.cancelled)
            XCTAssertFalse(outcome.isPartial)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// 没 Key：必须回一个带话的失败，而不是静默不回调（否则悬浮窗永远转圈）
    func testSegmentedBridgeFailsWithoutAKey() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .openai, apiKey: ""))
        let done = expectation(description: "completion")
        engine.transcribe(samples: [0.1, 0.2], onSegment: nil) { outcome in
            XCTAssertEqual(outcome.text, "")
            XCTAssertNotNil(outcome.failure)
            XCTAssertFalse(outcome.failure!.message.isEmpty)
            XCTAssertFalse(outcome.isComplete)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        // 没有 Key 的这一轮，集成层会按"没有本地退路就报错"走
        XCTAssertEqual(CloudFallbackDecision.decide(partialText: "", localModelAvailable: false),
                       .reportFailure)
    }

    // MARK: - 语言提示送不送得到（界面据此换文案）

    /// 云端的语言表比「识别语言」那张选单短：选了它不认识的码，提示根本送不出去。
    /// 设置页那句"选了具体语言就送过去"必须按这个判据分支，否则对小语种就是假话。
    func testCloudHintDeliveredMatchesWhatIsActuallySent() {
        XCTAssertTrue(CloudASRSettings.cloudHintDelivered(recognitionLanguage: "zh"))
        XCTAssertTrue(CloudASRSettings.cloudHintDelivered(recognitionLanguage: "ar"))
        XCTAssertTrue(CloudASRSettings.cloudHintDelivered(recognitionLanguage: " EN "))
        // 「自动」与空值：本来就不送提示，界面说的就是"交给云端判"，不算不一致
        XCTAssertTrue(CloudASRSettings.cloudHintDelivered(recognitionLanguage: ""))
        XCTAssertTrue(CloudASRSettings.cloudHintDelivered(recognitionLanguage: "auto"))
        // 选单里有、云端不认的那几种（荷兰语 / 波斯语 / 希腊语 / 罗马尼亚语 / 匈牙利语 / 马其顿语）
        for code in ["nl", "fa", "el", "ro", "hu", "mk"] {
            XCTAssertFalse(CloudASRSettings.cloudHintDelivered(recognitionLanguage: code),
                           "\(code) 不在云端语言表里，界面必须换一句话")
            XCTAssertTrue(CloudASRSettings.languageHints(recognitionLanguage: code, vocabulary: []).isEmpty,
                          "判据必须与真正送出去的 hints 同源")
        }
    }

    // MARK: - 桥接层的取消语义（假发送器，不上网）

    /// 200 秒等能量音频：阿里云档切成 2 段（120 + 80），够跑完整条多段流程
    private func longAudio(seconds: Double = 200) -> [Float] {
        [Float](repeating: 0.05, count: Int(seconds * Double(WAVEncoder.defaultSampleRate)))
    }

    private func engineWithFakeSender(_ sender: FakeCloudSender,
                                      provider: CloudASRProvider = .alibaba) -> CloudASREngine {
        let engine = CloudASREngine(config: CloudASRConfig(provider: provider, apiKey: "sk-test"))
        engine.sendSegment = { request, client, handle, completion in
            sender.send(request, client, handle, completion)
        }
        return engine
    }

    /// Esc 必须**立刻**收口，而不是等在飞的那一段传完、转完（阿里云单段 120s 起步，
    /// 还可能退避重试一次；那段音频照常上传、照常计费）。
    /// 这条测试里第 2 段故意永远不回——修复之前它会超时变红。
    func testCancelDeliversWithoutWaitingForTheInflightSegment() {
        let sender = FakeCloudSender()
        sender.script(1, .success(CloudASRSegmentResult(text: "前面这一段已经转好了")))
        // 第 2 段不排结果 = 还在飞
        let engine = engineWithFakeSender(sender)

        let progressed = expectation(description: "第 1 段报上来")
        let finished = expectation(description: "交付")
        var delivered: TranscriptionOutcome?
        let handle = engine.transcribe(samples: longAudio(), language: nil, previousText: "",
                                       onSegment: { _, index, total in
            XCTAssertEqual(total, 2, "200 秒在阿里云档下应该是 2 段")
            if index == 1 { progressed.fulfill() }
        }) { outcome in
            XCTAssertTrue(Thread.isMainThread)
            delivered = outcome
            finished.fulfill()
        }
        wait(for: [progressed], timeout: 20)
        // 第 2 段是在引擎自己的队列上排出去的，等它真的上路再按 Esc——
        // 要验的正是"在飞的那一段不必等它跑完"
        wait(for: [sender.expectRequest(2, self)], timeout: 20)

        handle.cancel()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(delivered?.text, "前面这一段已经转好了", "已经转好的段照常交付")
        XCTAssertEqual(delivered?.cancelled, true)
        XCTAssertNil(delivered?.failure, "用户自己停的，不是故障")
        XCTAssertEqual(delivered?.completedSegments, 1)
    }

    /// 取消**优先于**失败：Esc 之后在飞的那一段才超时/限流失败，不能报成"云端炸了"——
    /// 集成层的回落判据是 `usesCloud && failure != nil && !cancelled`，报错就会把整段音频
    /// 重新丢给本机引擎跑一遍（几十秒冷启动 + 整段插入），完全无视用户的停止。
    func testCancelledRunIsNeverReportedAsAFailure() {
        let sender = FakeCloudSender()
        sender.script(1, .success(CloudASRSegmentResult(text: "已经说完的前半段")))
        let engine = engineWithFakeSender(sender)

        let progressed = expectation(description: "第 1 段报上来")
        let finished = expectation(description: "交付")
        var outcomes: [TranscriptionOutcome] = []
        let handle = engine.transcribe(samples: longAudio(), language: nil, previousText: "",
                                       onSegment: { _, index, _ in
            if index == 1 { progressed.fulfill() }
        }) { outcome in
            outcomes.append(outcome)
            finished.fulfill()
        }
        wait(for: [progressed], timeout: 20)
        handle.cancel()
        wait(for: [finished], timeout: 5)

        // 在飞的第 2 段随后以失败收场（超时 + 退避重试也没过）
        sender.finishPending(.failure(CloudASRFailure("timeout", retryable: true)))
        drainMainQueue()

        XCTAssertEqual(outcomes.count, 1, "只许交付一次")
        XCTAssertEqual(outcomes.first?.cancelled, true)
        XCTAssertNil(outcomes.first?.failure, "取消之后的失败不是失败")
        XCTAssertEqual(outcomes.first?.text, "已经说完的前半段")
        // 这正是集成层"要不要回落本地"的判据：取消了就不许回落
        let outcome = outcomes.first
        XCTAssertFalse((outcome?.failure != nil) && !(outcome?.cancelled ?? false))
    }

    /// 段间上下文：第 2 段的请求里必须带着第 1 段的尾巴（帮云端接住被切开的句子）
    func testSegmentTailIsCarriedIntoTheNextRequest() {
        let sender = FakeCloudSender()
        sender.script(1, .success(CloudASRSegmentResult(text: "帮我把这段话记下来")))
        sender.script(2, .success(CloudASRSegmentResult(text: "然后发给张三")))
        let engine = engineWithFakeSender(sender)

        let finished = expectation(description: "交付")
        var delivered: TranscriptionOutcome?
        engine.transcribe(samples: longAudio(), language: nil, previousText: "",
                          onSegment: nil) { outcome in
            delivered = outcome
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)

        XCTAssertEqual(delivered?.text,
                       CloudTextJoiner.join(["帮我把这段话记下来", "然后发给张三"]))
        XCTAssertEqual(delivered?.completedSegments, 2)
        XCTAssertEqual(delivered?.cancelled, false)
        XCTAssertNil(delivered?.failure)
        XCTAssertEqual(sender.requestCount, 2)
        let body = sender.request(2)?.httpBody
        XCTAssertNotNil(body)
        XCTAssertNotNil(body?.range(of: Data("帮我把这段话记下来".utf8)),
                        "第 2 段必须带上第 1 段的尾巴当上下文")
        XCTAssertNil(sender.request(1)?.httpBody?.range(of: Data("然后发给张三".utf8)),
                     "第 1 段不该知道后面的事")
    }

    /// 让主队列上已经排好的块跑完（回调都投在主队列上）
    private func drainMainQueue() {
        let spin = expectation(description: "main queue drained")
        DispatchQueue.main.async { spin.fulfill() }
        wait(for: [spin], timeout: 2)
    }

    /// 取消之后**不回调**（与 LLMClient 同一约定）：用户按了 Esc 就是把自己放出来了，
    /// 不该再在悬浮窗上弹一句错误。这里用空音频走同一条收口，不碰网络。
    func testCancelledDetailedRequestNeverCallsBack() {
        let engine = CloudASREngine(config: CloudASRConfig(provider: .alibaba, apiKey: "sk-test"))
        var called = false
        let handle = engine.transcribeDetailed(samples: []) { _ in called = true }
        handle.cancel()
        // 让主队列把那个 async 块跑完
        let spin = expectation(description: "main queue drained")
        DispatchQueue.main.async { spin.fulfill() }
        wait(for: [spin], timeout: 2)
        XCTAssertFalse(called, "取消之后不该再回调")
    }
}


/// 假发送器：把 CloudASREngine 的发送缝接管过来，按脚本回结果。
/// 不碰网络、不花钱，却能把多段流程真的跑起来——桥接层的取消语义只有这样才验得到。
final class FakeCloudSender: @unchecked Sendable {

    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var scripted: [Int: Result<CloudASRSegmentResult, CloudASRFailure>] = [:]
    /// 没排结果的那几次 = "还在飞"，完成回调先攒着，等测试自己决定什么时候落地
    private var pending: [(Result<CloudASRSegmentResult, CloudASRFailure>) -> Void] = []

    private var waiters: [Int: XCTestExpectation] = [:]

    /// 第 index 次请求（从 1 起）回什么
    func script(_ index: Int, _ result: Result<CloudASRSegmentResult, CloudASRFailure>) {
        lock.lock()
        scripted[index] = result
        lock.unlock()
    }

    /// 等第 index 次请求真的发出去（段与段之间要过一趟引擎队列，不是同步的）
    func expectRequest(_ index: Int, _ test: XCTestCase) -> XCTestExpectation {
        let waiting = test.expectation(description: "第 \(index) 次请求发出")
        lock.lock()
        let already = requests.count >= index
        if !already { waiters[index] = waiting }
        lock.unlock()
        if already { waiting.fulfill() }
        return waiting
    }

    func send(_ request: URLRequest,
              _ provider: CloudTranscriptionProviding,
              _ handle: CloudASRHandle,
              _ completion: @escaping (Result<CloudASRSegmentResult, CloudASRFailure>) -> Void) {
        lock.lock()
        requests.append(request)
        let planned = scripted[requests.count]
        let waiting = waiters.removeValue(forKey: requests.count)
        if planned == nil { pending.append(completion) }
        lock.unlock()
        waiting?.fulfill()
        if let planned = planned { completion(planned) }
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    /// 第 index 次请求（从 1 起）
    func request(_ index: Int) -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        guard index >= 1, index <= requests.count else { return nil }
        return requests[index - 1]
    }

    /// 在飞的那几次到此为止（模拟超时/限流最终落地）
    func finishPending(_ result: Result<CloudASRSegmentResult, CloudASRFailure>) {
        lock.lock()
        let waiting = pending
        pending = []
        lock.unlock()
        waiting.forEach { $0(result) }
    }

    // MARK: - 老设置（4.0.0 的区域选择器）搬过来

    /// 候选表必须盖住 4.0.0 那个选择器能选的每一档。少一条 = 那一档的老用户升上来之后
    /// 永远试不到自己真正那台主机，表现是"Key 怎么都不对"
    func testWorkspaceSuffixesCoverEveryLegacyRegion() {
        let slugs = LLMCatalog.QwenRegion.allCases.compactMap { $0.regionSlug }
        XCTAssertFalse(slugs.isEmpty)
        for slug in slugs {
            XCTAssertTrue(AlibabaEndpoint.workspaceSuffixes.contains { $0.hasPrefix(slug + ".") },
                          "候选表里没有 \(slug)")
        }
        let candidates = AlibabaEndpoint.candidates(workspace: "ws-abc", legacyRegionSlug: "ap-northeast-1")
        XCTAssertEqual(candidates.first, "ws-abc.ap-northeast-1.maas.aliyuncs.com")
        XCTAssertTrue(candidates.contains("ws-abc.cn-hongkong.maas.aliyuncs.com"))
    }

    /// 东京 / 香港 / US 这三档 4.0.1 的候选表原本一台都拼不出来，靠这一次性迁移把老地址
    /// 种进"上一次试通的那台"，升级当天照常能用
    func testLegacyHostSeedMovesTheOldRegionIntoTheResolvedHost() {
        XCTAssertEqual(AlibabaEndpoint.legacyHostSeed(region: .tokyo, workspaceID: "llm-abc",
                                                      pastedHost: "", resolvedHost: ""),
                       "llm-abc.ap-northeast-1.maas.aliyuncs.com")
        XCTAssertEqual(AlibabaEndpoint.legacyHostSeed(region: .hongkong, workspaceID: "llm-abc",
                                                      pastedHost: "", resolvedHost: ""),
                       "llm-abc.cn-hongkong.maas.aliyuncs.com")
        // US 没有 WorkspaceId，主机名是另一台共享主机——它在任何候选表里都不出现
        XCTAssertEqual(AlibabaEndpoint.legacyHostSeed(region: .us, workspaceID: "",
                                                      pastedHost: "", resolvedHost: ""),
                       "dashscope-us.aliyuncs.com")
    }

    /// 不该种的几种：国际站是出厂默认（种进去只会让探测被白白跳过）、
    /// 已经有答案了（粘过 / 试通过）、以及 WorkspaceId 拼不出合法主机名
    func testLegacyHostSeedStaysOutOfTheWay() {
        XCTAssertNil(AlibabaEndpoint.legacyHostSeed(region: .international, workspaceID: "",
                                                    pastedHost: "", resolvedHost: ""))
        XCTAssertNil(AlibabaEndpoint.legacyHostSeed(region: .tokyo, workspaceID: "llm-abc",
                                                    pastedHost: "my.host.example.com", resolvedHost: ""))
        XCTAssertNil(AlibabaEndpoint.legacyHostSeed(region: .tokyo, workspaceID: "llm-abc",
                                                    pastedHost: "", resolvedHost: "dashscope.aliyuncs.com"))
        // 带下划线的 WorkspaceId 拼出来的主机连 DNS 都不通：不种，留给区域兜底与"粘地址"那条路
        XCTAssertNil(AlibabaEndpoint.legacyHostSeed(region: .beijing, workspaceID: "llm_abc",
                                                    pastedHost: "", resolvedHost: ""))
        // 工作空间区域但没填 WorkspaceId：老设置本来就拼不出地址
        XCTAssertNil(AlibabaEndpoint.legacyHostSeed(region: .beijing, workspaceID: "",
                                                    pastedHost: "", resolvedHost: ""))
    }

    /// WorkspaceId 的字符集必须和 normalizeHost 那张表对得上：放行一个拼出来过不了
    /// normalizeHost 的字符，等于生成几条永远拼不出 URL 的候选，然后静默跳过
    func testWorkspaceIDUsesTheSameCharacterSetAsTheHostName() {
        XCTAssertTrue(AlibabaEndpoint.isWorkspaceID("ws-e9548i71rc13pul7"))
        XCTAssertFalse(AlibabaEndpoint.isWorkspaceID("llm_abc"))
        XCTAssertTrue(AlibabaEndpoint.candidates(workspace: "llm_abc").allSatisfy {
            AlibabaEndpoint.normalizeHost($0) != nil
        })
        XCTAssertNil(AlibabaEndpoint.workspaceID(fromKey: "sk-ws-llm_abc.zzzz"))
    }
}
