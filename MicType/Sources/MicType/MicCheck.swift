import SwiftUI
import AppKit
import Combine

// MARK: - 麦克风自检

/// 麦克风自检此刻在不在跑。为什么要有这么一个全局：自检和主录音是各自独立的 AVAudioEngine，
/// 抢的是同一只麦克风。自检这边一直知道要避让主流程（AppDelegate.isDictationBusy），
/// 反过来主流程却完全看不见自检——用户在设置里点完「测试麦克风」顺手按了热键，两路 tap
/// 同时开着：电平条量的是他正在听写的那句话，3 秒到点还会给出一句与本次自检无关的结论。
/// 只在主线程读写（自检的起止、主流程的起录都在主线程）。
enum MicTest {

    private(set) static var isRunning = false
    /// 自检登记的收手闭包。主流程起录时用它把自检掐掉——用户正要说的那句话比一次自检重要得多
    private static var stopHandler: (() -> Void)?

    static func began(stop: @escaping () -> Void) {
        isRunning = true
        stopHandler = stop
    }

    static func ended() {
        isRunning = false
        stopHandler = nil
    }

    /// 正在自检就让位给听写。返回是否真的让了位（只给日志用）
    @discardableResult
    static func yieldToDictation() -> Bool {
        guard isRunning, let stop = stopHandler else { return false }
        stop()
        return true
    }
}

/// 麦克风自检（路线图 P12）：借 AudioRecorder 跑一段 3 秒录音，只读电平——
/// 采样收上来立刻丢掉，不送识别、不落盘、不进历史。
/// 为什么值得做：选错麦克风这件事，用户通常是在真的要说话的时候才发现的（说完一段，什么都没出来）。
/// 给一条电平条 + 峰值读数，选完当场就能确认"这只真的在收声"。
final class MicTestSession: ObservableObject {

    @Published private(set) var isRunning = false
    /// 0~1，画电平条（AudioRecorder 送来的归一化 RMS）
    @Published private(set) var level: Float = 0
    /// 本次自检收到的最大峰值（线性幅度 0~1）
    @Published private(set) var peak: Float = 0
    @Published private(set) var message = ""

    private static let seconds: Double = 3

    private let recorder = AudioRecorder()
    /// 自检代数：连点两次「测试」时，旧的那一次定时收尾不能把新的一次关掉
    private var run = 0

    /// 峰值读数。dBFS 是音频里通用的刻度（0 = 满刻度，越负越小），比 0~1 更好对照
    var peakLabel: String {
        guard peak > 0 else { return "— dBFS" }
        return String(format: "%.0f dBFS", 20 * log10(peak))
    }

    func start() {
        guard !isRunning else { return }
        // 主流程正在录音/出结果时不抢麦克风：用户正说着的话比一次自检重要得多
        guard !AppDelegate.isDictationBusy else {
            message = busyMessage
            return
        }
        message = tr("请用平常的音量说一句话…", "Say something at your normal volume…")
        Permissions.ensureMicrophone { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.message = tr("没有麦克风权限：系统设置 › 隐私与安全性 › 麦克风 里勾上 MicType",
                                  "Microphone permission denied — enable MicType in System Settings › Privacy & Security › Microphone")
                return
            }
            // 上面那次判定是在权限回调之前做的。首次授权的系统弹窗能挂好几秒，这期间用户
            // 完全来得及按热键开始听写，所以真正起录前必须再查一次。
            guard !AppDelegate.isDictationBusy else {
                self.message = self.busyMessage
                return
            }
            self.begin()
        }
    }

    private var busyMessage: String {
        tr("正在录音或处理中，稍后再测", "Busy recording — try again in a moment")
    }

    /// 结论文字是一次性生成的快照，切语言不会自己刷新 → 切换时清掉（3.1.1 的老坑）
    func clearMessage() { message = "" }

    /// 关窗 / 切走标签页时收手，别让一路录音在看不见的地方继续开着
    func cancel() {
        guard isRunning else { return }
        finish(note: "")
    }

    private func begin() {
        // 回调必须在 start() 之前设好：AudioRecorder 装 tap 那一刻就把它们快照给音频线程了
        recorder.onLevel = { [weak self] value in
            // 和 onPeak 一样要查 isRunning：tap 回调在音频线程，async 回主线程时 finish()
            // 可能已经把电平条归零了，在途的那一两块会把它写回非零——测试早结束了，
            // 条子却停在半格上，看着像麦克风还在收音
            DispatchQueue.main.async {
                guard let self = self, self.isRunning else { return }
                self.level = value
            }
        }
        recorder.onPeak = { [weak self] value in
            DispatchQueue.main.async {
                guard let self = self, self.isRunning else { return }
                self.peak = max(self.peak, value)
            }
        }
        recorder.onError = { [weak self] error in
            self?.finish(note: error.message)
        }
        peak = 0
        level = 0
        do {
            try recorder.start()
        } catch {
            message = (error as? MTError)?.message ?? error.localizedDescription
            Log.warn("Mic test start failed: \(message)")
            return
        }
        isRunning = true
        MicTest.began { [weak self] in
            self?.finish(note: tr("已让位给这次听写，稍后再测",
                                  "Stopped — dictation is using the microphone"))
        }
        run += 1
        let token = run
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds) { [weak self] in
            guard let self = self, self.run == token else { return }
            self.finish(note: nil)
        }
    }

    /// note: nil = 正常到点收尾（给结论）；非 nil = 被打断（原样显示，空串表示什么都不说）
    private func finish(note: String?) {
        guard isRunning else { return }
        _ = recorder.stop()
        isRunning = false
        MicTest.ended()
        level = 0
        run += 1     // 让还没到点的那个定时收尾作废
        if let note = note {
            message = note
            return
        }
        Log.info("Mic test done peak=\(String(format: "%.4f", peak)) uid=\(Settings.shared.inputDeviceUID)")
        // 结论直接对齐识别链路的静音闸门（SilenceGate），别让自检说"没问题"而真录音被判静音
        if peak < SilenceGate.silentPeak {
            message = tr("几乎没有收到声音：换一只麦克风，或检查系统设置里的输入音量",
                         "Almost nothing came through — try another microphone, or check the input volume in System Settings")
        } else if peak < SilenceGate.faintPeak {
            message = tr("收到了，但很小：靠近麦克风会明显更准",
                         "Picked you up, but very quietly — moving closer will noticeably help accuracy")
        } else {
            message = tr("麦克风工作正常", "Microphone works")
        }
    }
}

