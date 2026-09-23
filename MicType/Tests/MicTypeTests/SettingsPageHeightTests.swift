import XCTest
import SwiftUI
import AppKit
@testable import MicType

/// 设置正页报给窗口的高度**只能来自内容**（表 + 底栏），不许跟着窗口现在的高度走。
///
/// 为什么值一条测试：用户 2026-09-23 的实机截图里，设置窗口开着约 700 点高，
/// 里面只有三行控件加一条底栏，中间一大片空白——而同一份代码在快照里是 320。
/// 那种差别只可能来自一个地方：**页面把"窗口现在多高"当成了自己的自然高度**
/// （ScrollView 撑满窗口 → 量到的就是窗口高 → 窗口照它再设一遍，于是多高都"合理"）。
/// 这条测试把页面塞进一个 700 高的宿主里，逼它报一次高度。
final class SettingsPageHeightTests: XCTestCase {

    private var savedLanguage: AppLanguage = .zh
    private var savedProvider: Any?

    override func setUp() {
        super.setUp()
        savedLanguage = L10n.shared.language
        savedProvider = UserDefaults.standard.object(forKey: SettingsKeys.llmProvider)
        KeychainHelper.lookupOverride = { _ in "sk-height-test-placeholder" }
    }

    override func tearDown() {
        KeychainHelper.lookupOverride = nil
        if let value = savedProvider {
            UserDefaults.standard.set(value, forKey: SettingsKeys.llmProvider)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKeys.llmProvider)
        }
        L10n.shared.language = savedLanguage
        super.tearDown()
    }

    /// 700 高的宿主里，页面报的仍然是内容那么高（地板 320 上下），不是 700
    @MainActor
    func testPageHeightIgnoresATallHost() {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            for provider in LLMProvider.allCases {
                UserDefaults.standard.set(provider.rawValue, forKey: SettingsKeys.llmProvider)
                let reported = measure(hostHeight: 700)
                XCTAssertGreaterThanOrEqual(reported, SettingsWindowSizing.overviewContentHeight,
                                            "\(provider.rawValue)：低于地板")
                XCTAssertLessThan(reported, 500,
                                  "\(language.rawValue)/\(provider.rawValue)：页面把宿主的高度当成了自己的（报了 \(reported)）")
            }
        }
    }

    /// 同一页在矮宿主和高宿主里报的必须是**同一个数**——只要这两个数不一样，
    /// 窗口高度就会和"上一次窗口多高"有关，而那正是用户看到的那扇 700 点高的空窗
    @MainActor
    func testPageHeightIsTheSameInAShortAndATallHost() {
        L10n.shared.language = .en
        UserDefaults.standard.set(LLMProvider.openai.rawValue, forKey: SettingsKeys.llmProvider)
        let short = measure(hostHeight: 240)
        let tall = measure(hostHeight: 700)
        XCTAssertEqual(short, tall, accuracy: 1, "矮宿主 \(short) vs 高宿主 \(tall)")
    }

    /// 两家之间不许跳：阿里云多一行 API Host，而换一档服务商不该让整扇窗抖一下
    @MainActor
    func testTheTwoProvidersReportTheSameHeight() {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            UserDefaults.standard.set(LLMProvider.openai.rawValue, forKey: SettingsKeys.llmProvider)
            let openai = measure(hostHeight: 700)
            UserDefaults.standard.set(LLMProvider.qwen.rawValue, forKey: SettingsKeys.llmProvider)
            let qwen = measure(hostHeight: 700)
            XCTAssertEqual(openai, qwen, accuracy: 1,
                           "\(language.rawValue)：OpenAI \(openai) vs 阿里云 \(qwen)")
        }
    }

    /// 把 MainSettingsPage 塞进一个给定高度的宿主，收它报上来的那个数
    @MainActor
    private func measure(hostHeight: CGFloat) -> CGFloat {
        var reported: CGFloat = 0
        let probe = MainSettingsPage()
            .onPreferenceChange(SettingsPageHeightKey.self) { heights in
                reported = heights[.overview] ?? 0
            }
        let host = NSHostingView(rootView: AnyView(probe))
        host.frame = NSRect(x: 0, y: 0, width: SettingsWindowSizing.width, height: hostHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        // 屏幕外面：这组测试跑的时候人可能正在用这台 Mac
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        window.orderOut(nil)
        return reported
    }
}
