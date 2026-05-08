import SwiftUI

struct AppLockView: View {
    @Environment(AppLockManager.self) private var lockManager

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.primary)
                        .padding(24)
                        .glassEffect(.regular, in: .circle)

                    Text("Arcane Mobile")
                        .font(.title.bold())

                    Text("Unlock to continue")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await lockManager.authenticate() }
                } label: {
                    Label(lockManager.lockLabel, systemImage: lockManager.lockIcon)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.glassProminent)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .task {
            await lockManager.authenticate()
        }
    }
}
