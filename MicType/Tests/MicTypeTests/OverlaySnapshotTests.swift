import XCTest
import SwiftUI
import AppKit
@testable import MicType

/// 悬浮窗六种形态（听 / 想 / 落 / 指令 / 错 / 告知）的离屏截图（中 / 英各一张）。和 SettingsSnapshotTests 一样**是一台相机，不是断言**：
/// 这台 Mac 没有录屏权限，而"胶囊现在长什么样"读代码判断不了。
///
/// **平时不跑**：没有 `MICTYPE_SNAPSHOT_DIR` 就整组跳过。要看图：
///
/// ```
/// TEST_RUNNER_MICTYPE_SNAPSHOT_DIR=/tmp/shots xcodebuild test -scheme MicType \
///   -destination 'platform=macOS,arch=arm64' -derivedDataPath .xcbuild \
///   -only-testing:MicTypeTests/OverlaySnapshotTests
/// ```
///
/// 画布照设计稿（uxcanvas 的 Overlay-*.dc.html）：720 × 200 的深色底、上方一块示意窗口、
/// 胶囊贴底 28 pt。材质走回退那条路（GlassFallback.forced）：系统玻璃由窗口服务器合成，
/// cacheDisplay 拍不到它，拍出来会是一块透明——回退路与设计稿同为 90% 黑。
final class OverlaySnapshotTests: XCTestCase {

    private var outputDirectory: URL!
    private var savedLanguage: AppLanguage = .zh

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let path = ProcessInfo.processInfo.environment["MICTYPE_SNAPSHOT_DIR"],
              !path.isEmpty else {
            throw XCTSkip("设置 MICTYPE_SNAPSHOT_DIR 才拍照（见文件头的命令）")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        savedLanguage = L10n.shared.language
        GlassFallback.forced = true
    }

    override func tearDownWithError() throws {
        GlassFallback.forced = false
        L10n.shared.language = savedLanguage
        try super.tearDownWithError()
    }

    @MainActor
    func testRenderOverlayPhases() throws {
        for language in [AppLanguage.zh, .en] {
            L10n.shared.language = language
            let tag = language == .zh ? "zh" : "en"

            shoot("overlay-listening-\(tag)", height: 200) { state in
                state.phase = .listening
                state.level = 0.7
                state.charCount = 42
                Self.warmWaveform(state)
            }
            shoot("overlay-thinking-\(tag)", height: 200) { state in
                state.phase = .thinking
            }
            shoot("overlay-done-\(tag)", height: 200) { state in
                let body = language == .zh
                    ? OverlayDoneLine.make(raw: "那个我明天下午嗯三点开会", final: "明天下午三点开会。")
                    : OverlayDoneLine.make(raw: "um so I think we should uh meet", final: "I think we should meet.")
                state.phase = .done(OverlayDone(body: body, revertible: true))
            }
            shoot("overlay-command-\(tag)", height: 240) { state in
                state.phase = .command
                state.level = 0.6
                Self.warmWaveform(state)
            }
            shoot("overlay-error-\(tag)", height: 200) { state in
                let message = RecognitionEngineReadiness.cloudKeyMissing(.openai).message
                state.buttonLabel = RecognitionEngineReadiness.cloudKeyMissing(.openai).overlayAction.label
                state.phase = .error(message)
            }
            // 告知形态（黄调小字、无红边无按钮、2.5 s 自己走）：误触后的「没有听到内容」
            shoot("overlay-notice-\(tag)", height: 200) { state in
                state.phase = .warning(tr("没有听到内容", "Nothing heard"))
            }
        }
        print("[snapshot] PNGs written to \(outputDirectory.path)")
    }

    /// 波形的平滑是逐帧推进的：离屏窗口里 TimelineView 不一定走帧，先替它走几十帧，
    /// 拍出来的才是"说着话"的样子而不是刚起步的一排矮条
    private static func warmWaveform(_ state: OverlayState) {
        let now = Date().timeIntervalSinceReferenceDate
        for i in 0..<40 {
            _ = state.waveform.frame(level: state.level, time: now - Double(40 - i) / 30)
        }
    }

    @MainActor
    private func shoot(_ name: String, height: CGFloat, configure: (OverlayState) -> Void) {
        let state = OverlayState()
        configure(state)
        state.presented = true
        state.settled = true
        let canvas = SnapshotCanvas(state: state, height: height)
        let frame = NSRect(x: 0, y: 0, width: 720, height: height)
        let host = NSHostingView(rootView: canvas)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        // 屏幕外面：这组测试跑的时候人可能正在用这台 Mac
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        // 勾的描绘动画 0.25 s：等它走完
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        write(host: host, to: name)
        window.orderOut(nil)
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

/// 设计稿的画布：深色底 + 一块示意的前台窗口 + 贴底 28 pt 的胶囊
private struct SnapshotCanvas: View {
    let state: OverlayState
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg
            RadialGradient(colors: [Color(hex: 0x1A1C24), Theme.bg],
                           center: UnitPoint(x: 0.3, y: 0), startRadius: 0, endRadius: 520)
            VStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.02))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    .frame(height: 96)
                    .padding(.horizontal, 64)
                    .offset(y: -20)
                Spacer()
            }
            OverlayView(state: state)
                .padding(.bottom, 28)
        }
        .frame(width: 720, height: height)
        .environment(\.colorScheme, .dark)
    }
}
