import AudioToolbox
import CoreAudio
import Foundation

/// 一台可用的输入设备。**id 只在本次进程有效**（拔了再插就变），所以设置里存的永远是 uid——
/// UID 跨重启、跨拔插稳定，换机器时读不到就退回系统默认，不会把用户的选择悄悄改成别的麦克风。
struct InputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// CoreAudio 输入设备枚举（路线图 P12）。
///
/// 为什么不用 AVCaptureDevice：AVFoundation 那套拿到的是"采集设备"，而 AVAudioEngine 的
/// inputNode 认的是 CoreAudio 的 AudioDeviceID。中间隔一层映射，UID 才是两边都认的东西，
/// 所以干脆全程走 CoreAudio，少一层可能对不上的转换。
///
/// 全部是只读查询 + 一个可注销的监听，任何一步失败都返回空/nil 由调用方兜底——
/// 麦克风列表查不出来，最坏也只是"只能用系统默认"，绝不能因此让录音起不来。
enum InputDevices {

    // MARK: 枚举

    /// 当前所有**带输入声道**的设备。扬声器、虚拟输出这类没有输入流的一律不列。
    static func list() -> [InputDevice] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            Log.warn("InputDevices: device list size query failed")
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids)
        guard status == noErr else {
            Log.warn("InputDevices: device list query failed status=\(status)")
            return []
        }
        return ids.prefix(count).compactMap { describe($0) }
    }

    /// 系统当前的默认输入设备 UID（"系统默认"那一项实际指向谁）
    static var defaultUID: String? {
        guard let id = defaultDeviceID else { return nil }
        return stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    /// UID → 本次进程的 AudioDeviceID。设备不在（拔了 / 换了机器）时返回 nil，调用方退回系统默认。
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return list().first { $0.uid == uid }?.id
    }

    private static var defaultDeviceID: AudioDeviceID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &id)
        guard status == noErr, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    private static func describe(_ id: AudioDeviceID) -> InputDevice? {
        guard inputChannelCount(id) > 0 else { return nil }
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
        return InputDevice(id: id, uid: uid, name: name)
    }

    /// 输入声道总数（0 = 这台设备只能放音，不该出现在麦克风列表里）
    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        // AudioBufferList 是变长结构（尾部跟着 mNumberBuffers 个 AudioBuffer），
        // 只能按查询到的字节数裸分配，不能用 Swift 的定长值类型接
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        // CoreAudio 按 "Get" 规则返回 +1 的 CFStringRef：必须 takeRetainedValue，
        // 直接用 `var s: CFString` 接会每查一次漏一个字符串
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let ref = ref else { return nil }
        let value = ref.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: 设备变化监听

    /// 设备列表 / 默认输入设备的变化监听。插拔 AirPods、接上声卡时设置里的下拉框要立刻跟上，
    /// 否则用户得关掉设置窗口再打开才看得到刚插上的麦克风。
    /// 持有它就一直生效，释放即注销（deinit 里 remove）——调用方只要把它存成一个属性。
    final class DeviceChangeObserver {
        private let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
        ]
        private let block: AudioObjectPropertyListenerBlock

        /// handler 在主线程回调
        init(handler: @escaping () -> Void) {
            block = { _, _ in handler() }
            for selector in selectors {
                var address = InputDevices.globalAddress(selector)
                let status = AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
                if status != noErr {
                    Log.warn("InputDevices: add listener failed selector=\(selector) status=\(status)")
                }
            }
        }

        deinit {
            for selector in selectors {
                var address = InputDevices.globalAddress(selector)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
            }
        }
    }
}
