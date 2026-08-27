import SwiftUI

/// Canonical section header, matching the Dashboard's pattern: a
/// headline-weight secondary title with optional symbol and count. Trailing
/// content (count capsules, action buttons) renders after the title.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var systemImage: String? = nil
    var count: Int? = nil
    @ViewBuilder var trailing: Trailing

    init(
        _ title: String,
        systemImage: String? = nil,
        count: Int? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.trailing = trailing()
    }

    init(_ title: String, systemImage: String? = nil, count: Int? = nil) where Trailing == EmptyView {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.trailing = EmptyView()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let count {
                Text(verbatim: "\(count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 4)
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}
