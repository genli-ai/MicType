import XCTest
@testable import MicType

/// 录音计时文案的单测。这行字（「8:30 / 10:00」）是用户判断"还能说多久"的唯一依据，
/// 所以分秒进位、上限封顶这些地方一个都不能错。
final class RecordingClockTests: XCTestCase {

    func testFormatsMinutesAndSeconds() {
        XCTAssertEqual(DictationController.recordingTimeLabel(elapsed: 510, limit: 600),
                       "8:30 / 10:00")
        XCTAssertEqual(DictationController.recordingTimeLabel(elapsed: 125, limit: 600),
                       "2:05 / 10:00")
    }

    /// 秒数永远两位：2:5 会被读成"两分五秒"还是"两分五十秒"，谁也说不准
    func testSecondsAreAlwaysTwoDigits() {
        XCTAssertEqual(DictationController.clockText(61), "1:01")
        XCTAssertEqual(DictationController.clockText(600), "10:00")
        XCTAssertEqual(DictationController.clockText(0), "0:00")
    }

    /// 不足一秒向下取整：显示 0:01 的时候必须是真的过了 1 秒
    func testTruncatesTowardsZero() {
        XCTAssertEqual(DictationController.clockText(0.9), "0:00")
        XCTAssertEqual(DictationController.clockText(59.9), "0:59")
    }

    /// 到点收尾和时钟刷新之间有几十毫秒的空隙，别让用户看见 10:01 / 10:00
    func testElapsedIsClampedToTheLimit() {
        XCTAssertEqual(DictationController.recordingTimeLabel(elapsed: 601, limit: 600),
                       "10:00 / 10:00")
        XCTAssertEqual(DictationController.recordingTimeLabel(elapsed: -1, limit: 600),
                       "0:00 / 10:00")
    }

    // MARK: 设置页那句说明里的数字

    /// 上限 600 s、预警提前 30 s：这两个常量是"录音会不会被突然掐断"的全部答案
    func testRecordingLimitsAreTheMeasuredOnes() {
        XCTAssertEqual(DictationController.maxRecordingSeconds, 600)
        XCTAssertEqual(DictationController.preFinishWarningSeconds, 30)
    }

    /// 设置 → 录音 那句说明里的数字**必须来自常量**（写死的数字迟早和代码对不上，
    /// 而这行字是用户唯一能查到上限的地方）
    func testRecordingCopyReadsTheConstants() {
        let flows: [DictationController.RecordingFlow] = [.progressiveLocal, .cloudStreaming,
                                                          .cloudUpload]
        for language in AppLanguage.allCases {
            let saved = L10n.shared.language
            L10n.shared.language = language
            defer { L10n.shared.language = saved }
            for flow in flows {
                let copy = DictationController.recordingLimitCopy(flow: flow)
                XCTAssertTrue(copy.contains(DictationController.minutesLabel(
                    DictationController.maxRecordingSeconds)), "\(language) \(flow): \(copy)")
                XCTAssertTrue(copy.contains(DictationController.secondsLabel(
                    DictationController.preFinishWarningSeconds)), "\(language) \(flow): \(copy)")
                // 段长只有**真的分段**的那两条路才说：实时那条不分段，写个段长就是假话
                XCTAssertEqual(copy.contains(DictationController.secondsLabel(
                    AudioSegmenter.targetSeconds)), flow != .cloudStreaming,
                               "\(language) \(flow): \(copy)")
            }
            // 当前设置那一版（界面真正渲染的就是它）同样要说全上限与预警
            let live = DictationController.recordingLimitCopy
            XCTAssertTrue(live.contains(DictationController.minutesLabel(
                DictationController.maxRecordingSeconds)), "\(language): \(live)")
        }
    }

    /// 三条路三句话，一句都不能互相抄：本机是录音中就转，云端实时是边说边传、整段一次出，
    /// 云端整段上传是松手之后才分段传。写混了，用户就会去等一个不会出现的逐段进度
    func testRecordingCopyDistinguishesEveryFlow() {
        for language in AppLanguage.allCases {
            let saved = L10n.shared.language
            L10n.shared.language = language
            defer { L10n.shared.language = saved }
            let local = DictationController.recordingLimitCopy(flow: .progressiveLocal)
            let streaming = DictationController.recordingLimitCopy(flow: .cloudStreaming)
            let upload = DictationController.recordingLimitCopy(flow: .cloudUpload)
            XCTAssertEqual(Set([local, streaming, upload]).count, 3, "\(language)：三档必须各说各的")
            // ⓘ 的预算是中文 ≤ 120 字，而这三句前面还挂着"草稿只在悬浮窗里"那一句
            if language == .zh {
                for copy in [local, streaming, upload] {
                    XCTAssertLessThanOrEqual(copy.count, 100, copy)
                }
            }
        }
        L10n.shared.language = .en
        XCTAssertTrue(DictationController.recordingLimitCopy(flow: .progressiveLocal)
            .contains("transcribed while you speak"))
        // 云端整段上传那一档不能承诺录音过程中就在传，更不能承诺在转
        XCTAssertFalse(DictationController.recordingLimitCopy(flow: .cloudUpload)
            .contains("as you speak"), "整段上传那一档不能承诺边说边传")
        // 实时那一档必须说清是边说边传（这正是它与上一档的全部区别）
        XCTAssertTrue(DictationController.recordingLimitCopy(flow: .cloudStreaming)
            .contains("as you speak"))
        XCTAssertFalse(DictationController.recordingLimitCopy(flow: .cloudStreaming)
            .contains("transcribed while you speak"), "实时是在传，不是在本机转")
        L10n.shared.language = .zh
        XCTAssertTrue(DictationController.recordingLimitCopy(flow: .cloudStreaming)
            .contains("不分段"))
    }

