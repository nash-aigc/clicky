//
//  ModelSettingsViewModel.swift
//  leanring-buddy
//
//  State for the model settings window: a draft configuration the user edits, and
//  the actions that save it or test it.
//
//  The window edits a *draft* rather than the live configuration. Nothing the user
//  types changes what the app is doing until they press 保存, so an abandoned edit
//  can't leave the app half-switched to a provider that was never finished.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class ModelSettingsViewModel: ObservableObject {

    /// The configuration being edited. Bound directly by every field in the window.
    @Published var draftConfiguration: ModelConfiguration {
        didSet {
            guard draftConfiguration != oldValue else { return }
            // A test result only describes the exact settings it was measured
            // against. Leaving a green tick next to a field the user has since
            // edited would say "this works" about a configuration nobody tested.
            connectionTestResults.removeAll()
            saveErrorMessage = nil
        }
    }

    /// Latest result per role, empty until 测试连接 is pressed.
    @Published private(set) var connectionTestResults: [ModelRole: ModelConnectionTestResult] = [:]
    @Published private(set) var isTestingConnections = false
    @Published private(set) var saveErrorMessage: String?
    @Published private(set) var lastSavedAt: Date?

    /// The configuration as last written to disk. Everything that differs from it
    /// is unsaved work, which is what `isDirty` reports.
    private var savedConfiguration: ModelConfiguration

    init() {
        let currentConfiguration = ModelConfigurationStore.snapshot()
        self.savedConfiguration = currentConfiguration
        self.draftConfiguration = currentConfiguration
    }

    // MARK: - Dirty state

    var isDirty: Bool {
        draftConfiguration != savedConfiguration
    }

    /// Re-reads the saved configuration when the window is reopened.
    ///
    /// The window controller is created once and reused, so without this the window
    /// would come back showing whatever was in the draft when it was last closed.
    /// A draft with unsaved edits is left alone — someone who closed the window
    /// without meaning to should not lose their typing.
    func reloadDraftFromStoreIfUnchanged() {
        guard !isDirty else { return }
        let currentConfiguration = ModelConfigurationStore.snapshot()
        savedConfiguration = currentConfiguration
        draftConfiguration = currentConfiguration
        connectionTestResults.removeAll()
        saveErrorMessage = nil
        lastSavedAt = nil
    }

    // MARK: - Role assignment

    /// Providers that can serve `role`, in the order they appear in the window.
    ///
    /// Only providers whose flavour actually offers the role: DeepSeek has no
    /// speech recognition or synthesis, so offering it for 👂 or 👄 would let the
    /// user pick something that can never work.
    func assignableProviders(for role: ModelRole) -> [ProviderProfile] {
        draftConfiguration.providers.filter { $0.supports(role) }
    }

    func assignProvider(_ providerID: UUID?, to role: ModelRole) {
        draftConfiguration.setProviderID(providerID, for: role)
    }

    func status(of role: ModelRole) -> RoleConfigurationStatus {
        draftConfiguration.status(of: role)
    }

    // MARK: - Provider editing

    func addProvider(flavor: APIProviderFlavor) {
        var newProvider = ProviderProfile(
            id: UUID(),
            displayName: flavor.displayName,
            baseURL: flavor.defaultBaseURL,
            apiKey: "",
            flavor: flavor,
            customProtocol: flavor == .custom ? .bailian : nil
        )

        // Pre-fill the model names this app is known to work with, so a newly added
        // provider needs only a URL and a key to become usable. Every one of these
        // stays editable.
        for role in ModelRole.allCases {
            newProvider.setModelID(flavor.presetModelIDs(for: role).first, for: role)
        }
        // The Bailian protocol's TTS voices are model-family specific and the
        // service requires one, so a voice is filled in rather than left blank.
        if flavor.effectiveFlavorForNewProvider == .bailian {
            newProvider.speechVoiceID = BailianConfiguration.textToSpeechVoice
        }

        draftConfiguration.providers.append(newProvider)
    }

    /// A binding to one provider card's fields.
    ///
    /// Resolved by provider id inside the accessors rather than captured as an array
    /// index, so removing a card can never leave another card's fields bound to the
    /// wrong row.
    func providerBinding(for providerID: UUID) -> Binding<ProviderProfile> {
        Binding(
            get: { [weak self] in
                guard let self,
                      let provider = self.draftConfiguration.providers.first(where: { $0.id == providerID })
                else {
                    // Unreachable while the card is on screen: the card is only
                    // rendered for a provider that exists. Returned rather than
                    // force-unwrapped so a deallocated view model can't crash the app.
                    return ProviderProfile(
                        id: providerID,
                        displayName: "",
                        baseURL: "",
                        apiKey: "",
                        flavor: .bailian,
                        customProtocol: nil
                    )
                }
                return provider
            },
            set: { [weak self] editedProvider in
                guard let self,
                      let index = self.draftConfiguration.providers.firstIndex(where: { $0.id == providerID })
                else { return }
                self.draftConfiguration.providers[index] = editedProvider
            }
        )
    }

    /// A binding to one provider's model name for one role.
    ///
    /// `TextField` needs a non-optional `String`, while the stored value is optional
    /// so that "no model chosen" is distinguishable from "a model named empty
    /// string". This converts between the two, treating a blank field as unset.
    func modelIDBinding(for providerID: UUID, role: ModelRole) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self,
                      let provider = self.draftConfiguration.providers.first(where: { $0.id == providerID })
                else { return "" }
                // `modelID(for:)` trims, so a trailing space typed into the field is
                // dropped on the next render. Harmless for a model name, and it means
                // the value that gets used is never padded with invisible whitespace.
                return provider.modelID(for: role) ?? ""
            },
            set: { [weak self] newModelID in
                guard let self,
                      let index = self.draftConfiguration.providers.firstIndex(where: { $0.id == providerID })
                else { return }

                let trimmedModelID = newModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                self.draftConfiguration.providers[index].setModelID(
                    trimmedModelID.isEmpty ? nil : newModelID,
                    for: role
                )
            }
        )
    }

    func speechVoiceIDBinding(for providerID: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in
                guard let self,
                      let provider = self.draftConfiguration.providers.first(where: { $0.id == providerID })
                else { return "" }
                return provider.speechVoiceID ?? ""
            },
            set: { [weak self] newVoiceID in
                guard let self,
                      let index = self.draftConfiguration.providers.firstIndex(where: { $0.id == providerID })
                else { return }

                let trimmedVoiceID = newVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
                self.draftConfiguration.providers[index].speechVoiceID = trimmedVoiceID.isEmpty ? nil : newVoiceID
            }
        )
    }

    /// The 「让模型先推理」 switch on a provider card.
    ///
    /// Writes an explicit `true` or `false` rather than leaving the stored value
    /// `nil`: once the user has touched the switch, the file should record the
    /// choice they made instead of continuing to mean "never set". The two happen
    /// to read the same today, but they stop agreeing the moment the default
    /// changes, and a stored `nil` would silently follow the new default.
    func visionReasoningBinding(for providerID: UUID) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                guard let self,
                      let provider = self.draftConfiguration.providers.first(where: { $0.id == providerID })
                else { return false }
                return provider.allowsVisionReasoning
            },
            set: { [weak self] allowsVisionReasoning in
                guard let self,
                      let index = self.draftConfiguration.providers.firstIndex(where: { $0.id == providerID })
                else { return }
                self.draftConfiguration.providers[index].visionReasoningEnabled = allowsVisionReasoning
            }
        )
    }

    func providerName(for providerID: UUID?) -> String? {
        draftConfiguration.provider(withID: providerID)?.displayName
    }

    /// The names of the roles a provider is currently responsible for, for the
    /// "承担：👂 👄" read-back on its card.
    func roleEmojiServed(by providerID: UUID) -> [String] {
        draftConfiguration.rolesServed(by: providerID).map(\.emoji)
    }

    /// Removes a provider and unassigns it from every role it served.
    ///
    /// The roles are left unassigned rather than handed to another provider: doing
    /// the latter would silently start sending the user's screenshots to a company
    /// they did not choose. The window warns about exactly which roles will stop
    /// working before calling this.
    func removeProvider(withID providerID: UUID) {
        draftConfiguration.providers.removeAll { $0.id == providerID }
        for role in ModelRole.allCases where draftConfiguration.providerID(for: role) == providerID {
            draftConfiguration.setProviderID(nil, for: role)
        }
    }

    // MARK: - Actions

    func testConnections() async {
        isTestingConnections = true
        connectionTestResults = [:]

        let draftConfiguration = self.draftConfiguration
        let results = await ModelConnectionTester.testAllRoles(in: draftConfiguration)

        // Discard results that describe a configuration the user has since edited
        // again, so a slow test can't paint a stale verdict onto changed fields.
        guard draftConfiguration == self.draftConfiguration else {
            isTestingConnections = false
            return
        }

        connectionTestResults = Dictionary(
            uniqueKeysWithValues: results.map { ($0.role, $0) }
        )
        isTestingConnections = false
    }

    func save() {
        // A hand-typed URL with a space in it is a mistake worth catching while the
        // user is still looking at the field, rather than on the next question.
        if let firstMalformedURLRole = ModelRole.allCases.first(where: {
            if case .invalidURL = draftConfiguration.status(of: $0) { return true }
            return false
        }) {
            saveErrorMessage = "\(firstMalformedURLRole.emoji) 的 URL 填得不对，请检查有没有空格或多余字符。"
            return
        }

        do {
            try ModelConfigurationStore.save(draftConfiguration)
            savedConfiguration = draftConfiguration
            saveErrorMessage = nil
            lastSavedAt = Date()
            // The store posts `.clickyModelConfigurationChanged`, which the panel
            // listens for, so the new models show up there without this window
            // having to know anything about it.
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}

private extension APIProviderFlavor {
    /// The protocol a provider of this flavour will actually speak.
    ///
    /// `addProvider` works on a flavour the user just picked, which for 自定义 has
    /// no protocol chosen yet; that defaults to Bailian, matching
    /// `ProviderProfile.effectiveFlavor` once the provider exists.
    var effectiveFlavorForNewProvider: APIProviderFlavor {
        self == .custom ? .bailian : self
    }
}
