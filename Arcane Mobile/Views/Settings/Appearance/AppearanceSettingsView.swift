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
    @AppStorage("arcane.sidebarNavigationEnabled") private var sidebarNavigationEnabled = false
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

    /// A 26pt swatch inside a fixed 36pt slot; the selected one earns a 2pt
    /// ring in its own color. Fixed slot size = no layout shift on selection.
    private func accentSwatch(_ option: AccentColorOption) -> some View {
        let isSelected = selectedOption == option
        return Button {
            accentColorHex = option.hex
        } label: {
            Circle()
                .fill(option.color)
                .frame(width: 26, height: 26)
                .overlay {
                    Circle()
                        .strokeBorder(option.color, lineWidth: 2)
                        .frame(width: 36, height: 36)
                        .opacity(isSelected ? 1 : 0)
                        .scaleEffect(isSelected ? 1 : 0.7)
                }
                .frame(width: 36, height: 36)
                .motionAwareAnimation(Motion.state, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.displayName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    var body: some View {
        Form {
            Section {
                // Compact single-row picker (like the system accent picker):
                // small swatches, selection shown as a concentric ring in the
                // swatch's own color rather than a checkmark.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(AccentColorOption.allCases) { option in
                            accentSwatch(option)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Choose a color to customize the app's appearance.")
            }

            Section {
                Toggle(isOn: $sidebarNavigationEnabled) {
                    SettingsRow(
                        title: "Sidebar Navigation",
                        systemImage: "sidebar.left",
                        color: .indigo
                    )
                }
            } header: {
                Text("Navigation")
            } footer: {
                Text("Lists all available pages in a sidebar instead of the bottom dock.")
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
                    Text("Reset Dock")
                }
                .foregroundStyle(.red)
                .disabled(navTabsStore.pinnedTabs == AppTab.mainDefaults)
            } header: {
                Text("Dock")
            } footer: {
                Text("Restores the bottom dock to Dashboard, Containers, Images, and Projects. Long-press a dock item to swap it.")
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
            title: "Reset Dock",
            message: "Restores the bottom dock to Dashboard, Containers, Images, and Projects.",
            icon: "rectangle.3.offgrid",
            confirmTitle: "Reset"
        ) {
            navTabsStore.resetToDefaults()
        }
    }
}
