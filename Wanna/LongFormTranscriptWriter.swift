import Combine
import Foundation

/// 转录文本的落盘与显示窗口。
///
/// ## 为什么不是一个 `@Published var fullText: String`
///
/// 3 小时的转录约 3–6 万字。把它整段挂在 `@Published` 上，每来一个字 SwiftUI 就
/// 要 diff 整个字符串、重排整个视图 —— 这正是这个仓库刚在回答卡片上踩过的坑
/// （长文最后一行卡顿，根因就是每个字符都触发一次全量重排）。所以这里分开：
///
/// - **磁盘是真相。** `<id>.jsonl` 逐段追加（带毫秒时间戳），`<id>.txt` 是给人
///   直接打开看的纯文本。每段 `definite` 落盘后立刻 `synchronize()`，断电最多
///   丢最后一句。
/// - **内存只留窗口。** `liveLineText` 是当前还没定稿的那一句（跑马灯只用它），
///   加上最近若干段的计数。全文从不进内存做显示，只在用户按下停止时从磁盘读一次
///   用于剪贴板。
///
/// 这样「录了 3 小时」和「录了 30 秒」在运行时的开销是同一个量级。
@MainActor
final class LongFormTranscriptWriter: ObservableObject {

    /// 磁盘上一行一段的形状。字段名短，因为 3 小时要写几千行。
    private struct SegmentRecord: Codable {
        let start: Int
        let end: Int
        let text: String
    }

    /// 跑马灯显示的那一行 —— 当前还没定稿的句子。空字符串是唯一的「没东西显示」
    /// 状态，和这个项目里回答气泡的做法一致。
    @Published private(set) var liveLineText: String = ""
    /// 已落盘的字符数。设置页历史列表和录音中的统计读它。
    @Published private(set) var committedCharacterCount: Int = 0
    @Published private(set) var committedSegmentCount: Int = 0

    let segmentFileURL: URL
    let plainTextFileURL: URL

    private let ioQueue = DispatchQueue(label: "wanna.longform.transcript.io")
    private var segmentHandle: FileHandle?
    private var plainTextHandle: FileHandle?
    /// 上一个已落盘段的文本。跨重连也成立的判重依据 —— 见 `commit`。
    private var lastCommittedText = ""
    private var hasFinalized = false

    /// 「已提交水位」：已经落盘的音频毫秒位置。
    ///
    /// 它是重连时对齐的锚点。新连接的 `start_time`/`end_time` 是**从 0 重计**的，
    /// 所以调用方要按「已喂总时长」把这个水位平移过去，凡落在水位之前的段一律丢弃。
    /// 用服务端给的绝对毫秒而不是文本相似度，是因为文本会被识别器改写，毫秒不会。
    private(set) var committedWatermarkMilliseconds: Int = 0

    /// - Parameter appendingToExistingFile: `true` 时接着已有文件写，并把已经落盘的
    ///   字数、段数、以及文本尾部读回来 —— 界面上的跑马灯和统计要接着上一段走，
    ///   不能在「继续录」之后从零开始。
    init(folder: URL, sessionID: String, appendingToExistingFile: Bool = false) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        segmentFileURL = folder.appendingPathComponent("\(sessionID).jsonl")
        plainTextFileURL = folder.appendingPathComponent("\(sessionID).txt")

        if appendingToExistingFile, FileManager.default.fileExists(atPath: plainTextFileURL.path) {
            let existing = (try? String(contentsOf: plainTextFileURL, encoding: .utf8)) ?? ""
            let existingLines = existing.split(separator: "\n", omittingEmptySubsequences: true)
            committedCharacterCount = existingLines.reduce(0) { $0 + $1.count }
            committedSegmentCount = existingLines.count
            segmentHandle = try FileHandle(forWritingTo: segmentFileURL)
            plainTextHandle = try FileHandle(forWritingTo: plainTextFileURL)
            try segmentHandle?.seekToEnd()
            try plainTextHandle?.seekToEnd()
            // 服务端的时间轴从新连接起**重新计零**，所以对齐用的水位也要归零，
            // 否则新连接的内容会全部因为「end 比上一段小」被当成重复丢掉。
            lastCommittedText = ""
            committedWatermarkMilliseconds = 0
            return
        }

