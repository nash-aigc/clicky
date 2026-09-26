//
//  ModelSettingsView.swift
//  Wanna
//
//  The model settings form: which provider serves each of the three roles, and
//  what each provider's URL, key and model names are.
//
//  Two sections, and the split matters:
//
//  * 「当前使用」 answers "who is doing what right now" — one row per role. This is
//    the only place a role's provider is chosen, so there is never a question of
//    which card wins when two providers both have a vision model filled in.
//  * 「服务商」 holds credentials only — one card per provider. Model names are not
//    duplicated here; they are stored per provider and edited in 「当前使用」, where
//    the provider using them is visible.
//

import SwiftUI

/// Identifies which field has keyboard focus, so a field can draw an accent
/// border while it is being edited.
private struct SettingsFieldIdentifier: Hashable {
    enum Kind: Hashable {
        case providerDisplayName
        case baseURL
        case apiKey
        case modelID(ModelRole)
        case speechVoiceID
    }

    let providerID: UUID
    let kind: Kind
}

struct ModelSettingsView: View {
    @ObservedObject var modelSettingsViewModel: ModelSettingsViewModel

    @FocusState private var focusedField: SettingsFieldIdentifier?
    @State private var revealedAPIKeyProviderIDs: Set<UUID> = []
    @State private var providerPendingDeletion: ProviderProfile?

    /// Fixed label column so every row's fields start at the same x position.
    /// A `Grid` would be the tidier tool, but its columns size to their widest
    /// content, which lets a long provider name push every field out of alignment.
    private let labelColumnWidth: CGFloat = 120
    private let providerPickerWidth: CGFloat = 150
    private let formHorizontalPadding: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            introductionSection

