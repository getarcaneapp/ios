import Arcane
import SwiftUI

struct AllVulnerabilitiesView: View {
    private static let pageSize = 50

    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(EnvironmentsStore.self) private var environmentsStore
    let environmentID: EnvironmentID
    /// All Environments preview: Findings lists vulnerabilities from every
    /// enabled environment; Overview shows the environment chosen in the toolbar.
    var allEnvironments = false

    @State private var list = EnvironmentPagedList<Arcane.VulnerabilityWithImage>(pageSize: Self.pageSize)
    @State private var overview: VulnerabilityRiskOverview?
    @State private var overviewError: String?
    @State private var summary: Arcane.EnvironmentVulnerabilitySummary?
    @State private var imageOptions: [String] = []
    @State private var selectedSeverities: Set<VulnerabilitySeverity> = []
    @State private var selectedImage: String?
    @State private var onlyFixAvailable = false
    @State private var environmentFilter: EnvironmentID?
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var showFilterSheet = false
    @State private var errorMessage: String?
    @State private var focusedVulnerabilityID: String?
    @State private var selectedSection: SecuritySection = .overview
    @State private var chosenEnvironmentID: EnvironmentID?
    @State private var patchEnvironmentID: EnvironmentID?
    @State private var displayedItems: [EnvironmentItem<Arcane.VulnerabilityWithImage>] = []

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

    private var items: [EnvironmentItem<Arcane.VulnerabilityWithImage>] { list.items }

    /// The environments this list covers, known before the first load finishes.
    private var listEnvironments: [ListEnvironment] {
        allEnvironments ? list.environments : [ListEnvironment(id: environmentID, name: nil)]
    }

    /// The risk overview is scored per environment, so All Environments shows
    /// the environment chosen in the toolbar.
    private var overviewEnvironmentID: EnvironmentID {
        allEnvironments ? chosenEnvironmentID ?? environmentID : environmentID
    }

    private var overviewEnvironmentSelection: Binding<EnvironmentID> {
        Binding(
            get: { overviewEnvironmentID },
            set: { newValue in
                guard newValue != overviewEnvironmentID else { return }
                chosenEnvironmentID = newValue
                overview = nil
                overviewError = nil
                summary = nil
                Task { await loadOverviewSection() }
            }
        )
    }

