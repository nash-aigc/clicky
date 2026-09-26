// AUHAL 采集**振幅**探针 —— 量的是「拉回来的样本到底是不是零」，不是「声明的格式对不对」。
//
//     swift scripts/recording-hal-amplitude-probe.swift
//
// 退出码 0 = 采到的样本里有真实信号；1 = 采到的全是零（故障复现）。
//
// ## 为什么要有第二个探针
//
// `recording-capture-probe.swift` 比的是「引擎声明的格式和设备自己的声道数是否一致」。
// 那条判据在 `AVAudioEngine` 时代有效，但 2026-09-26 换到 AUHAL 之后它**失去了意义**：
// AUHAL 在 `AudioUnitInitialize` 之前认下设备，读回来的格式永远是对的 —— 包括
// 那几场实际全是零的录音（日志里 `AUHAL 已启动 · 设备=MacBook Pro麦克风 [id=88] ·
// 48000.0Hz 1ch`，紧接着每一块 `峰值=0/32768，累计零块=2750/2750`）。
// 格式对、回调在跑、帧数正确、文件写好了 —— 只有样本是零。所以必须直接量样本。
//
// ## 它怎么量
//
// 复刻 App 里 `LongFormRecorderController.start()` 的每一步（设备解析方式也一样：
// 设置里的 UID，没设就用系统默认），跑 2 秒，在输入回调里 `AudioUnitRender` 之后
// 统计峰值。四件事同时打印，因为它们一起才能定位：
//
//   1. **系统当前**的默认输入设备（现问 CoreAudio，不读缓存）
//   2. 设备清单里每个设备的声道数 —— 3 声道那种东西只可能是聚合体
//   3. 绑定设备自己的输入静音 / 音量标量 —— 数字零也可以来自"被静音"
//   4. 2 秒内每块的峰值与零块比例

import AVFoundation
import CoreAudio
import Foundation

// MARK: - CoreAudio 读取

func defaultInputDeviceID() -> AudioDeviceID {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                               &address, 0, nil, &size, &deviceID)
    return deviceID
}

func allDeviceIDs() -> [AudioDeviceID] {
    var size = UInt32(0)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }
    return status == noErr ? (value as String) : "?"
}

func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
          size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

/// 设备输入侧的静音状态。数字零有两个来源：没人说话，和被静音。这个把它们分开。
func inputMuteState(of deviceID: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(deviceID, &address) else { return "该设备没有静音属性" }
    var muted = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
    return status == noErr ? (muted != 0 ? "🔇 已静音（这就是全零的直接原因）" : "未静音")
                           : "读不到（OSStatus \(status)）"
}

func inputVolumeScalar(of deviceID: AudioDeviceID) -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(deviceID, &address) else { return "该设备没有主音量属性" }
    var volume = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
    return status == noErr ? String(format: "%.3f", volume) : "读不到（OSStatus \(status)）"
}

// MARK: - AUHAL 采集（复刻 App 的那一套）

final class AmplitudeRecorder {
    var unit: AudioUnit?
    var renderBuffer: AVAudioPCMBuffer?
    var peakOverall: Int16 = 0
    var zeroBlocks = 0
    var totalBlocks = 0
    var frameTotal = 0
    var firstNonZeroBlock: Int?

