import SwiftUI

struct StableListSection<SectionID: Hashable, Item: Identifiable> {
    let id: SectionID
    let title: String?
    let items: [Item]

    init(id: SectionID, title: String? = nil, items: [Item]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

struct StableSectionedList<SectionID: Hashable, Item: Identifiable, RowContent: View>: View {
    private let sections: [StableListSection<SectionID, Item>]
    private let rowContent: (Item) -> RowContent

    init(_ sections: [StableListSection<SectionID, Item>],
         @ViewBuilder rowContent: @escaping (Item) -> RowContent) {
        self.sections = sections
        self.rowContent = rowContent
    }

    var body: some View {
        ForEach(rows) { row in
            switch row {
            case .header(_, let title):
                sectionHeader(title)
            case .item(_, let item, let position):
                rowContent(item)
                    .listRowBackground(itemBackground(for: position))
            }
        }
    }

    private var rows: [StableSectionedListRow<Item>] {
        var collected: [StableSectionedListRow<Item>] = []

        for section in sections where !section.items.isEmpty {
            if let title = section.title {
                collected.append(.header(id: AnyHashable(section.id), title: title))
            }
            let count = section.items.count
            collected.append(contentsOf: section.items.enumerated().map { index, item in
                .item(
                    id: AnyHashable(item.id),
                    item: item,
                    position: rowPosition(for: index, count: count)
                )
            })
        }

        return collected
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func rowPosition(for index: Int, count: Int) -> StableSectionedListItemPosition {
        if count == 1 {
            return .single
        }
        if index == 0 {
            return .first
        }
        if index == count - 1 {
            return .last
        }
        return .middle
    }

    private func itemBackground(for position: StableSectionedListItemPosition) -> some View {
        UnevenRoundedRectangle(
            cornerRadii: cornerRadii(for: position),
            style: .continuous
        )
        .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func cornerRadii(for position: StableSectionedListItemPosition) -> RectangleCornerRadii {
        let radius: CGFloat = 12
        switch position {
        case .single:
            return RectangleCornerRadii(
                topLeading: radius,
                bottomLeading: radius,
                bottomTrailing: radius,
                topTrailing: radius
            )
        case .first:
            return RectangleCornerRadii(
                topLeading: radius,
                bottomLeading: 0,
                bottomTrailing: 0,
                topTrailing: radius
            )
        case .middle:
            return RectangleCornerRadii()
        case .last:
            return RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: radius,
                bottomTrailing: radius,
                topTrailing: 0
            )
        }
    }
}

private enum StableSectionedListRowID: Hashable {
    case header(AnyHashable)
    case item(AnyHashable)
}

private enum StableSectionedListItemPosition {
    case single
    case first
    case middle
    case last
}

private enum StableSectionedListRow<Item: Identifiable>: Identifiable {
    case header(id: AnyHashable, title: String)
    case item(id: AnyHashable, item: Item, position: StableSectionedListItemPosition)

    var id: StableSectionedListRowID {
        switch self {
        case .header(let id, _):
            .header(id)
        case .item(let id, _, _):
            .item(id)
        }
    }
}
