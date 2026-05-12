import SwiftUI
import Arcane

struct JobsListView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID

    @State private var jobs: [JobStatus] = []
    @State private var isAgent = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var runningJobs: Set<String> = []
    @State private var actionMessage: String?

    private var grouped: [(category: String, jobs: [JobStatus])] {
        let filtered = filteredJobs
        let groups = Dictionary(grouping: filtered) { $0.category.isEmpty ? "Other" : $0.category }
        return groups.keys.sorted().map { key in
            (category: key, jobs: groups[key]?.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } ?? [])
        }
    }

    private var filteredJobs: [JobStatus] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return jobs }
        return jobs.filter { job in
            job.name.localizedCaseInsensitiveContains(trimmed) ||
            job.description.localizedCaseInsensitiveContains(trimmed) ||
            job.category.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        Group {
            if isLoading && jobs.isEmpty {
                ProgressView("Loading jobs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, jobs.isEmpty {
                ContentUnavailableView("Couldn't Load Jobs", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if jobs.isEmpty {
                ContentUnavailableView("No Jobs", systemImage: "play.square.stack")
            } else {
                List {
                    if let actionMessage {
                        Section {
                            Label(actionMessage, systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        }
                    }
                    ForEach(grouped, id: \.category) { group in
                        Section {
                            ForEach(group.jobs) { job in
                                NavigationLink {
                                    JobDetailView(
                                        environmentID: environmentID,
                                        job: job,
                                        isRunning: runningJobs.contains(job.id),
                                        onRun: { await run(job) }
                                    )
                                } label: {
                                    JobRow(job: job, isRunning: runningJobs.contains(job.id))
                                }
                            }
                        } header: {
                            Text(group.category.capitalized)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Jobs")
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search jobs")
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
        if jobs.isEmpty { isLoading = true }
        if refresh { errorMessage = nil }
        defer { isLoading = false }
        do {
            let response = try await client.jobs.list(envID: environmentID)
            jobs = response.jobs
            isAgent = response.isAgent
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func run(_ job: JobStatus) async {
        guard let client = manager.client, !runningJobs.contains(job.id) else { return }
        runningJobs.insert(job.id)
        defer { runningJobs.remove(job.id) }
        do {
            let result = try await client.jobs.run(envID: environmentID, id: job.id)
            actionMessage = result.message.isEmpty ? "\(job.name) started" : result.message
        } catch {
            actionMessage = friendlyErrorMessage(error)
        }
    }
}

private struct JobRow: View {
    let job: JobStatus
    let isRunning: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.15), in: .circle)
                .symbolEffect(.rotate, options: .repeating, isActive: isRunning)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !job.description.isEmpty {
                    Text(job.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(job.schedule)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    if let next = job.nextRun {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(next, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
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
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: .capsule)
    }
}
