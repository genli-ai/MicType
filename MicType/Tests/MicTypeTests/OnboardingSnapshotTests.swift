import XCTest
import SwiftUI
import AppKit
@testable import MicType

/// 引导三屏的离屏截图：3 屏 × 中英 × 深浅 = 12 张。**不是一条断言，是一台相机**（同 SettingsSnapshotTests）。
///
/// 为什么非要有它：这台 Mac 没给终端屏幕录制权限，而引导是**只有第一次打开 MicType 的人
/// 才看得到**的界面——改完之后连"它现在长什么样"都没办法确认一次。5.3.0 起它还跟系统外观走，
/// 浅色那一套只有在这里才看得见。
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
///   • **不许有任何真实副作用**——引导窗口没开着，所以 ② 不读剪贴板、③ 不动系统登录项。
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
        defaults.set(LLMProvider.openai.rawValue, forKey: SettingsKeys.llmProvider)
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
            (.hold, "onboarding-1-hold"),
            (.key, "onboarding-2-key"),
            (.tryIt, "onboarding-3-try-it"),
        ]
        for dark in [true, false] {
            for language in [AppLanguage.zh, .en] {
                L10n.shared.language = language
                let tag = (language == .zh ? "zh" : "en") + (dark ? "-dark" : "-light")
                for (page, name) in names {
                    shoot(page, name: "\(name)-\(tag)", dark: dark)
                }
            }
        }
        print("[snapshot] PNGs written to \(outputDirectory.path)")
    }

    /// 一屏 → 一张 PNG
    @MainActor
    private func shoot(_ page: OnboardingPage, name: String, dark: Bool) {
        let model = OnboardingModel()
        model.page = page
        // ① 拍"一项已授权、一项没有"的样子：两种状态圆同一张图里都看得见
        model.micOK = true
        model.axOK = false
        model.refreshAIReady()
        // ③ 拍"字已经落进来"的那一刻（「就是这样…」+「开始使用」）——那是这一屏要被看的样子。
        // 权限摆成齐的：否则按钮是「先跳过」
        if page == .tryIt {
            model.axOK = true
            model.appendTryItText(language == .zh ? "明天下午三点开会。" : "Meeting tomorrow at 3 pm.")
        }

        let host = NSHostingView(rootView: AnyView(OnboardingView(model: model)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: OnboardingWindowSizing.minContentHeight)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        host.layoutSubtreeIfNeeded()
        let natural = host.fittingSize.height
        let fitted = OnboardingWindowSizing.contentHeight(natural: natural,
                                                          visibleScreenHeight: screenHeight)
        XCTAssertGreaterThanOrEqual(fitted, natural, "\(name)：窗口给的高度装不下这一屏")
        let frame = NSRect(x: 0, y: 0, width: width, height: fitted)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        // 屏幕外面：这组测试跑的时候人可能正在用这台 Mac，别往他脸上弹窗
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()

        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        write(host: host, to: name)
        window.orderOut(nil)
        print("[snapshot] \(name): natural=\(Int(natural)) window=\(Int(fitted))")
    }

    private var language: AppLanguage { L10n.shared.language }

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
