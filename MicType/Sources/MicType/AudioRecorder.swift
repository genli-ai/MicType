import AudioToolbox
import AVFoundation
import CoreAudio

/// 一次录音会话的采样缓冲。tap 闭包直接捕获它，不经过 AudioRecorder 的属性——
/// 音频线程于是只碰这一个对象和它自己的锁；stop() 换掉会话之后，那一次还没返回的
/// tap 回调最多往旧缓冲里多写几十毫秒，污染不到下一次录音。
private final class RecordingBuffer {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ ptr: UnsafeBufferPointer<Float>) {
        lock.lock()
        samples.append(contentsOf: ptr)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// 取 [start, start+maxCount) 的一段快照，**不清空**（伪流式预览用：录音继续，只是看一眼已经录到的）。
    /// maxCount 把切片长度钉死：预览窗口有秒数上限，轮询晚到时这一窗不能跟着变长，
    /// 多出来的尾巴留给下一窗。锁只按住一次 memcpy（20s 音频约 1.3MB，远短于一个 tap 周期），
    /// 音频线程不会被拖垮。
    func slice(from start: Int, maxCount: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let lower = max(0, start)
        let upper = min(samples.count, lower + max(0, maxCount))
        guard lower < upper else { return [] }
        return Array(samples[lower..<upper])
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples.removeAll()
        return result
    }
}

/// 麦克风录音，实时重采样为 16kHz 单声道 Float32（识别模型需要的格式）
final class AudioRecorder {

    private var engine: AVAudioEngine?
    /// 当前会话的采样缓冲（只在主线程换；音频线程拿的是捕获进闭包的同一个引用）
    private var buffer: RecordingBuffer?
    /// tap 是否还挂在 inputNode 上（只在主线程读写）：重装/停止前要准确知道，避免空 removeTap
    private var tapInstalled = false
    /// 装 tap 时输入设备的格式，用来判断配置变更是否真的换了格式
    private var installedFormat: AVAudioFormat?
    /// 设备变更观察者（AirPods 插拔、采样率变化）
    private var configObserver: NSObjectProtocol?

    /// 录音音量回调（0~1），用于悬浮窗波形动画。注意：在音频线程回调。
    /// 装 tap 那一刻取一次快照交给音频线程，录音开始后再改不会生效。
    var onLevel: ((Float) -> Void)?
    /// 每个音频块的**线性峰值幅度**（0~1）。只有麦克风自检要它（换算 dBFS 给用户看），
    /// 平时是 nil —— 音频线程里连那一趟求峰值的循环都不跑。同样在装 tap 那一刻取快照。
    var onPeak: ((Float) -> Void)?
    /// 录音期间音频链路不可恢复地断了（换设备后重装 tap 失败）。主线程回调。
    /// 上层应当拿已经录到的采样收尾，而不是干等一个再也不会来数据的录音。
    var onError: ((MTError) -> Void)?

