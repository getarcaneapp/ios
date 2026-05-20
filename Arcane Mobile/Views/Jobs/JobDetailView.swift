import SwiftUI
import Arcane

struct JobDetailView: View {
    let environmentID: EnvironmentID
    let job: JobStatus
    let isRunning: Bool
    let onRun: () async -> Void

    var body: some View {
        List {
            Section {
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
                .padding(.vertical, 4)
                if !job.description.isEmpty {
                    Text(job.description)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }

            Section("Schedule") {
                LabeledContent("Cron") {
                    Text(job.schedule)
                        .font(.subheadline.monospaced())
                        .textSelection(.enabled)
                }
                if let readable = CronExpression.readable(job.schedule) {
                    LabeledContent("Runs", value: readable)
                }
                if let next = job.nextRun {
                    LabeledContent("Next Run", value: next.formatted(date: .abbreviated, time: .standard))
                }
            }

            Section("Flags") {
                LabeledContent("Enabled", value: job.enabled ? "Yes" : "No")
                LabeledContent("Continuous", value: job.isContinuous ? "Yes" : "No")
                LabeledContent("Manager Only", value: job.managerOnly ? "Yes" : "No")
                LabeledContent("Runnable Manually", value: job.canRunManually ? "Yes" : "No")
            }

            if !job.prerequisites.isEmpty {
                let prerequisites = job.prerequisites
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

            Section("Identifier") {
                LabeledContent("Job ID") {
                    Text(job.id)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let key = job.settingsKey, !key.isEmpty {
                    LabeledContent("Settings Key") {
                        Text(key)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
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
