import SwiftUI
import UIKit

struct AccentColorMenu: View {
    @Binding var selection: String
    var isAvailable: (String) -> Bool = { _ in true }
    var onCustom: (() -> Void)?

    private var selectedOption: AccentColorOption? {
        AccentColorOption.allCases.first { $0.hex.caseInsensitiveCompare(selection) == .orderedSame }
    }

    var body: some View {
        Menu {
            ForEach(AccentColorOption.allCases) { option in
                Toggle(
                    isOn: Binding(
                        get: { selectedOption == option },
                        set: { if $0 { selection = option.hex } }
                    )
                ) {
                    Label {
                        Text(option.displayName)
                    } icon: {
                        Image(uiImage: option.menuDot)
                    }
                }
                .disabled(!isAvailable(option.hex))
            }
            if let onCustom {
                Divider()
                Button("Custom…", systemImage: "paintpalette", action: onCustom)
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(selectedOption?.color ?? Color(hex: selection) ?? .blue)
                    .frame(width: 9, height: 9)
                Text(selectedOption?.displayName ?? "Custom")
                    .foregroundStyle(selectedOption?.color ?? Color(hex: selection) ?? .blue)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .fixedSize()
            .contentShape(Rectangle())
        }
    }
}

struct CustomAccentColorPicker: UIViewControllerRepresentable {
    @Binding var selection: Color

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = UIColor(selection)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.selection = $selection
        let color = UIColor(selection)
        if picker.selectedColor != color { picker.selectedColor = color }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var selection: Binding<Color>
        init(selection: Binding<Color>) { self.selection = selection }
        func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
            selection.wrappedValue = Color(uiColor: viewController.selectedColor)
        }
    }
}
