import SwiftUI
import AppKit
import AVFoundation
import Combine

/// 参考音频的试听播放器。
///
/// **为什么不用那台共享的 TTS 引擎**：那台引擎是「让用户听到选完之后朗读会是什么声音」
/// 用的，走 voice-processing 链路；而这里要听的是**一个本地文件**，用户想确认的是
/// 「我选对录音了吗」。这台播放器要的是**暂停/继续**，而 `VoicePlaybackEngine`
/// 的 `stopChunk()` 只有停、没有暂停 —— 用 `AVAudioPlayer` 反而更直接。
///
/// 顺带一个好处：`AVAudioPlayer` 自己认 wav / mp3 / m4a 三种容器，而引擎那条路
/// 是把字节写进一个 `.wav` 临时文件再让 `AVAudioFile` 打开，非 WAV 会解不开。
@MainActor
final class ReferenceAudioAuditionPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {

    @Published private(set) var playingFileURL: URL?
    @Published private(set) var isPaused = false

    private var player: AVAudioPlayer?

    func toggle(_ fileURL: URL) {
        if playingFileURL == fileURL, let player {
            if player.isPlaying {
                player.pause()
                isPaused = true
            } else {
                player.play()
                isPaused = false
            }
            return
        }
        play(fileURL)
    }

    func play(_ fileURL: URL) {
        player?.stop()
        guard let newPlayer = try? AVAudioPlayer(contentsOf: fileURL) else {
            playingFileURL = nil
            player = nil
            return
        }
        newPlayer.delegate = self
        newPlayer.prepareToPlay()
        newPlayer.play()
        player = newPlayer
        playingFileURL = fileURL
        isPaused = false
    }

    func stop() {
        player?.stop()
        player = nil
        playingFileURL = nil
        isPaused = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playingFileURL = nil
            self.isPaused = false
            self.player = nil
        }
    }
}

/// 「声音克隆」—— 用户 2026-09-24 要的那一页：上传参考音频（单个或整个文件夹）、
/// 逐个试听、然后克隆，并看着结果一个个出来。
///
/// 三个设计点是从实测里来的，不是排版选择：
///
///  1. **克隆要 8~10 秒**（实测：`DEPLOYING` 四五次才 `OK`），所以每一步都有状态，
///     而且**一件一件来**：并发上传会在控制台上看到一堆同名任务，出错也分不清是哪个。
///  2. **按 `voice_id` 认结果，不按「列表里新出现的」认**。用户账号里可能本来就有
///     十个音色，这一轮又克隆了五个 —— 只有克隆调用返回的 id 才是「这一次的」。
///     所以每一行的结果都绑着它自己那次调用返回的 id。
///  3. **昵称默认取文件名**（用户 2026-09-24：「用户上传的音频文件本身就可以默认作为
///     音色克隆的昵称……比如用户想克隆张三的音色，使用这个文件时就能看到文件名」）。
///     克隆成功后立刻写进本地昵称表，用户不用手动起名；想改还是能改。
struct VoiceCloneWorkflowView: View {

    let companionManager: CompanionManager
    /// 「完成克隆」—— 跳回「克隆音色」并刷新，让用户看到刚建好的那批。
    var onFinished: () -> Void

    /// 一个参考文件对应的一次克隆。
    private struct CloneJob: Identifiable {
        enum Status: Equatable {
            case waiting
            case working(String)
            /// 成功：拿到云端 id。
            case created(voiceID: String)
            case failed(String)
        }

        let id = UUID()
        let fileURL: URL
        var status: Status = .waiting
        /// 用户没有手动改过昵称时，默认用文件名（去掉扩展名）。
        var nickname: String

        var displayName: String { nickname.isEmpty ? fileURL.lastPathComponent : nickname }
    }

    @State private var jobs: [CloneJob] = []
    @State private var isCloning = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isConfirmingUpload = false

    /// 结果里正在被编辑名称的那一行，以及草稿。
    @State private var editingResultJobID: UUID?
    @State private var nicknameDraft = ""
    /// 结果里等着第二次确认的删除。
    @State private var pendingDeleteJobID: UUID?

