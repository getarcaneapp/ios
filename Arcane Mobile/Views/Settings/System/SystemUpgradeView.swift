import SwiftUI
import Arcane

struct SystemUpgradeView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    let environmentID: EnvironmentID

    private enum Phase: Equatable {
        case checking
        case ready(UpgradeCheckResultData)
        case checkFailed(String)
        case triggering
        case triggered(String)
        case triggerFailed(String)
    }

    @State private var phase: Phase = .checking
    @State private var showConfirm = false

    private var isAdmin: Bool { manager.currentUser?.isAdmin == true }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !isAdmin {
                    ContentUnavailableView(
                        "Admins Only",
                        systemImage: "lock.shield",
                        description: Text("Upgrading Arcane requires an administrator account.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    switch phase {
                    case .checking:
                        loadingCard
                    case .ready(let result):
                        readyContent(result: result)
                    case .checkFailed(let message):
                        ContentUnavailableView(
                            "Couldn't Check for Upgrade",
                            systemImage: "exclamationmark.triangle",
                            description: Text(message)
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    case .triggering:
                        triggeringCard
                    case .triggered(let message):
                        triggeredCard(message: message)
                    case .triggerFailed(let message):
                        ContentUnavailableView(
                            "Upgrade Failed",
                            systemImage: "exclamationmark.triangle",
                            description: Text(message)
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                        retryButton
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Upgrade Arcane")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isAdmin, case .ready = phase {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await checkUpgrade() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
        }
        .task {
            guard isAdmin else { return }
            await checkUpgrade()
        }
        .confirmationDialog("Upgrade Arcane?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Upgrade", role: .destructive) {
                Task { await triggerUpgrade() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Arcane will restart. The mobile app may briefly lose connection.")
        }
    }

    // MARK: - States

    private var loadingCard: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Checking for upgrade…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func readyContent(result: UpgradeCheckResultData) -> some View {
        VStack(spacing: 16) {
            heroCard(
                tint: result.canUpgrade ? .blue : .gray,
                icon: result.canUpgrade ? "arrow.up.circle.fill" : "lock.circle.fill",
                title: result.canUpgrade ? "Upgrade Available" : "Upgrade Unavailable",
                subtitle: result.message
            )

            if result.canUpgrade {
                infoCard(
                    icon: "info.circle.fill",
                    tint: .blue,
                    title: "What happens next",
                    body: "A new Arcane container will be created from the latest image and replace this one. The mobile app will briefly lose connection while it restarts."
                )

                Button(role: .destructive) {
                    showConfirm = true
                } label: {
                    Label("Upgrade Arcane", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                infoCard(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "Self-upgrade is not supported here",
                    body: "Arcane can only self-upgrade when running in a Docker container with access to the Docker socket. Update Arcane from your deployment instead."
                )
            }
        }
    }

    private var triggeringCard: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.18))
                    .frame(width: 96, height: 96)
                ProgressView()
                    .controlSize(.large)
            }
            .glassEffect(.regular.tint(Color.blue.opacity(0.25)), in: .circle)
            VStack(spacing: 6) {
                Text("Starting upgrade…")
                    .font(.title2.bold())
                Text("Asking Arcane to restart")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func triggeredCard(message: String) -> some View {
        VStack(spacing: 20) {
            heroCard(
                tint: .green,
                icon: "checkmark.circle.fill",
                title: "Upgrade Initiated",
                subtitle: message
            )
            infoCard(
                icon: "antenna.radiowaves.left.and.right",
                tint: .blue,
                title: "Reconnecting shortly",
                body: "A new Arcane container is starting. The mobile app may briefly lose connection — pull to refresh once it's back."
            )
            ProgressView()
                .controlSize(.regular)
        }
    }

    private var retryButton: some View {
        Button {
            Task { await checkUpgrade() }
        } label: {
            Label("Check Again", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Reusable cards

    private func heroCard(tint: Color, icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(tint)
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

    private func infoCard(icon: String, tint: Color, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
            }
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    // MARK: - Network

    private func checkUpgrade() async {
        guard let client = manager.client else {
            phase = .checkFailed("Not connected")
            return
        }
        phase = .checking
        do {
            let result = try await client.system.checkUpgrade(envID: environmentID)
            phase = .ready(result)
        } catch {
            phase = .checkFailed(friendlyErrorMessage(error))
        }
    }

    private func triggerUpgrade() async {
        guard let client = manager.client else {
            phase = .triggerFailed("Not connected")
            return
        }
        phase = .triggering
        do {
            // SDK returns Void here — the server may return 202 because it's
            // mid-replacement. Show a static success message; the app will
            // reconnect once the new container is up.
            try await client.system.triggerUpgrade(envID: environmentID)
            phase = .triggered("Upgrade initiated. Arcane will restart shortly.")
        } catch {
            phase = .triggerFailed(friendlyErrorMessage(error))
        }
    }
}
