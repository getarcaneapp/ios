import SwiftUI
import Arcane

/// In-toto attestation browser for an image — the iOS counterpart of the
/// web's attestations panel: filter by predicate type, tap a row for the
/// full details including the statement payload.
struct ImageAttestationsView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    let imageID: String
    let imageDisplayName: String
    let environmentID: EnvironmentID

    @State private var result: ImageAttestationList?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedPredicateType: String?
    @State private var detailAttestation: ImageAttestation?

    private var attestations: [ImageAttestation] {
        let all = result?.attestations ?? []
        guard let selectedPredicateType else { return all }
        return all.filter { $0.predicateType == selectedPredicateType }
    }

    private var predicateTypes: [String] {
        Array(Set((result?.attestations ?? []).map(\.predicateType))).sorted()
    }

    var body: some View {
        Group {
            if isLoading && result == nil {
                SkeletonListLoadingView(rowCount: 3)
            } else if let errorMessage, result == nil {
                ContentUnavailableView {
                    Label("Couldn't Load Attestations", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if attestations.isEmpty && selectedPredicateType == nil {
                ContentUnavailableView {
                    Label("No Attestations", systemImage: "checkmark.seal")
                } description: {
                    Text("This image has no in-toto attestations attached (provenance, SBOM, …).")
                }
            } else {
                List {
                    Section {
                        ForEach(attestations) { attestation in
                            Button {
                                detailAttestation = attestation
                            } label: {
                                row(attestation)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: {
                        if let digest = result?.subjectDigest, !digest.isEmpty {
                            Text("Subject digest: \(digest)")
                                .font(.caption2.monospaced())
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Attestations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if predicateTypes.count > 1 {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Predicate Type", selection: $selectedPredicateType) {
                            Text("All Types").tag(String?.none)
                            ForEach(predicateTypes, id: \.self) { type in
                                Text(shortPredicateName(type)).tag(String?.some(type))
                            }
                        }
                    } label: {
                        Image(systemName: selectedPredicateType == nil
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter by predicate type")
                }
            }
        }
        .sheet(item: $detailAttestation) { attestation in
            NavigationStack {
                ImageAttestationDetailView(
                    attestation: attestation,
                    imageID: imageID,
                    environmentID: environmentID
                )
            }
            .presentationDragIndicator(.visible)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ attestation: ImageAttestation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: attestation.predicateType))
                .font(.title3)
                .foregroundStyle(.indigo)
                .frame(width: 36, height: 36)
                .glassEffectCompat(in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(shortPredicateName(attestation.predicateType))
                    .font(.subheadline.weight(.semibold))
                Text(attestation.predicateType)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let platform = attestation.platform {
                    Text(platform)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(attestation.size.byteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.bold())
                .foregroundStyle(.secondary.opacity(0.5))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Friendly names for well-known predicate type URIs (matches the web).
    private func shortPredicateName(_ type: String) -> String {
        if type.contains("slsa.dev/provenance") { return "SLSA Provenance" }
        if type.contains("spdx") { return "SPDX SBOM" }
        if type.contains("cyclonedx") { return "CycloneDX SBOM" }
        if type.contains("vuln") { return "Vulnerability Scan" }
        return type.components(separatedBy: "/").last?.capitalized ?? type
    }

    private func iconName(for type: String) -> String {
        if type.contains("provenance") { return "checkmark.seal" }
        if type.contains("spdx") || type.contains("cyclonedx") { return "shippingbox" }
        if type.contains("vuln") { return "shield.lefthalf.filled" }
        return "doc.badge.ellipsis"
    }

    private func load() async {
        guard let client = manager.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            result = try await client.images.attestations(envID: environmentID, id: imageID)
            errorMessage = nil
        } catch {
            errorMessage = friendlyErrorMessage(error)
        }
    }
}

/// Detail sheet for one attestation: metadata, subjects, and the full
/// statement JSON (fetched on demand — statement payloads are heavy).
private struct ImageAttestationDetailView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager
    @SwiftUI.Environment(\.dismiss) private var dismiss
    let attestation: ImageAttestation
    let imageID: String
    let environmentID: EnvironmentID

    @State private var statementJSON: String?
    @State private var isLoadingStatement = false
    @State private var statementError: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Type") {
                    Text(attestation.predicateType)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                if let platform = attestation.platform {
                    LabeledContent("Platform", value: platform)
                }
                LabeledContent("Size", value: attestation.size.byteString)
                LabeledContent("Media Type") {
                    Text(attestation.mediaType)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Digest").font(.caption).foregroundStyle(.secondary)
                    Text(attestation.digest)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if let subjects = attestation.subject, !subjects.isEmpty {
                Section("Subjects") {
                    ForEach(subjects, id: \.name) { subject in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(subject.name)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            ForEach(subject.digest.sorted(by: { $0.key < $1.key }), id: \.key) { algorithm, value in
                                Text("\(algorithm):\(value)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }

            Section("Statement") {
                if let statementJSON {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(statementJSON)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        UIPasteboard.general.string = statementJSON
                        showToast(.copied("Statement copied"))
                    } label: {
                        Label("Copy Statement", systemImage: "doc.on.doc")
                    }
                } else if isLoadingStatement {
                    HStack {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading statement…").foregroundStyle(.secondary)
                    }
                } else if let statementError {
                    Label(statementError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Button("Load Statement") {
                        Task { await loadStatement() }
                    }
                }
            }
        }
        .navigationTitle("Attestation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func loadStatement() async {
        guard let client = manager.client else { return }
        isLoadingStatement = true
        defer { isLoadingStatement = false }
        do {
            let list = try await client.images.attestations(
                envID: environmentID,
                id: imageID,
                platform: attestation.platform,
                predicateType: attestation.predicateType,
                includeStatement: true
            )
            guard let match = list.attestations.first(where: { $0.digest == attestation.digest }),
                  let statement = match.statement else {
                statementError = "No statement payload returned."
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(statement)
            statementJSON = String(decoding: data, as: UTF8.self)
            statementError = nil
        } catch {
            statementError = friendlyErrorMessage(error)
        }
    }
}
