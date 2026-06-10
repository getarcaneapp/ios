import SwiftUI
import Arcane

// MARK: - Reusable rows

struct SettingsRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    let color: Color
    var titleColor: Color = .primary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(titleColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

// External-link row with a matching outbound-arrow trailing affordance.
struct SettingsExternalRow: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack {
            SettingsRow(title: title, systemImage: systemImage, color: color, titleColor: .primary)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

// Kept as an alias for any older callers; prefer SettingsRow.
struct SettingsNavigationRow: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        SettingsRow(title: title, systemImage: systemImage, color: color)
    }
}

// MARK: - Users View

