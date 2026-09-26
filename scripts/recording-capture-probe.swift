// 录音采集探针 —— **改录音这条路上的任何代码之前，先跑它。**
//
//     swift scripts/recording-capture-probe.swift
//
// 退出码 0 = 采集链路正常；1 = 复现出了那个「录出来全是零」的故障。
//
// ## 为什么要有这个文件
//
// 2026-09-26 之前，「录音又坏了」连续发生了十次，每一次都是用户在真实使用里撞出来的，
// 每一次都要靠人回想「刚才是不是用过语音」。而那十次里没有一次是机器发现的 ——
// 因为**静音是一种看不见的失败**：时长正确、文件写好了、没有报错、没有崩溃，
// 只是全是零。所有「看起来在正常运行」的信号它都有。
//
// 而这个故障其实**三分钟、二十行就能复现**。它一直没被复现，只是因为没人写。
// 所以这个文件的作用不是「多一个测试」，而是**把发现故障的位置从用户手里挪到机器手里**。
//
// ## 它测的是什么
//
// 两个子系统抢同一份**进程级**的音频状态：
//
// - `VoicePlaybackEngine` 开语音处理（VPIO，回声消除要用）时，会把整个硬件 IO
//   重配成一套语音处理格式；
// - 长录音走 `AVAudioEngine`，而它的输入节点**跟着进程的状态走**。
//
// 关键在于这个污染是**进程级、且不可还原**的 —— 放掉引擎、关掉语音处理、新建引擎，
// 都回不去。所以录音只在「本进程从没开过语音处理」时是好的。
//
// 期望值（2026-09-26 实测）：
//
//     | 进程状态                          | 钉到麦克风后声明的格式      |
//     |-----------------------------------|-----------------------------|
//     | 从没开过 VPIO                     | 1 声道 @48kHz      ✅        |
//     | 开过一次 VPIO，stop + 关语音处理  | 2 声道 @44.1kHz    ❌        |
//     | 紧接着再建一个引擎                | 2 声道 @44.1kHz    ❌        |
//
// ## 这个探针绿了意味着什么，红了又意味着什么
//
// - **全绿**：采集链路目前是好的。改录音可以先做后跑这个确认没有踩坏。
// - **红了**：故障被复现出来了。**这时候不要动 App 代码** —— 先去改采集本身
//   （让它不走 `AVAudioEngine`，改用 AUHAL 直接对设备取流），然后再跑这个，
//   直到它整条绿。在它绿之前改 App 里别的东西，等于在别人的地基上补墙。

import AVFoundation
import CoreAudio
import Foundation

// MARK: - 小工具

/// 系统默认输入设备的 id。
func systemDefaultInputDeviceID() -> AudioDeviceID {
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

/// 这个设备自己的输入声道数 —— 不是引擎声明的，是设备真实的。
func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
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

/// 按长录音起采时那套做法建一个引擎：**先钉设备，再读格式。**
func makePinnedRecordingEngine(deviceID: AudioDeviceID) -> (AVAudioEngine, String) {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    var target = deviceID
    AudioUnitSetProperty(inputNode.audioUnit!,
                         kAudioOutputUnitProperty_CurrentDevice,
                         kAudioUnitScope_Global, 0, &target,
                         UInt32(MemoryLayout<AudioDeviceID>.size))
    let format = inputNode.outputFormat(forBus: 0)
    return (engine, "\(format.sampleRate)Hz \(format.channelCount)ch")
}

// MARK: - 跑

let defaultDeviceID = systemDefaultInputDeviceID()
let deviceChannels = inputChannelCount(of: defaultDeviceID)

print("录音采集探针")
print("────────────")
print("系统默认输入设备：\(deviceName(defaultDeviceID)) [id=\(defaultDeviceID)]，"
      + "\(deviceChannels) 声道")
print("")

var failures: [String] = []

// ① 干净状态：本进程从没开过语音处理。
print("① 本进程从没开过语音处理时，建一个录音引擎…")
let (baselineEngine, baselineFormat) = makePinnedRecordingEngine(deviceID: defaultDeviceID)
print("   钉到默认设备之后声明：\(baselineFormat)")

if baselineFormat.contains("\(deviceChannels)ch") {
    print("   ✅ 和设备自己的声道数一致 —— 采集链路正常")
} else {
    print("   ❌ 和设备对不上（设备 \(deviceChannels) 声道）")
    failures.append("干净状态下格式就对不上：\(baselineFormat) 对设备 \(deviceChannels) 声道")
}
_ = baselineEngine

// ② 开一次语音处理（模拟语音管线跑过一轮）。
print("")
print("② 开一次语音处理，然后 stop + 关掉…")
let voiceEngine = AVAudioEngine()
// 这一行不能省：主混音节点必须在开语音处理之前被读到，否则 engine.start() 会以
// -10875 失败（见 VoicePlaybackEngine.warmUpMainMixerNode 的四组实测）。
_ = voiceEngine.mainMixerNode.outputFormat(forBus: 0)
do {
    try voiceEngine.inputNode.setVoiceProcessingEnabled(true)
    try voiceEngine.start()
    let voiceFormat = voiceEngine.inputNode.outputFormat(forBus: 0)
    print("   语音处理引擎运行中：\(voiceFormat.sampleRate)Hz \(voiceFormat.channelCount)ch")
} catch {
    print("   ⚠️ 语音处理没能起来：\(error.localizedDescription)")
}
voiceEngine.stop()
try? voiceEngine.inputNode.setVoiceProcessingEnabled(false)
print("   已 stop 且关了语音处理")

// ③ 污染之后，再建一个录音引擎 —— **这就是用户遇到的那个场景。**
print("")
print("③ 语音处理跑过之后，再建一个录音引擎（用户按下录音时就是这一步）…")
let (afterEngine, afterFormat) = makePinnedRecordingEngine(deviceID: defaultDeviceID)
print("   钉到默认设备之后声明：\(afterFormat)")

if afterFormat.contains("\(deviceChannels)ch") {
    print("   ✅ 仍然和设备一致 —— 采集不受语音处理影响")
} else {
    print("   ❌ 和设备对不上 —— **故障复现**：录音会是一整段静音")
    failures.append("语音处理跑过之后，录音引擎声明 \(afterFormat)，"
                    + "而设备是 \(deviceChannels) 声道 —— 录下来会是静音")
}
_ = afterEngine

// MARK: - 结论

print("")
print("────────────")
if failures.isEmpty {
    print("✅ 全绿：采集链路正常。")
    exit(0)
} else {
    print("❌ 复现出故障（\(failures.count) 处）：")
    for failure in failures { print("   · \(failure)") }
    print("")
    print("这一次不要去改 App 里别的东西 —— 先改采集本身：")
    print("让长录音不走 AVAudioEngine（它对的是进程级聚合体），改用 AUHAL")
    print("（kAudioUnitSubType_HALOutput）直接对选定的设备取流，")
    print("然后重跑这个探针，直到整条绿。")
    exit(1)
}
