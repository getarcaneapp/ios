import Arcane
import SwiftUI
import UIKit

struct SupportBundleView: View {
    @SwiftUI.Environment(ArcaneClientManager.self) private var manager

    @State private var document: SupportBundleDocument?
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        List {
            privacySection
            includedSection
            actionsSection
            if let document {
                previewSection(document.report)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Support Bundle")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var privacySection: some View {
        Section {
            Label {
                Text("Collects live diagnostics you can inspect before sharing.")
            } icon: {
                Image(systemName: "stethoscope")
                    .foregroundStyle(.teal)
            }
        } footer: {
            Text("Credentials and common secret fields are redacted automatically. Review the preview before sharing.")
        }
    }

    private var includedSection: some View {
        Section("Collected Diagnostics") {
            SupportBundleDetailRow(
                title: "App and session",
                detail: "Build, device, signed-in user, server, and active environment",
                systemImage: "iphone"
            )
            SupportBundleDetailRow(
                title: "Server and Docker",
                detail: "Endpoint errors, Arcane build, Docker versions, and daemon state",
                systemImage: "waveform.path.ecg"
            )
            SupportBundleDetailRow(
                title: "Recent failures",
                detail: "Environment state, failed activities, messages, errors, and metadata",
                systemImage: "server.rack"
            )
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if isGenerating {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Collecting diagnostics…")
                        .foregroundStyle(.secondary)
                }
            } else if let document {
                ShareLink(
                    item: document.fileURL,
                    subject: Text("Arcane Mobile Support Bundle")
                ) {
                    Label("Share Support Bundle", systemImage: "square.and.arrow.up")
                }

                Button {
                    UIPasteboard.general.string = document.report.text
                    showToast(.copied("Support bundle copied"))
                } label: {
                    Label("Copy Report", systemImage: "document.on.document")
                }

                Button {
                    Task { await generate() }
                } label: {
                    Label("Run Diagnostics Again", systemImage: "arrow.clockwise")
                }
            } else {
                Button {
                    Task { await generate() }
                } label: {
                    Label("Generate Support Bundle", systemImage: "doc.text.magnifyingglass")
                }
            }

            if let generationError {
                Label(generationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } footer: {
            Text("Diagnostics are read-only. The exported bundle is a plain-text file containing the preview below.")
        }
    }

    private func previewSection(_ report: SupportBundleReport) -> some View {
        Section("Preview") {
            ScrollView(.horizontal) {
                Text(verbatim: report.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.vertical, 4)
            }
            .accessibilityLabel("Support bundle preview")
        }
    }

    private func generate() async {
        guard !isGenerating else { return }
        isGenerating = true
        generationError = nil
        defer { isGenerating = false }

        let generation = manager.clientGeneration
        let diagnostics = await SupportBundleCollector.collect(
            client: manager.client,
            activeEnvironmentID: manager.activeEnvironmentID,
            activeEnvironmentName: manager.activeEnvironmentName,
            supportsActivities: manager.supportsActivities
        )
        guard !Task.isCancelled, generation == manager.clientGeneration else { return }

        let server = manager.parsedServerURL.map {
            SupportBundleBuilder.serverDescriptor(
                for: $0,
                fingerprintSalt: supportFingerprintSalt()
            )
        }
        let capabilities = manager.serverCapabilities
        let user = manager.currentUser
        let snapshot = SupportBundleSnapshot(
            generatedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown",
            operatingSystem: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            deviceClass: UIDevice.current.model,
            localeIdentifier: Locale.current.identifier,
            timeZoneIdentifier: TimeZone.current.identifier,
            authenticationState: supportAuthenticationState,
            userRole: supportUserRole,
            userID: user?.id,
            username: user?.username,
            assignedRoles: user?.roles ?? [],
            backendMode: supportBackendMode,
            server: server,
            serverURLConfigured: manager.parsedServerURL != nil,
            clientConfigured: manager.client != nil,
            connectionWarning: manager.errorMessage,
            activeEnvironmentID: manager.activeEnvironmentID.rawValue,
            activeEnvironmentName: manager.activeEnvironmentName,
            capabilitiesLoaded: capabilities != nil,
            supportsActivities: capabilities?.supportsActivities == true,
            supportsRoleManagement: capabilities?.supportsRoleManagement == true,
            permissionsManifestLoaded: manager.permissionsManifest != nil,
            supportsExtendedMobileAPI: manager.supportsPost26MobileFeatures,
            supportsMobilePush: manager.supportsMobilePush,
            diagnostics: diagnostics
        )
        let report = SupportBundleBuilder.makeReport(from: snapshot)

        do {
            let fileURL = try write(report)
            if let previousURL = document?.fileURL, previousURL != fileURL {
                try? FileManager.default.removeItem(at: previousURL)
            }
            document = SupportBundleDocument(report: report, fileURL: fileURL)
        } catch {
            generationError = "The support bundle couldn't be saved. Please try again."
            showToast(.error("Couldn't save support bundle"))
        }
    }

    private var supportAuthenticationState: SupportBundleAuthenticationState {
        switch manager.authState {
        case .setup: .notConfigured
        case .authenticating: .authenticating
        case .login: .signedOut
        case .authenticated: .authenticated
        }
    }

    private var supportUserRole: SupportBundleUserRole {
        guard let user = manager.currentUser else { return .unavailable }
        return user.isAdmin ? .administrator : .standard
    }

    private var supportBackendMode: SupportBundleBackendMode {
        switch manager.serverCapabilities?.mode {
        case .legacyRoles: .legacy
        case .rbac: .rbac
        case .unknown, nil: .unknown
        }
    }

    private func supportFingerprintSalt() -> String {
        let key = "arcane.supportBundleFingerprintSalt"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let salt = UUID().uuidString
        UserDefaults.standard.set(salt, forKey: key)
        return salt
    }

    private func write(_ report: SupportBundleReport) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(report.filename, isDirectory: false)
        try report.text.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
        )
        return fileURL
    }
}

private struct SupportBundleDocument {
    let report: SupportBundleReport
    let fileURL: URL
}

private struct SupportBundleDetailRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.teal)
                .frame(width: 24)
        }
    }
}
