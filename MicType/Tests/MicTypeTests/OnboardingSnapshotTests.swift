import XCTest
import SwiftUI
import AppKit
@testable import MicType

/// 引导五屏的离屏截图。**不是一条断言，是一台相机**（同 SettingsSnapshotTests）。
///
/// 为什么非要有它：这台 Mac 没给终端屏幕录制权限，而引导是**只有第一次打开 MicType 的人
/// 才看得到**的界面——改完之后连"它现在长什么样"都没办法确认一次。
/// 4.3.4 给它加了键盘示意图和一整屏「它在哪」，正是最容易在英文下被撑破版式的两处。
///
/// 平时不跑（没有 `MICTYPE_SNAPSHOT_DIR` 就整组跳过）。要看图：
///
/// ```
/// TEST_RUNNER_MICTYPE_SNAPSHOT_DIR=/tmp/shots xcodebuild test -scheme MicType \
///   -destination 'platform=macOS,arch=arm64' -only-testing:MicTypeTests/OnboardingSnapshotTests
/// ```
///
/// 三条纪律（这是一个会在别人机器上跑的测试）：
///   • **不碰钥匙串**（KeychainHelper.lookupOverride 装一个假的）；
///   • **不弄脏用户的设置**（用到的键 setUp 里存下来，tearDown 原样写回）；
///   • **不许有任何真实副作用**——识别档摆成云端，免得权限页的 onAppear 在一台
///     没下过模型的机器上真的开始下 860MB；引导窗口没开着，所以最后一屏
///     不会去动系统登录项（见 DonePage.armLaunchAtLogin）。
final class OnboardingSnapshotTests: XCTestCase {

    /// 和真窗口一样的宽度，否则量出来的换行都不算数（高度按内容现算，见 shoot）
    private let width: CGFloat = OnboardingWindowSizing.width
    /// 假装是一块 13 寸 MacBook Air 的可见高度：上限那条路（可见屏高 − 120）要真的被走一遍
    private let screenHeight: CGFloat = 868

    private static let touchedKeys = [
        SettingsKeys.appLanguage,
        SettingsKeys.llmProvider,
    ]

    private var savedDefaults: [String: Any?] = [:]
    private var savedLanguage: AppLanguage = .zh
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let path = ProcessInfo.processInfo.environment["MICTYPE_SNAPSHOT_DIR"],
              !path.isEmpty else {
            throw XCTSkip("设置 MICTYPE_SNAPSHOT_DIR 才拍照（见文件头的命令）")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true)
        savedLanguage = L10n.shared.language
        let defaults = UserDefaults.standard
        for key in Self.touchedKeys { savedDefaults[key] = defaults.object(forKey: key) }
        KeychainHelper.lookupOverride = { _ in "sk-snapshot-placeholder" }
        // 阿里云：第三屏这一档控件最全（服务商 / Key / 接入地址），OpenAI 那一档少一行
        defaults.set(LLMProvider.qwen.rawValue, forKey: SettingsKeys.llmProvider)
    }

    override func tearDownWithError() throws {
        KeychainHelper.lookupOverride = nil
        let defaults = UserDefaults.standard
        for (key, value) in savedDefaults {
            if let value = value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        L10n.shared.language = savedLanguage
        try super.tearDownWithError()
    }

    @MainActor
    func testRenderOnboardingPages() throws {
        let names: [(OnboardingPage, String)] = [
            (.welcome, "onboarding-1-welcome"),
            (.permissions, "onboarding-2-permissions"),
            (.howYouUse, "onboarding-3-how-you-use"),
            (.tryIt, "onboarding-4-try-it"),
            (.done, "onboarding-5-done"),
        ]
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            let tag = language == .zh ? "zh" : "en"
            for (page, name) in names {
                shoot(page, name: "\(name)-\(tag)")
            }
        }
        print("[snapshot] PNGs written to \(outputDirectory.path)")
    }

    /// 一屏 → 一张 PNG
    @MainActor
    private func shoot(_ page: OnboardingPage, name: String) {
        let model = OnboardingModel()
        model.page = page
        // 权限那一屏拍"未授权"态：那才是第一次打开的人看到的样子，
        // 而且 micOK = false 时不会渲染 MicCheckPanel（它会真的打开麦克风）
        model.micOK = false
        model.axOK = false
        model.refreshAIReady()

        let host = NSHostingView(rootView: AnyView(OnboardingView(model: model)))
        // **和真窗口同一条路**（OnboardingWindowController.applyFittedHeight）：
        // 按目标宽度排一遍版 → 问 fittingSize → 过一遍 OnboardingWindowSizing。
        // 写死 470 的话这组图既看不出留白也看不出裁切，而这一版要看的正是这两件事
        host.frame = NSRect(x: 0, y: 0, width: width, height: OnboardingWindowSizing.minContentHeight)
        host.layoutSubtreeIfNeeded()
        let natural = host.fittingSize.height
        let fitted = OnboardingWindowSizing.contentHeight(natural: natural,
                                                          visibleScreenHeight: screenHeight)
        // 图上看不出"差一点点"：裁掉两三个像素的截图和没裁的长得一样，所以这里断言一次
        XCTAssertGreaterThanOrEqual(fitted, natural, "\(name)：窗口给的高度装不下这一屏")
        let frame = NSRect(x: 0, y: 0, width: width, height: fitted)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        // 屏幕外面：这组测试跑的时候人可能正在用这台 Mac，别往他脸上弹窗
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()

        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        write(host: host, to: name)
        window.orderOut(nil)
        print("[snapshot] \(name): natural=\(Int(natural)) window=\(Int(fitted))")
    }

    @MainActor
    private func write(host: NSView, to name: String) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("拿不到位图：\(name)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("PNG 编码失败：\(name)")
            return
        }
        do {
            try data.write(to: outputDirectory.appendingPathComponent(name + ".png"))
        } catch {
            XCTFail("写不出 \(name)：\(error)")
        }
    }
}
