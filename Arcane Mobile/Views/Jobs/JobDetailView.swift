import SwiftUI
import Arcane

struct JobDetailView: View {
    let environmentID: EnvironmentID
    let job: JobStatus
    let isRunning: Bool
    let onRun: () async -> Void

    var body: some View {
        List {
            headerSection
            scheduleSection
            flagsSection

            if !job.prerequisites.isEmpty {
                prerequisitesSection(job.prerequisites)
            }

            identifierSection
        }
        .listStyle(.insetGrouped)
        .softTopScrollEdgeEffectCompat()
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

    private var headerSection: some View {
        Section {
            Label {
                VStack(alignment: .leading) {
                    Text(job.name).font(.headline)
                    if !job.category.isEmpty {
                        Text(job.category.capitalized).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            if !job.description.isEmpty {
                Text(job.description).textSelection(.enabled)
            }
        }
    }

    private var scheduleSection: some View {
        Section("Schedule") {
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

    private var flagsSection: some View {
        Section("Flags") {
            row("Enabled") { valueText(job.enabled ? "Yes" : "No") }
            row("Continuous") { valueText(job.isContinuous ? "Yes" : "No") }
            row("Manager Only") { valueText(job.managerOnly ? "Yes" : "No") }
            row("Runnable Manually") { valueText(job.canRunManually ? "Yes" : "No") }
        }
    }

    private func prerequisitesSection(_ prerequisites: [JobPrerequisite]) -> some View {
        Section("Prerequisites") {
            ForEach(Array(prerequisites.enumerated()), id: \.offset) { _, prerequisite in
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
            }
        }
    }

    private var identifierSection: some View {
        Section("Identifier") {
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
        LabeledContent(label) { value() }
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
