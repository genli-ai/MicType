import XCTest
import SwiftUI
import AppKit
@testable import MicType

/// 设置窗口的离屏截图。**不是一条断言，是一台相机。**
///
/// 为什么要有它：这台 Mac 上没有录屏权限，而"设置页现在长什么样"恰恰是这次改动里唯一
/// 靠读代码判断不了的事（一段文案是不是被挤成两行、一个框是不是空出一大块、
/// 窗口高度是不是真的跟上了内容）。所以留一个能随时跑一遍、把每一页拍成 PNG 的入口。
///
/// **平时不跑**：没有 `MICTYPE_SNAPSHOT_DIR` 这个环境变量就整组跳过——它要开窗口、要 GPU、
/// 每张图几百毫秒，不该挂在每次 `xcodebuild test` 上。要看图就这么跑：
///
/// ```
/// TEST_RUNNER_MICTYPE_SNAPSHOT_DIR=/tmp/shots xcodebuild test -scheme MicType \
///   -destination 'platform=macOS,arch=arm64' -only-testing:MicTypeTests/SettingsSnapshotTests
/// ```
///
/// 两条纪律（这是一个会在别人机器上跑的测试）：
///   • **不碰钥匙串**——KeychainHelper.lookupOverride 装一个假的（见那里的注释）；
///   • **不弄脏用户的设置**——用到的 UserDefaults 键在 setUp 里逐个存下来，tearDown 原样写回。
///     这一点做不到彻底隔离：视图层读的是 @AppStorage / Settings.shared，也就是
///     UserDefaults.standard，没有注入 suite 的缝。所以走的是"存下来再放回去"这条路。
final class SettingsSnapshotTests: XCTestCase {

    /// 拍摄用的宽度：和真窗口一样，否则量出来的换行都不算数
    private let width = SettingsWindowSizing.width

    /// 这几条设置会被摆布，跑完原样放回去
    private static let touchedKeys = [
        SettingsKeys.appLanguage,
        SettingsKeys.customVocabulary,
        SettingsKeys.customPolishRules,
        SettingsKeys.llmProvider,
        SettingsKeys.polishLevel,
        SettingsKeys.recognitionEngine,
        SettingsKeys.recognitionLanguage,
        SettingsKeys.chatModel,
        SettingsKeys.openaiCommandModel,
        SettingsKeys.qwenModel,
        SettingsKeys.qwenCommandModel,
        SettingsKeys.webSearchEnabled,
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
        // 钥匙串的替身：OpenAI 与阿里云都"有 Key"，这样「云端 AI」页才会摆出
        // 模型下拉与（阿里云那一档的）云端识别开关——没有 Key 的那半页什么都看不到
        KeychainHelper.lookupOverride = { account in
            account.contains("deepseek") ? nil : "sk-snapshot-placeholder"
        }
        seedRepresentativeSettings()
    }

    override func tearDownWithError() throws {
        KeychainHelper.lookupOverride = nil
        let defaults = UserDefaults.standard
        for (key, value) in savedDefaults {
            if let value = value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        L10n.shared.language = savedLanguage
        SettingsNavigator.shared.go(to: .overview)
        try super.tearDownWithError()
    }

    /// 截图里要有东西可看：空词汇表、空规则的那一页证明不了任何排版问题
    private func seedRepresentativeSettings() {
        let defaults = UserDefaults.standard
        defaults.set("Power BI, Microsoft Excel, Rappel, 云术法, MicType, Qwen, DashScope, MLX,"
                     + " Stern, Abu Dhabi, 杰文=捷文",
                     forKey: SettingsKeys.customVocabulary)
        defaults.set("署名用 Gen；邮件偏正式；英文术语保留原文。",
                     forKey: SettingsKeys.customPolishRules)
        defaults.set(PolishLevel.smart.rawValue, forKey: SettingsKeys.polishLevel)
        defaults.set(RecognitionLanguages.autoCode, forKey: SettingsKeys.recognitionLanguage)
        defaults.set(true, forKey: SettingsKeys.webSearchEnabled)
    }

    // MARK: - 拍照

    @MainActor
    func testRenderSettingsPages() throws {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            let tag = language == .zh ? "zh" : "en"

            useProvider(.openai, cloudRecognition: false)
            shoot(.overview, name: "overview-\(tag)")
            shoot(.input, name: "input-\(tag)")
            // 「写作偏好」那一段整个入画：这一页比窗口高，按窗口高度拍只看得到最上面两段
            shoot(.input, name: "input-writing-preferences-\(tag)", fullHeight: true)
            shoot(.recognition, name: "recognition-\(tag)")
            shoot(.cloud, name: "cloud-openai-\(tag)")

            useProvider(.qwen, cloudRecognition: true)
            shoot(.cloud, name: "cloud-alibaba-\(tag)")

            // 「只用本地」那一档：自定义规则下面那句「开启 AI 后生效」只有这时候才在屏幕上
            UserDefaults.standard.set(PolishLevel.off.rawValue, forKey: SettingsKeys.polishLevel)
            useProvider(.openai, cloudRecognition: false)
            shoot(.input, name: "input-local-only-\(tag)", fullHeight: true)
            UserDefaults.standard.set(PolishLevel.smart.rawValue, forKey: SettingsKeys.polishLevel)
        }
        print("[snapshot] PNGs written to \(outputDirectory.path)")
    }

