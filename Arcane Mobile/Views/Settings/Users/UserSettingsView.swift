import SwiftUI
import Arcane

struct UserSettingsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    @State private var enableGravatar = false
    @State private var originalEnableGravatar = false
    @State private var avatarMaxUploadSizeMb = "2"
    @State private var originalAvatarMaxUploadSizeMb = "2"
    @State private var supportsAvatarUploadLimit = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var hasChanges: Bool {
        enableGravatar != originalEnableGravatar
            || (supportsAvatarUploadLimit && avatarMaxUploadSizeMb != originalAvatarMaxUploadSizeMb)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Gravatar", isOn: $enableGravatar)

                if supportsAvatarUploadLimit {
                    FormNumberField(
                        title: "Maximum Upload Size",
                        placeholder: "2",
                        text: $avatarMaxUploadSizeMb,
                        minValue: 1,
                        maxValue: 50,
                        helper: "Megabytes (1–50)"
                    )
                }
            } header: {
                Label("User Avatars", systemImage: "person.crop.circle")
            } footer: {
                Text("Gravatar supplies a profile picture when a user has no uploaded avatar. These settings are stored on the Arcane manager.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("User Settings")
        .navigationBarTitleDisplayMode(.inline)
        .settingsSaveBar(
            hasChanges: hasChanges,
            isSaving: isSaving,
            isInteractionDisabled: isLoading,
            onSave: { Task { await saveSettings() } },
            onRevert: revertChanges
        )
        .task {
            await loadSettings()
        }
        .refreshable {
            await loadSettings()
        }
        .overlay {
            if isLoading {
                ProgressView("Loading…")
            }
        }
    }

    private func loadSettings() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let settings = try await client.settings.getSettings(envID: .localDocker)
            let values = Dictionary(
                settings.map { ($0.key, $0.value) },
                uniquingKeysWith: { _, newValue in newValue }
            )
            guard !Task.isCancelled else { return }

            let gravatarEnabled = values["enableGravatar"]?.lowercased() == "true"
            enableGravatar = gravatarEnabled
            originalEnableGravatar = gravatarEnabled

            if let uploadLimit = values["avatarMaxUploadSizeMb"] {
                avatarMaxUploadSizeMb = uploadLimit
                originalAvatarMaxUploadSizeMb = uploadLimit
                supportsAvatarUploadLimit = true
            } else {
                avatarMaxUploadSizeMb = "2"
                originalAvatarMaxUploadSizeMb = "2"
                supportsAvatarUploadLimit = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func revertChanges() {
        enableGravatar = originalEnableGravatar
        avatarMaxUploadSizeMb = originalAvatarMaxUploadSizeMb
        errorMessage = nil
    }

    private func saveSettings() async {
        guard let client = manager.client else { return }

        if supportsAvatarUploadLimit {
            let trimmedLimit = avatarMaxUploadSizeMb.trimmingCharacters(in: .whitespaces)
            guard let uploadLimit = Int(trimmedLimit), (1...50).contains(uploadLimit) else {
                errorMessage = "Maximum Upload Size must be between 1 and 50 MB."
                return
            }
            avatarMaxUploadSizeMb = String(uploadLimit)
        }

        var changedSettings: [String: String] = [:]
        if enableGravatar != originalEnableGravatar {
            changedSettings["enableGravatar"] = String(enableGravatar)
        }
        if supportsAvatarUploadLimit,
           avatarMaxUploadSizeMb != originalAvatarMaxUploadSizeMb {
            changedSettings["avatarMaxUploadSizeMb"] = avatarMaxUploadSizeMb
        }
        guard !changedSettings.isEmpty else { return }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let path = client.rest.environmentPath(.localDocker, "settings")
            let _: [PublicSetting] = try await client.rest.put(path, body: changedSettings)
            guard !Task.isCancelled else { return }

            let gravatarChanged = changedSettings["enableGravatar"] != nil
            originalEnableGravatar = enableGravatar
            originalAvatarMaxUploadSizeMb = avatarMaxUploadSizeMb
            showToast(.success("User settings saved"))

            if gravatarChanged {
                await manager.refreshCurrentUserAvatar(force: true)
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
