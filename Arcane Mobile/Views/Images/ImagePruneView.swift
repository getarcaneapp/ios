import SwiftUI
import Arcane

struct ImagePruneView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let onComplete: () async -> Void

    @State private var mode: Mode = .dangling
    @State private var until: String = "24h"
    @State private var isPruning = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    enum Mode: String, CaseIterable, Identifiable {
        case dangling = "Dangling Only"
        case all = "All Unused"
        case olderThan = "Older Than..."
        var id: String { rawValue }

        var apiValue: String {
            switch self {
            case .dangling: return "dangling"
            case .all: return "all"
            case .olderThan: return "olderThan"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Prune Mode")
                } footer: {
                    Text(modeDescription)
                }

                if mode == .olderThan {
                    Section {
                        HStack {
                            Text("Older than").foregroundStyle(.secondary)
                            Spacer()
                            TextField("e.g. 24h, 7d", text: $until)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .frame(width: 120)
                        }
                    }
                }
            }
            .navigationTitle("Prune Images")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPruning {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button(role: .destructive) {
                            Task { await runPrune() }
                        } label: {
                            Label("Prune", systemImage: "trash")
                        }
                    }
                }
            }
            .alert("Prune complete", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil; dismiss() } })) {
                Button("OK") { resultMessage = nil; dismiss() }
            } message: {
                Text(resultMessage ?? "")
            }
            .alert("Prune failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var modeDescription: String {
        switch mode {
        case .dangling: return "Removes only untagged images with no children."
        case .all: return "Removes every image not used by a container."
        case .olderThan: return "Removes unused images older than the given age (e.g. 24h, 7d)."
        }
    }

    private func runPrune() async {
        guard let client = manager.client else { return }
        isPruning = true
        defer { isPruning = false }
        let body = ImagePruneRequest(
            mode: mode.apiValue,
            until: mode == .olderThan ? until : nil,
            dangling: nil,
            filters: nil
        )
        do {
            let path = client.rest.environmentPath(environmentID, "images/prune")
            let report: ImagePruneReport = try await client.rest.post(path, body: body)
            if let cached = manager.cached {
                await cached.invalidate(envID: environmentID, paths: [
                    client.rest.environmentPath(environmentID, "images") + "*",
                    client.rest.environmentPath(environmentID, "images/*")
                ])
            }
            mutationStore.markChanged(kind: .images, envID: environmentID)
            resultMessage = formatResult(report)
            await onComplete()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func formatResult(_ report: ImagePruneReport) -> String {
        let count = report.imagesDeleted?.count ?? 0
        var msg = count == 0 ? "Nothing to remove." : "Removed \(count) image\(count == 1 ? "" : "s")."
        if let space = report.spaceReclaimed, space > 0 {
            msg += " Freed \(space.byteString)."
        }
        return msg
    }
}
