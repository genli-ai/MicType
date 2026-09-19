import XCTest
@testable import MicType

/// 「引导办不完这三件事就不算走完」那条规则本身（用户 2026-09-20 拍板）。
///
/// 这一层判错了不会崩，但会正正好毁掉第一次打开 MicType 的那五分钟：
/// 放行早了，用户走完一遍引导回到文档里轻点，什么都不会发生（他不会认为是权限没给，
/// 他会认为这个 App 坏了）；接续错了，下次启动把已经办完两件事的人又扔回第一屏。
/// 所以判据是纯结构，四个布尔进、两个结论出，逐条钉在这里。
final class FirstRunEssentialsTests: XCTestCase {

    private func essentials(hotkey: Bool = true,
                            mic: Bool = true,
                            ax: Bool = true,
                            model: Bool = true) -> FirstRunEssentials {
        FirstRunEssentials(hotkeyConfirmed: hotkey, microphone: mic,
                           accessibility: ax, modelReady: model)
    }

    // MARK: - 能不能点「完成」

    /// 三件事齐了才放行
    func testCanFinishOnlyWhenEverythingIsDone() {
        XCTAssertTrue(essentials().canFinish)
        XCTAssertFalse(essentials(hotkey: false).canFinish)
        XCTAssertFalse(essentials(mic: false).canFinish)
        XCTAssertFalse(essentials(ax: false).canFinish)
        XCTAssertFalse(essentials(model: false).canFinish)
    }

    /// 缺一项权限就不算"权限齐了"——两项是一起的，缺哪一项热键都不工作
    func testPermissionsNeedBoth() {
        XCTAssertTrue(essentials().permissionsGranted)
        XCTAssertFalse(essentials(mic: false).permissionsGranted)
        XCTAssertFalse(essentials(ax: false).permissionsGranted)
        XCTAssertFalse(essentials(mic: false, ax: false).permissionsGranted)
    }

    // MARK: - 下次启动接在哪一屏

    /// 顺序写死：欢迎（选键）→ 权限 →「试一下」（模型要在这里就绪）
    func testFirstIncompletePageFollowsTheGuideOrder() {
        XCTAssertEqual(essentials(hotkey: false, mic: false, ax: false, model: false)
                        .firstIncompletePage, .welcome)
        XCTAssertEqual(essentials(mic: false, model: false).firstIncompletePage, .permissions)
        XCTAssertEqual(essentials(ax: false, model: false).firstIncompletePage, .permissions)
        XCTAssertEqual(essentials(model: false).firstIncompletePage, .tryIt)
        XCTAssertNil(essentials().firstIncompletePage)
    }

    /// 「怎么用」（AI）**永远**不在这条链上：轻点听写压根不需要 Key，
    /// 把它做成任何人的断点都等于骗人
    func testAIPageIsNeverABlocker() {
        for hotkey in [true, false] {
            for mic in [true, false] {
                for ax in [true, false] {
                    for model in [true, false] {
                        let page = essentials(hotkey: hotkey, mic: mic, ax: ax, model: model)
                            .firstIncompletePage
                        XCTAssertNotEqual(page, .howYouUse)
                    }
                }
            }
        }
    }

    /// 都办完了也要有个落点：最后一屏——那一下「完成」才是 onboardingCompleted 真正写进去的时刻
    func testResumePageFallsBackToTheLastPage() {
        XCTAssertEqual(essentials().resumePage, .tryIt)
        XCTAssertEqual(essentials(hotkey: false).resumePage, .welcome)
        XCTAssertEqual(essentials(mic: false).resumePage, .permissions)
        XCTAssertEqual(essentials(model: false).resumePage, .tryIt)
    }

    /// 接续的落点必须就是"第一件没办完的事"那一屏，不能悄悄往前挪一屏
    func testResumePageMatchesFirstIncompletePage() {
        for hotkey in [true, false] {
            for mic in [true, false] {
                for model in [true, false] {
                    let state = essentials(hotkey: hotkey, mic: mic, model: model)
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

    // MARK: - 日志

    /// 日志里只有四个布尔，永远不会带上用户说过的字（Log 的铁律）
    func testLogSummaryCarriesOnlyBooleans() {
        let summary = essentials(mic: false).logSummary
        XCTAssertEqual(summary, "hotkey=true mic=false ax=true model=true")
    }
}
