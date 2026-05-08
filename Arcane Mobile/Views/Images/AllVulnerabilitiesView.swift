import SwiftUI
import Arcane

struct AllVulnerabilitiesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID

    @State private var summary: EnvironmentVulnerabilitySummary?
    @State private var items: [VulnerabilityWithImage] = []
    @State private var imageOptions: [String] = []
    @State private var selectedSeverities: Set<VulnerabilitySeverity> = []
    @State private var selectedImage: String?
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var showFilterSheet = false
    @State private var errorMessage: String?

    private var filterCount: Int {
        selectedSeverities.count + (selectedImage == nil ? 0 : 1)
    }

    var body: some View {
        List {
            Section {
                summaryCard
            } header: {
                Text("Environment Summary")
            }

            if !items.isEmpty {
                Section("Findings") {
                    ForEach(items) { item in
                        NavigationLink(destination: VulnerabilityWithImageDetailView(record: item)) {
                            VulnerabilityWithImageRow(item: item)
                        }
                    }
                    if hasMore {
                        Button("Load More") { Task { await loadMore() } }
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            } else if !isLoading {
                ContentUnavailableView("No vulnerabilities", systemImage: "checkmark.shield",
                                       description: Text("Either no images have been scanned, or all findings have been filtered out."))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("All Vulnerabilities")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showFilterSheet = true
                } label: {
                    Image(systemName: filterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            filterSheet
        }
        .task {
            await loadInitial()
        }
        .refreshable { await reload() }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        if let summary {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    metric("Images", value: "\(summary.totalImages)", color: .secondary)
                    Spacer()
                    metric("Scanned", value: "\(summary.scannedImages)", color: .blue)
                    if let s = summary.summary {
                        Spacer()
                        metric("Total CVEs", value: "\(s.total)", color: s.total > 0 ? .orange : .secondary)
                    }
                }
                if let s = summary.summary {
                    HStack(spacing: 12) {
                        sevPill("Critical", count: s.critical, color: .red)
                        sevPill("High", count: s.high, color: .orange)
                        sevPill("Med", count: s.medium, color: .yellow)
                        sevPill("Low", count: s.low, color: .blue)
                        sevPill("?", count: s.unknown, color: .gray)
                    }
                }
            }
            .padding(.vertical, 4)
        } else {
            HStack { ProgressView().scaleEffect(0.8); Text("Loading…").foregroundStyle(.secondary) }
        }
    }

    private func metric(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func sevPill(_ label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(count)").font(.caption.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section("Severity") {
                    ForEach(VulnerabilitySeverity.allCases) { sev in
                        Toggle(isOn: bindingForSeverity(sev)) {
                            HStack { SeverityBadge(severity: sev); Text(sev.displayLabel) }
                        }
                    }
                }
                if !imageOptions.isEmpty {
                    Section("Image") {
                        Picker("Image", selection: $selectedImage) {
                            Text("All").tag(String?.none)
                            ForEach(imageOptions, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        selectedSeverities = []
                        selectedImage = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showFilterSheet = false
                        Task { await reload() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func bindingForSeverity(_ sev: VulnerabilitySeverity) -> Binding<Bool> {
        Binding(
            get: { selectedSeverities.contains(sev) },
            set: { isOn in
                if isOn { selectedSeverities.insert(sev) }
                else { selectedSeverities.remove(sev) }
            }
        )
    }

    private func loadInitial() async {
        await loadSummary()
        await loadImageOptions()
        await reload()
    }

    private func reload() async {
        page = 1
        items = []
        await loadItems()
    }

    private func loadSummary() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "vulnerabilities/summary")
            summary = try await client.rest.get(path)
        } catch {
            // Best effort.
        }
    }

    private func loadImageOptions() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "vulnerabilities/image-options")
            var query: [URLQueryItem] = []
            if !selectedSeverities.isEmpty {
                query.append(URLQueryItem(name: "severity", value: selectedSeverities.map(\.rawValue).joined(separator: ",")))
            }
            imageOptions = try await client.rest.get(path, query: query)
        } catch {
            imageOptions = []
        }
    }

    private func loadItems() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "vulnerabilities/all")
            var query: [URLQueryItem] = [
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "limit", value: "50")
            ]
            if !selectedSeverities.isEmpty {
                query.append(URLQueryItem(name: "severity", value: selectedSeverities.map(\.rawValue).joined(separator: ",")))
            }
            if let img = selectedImage {
                query.append(URLQueryItem(name: "imageName", value: img))
            }
            let newItems: [VulnerabilityWithImage] = try await client.rest.get(path, query: query)
            items.append(contentsOf: newItems)
            hasMore = newItems.count == 50
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func loadMore() async {
        page += 1
        await loadItems()
    }
}

struct VulnerabilityWithImageRow: View {
    let item: VulnerabilityWithImage

    var body: some View {
        HStack(spacing: 12) {
            SeverityBadge(severity: item.severityValue)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.vulnerabilityId).font(.subheadline.bold())
                Text(item.imageName).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                Text(item.pkgName + (item.installedVersion.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let cvss = item.cvss?.preferredScore {
                Text(String(format: "%.1f", cvss)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct VulnerabilityWithImageDetailView: View {
    let record: VulnerabilityWithImage

    var body: some View {
        List {
            Section("Image") {
                LabeledContent("Name", value: record.imageName)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ID").font(.caption).foregroundStyle(.secondary)
                    Text(record.imageId)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                LabeledContent("ID", value: record.vulnerabilityId)
                LabeledContent("Severity", value: record.severityValue.displayLabel)
                LabeledContent("Package", value: record.pkgName)
                if let v = record.installedVersion { LabeledContent("Installed", value: v) }
                if let v = record.fixedVersion, !v.isEmpty { LabeledContent("Fixed in", value: v) }
                if let cvss = record.cvss?.preferredScore { LabeledContent("CVSS", value: String(format: "%.1f", cvss)) }
                if let date = record.publishedDate { LabeledContent("Published", value: date) }
                if let date = record.lastModifiedDate { LabeledContent("Modified", value: date) }
            }

            if let title = record.title, !title.isEmpty {
                Section("Title") { Text(title) }
            }
            if let description = record.description, !description.isEmpty {
                Section("Description") { Text(description) }
            }
            if let refs = record.references, !refs.isEmpty {
                Section("References") {
                    ForEach(refs, id: \.self) { ref in
                        Text(ref).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(record.vulnerabilityId)
        .navigationBarTitleDisplayMode(.inline)
    }
}
