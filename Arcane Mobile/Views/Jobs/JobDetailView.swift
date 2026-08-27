import SwiftUI
import Arcane

struct JobDetailView: View {
    let environmentID: EnvironmentID
    let job: JobStatus
    let isRunning: Bool
    let onRun: () async -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                headerCard
                scheduleCard
                flagsCard

                if !job.prerequisites.isEmpty {
                    prerequisitesCard(job.prerequisites)
                }

                identifierCard
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .softTopScrollEdgeEffectCompat()
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(job.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if job.canRunManually {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await onRun() }
                    } label: {
                        if isRunning {
                            ProgressView()
                        } else {
                            Image(systemName: "play.fill")
                        }
                    }
                    .disabled(isRunning || !job.enabled)
                    .accessibilityLabel("Run Now")
                }
            }
        }
    }

    // MARK: - Cards

    /// Grouped card of rows, mirroring the dashboard's info-group vocabulary.
    private func card<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title, systemImage: systemImage)
            VStack(spacing: 0) { content() }
                .dashboardCardBackground(cornerRadius: Radius.standard)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.15), in: .circle)
                    .symbolEffect(.rotate, options: .repeating, isActive: isRunning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.name)
                        .font(.headline)
                    if !job.category.isEmpty {
                        Text(job.category.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                }
            }
            if !job.description.isEmpty {
                Text(job.description)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCardBackground()
    }

    private var scheduleCard: some View {
        card(title: "Schedule", systemImage: "clock") {
            row("Cron") {
                Text(job.schedule)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            if let readable = CronExpression.readable(job.schedule) {
                row("Runs") { valueText(readable) }
            }
            if let next = job.nextRun {
                row("Next Run") { valueText(next.formatted(date: .abbreviated, time: .standard)) }
            }
        }
    }

    private var flagsCard: some View {
        card(title: "Flags", systemImage: "flag") {
            row("Enabled") { valueText(job.enabled ? "Yes" : "No") }
            row("Continuous") { valueText(job.isContinuous ? "Yes" : "No") }
            row("Manager Only") { valueText(job.managerOnly ? "Yes" : "No") }
            row("Runnable Manually") { valueText(job.canRunManually ? "Yes" : "No") }
        }
    }

    private func prerequisitesCard(_ prerequisites: [JobPrerequisite]) -> some View {
        card(title: "Prerequisites", systemImage: "checklist") {
            ForEach(Array(prerequisites.enumerated()), id: \.offset) { index, prerequisite in
                if index > 0 { Divider().padding(.leading, 12) }
                HStack(spacing: 10) {
                    Image(systemName: prerequisite.isMet ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(prerequisite.isMet ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prerequisite.label)
                            .font(.subheadline)
                        Text(prerequisite.settingKey)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
            }
        }
    }

    private var identifierCard: some View {
        card(title: "Identifier", systemImage: "number") {
            row("Job ID") {
                Text(job.id)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            if let key = job.settingsKey, !key.isEmpty {
                row("Settings Key") {
                    Text(key)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            value()
        }
        .padding(12)
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .font(.subheadline)
            .multilineTextAlignment(.trailing)
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
}