    func start(deviceID: AudioDeviceID) -> String? {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return "FindNext 失败" }
        var newUnit: AudioUnit?
        guard AudioComponentInstanceNew(component, &newUnit) == noErr, let unit = newUnit else {
            return "InstanceNew 失败"
        }
        self.unit = unit

        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &enableInput,
                             UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &disableOutput,
                             UInt32(MemoryLayout<UInt32>.size))
        var device = deviceID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &device,
                             UInt32(MemoryLayout<AudioDeviceID>.size))

        var hardwareFormat = AudioStreamBasicDescription()
        var hardwareFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 1, &hardwareFormat, &hardwareFormatSize)

        // 用 int16 非交错：App 里上游就是 PCM16，这样量到的峰值和 App 日志里的
        // `峰值=n/32768` 是同一个尺子，可以直接对比。
        //
        // **声道数恒为 1，跟 App 一样**（App 侧那行是为了修「设备报 3 声道 → 格式建不出来
        // → 整场录音起不来」那个故障，见 `bindAndStartCapture` 里的说明）。
        // 设备在系统进入语音处理/聚合体状态时会自己从 1ch 变成 3ch / 9ch，而
        // 3 声道的 `AVAudioFormat` 根本建不出来 —— 探针要是跟着设备走，就会在那种
        // 状态下报「建 render buffer 失败」，而那**正是**要修的东西，不是要测的东西。
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: hardwareFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        let setFormatStatus = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                                  kAudioUnitScope_Output, 1, &clientFormat,
                                                  UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard setFormatStatus == noErr else { return "设客户端格式失败（OSStatus \(setFormatStatus)）" }
        guard let avFormat = AVAudioFormat(streamDescription: &clientFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: 8192) else {
            return "建 render buffer 失败（\(clientFormat.mSampleRate)Hz \(clientFormat.mChannelsPerFrame)ch）"
        }
        renderBuffer = buffer

        var callback = AURenderCallbackStruct(
            inputProc: halAmplitudeInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, 0, &callback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else { return "AudioUnitInitialize 返回 \(initStatus)" }
        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else { return "AudioOutputUnitStart 返回 \(startStatus)" }
        return nil
    }

    func handle(frameCount: UInt32, timeStamp: UnsafePointer<AudioTimeStamp>,
                actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>) {
        guard let unit = unit, let renderBuffer = renderBuffer else { return }
        renderBuffer.frameLength = frameCount
        var flags = actionFlags.pointee
        let status = AudioUnitRender(unit, &flags, timeStamp, 1, frameCount,
                                     renderBuffer.mutableAudioBufferList)
        guard status == noErr else { return }
        totalBlocks += 1
        frameTotal += Int(frameCount)

        var blockPeak: Int16 = 0
        let channelCount = Int(renderBuffer.format.channelCount)
        for channel in 0..<channelCount {
            guard let samples = renderBuffer.int16ChannelData?[channel] else { continue }
            for index in 0..<Int(frameCount) {
                let value = samples[index]
                let magnitude = value == Int16.min ? Int16.max : abs(value)
                if magnitude > blockPeak { blockPeak = magnitude }
            }
        }
        if blockPeak == 0 {
            zeroBlocks += 1
        } else if firstNonZeroBlock == nil {
            firstNonZeroBlock = totalBlocks
        }
        if blockPeak > peakOverall { peakOverall = blockPeak }
    }

    func stop() {
        guard let unit = unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }
}

func halAmplitudeInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let recorder = Unmanaged<AmplitudeRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
    recorder.handle(frameCount: inNumberFrames, timeStamp: inTimeStamp, actionFlags: ioActionFlags)
    return noErr
}

// MARK: - 跑

print("AUHAL 采集振幅探针")
print("════════════════")
let liveDefaultID = defaultInputDeviceID()
print("【1】系统**此刻**的默认输入设备：\(deviceName(liveDefaultID)) [id=\(liveDefaultID)]"
      + "，\(inputChannelCount(of: liveDefaultID)) 声道")
print("")
print("【2】全部输入设备（有输入声道的）：")
for id in allDeviceIDs() {
    let channels = inputChannelCount(of: id)
    guard channels > 0 else { continue }
    let marker = id == liveDefaultID ? "  ← 当前系统默认" : ""
    print("     [id=\(id)] \(deviceName(id)) — \(channels) 声道\(marker)")
}
print("")
print("【3】默认设备的输入静音/音量：静音=\(inputMuteState(of: liveDefaultID))，"
      + "主音量=\(inputVolumeScalar(of: liveDefaultID))")
print("")

// App 解析设备的方式：设置里有 UID 就用它，没有就用系统默认。
// 这里量系统默认那一路 —— 用户当前的设置就是空的（跟系统默认）。
print("【4】按 App 的做法（跟系统默认）采 2 秒，量振幅…")
let recorder = AmplitudeRecorder()
if let failure = recorder.start(deviceID: liveDefaultID) {
    print("   ❌ 起不来：\(failure)")
    exit(1)
}
Thread.sleep(forTimeInterval: 2.0)
recorder.stop()

let totalBlocks = recorder.totalBlocks
let zeroBlocks = recorder.zeroBlocks
print("   块数=\(totalBlocks)  帧数=\(recorder.frameTotal)  "
      + "整体峰值=\(recorder.peakOverall)/32768  零块=\(zeroBlocks)/\(totalBlocks)")
print("")

if recorder.peakOverall == 0 {
    print("❌ **故障复现**：采到的样本全是零。")
    print("   格式对、回调在跑、帧数正常、没有报错 —— 只有样本是零，和那几场坏录音一模一样。")
    exit(1)
} else {
    let firstNonZero = recorder.firstNonZeroBlock ?? -1
    print("✅ 采到了真实信号（峰值 \(recorder.peakOverall)/32768，第 \(firstNonZero) 块起有信号）。")
    exit(0)
}
