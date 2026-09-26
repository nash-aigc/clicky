import Foundation

/// 边录边写的 WAV 落盘器。
///
/// 存在的唯一理由是**长录音不能把音频攒在内存里**：16kHz 单声道 PCM16 录 3 小时
/// 是 345 MB，攒够了再写盘既吃内存又会在崩溃时全丢。所以这里开文件时就先写一个
/// 44 字节的占位头，之后每来一块 PCM 就追加一块、立刻落盘，停止时再 seek 回文件
/// 开头把两个长度字段补上。
///
/// 三个刻意的选择：
///
/// - **格式是 WAV/PCM16，不是压缩格式。** 录下来的字节和发给识别服务的字节**完全
///   一致**（都取自同一个重采样缓冲），所以这个文件可以原样重放给服务端、完整复现
///   一次识别。调试长录音的问题全靠这个性质 —— 否则「3 小时里第 2 小时那段错了」
///   根本无法复现。
/// - **写入就 flush。** 断电时最多丢最后一块，而不是整场。
/// - **头可以事后补。** `repairHeaderIfNeeded` 让一个断电/被杀进程留下的、头还是
///   占位值的文件也能被修好并播放：字节数记在会话元数据里，时长 = 字节数 ÷ 每秒
///   字节数。没有这一步，用户最需要的那份录音（正好是崩溃前那段）恰恰打不开。
///
/// 这个类是 `nonisolated` 的：它被录音线程每 100ms 调用一次，不该为了写盘去等主
/// 线程。内部没有可变共享状态之外的东西，所有调用都来自同一个串行队列。
nonisolated final class RecordingAudioWriter {

    /// 标准 PCM WAV 的头部长度。占位头和最终头都是这个长度，所以回填只是覆写
    /// 开头 44 字节，不需要挪动任何音频数据。
    static let wavHeaderByteCount = 44

    let fileURL: URL
    let sampleRate: Int
    let channelCount: Int
    let bitsPerSample: Int

    private let fileHandle: FileHandle
    private(set) var writtenPCMByteCount: Int64 = 0
    private var hasFinalized = false

    /// 每秒字节数。WAV 头的 `byteRate` 字段和「由字节数反推时长」都用它。
    var bytesPerSecond: Int {
        sampleRate * channelCount * (bitsPerSample / 8)
    }

    /// 已录时长（秒）。不需要问服务端 —— 我们自己写的字节数就是答案，
    /// 而且它对「服务端还没回任何东西」的那一秒同样成立。
    var recordedDurationSeconds: Double {
        Double(writtenPCMByteCount) / Double(max(bytesPerSecond, 1))
    }

    /// - Parameter appendingToExistingFile: `true` 时**不截断**已有文件，而是接着
    ///   往后写 —— 「挂断后点绿色按钮继续录、内容追加」靠它。同一个 `.wav` 一路写下去，
    ///   历史里也只有一场，而不是每按一次停就多出一条记录。
    init(fileURL: URL, sampleRate: Int, channelCount: Int, bitsPerSample: Int,
         appendingToExistingFile: Bool = false) throws {
        self.fileURL = fileURL
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // `createFile` 在文件已存在时是**截断**，所以追加这条路必须绕开它 ——
        // 否则「继续录」会把上一段的录音整个抹掉，而且不报任何错。
        if appendingToExistingFile, FileManager.default.fileExists(atPath: fileURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            // 文件大小减去 44 字节头 = 已经写进去的 PCM。停止时回填的头要算**总**长度，
            // 不是这一段的长度，所以起点必须从这里接着数。
            writtenPCMByteCount = max(fileSize - Int64(Self.wavHeaderByteCount), 0)
            fileHandle = try FileHandle(forWritingTo: fileURL)
            try fileHandle.seekToEnd()
            return
        }

        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw RecordingAudioWriterError.cannotCreateFile(fileURL.path)
        }
        fileHandle = try FileHandle(forWritingTo: fileURL)

        // 真正的长度还不知道，先按 0 写一个合法的头占位。这样即使进程立刻被杀，
        // 文件也是一个「0 秒的合法 WAV」而不是一个没有头的裸 PCM。
        try fileHandle.write(contentsOf: Self.wavHeader(pcmByteCount: 0,
                                                        sampleRate: sampleRate,
                                                        channelCount: channelCount,
                                                        bitsPerSample: bitsPerSample))
    }

    /// 追加一块 PCM。这是热路径 —— 每 100ms 一次，一录 3 小时要跑十万次。
    func append(_ pcm: Data) throws {
        guard !pcm.isEmpty else { return }
        try fileHandle.write(contentsOf: pcm)
        writtenPCMByteCount += Int64(pcm.count)
    }

    /// 回填头部并关闭。重复调用是安全的 —— 停止路径有好几条（用户按停止、快捷键、
    /// 退出 App），任何一条走到这里都必须能把文件收干净。
    func finalize() throws {
        guard !hasFinalized else { return }
        hasFinalized = true
        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: Self.wavHeader(pcmByteCount: writtenPCMByteCount,
                                                        sampleRate: sampleRate,
                                                        channelCount: channelCount,
                                                        bitsPerSample: bitsPerSample))
        try fileHandle.synchronize()
        try fileHandle.close()
    }

    /// 组装 44 字节的标准 PCM WAV 头。
    ///
    /// `pcmByteCount` 是 `data` 块的长度，`RIFF` 块的长度是它加上后面 36 字节。
    /// 这两个数字算错的话，文件在「QuickTime 能放、访达说损坏」之间反复横跳，
    /// 所以只在这一处算。
    static func wavHeader(pcmByteCount: Int64,
                          sampleRate: Int,
                          channelCount: Int,
                          bitsPerSample: Int) -> Data {
        let bytesPerFrame = channelCount * (bitsPerSample / 8)
        let byteRate = sampleRate * bytesPerFrame

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(littleEndianUInt32(UInt32(clamping: 36 + pcmByteCount)))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(littleEndianUInt32(16))                       // fmt 块长度
        header.append(littleEndianUInt16(1))                        // 1 = 未压缩 PCM
        header.append(littleEndianUInt16(UInt16(clamping: channelCount)))
        header.append(littleEndianUInt32(UInt32(clamping: sampleRate)))
        header.append(littleEndianUInt32(UInt32(clamping: byteRate)))
        header.append(littleEndianUInt16(UInt16(clamping: bytesPerFrame)))  // 块对齐
        header.append(littleEndianUInt16(UInt16(clamping: bitsPerSample)))
        header.append(contentsOf: Array("data".utf8))
        header.append(littleEndianUInt32(UInt32(clamping: pcmByteCount)))
        return header
    }

    /// 修一个「头还是占位值」的 WAV —— 断电、强杀、崩溃留下的都是这种。
    ///
    /// 判据不能靠读文件本身：占位头里 `data` 长度写的是 0，而 0 也是「刚开录就
    /// 断电」的合法值，两者从文件里分不出来。所以已写入的 PCM 字节数记在会话
    /// 元数据里，由调用方传进来。文件实际大小比元数据大时以文件为准 —— 那一块
    /// 是落盘成功但元数据没来得及更新。
    @discardableResult
    static func repairHeaderIfNeeded(fileURL: URL,
                                     recordedPCMByteCount: Int64,
                                     sampleRate: Int,
                                     channelCount: Int,
                                     bitsPerSample: Int) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let headerLength = Int64(wavHeaderByteCount)
        guard fileSize > headerLength else { return 0 }

        let pcmByteCount = max(fileSize - headerLength, recordedPCMByteCount)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: wavHeader(pcmByteCount: pcmByteCount,
                                               sampleRate: sampleRate,
                                               channelCount: channelCount,
                                               bitsPerSample: bitsPerSample))
        try handle.synchronize()
        return pcmByteCount
    }

    private static func littleEndianUInt32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
              UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
    }
    private static func littleEndianUInt16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }
}

nonisolated enum RecordingAudioWriterError: Error, CustomStringConvertible {
    case cannotCreateFile(String)

    var description: String {
        switch self {
        case .cannotCreateFile(let path): return "无法创建录音文件：\(path)"
        }
    }
}
