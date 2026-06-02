import SwiftUI
import Arcane

struct ImageVulnerabilitiesView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let imageID: String
    let imageDisplayName: String
    let environmentID: EnvironmentID

    @State private var status: ScannerStatus?
    @State private var summary: ScanSummary?
    @State private var vulnerabilities: [VulnerabilityRecord] = []
    @State private var ignoredById: [String: IgnoredVulnerability] = [:]
    @State private var selectedSeverities: Set<VulnerabilitySeverity> = []
    @State private var showIgnored = false
    @State private var isLoading = false
    @State private var isScanning = false
    @State private var page = 1
    @State private var hasMore = false
    @State private var errorMessage: String?
    @State private var ignoreTarget: VulnerabilityRecord?
    @State private var unignoreId: String?

    private var isAdmin: Bool { manager.currentUser?.isAdmin == true }

    private func ignoreKey(_ v: VulnerabilityRecord) -> String {
        "\(v.vulnerabilityId)|\(v.pkgName)|\(v.installedVersion ?? "")"
    }

    private var filtered: [VulnerabilityRecord] {
        vulnerabilities.filter { v in
            let isIgnored = ignoredById[ignoreKey(v)] != nil
            return showIgnored || !isIgnored
        }
    }

    var body: some View {
        Group {
            if let status, !status.available {
                scannerUnavailableView(status: status)
            } else {
                scanList
            }
        }
        .navigationTitle("Vulnerabilities")
        .navigationBarTitleDisplayMode(.inline)
        .task { await initialLoad() }
        .refreshable { await reload() }
        .sheet(item: $ignoreTarget) { target in
            IgnoreVulnerabilitySheet(
                vulnerability: target,
                imageID: imageID,
                environmentID: environmentID
            ) { newRecord in
                ignoredById[ignoreKey(target)] = newRecord
            }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var scanList: some View {
        List {
            if let summary {
                Section("Summary") {
                    SeveritySummaryRow(summary: summary.summary, scanTime: summary.scanTime, status: summary.status, error: summary.error)
                }
            }

            Section {
                ForEach(VulnerabilitySeverity.allCases) { sev in
                    Toggle(isOn: bindingForSeverity(sev)) {
                        HStack {
                            SeverityBadge(severity: sev)
                            Text(sev.displayLabel)
                        }
                    }
                }
                Toggle("Show Ignored", isOn: $showIgnored)
            } header: {
                Text("Filters")
            }

            Section {
                Button {
                    Task { await runScan() }
                } label: {
                    HStack {
                        Label(isScanning ? "Scanning…" : "Re-scan now", systemImage: "magnifyingglass")
                        Spacer()
                        if isScanning { ProgressView().scaleEffect(0.8) }
                    }
                }
                .disabled(isScanning)
            } footer: {
                Text("Re-runs Trivy against this image.")
            }

            if filtered.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No vulnerabilities",
                    systemImage: "checkmark.shield",
                    description: Text(summary == nil ? "Run a scan to see results." : "Nothing matches the current filter.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section("Findings (\(filtered.count))") {
                    ForEach(filtered) { vuln in
                        NavigationLink(destination: VulnerabilityDetailView(record: vuln, ignoreInfo: ignoredById[ignoreKey(vuln)])) {
                            VulnerabilityRow(record: vuln, isIgnored: ignoredById[ignoreKey(vuln)] != nil)
                        }
                        .swipeActions(edge: .trailing) {
                            if isAdmin {
                                if let ignore = ignoredById[ignoreKey(vuln)] {
                                    Button {
                                        Task { await unignore(ignoreId: ignore.id, key: ignoreKey(vuln)) }
                                    } label: {
                                        Label("Unignore", systemImage: "eye")
                                    }
                                    .tint(Color.accentColor)
                                } else {
                                    Button {
                                        ignoreTarget = vuln
                                    } label: {
                                        Label("Ignore", systemImage: "eye.slash")
                                    }
                                    .tint(.gray)
                                }
                            }
                        }
                    }

                    if hasMore {
                        Button("Load More") {
                            Task { await loadMore() }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func bindingForSeverity(_ sev: VulnerabilitySeverity) -> Binding<Bool> {
        Binding(
            get: { selectedSeverities.contains(sev) },
            set: { isOn in
                if isOn { selectedSeverities.insert(sev) }
                else { selectedSeverities.remove(sev) }
                Task { await reload() }
            }
        )
    }

    private func scannerUnavailableView(status: ScannerStatus) -> some View {
        ContentUnavailableView {
            Label("Scanner unavailable", systemImage: "shield.slash")
        } description: {
            Text("Trivy is not installed or reachable on the host. Install Trivy and reload to scan images.")
        } actions: {
            Button("Reload") { Task { await initialLoad() } }
        }
    }

    private func initialLoad() async {
        await loadStatus()
        if status?.available == true {
            await reload()
        }
    }

    private func reload() async {
        page = 1
        vulnerabilities = []
        await loadSummary()
        await loadVulnerabilities()
    }

    private func loadStatus() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "vulnerabilities/scanner-status")
            status = try await client.rest.get(path)
        } catch {
            // Treat as unavailable.
            status = ScannerStatus(available: false, version: nil)
        }
    }

    private func loadSummary() async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "images/\(imageID)/vulnerabilities/summary")
            summary = try await client.rest.get(path)
        } catch {
            // Likely 404 (no scan yet) — leave summary nil.
            summary = nil
        }
    }

    private func loadVulnerabilities() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let path = client.rest.environmentPath(environmentID, "images/\(imageID)/vulnerabilities/list")
            var query: [URLQueryItem] = [
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "limit", value: "50")
            ]
            if !selectedSeverities.isEmpty {
                let sev = selectedSeverities.map(\.rawValue).joined(separator: ",")
                query.append(URLQueryItem(name: "severity", value: sev))
            }
            let items: [VulnerabilityRecord] = try await client.rest.get(path, query: query)
            vulnerabilities.append(contentsOf: items)
            hasMore = items.count == 50
        } catch {
            // Empty list / not yet scanned — silent.
        }
    }

    private func loadMore() async {
        page += 1
        await loadVulnerabilities()
    }

    private func runScan() async {
        guard let client = manager.client else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let path = client.rest.environmentPath(environmentID, "images/\(imageID)/vulnerabilities/scan")
            let _: ScanResult = try await client.rest.post(path, body: String?.none)
            await reload()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }

    private func unignore(ignoreId: String, key: String) async {
        guard let client = manager.client else { return }
        do {
            let path = client.rest.environmentPath(environmentID, "vulnerabilities/ignore/\(ignoreId)")
            let _: AnyDecodableMessage = try await client.rest.delete(path)
            ignoredById.removeValue(forKey: key)
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

// MARK: - Row + helper views

struct VulnerabilityRow: View {
    let record: VulnerabilityRecord
    let isIgnored: Bool

    var body: some View {
        HStack(spacing: 12) {
            SeverityBadge(severity: record.severityValue)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.vulnerabilityId)
                    .font(.subheadline.bold())
                    .strikethrough(isIgnored)
                Text(record.pkgName + (record.installedVersion.map { " · \($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let fixed = record.fixedVersion, !fixed.isEmpty {
                    Text("Fixed in \(fixed)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            if isIgnored {
                Text("Ignored")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
            } else if let cvss = record.cvss?.preferredScore {
                Text(String(format: "%.1f", cvss))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SeverityBadge: View {
    let severity: VulnerabilitySeverity

    private var color: Color {
        switch severity {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .unknown: return .gray
        }
    }

    private var letter: String {
        switch severity {
        case .critical: return "C"
        case .high: return "H"
        case .medium: return "M"
        case .low: return "L"
        case .unknown: return "?"
        }
    }

    var body: some View {
        Text(letter)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color, in: Circle())
    }
}

struct SeveritySummaryRow: View {
    let summary: SeveritySummary?
    let scanTime: String?
    let status: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let summary {
                HStack(spacing: 12) {
                    sevPill("Critical", count: summary.critical, color: .red)
                    sevPill("High", count: summary.high, color: .orange)
                    sevPill("Med", count: summary.medium, color: .yellow)
                    sevPill("Low", count: summary.low, color: .blue)
                    sevPill("?", count: summary.unknown, color: .gray)
                }
            }
            HStack {
                Text("Status: \(status.capitalized)").font(.caption2).foregroundStyle(.secondary)
                if let scanTime, !scanTime.isEmpty {
                    Text("·").foregroundStyle(.secondary)
                    Text(scanTime).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func sevPill(_ label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(count)").font(.caption.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct VulnerabilityDetailView: View {
    let record: VulnerabilityRecord
    let ignoreInfo: IgnoredVulnerability?

    var body: some View {
        List {
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

            if let ignore = ignoreInfo {
                Section("Ignored") {
                    if let reason = ignore.reason, !reason.isEmpty {
                        LabeledContent("Reason", value: reason)
                    }
                    if let by = ignore.createdBy { LabeledContent("By", value: by) }
                    if let when = ignore.createdAt { LabeledContent("When", value: when) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(record.vulnerabilityId)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct IgnoreVulnerabilitySheet: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let vulnerability: VulnerabilityRecord
    let imageID: String
    let environmentID: EnvironmentID
    let onIgnored: (IgnoredVulnerability) -> Void

    @State private var reason: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Vulnerability") {
                    LabeledContent("ID", value: vulnerability.vulnerabilityId)
                    LabeledContent("Package", value: vulnerability.pkgName)
                }

                Section {
                    FormTextField(
                        title: "Reason",
                        placeholder: "Optional",
                        text: $reason,
                        axis: .vertical,
                        lineLimit: 2...5
                    )
                } footer: {
                    Text("Why this CVE is acceptable for this image (e.g. \"not exploitable in our usage\").")
                }

                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Ignore CVE")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Ignore", role: .destructive) { Task { await save() } }
                    }
                }
            }
        }
    }

    private func save() async {
        guard let client = manager.client else { return }
        isSaving = true
        defer { isSaving = false }
        let body = IgnoreVulnerabilityRequest(
            imageId: imageID,
            vulnerabilityId: vulnerability.vulnerabilityId,
            pkgName: vulnerability.pkgName,
            installedVersion: vulnerability.installedVersion,
            reason: reason.isEmpty ? nil : reason
        )
        do {
            let path = client.rest.environmentPath(environmentID, "vulnerabilities/ignore")
            let result: IgnoredVulnerability = try await client.rest.post(path, body: body)
            onIgnored(result)
            dismiss()
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

// Empty-message decoder used for endpoints that return `{success: true}` with no useful data.
nonisolated struct AnyDecodableMessage: Decodable, Sendable {
    init(from decoder: any Decoder) throws {}
}
