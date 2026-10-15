import Arcane
import SwiftUI

struct JobsListView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore
    let environmentID: EnvironmentID
    /// All Environments preview: list and run jobs from every enabled environment.
    var allEnvironments = false

    @State private var list = EnvironmentPagedList<JobStatus>()
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var runningJobs: Set<String> = []
    @State private var actionMessage: String?
    @State private var groups: [JobGroup] = []
    @State private var filteredJobCount = 0

    private var jobs: [EnvironmentItem<JobStatus>] { list.items }

    private struct JobGroup: Identifiable {
        let category: String
        let jobs: [EnvironmentItem<JobStatus>]
        var id: String { category }
    }

    private func rebuildGroups() {
        let filtered = filteredJobs()
        let groups = Dictionary(grouping: filtered) { $0.category.isEmpty ? "Other" : $0.category }
        self.groups = groups.keys.sorted().map { key in
            JobGroup(
                category: key,
                jobs: groups[key]?.sorted {
                    let order = $0.name.localizedStandardCompare($1.name)
                    guard order == .orderedSame else { return order == .orderedAscending }
                    return ($0.environmentName ?? "").localizedStandardCompare($1.environmentName ?? "")
                        == .orderedAscending
                } ?? []
            )
        }
        filteredJobCount = filtered.count
    }

    private func filteredJobs() -> [EnvironmentItem<JobStatus>] {
        let trimmed = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return jobs }
        return jobs.filter { job in
            job.name.localizedCaseInsensitiveContains(trimmed)
                || job.description.localizedCaseInsensitiveContains(trimmed)
                || job.category.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        Group {
            if list.isLoading && jobs.isEmpty {
                ArcaneLoadingView("Loading jobs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = list.errorMessage, jobs.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Jobs", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else if jobs.isEmpty {
                ContentUnavailableView("No Jobs", systemImage: "play.square.stack")
            } else {
                List {
                    EnvironmentLoadFailuresSection(failures: list.failedEnvironments) {
                        Task { await load() }
                    }
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.jobs) { job in
                                NavigationLink {
                                    JobDetailView(
                                        environmentID: job.environmentID,
                                        job: job.value,
                                        isRunning: runningJobs.contains(job.id),
                                        onRun: { await run(job) }
                                    )
                                } label: {
                                    JobRow(
                                        job: job.value, isRunning: runningJobs.contains(job.id),
                                        environmentName: job.environmentName
                                    )
                                    .rowEnvironment(job)
                                }
                                .contextMenu {
                                    Button {
                                        Task { await run(job) }
                                    } label: {
                                        Label("Run Job", systemImage: "play.fill")
                                    }
                                    .disabled(runningJobs.contains(job.id) || !job.enabled)

                                    Button {
                                        UIPasteboard.general.string = job.name
                                        showToast(.copied("Job name copied"))
                                    } label: {
                                        Label("Copy Job Name", systemImage: "doc.on.doc")
                                    }

                                    if !job.schedule.isEmpty {
                                        Button {
                                            UIPasteboard.general.string = job.schedule
                                            showToast(.copied("Schedule copied"))
                                        } label: {
                                            Label("Copy Schedule", systemImage: "clock")
                                        }
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        Task { await run(job) }
                                    } label: {
                                        Label("Run", systemImage: "play.fill")
                                    }
                                    .tint(.blue)
                                    .disabled(runningJobs.contains(job.id) || !job.enabled)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        UIPasteboard.general.string = job.name
                                        showToast(.copied("Job name copied"))
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    .tint(.gray)
                                }
                            }
                        } header: {
                            if group.category == groups.first?.category {
                                ResourceCountSectionHeader(
                                    group.category.capitalized,
                                    loadedCount: filteredJobCount
                                )
                            } else {
                                Text(group.category.capitalized)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Jobs")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search jobs")
        .debounce(searchText, for: .milliseconds(200), into: $debouncedSearchText)
        .onChange(of: debouncedSearchText) { rebuildGroups() }
        .toolbar {
            AppToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
                .disabled(list.isLoading)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = manager.client else { return }
        let environments = await environmentsStore.listEnvironments(
            environmentID, allEnvironments: allEnvironments, manager: manager)
        // The jobs endpoint isn't paginated: each environment returns one complete page.
        await list.reload(environments) { environmentID, _, _ in
            let jobs = try await client.jobs.list(envID: environmentID).jobs
            return ResourcePage(
                items: jobs,
                pagination: PaginationResponse(
                    totalPages: 1, totalItems: Int64(jobs.count), currentPage: 1, itemsPerPage: max(jobs.count, 1))
            )
        }
        rebuildGroups()
    }

    private func run(_ job: EnvironmentItem<JobStatus>) async {
        guard let client = manager.client, !runningJobs.contains(job.id) else { return }
        HapticsManager.medium()
        runningJobs.insert(job.id)
        defer { runningJobs.remove(job.id) }
        do {
            let result = try await client.jobs.run(jobID: job.value.id, envID: job.environmentID)
            let msg = result.message.isEmpty ? "\(job.name) started" : result.message
            HapticsManager.success()
            showToast(.success(msg))
        } catch {
            showToast(.error(friendlyErrorMessage(error)))
        }
    }
}

private struct JobRow: View {
    let job: JobStatus
    let isRunning: Bool
    var environmentName: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RowIcon(systemImage: icon, tint: tint)
                .symbolEffect(.rotate, options: .repeating, isActive: isRunning)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.name)
                    .font(.body)

                if !job.description.isEmpty {
                    Text(job.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                }
                HStack(spacing: 6) {
                    Text(job.schedule)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    if let next = job.nextRun {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(next, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                EnvironmentLabel(name: environmentName)
            }
            Spacer(minLength: 0)
            statusBadge
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if !job.enabled { return "pause.circle.fill" }
        if isRunning { return "arrow.triangle.2.circlepath" }
        if job.isContinuous { return "infinity.circle.fill" }
        return "clock.fill"
    }

    private var tint: Color {
        if !job.enabled { return .gray }
        if isRunning { return .blue }
        return .indigo
    }

    @ViewBuilder
    private var statusBadge: some View {
        if !job.enabled {
            JobBadge(text: "OFF", tint: .gray)
        } else if job.isContinuous {
            JobBadge(text: "CONT", tint: .purple)
        }
    }
}

struct JobBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)

    }
}
