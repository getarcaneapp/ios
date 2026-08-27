import SwiftUI

/// Treats empty API strings as absent without depending on SDK-internal helpers.
func nonEmptyResourceValue(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

struct ResourceMetadataItem: Identifiable {
    let id: String
    let label: String
    let value: String
    var systemImage: String
    var tint: Color = .secondary
    var status: String?
    var monospaced = false

    init(
        id: String? = nil,
        label: String,
        value: String,
        systemImage: String,
        tint: Color = .secondary,
        status: String? = nil,
        monospaced: Bool = false
    ) {
        self.id = id ?? label
        self.label = label
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
        self.status = status
        self.monospaced = monospaced
    }
}

struct AdaptiveMetadataGrid: View {
    let items: [ResourceMetadataItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], spacing: 14) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(item.tint)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if item.monospaced {
                            Text(verbatim: item.value)
                                .font(.subheadline.monospaced().weight(.semibold))
                                .textSelection(.enabled)
                                .lineLimit(2)
                        } else {
                            Text(item.value)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                        }
                        if let status = item.status {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.label): \(item.value)\(item.status.map { ", \($0)" } ?? "")")
            }
        }
        .padding(.vertical, 4)
    }
}

struct MonospacedValue: View {
    let value: String
    var lineLimit: Int? = nil

    var body: some View {
        Text(verbatim: value)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
    }
}

struct PartialDataNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }
}