// MARK: - 麦克风选择 + 电平自检面板（设置与引导共用）

/// 设备下拉 + 「测试麦克风」+ 电平条 + 峰值读数 + 结论，一整套控件的共用组件。
///
/// 为什么抽成组件：引导第二屏拿到麦克风权限之后，用户需要当场看见"这只麦真的在收声"
/// （v4.0 调研 §4.5：Wispr Flow 的引导就在权限之后放电平测试），而这套控件在
/// 设置 → 本地识别 里早已写全并踩平了坑（让位给听写、设备热插拔、结论对齐静音闸门）。
/// 两处共用同一份实现，行为与文案只有一处可改，不会再出现"引导里能换麦、设置里不能"这种偏差。
struct MicCheckPanel: View {

    /// 设置页要那段"测试会录 3 秒、只看音量"的长说明；引导页寸土寸金，只留控件
    let showsFootnote: Bool

    @ObservedObject private var l10n = L10n.shared
    @AppStorage(SettingsKeys.inputDeviceUID) private var inputDeviceUID = ""
    @StateObject private var session = MicTestSession()
    @State private var devices: [InputDevice] = []
    /// 插拔 AirPods / 接上声卡时下拉框要立刻跟上（否则得关掉窗口再打开才看得见）
    @State private var deviceObserver: InputDevices.DeviceChangeObserver?

    init(showsFootnote: Bool = true) {
        self.showsFootnote = showsFootnote
    }

    /// 那段"测试会录 3 秒、只看音量"的说明。**只写一处**：设置页把它收进段头那颗 ⓘ 里
    /// （Plan C 的文案预算），引导页仍然摆在控件下面——两边逐字同一句。
    static var footnote: String {
        tr("测试会录 3 秒，只看音量：录到的声音当场丢弃，不识别、不保存。\n选定的麦克风在开始录音时没插上，会自动退回系统默认（这次录音照常进行），设置本身不改动。",
           "The test records for 3 seconds and only meters the level - the audio is discarded, never transcribed or saved.\nIf the selected microphone is not connected when recording starts, MicType falls back to the system default for that session and leaves your choice untouched.")
    }

    /// 「系统默认」当前实际指向谁——写在选项里，用户不用去系统设置里对照
    private var systemDefaultLabel: String {
        let base = tr("系统默认", "System default")
        guard let uid = InputDevices.defaultUID,
              let device = devices.first(where: { $0.uid == uid }) else { return base }
        return base + tr("（\(device.name)）", " (\(device.name))")
    }

    /// 存着的麦克风此刻不在（没插上 / 换了台机器）。**不自动改设置**：插回来还要照旧用，
    /// 只是在列表里如实标出来，并让 Picker 有一个能选中的选项（否则 SwiftUI 显示空白）
    private var savedDeviceMissing: Bool {
        !inputDeviceUID.isEmpty && !devices.contains { $0.uid == inputDeviceUID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(tr("麦克风：", "Microphone:"), selection: $inputDeviceUID) {
                Text(systemDefaultLabel).tag("")
                ForEach(devices) { device in
                    Text(device.name).tag(device.uid)
                }
                if savedDeviceMissing {
                    Text(tr("已选的麦克风（当前未连接）", "Selected microphone (not connected)"))
                        .tag(inputDeviceUID)
                }
            }
            HStack(spacing: 10) {
                Button(session.isRunning ? tr("测试中…", "Testing…")
                                         : tr("测试麦克风", "Test microphone")) {
                    session.start()
                }
                .disabled(session.isRunning)
                ProgressView(value: Double(min(max(session.level, 0), 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 150)
                Text(session.peakLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            if !session.message.isEmpty {
                Text(session.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsFootnote {
                Text(Self.footnote)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            let list = $devices
            list.wrappedValue = InputDevices.list()
            deviceObserver = InputDevices.DeviceChangeObserver {
                list.wrappedValue = InputDevices.list()
            }
        }
        .onDisappear {
            deviceObserver = nil      // 释放即注销 CoreAudio 监听
            session.cancel()          // 别让一路录音在看不见的地方继续开着
        }
        // 结论文字是一次性生成的语言快照，切语言即清空（见 CLAUDE.md「i18n 快照字符串」）
        .onChange(of: l10n.language) { _, _ in
            session.clearMessage()
        }
    }
}
