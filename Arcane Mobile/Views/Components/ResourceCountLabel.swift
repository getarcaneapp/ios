import SwiftUI

struct ResourceCountLabel: View {
    let loadedCount: Int
    let totalCount: Int64?
    let hasMore: Bool

    private var knownTotal: Int64? {
        guard let totalCount, totalCount >= 0 else { return nil }
        return totalCount
    }

    var body: some View {
        Label {
            countText
        } icon: {
            Image(systemName: "list.bullet")
        }
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .textCase(nil)
        .foregroundStyle(.tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12), in: .capsule)
        .overlay {
            Capsule()
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var countText: some View {
        if hasMore, let knownTotal, knownTotal > Int64(loadedCount) {
            Text("\(loadedCount) of \(knownTotal)")
        } else if hasMore {
            Text("\(loadedCount) loaded")
        } else {
            Text("\(loadedCount) \(loadedCount == 1 ? "item" : "items")")
        }
    }

    private var accessibilityText: Text {
        if hasMore, let knownTotal, knownTotal > Int64(loadedCount) {
            return Text("Showing \(loadedCount) of \(knownTotal) items")
        }
        if hasMore {
            return Text("\(loadedCount) \(loadedCount == 1 ? "item" : "items") loaded")
        }
        return Text("\(loadedCount) \(loadedCount == 1 ? "item" : "items")")
    }
}

struct ResourceCountSectionHeader: View {
    let title: String
    let loadedCount: Int
    let totalCount: Int64?
    let hasMore: Bool

    init(
        _ title: String,
        loadedCount: Int,
        totalCount: Int64? = nil,
        hasMore: Bool = false
    ) {
        self.title = title
        self.loadedCount = loadedCount
        self.totalCount = totalCount
        self.hasMore = hasMore
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
            Spacer(minLength: 8)
            ResourceCountLabel(
                loadedCount: loadedCount,
                totalCount: totalCount,
                hasMore: hasMore
            )
        }
        .textCase(nil)
    }
}
