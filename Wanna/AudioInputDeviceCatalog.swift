import CoreAudio
import Foundation

/// 一个可以拿来录音的输入设备。
///
/// 建这个类型是因为**「系统默认输入」不是一个稳定的东西**，而用户需要能看见、能指定。
/// 实测（2026-09-26）：这台机器上同时有内置麦克风（1 声道）、一个外接设备的麦克风
/// （1 声道）和一个录屏软件的虚拟驱动（2 声道），而 `AVAudioEngine` 默认跟的那个
/// 「默认设备聚合体」会把它们**合成** —— 合成之后是 3 声道，**交出的是静音**。
///
/// 所以用户要能在设置里看到「现在有哪些设备、哪个是默认、Wanna 实际绑的是谁」。
nonisolated struct AudioInputDevice: Identifiable, Sendable, Equatable {
    let id: AudioDeviceID
    /// CoreAudio 的 UID。**存它不存 id** —— `AudioDeviceID` 是会话内的临时编号，
    /// 重启或重新插拔之后会变，UID 才是那个设备的身份。
    let uid: String
    let name: String
    let channelCount: Int
    let isSystemDefault: Bool
    /// **它是一个组合，不是一个设备。**
    ///
    /// CoreAudio 的「默认设备聚合体」（`CADefaultDeviceAggregate-<pid>-0`）是 macOS
    /// 按「此刻有哪些设备」现组的，**它的声道数会随成员变** —— 内置麦克风 1 声道
    /// 加录屏软件的虚拟驱动 2 声道，合出来就是 3 声道，而 3 声道那个形态交出的是
    /// **纯静音**（实测 2026-09-26：117 秒 0 字）。
    ///
    /// 所以它**绝不能被列进选择器**：选它等于把当天修掉的东西又装回去。
    /// 判据只能是「它是不是聚合体」，不能是「有没有声道」—— 健康的聚合体也有 1 声道，
    /// 而那正是它会混进列表的原因（用户实测截图里它就排在第 4 项）。
    let isAggregate: Bool
    /// 虚拟设备（如录屏软件的环回声道）。**留着但标出来** —— 它可能正是用户想要的
    ///（比如录系统声音），所以不替用户做这个判断。
    let isVirtual: Bool

    var displayName: String {
        var text = channelCount > 0 ? "\(name)（\(channelCount) 声道）" : name
        if isVirtual { text += "（虚拟）" }
        return text
    }
}

/// 列出系统里所有能录音的输入设备。
///
/// 全部走 `AudioObjectGetPropertyData`，没有 `AVAudioEngine`、没有状态 —— 所以设置页
/// 列设备和录音绑设备读的是同一份真相，不会出现「设置页说有、录音说没有」。
nonisolated enum AudioInputDeviceCatalog {

    /// 系统当前的默认输入设备 id。找不到返回 0。
    static func systemDefaultInputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : 0
    }

    /// 所有输入设备，**默认那个排最前**，其余按名字。设置页直接用这个顺序。
    static func allInputDevices() -> [AudioInputDevice] {
        let defaultID = systemDefaultInputDeviceID()
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id -> AudioInputDevice? in
            // **只要真有输入通道的。** 扬声器也在设备表里，它对录音没有意义，
            // 列出来只会让用户选到它然后录到静音。
            let channels = inputChannelCount(of: id)
            guard channels > 0 else { return nil }
            let transport = transportType(of: id)
            // **聚合体一律不列。** 它不是设备，是组合，而它的声道数会变 ——
            // 变到某个形态就是静音。用户选了它，等于把这次的故障重新装回去。
            guard transport != kAudioDeviceTransportTypeAggregate else { return nil }
            return AudioInputDevice(id: id,
                                    uid: stringProperty(of: id, selector: kAudioDevicePropertyDeviceUID) ?? "",
                                    name: stringProperty(of: id, selector: kAudioObjectPropertyName) ?? "未命名设备",
                                    channelCount: channels,
                                    isSystemDefault: id == defaultID,
                                    isAggregate: false,
                                    isVirtual: transport == kAudioDeviceTransportTypeVirtual)
        }
        .sorted {
            if $0.isSystemDefault != $1.isSystemDefault { return $0.isSystemDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 按 UID 找。**找不到返回 nil，不返回「默认」** —— 调用方必须自己决定
    /// 落不落回默认：一个被拔掉的设备静默换成别的，用户会以为自己在用外置麦。
    static func device(withUID uid: String) -> AudioInputDevice? {
        guard !uid.isEmpty else { return nil }
        return allInputDevices().first { $0.uid == uid }
    }

    static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// 这个设备的传输类型 —— 用来认出聚合体和虚拟设备。
    private static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    private static func stringProperty(of deviceID: AudioDeviceID,
                                       selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, !(value as String).isEmpty else { return nil }
        return value as String
    }
}
