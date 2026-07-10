import Foundation
import Arcane
import FoundationModels

/// One image, three views: details, update check, or CVE findings. With no
/// imageId, the environment-wide update or vulnerability summary.
/// Image-update and vulnerability endpoints use the app-local Models.swift
/// types + raw REST (the SDK's typed shapes don't match the current server).
@available(iOS 26, *)
struct InspectImageTool: Tool {
    let context: ArcaneToolContext

    let name = "inspectImage"
    let description = "ONE image's details, update check, or CVEs. Without imageId: environment-wide update or CVE summary."

    @Generable
    enum ImageTopic: Sendable {
        case details
        case updates
        case cves
    }

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Image id from listImages. Omit for environment summary.")
        var imageId: String?
        @Guide(description: "details (default), updates, or cves.")
        var topic: ImageTopic?
        @Guide(description: "cves only: limit to critical/high.")
        var onlySevere: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        let topic = arguments.topic ?? .details
        let id = arguments.imageId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if id.isEmpty {
            switch topic {
            case .cves: return await environmentCVEText()
            default: return await updateSummaryText()
            }
        }
        switch topic {
        case .details: return await detailsText(id: id)
        case .updates: return await updateCheckText(id: id)
        case .cves: return await cveText(id: id, onlySevere: arguments.onlySevere == true)
        }
    }

    // MARK: - Details

    private func detailsText(id: String) async -> String {
        context.status.report("Inspecting image…")
        let d: ImageDetailSummary
        do {
            d = try await context.client.images.inspect(envID: context.envID, id: id)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "image “\(id)”")
        }
        var lines: [String] = []
        let tags = d.repoTags.filter { $0 != "<none>:<none>" }
        lines.append("image: \(tags.first ?? String(d.id.prefix(12)))")
        if tags.count > 1 { lines.append("otherTags: \(tags.dropFirst().prefix(5).joined(separator: ", "))") }
        lines.append("size: \(ByteCountFormatter.string(fromByteCount: d.size, countStyle: .file))")
        if !d.created.isEmpty { lines.append("created: \(d.created)") }
        if !d.os.isEmpty || !d.architecture.isEmpty { lines.append("platform: \(d.os)/\(d.architecture)") }
        // Vulnerability garnish — never fail the inspect for it.
        let scanPath = context.client.rest.environmentPath(context.envID, "images/\(id)/vulnerabilities/summary")
        if let scan: ScanSummary = try? await context.client.rest.get(scanPath),
           let s = scan.summary {
            lines.append("vulnerabilities: \(s.critical) critical, \(s.high) high, \(s.medium) medium, \(s.low) low")
        }
        return String(lines.joined(separator: "\n").prefix(3000))
    }

    // MARK: - Updates (SDK typed API, mirrors ImageDetailView/ImageUpdatesView)

    private func updateCheckText(id: String) async -> String {
        context.status.report("Checking for image updates…")
        let r: ImageUpdateResponse
        do {
            r = try await context.client.images.checkUpdateByIDPost(envID: context.envID, imageId: id)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "update check for image “\(id)”")
        }
        if let error = r.error, !error.isEmpty {
            return "Update check failed: \(error)"
        }
        let current = r.currentVersion.isEmpty ? "the current version" : r.currentVersion
        guard r.hasUpdate else { return "No update available — \(current) is current." }
        let latest = r.latestVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "a newer digest"
        let type = r.updateType.isEmpty ? "" : " (\(r.updateType))"
        return "Update available\(type): \(current) → \(latest)."
    }

    private func updateSummaryText() async -> String {
        context.status.report("Checking image updates…")
        do {
            let s = try await context.client.images.updateSummary(envID: context.envID)
            var text = "Across \(s.totalImages) image(s): \(s.imagesWithUpdates) with updates available"
            if s.errorsCount > 0 { text += ", \(s.errorsCount) check error(s)" }
            return text + "."
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "the image update summary")
        }
    }

    // MARK: - CVEs (raw REST, mirrors the vulnerability views)

    private func environmentCVEText() async -> String {
        context.status.report("Checking vulnerabilities…")
        let summary: EnvironmentVulnerabilitySummary
        do {
            let path = context.client.rest.environmentPath(context.envID, "vulnerabilities/summary")
            summary = try await context.client.rest.get(path)
        } catch {
            // Distinguish "scanner off" from a real failure when we can.
            let statusPath = context.client.rest.environmentPath(context.envID, "vulnerabilities/scanner-status")
            if let status: ScannerStatus = try? await context.client.rest.get(statusPath), !status.available {
                return "(the vulnerability scanner is not available on this server)"
            }
            return ToolSupport.friendlyFailure(error, reading: "vulnerabilities")
        }
        var text = "Scanned \(summary.scannedImages) of \(summary.totalImages) image(s) in \(context.envName)."
        if let s = summary.summary {
            text += "\nCVEs: \(s.critical) critical, \(s.high) high, \(s.medium) medium, \(s.low) low (\(s.total) total)."
            if s.critical + s.high > 0 {
                text += "\nFor one image's findings, call inspectImage with its imageId and topic=cves."
            }
        } else {
            text += "\nNo scan results yet."
        }
        return text
    }

    private func cveText(id: String, onlySevere: Bool) async -> String {
        context.status.report("Checking vulnerabilities…")
        var findings: [VulnerabilityRecord]
        do {
            let path = context.client.rest.environmentPath(context.envID, "images/\(id)/vulnerabilities/list")
            let query = [
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "limit", value: "50")
            ]
            findings = try await context.client.rest.get(path, query: query)
        } catch {
            return ToolSupport.friendlyFailure(error, reading: "vulnerabilities for image “\(id)”")
        }
        let total = findings.count
        if onlySevere {
            findings = findings.filter { $0.severityValue == .critical || $0.severityValue == .high }
        }
        // Worst first so truncation keeps what matters.
        let rank: [VulnerabilitySeverity: Int] = [.critical: 0, .high: 1, .medium: 2, .low: 3, .unknown: 4]
        findings.sort { (rank[$0.severityValue] ?? 5) < (rank[$1.severityValue] ?? 5) }

        if findings.isEmpty {
            return onlySevere
                ? "No critical or high findings for this image (\(total) total findings)."
                : "No vulnerability findings for this image. It may not have been scanned yet."
        }
        let shown = findings.prefix(10)
        var lines = ["\(total) finding(s) for this image (showing \(shown.count), worst first):"]
        for v in shown {
            let fix = v.fixedVersion.map { " → fixed in \($0)" } ?? " (no fix yet)"
            let installed = v.installedVersion.map { " \($0)" } ?? ""
            lines.append("- \(v.vulnerabilityId) [\(v.severityValue.rawValue)] \(v.pkgName)\(installed)\(fix)")
        }
        return lines.joined(separator: "\n")
    }
}