        FileManager.default.createFile(atPath: segmentFileURL.path, contents: nil)
        FileManager.default.createFile(atPath: plainTextFileURL.path, contents: nil)
        segmentHandle = try FileHandle(forWritingTo: segmentFileURL)
        plainTextHandle = try FileHandle(forWritingTo: plainTextFileURL)
    }

    // MARK: - 写入

    /// 把当前这一句的最新版本交给跑马灯。只改内存，不碰磁盘 —— 一句话在说的时候
    /// 会回调几十次，每次都落盘会让硬盘一直转。
    func updateLiveLine(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != liveLineText else { return }
        liveLineText = trimmed
    }

    /// 落盘一个已经定稿的段。**返回是否真的落盘了** —— 调用方（展开面板的那份
    /// 文本）必须跟着这个返回值走，否则被判重丢掉的那一段仍然会显示出来，屏幕上
    /// 就是每句都出现两遍。
    @discardableResult
    func commit(segment: VolcengineASRSegment) -> Bool {
        guard segment.isDefinite else { return false }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        // 判重**按文本**，不按时间戳。
        //
        // 原来按 `endMilliseconds` 递增判断，跨重连是错的：重连之后服务端的时间轴
        // **从零重计**，新段的 end（比如 3000）会小于上一段的 end（比如 60000），
        // 于是真实内容被当成重复整段丢掉 —— 而重复的那一份反而留下。按文本比，
        // 跨连接、跨轮换都成立。
        guard text != lastCommittedText else { return false }
        lastCommittedText = text
        committedWatermarkMilliseconds = max(committedWatermarkMilliseconds, segment.endMilliseconds)

        committedCharacterCount += text.count
        committedSegmentCount += 1
        if liveLineText == text { liveLineText = "" }

        let record = SegmentRecord(start: segment.startMilliseconds,
                                   end: segment.endMilliseconds,
                                   text: text)
        ioQueue.async { [weak self] in
            guard let self else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            if let data = try? encoder.encode(record), var line = data as Data? {
                line.append(0x0A)                                  // 换行
                try? self.segmentHandle?.write(contentsOf: line)
            }
            // 纯文本那份：一句一行，带序号在阅读时更容易对照 jsonl。
            if let textData = (text + "\n").data(using: .utf8) {
                try? self.plainTextHandle?.write(contentsOf: textData)
            }
            // 立刻刷盘。断电时最多丢最后一句 —— 这是「实时保存」这条要求的下限。
            try? self.segmentHandle?.synchronize()
            try? self.plainTextHandle?.synchronize()
        }
        return true
    }

    /// 换连接前把当前没定稿的那句也留在磁盘上。
    ///
    /// 必须有这一步：用户说到一半连接断了，那句还停在 `liveLineText` 里，重连后
    /// 服务端会重新识别那几秒，但如果重连失败它就永远丢了。留一个「未定稿」标记，
    /// 让用户至少能在文件里看到自己说过什么。
    func commitLiveLineAsUnfinished() {
        let text = liveLineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        liveLineText = ""
        committedCharacterCount += text.count
        committedSegmentCount += 1

        ioQueue.async { [weak self] in
            guard let self else { return }
            if let textData = (text + "\n").data(using: .utf8) {
                try? self.plainTextHandle?.write(contentsOf: textData)
                try? self.plainTextHandle?.synchronize()
            }
            if let jsonData = try? JSONSerialization.data(withJSONObject: [
                "start": 0, "end": 0, "text": text, "unfinished": true,
            ] as [String: Any]), var line = jsonData as Data? {
                line.append(0x0A)
                try? self.segmentHandle?.write(contentsOf: line)
                try? self.segmentHandle?.synchronize()
            }
        }
    }

    func finalize() {
        guard !hasFinalized else { return }
        hasFinalized = true
        ioQueue.sync {
            try? self.segmentHandle?.synchronize()
            try? self.plainTextHandle?.synchronize()
            try? self.segmentHandle?.close()
            try? self.plainTextHandle?.close()
            self.segmentHandle = nil
            self.plainTextHandle = nil
        }
    }

    // MARK: - 读回

    /// 全文。只在用户按下停止、要往剪贴板写的时候调用一次 —— 3 小时几万字，
    /// 读一次是毫秒级，但绝不能挂在 `@Published` 上每帧重排。
    func readFullTextFromDisk() -> String {
        finalize()
        return (try? String(contentsOf: plainTextFileURL, encoding: .utf8)) ?? ""
    }
}
