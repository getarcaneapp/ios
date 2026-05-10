import SwiftUI

enum AccentColorOption: String, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, mint, cyan
    case custom

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
        case .custom: return .gray
        }
    }

    var hex: String? {
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
        case .custom: return nil
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("accentColorOption") private var selectedOption = "blue"
    @AppStorage("accentColorHex") private var accentColorHex = ""
    @State private var customColor: Color = .blue
    @State private var showColorPicker = false

    private let columns = Array(repeating: GridItem(.adaptive(minimum: 48), spacing: 12), count: 1)

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 12)], spacing: 12) {
                    ForEach(AccentColorOption.allCases.filter { $0 != .custom }) { option in
                        Circle()
                            .fill(option.color)
                            .frame(width: 48, height: 48)
                            .overlay {
                                if selectedOption == option.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.headline.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                            .onTapGesture {
                                selectedOption = option.rawValue
                                if let hex = option.hex {
                                    accentColorHex = hex
                                }
                            }
                    }
                }
                .padding(.vertical, 8)
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Choose a color to customize the app's appearance.")
            }

            Section {
                HStack {
                    Circle()
                        .fill(customColor)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if selectedOption == "custom" {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                            }
                        }

                    ColorPicker("Custom Color", selection: $customColor, supportsOpacity: false)
                }
                .onChange(of: customColor) { _, newColor in
                    selectedOption = "custom"
                    if let hex = newColor.hexString {
                        accentColorHex = hex
                    }
                }

                if selectedOption == "custom" {
                    Button("Apply Custom Color") {
                        if let hex = customColor.hexString {
                            accentColorHex = hex
                        }
                    }
                }
            } header: {
                Text("Custom")
            }

            Section {
                Button("Reset to Default") {
                    selectedOption = "blue"
                    accentColorHex = ""
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selectedOption == "custom", let color = Color(hex: accentColorHex) {
                customColor = color
            }
        }
    }
}