    private var filterCount: Int {
        selectedSeverities.count + (selectedImage == nil ? 0 : 1) + (onlyFixAvailable ? 1 : 0)
            + (environmentFilter == nil ? 0 : 1)
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
                            environmentID: overviewEnvironmentID,
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
                    EnvironmentLoadFailuresSection(failures: list.failedEnvironments) {
                        Task { await reload() }
                    }

                    if let focusedVulnerabilityID {
                        Section {
                            HStack {
                                Text("Showing \(focusedVulnerabilityID)")
                                Spacer()
                                Button("Clear") {
                                    self.focusedVulnerabilityID = nil
                                    clearItems()
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

                    if !displayedItems.isEmpty {
                        Section("Findings") {
                            ForEach(displayedItems) { item in
                                NavigationLink(
                                    destination: VulnerabilityWithImageDetailView(record: item.value)
                                ) {
                                    VulnerabilityWithImageRow(item: item.value, environmentName: item.environmentName)
                                        .rowEnvironment(item)
                                }
                            }
                            PaginatedListFooter(
                                hasMore: list.hasMore, loadMoreError: list.loadMoreError,
                                onRetry: { Task { await loadMore() } },
                                onLoadMore: { Task { await loadMore() } }
                            )
                        }
                    } else if !list.isLoading {
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
            if allEnvironments {
                if manager.supportsActivities {
                    AppToolbarItem(placement: .topBarTrailing) {
                        EnvironmentActionButton(
                            title: "Patch images",
                            systemImage: "wrench.and.screwdriver",
                            environments: listEnvironments.filter {
                                manager.permissions.has("vulnerabilities:read", in: $0.id)
                            }
                        ) { environmentID in
                            patchEnvironmentID = environmentID
                        }
                    }
                }
            } else if manager.permissions.has("vulnerabilities:read", in: environmentID), manager.supportsActivities {
                AppToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ImagePatchTargetsView(environmentID: environmentID)
                    } label: {
                        Image(systemName: "wrench.and.screwdriver")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Patch images")
                }
            }
            if allEnvironments, selectedSection == .overview {
                AppToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Environment", selection: overviewEnvironmentSelection) {
                            ForEach(environmentsStore.enabledEnvironments, id: \.id) { environment in
                                Text(environment.displayName).tag(EnvironmentID(rawValue: environment.id))
                            }
                        }
                    } label: {
                        Image(systemName: "server.rack")
                            .appAccentToolbarSymbol()
                    }
                    .accessibilityLabel("Environment")
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
                    if allEnvironments {
                        // The export endpoint is per environment, so the user picks one.
                        EnvironmentActionButton(
                            title: "Export CSV",
                            systemImage: "square.and.arrow.up",
                            environments: listEnvironments.filter { environment in
                                items.contains { $0.environmentID == environment.id }
                            }
                        ) { environmentID in
                            Task { await exportCSV(environmentID) }
                        }
                        .disabled(isExporting || items.isEmpty)
                    } else {
                        Button {
                            Task { await exportCSV(environmentID) }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .appAccentToolbarSymbol()
                        }
                        .accessibilityLabel("Export vulnerabilities as CSV")
                        .disabled(isExporting || items.isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: $showFilterSheet) {
            filterSheet
        }
        .navigationDestination(item: $patchEnvironmentID) { environmentID in
            ImagePatchTargetsView(environmentID: environmentID)
        }
        .task(id: environmentID) {
            overview = nil
            summary = nil
            chosenEnvironmentID = nil
            clearItems()
            focusedVulnerabilityID = nil
            await loadInitial()
        }
        .onChange(of: environmentFilter) { rebuildDisplayedItems() }
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
                EnvironmentFilterSection(environments: list.environments, selection: $environmentFilter)
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
                        environmentFilter = nil
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
        async let overview: Void = loadOverviewSection()
        async let options: Void = loadImageOptions()
        async let items: Void = reload()
        await overview
        await options
        await items
    }

    private func loadOverviewSection() async {
        async let overview: Void = loadOverview()
        async let summary: Void = loadSummary()
        await overview
        await summary
    }

    private func showVulnerability(_ id: String) {
        selectedSeverities = []
        selectedImage = nil
        onlyFixAvailable = false
        focusedVulnerabilityID = id
        clearItems()
        selectedSection = .findings
        Task { await reload() }
    }

    private func clearItems() {
        list.update { $0.removeAll() }
        rebuildDisplayedItems()
    }

    private func rebuildDisplayedItems() {
        displayedItems = items.filter { environmentFilter == nil || $0.environmentID == environmentFilter }
    }

    private func reload() async {
        guard let client = manager.client else { return }
        let environments = await environmentsStore.listEnvironments(
            environmentID, allEnvironments: allEnvironments, manager: manager)
        await list.reload(environments, fetch: findingsPage(client: client))
        rebuildDisplayedItems()
        if let error = list.errorMessage { errorMessage = error }
    }

    private func loadMore() async {
        guard let client = manager.client else { return }
        await list.loadMore(fetch: findingsPage(client: client))
        rebuildDisplayedItems()
    }

    private var severityQuery: String? {
        selectedSeverities.isEmpty ? nil : selectedSeverities.map(\.rawValue).joined(separator: ",")
    }

    private func findingsPage(client: ArcaneClient) -> EnvironmentPagedList<Arcane.VulnerabilityWithImage>.Fetch {
        let search = focusedVulnerabilityID
        let severity = severityQuery
        let imageName = selectedImage
        let fixAvailable: Bool? = onlyFixAvailable ? true : nil
        return { environmentID, start, limit in
            let response = try await client.vulnerabilities.listAll(
                envID: environmentID,
                query: SearchPaginationSort(search: search, start: start, limit: limit),
                severity: severity,
                imageName: imageName,
                fixAvailable: fixAvailable
            )
            return ResourcePage(items: response.data, pagination: response.pagination)
        }
    }

    private func loadOverview() async {
        guard manager.supportsActivities, let client = manager.client else { return }
        let target = overviewEnvironmentID
        do {
            let response = try await client.vulnerabilities.riskOverview(envID: target)
            guard target == overviewEnvironmentID else { return }
            overview = response
            overviewError = nil
        } catch ArcaneError.notFound {
            guard target == overviewEnvironmentID else { return }
            overview = nil
            overviewError = nil
        } catch {
            guard target == overviewEnvironmentID else { return }
            overview = nil
            overviewError = "Risk overview unavailable: \(friendlyErrorMessage(error))"
        }
    }

    private func loadSummary() async {
        guard let client = manager.client else { return }
        let target = overviewEnvironmentID
        do {
            let response = try await client.vulnerabilities.environmentSummary(envID: target)
            guard target == overviewEnvironmentID else { return }
            summary = response
        } catch {
            // Best effort.
        }
    }

    /// All Environments merges every environment's image names.
    private func loadImageOptions() async {
        guard let client = manager.client else { return }
        let environments = await environmentsStore.listEnvironments(
            environmentID, allEnvironments: allEnvironments, manager: manager)
        let severity = severityQuery
        let options = await withTaskGroup(of: [String]?.self) { group in
            for environment in environments {
                group.addTask {
                    try? await client.vulnerabilities.imageOptions(envID: environment.id, severity: severity)
                }
            }
            var merged: [[String]] = []
            for await result in group {
                if let result { merged.append(result) }
            }
            return merged
        }
        imageOptions =
            environments.count == 1
            ? options.first ?? []
            : Array(Set(options.joined())).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func exportCSV(_ environmentID: EnvironmentID) async {
        guard let client = manager.client else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await client.vulnerabilities.exportAll(
                envID: environmentID,
                search: focusedVulnerabilityID,
                severity: severityQuery,
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
    var environmentName: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            SeverityBadge(severity: item.mobileSeverity)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.vulnerabilityId).font(.subheadline.bold())
                Text(item.imageName).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                Text(item.pkgName + (item.installedVersion.isEmpty ? "" : " · \(item.installedVersion)"))
                    .font(.caption).foregroundStyle(.secondary)
                EnvironmentLabel(name: environmentName)
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

extension Arcane.VulnerabilityWithImage: @retroactive Identifiable {
    /// One package version's finding in one image.
    nonisolated public var id: String { "\(imageId)|\(vulnerabilityId)|\(pkgName)|\(installedVersion)" }
}

extension Arcane.VulnerabilityWithImage {
    fileprivate var mobileSeverity: VulnerabilitySeverity {
        VulnerabilitySeverity(rawValue: severity.rawValue) ?? .unknown
    }

    fileprivate var preferredCVSS: Double? {
        cvss?.v3Score ?? cvss?.v2Score
    }
}
