import SwiftUI
import Arcane

struct UpdaterStatusView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID

    @State private var status: UpdaterStatus?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastRefreshed: Date?

    private var isActive: Bool {
        guard let status else { return false }
        return status.updatingContainers > 0 || status.updatingProjects > 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if isLoading && status == nil {
                    ProgressView("Loading updater status…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if let errorMessage, status == nil {
                    ContentUnavailableView("Couldn't Load Status", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if let status {
                    statusHero(status: status)
                    countersCard(status: status)
                    if let ids = status.containerIds, !ids.isEmpty {
                        idListCard(title: "Containers Updating", icon: "shippingbox.fill", tint: .blue, ids: ids)
                    }
                    if let ids = status.projectIds, !ids.isEmpty {
                        idListCard(title: "Projects Updating", icon: "folder.fill", tint: .purple, ids: ids)
                    }
                    refreshFooter
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Updater Status")
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

    private func statusHero(status: UpdaterStatus) -> some View {
        let active = isActive
        let tint: Color = active ? .blue : .green
        let icon = active ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
        let title = active ? "Updating" : "Idle"
        let subtitle: String = {
            if active {
                var parts: [String] = []
                if status.updatingContainers > 0 {
                    parts.append("\(status.updatingContainers) container\(status.updatingContainers == 1 ? "" : "s")")
                }
                if status.updatingProjects > 0 {
                    parts.append("\(status.updatingProjects) project\(status.updatingProjects == 1 ? "" : "s")")
                }
                return parts.joined(separator: " · ") + " in progress"
            }
            return "Nothing in progress"
        }()

        return VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.rotate, options: .repeating, isActive: active)
            }
            .glassEffect(.regular.tint(tint.opacity(0.25)), in: .circle)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func countersCard(status: UpdaterStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Activity", icon: "chart.bar.fill", tint: .purple)
            HStack(spacing: 12) {
                counterTile(
                    label: "Containers",
                    value: status.updatingContainers,
                    icon: "shippingbox.fill",
                    tint: .blue
                )
                counterTile(
                    label: "Projects",
                    value: status.updatingProjects,
                    icon: "folder.fill",
                    tint: .purple
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func counterTile(label: String, value: Int64, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("\(value)")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 14))
    }

    private func idListCard(title: String, icon: String, tint: Color, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: title, icon: icon, tint: tint)
            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                            .symbolEffect(.rotate, options: .repeating, isActive: true)
                            .frame(width: 22, height: 22)
                            .background(tint.opacity(0.15), in: .circle)
                        Text(id)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    if index < ids.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var refreshFooter: some View {
        Group {
            if let lastRefreshed {
                Text("Updated \(lastRefreshed.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func cardHeader(title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
            Spacer()
        }
    }

    private func load(refresh: Bool = false) async {
        guard let client = manager.client else { return }
        if status == nil { isLoading = true }
        if refresh { errorMessage = nil }
        defer { isLoading = false }
        do {
            status = try await client.updater.status(envID: environmentID)
            lastRefreshed = Date()
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}
