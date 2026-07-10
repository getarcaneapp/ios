import SwiftUI
import Arcane

struct ImageUpdatesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ImageUpdateCountStore.self) private var imageUpdateCountStore
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let images: [ImageSummary]

    @State private var summary: ImageUpdateSummary?
    @State private var byRef: [String: ImageUpdateResponse] = [:]
    @State private var isScanning = false
    @State private var checkingRef: String?
    @State private var errorMessage: String?
    @State private var loadingSummary = false
    @State private var loadingRefs = false

    private var taggedRefs: [String] {
        images.flatMap { $0.repoTags }
            .filter { $0 != "<none>:<none>" }
    }

    private var rowsWithUpdates: Int {
        byRef.values.filter { $0.hasUpdate }.count
    }

    var body: some View {
        List {
            Section {
                ImageUpdateSummaryStrip(summary: summary, isLoading: loadingSummary)
            } header: {
                Text("Summary")
            }

            Section {
                Button {
                    Task { await scanAll() }
                } label: {
                    HStack {
                        Label("Scan all images", systemImage: "magnifyingglass")
                        Spacer()
                        if isScanning { ProgressView().scaleEffect(0.8) }
                    }
                }
                .disabled(isScanning)
            } footer: {
                Text("Contacts each image's registry. Can take a while for large environments.")
            }

            if !taggedRefs.isEmpty {
                Section("Images") {
                    ForEach(taggedRefs, id: \.self) { ref in
                        UpdateRow(
                            ref: ref,
                            info: byRef[ref],
                            isChecking: checkingRef == ref,
                            recheck: { Task { await recheck(ref: ref) } }
                        )
                    }
                }
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSummary()
            await loadByRefs()
        }
        .refreshable {
            await loadSummary()
            await loadByRefs()
        }
    }

    private func loadSummary() async {
        guard let client = manager.client else { return }
        loadingSummary = true
        defer { loadingSummary = false }
        do {
            summary = try await client.images.updateSummary(envID: environmentID)
            if let summary {
                imageUpdateCountStore.setCount(
                    summary.imagesWithUpdates,
                    environmentID: environmentID,
                    client: manager.client,
                    userID: manager.currentUser?.id
                )
            }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadByRefs() async {
        guard let client = manager.client, !taggedRefs.isEmpty else { return }
        loadingRefs = true
        defer { loadingRefs = false }
        do {
            let map = try await client.images.updateInfoByRefs(envID: environmentID, imageRefs: taggedRefs)
            byRef = map.compactMapValues { $0?.asUpdateResponse }
        } catch {
            // by-refs is a cache-read; failure isn't fatal
        }
    }

    private func recheck(ref: String) async {
        guard let client = manager.client else { return }
        checkingRef = ref
        defer { checkingRef = nil }
        do {
            byRef[ref] = try await client.images.checkUpdateByRef(envID: environmentID, imageRef: ref)
            await loadSummary()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func scanAll() async {
        guard let client = manager.client else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            _ = try await client.images.checkAllUpdates(envID: environmentID)
            await loadSummary()
            await loadByRefs()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct ImageUpdateSummaryStrip: View {
    let summary: ImageUpdateSummary?
    let isLoading: Bool

    var body: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    metric("Total", value: "\(summary.totalImages)", color: .secondary)
                    Spacer()
                    metric(
                        "With updates",
                        value: "\(summary.imagesWithUpdates)",
                        color: summary.imagesWithUpdates > 0 ? .orange : .secondary
                    )
                    Spacer()
                    metric("Digest", value: "\(summary.digestUpdates)", color: Color.accentColor)
                    Spacer()
                    metric(
                        "Errors",
                        value: "\(summary.errorsCount)",
                        color: summary.errorsCount > 0 ? .red : .secondary
                    )
                }
            }
            .padding(.vertical, 4)
        } else if isLoading {
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Loading summary…").foregroundStyle(.secondary)
            }
        } else {
            Text("No summary available").foregroundStyle(.secondary)
        }
    }

    private func metric(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct UpdateRow: View {
    let ref: String
    let info: ImageUpdateResponse?
    let isChecking: Bool
    let recheck: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ref)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                if let info {
                    if let err = info.error, !err.isEmpty {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else if info.hasUpdate {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(.orange)
                            Text(versionLine(info))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Up to date")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } else {
                    Text("Not yet checked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isChecking {
                ProgressView().scaleEffect(0.8)
            } else {
                Button(action: recheck) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func versionLine(_ info: ImageUpdateResponse) -> String {
        if let latest = info.latestVersion, !latest.isEmpty,
           !info.currentVersion.isEmpty, latest != info.currentVersion {
            return "\(info.currentVersion) → \(latest)"
        }
        if !info.updateType.isEmpty {
            return "Update available (\(info.updateType))"
        }
        return "Update available"
    }
}