    private(set) var isRecording = false

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() throws {
        guard !isRecording else { return }

        let engine = AVAudioEngine()
        let buffer = RecordingBuffer()
        self.buffer = buffer

        do {
            try installTap(on: engine, into: buffer)
        } catch {
            self.buffer = nil
            throw error
        }

        self.engine = engine
        isRecording = true

        // 录音途中换设备（插拔 AirPods、切外置声卡、采样率变化）会让 inputNode 换格式，
        // 旧 tap 从此收不到数据。收到通知就按新格式重装一次，用户无感，已录采样原样保留。
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// 按当前输入设备的格式装 tap 并启动引擎。
    /// 关键：converter / outFormat / onLevel 全部作为闭包捕获的**局部常量**交给音频线程，
    /// 实时回调里一个 self 的可变属性都不读——否则 stop() 在主线程把属性置 nil 时会和
    /// 正在执行的 tap 并发读写同一引用（removeTap 不保证 block 已返回，TSan 必报，
    /// 线上表现为偶发崩溃）。
    private func installTap(on engine: AVAudioEngine, into sink: RecordingBuffer) throws {
        let input = engine.inputNode
        // 选麦克风必须**赶在读格式和装 tap 之前**：inputNode 的格式是跟着当前设备走的，
        // 先读格式再换设备，转换器就是按旧设备的采样率建的，录出来会变调
        applyPreferredInputDevice(to: input)
        let inFormat = input.outputFormat(forBus: 0)

        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw MTError(tr("没有可用的麦克风输入设备", "No microphone input device available"))
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16000,
                                            channels: 1,
                                            interleaved: false) else {
            throw MTError(tr("无法创建音频格式", "Could not create audio format"))
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw MTError(tr("无法创建音频转换器", "Could not create audio converter"))
        }
        let levelCallback = onLevel
        let peakCallback = onPeak

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { pcm, _ in
            AudioRecorder.process(buffer: pcm, into: sink, converter: converter,
                                  outFormat: outFormat, onLevel: levelCallback,
                                  onPeak: peakCallback)
        }
        tapInstalled = true
        installedFormat = inFormat

        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTap(from: engine)
            throw MTError(tr("无法启动录音：", "Could not start recording: ") + error.localizedDescription)
        }
        Log.info("Audio tap installed rate=\(Int(inFormat.sampleRate)) ch=\(inFormat.channelCount)")
    }

    /// 按设置里的 UID 指定输入设备。空 UID（默认）＝什么都不碰，行为与 3.2 完全一致。
    /// 三种失败（拿不到 audio unit / 设备不在 / 设置属性失败）**一律只记日志然后继续**：
    /// 用户保存过的麦克风今天没插上，也得让他能对着内建麦克风把话说完，
    /// 而不是收到一句"录音失败"。设置本身不动，下次插回来照旧生效。
    private func applyPreferredInputDevice(to input: AVAudioInputNode) {
        let uid = Settings.shared.inputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return }
        guard let unit = input.audioUnit else {
            Log.warn("Preferred input device skipped: input node has no audio unit (uid=\(uid))")
            return
        }
        guard var deviceID = InputDevices.deviceID(forUID: uid) else {
            Log.warn("Preferred input device not connected (uid=\(uid)) — using system default")
            return
        }
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status == noErr {
            Log.info("Input device selected uid=\(uid) id=\(deviceID)")
        } else {
            Log.warn("Input device select failed uid=\(uid) status=\(status) — using system default")
        }
    }

    private func removeTap(from engine: AVAudioEngine) {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        installedFormat = nil
    }

    /// 输入设备变了：旧 tap 的格式已经对不上，就地按新格式重装。
    /// 缓冲不动——用户前半句话必须留着。主线程调用。
    private func handleConfigurationChange() {
        guard isRecording, let engine = engine, let sink = buffer else { return }

        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        if let old = installedFormat, engine.isRunning,
           old.sampleRate == newFormat.sampleRate, old.channelCount == newFormat.channelCount {
            // 格式没变、引擎还在跑（常见的无害通知）：不打断，避免白白丢一小段音频
            Log.info("Audio configuration change ignored (format unchanged, engine running)")
            return
        }

        let kept = String(format: "%.2f", Double(sink.count) / 16000.0)
        Log.warn("Audio configuration changed rate=\(Int(newFormat.sampleRate)) ch=\(newFormat.channelCount)"
                 + " — reinstalling tap (kept \(kept)s)")
        removeTap(from: engine)
        engine.stop()

        do {
            try installTap(on: engine, into: sink)
        } catch {
            let message = (error as? MTError)?.message ?? error.localizedDescription
            Log.error("Audio tap reinstall failed: \(message)")
            // 引擎已经停了，再"录"下去只有静音。不动 isRecording：上层随后 stop() 依然拿得到
            // 已经录到的采样，用半句话出结果，好过让用户对着死掉的麦克风一直说。
            stopObservingConfiguration()
            onError?(MTError(tr("录音设备已变更，本次录音提前结束",
                                "Audio device changed — recording ended early")))
        }
    }

    private func stopObservingConfiguration() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    /// 音频线程入口：静态方法，不捕获 self，所有依赖由调用点以局部常量传入
    private static func process(buffer: AVAudioPCMBuffer, into sink: RecordingBuffer,
                                converter: AVAudioConverter, outFormat: AVAudioFormat,
                                onLevel: ((Float) -> Void)?, onPeak: ((Float) -> Void)?) {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: out, error: &error, withInputFrom: inputBlock)
        guard status != .error, error == nil, let channel = out.floatChannelData else { return }

        let n = Int(out.frameLength)
        guard n > 0 else { return }

        let ptr = UnsafeBufferPointer(start: channel[0], count: n)
        sink.append(ptr)

        // 计算 RMS 音量
        var sum: Float = 0
        for v in ptr { sum += v * v }
        let rms = (sum / Float(n)).squareRoot()
        onLevel?(min(1.0, rms * 14))

        // 峰值只在自检时算（onPeak 为 nil 时一个样本都不多扫）
        if let onPeak = onPeak {
            var peak: Float = 0
            for v in ptr { peak = max(peak, abs(v)) }
            onPeak(peak)
        }
    }

    /// 停止并返回 16kHz 采样
    func stop() -> [Float] {
        guard isRecording else { return [] }
        stopObservingConfiguration()
        if let engine = engine {
            removeTap(from: engine)
            engine.stop()
        }
        engine = nil
        isRecording = false

        let result = buffer?.drain() ?? []
        buffer = nil
        return result
    }

    var recordedDuration: Double {
        Double(buffer?.count ?? 0) / 16000.0
    }

    /// 已录采样数（伪流式预览用来算窗口位置；不录音时为 0）
    var recordedSampleCount: Int { buffer?.count ?? 0 }

    /// 录音进行中读一段已录采样（不消费、不影响录音本身），最多 maxCount 个采样。
    /// 只给悬浮窗的灰字预览用——真正要送去识别的永远是 stop() 返回的那一整段。
    func snapshot(fromSampleIndex start: Int, maxCount: Int) -> [Float] {
        guard isRecording, let buffer = buffer else { return [] }
        return buffer.slice(from: max(0, start), maxCount: maxCount)
    }
}
