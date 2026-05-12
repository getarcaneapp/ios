import SwiftUI
import Arcane

struct UpdaterHistoryView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID

    private static let pageSize = 50

    @State private var records: [AutoUpdateRecord] = []
    @State private var limit: Int = UpdaterHistoryView.pageSize
    @State private var hasMore: Bool = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var filtered: [AutoUpdateRecord] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        return records.filter { record in
            record.resourceName.localizedCaseInsensitiveContains(trimmed) ||
            record.resourceType.localizedCaseInsensitiveContains(trimmed) ||
            record.status.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        Group {
            if isLoading && records.isEmpty {
                ProgressView("Loading updater history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, records.isEmpty {
                ContentUnavailableView("Couldn't Load History", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if records.isEmpty {
                ContentUnavailableView("No Update History", systemImage: "clock.arrow.circlepath")
            } else {
                List {
                    ForEach(filtered) { record in
                        NavigationLink {
                            UpdaterHistoryDetailView(record: record)
                        } label: {
                            UpdaterHistoryRow(record: record)
                        }
                    }
                    if hasMore, searchText.isEmpty {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            HStack {
                                Spacer()
                                if isLoadingMore {
                                    ProgressView()
                                } else {
                                    Label("Show More", systemImage: "arrow.down.circle")
                                        .font(.subheadline.weight(.semibold))
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .disabled(isLoadingMore)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Updater History")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search updater history")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await load(refresh: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
                .disabled(isLoading)
            }
        }
        .task { await load() }
        .refreshable { await load(refresh: true) }
    }

    private func load(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        if records.isEmpty { isLoading = true }
        if refresh {
            limit = Self.pageSize
            errorMessage = nil
        }
        defer { isLoading = false }
        do {
            let fetched = try await client.updater.history(envID: environmentID, limit: limit)
            records = fetched
            hasMore = fetched.count >= limit
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadMore() async {
        guard let client = manager.client, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let newLimit = limit + Self.pageSize
        do {
            let fetched = try await client.updater.history(envID: environmentID, limit: newLimit)
            records = fetched
            limit = newLimit
            hasMore = fetched.count >= newLimit
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

private struct UpdaterHistoryRow: View {
    let record: AutoUpdateRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: typeIcon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(typeTint)
                .frame(width: 32, height: 32)
                .background(typeTint.opacity(0.15), in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.resourceName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.resourceType.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(record.startTime, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let imageChange {
                    Text(imageChange)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            UpdaterStatusBadge(text: statusText, tint: statusTint)
        }
        .padding(.vertical, 4)
    }

    private var typeIcon: String {
        switch record.resourceType.lowercased() {
        case "container": return "shippingbox.fill"
        case "project", "stack": return "folder.fill"
        case "image": return "photo.stack.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var typeTint: Color {
        switch record.resourceType.lowercased() {
        case "container": return .blue
        case "project", "stack": return .purple
        case "image": return .pink
        default: return .gray
        }
    }

    private var statusText: String {
        if let error = record.error, !error.isEmpty { return "Failed" }
        if record.updateApplied { return "Updated" }
        if record.updateAvailable { return "Available" }
        return record.status.capitalized
    }

    private var statusTint: Color {
        if record.error?.isEmpty == false { return .red }
        if record.updateApplied { return .green }
        if record.updateAvailable { return .orange }
        switch record.status.lowercased() {
        case "skipped", "ignored": return .gray
        case "failed", "error": return .red
        case "updated", "success": return .green
        default: return .blue
        }
    }

    private var imageChange: String? {
        let oldVersions = record.oldImageVersionsMap
        let newVersions = record.newImageVersionsMap
        guard let key = newVersions.keys.first ?? oldVersions.keys.first else { return nil }
        let oldTag = oldVersions[key]
        let newTag = newVersions[key]
        switch (oldTag, newTag) {
        case let (.some(old), .some(new)) where old != new: return "\(old) → \(new)"
        case let (.some(old), _): return old
        case let (_, .some(new)): return new
        default: return nil
        }
    }
}

private struct UpdaterStatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: .capsule)
    }
}

private struct UpdaterHistoryDetailView: View {
    let record: AutoUpdateRecord

    var body: some View {
        List {
            Section {
                LabeledContent("Resource", value: record.resourceName)
                LabeledContent("Type", value: record.resourceType.capitalized)
                LabeledContent("Status") {
                    UpdaterStatusBadge(text: badgeText, tint: badgeTint)
                }
                LabeledContent("Update Applied", value: record.updateApplied ? "Yes" : "No")
                LabeledContent("Update Available", value: record.updateAvailable ? "Yes" : "No")
            }

            Section("Timing") {
                LabeledContent("Started", value: record.startTime.formatted(date: .abbreviated, time: .standard))
                if let end = record.endTime {
                    LabeledContent("Ended", value: end.formatted(date: .abbreviated, time: .standard))
                    let duration = end.timeIntervalSince(record.startTime)
                    if duration > 0 {
                        LabeledContent("Duration", value: formatDuration(duration))
                    }
                }
            }

            if let error = record.error, !error.isEmpty {
                Section("Error") {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            let oldVersions = record.oldImageVersionsMap
            let newVersions = record.newImageVersionsMap
            if !oldVersions.isEmpty || !newVersions.isEmpty {
                Section("Image Versions") {
                    let allKeys = Set(oldVersions.keys).union(newVersions.keys).sorted()
                    ForEach(allKeys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(oldVersions[key] ?? "—")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(newVersions[key] ?? "—")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Identifiers") {
                LabeledContent("Resource ID", value: record.resourceId)
                    .font(.caption.monospaced())
                LabeledContent("Record ID", value: record.id)
                    .font(.caption.monospaced())
            }
        }
        .navigationTitle(record.resourceName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var badgeText: String {
        if let error = record.error, !error.isEmpty { return "Failed" }
        if record.updateApplied { return "Updated" }
        if record.updateAvailable { return "Available" }
        return record.status.capitalized
    }

    private var badgeTint: Color {
        if record.error?.isEmpty == false { return .red }
        if record.updateApplied { return .green }
        if record.updateAvailable { return .orange }
        return .blue
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "\(Int(seconds))s"
    }
}
