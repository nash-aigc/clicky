//
//  VoicePickerPanel.swift
//  Wanna
//
//  **音色面板** —— Ask 页与 Chatting 页共用的一份。
//
//  用户 2026-09-25 要求 Ask 页的音色按钮「仿照 Chatting 页面的音色按钮，它的下拉菜单
//  包括**试听、使用、收藏**、卡片的样式」。既然要"仿照"，就把那一套装成**一个组件**：
//  两个页面各写一遍必然漂，而它们本来就该长得一模一样 —— 卡片、★ 收藏、使用、▶ 试听，
//  分类只有「系统音色 / 克隆音色」（流式/非流式那层已在 2026-09-24 废弃）。
//
//  试听走 `VoicePreviewService`（三条合成路按音色族分派），播放走共享播放引擎 ——
//  与 Chatting 页的试听是同一条链路，所以"试听听到的 = 选中后朗读会发出的"。
//

import AppKit
import SwiftUI

struct VoicePickerPanel: View {

    /// 这一族音色：决定音色表与试听走哪条合成路。
    let engine: VoiceChatEngine
    /// 决定用哪张表的模型 id（全双工：模型版本；三段式：合成模型）。
    let modelID: String
    let selectedVoiceID: String
    let onSelectVoice: (String) -> Void
    /// 点面板外或选完就收起来（调用方自己管展开态）。
    let onClose: () -> Void

    private enum Category: String, CaseIterable, Identifiable {
        case system = "系统音色"
        case cloned = "克隆音色"
        var id: String { rawValue }
    }

    @State private var category: Category = .system
    @State private var customVoices: [CustomVoice] = []
    @State private var isLoadingCustomVoices = false
    @State private var previewingVoiceID: String?
    /// 收藏写入后强制重画（星星状态读的是 `VoiceLibraryStore`，不是 @Published）。
    @State private var favouriteRevision = 0
    @State private var hoveredVoiceID: String?

