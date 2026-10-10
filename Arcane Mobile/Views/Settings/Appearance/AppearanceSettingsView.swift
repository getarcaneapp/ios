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

    /// Pre-rendered dot for menu rows. Bitmap with always-original rendering
    /// so menus keep the real color instead of tinting the glyph.
    private static var dotImages: [String: UIImage] = [:]

    var menuDot: UIImage {
        if let cached = Self.dotImages[rawValue] { return cached }
        let diameter: CGFloat = 15
        let image = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter)).image { _ in
            UIColor(color).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        }.withRenderingMode(.alwaysOriginal)
        Self.dotImages[rawValue] = image
        return image
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("accentColorHex") private var accentColorHex = ""
    @AppStorage("arcane.launchAnimationEnabled") private var launchAnimationEnabled = true
    @AppStorage("arcane.showTabLabels") private var showTabLabels = false

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

    /// Picker selection never stores empty: empty hex means the blue default.
    private var accentPickerSelection: Binding<String> {
        Binding(
            get: { selectedOption?.hex ?? AccentColorOption.blue.hex },
            set: { accentColorHex = $0 }
        )
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    SettingsRow(
                        title: "Accent Color",
                        systemImage: "paintpalette.fill",
                        color: selectedAccentColor
                    )
                    Spacer()
                    AccentColorMenu(selection: accentPickerSelection)
                }
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

            } header: {
                Text("Motion")
            } footer: {
                Text("Controls the launch animation.")
            }

            Section {
                Toggle(isOn: $showTabLabels) {
                    SettingsRow(
                        title: "Show Tab Labels",
                        systemImage: "character.cursor.ibeam",
                        color: .blue
                    )
                }
            } header: {
                Text("Tab Bar")
            } footer: {
                Text("Hide labels for evenly sized tab bar items. Tab names remain available to VoiceOver.")
            }

            if UIApplication.shared.supportsAlternateIcons {
                Section {
                    NavigationLink(destination: AppIconPickerView()) {
                        HStack(spacing: 12) {
                            if let image = UIImage(
                                named: AppIconPreviewAsset.name(
                                    for: UIApplication.shared.alternateIconName
                                ))
                            {
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
                Button("Reset to Default") {
                    accentColorHex = ""
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
