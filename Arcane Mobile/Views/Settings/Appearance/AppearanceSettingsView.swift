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
    @AppStorage("arcane.launchAnimationEnabled") private var launchAnimationEnabled = true
    @AppStorage(TabIndicatorMotion.storageKey) private var tabIndicatorMotion: TabIndicatorMotion = .straight
    @State private var showAccentColorMenu = false
    @State private var showTabBarResetConfirm = false
    @State private var navTabsStore = NavTabsStore.shared

    // Derive the picker selection from the stored hex so the two cannot drift
    // apart. An empty hex represents the blue system default. `nil` preserves
    // a custom hex stored by an older build until the user chooses a preset.
    private var selectedOption: AccentColorOption? {
        if accentColorHex.isEmpty { return .blue }
        let normalized = accentColorHex.lowercased()
        return AccentColorOption.allCases.first { $0.hex.lowercased() == normalized }
    }

    private var selectedAccentColor: Color {
        selectedOption?.color ?? Color(hex: accentColorHex) ?? .blue
    }

    var body: some View {
        Form {
            Section {
                Button {
                    showAccentColorMenu = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsRow(
                            title: "Accent Color",
                            systemImage: "paintpalette.fill",
                            color: selectedAccentColor
                        )
                        Spacer()
                        HStack(spacing: 8) {
                            if let selectedOption {
                                Circle()
                                    .fill(selectedOption.color)
                                    .frame(width: 9, height: 9)
                                Text(selectedOption.displayName)
                                    .foregroundStyle(selectedOption.color)
                            }
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                        .fixedSize()
                        .popover(isPresented: $showAccentColorMenu, arrowEdge: .top) {
                            AccentColorMenu(selection: selectedOption) { option in
                                accentColorHex = option.hex
                                showAccentColorMenu = false
                            }
                            .presentationCompactAdaptation(.popover)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Choose a color to customize the app's appearance.")
            }

            Section {
                Toggle(isOn: $launchAnimationEnabled) {
                    SettingsRow(
                        title: "Launch Animation",
                        systemImage: "sparkles",
                        color: .purple
                    )
                }

                Picker(selection: $tabIndicatorMotion) {
                    ForEach(TabIndicatorMotion.allCases) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    SettingsRow(
                        title: "Tab Indicator Path",
                        systemImage: "arrow.left.and.right.circle.fill",
                        color: .orange
                    )
                }
            } header: {
                Text("Motion")
            } footer: {
                Text("Controls the launch animation and how the dock indicator moves between tabs.")
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
                            if let image = UIImage(named: AppIconPreviewAsset.name(
                                for: UIApplication.shared.alternateIconName
                            )) {
                                Image(uiImage: image)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
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

private struct AccentColorMenu: View {
    let selection: AccentColorOption?
    let onSelect: (AccentColorOption) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(AccentColorOption.allCases) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(option.color)
                                .frame(width: 12, height: 12)
                                .overlay {
                                    Circle()
                                        .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                                }
                            Text(option.displayName)
                                .foregroundStyle(option.color)
                            Spacer()
                            if selection == option {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(option.color)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(width: 240, height: 478)
    }
}
