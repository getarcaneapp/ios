import Arcane
import SwiftUI

struct FleetResourceFilterSheet: View {
    let kind: FleetResourceKind
    let buckets: [FleetResourceBucket]
    @Binding var filters: FleetResourceFilters
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Environment") {
                    Picker("Environment", selection: $filters.environmentID) {
                        Text("All Environments").tag(String?.none)
                        ForEach(buckets) { bucket in Text(bucket.name).tag(String?.some(bucket.id)) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
                switch kind {
                case .containers:
                    choices("State", selection: $filters.state)
                    updates
                    Section("Visibility") {
                        Toggle("Show hidden", isOn: $filters.showHidden)
                        TextField("Label (key or key=value)", text: $filters.label)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                case .projects:
                    choices("Status", selection: $filters.status)
                    updates
                case .images: choices("Tags", selection: $filters.tags)
                case .networks: choices("Type", selection: $filters.networkType)
                case .volumes: choices("Scope", selection: $filters.scope)
                case .vulnerabilities:
                    Section("Severity") {
                        ForEach(VulnerabilitySeverity.allCases) { severity in
                            Toggle(
                                severity.displayLabel,
                                isOn: Binding(
                                    get: { filters.severities.contains(severity) },
                                    set: {
                                        if $0 {
                                            filters.severities.insert(severity)
                                        } else {
                                            filters.severities.remove(severity)
                                        }
                                    }
                                ))
                        }
                    }
                    Section("Image") {
                        Picker("Image", selection: $filters.image) {
                            Text("All").tag(String?.none)
                            ForEach(imageNames, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                    Section("Options") { Toggle("Only with fix available", isOn: $filters.onlyFixAvailable) }
                default: EmptyView()
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) { Button("Reset") { filters = FleetResourceFilters() } }
                AppToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var imageNames: [String] {
        Array(
            Set(
                buckets.flatMap(\.resources).compactMap { resource -> String? in
                    if case .vulnerability(let item) = resource { return item.imageName }
                    return nil
                })
        ).sorted()
    }

    private var updates: some View {
        Section("Updates") {
            Picker("Updates", selection: $filters.updates) {
                ForEach(ResourceUpdateFilter.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.inline).labelsHidden()
        }
    }

    private func choices<T: RawRepresentable & CaseIterable & Hashable>(_ title: String, selection: Binding<T>)
        -> some View where T.RawValue == String, T.AllCases: RandomAccessCollection
    {
        Section(title) {
            Picker(title, selection: selection) {
                ForEach(T.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.inline).labelsHidden()
        }
    }
}
