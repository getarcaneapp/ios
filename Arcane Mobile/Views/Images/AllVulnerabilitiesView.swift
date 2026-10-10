import Arcane
import SwiftUI

struct AllVulnerabilitiesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let environmentID: EnvironmentID

    @State private var loadMoreError: String?
    @State private var overview: VulnerabilityRiskOverview?
    @State private var overviewError: String?
    @State private var summary: Arcane.EnvironmentVulnerabilitySummary?
    @State private var items: [Arcane.VulnerabilityWithImage] = []
    @State private var imageOptions: [String] = []
    @State private var selectedSeverities: Set<VulnerabilitySeverity> = []
    @State private var selectedImage: String?
    @State private var onlyFixAvailable = false
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var page = 1
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var showFilterSheet = false
    @State private var errorMessage: String?
    @State private var focusedVulnerabilityID: String?
    @State private var selectedSection: SecuritySection = .overview

    private enum SecuritySection: String, CaseIterable {
        case overview = "Overview"
        case findings = "Findings"

        var systemImage: String {
            switch self {
            case .overview: "shield.lefthalf.filled"
            case .findings: "list.bullet"
            }
        }

        var tint: Color {
            switch self {
            case .overview: .accentColor
            case .findings: .orange
            }
        }
    }

    private var filterCount: Int {
        selectedSeverities.count + (selectedImage == nil ? 0 : 1) + (onlyFixAvailable ? 1 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollableTabBar(
                selection: $selectedSection,
                options: SecuritySection.allCases.map {
                    ScrollableTabOption(
                        $0,
                        title: $0.rawValue,
                        systemImage: $0.systemImage,
                        tint: $0.tint
                    )
                },
                accessibilityLabel: "Security sections"
            )

            List {
                if selectedSection == .overview {
                    if let overview {
                        SecurityOverviewView(
                            overview: overview,
                            environmentID: environmentID,
                            selectVulnerability: showVulnerability
                        )
                    } else {
                        Section("Environment summary") {
                            summaryCard
                            if let overviewError {
                                Text(overviewError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    if let focusedVulnerabilityID {
                        Section {
                            HStack {
                                Text("Showing \(focusedVulnerabilityID)")
                                Spacer()
                                Button("Clear") {
                                    self.focusedVulnerabilityID = nil
                                    items = []
                                    Task { await reload() }
                                }
                            }
                        }
                    }

                    if let exportURL {
                        Section {
                            ShareLink("Share exported CSV", item: exportURL)
                        }
                    }

                    if !items.isEmpty {
                        Section("Findings") {
                            ForEach(items, id: \.self) { item in
                                NavigationLink(destination: VulnerabilityWithImageDetailView(record: item)) {
                                    VulnerabilityWithImageRow(item: item)
                                }
                            }
                            PaginatedListFooter(
                                hasMore: hasMore, loadMoreError: loadMoreError,
                                onRetry: { Task { await loadMore() } },
                                onLoadMore: { Task { await loadMore() } }
                            )
                        }
                    } else if !isLoading {
                        ContentUnavailableView(
                            "No vulnerabilities", systemImage: "checkmark.shield",
                            description: Text(
                                "Either no images have been scanned, or all findings have been filtered out.")
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await loadInitial() }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if manager.permissions.has("vulnerabilities:read", in: environmentID), manager.supportsActivities {
                AppToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ImagePatchTargetsView(environmentID: environmentID)
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Patch images")
                }
                if #available(iOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
            }
            if selectedSection == .findings {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showFilterSheet = true
                    } label: {
                        Image(
                            systemName: filterCount > 0
                                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                        )
                        .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Filter vulnerabilities")
                }
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await exportCSV() }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Export vulnerabilities as CSV")
                    .disabled(isExporting || items.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            filterSheet
        }
        .task(id: environmentID) {
            overview = nil
            summary = nil
            items = []
            focusedVulnerabilityID = nil
            await loadInitial()
        }
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
                    metric("Scanned", value: "\(summary.scannedImages)", color: Color.accentColor)
                    if let s = summary.summary {
                        Spacer()
                        metric("Total CVEs", value: "\(s.total)", color: s.total > 0 ? .orange : .secondary)
                    }
                }
                if let s = summary.summary {
                    SeverityBar(
                        critical: s.critical,
                        high: s.high,
                        medium: s.medium,
                        low: s.low,
                        unknown: s.unknown
                    )
                }
            }
            .padding(.vertical, 4)
        } else {
            HStack {
                ProgressView().scaleEffect(0.8)
                Text("Loading…").foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section("Severity") {
                    ForEach(VulnerabilitySeverity.allCases) { sev in
                        Toggle(isOn: bindingForSeverity(sev)) {
                            HStack {
                                SeverityBadge(severity: sev)
                                Text(sev.displayLabel)
                            }
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
                Section("Options") {
                    Toggle("Only with fix available", isOn: $onlyFixAvailable)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        selectedSeverities = []
                        selectedImage = nil
                        onlyFixAvailable = false
                    }
                }
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showFilterSheet = false
                        Task { await reload() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func bindingForSeverity(_ sev: VulnerabilitySeverity) -> Binding<Bool> {
        Binding(
            get: { selectedSeverities.contains(sev) },
            set: { isOn in
                if isOn { selectedSeverities.insert(sev) } else { selectedSeverities.remove(sev) }
            }
        )
    }

    private func loadInitial() async {
        // Overview, summary, filter options, and findings are independent.
        async let overview: Void = loadOverview()
        async let summary: Void = loadSummary()
        async let options: Void = loadImageOptions()
        async let items: Void = reload()
        await overview
        await summary
        await options
        await items
    }

    private func showVulnerability(_ id: String) {
        selectedSeverities = []
        selectedImage = nil
        onlyFixAvailable = false
        focusedVulnerabilityID = id
        items = []
        selectedSection = .findings
        Task { await reload() }
    }

    private func reload() async {
        page = 1
        await loadItems()
    }

    private func loadOverview() async {
        guard manager.supportsActivities, let client = manager.client else { return }
        do {
            overview = try await client.vulnerabilities.riskOverview(envID: environmentID)
            overviewError = nil
        } catch ArcaneError.notFound {
            overview = nil
            overviewError = nil
        } catch {
            overview = nil
            overviewError = "Risk overview unavailable: \(friendlyErrorMessage(error))"
        }
    }

    private func loadSummary() async {
        guard let client = manager.client else { return }
        do {
            summary = try await client.vulnerabilities.environmentSummary(envID: environmentID)
        } catch {
            // Best effort.
        }
    }

    private func loadImageOptions() async {
        guard let client = manager.client else { return }
        do {
            imageOptions = try await client.vulnerabilities.imageOptions(
                envID: environmentID,
                severity: selectedSeverities.isEmpty ? nil : selectedSeverities.map(\.rawValue).joined(separator: ",")
            )
        } catch {
            imageOptions = []
        }
    }

    private func loadItems() async {
        guard let client = manager.client else { return }
        loadMoreError = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await client.vulnerabilities.listAll(
                envID: environmentID,
                query: SearchPaginationSort(search: focusedVulnerabilityID, start: (page - 1) * 50, limit: 50),
                severity: selectedSeverities.isEmpty ? nil : selectedSeverities.map(\.rawValue).joined(separator: ","),
                imageName: selectedImage,
                fixAvailable: onlyFixAvailable ? true : nil
            )
            items = page == 1 ? response.data : items + response.data
            hasMore = Int64(page * 50) < response.pagination.totalItems
        } catch {
            if page > 1 {
                loadMoreError = friendlyErrorMessage(error)
            } else {
                errorMessage = friendlyErrorMessage(error)
            }
        }
    }

    private func loadMore() async {
        guard hasMore, !isLoading else { return }
        page += 1
        await loadItems()
        if loadMoreError != nil { page -= 1 }
    }

    private func exportCSV() async {
        guard let client = manager.client else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await client.vulnerabilities.exportAll(
                envID: environmentID,
                search: focusedVulnerabilityID,
                severity: selectedSeverities.isEmpty ? nil : selectedSeverities.map(\.rawValue).joined(separator: ","),
                imageName: selectedImage,
                fixAvailable: onlyFixAvailable ? true : nil
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "vulnerabilities-\(environmentID.rawValue)-\(Int(Date().timeIntervalSince1970)).csv")
            try data.write(to: url, options: .atomic)
            if let old = exportURL { try? FileManager.default.removeItem(at: old) }
            exportURL = url
            showToast(.success("Vulnerabilities exported"))
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

struct VulnerabilityWithImageRow: View {
    let item: Arcane.VulnerabilityWithImage

    var body: some View {
        HStack(spacing: 12) {
            SeverityBadge(severity: item.mobileSeverity)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.vulnerabilityId).font(.subheadline.bold())
                Text(item.imageName).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                Text(item.pkgName + (item.installedVersion.isEmpty ? "" : " · \(item.installedVersion)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let cvss = item.preferredCVSS {
                Text(String(format: "%.1f", cvss)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct VulnerabilityWithImageDetailView: View {
    let record: Arcane.VulnerabilityWithImage

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
                LabeledContent("Severity", value: record.mobileSeverity.displayLabel)
                LabeledContent("Package", value: record.pkgName)
                if !record.installedVersion.isEmpty { LabeledContent("Installed", value: record.installedVersion) }
                if let v = record.fixedVersion, !v.isEmpty { LabeledContent("Fixed in", value: v) }
                if let cvss = record.preferredCVSS { LabeledContent("CVSS", value: String(format: "%.1f", cvss)) }
                if let date = record.publishedDate {
                    LabeledContent("Published", value: date.formatted(date: .abbreviated, time: .omitted))
                }
                if let date = record.lastModifiedDate {
                    LabeledContent("Modified", value: date.formatted(date: .abbreviated, time: .omitted))
                }
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

extension Arcane.VulnerabilityWithImage {
    fileprivate var mobileSeverity: VulnerabilitySeverity {
        VulnerabilitySeverity(rawValue: severity.rawValue) ?? .unknown
    }

    fileprivate var preferredCVSS: Double? {
        cvss?.v3Score ?? cvss?.v2Score
    }
}
