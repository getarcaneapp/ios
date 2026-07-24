import SwiftUI
import Arcane

struct ActivitiesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    @State private var store = ActivityCenterStore()
    @State private var showClearConfirm = false
    @State private var expandedBatchIDs: Set<String> = []

    private var taskID: String {
        let transportID = manager.client.map { ObjectIdentifier($0.transport).hashValue } ?? 0
        return "\(manager.supportsActivities)-\(transportID)"
    }

    private var clearableEnvironmentIDs: Set<String> {
        guard let user = manager.currentUser else { return [] }
        return Set(store.environmentIDs.filter { user.hasPermission("activities:delete", environmentID: $0) })
    }

    private var canClearHistory: Bool {
        !clearableEnvironmentIDs.isEmpty
    }

    var body: some View {
        @Bindable var store = store

        Group {
            if !manager.supportsActivities {
                ContentUnavailableView(
                    "Requires Arcane v2",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Activity Center is available when connected to an Arcane 2.0 server.")
                )
            } else if store.isLoading && store.activities.isEmpty {
                ProgressView("Loading activities...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = store.errorMessage, store.activities.isEmpty {
                ContentUnavailableView(
                    "Couldn't Load Activities",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if store.activities.isEmpty {
                ContentUnavailableView(
                    "No Activities",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Background work from your environments will appear here.")
                )
            } else {
                List {
                    if let streamError = store.streamErrorMessage {
                        Section {
                            ErrorBanner(
                                message: streamError,
                                severity: .warning,
                                retry: {
                                    Task {
                                        await store.retryLiveUpdates()
                                    }
                                }
                            )
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }

                    if store.runningItems.isEmpty && store.historyItems.isEmpty {
                        ContentUnavailableView(
                            "No Matching Activities",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("Adjust the filters or search text.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        if !store.runningItems.isEmpty {
                            activitySection(title: "Running", items: store.runningItems)
                        }

                        if !store.historyItems.isEmpty {
                            activitySection(title: "History", items: store.historyItems)
                        }

                        if store.hasMore && store.searchText.isEmpty {
                            Section {
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
                                }
                                .disabled(store.isLoadingMore)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await store.retryLiveUpdates()
                }
            }
        }
        .navigationTitle("Activities")
        .navigationDestination(for: Activity.self) { activity in
            ActivityDetailView(activity: activity)
        }
        .searchable(
            text: $store.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search activities"
        )
        .toolbar {
            if manager.supportsActivities {
                ToolbarItem(placement: .navigationBarTrailing) {
                    filterMenu
                }
                if #available(iOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await store.retryLiveUpdates() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                    .disabled(store.isLoading)
                }
                if canClearHistory {
                    if #available(iOS 26, *) {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(role: .destructive) { showClearConfirm = true } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel("Clear history")
                        .disabled(store.activities.isEmpty)
                    }
                }
            }
        }
        .task(id: taskID) {
            store.configure(client: manager.supportsActivities ? manager.client : nil)
            guard manager.supportsActivities else { return }
            await store.retryLiveUpdates()
        }
        .onDisappear {
            store.stopStream()
        }
        .deleteConfirmation(
            isPresented: $showClearConfirm,
            title: "Clear Activity History?",
            message: "Running and queued activities are preserved.",
            icon: "trash",
            confirmTitle: "Clear History"
        ) {
            Task {
                if let result = await store.clearHistory(environmentIDs: clearableEnvironmentIDs) {
                    var message = "Cleared \(result.deleted) completed activit\(result.deleted == 1 ? "y" : "ies")."
                    if result.failed > 0 {
                        message += " \(result.failed) environment\(result.failed == 1 ? "" : "s") could not be cleared."
                    }
                    showToast(.success(message))
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Status", selection: $store.statusFilter) {
                ForEach(ActivityStatusFilter.allCases) { filter in
                    Label(filter.title, systemImage: filter.systemImage).tag(filter)
                }
            }

            Picker("Type", selection: $store.typeFilter) {
                Text("All Types").tag("")
                ForEach(store.availableTypes, id: \.self) { type in
                    Text(type.activityDisplayName).tag(type)
                }
            }

            Picker("Resource", selection: $store.resourceFilter) {
                Text("All Resources").tag("")
                ForEach(store.availableResourceTypes, id: \.self) { resource in
                    Text(resource.activityDisplayName).tag(resource)
                }
            }

            if store.statusFilter != .all || !store.typeFilter.isEmpty || !store.resourceFilter.isEmpty {
                Divider()
                Button {
                    store.statusFilter = .all
                    store.typeFilter = ""
                    store.resourceFilter = ""
                } label: {
                    Label("Clear Filters", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: activeFilterCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter activities")
    }

    private var activeFilterCount: Int {
        var count = store.statusFilter == .all ? 0 : 1
        if !store.typeFilter.isEmpty { count += 1 }
        if !store.resourceFilter.isEmpty { count += 1 }
        return count
    }

    private func activitySection(title: String, items: [ActivityCenterItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                switch item {
                case .activity(let activity):
                    NavigationLink(value: activity) {
                        ActivityRow(activity: activity)
                    }
                case .batch(let batch):
                    DisclosureGroup(isExpanded: expansionBinding(for: batch.id)) {
                        ForEach(batch.activities) { activity in
                            NavigationLink(value: activity) {
                                ActivityBatchMemberRow(activity: activity)
                            }
                        }
                    } label: {
                        ActivityBatchRow(batch: batch)
                    }
                }
            }
        }
    }

    private func expansionBinding(for batchID: String) -> Binding<Bool> {
        Binding(
            get: { expandedBatchIDs.contains(batchID) },
            set: { expanded in
                if expanded {
                    expandedBatchIDs.insert(batchID)
                } else {
                    expandedBatchIDs.remove(batchID)
                }
            }
        )
    }
}

private struct ActivityBatchRow: View {
    let batch: ActivityBatchSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(batch.status.activityTint)
                .frame(width: 34, height: 34)
                .background(batch.status.activityTint.opacity(0.14), in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(batch.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    ResourceStatusBadge(status: batch.status.rawValue)
                }

                Text("\(batch.completedCount) of \(batch.activities.count) completed")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if batch.failedCount > 0 {
                    Text("\(batch.failedCount) failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                ProgressView(value: Double(batch.progress), total: 100)
                    .tint(batch.status.activityTint)

                HStack(spacing: 6) {
                    Text(batch.startedAt, format: .relative(presentation: .named))
                    if let environmentLabel = batch.environmentLabel {
                        Text("-")
                        Text(environmentLabel)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(batch.displayTitle), \(batch.status.rawValue), \(batch.completedCount) of \(batch.activities.count) completed"
        )
        .accessibilityHint("Expands related activities")
    }
}

private struct ActivityBatchMemberRow: View {
    let activity: Activity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ActivityIcon(activity: activity)

            VStack(alignment: .leading, spacing: 4) {
                Text(activity.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(activity.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let source = activity.sourceEnvironmentName, !source.isEmpty {
                    Text(source)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
            ResourceStatusBadge(status: activity.status.rawValue)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ActivityIcon(activity: activity)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(activity.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    Spacer(minLength: 0)

                    ResourceStatusBadge(status: activity.status.rawValue)
                }

                Text(activity.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !activity.latestMessage.isEmpty {
                    Text(activity.latestMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let progress = activity.progress, activity.isCancellable {
                    ProgressView(value: Double(progress), total: 100)
                        .tint(activity.statusTint)
                }

                HStack(spacing: 6) {
                    Text(activity.startedAt, format: .relative(presentation: .named))
                    if let source = activity.sourceEnvironmentName, !source.isEmpty {
                        Text("-")
                        Text(source)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activity.displayTitle), \(activity.status.rawValue), \(activity.subtitle)")
    }
}

private struct ActivityIcon: View {
    let activity: Activity

    var body: some View {
        Image(systemName: activity.typeIcon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(activity.statusTint)
            .frame(width: 34, height: 34)
            .background(activity.statusTint.opacity(0.14), in: .circle)
            .accessibilityHidden(true)
    }
}

struct ActivityDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    @State private var activity: Activity
    @State private var messages: [ActivityMessage] = []
    @State private var isLoading = false
    @State private var isCancelling = false
    @State private var errorMessage: String?
    @State private var showCancelConfirm = false

    init(activity: Activity) {
        _activity = State(initialValue: activity)
    }

    private var environmentID: EnvironmentID {
        EnvironmentID(rawValue: activity.sourceEnvironmentKey)
    }

    private var canCancel: Bool {
        activity.isCancellable
            && (manager.currentUser?.hasPermission("activities:cancel", environmentID: environmentID.rawValue) ?? false)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ActivityIcon(activity: activity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(activity.displayTitle)
                            .font(.headline)
                        Text(activity.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    ResourceStatusBadge(status: activity.status.rawValue)
                }
                .padding(.vertical, 4)

                if let progress = activity.progress {
                    ProgressView(value: Double(progress), total: 100) {
                        Text("Progress")
                    } currentValueLabel: {
                        Text("\(progress)%")
                    }
                    .tint(activity.statusTint)
                }

                if let error = activity.error, !error.isEmpty {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section("Details") {
                LabeledContent("Type", value: activity.type.displayName)
                LabeledContent("Status", value: activity.status.rawValue.capitalized)
                LabeledContent("Started", value: activity.startedAt.formatted(date: .abbreviated, time: .standard))
                if let endedAt = activity.endedAt {
                    LabeledContent("Ended", value: endedAt.formatted(date: .abbreviated, time: .standard))
                }
                if let durationMs = activity.durationMs {
                    LabeledContent("Duration", value: formatDuration(durationMs))
                }
                if let startedBy = activity.startedBy {
                    LabeledContent("Started By", value: startedBy.displayLabel)
                }
                if let source = activity.sourceEnvironmentName, !source.isEmpty {
                    LabeledContent("Source", value: source)
                }
                if let resourceID = activity.resourceID, !resourceID.isEmpty {
                    LabeledContent("Resource ID", value: resourceID)
                }
            }

            if !messages.isEmpty {
                Section("Messages") {
                    ForEach(messages) { message in
                        ActivityMessageRow(message: message)
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if canCancel {
                    Button(role: .destructive) {
                        showCancelConfirm = true
                    } label: {
                        if isCancelling {
                            ProgressView()
                        } else {
                            Image(systemName: "xmark.circle")
                        }
                    }
                    .accessibilityLabel("Cancel activity")
                    .disabled(isCancelling)
                }
            }
        }
        .task { await loadDetail() }
        .refreshable { await loadDetail() }
        .deleteConfirmation(isPresented: $showCancelConfirm, config: DeleteConfirmationConfig(
            title: "Cancel Activity?",
            message: "Arcane will request cancellation. Work that already finished cannot be undone.",
            icon: "xmark.circle",
            actions: [DeleteConfirmationAction(title: "Cancel Activity") {
                Task { await cancelActivity() }
            }],
            cancelTitle: "Keep Running"
        ))
        .alert(
            "Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay {
            if isLoading && messages.isEmpty {
                ProgressView()
                    .controlSize(.large)
            }
        }
    }

    private func loadDetail() async {
        guard let client = manager.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let detail = try await client.activities.detail(
                envID: environmentID,
                activityID: activity.id,
                limit: 500
            )
            activity = detail.activity
            messages = detail.messages.sorted { $0.createdAt < $1.createdAt }
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func cancelActivity() async {
        guard let client = manager.client else { return }
        isCancelling = true
        errorMessage = nil
        defer { isCancelling = false }
        do {
            let requestedBy = manager.currentUser?.displayName ?? manager.currentUser?.username
            let updated = try await client.activities.cancel(
                envID: environmentID,
                activityID: activity.id,
                requestedBy: requestedBy
            )
            activity = updated
            HapticsManager.warning()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func formatDuration(_ durationMs: Int64) -> String {
        let seconds = max(0, durationMs / 1000)
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 { return "\(minutes)m \(remainder)s" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m"
    }
}

private struct ActivityMessageRow: View {
    let message: ActivityMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.level.icon)
                .foregroundStyle(message.level.tint)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(message.message)
                    .font(.subheadline)
                    .textSelection(.enabled)
                Text(message.createdAt, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