    @StateObject private var auditionPlayer = ReferenceAudioAuditionPlayer()

    /// 官方接受的三种容器。
    private static let acceptedAudioExtensions: Set<String> = ["wav", "mp3", "m4a"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DS.Colors.borderSubtle)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    referenceAudioSection
                    if !createdJobs.isEmpty {
                        createdVoicesSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            statusBar
        }
        .onDisappear { auditionPlayer.stop() }
    }

    private var createdJobs: [CloneJob] {
        jobs.filter { if case .created = $0.status { return true }; return false }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("声音克隆")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)

            Spacer(minLength: 8)

            // 右上角的「完成克隆」：**只负责跳回去 + 刷新**，让用户立刻在
            // 「克隆音色」那一栏看到刚建好的音色（用户 2026-09-24 的要求）。
            Button {
                auditionPlayer.stop()
                onFinished()
            } label: {
                Text("完成克隆")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DS.Colors.textOnAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - 参考音频

    private var referenceAudioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第一步 · 选参考音频")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)

            Text("官方要求：10~20 秒、≤10 MB、清晰无背景音。可以选单个文件，也可以选整个文件夹批量。")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                rowButton("选择音频文件") { pickAudioFiles() }
                rowButton("选择文件夹（批量）") { pickAudioFolder() }
                if !jobs.isEmpty {
                    rowButton("清空", isEnabled: !isCloning) { clearJobs() }
                }
                Spacer(minLength: 8)
                rowButton(isCloning ? "克隆中…" : "开始克隆", isPrimary: true, isEnabled: !isCloning && !jobs.isEmpty) {
                    // **先问一次再上传**（用户 2026-09-24：「因为要上传一个文件，
                    // 你要先让用户确定是不是真的上传了」）。上传是往云端写东西，
                    // 不该点一下就发生。
                    isConfirmingUpload = true
                }
            }

            if jobs.isEmpty {
                Text("还没有选文件。")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .padding(.top, 2)
            } else {
                ForEach(jobs) { job in
                    referenceFileRow(job)
                }
            }
        }
        .alert("把这 \(jobs.count) 个文件上传到云端并创建音色？", isPresented: $isConfirmingUpload) {
            Button("取消", role: .cancel) {}
            Button("上传并克隆") { startCloning() }
        } message: {
            Text("参考音频会上传到百炼的临时存储（48 小时后自动清理），并各创建一个克隆音色。"
                 + "克隆大约每个 8~10 秒。")
        }
    }

    private func referenceFileRow(_ job: CloneJob) -> some View {
        let isPlayingThisFile = auditionPlayer.playingFileURL == job.fileURL
        return HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.fileURL.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(jobStatusText(job))
                    .font(.system(size: 10.5))
                    .foregroundStyle(statusColor(job))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            rowButton(isPlayingThisFile ? (auditionPlayer.isPaused ? "继续" : "暂停") : "▶ 试听",
                      isEnabled: !isCloning) {
                auditionPlayer.toggle(job.fileURL)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.surface3))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
    }

    // MARK: - 克隆结果

    private var createdVoicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第二步 · 克隆结果")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)

            // 这一句是这一页最容易被误解的地方，所以写在界面上：账号里可能本来就有
            // 别的音色，这里**只列这一轮克隆出来的**。
            Text("只列这一次克隆出来的音色（按克隆调用返回的 id 认），账号里原有的不在其中。")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(createdJobs) { job in
                createdVoiceRow(job)
            }
        }
    }

    private func createdVoiceRow(_ job: CloneJob) -> some View {
        guard case .created(let voiceID) = job.status else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if editingResultJobID == job.id {
                        HStack(spacing: 6) {
                            TextField("给它起个名字", text: $nicknameDraft)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Colors.textPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.surface3))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.accent.opacity(0.6), lineWidth: 1))
                                .frame(maxWidth: 260)
                                .onSubmit { commitResultNickname(jobID: job.id, voiceID: voiceID) }
                            rowButton("保存", isPrimary: true) { commitResultNickname(jobID: job.id, voiceID: voiceID) }
                            rowButton("取消") { editingResultJobID = nil }
                        }
                    } else {
                        Text(job.displayName)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .onTapGesture(count: 2) { beginEditingResultNickname(job) }
                            .help("双击改名")
                    }
                    Text(voiceID)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                rowButton("▶ 试听") { previewCreatedVoice(voiceID: voiceID, displayName: job.displayName) }

                if pendingDeleteJobID == job.id {
                    Button {
                        deleteCreatedVoice(job, voiceID: voiceID)
                    } label: {
                        Text("确认删除")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Colors.destructiveText))
                    }
                    .buttonStyle(.plain)
                    rowButton("取消") { pendingDeleteJobID = nil }
                } else {
                    // 这一页**只有上传/试听/编辑/删除**，没有「使用」—— 用户明确说了
                    // 「音色克隆页面本身没有使用按钮，不能给它添加使用按钮」。
                    // 要用它，去「克隆音色」那一栏。
                    rowButton("删除") { pendingDeleteJobID = job.id }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.surface3))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        )
    }

    // MARK: - 底部状态

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(DS.Colors.borderSubtle)
            Group {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(DS.Colors.destructiveText)
                } else if let statusMessage {
                    Text(statusMessage).foregroundStyle(DS.Colors.textSecondary)
                } else {
                    Text("克隆出来的音色默认用文件名当名字，可以双击改。")
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }
            .font(.system(size: 11))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
        }
    }

    // MARK: - 小按钮（和「音色查看」那一页同一种样子）

    private func rowButton(
        _ title: String,
        isPrimary: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isPrimary ? .semibold : .regular))
                .foregroundStyle(isEnabled ? (isPrimary ? DS.Colors.accentText : DS.Colors.textSecondary) : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Colors.surface3))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isPrimary && isEnabled ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func jobStatusText(_ job: CloneJob) -> String {
        switch job.status {
        case .waiting: return "等待克隆"
        case .working(let step): return step
        case .created(let voiceID): return "已创建：\(voiceID)"
        case .failed(let message): return "失败：\(message)"
        }
    }

    private func statusColor(_ job: CloneJob) -> Color {
        switch job.status {
        case .failed: return DS.Colors.destructiveText
        case .created: return DS.Colors.success
        default: return DS.Colors.textTertiary
        }
    }

    // MARK: - 选文件

    private func pickAudioFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.allowedFileTypes = Array(Self.acceptedAudioExtensions)
        // 面板必须落在刘海面板**之上**：那个面板在 `.mainMenu + 1`，而 NSOpenPanel
        // 默认是 `.modalPanel`(8)，所以不抬起来的话用户点不到它里面任何东西
        // （仓库里 Agent 页的文件夹选择器踩过同一个坑，`NotchSupport` 为此留了
        // `modalFileDialogWindowLevel`）。
        panel.level = NotchSupport.modalFileDialogWindowLevel
        guard panel.runModal() == .OK else { return }
        appendJobs(for: panel.urls)
    }

    private func pickAudioFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.level = NotchSupport.modalFileDialogWindowLevel
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        let folderContents = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let audioFiles = folderContents
            .filter { Self.acceptedAudioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !audioFiles.isEmpty else {
            errorMessage = "「\(folderURL.lastPathComponent)」里没有 wav / mp3 / m4a 文件。"
            return
        }
        appendJobs(for: audioFiles)
    }

    private func appendJobs(for fileURLs: [URL]) {
        errorMessage = nil
        let existingPaths = Set(jobs.map { $0.fileURL.path })
        let newJobs = fileURLs
            .filter { !existingPaths.contains($0.path) }
            .map { CloneJob(fileURL: $0, nickname: $0.deletingPathExtension().lastPathComponent) }
        jobs.append(contentsOf: newJobs)
        statusMessage = "已加入 \(newJobs.count) 个文件，点「开始克隆」上传。"
    }

    private func clearJobs() {
        auditionPlayer.stop()
        jobs.removeAll()
        editingResultJobID = nil
        pendingDeleteJobID = nil
        statusMessage = nil
        errorMessage = nil
    }

    // MARK: - 克隆

    private func startCloning() {
        guard !isCloning, !jobs.isEmpty else { return }
        isCloning = true
        errorMessage = nil

        Task { @MainActor in
            defer { isCloning = false }
            let targetModel = currentSynthesisModel

            // **一件一件来**，不并发：并发上传会在账号里堆一串分不清谁是谁的任务，
            // 而且失败时无法归因。每个 8~10 秒，用户在列表上看得到进度。
            for index in jobs.indices {
                guard case .waiting = jobs[index].status else { continue }
                let fileURL = jobs[index].fileURL
                let fileJobID = jobs[index].id

                do {
                    let voiceID = try await CustomVoiceLibraryClient.createVoice(
                        referenceAudioFileURL: fileURL,
                        targetModel: targetModel,
                        onProgress: { step in
                            Task { @MainActor in
                                updateJob(id: fileJobID) { $0.status = .working(step) }
                            }
                        }
                    )
                    updateJob(id: fileJobID) { $0.status = .created(voiceID: voiceID) }

                    // 昵称默认取文件名（已去掉扩展名），克隆成功就立刻落盘 ——
                    // 用户不用手动起名，去「克隆音色」那一栏就能认出谁是谁。
                    if let job = jobs.first(where: { $0.id == fileJobID }), !job.nickname.isEmpty {
                        try? VoiceLibraryStore.setNickname(job.nickname, forCustomVoiceID: voiceID)
                    }
                    statusMessage = "「\(fileURL.lastPathComponent)」克隆好了。"
                } catch {
                    updateJob(id: fileJobID) { $0.status = .failed(error.localizedDescription) }
                    errorMessage = "「\(fileURL.lastPathComponent)」失败：\(error.localizedDescription)"
                }
            }
            statusMessage = "这一批处理完了。点右上角「完成克隆」回到「克隆音色」看结果。"
        }
    }

    private func updateJob(id: UUID, _ change: (inout CloneJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    /// 克隆绑定合成模型，所以用的是当前配置的合成模型 —— 与 VoiceCatalog 的
    /// 判断同源，不从别处再取一次。
    private var currentSynthesisModel: String {
        ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole?.modelID
            ?? BailianConfiguration.Models.textToSpeech
    }

    // MARK: - 结果上的动作

    private func beginEditingResultNickname(_ job: CloneJob) {
        guard case .created(let voiceID) = job.status else { return }
        editingResultJobID = job.id
        nicknameDraft = VoiceLibraryStore.nickname(forCustomVoiceID: voiceID) ?? job.nickname
    }

    private func commitResultNickname(jobID: UUID, voiceID: String) {
        let trimmed = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        try? VoiceLibraryStore.setNickname(trimmed, forCustomVoiceID: voiceID)
        updateJob(id: jobID) { $0.nickname = trimmed }
        editingResultJobID = nil
        statusMessage = trimmed.isEmpty ? "已清掉名字，这一行回到显示编号。" : "已改名为「\(trimmed)」。"
    }

    private func previewCreatedVoice(voiceID: String, displayName: String) {
        errorMessage = nil
        statusMessage = "正在合成「\(displayName)」…"
        Task { @MainActor in
            do {
                let appSettings = AppSettingsStore.snapshot()
                let audioData = try await VoicePreviewService.previewAudioData(
                    engine: .threeStage,
                    voice: voiceID,
                    model: currentSynthesisModel,
                    speechRate: appSettings.speechPlaybackRate,
                    speechVolumePercent: appSettings.speechPlaybackVolumePercent,
                    styleInstruction: ""
                )
                try await companionManager.playVoicePreview(wavData: audioData)
                statusMessage = "正在试听「\(displayName)」。"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = nil
            }
        }
    }

    private func deleteCreatedVoice(_ job: CloneJob, voiceID: String) {
        pendingDeleteJobID = nil
        statusMessage = "正在删除「\(voiceID)」…"
        Task { @MainActor in
            do {
                try await CustomVoiceLibraryClient.deleteVoice(voiceID: voiceID)
                try? VoiceLibraryStore.setNickname("", forCustomVoiceID: voiceID)
                jobs.removeAll { $0.id == job.id }
                statusMessage = "已删除「\(voiceID)」（云端也删了），可以重新克隆一个。"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = nil
            }
        }
    }
}
