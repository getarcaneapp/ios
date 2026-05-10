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
        ForEach(sections.filter { !$0.items.isEmpty }, id: \.id) { section in
            Section {
                ForEach(section.items) { item in
                    rowContent(item)
                }
            } header: {
                if let title = section.title {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                }
            }
        }
    }
}
