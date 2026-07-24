import SwiftUI
import Arcane

struct EventsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var store = EventsStore()
    @State private var isLive = true
    @State private var pendingDeleteEvent: Event?

    var body: some View {
        @Bindable var store = store

        Group {
            if store.isLoading && store.events.isEmpty {
                ProgressView("Loading events…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = store.errorMessage, store.events.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load Events",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                List {
                    if store.supportsSeverityCounts, let counts = store.severityCounts {
                        Section {
                            EventSeveritySummary(
                                counts: counts,
                                selectedSeverities: store.selectedSeverities,
                                onSelectAll: store.clearSeverities,
                                onToggle: store.toggle
                            )
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                            .listRowBackground(Color.clear)
                        }
                    }

                    if store.events.isEmpty {
                        ContentUnavailableView {
                            Label(
                                store.selectedSeverities.isEmpty && store.searchText.isEmpty
                                    ? "No Events"
                                    : "No Matching Events",
                                systemImage: "clock.badge.exclamationmark"
                            )
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        Section {
                            ForEach(store.events) { event in
                                NavigationLink {
                                    EventDetailView(event: event)
                                } label: {
                                    EventRow(event: event)
                                }
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = event.title
                                        showToast(.copied("Title copied"))
                                    } label: {
                                        Label("Copy Title", systemImage: "doc.on.doc")
                                    }

                                    if let description = event.description, !description.isEmpty {
                                        Button {
                                            UIPasteboard.general.string = description
                                            showToast(.copied("Description copied"))
                                        } label: {
                                            Label("Copy Description", systemImage: "doc.on.doc.fill")
                                        }
                                    }

                                    if canDeleteEvents {
                                        Divider()
                                        Button(role: .destructive) {
                                            pendingDeleteEvent = event
                                        } label: {
                                            Label("Delete Event", systemImage: "trash")
                                        }
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button {
                                        UIPasteboard.general.string = event.title
                                        showToast(.copied("Title copied"))
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if canDeleteEvents {
                                        Button(role: .destructive) {
                                            pendingDeleteEvent = event
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .disabled(store.deletingEventIDs.contains(event.id))
                                    }
                                }
                            }
                        }
                    }

                    if let errorMessage = store.errorMessage, !store.events.isEmpty {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

                    if store.hasMore {
                        Button {
                            Task { await store.loadMore() }
                        } label: {
                            HStack {
                                Spacer()
                                if store.isLoadingMore {
                                    ProgressView()
                                } else {
                                    Label("Show More", systemImage: "arrow.down.circle")
                                        .font(.subheadline.weight(.semibold))
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .disabled(store.isLoadingMore)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Events")
        .searchable(
            text: $store.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search events"
        )
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isLive.toggle()
                } label: {
                    Image(systemName: isLive ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .accessibilityLabel(isLive ? "Pause live events" : "Resume live events")
            }
        }
        .deleteConfirmation(
            item: $pendingDeleteEvent,
            title: { _ in "Delete Event" },
            message: { event in "Delete “\(event.title)” from the event history?" },
            icon: "trash",
            confirmTitle: "Delete"
        ) { event in
            Task { await deleteEvent(event) }
        }
        .task(id: queryTaskKey) {
            store.configure(client: manager.client)
            do {
                try await Task.sleep(for: .milliseconds(350))
                await store.reload(clearExisting: true)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
        .task(id: clientIdentity) {
            store.configure(client: manager.client)
            await store.loadSeverityCounts()
        }
        .task(id: liveTaskKey) { await liveLoop() }
        .refreshable {
            await store.reload()
            await store.loadSeverityCounts()
        }
    }

    private var clientIdentity: ObjectIdentifier? {
        manager.client.map { ObjectIdentifier($0.transport) }
    }

    private var queryTaskKey: String {
        "\(clientIdentity?.hashValue ?? 0)|\(store.queryKey)"
    }

    private var liveTaskKey: String {
        "\(queryTaskKey)|\(isLive)|\(scenePhase == .active)"
    }

    private func liveLoop() async {
        guard isLive, scenePhase == .active else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard !Task.isCancelled, isLive, scenePhase == .active else { return }
            await store.poll()
            await store.loadSeverityCounts()
        }
    }

    private var canDeleteEvents: Bool {
        manager.permissions.has(Permission.Events.delete, in: nil)
    }

    private func deleteEvent(_ event: Event) async {
        do {
            try await store.delete(event)
            showToast(.success("Event deleted"))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}

private struct EventSeveritySummary: View {
    let counts: EventSeverityCounts
    let selectedSeverities: Set<EventSeverityFilter>
    let onSelectAll: () -> Void
    let onToggle: (EventSeverityFilter) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                EventSeverityChip(
                    title: "Total",
                    count: counts.total,
                    icon: "tray.full.fill",
                    tint: .primary,
                    isSelected: selectedSeverities.isEmpty,
                    action: onSelectAll
                )

                ForEach(EventSeverityFilter.allCases) { severity in
                    EventSeverityChip(
                        title: severity.title,
                        count: count(for: severity),
                        icon: severity.icon,
                        tint: tint(for: severity),
                        isSelected: selectedSeverities.contains(severity),
                        action: { onToggle(severity) }
                    )
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Event severity filters")
    }

    private func count(for severity: EventSeverityFilter) -> Int64 {
        switch severity {
        case .info: counts.info
        case .success: counts.success
        case .warning: counts.warning
        case .error: counts.error
        }
    }

    private func tint(for severity: EventSeverityFilter) -> Color {
        switch severity {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct EventSeverityChip: View {
    let title: String
    let count: Int64
    let icon: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    Text(count, format: .number)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isSelected ? tint.opacity(0.15) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: Radius.standard, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.standard, style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.45) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count.formatted()) events")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
