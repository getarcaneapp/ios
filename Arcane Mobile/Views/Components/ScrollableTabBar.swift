import SwiftUI

struct ScrollableTabOption<Selection: Hashable>: Identifiable {
    let value: Selection
    let title: String
    let systemImage: String
    let tint: Color

    var id: Selection { value }

    init(
        _ value: Selection,
        title: String,
        systemImage: String,
        tint: Color = .accentColor
    ) {
        self.value = value
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }
}

struct ScrollableTabBar<Selection: Hashable>: View {
    @Binding private var selection: Selection
    private let options: [ScrollableTabOption<Selection>]
    private let accessibilityLabel: String
    private let addsHorizontalContentInset: Bool

    init(
        selection: Binding<Selection>,
        options: [ScrollableTabOption<Selection>],
        accessibilityLabel: String,
        addsHorizontalContentInset: Bool = true
    ) {
        _selection = selection
        self.options = options
        self.accessibilityLabel = accessibilityLabel
        self.addsHorizontalContentInset = addsHorizontalContentInset
    }

    var body: some View {
        ScrollView(.horizontal) {
            optionRow
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var optionRow: some View {
        if addsHorizontalContentInset {
            optionsStack
                .padding(.horizontal)
        } else {
            optionsStack
        }
    }

    private var optionsStack: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                optionButton(option)
            }
        }
    }

    private func optionButton(_ option: ScrollableTabOption<Selection>) -> some View {
        let isSelected = selection == option.value

        return Button {
            selection = option.value
        } label: {
            HStack(spacing: 7) {
                Image(systemName: option.systemImage)
                    .foregroundStyle(option.tint)
                Text(option.title)
                    .foregroundStyle(isSelected ? option.tint : Color.primary)
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isSelected ? option.tint.opacity(0.15) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: Radius.standard, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.standard, style: .continuous)
                    .stroke(isSelected ? option.tint.opacity(0.45) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
