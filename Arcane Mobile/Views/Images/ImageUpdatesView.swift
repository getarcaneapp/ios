import SwiftUI
import Arcane

struct ImageUpdatesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let environmentID: EnvironmentID
    let images: [ImageInfo]

    @State private var summary: ImageUpdateSummary?
    @State private var byRef: [String: ImageUpdateResponse] = [:]
    @State private var isScanning = false
    @State private var checkingRef: String?
    @State private var errorMessage: String?
    @State private var loadingSummary = false
    @State private var loadingRefs = false

    private var taggedRefs: [String] {
        images.flatMap { $0.repoTags ?? [] }
            .filter { $0 != "<none>:<none>" }
    }

    private var rowsWithUpdates: Int {
        byRef.values.filter { $0.hasUpdate }.count
    }

    var body: some View {
        List {
            Section {
                summaryRow
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

    @ViewBuilder
    private var summaryRow: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    metric("Total", value: "\(summary.totalImages)", color: .secondary)
                    Spacer()
                    metric("With updates", value: "\(summary.imagesWithUpdates)", color: summary.imagesWithUpdates > 0 ? .orange : .secondary)
                    Spacer()
                    metric("Digest", value: "\(summary.digestUpdates)", color: .blue)
                    Spacer()
                    metric("Errors", value: "\(summary.errorsCount)", color: summary.errorsCount > 0 ? .red : .secondary)
                }
            }
            .padding(.vertical, 4)
        } else if loadingSummary {
            HStack { ProgressView().scaleEffect(0.8); Text("Loading summary…").foregroundStyle(.secondary) }
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

    private func loadSummary() async {
        guard let client = manager.client else { return }
        loadingSummary = true
        defer { loadingSummary = false }
        do {
            let path = client.rest.environmentPath(environmentID, "image-updates/summary")
            summary = try await client.rest.get(path)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadByRefs() async {
        guard let client = manager.client, !taggedRefs.isEmpty else { return }
        loadingRefs = true
        defer { loadingRefs = false }
        do {
            let path = client.rest.environmentPath(environmentID, "image-updates/by-refs")
            let query = [URLQueryItem(name: "imageRefs", value: taggedRefs.joined(separator: ","))]
            let map: BatchImageUpdateResponse = try await client.rest.get(path, query: query)
            byRef = map
        } catch {
            // by-refs is a cache-read; failure isn't fatal
        }
    }

    private func recheck(ref: String) async {
        guard let client = manager.client else { return }
        checkingRef = ref
        defer { checkingRef = nil }
        do {
            let path = client.rest.environmentPath(environmentID, "image-updates/check")
            let query = [URLQueryItem(name: "imageRef", value: ref)]
            let response: ImageUpdateResponse = try await client.rest.get(path, query: query)
            byRef[ref] = response
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func scanAll() async {
        guard let client = manager.client else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let path = client.rest.environmentPath(environmentID, "image-updates/check-all")
            let body: [String: String] = [:]
            let _: BatchImageUpdateResponse = try await client.rest.post(path, body: body)
            await loadSummary()
            await loadByRefs()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

private struct UpdateRow: View {
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
        if let latest = info.latestVersion, let current = info.currentVersion, !latest.isEmpty, !current.isEmpty, latest != current {
            return "\(current) → \(latest)"
        }
        if let type = info.updateType, !type.isEmpty {
            return "Update available (\(type))"
        }
        return "Update available"
    }
}
