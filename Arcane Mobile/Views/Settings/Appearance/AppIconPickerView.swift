import SwiftUI
import UIKit

private struct AppIconOption: Identifiable, Hashable {
    /// `nil` represents the primary / default icon.
    let alternateName: String?
    let displayName: String
    let previewAssetName: String

    var id: String { alternateName ?? "__primary__" }
}

struct AppIconPickerView: View {
    @State private var currentIconName: String? = UIApplication.shared.alternateIconName
    @State private var errorMessage: String?
    @Namespace private var selectionNamespace
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Read alternates declared in Info.plist's `CFBundleAlternateIcons`.
    /// Returns an array starting with the primary icon, followed by each alternate.
    private var options: [AppIconOption] {
        var result: [AppIconOption] = [
            .init(alternateName: nil, displayName: "Default", previewAssetName: "AppIcon")
        ]
        guard
            let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
            let alternates = icons["CFBundleAlternateIcons"] as? [String: Any]
        else { return result }
        for name in alternates.keys.sorted() {
            result.append(.init(
                alternateName: name,
                displayName: prettify(name),
                previewAssetName: name
            ))
        }
        return result
    }

    var body: some View {
        List {
            Section {
                ForEach(options) { option in
                    Button {
                        select(option)
                    } label: {
                        HStack(spacing: 14) {
                            iconPreview(option.previewAssetName)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.displayName)
                                    .foregroundStyle(.primary)
                                if option.alternateName == nil {
                                    Text("Original")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if option.alternateName == currentIconName {
                                Image(systemName: "checkmark")
                                    .font(.headline.bold())
                                    .foregroundStyle(Color.accentColor)
                                    .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("iOS will briefly show an \"App Icon Changed\" alert when you switch.")
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't change icon", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func iconPreview(_ name: String) -> some View {
        if let image = UIImage(named: name) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
                }
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "questionmark")
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func select(_ option: AppIconOption) {
        guard option.alternateName != currentIconName else { return }
        UIApplication.shared.setAlternateIconName(option.alternateName) { error in
            Task { @MainActor in
                if let error {
                    errorMessage = error.localizedDescription
                } else {
                    let animation: Animation? = reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75)
                    withAnimation(animation) {
                        currentIconName = option.alternateName
                    }
                    showToast(.success("App icon changed"))
                }
            }
        }
    }

    private func prettify(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "AppIcon-", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}