            // The form scrolls; the action bar below does not, so 保存 and 测试连接
            // stay reachable no matter how many providers are configured.
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xxl) {
                    currentUsageSection
                    providersSection
                }
                .padding(.horizontal, formHorizontalPadding)
                .padding(.bottom, DS.Spacing.xl)
            }

            actionBar
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(DS.Colors.background)
        .alert(
            "删除服务商？",
            isPresented: Binding(
                get: { providerPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented { providerPendingDeletion = nil }
                }
            ),
            presenting: providerPendingDeletion
        ) { providerPendingDeletion in
            Button("删除", role: .destructive) {
                modelSettingsViewModel.removeProvider(withID: providerPendingDeletion.id)
                self.providerPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                self.providerPendingDeletion = nil
            }
        } message: { providerPendingDeletion in
            Text(deletionConsequenceDescription(for: providerPendingDeletion))
        }
    }

    // MARK: - Introduction

    private var introductionSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("为每个服务商填 URL 与 API Key，再为三个角色指定用哪家、用哪个模型。")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Text("「保存」后立即生效，不用重启。正在朗读的这一句会念完，下一句才换。")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, formHorizontalPadding)
        .padding(.top, DS.Spacing.xl)
        .padding(.bottom, DS.Spacing.lg)
    }

    // MARK: - Current usage

    private var currentUsageSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            sectionHeader("当前使用")

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                ForEach(ModelRole.allCases, id: \.self) { role in
                    roleRow(for: role)
                }
            }
        }
    }

    @ViewBuilder
    private func roleRow(for role: ModelRole) -> some View {
        let roleStatus = modelSettingsViewModel.status(of: role)
        let assignedProviderID = modelSettingsViewModel.draftConfiguration.providerID(for: role)

        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.md) {
                Text("\(role.emoji) \(role.shortName)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: labelColumnWidth, alignment: .leading)

                providerPicker(for: role)
                    .frame(width: providerPickerWidth)

                if let assignedProviderID {
                    modelField(for: role, providerID: assignedProviderID)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("先在上面选一个服务商")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // The voice belongs to the speech row rather than to a provider card,
            // because the valid voice names depend on which TTS model family is in
            // use — and model names are chosen here.
            if role == .speech, let assignedProviderID {
                HStack(spacing: DS.Spacing.md) {
                    Text("音色")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: labelColumnWidth, alignment: .leading)

                    speechVoiceField(providerID: assignedProviderID)
                        .frame(maxWidth: .infinity)
                }
            }

            if let unavailableExplanation = roleStatus.unavailableExplanation {
                HStack(spacing: DS.Spacing.md) {
                    Color.clear.frame(width: labelColumnWidth, height: 1)

                    Text(unavailableExplanation)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.destructiveText)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func providerPicker(for role: ModelRole) -> some View {
        Picker(
            "",
            selection: Binding(
                get: { modelSettingsViewModel.draftConfiguration.providerID(for: role) },
                set: { modelSettingsViewModel.assignProvider($0, to: role) }
            )
        ) {
            Text("未指定").tag(UUID?.none)

            ForEach(modelSettingsViewModel.assignableProviders(for: role)) { provider in
                Text(provider.displayName).tag(UUID?.some(provider.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .font(.system(size: 12))
    }

    /// The model name for `role`, on the provider that currently serves it.
    ///
    /// A plain text field rather than a dropdown: this app has to work with model
    /// names it has never heard of, so the known-good names are offered beside the
    /// field instead of replacing the ability to type one.
    private func modelField(for role: ModelRole, providerID: UUID) -> some View {
        let provider = modelSettingsViewModel.draftConfiguration.provider(withID: providerID)
        let presetModelIDs = provider?.effectiveFlavor.presetModelIDs(for: role) ?? []

        return HStack(spacing: DS.Spacing.sm) {
            TextField("模型名", text: modelSettingsViewModel.modelIDBinding(for: providerID, role: role))
                .settingsTextFieldStyle(
                    isFocused: focusedField == SettingsFieldIdentifier(providerID: providerID, kind: .modelID(role))
                )
                .focused($focusedField, equals: SettingsFieldIdentifier(providerID: providerID, kind: .modelID(role)))

            if !presetModelIDs.isEmpty {
                Menu {
                    ForEach(presetModelIDs, id: \.self) { presetModelID in
                        Button(presetModelID) {
                            modelSettingsViewModel.modelIDBinding(for: providerID, role: role).wrappedValue = presetModelID
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 22, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .pointerCursor()
            }
        }
    }

    private func speechVoiceField(providerID: UUID) -> some View {
        TextField(
            "音色名（音色名不能跨模型族使用）",
            text: modelSettingsViewModel.speechVoiceIDBinding(for: providerID)
        )
        .settingsTextFieldStyle(
            isFocused: focusedField == SettingsFieldIdentifier(providerID: providerID, kind: .speechVoiceID)
        )
        .focused($focusedField, equals: SettingsFieldIdentifier(providerID: providerID, kind: .speechVoiceID))
    }

    // MARK: - Providers

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            sectionHeader("服务商")

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                ForEach(modelSettingsViewModel.draftConfiguration.providers) { provider in
                    providerCard(for: provider.id)
                }
            }

            Menu {
                ForEach([APIProviderFlavor.bailian, .deepSeek, .custom], id: \.self) { flavor in
                    Button(flavor.displayName) {
                        modelSettingsViewModel.addProvider(flavor: flavor)
                    }
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("添加服务商")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
        }
    }

    @ViewBuilder
    private func providerCard(for providerID: UUID) -> some View {
        let providerBinding = modelSettingsViewModel.providerBinding(for: providerID)
        let rolesServedEmoji = modelSettingsViewModel.roleEmojiServed(by: providerID)

        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                TextField("名称", text: providerBinding.displayName)
                    .settingsTextFieldStyle(
                        isFocused: focusedField == SettingsFieldIdentifier(providerID: providerID, kind: .providerDisplayName)
                    )
                    .focused($focusedField, equals: SettingsFieldIdentifier(providerID: providerID, kind: .providerDisplayName))
                    .frame(width: 180)

                Text(providerBinding.wrappedValue.effectiveFlavor.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(DS.Colors.surface3)
                    )

                // Read-back of what this provider is responsible for, so a role's
                // owner is never invisible.
                Text(rolesServedEmoji.isEmpty ? "未承担角色" : "承担：\(rolesServedEmoji.joined(separator: " "))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(rolesServedEmoji.isEmpty ? DS.Colors.textTertiary : DS.Colors.success)

                Spacer()

                Button("删除") {
                    providerPendingDeletion = providerBinding.wrappedValue
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.destructiveText)
                .pointerCursor()
            }

            if providerBinding.wrappedValue.flavor == .custom {
                protocolRow(for: providerID, providerBinding: providerBinding)
            }

            labeledFieldRow(label: "URL") {
                TextField("https://…", text: providerBinding.baseURL)
                    .settingsTextFieldStyle(
                        isFocused: focusedField == SettingsFieldIdentifier(providerID: providerID, kind: .baseURL)
                    )
                    .focused($focusedField, equals: SettingsFieldIdentifier(providerID: providerID, kind: .baseURL))
                    .font(.system(size: 12, design: .monospaced))
            }

            labeledFieldRow(label: "API Key") {
                HStack(spacing: DS.Spacing.sm) {
                    apiKeyField(for: providerID, providerBinding: providerBinding)

                    Button(revealedAPIKeyProviderIDs.contains(providerID) ? "隐藏" : "显示") {
                        if revealedAPIKeyProviderIDs.contains(providerID) {
                            revealedAPIKeyProviderIDs.remove(providerID)
                        } else {
                            revealedAPIKeyProviderIDs.insert(providerID)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 34)
                    .pointerCursor()
                }
            }

            labeledFieldRow(label: "推理") {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Toggle(
                        "让模型先推理再回答",
                        isOn: modelSettingsViewModel.visionReasoningBinding(for: providerID)
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()

                    // The cost is stated in the caption rather than left to be
                    // discovered, because it is large: measured 2026-09-21 at
                    // 664-868 reasoning tokens on a question as simple as "屏幕右上角
                    // 有什么？" — 3.4s of thinking against 0.3s of actual answer.
                    Text(
                        providerBinding.wrappedValue.allowsVisionReasoning
                            ? "先想再答。每次大约慢 3.4 秒，难题可能答得更准。只影响 🧠 想。"
                            : "直接回答。每次快大约 3.4 秒。只影响 🧠 想。"
                    )
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DS.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    /// Which protocol a 自定义 host speaks. Only the two protocols this app knows
    /// how to address are offered — that is what keeps the request path out of the
    /// user's hands, where a typo would fail as a mystery 404.
    private func protocolRow(for providerID: UUID, providerBinding: Binding<ProviderProfile>) -> some View {
        HStack(spacing: DS.Spacing.md) {
            Text("协议")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: labelColumnWidth, alignment: .leading)

            Picker(
                "",
                selection: Binding(
                    get: { providerBinding.wrappedValue.customProtocol ?? .bailian },
                    set: { newProtocol in
                        var editedProvider = providerBinding.wrappedValue
                        editedProvider.customProtocol = newProtocol
                        providerBinding.wrappedValue = editedProvider
                    }
                )
            ) {
                Text(APIProviderFlavor.bailian.displayName).tag(APIProviderFlavor.bailian)
                Text(APIProviderFlavor.deepSeek.displayName).tag(APIProviderFlavor.deepSeek)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: providerPickerWidth)
        }
    }

    @ViewBuilder
    private func apiKeyField(for providerID: UUID, providerBinding: Binding<ProviderProfile>) -> some View {
        let isRevealed = revealedAPIKeyProviderIDs.contains(providerID)
        let fieldIdentifier = SettingsFieldIdentifier(providerID: providerID, kind: .apiKey)

        Group {
            if isRevealed {
                // Revealed on request only. The key is never shown by default, and
                // never shown merely because the field took focus — this window can
                // be open on a shared screen.
                TextField("sk-…", text: providerBinding.apiKey)
            } else {
                SecureField("sk-…", text: providerBinding.apiKey)
            }
        }
        .settingsTextFieldStyle(isFocused: focusedField == fieldIdentifier)
        .focused($focusedField, equals: fieldIdentifier)
        .font(.system(size: 12, design: .monospaced))
    }

    private func labeledFieldRow<FieldContent: View>(
        label: String,
        @ViewBuilder fieldContent: () -> FieldContent
    ) -> some View {
        HStack(spacing: DS.Spacing.md) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: labelColumnWidth, alignment: .leading)

            fieldContent()
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Divider().overlay(DS.Colors.borderSubtle)

            HStack(alignment: .top, spacing: DS.Spacing.lg) {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Button {
                        Task { await modelSettingsViewModel.testConnections() }
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            if modelSettingsViewModel.isTestingConnections {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(modelSettingsViewModel.isTestingConnections ? "测试中…" : "测试连接")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(modelSettingsViewModel.isTestingConnections)

                    connectionTestResultsSummary
                }

                Spacer()

                HStack(spacing: DS.Spacing.sm) {
                    if let saveErrorMessage = modelSettingsViewModel.saveErrorMessage {
                        Text(saveErrorMessage)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.destructiveText)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else if modelSettingsViewModel.lastSavedAt != nil && !modelSettingsViewModel.isDirty {
                        Text("已保存，立即生效")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.success)
                    }

                    Button("保存") {
                        modelSettingsViewModel.save()
                    }
                    .buttonStyle(DSPillButtonStyle(isEnabled: modelSettingsViewModel.isDirty))
                    .disabled(!modelSettingsViewModel.isDirty)

                    Button("关闭") {
                        NSApp.keyWindow?.close()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                    .pointerCursor()
                }
            }
            .padding(.horizontal, formHorizontalPadding)
            .padding(.vertical, DS.Spacing.md)
        }
        .background(DS.Colors.background)
    }

    /// One line per role. Failures show the service's own error text, selectable so
    /// it can be copied straight into a search box — the wording is what identifies
    /// the problem, and a paraphrase would not.
    @ViewBuilder
    private var connectionTestResultsSummary: some View {
        if !modelSettingsViewModel.connectionTestResults.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ModelRole.allCases, id: \.self) { role in
                    if let result = modelSettingsViewModel.connectionTestResults[role] {
                        Text(connectionTestResultDescription(for: result))
                            .font(.system(size: 11))
                            .foregroundColor(result.isSuccess ? DS.Colors.success : DS.Colors.destructiveText)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    private func connectionTestResultDescription(for result: ModelConnectionTestResult) -> String {
        let durationDescription = String(format: "%.0fms", result.durationSeconds * 1000)

        guard result.isSuccess else {
            return "❌ \(result.role.emoji) \(result.role.shortName)：\(result.errorText ?? "失败")"
        }

        if let httpStatusCode = result.httpStatusCode {
            return "✅ \(result.role.emoji) \(result.role.shortName) HTTP \(httpStatusCode) · \(durationDescription)"
        }
        return "✅ \(result.role.emoji) \(result.role.shortName) 已连接 · \(durationDescription)"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(DS.Colors.textTertiary)
    }

    /// Spells out what deleting a provider will cost, naming the roles it currently
    /// serves. Deleting never hands a role to another provider behind the user's
    /// back, so those roles simply stop working until one is chosen.
    private func deletionConsequenceDescription(for provider: ProviderProfile) -> String {
        let affectedRoles = modelSettingsViewModel.draftConfiguration.rolesServed(by: provider.id)

        guard !affectedRoles.isEmpty else {
            return "「\(provider.displayName)」没有被任何角色使用，删除后不受影响。"
        }

        let affectedRoleNames = affectedRoles
            .map { "\($0.emoji) \($0.shortName)" }
            .joined(separator: "、")
        return "「\(provider.displayName)」正在承担 \(affectedRoleNames)。删除后这些角色将没有可用的服务商，需要重新指定一个。"
    }
}

// MARK: - Field styling

private extension View {
    /// The panel's text field look, shared by every field in this window so the
    /// form reads as one surface.
    func settingsTextFieldStyle(isFocused: Bool) -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(isFocused ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: isFocused ? 1 : 0.5)
            )
            // The default arrow cursor over a text field reads as "not editable".
            // `IBeamCursorView` registers an I-beam cursor rect and passes clicks
            // through, so the field still takes focus and selection normally.
            .overlay(IBeamCursorView())
            .animation(.easeOut(duration: DS.Animation.fast), value: isFocused)
    }
}