    /// 走哪条路由设置 + 这次运行的实时可用性决定（纯函数拿不到的那一半）
    func testRecordingFlowFollowsTheEngineAndStreamingAvailability() {
        let saved = Settings.shared.recognitionEngine
        defer {
            Settings.shared.recognitionEngine = saved
            CloudStreamingAvailability.resetForTesting()
        }
        CloudStreamingAvailability.resetForTesting()
        Settings.shared.recognitionEngine = .local
        XCTAssertEqual(DictationController.currentRecordingFlow(), .progressiveLocal)
        Settings.shared.recognitionEngine = .cloudOpenAI
        XCTAssertEqual(DictationController.currentRecordingFlow(), .cloudUpload,
                       "OpenAI 那一档没有实时接口")
        Settings.shared.recognitionEngine = .cloudAlibaba
        XCTAssertEqual(DictationController.currentRecordingFlow(), .cloudStreaming)
        // 这台主机这次运行里被判过"实时用不了"：那句话得换回整段上传那一版
        let s = Settings.shared
        let host = CloudASRSettings.alibabaHost(pastedHost: s.qwenAPIHost,
                                                resolvedHost: s.qwenResolvedHost,
                                                workspace: s.qwenWorkspaceID,
                                                legacyRegionSlug: s.qwenRegion.regionSlug,
                                                apiKey: "")
        CloudStreamingAvailability.markUnsupported(host: host, reason: "test")
        XCTAssertEqual(DictationController.currentRecordingFlow(), .cloudUpload)
    }

    // MARK: 处理中按 Esc 到底是什么意思

    /// 胶囊/菜单项的字与 cancel() 的行为必须由同一个判据决定——
    /// 这条判据一旦和文案脱节，用户点的就是一颗写着"取消"、点下去却往文档里打字的按钮
    func testEscFinishesEarlyOnlyWhenSomethingCanBeDelivered() {
        // 已经转出段落 / 录音中预转写过 → 第一次 Esc 是"收尾并输入"
        XCTAssertTrue(DictationController.escFinishesEarly(
            completedSegments: 2, hasLiveParts: false, isSkillSession: false))
        XCTAssertTrue(DictationController.escFinishesEarly(
            completedSegments: 0, hasLiveParts: true, isSkillSession: false))
        // 手上什么都没有 → 就是普通取消
        XCTAssertFalse(DictationController.escFinishesEarly(
            completedSegments: 0, hasLiveParts: false, isSkillSession: false))
        // 指令会话永远不部分交付：半句指令绝不能拿去执行
        XCTAssertFalse(DictationController.escFinishesEarly(
            completedSegments: 3, hasLiveParts: true, isSkillSession: true))
    }

    func testDurationLabels() {
        L10n.shared.language = .en
        XCTAssertEqual(DictationController.minutesLabel(600), "10 minutes")
        XCTAssertEqual(DictationController.secondsLabel(45), "45s")
        // 不是整分钟就按秒说（常量以后改成 90 s 也不会被读成 2 分钟）
        XCTAssertEqual(DictationController.minutesLabel(90), "90s")
        L10n.shared.language = .zh
        XCTAssertEqual(DictationController.minutesLabel(600), "10 分钟")
        XCTAssertEqual(DictationController.secondsLabel(45), "45 秒")
    }

    // MARK: 每段的 token 预算

    /// 秒数 × 8 + 64（实测峰值出字速率 3.5 字/秒，两倍余量）。
    /// 库的默认 4096 会让密集语音在约 3.4 分钟处**静默截断**，所以每段都必须显式传。
    func testSegmentTokenBudget() {
        XCTAssertEqual(QwenModels.segmentMaxTokens(seconds: 45), 424)
        XCTAssertEqual(QwenModels.segmentMaxTokens(seconds: 0), 64)
        XCTAssertEqual(QwenModels.segmentMaxTokens(seconds: -3), 64)
        // 比库内部那条上限（秒数 × 20 + 64）更紧：跑飞的那一段烧不了多久
        XCTAssertLessThan(QwenModels.segmentMaxTokens(seconds: 45), Int(ceil(45 * 20)) + 64)
    }
}
