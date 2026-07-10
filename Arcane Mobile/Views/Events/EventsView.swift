import SwiftUI
import Arcane

struct EventsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let pageSize = 50

    @State private var events: [Event] = []
    @State private var limit: Int = EventsView.pageSize
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var severityFilter: EventSeverity = .all
    @State private var isLive = true

    private var filtered: [Event] {
        let bySeverity: [Event]
        if severityFilter == .all {
            bySeverity = events
        } else {
            bySeverity = events.filter { $0.severity.lowercased() == severityFilter.rawValue }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return bySeverity }
        return bySeverity.filter { event in
            event.title.localizedCaseInsensitiveContains(trimmed) ||
            (event.description ?? "").localizedCaseInsensitiveContains(trimmed) ||
            (event.resourceName ?? "").localizedCaseInsensitiveContains(trimmed) ||
            event.type.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        Group {
            if isLoading && events.isEmpty {
                ProgressView("Loading events…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, events.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load Events",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if events.isEmpty {
                ContentUnavailableView("No Events", systemImage: "clock.badge.exclamationmark")
            } else {
                List {
                    ForEach(filtered) { event in
                        NavigationLink {
                            EventDetailView(event: event)
                        } label: {
                            EventRow(event: event)
                        }
                    }
                    if hasMore, searchText.isEmpty, severityFilter == .all {
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
        .navigationTitle("Events")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search events")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Severity", selection: $severityFilter) {
                        ForEach(EventSeverity.allCases) { severity in
                            Label(severity.title, systemImage: severity.icon).tag(severity)
                        }
                    }
                } label: {
                    Image(
                        systemName: severityFilter == .all
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                }
                .accessibilityLabel("Filter")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isLive.toggle()
                } label: {
                    Image(systemName: isLive ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(isLive ? "Pause live events" : "Resume live events")
            }
        }
        .task { await load() }
        .task(id: liveTaskKey) { await liveLoop() }
        .refreshable { await load(refresh: true) }
    }

    private var liveTaskKey: String {
        "\(isLive)-\(scenePhase == .active)"
    }

    private func load(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        if events.isEmpty || refresh { isLoading = true }
        if refresh {
            limit = Self.pageSize
            errorMessage = nil
        }
        defer { isLoading = false }
        do {
            let response = try await client.events.listPaginated(start: 0, limit: limit)
            events = EventHistory.merged(current: [], incoming: response.data, limit: limit)
            hasMore = response.data.count >= limit
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
            let response = try await client.events.listPaginated(start: 0, limit: newLimit)
            events = EventHistory.merged(current: [], incoming: response.data, limit: newLimit)
            limit = newLimit
            hasMore = response.data.count >= newLimit
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func liveLoop() async {
        guard isLive, scenePhase == .active else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, isLive, scenePhase == .active, !isLoading, !isLoadingMore else { continue }
            await pollForNewEvents()
        }
    }

    private func pollForNewEvents() async {
        guard let client = manager.client else { return }
        do {
            let response = try await client.events.listPaginated(start: 0, limit: Self.pageSize)
            guard !Task.isCancelled, !isLoading, !isLoadingMore else { return }
            let merged = EventHistory.merged(current: events, incoming: response.data, limit: limit)
            guard merged != events else { return }
            withAnimation(Motion.reduced(Motion.reflow, reduceMotion: reduceMotion)) {
                events = merged
            }
            errorMessage = nil
        } catch {
            if events.isEmpty {
                errorMessage = friendlyErrorMessage(error)
            }
        }
    }
}

private enum EventSeverity: String, CaseIterable, Identifiable, Hashable {
    case all
    case info
    case warning
    case error
    case critical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        case .critical: return "Critical"
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .critical: return "flame"
        }
    }
}

private struct EventRow: View {
    let event: Event

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: severityIcon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(severityTint)
                .frame(width: 32, height: 32)
                .background(severityTint.opacity(0.15), in: .circle)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let description = event.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(event.timestamp, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if !event.type.isEmpty {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(event.type)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var severityIcon: String {
        switch event.severity.lowercased() {
        case "critical", "fatal": return "flame.fill"
        case "error": return "xmark.octagon.fill"
        case "warning", "warn": return "exclamationmark.triangle.fill"
        case "success": return "checkmark.circle.fill"
        case "debug": return "ladybug.fill"
        default: return "info.circle.fill"
        }
    }

    private var severityTint: Color {
        switch event.severity.lowercased() {
        case "critical", "fatal": return .pink
        case "error": return .red
        case "warning", "warn": return .orange
        case "success": return .green
        case "debug": return .gray
        default: return .blue
        }
    }
}

private struct EventDetailView: View {
    let event: Event

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: severityIcon)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(severityTint)
                        .frame(width: 44, height: 44)
                        .background(severityTint.opacity(0.15), in: .circle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title)
                            .font(.headline)
                        Text(event.severity.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(severityTint)
                    }
                }
                .padding(.vertical, 4)
                if let description = event.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
            }

            Section("Event") {
                LabeledContent("Type", value: event.type)
                LabeledContent("Occurred", value: event.timestamp.formatted(date: .abbreviated, time: .standard))
                if event.createdAt != event.timestamp {
                    LabeledContent("Recorded", value: event.createdAt.formatted(date: .abbreviated, time: .standard))
                }
            }

            if event.resourceType != nil || event.resourceName != nil || event.resourceId != nil {
                Section("Resource") {
                    if let type = event.resourceType, !type.isEmpty {
                        LabeledContent("Type", value: type.capitalized)
                    }
                    if let name = event.resourceName, !name.isEmpty {
                        LabeledContent("Name", value: name)
                    }
                    if let id = event.resourceId, !id.isEmpty {
                        LabeledContent("ID", value: id)
                            .font(.caption.monospaced())
                    }
                }
            }

            if event.username != nil || event.userId != nil || event.environmentId != nil {
                Section("Context") {
                    if let username = event.username, !username.isEmpty {
                        LabeledContent("User", value: username)
                    }
                    if let userId = event.userId, !userId.isEmpty {
                        LabeledContent("User ID", value: userId)
                            .font(.caption.monospaced())
                    }
                    if let envId = event.environmentId, !envId.isEmpty {
                        LabeledContent("Environment", value: envId)
                            .font(.caption.monospaced())
                    }
                }
            }

            let metadata = event.metadataMap
            if !metadata.isEmpty {
                Section("Metadata") {
                    ForEach(metadata.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: metadata[key] ?? "")
                    }
                }
            }
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var severityIcon: String {
        switch event.severity.lowercased() {
        case "critical", "fatal": return "flame.fill"
        case "error": return "xmark.octagon.fill"
        case "warning", "warn": return "exclamationmark.triangle.fill"
        case "success": return "checkmark.circle.fill"
        case "debug": return "ladybug.fill"
        default: return "info.circle.fill"
        }
    }

    private var severityTint: Color {
        switch event.severity.lowercased() {
        case "critical", "fatal": return .pink
        case "error": return .red
        case "warning", "warn": return .orange
        case "success": return .green
        case "debug": return .gray
        default: return .blue
        }
    }
}
