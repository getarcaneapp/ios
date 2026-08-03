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

struct StableSectionedList<
    SectionID: Hashable,
    Item: Identifiable,
    RowContent: View,
    HeaderAccessory: View
>: View {
    private let sections: [StableListSection<SectionID, Item>]
    private let rowContent: (Item) -> RowContent
    private let preferredHeaderAccessorySectionID: SectionID?
    private let headerAccessory: (StableListSection<SectionID, Item>) -> HeaderAccessory

    init(
        _ sections: [StableListSection<SectionID, Item>],
        preferredHeaderAccessorySectionID: SectionID? = nil,
        @ViewBuilder headerAccessory: @escaping (StableListSection<SectionID, Item>) -> HeaderAccessory,
        @ViewBuilder rowContent: @escaping (Item) -> RowContent
    ) {
        self.sections = sections
        self.preferredHeaderAccessorySectionID = preferredHeaderAccessorySectionID
        self.headerAccessory = headerAccessory
        self.rowContent = rowContent
    }

    private var headerAccessorySectionID: SectionID? {
        if let preferredHeaderAccessorySectionID,
           sections.contains(where: {
               $0.id == preferredHeaderAccessorySectionID && !$0.items.isEmpty
           }) {
            return preferredHeaderAccessorySectionID
        }
        return sections.first(where: { !$0.items.isEmpty })?.id
    }

    var body: some View {
        ForEach(sections.filter { !$0.items.isEmpty }, id: \.id) { section in
            Section {
                ForEach(section.items) { item in
                    rowContent(item)
                        .tag(item.id)
                }
            } header: {
                if let title = section.title {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.footnote.weight(.semibold))
                        Spacer(minLength: 8)
                        if section.id == headerAccessorySectionID {
                            headerAccessory(section)
                        }
                    }
                }
            }
        }
    }
}

extension StableSectionedList where HeaderAccessory == EmptyView {
    init(
        _ sections: [StableListSection<SectionID, Item>],
        @ViewBuilder rowContent: @escaping (Item) -> RowContent
    ) {
        self.init(
            sections,
            preferredHeaderAccessorySectionID: nil,
            headerAccessory: { _ in EmptyView() },
            rowContent: rowContent
        )
    }
}
