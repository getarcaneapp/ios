import SwiftUI
import Arcane

/// Entry point for the assistant — presented as a sheet from the toolbar
/// button and as a seeded sheet from container/project detail screens.
@available(iOS 26, *)
struct AIAssistantView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(ResourceMutationStore.self) private var mutationStore

    var seed: AISeed = .none

    @State private var service: AIAssistantService?

    var body: some View {
        Group {
            if let service {
                switch service.availability {
                case .available:
                    AIChatView(service: service)
                case .checking:
                    assistantLoadingView
                default:
                    AIUnavailableView(state: service.availability) {
                        service.refreshAvailability()
                        service.startSessionIfNeeded()
                    }
                }
            } else if manager.client == nil {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "bolt.horizontal.circle",
                    description: Text("Connect to a server to use Arcane Assistant.")
                )
            } else {
                assistantLoadingView
            }
        }
        .navigationTitle("Arcane Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text("Arcane Assistant")
                        .font(.headline)
                    Text("ALPHA")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hue: 0.78, saturation: 0.6, brightness: 0.65), in: .capsule)
                }
            }
        }
        .task { setupIfNeeded() }
    }

    private var assistantLoadingView: some View {
        VStack(spacing: 16) {
            ArcaneAssistantIcon(size: 56)
            ProgressView()
                .tint(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setupIfNeeded() {
        guard service == nil, let client = manager.client else { return }

        let envID = manager.activeEnvironmentID
        let context = ArcaneToolContext(
            client: client,
            envID: envID,
            envName: manager.activeEnvironmentName,
            capabilities: manager.serverCapabilities ?? .unknown,
            status: AIToolStatus()
        )
        let store = mutationStore

        let svc = AIAssistantService(context: context, seed: seed) { action in
            for kind in action.mutationKinds {
                store.markChanged(kind: kind, envID: envID)
            }
            Task {
                await manager.cached?.invalidate(
                    envID: envID,
                    paths: action.cachePaths(client: client, envID: envID)
                )
            }
        }
        svc.refreshAvailability()
        svc.startSessionIfNeeded()
        service = svc
    }
}