    /// 摆出"正在用这一档"的状态。云端识别开关只在**生效档是阿里云**时才渲染
    private func useProvider(_ provider: LLMProvider, cloudRecognition: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue, forKey: SettingsKeys.llmProvider)
        defaults.set(cloudRecognition ? RecognitionEngineChoice.cloudAlibaba.rawValue
                                      : RecognitionEngineChoice.local.rawValue,
                     forKey: SettingsKeys.recognitionEngine)
        defaults.set(LLMCatalog.defaultModel(for: provider),
                     forKey: provider == .qwen ? SettingsKeys.qwenModel : SettingsKeys.chatModel)
        defaults.set(LLMCatalog.defaultModel(for: provider),
                     forKey: provider == .qwen ? SettingsKeys.qwenCommandModel
                                               : SettingsKeys.openaiCommandModel)
    }

    /// 一页 → 一张 PNG。两趟渲染：第一趟把页面自然高度量出来（和真窗口同一条路，
    /// 走 SettingsPageHeightKey），第二趟按算出来的窗口高度重拍。
    /// - fullHeight: 不按窗口上限截断，整页入画（用来看"下面还有什么"）
    @MainActor
    private func shoot(_ route: SettingsRoute, name: String, fullHeight: Bool = false) {
        SettingsNavigator.shared.go(to: route)

        var natural: CGFloat = 0
        var chrome: CGFloat = 0
        // resizesWindow: false —— 这一份 SettingsView 住在我们自己的离屏窗口里，
        // 绝不能让它去改真正那扇设置窗口的尺寸
        let probe = SnapshotProbe(route: route,
                                  content: SettingsView(resizesWindow: false),
                                  onPage: { natural = $0 },
                                  onChrome: { chrome = $0 })

        // 第一趟给一个够高的画布：矮了的话 ScrollView 里那一叠会被压着量
        let (probeWindow, probeHost) = makeWindow(height: 4000)
        probeHost.rootView = AnyView(probe)
        settle(probeHost)
        probeWindow.orderOut(nil)

        let content = fullHeight
            ? min(max(natural + chrome, SettingsWindowSizing.minContentHeight), 4000)
            : SettingsWindowSizing.contentHeight(natural: natural + chrome,
                                                 visibleScreenHeight: screenHeight)
        let (window, host) = makeWindow(height: content)
        host.rootView = AnyView(SettingsView(resizesWindow: false))
        settle(host)
        write(host: host, to: name)
        window.orderOut(nil)
        print("[snapshot] \(name): page=\(Int(natural)) chrome=\(Int(chrome)) window=\(Int(content))")
    }

    private var screenHeight: CGFloat {
        NSScreen.main?.visibleFrame.height ?? 900
    }

    /// 离屏窗口 + NSHostingView。**必须是真窗口**：AppKit 背书的控件（TextEditor、Picker、
    /// 分段选择器）不挂在窗口上就画不出来——SwiftUI 的 ImageRenderer 同理，所以这里不用它。
    @MainActor
    private func makeWindow(height: CGFloat) -> (NSWindow, NSHostingView<AnyView>) {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        // 屏幕外面：这组测试跑的时候人可能正在用这台 Mac，别往他脸上弹窗
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        return (window, host)
    }

    /// 让 SwiftUI 把这一帧算完：onAppear、preference 回传、异步的状态更新都要跑完一轮 runloop
    @MainActor
    private func settle(_ host: NSHostingView<AnyView>) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
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
        let url = outputDirectory.appendingPathComponent(name + ".png")
        do {
            try data.write(to: url)
        } catch {
            XCTFail("写不出 \(url.path)：\(error)")
        }
    }
}

/// 把页面的自然高度从 preference 里接出来（真窗口走的是同一条路，见 SettingsView）
private struct SnapshotProbe<Content: View>: View {
    let route: SettingsRoute
    let content: Content
    let onPage: (CGFloat) -> Void
    let onChrome: (CGFloat) -> Void

    var body: some View {
        content
            .onPreferenceChange(SettingsPageHeightKey.self) { heights in
                if let height = heights[route] { onPage(height) }
            }
            .onPreferenceChange(SettingsChromeHeightKey.self) { onChrome($0) }
    }
}
