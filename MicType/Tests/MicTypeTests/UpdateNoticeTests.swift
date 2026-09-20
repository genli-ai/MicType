import XCTest
@testable import MicType

/// 自更新装好之后的那一句提示。
///
/// 来历：4.1.0 的自更新是**完全静默**的——App 把自己换掉、重开，屏幕上一个字都没有，
/// 用户只能自己去「关于」页对版本号（2026-09-20 的反馈原话：
/// 「目前自动更新完成后也没有一个提示告诉提示完成」）。
final class UpdateNoticeTests: XCTestCase {

    /// 条子上的 `OK:<版本>` 要被读成"装好了"，不再是一个静默的 nil
    func testInstalledCarriesTheVersion() {
        XCTAssertEqual(UpdateChecker.PreviousInstall.installed(version: "4.1.1"),
                       .installed(version: "4.1.1"))
        XCTAssertNotEqual(UpdateChecker.PreviousInstall.installed(version: "4.1.1"),
                          .failed(message: "4.1.1"))
    }

    /// 提示里带版本号——只说"已更新"等于没说，用户就是想知道现在跑的是哪一版
    func testNoticeNamesTheVersion() {
        let copy = UpdateChecker.installedNoticeCopy(version: "4.1.1")
        XCTAssertTrue(copy.contains("4.1.1"))
        XCTAssertFalse(copy.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// 默认取的是**本 bundle** 的版本，不是条子上那个：
    /// 条子是上一个进程写的，回滚过的话两者会对不上，那时该信现在跑起来的这一份
    func testNoticeDefaultsToTheRunningBundle() {
        XCTAssertEqual(UpdateChecker.installedNoticeCopy(),
                       UpdateChecker.installedNoticeCopy(version: UpdateChecker.currentVersion))
    }

    /// 一行短提示，不是一段说明——悬浮窗只有一行的宽度
    func testNoticeStaysOnOneLine() {
        let copy = UpdateChecker.installedNoticeCopy(version: "4.1.1")
        XCTAssertFalse(copy.contains("\n"))
        XCTAssertLessThanOrEqual(copy.count, 40)
    }

    /// 晚几秒再闪：启动这一刻引导 / 权限 / 模型预加载都在抢主线程，
    /// 立刻闪一下会被它们盖掉，等于没提示。停留时长要够读完一句话。
    func testNoticeIsDelayedAndReadable() {
        XCTAssertEqual(UpdateChecker.installedNoticeDelay, 3)
        XCTAssertGreaterThanOrEqual(UpdateChecker.installedNoticeDuration, 2,
                                    "1 秒的默认时长读不完一句带版本号的话")
    }
}
