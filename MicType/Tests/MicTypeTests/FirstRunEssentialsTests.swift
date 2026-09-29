import XCTest
@testable import MicType

/// 「引导办不完这三件事就不算走完」那条规则本身（用户 2026-09-20 拍板）。
///
/// 这一层判错了不会崩，但会正正好毁掉第一次打开 MicType 的那五分钟：
/// 放行早了，用户走完一遍引导回到文档里轻点，什么都不会发生（他不会认为是权限没给，
/// 他会认为这个 App 坏了）；接续错了，下次启动把已经办完两件事的人又扔回第一屏。
/// 所以判据是纯结构，三个布尔进、两个结论出，逐条钉在这里。
///
/// 5.3.0：三件事是**麦克风、辅助功能、Key**——「识别模型下好了」那一件已经不存在（识别只在云端）。
final class FirstRunEssentialsTests: XCTestCase {

    private func essentials(mic: Bool = true,
                            ax: Bool = true,
                            key: Bool = true) -> FirstRunEssentials {
        FirstRunEssentials(microphone: mic, accessibility: ax, keyReady: key)
    }

    // MARK: - 能不能用

    /// 三件事齐了才算这台 Mac 能听写
    func testCanFinishOnlyWhenEverythingIsDone() {
        XCTAssertTrue(essentials().canFinish)
        XCTAssertFalse(essentials(mic: false).canFinish)
        XCTAssertFalse(essentials(ax: false).canFinish)
        XCTAssertFalse(essentials(key: false).canFinish)
    }

    /// 缺一项权限就不算"权限齐了"——两项是一起的，缺哪一项热键都不工作
    func testPermissionsNeedBoth() {
        XCTAssertTrue(essentials().permissionsGranted)
        XCTAssertFalse(essentials(mic: false).permissionsGranted)
        XCTAssertFalse(essentials(ax: false).permissionsGranted)
        XCTAssertFalse(essentials(mic: false, ax: false).permissionsGranted)
    }

    // MARK: - 下次启动接在哪一屏

    /// 顺序写死：① 按住说话（两项权限）→ ② 贴 Key。「试一下」永远不是断点：
    /// 它要的那两件事在它前面两屏
    func testFirstIncompletePageFollowsTheGuideOrder() {
        XCTAssertEqual(essentials(mic: false, ax: false, key: false).firstIncompletePage, .hold)
        XCTAssertEqual(essentials(mic: false, key: false).firstIncompletePage, .hold)
        XCTAssertEqual(essentials(ax: false, key: false).firstIncompletePage, .hold)
        XCTAssertEqual(essentials(key: false).firstIncompletePage, .key)
        XCTAssertNil(essentials().firstIncompletePage)
    }

    /// 「试一下」永远不是**断点**：没有一件必办的事住在那一屏上
    func testTryItIsNeverTheBlocker() {
        for mic in [true, false] {
            for ax in [true, false] {
                for key in [true, false] {
                    XCTAssertNotEqual(essentials(mic: mic, ax: ax, key: key).firstIncompletePage, .tryIt)
                }
            }
        }
    }

    /// 都办完了也要有个落点：「试一下」——真落一次字再点「开始使用」，那一下才写 onboardingCompleted
    func testResumePageFallsBackToTryIt() {
        XCTAssertEqual(essentials().resumePage, .tryIt)
        XCTAssertEqual(essentials(mic: false).resumePage, .hold)
        XCTAssertEqual(essentials(key: false).resumePage, .key)
    }

    /// 接续的落点必须就是"第一件没办完的事"那一屏，不能悄悄往前挪一屏
    func testResumePageMatchesFirstIncompletePage() {
        for mic in [true, false] {
            for ax in [true, false] {
                for key in [true, false] {
                    let state = essentials(mic: mic, ax: ax, key: key)
                    if let first = state.firstIncompletePage {
                        XCTAssertEqual(state.resumePage, first)
                        XCTAssertFalse(state.canFinish)
                    } else {
                        XCTAssertTrue(state.canFinish)
                    }
                }
            }
        }
    }

    // MARK: - Key 这一位问的是"有没有 Key"，不是"这会儿有没有网"

    /// 没网是一时的：钥匙串里有 Key 的人不该被判成"还差一把 Key"而被拽回引导
    func testKeyReadyIgnoresConnectivity() {
        XCTAssertTrue(RecognitionEngineReadiness.ready.hasKey)
        XCTAssertTrue(RecognitionEngineReadiness.offline.hasKey)
        XCTAssertFalse(RecognitionEngineReadiness.cloudKeyMissing(.openai).hasKey)
    }

    // MARK: - 日志

    /// 日志里只有三个布尔，永远不会带上用户说过的字（Log 的铁律）
    func testLogSummaryCarriesOnlyBooleans() {
        let summary = essentials(mic: false).logSummary
        XCTAssertEqual(summary, "mic=false ax=true key=true")
    }
}
