import AppKit
import SwiftUI

// MARK: - 悬浮窗状态

final class OverlayState: ObservableObject {
    enum Mode: Equatable {
        case recording(String)
        case processing(String)
        case success(String)
        case error(String)
        /// 中性提示（取消等用户主动动作）：既不是成功也不是错误，别用绿勾/黄三角误导
        case notice(String)
    }

    // 占位初值，显示前必然会被 showRecording/showProcessing 覆盖
    @Published var mode: Mode = .recording("")
    @Published var levels: [Float] = Array(repeating: 0.05, count: 13)

    func pushLevel(_ level: Float) {
        var l = levels
        l.removeFirst()
        l.append(max(0.05, min(1.0, level)))
        levels = l
    }

    func resetLevels() {
        levels = Array(repeating: 0.05, count: 13)
    }
}

// MARK: - 悬浮窗视图

struct OverlayView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        HStack(spacing: 10) {
            switch state.mode {
            case .recording(let label):
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<state.levels.count, id: \.self) { i in
                        Capsule()
                            .fill(Color.white.opacity(0.95))
                            .frame(width: 3, height: 5 + 23 * CGFloat(state.levels[i]))
                    }
                }
                .animation(.linear(duration: 0.1), value: state.levels)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
            case .processing(let label):
                ProgressView()
                    .controlSize(.small)
                    .colorInvert()
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                // 处理中唯一的出口就是 Esc——一直摆在眼前，别让用户以为自己被锁住了
                Text(tr("⎋ 取消", "⎋ Cancel"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            case .notice(let label):
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.75))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            case .success(let label):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            case .error(let label):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minWidth: 160, minHeight: 44)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.82))
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
        )
        .padding(16)
    }
}

// MARK: - 悬浮窗控制器

final class OverlayController {

    let state = OverlayState()
    private var panel: NSPanel?
    private var hideGeneration = 0
    /// 本轮「处理中」的起点与当前阶段标签：秒数从整轮处理开始算（用户关心的是"我等了多久"，
    /// 不是"这一段等了多久"），阶段标签换成「润色中…」时不重新计时
    private var processingStartedAt: Date?
    private var processingLabel = ""
    private var processingTimer: Timer?

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 90),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hosting = NSHostingView(rootView: OverlayContainer(state: state))
        hosting.frame = p.contentRect(forFrameRect: p.frame)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        panel = p
        return p
    }

    private func position(_ p: NSPanel) {
        // 多屏：跟随鼠标所在屏幕（用户正在操作的那块屏），固定主屏会让悬浮窗"消失"在别的屏上
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - p.frame.width / 2
        let y = frame.minY + 28
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func showRecording(label: String = tr("正在听…", "Listening…")) {
        hideGeneration += 1
        endProcessing()
        state.resetLevels()
        state.mode = .recording(label)
        present(context: "recording")
    }

    func showProcessing(_ label: String) {
        hideGeneration += 1
        processingLabel = label
        if processingStartedAt == nil { processingStartedAt = Date() }
        state.mode = .processing(processingText())
        startProcessingTimer()
        present(context: "processing")
    }

    /// 处理中被拒绝的手势（轻点/按住）：闪一句提示后回到「处理中」显示，
    /// 绝不用这条提示把进度显示擦掉
    func flashOverProcessing(_ label: String, duration: Double = 1.6) {
        guard processingStartedAt != nil else {
            flashError(label)
            return
        }
        hideGeneration += 1
        let generation = hideGeneration
        state.mode = .error(label)
        present(context: "flash-busy")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.hideGeneration == generation,
                  self.processingStartedAt != nil else { return }
            self.state.mode = .processing(self.processingText())
        }
    }

    /// 已等待秒数：3 秒内不显示——短请求上闪一个数字只是噪音
    private func processingText() -> String {
        guard let start = processingStartedAt else { return processingLabel }
        let elapsed = Int(Date().timeIntervalSince(start))
        guard elapsed >= 3 else { return processingLabel }
        return processingLabel + " \(elapsed)s"
    }

    private func startProcessingTimer() {
        guard processingTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickProcessing()
        }
        // .common：菜单打开 / 窗口拖动期间 runloop 切模式，默认模式的 timer 会停走
        RunLoop.main.add(timer, forMode: .common)
        processingTimer = timer
    }

    private func tickProcessing() {
        guard processingStartedAt != nil else { return }
        // 正在闪别的提示（flashOverProcessing）时不要抢回显示
        guard case .processing = state.mode else { return }
        state.mode = .processing(processingText())
    }

    private func endProcessing() {
        processingTimer?.invalidate()
        processingTimer = nil
        processingStartedAt = nil
        processingLabel = ""
    }

    /// 统一的显示入口：定位 → 置顶 → 回读真实状态。
    /// 3.2.13：不只查 isVisible，还查 isOnActiveSpace——panel 的 Space 关联会偶发损坏
    /// （visible=true 但挂在别的桌面空间，用户看不见，2026-06-12 日志实锤）。
    /// 任一不健康就整个重建 panel：新建的 panel 必然落在当前活跃 Space。
    private func present(context: String) {
        var p = ensurePanel()
        position(p)
        p.orderFrontRegardless()
        if !p.isVisible || !p.isOnActiveSpace {
            Log.warn("Overlay \(context) unhealthy (visible=\(p.isVisible) onActiveSpace=\(p.isOnActiveSpace)) — rebuilding panel")
            p.orderOut(nil)
            panel = nil
            p = ensurePanel()
            position(p)
            p.orderFrontRegardless()
        }
        Log.overlayShown(context: context, panel: p)
    }

    func flashSuccess(_ label: String) {
        flash(.success(label), duration: 1.0)
    }

    func flashError(_ label: String) {
        flash(.error(label), duration: 2.5)
    }

    func flashNotice(_ label: String) {
        flash(.notice(label), duration: 1.0)
    }

    private func flash(_ mode: OverlayState.Mode, duration: Double) {
        hideGeneration += 1
        endProcessing()
        let generation = hideGeneration
        state.mode = mode
        present(context: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self = self, self.hideGeneration == generation else { return }
            self.hide()
        }
    }

    func hide() {
        hideGeneration += 1
        endProcessing()
        panel?.orderOut(nil)
    }
}

/// 让胶囊在固定大小面板里居中
private struct OverlayContainer: View {
    @ObservedObject var state: OverlayState
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                OverlayView(state: state)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }
}
