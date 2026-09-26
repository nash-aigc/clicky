import Foundation

/// 一次录音的元数据。文件名由 `id` 派生，所以 `id` 必须对文件系统安全。
///
/// 落盘位置：`<保存目录>/<id>.json`，和音频、转录文本放在一起。它刻意**不**只存在
/// 一个中心索引文件里 —— 每次录音自己带一份元数据，意味着用户可以把一整场录音
/// （四个文件）直接拖走，不需要任何外部索引也对得上。
nonisolated struct RecordingSession: Codable, Identifiable, Equatable {
    /// 形如 `2026-09-25-190412-A3F2`：时间在前，用户在访达里按名字排序就是按
    /// 时间排序；后缀四位短随机码避免同一秒开两次撞名。
    let id: String
    var startedAt: Date
    var endedAt: Date?
    /// 已录时长（秒）。由**写入的音频字节数**反推，不是墙上时钟 —— 中途暂停、
    /// 重连空档都不该算进音频长度。
    var recordedSeconds: Double
    var characterCount: Int
    var segmentCount: Int
    /// 正常停止为 `true`；崩溃、断电、强杀留下的都是 `false`，历史列表据此提示
    /// 「未正常结束」并走一次 `repairHeaderIfNeeded`。
    var endedCleanly: Bool
    /// 中途换过几次连接。这个数字是「长会话到底稳不稳」唯一可核对的判据。
    var connectionRotationCount: Int
    /// 真正发出去的 `X-Api-Resource-Id`，记下来才知道这份录音是哪一档模型识别的。
    var resourceID: String
    var sampleRate: Int
    var channelCount: Int
    var bitsPerSample: Int
    /// 最后一次错误。正常结束为 nil。
    var lastErrorMessage: String?

    var audioFileName: String { "\(id).wav" }
    /// **源文本**：识别器逐句落盘的原文，录制过程中就在写，润色不碰它。
    var transcriptFileName: String { "\(id).txt" }
    /// **润色文本**：走「自定义风格」重写之后的结果。没开润色时这个文件不存在。
    ///
    /// 用户的要求：「润色文本与原文（撰写文本）要保存两份，分别是不同的文本文件，
    /// 因为用户很有可能去看原文、原文档」。合成一份的话，润色一跑原文就没了 ——
    /// 而那恰恰是他最想回头核对的东西。
    var polishedTranscriptFileName: String { "\(id).polished.txt" }
    var segmentFileName: String { "\(id).jsonl" }

    func audioFileURL(inFolder folder: URL) -> URL { folder.appendingPathComponent(audioFileName) }
    func transcriptFileURL(inFolder folder: URL) -> URL { folder.appendingPathComponent(transcriptFileName) }
    func polishedTranscriptFileURL(inFolder folder: URL) -> URL {
        folder.appendingPathComponent(polishedTranscriptFileName)
    }
    func segmentFileURL(inFolder folder: URL) -> URL { folder.appendingPathComponent(segmentFileName) }
    func metadataFileURL(inFolder folder: URL) -> URL { folder.appendingPathComponent("\(id).json") }

    /// 这一场的四个文件在不在。历史列表用它判断一份记录是不是被用户手动删过。
    func isComplete(inFolder folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: metadataFileURL(inFolder: folder).path)
    }

    var formattedDuration: String {
        let total = Int(recordedSeconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// 录音历史。索引落在 `Recordings.json`，位置和 `AppSettings.json` 同一层
/// （`~/Library/Application Support/Wanna/`）。
///
/// 形状照 `ConversationSessionsStore` / `AppSettingsStore`：`nonisolated` +
/// `NSLock` + 原子写后补 `0600` + 变更通知。这几个 store 长一样不是巧合 ——
/// 项目的 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 让一个隔离写错变得静默，
/// 所以凡是跨线程读写的存储都用同一种能一眼看懂的形状。
///
/// **索引只是缓存，不是真相。** `rescanFromDisk` 能只靠目录里的 `.json` 把历史
/// 重建出来 —— 索引文件被删、被写坏、或者录音是崩溃留下的（根本没来得及更新
/// 索引），历史列表都必须照样显示得出来。
nonisolated final class RecordingLibraryStore {

    static let shared = RecordingLibraryStore()
    static let didChangeNotification = Notification.Name("wannaRecordingLibraryDidChange")

    private let lock = NSLock()
    private var cachedSessions: [RecordingSession]?

    private var indexFileURL: URL {
        AppSupportDirectory.folderURLOrHome.appendingPathComponent("Recordings.json")
    }

    /// 用户没指定时的保存目录：checkout 里的 `Wanna录音/`。
    ///
    /// 放 checkout 而不是 `Application Support`：那是隐藏目录，用户在访达里找不到。
    /// 录完的文件是要给人看、给人拖走的，所以和图形、复盘一起放在 checkout 里
    /// —— 具体位置由 `WorkspaceDirectory` 一家说了算。
    static var defaultFolderURL: URL {
        WorkspaceDirectory.recordingsURL
    }

    static func resolvedFolderURL(fromSettingsPath path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultFolderURL }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    // MARK: - 读

    func allSessions() -> [RecordingSession] {
        lock.lock()
        if let cachedSessions { lock.unlock(); return cachedSessions }
        lock.unlock()

        let loaded = loadIndexFromDisk()
        lock.lock(); cachedSessions = loaded; lock.unlock()
        return loaded
    }

    private func loadIndexFromDisk() -> [RecordingSession] {
        guard let data = try? Data(contentsOf: indexFileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessions = (try? decoder.decode([RecordingSession].self, from: data)) ?? []
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// 只靠磁盘重建历史 —— 索引丢了也能恢复。按保存目录里的 `<id>.json` 扫，
    /// 读不出来或者没有音频对应文件的条目直接跳过。
    func rescanFromDisk(folder: URL) -> [RecordingSession] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var sessions: [RecordingSession] = []
        for file in contents where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(RecordingSession.self, from: data) else { continue }
            sessions.append(session)
        }
        sessions.sort { $0.startedAt > $1.startedAt }

        lock.lock(); cachedSessions = sessions; lock.unlock()
        writeIndexToDisk(sessions)
        return sessions
    }

    // MARK: - 写

    func upsert(_ session: RecordingSession) {
        lock.lock()
        var sessions = cachedSessions ?? loadIndexFromDisk()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.startedAt > $1.startedAt }
        cachedSessions = sessions
        lock.unlock()

        writeIndexToDisk(sessions)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// 从历史里移除。**只删索引，不删用户的文件** —— 删录音是删除文件本身的事，
    /// 由界面上带确认的「移到废纸篓」负责。悄悄删掉用户的录音是这个项目里最不能
    /// 接受的一类错误。
    func forget(sessionID: String) {
        lock.lock()
        var sessions = cachedSessions ?? loadIndexFromDisk()
        sessions.removeAll { $0.id == sessionID }
        cachedSessions = sessions
        lock.unlock()

        writeIndexToDisk(sessions)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// 按保留天数清掉过期的东西。返回删了几个文件。
    ///
    /// **音频先删、文本后删，而且只删文件、不删记录** —— 历史列表里那一条依然在，
    /// 只是打不开音频了。用户的要求是「录音文件很占空间」，所以音频留一天、文本留
    /// 三十天（3 小时约 6 万字 = 180KB，比音频小三个数量级）。
    ///
    /// `0` = 永久保存，那一路什么都不做。
    ///
    /// **删文件是这个 App 里唯一一处不可逆的动作**，所以它只在启动时跑一次、
    /// 只按天数判断、并且把每一步都写进诊断日志 —— 不留任何「悄悄删掉」的路径。
    @discardableResult
    func purgeExpiredRecordings(folder: URL,
                                audioRetentionDays: Int,
                                textRetentionDays: Int) -> Int {
        let fileManager = FileManager.default
        let now = Date()
        var deletedCount = 0

        for session in allSessions() {
            let ageInDays = now.timeIntervalSince(session.startedAt) / 86_400

            // 文本到期 → 整场都删掉（音频必然更早到期）。
            if textRetentionDays > 0, ageInDays > Double(textRetentionDays) {
                for url in [session.audioFileURL(inFolder: folder),
                            session.transcriptFileURL(inFolder: folder),
                            session.polishedTranscriptFileURL(inFolder: folder),
                            session.segmentFileURL(inFolder: folder),
                            session.metadataFileURL(inFolder: folder)] {
                    if (try? fileManager.removeItem(at: url)) != nil { deletedCount += 1 }
                }
                forget(sessionID: session.id)
                continue
            }

            // 只删音频。
            if audioRetentionDays > 0, ageInDays > Double(audioRetentionDays) {
                let audioURL = session.audioFileURL(inFolder: folder)
                if fileManager.fileExists(atPath: audioURL.path),
                   (try? fileManager.removeItem(at: audioURL)) != nil {
                    deletedCount += 1
                }
            }
        }
        return deletedCount
    }

    private func writeIndexToDisk(_ sessions: [RecordingSession]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sessions) else { return }

        let url = indexFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            // `.atomic` 落下来是 0644，而这几个文件都记着用户录了什么，不该是
            // 其他用户可读的。项目里每个 store 都这么做，理由相同。
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("[RecordingLibrary] 写索引失败：\(error)")
        }
    }
}