    private static let cardSpacing: CGFloat = 6
    private static let cardHeight: CGFloat = 62

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(Category.allCases) { option in
                    let isSelected = category == option
                    Button {
                        category = option
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isSelected ? DS.Colors.accent : DS.Colors.surface3)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11.5, weight: .medium))
                    Text(selectedVoiceDisplayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(DS.Colors.success)
                .frame(maxWidth: 150, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Text(hintText)
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)

            ScrollView {
                content
                    .id(favouriteRevision)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: 340)
        }
        .frame(width: 520)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .onTapGesture { }
        .onReceive(NotificationCenter.default.publisher(for: .wannaVoiceLibraryChanged)) { _ in
            favouriteRevision += 1
        }
        .onAppear(perform: loadCustomVoicesIfNeeded)
    }

    private var hintText: String {
        switch engine {
        case .threeStage: return "左列男声，右列女声。系统音色 + 你自己的克隆音色（收藏的排最前）。"
        case .duplexVoice: return "全双工语音模型的系统音色，跟着模型版本走。它没有克隆音色。"
        case .omni: return "全模态模型的内置音色。没有克隆音色。"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .system:
            let voices = VoiceLibraryStore.orderedByFavourites(
                VoiceCatalog.systemVoices(for: engine, model: modelID),
                engine: engine
            )
            if engine == .threeStage {
                let maleVoices = voices.filter { $0.gender == "男" }
                let femaleVoices = voices.filter { $0.gender == "女" }
                HStack(alignment: .top, spacing: Self.cardSpacing) {
                    genderColumn(maleVoices)
                    genderColumn(femaleVoices)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: Self.cardSpacing),
                        GridItem(.flexible(), spacing: Self.cardSpacing)
                    ],
                    spacing: Self.cardSpacing
                ) {
                    ForEach(voices) { voice in
                        voiceCard(
                            voiceID: voice.id,
                            title: voice.displayName,
                            subtitle: voice.id,
                            isSelected: voice.id == selectedVoiceID
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }

        case .cloned:
            if engine != .threeStage {
                Text("克隆音色只属于 3.1 TTS（三段式的「表达」）。全双工/全模态模型只能用它自带的系统音色。")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: Self.cardSpacing),
                        GridItem(.flexible(), spacing: Self.cardSpacing)
                    ],
                    spacing: Self.cardSpacing
                ) {
                    ForEach(customVoices) { customVoice in
                        voiceCard(
                            voiceID: customVoice.id,
                            title: VoiceLibraryStore.displayName(
                                forCustomVoiceID: customVoice.id,
                                cloudProvidedName: ""
                            ),
                            subtitle: "克隆 · \(customVoice.targetModel)",
                            isSelected: customVoice.id == selectedVoiceID
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                if customVoices.isEmpty, !isLoadingCustomVoices {
                    Text("这个账号下还没有克隆音色。去 设置 → 语音聊天 → 音色查看 → 声音克隆 里创建。")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private func genderColumn(_ voices: [VoiceOption]) -> some View {
        VStack(alignment: .leading, spacing: Self.cardSpacing) {
            ForEach(voices) { voice in
                voiceCard(
                    voiceID: voice.id,
                    title: voice.displayName,
                    subtitle: voice.id,
                    isSelected: voice.id == selectedVoiceID
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一张音色卡：名字 + id + ★ 收藏 / 使用 / ▶ 试听。与 Chatting 页同一套视觉。
    private func voiceCard(
        voiceID: String,
        title: String,
        subtitle: String,
        isSelected: Bool
    ) -> some View {
        // 克隆音色的收藏归属三段式（它只可能出现在那一族里）。
        let favouriteEngine: VoiceChatEngine = engine == .threeStage ? .threeStage : engine
        let favouriteKey = VoiceLibraryStore.favouriteKey(for: voiceID, engine: favouriteEngine)
        let isFavourite = VoiceLibraryStore.isFavourite(key: favouriteKey)
        let isHovered = hoveredVoiceID == voiceID
        let isPreviewing = previewingVoiceID == voiceID

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)

                cardButton(
                    systemImage: isFavourite ? "star.fill" : "star",
                    tint: isFavourite ? DS.Colors.warning : DS.Colors.textSecondary,
                    help: isFavourite ? "取消收藏" : "收藏"
                ) {
                    _ = try? VoiceLibraryStore.toggleFavourite(key: favouriteKey, displayName: title)
                    favouriteRevision += 1
                }

                cardButton(
                    systemImage: nil,
                    label: "使用",
                    tint: DS.Colors.accentText,
                    help: isSelected ? "当前音色" : "使用这个音色"
                ) {
                    onSelectVoice(voiceID)
                }
                .disabled(isSelected)

                cardButton(
                    systemImage: isPreviewing ? "hourglass" : "play.fill",
                    tint: DS.Colors.textSecondary,
                    help: "试听"
                ) {
                    audition(voiceID)
                }
                .disabled(previewingVoiceID != nil)
            }
            Text(subtitle)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: Self.cardHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isSelected ? DS.Colors.accent.opacity(0.18)
                    : (isHovered ? Color.white.opacity(0.07) : DS.Colors.surface3)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderSubtle, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { onSelectVoice(voiceID) }
        .onHover { hovering in hoveredVoiceID = hovering ? voiceID : nil }
        .help(isSelected ? "当前音色" : "点击选用 · ▶ 试听 · ★ 收藏")
    }

    private func cardButton(
        systemImage: String?,
        label: String? = nil,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11))
                } else {
                    Text(label ?? "").font(.system(size: 10.5, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
            .frame(width: label == nil ? 30 : 34, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.surface3))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }

    private func audition(_ voiceID: String) {
        guard previewingVoiceID == nil else { return }
        previewingVoiceID = voiceID
        Task { @MainActor in
            defer { previewingVoiceID = nil }
            guard let audioData = try? await VoicePreviewService.previewAudioData(
                engine: engine,
                voice: voiceID,
                model: modelID,
                speechRate: AppSettingsStore.snapshot().speechPlaybackRate,
                speechVolumePercent: AppSettingsStore.snapshot().speechPlaybackVolumePercent,
                styleInstruction: ""
            ) else { return }
            // 试听音频直接交给共享播放引擎（与 Chatting 页同一条链路）。
            await SharedVoicePreviewPlayer.shared.play(audioData)
        }
    }

    private func loadCustomVoicesIfNeeded() {
        guard engine == .threeStage, customVoices.isEmpty, !isLoadingCustomVoices else { return }
        isLoadingCustomVoices = true
        Task { @MainActor in
            defer { isLoadingCustomVoices = false }
            customVoices = (try? await CustomVoiceLibraryClient.listCustomVoices()) ?? []
        }
    }

    private var selectedVoiceDisplayName: String {
        let voices = VoiceCatalog.systemVoices(for: engine, model: modelID)
        if let nickname = VoiceLibraryStore.nickname(forCustomVoiceID: selectedVoiceID), !nickname.isEmpty {
            return nickname
        }
        return voices.first { $0.id == selectedVoiceID }?.displayName ?? selectedVoiceID
    }
}

/// 试听的播放器 —— 面板自己不认识 CompanionManager，用一个共享入口。
///
/// 复用那台 `AVAudioEngine`（`VoicePlaybackEngine`）是**刻意**的：试听与朗读走同一条
/// voice-processing 链路，用户听到的才是"选中之后它会发出的声音"。
@MainActor
final class SharedVoicePreviewPlayer {
    static let shared = SharedVoicePreviewPlayer()
    /// 由 `CompanionManager.start()` 注入（全 app 唯一那台播放引擎）。
    var playbackEngine: VoicePlaybackEngine?

    func play(_ wavData: Data) async {
        guard let playbackEngine else { return }
        await playbackEngine.warmUpForVoiceChat()
        let rate = Float(AppSettingsStore.snapshot().speechPlaybackRate)
        let volume = Float(AppSettingsStore.snapshot().speechPlaybackVolumePercent) / 100
        try? await playbackEngine.playWAVData(wavData, rate: rate, volume: volume)
    }
}
