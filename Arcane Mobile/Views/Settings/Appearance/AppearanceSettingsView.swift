import SwiftUI
import UIKit

enum AccentColorOption: String, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, mint, cyan

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .mint: return .mint
        case .cyan: return .cyan
        }
    }

    var hex: String {
        switch self {
        case .blue: return "#007AFF"
        case .indigo: return "#5856D6"
        case .purple: return "#AF52DE"
        case .pink: return "#FF2D55"
        case .red: return "#FF3B30"
        case .orange: return "#FF9500"
        case .yellow: return "#FFCC00"
        case .green: return "#34C759"
        case .teal: return "#5AC8FA"
        case .mint: return "#00C7BE"
        case .cyan: return "#32D2F0"
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("accentColorHex") private var accentColorHex = ""
    @State private var showTabBarResetConfirm = false
    @State private var navTabsStore = NavTabsStore.shared

    // Derive the selected swatch from the stored hex so the two can never
    // drift apart. An empty hex means "use the system default" which we
    // visually represent as the blue swatch. `nil` means a custom hex from
    // an older build is stored, so no swatch is highlighted.
    private var selectedOption: AccentColorOption? {
        if accentColorHex.isEmpty { return .blue }
        let normalized = accentColorHex.lowercased()
        return AccentColorOption.allCases.first { $0.hex.lowercased() == normalized }
    }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 12)], spacing: 12) {
                    ForEach(AccentColorOption.allCases) { option in
                        Button {
                            accentColorHex = option.hex
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 48, height: 48)
                                .overlay {
                                    if selectedOption == option {
                                        Image(systemName: "checkmark")
                                            .font(.headline.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(option.rawValue.capitalized))
                        .accessibilityAddTraits(selectedOption == option ? .isSelected : [])
                    }
                }
                .padding(.vertical, 8)
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Choose a color to customize the app's appearance.")
            }

            if UIApplication.shared.supportsAlternateIcons {
                Section {
                    NavigationLink(destination: AppIconPickerView()) {
                        HStack(spacing: 12) {
                            if let image = UIImage(named: UIApplication.shared.alternateIconName.map({ "\($0)-Preview" }) ?? "AppIcon-Preview") {
                                Image(uiImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            } else {
                                Image(systemName: "app.fill")
                                    .foregroundStyle(.blue)
                                    .frame(width: 32, height: 32)
                            }
                            Text("App Icon")
                        }
                    }
                } header: {
                    Text("Icon")
                }
            }

            Section {
                Button(role: .destructive) {
                    showTabBarResetConfirm = true
                } label: {
                    Text("Reset Tab Bar")
                }
                .foregroundStyle(.red)
                .disabled(navTabsStore.pinnedTabs == AppTab.mainDefaults)
            } header: {
                Text("Tab Bar")
            } footer: {
                Text("Restores the bottom tab bar to Dashboard, Containers, Images, and Projects. Long-press a tab to swap it.")
            }

            Section {
                Button("Reset to Default") {
                    accentColorHex = ""
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .deleteConfirmation(
            isPresented: $showTabBarResetConfirm,
            title: "Reset Tab Bar",
            message: "Restores the bottom tab bar to Dashboard, Containers, Images, and Projects.",
            icon: "rectangle.3.offgrid",
            confirmTitle: "Reset"
        ) {
            navTabsStore.resetToDefaults()
        }
    }
}
