import SwiftUI
import Charts
import Arcane

struct SecurityOverviewView: View {
    let overview: VulnerabilityRiskOverview
    let environmentID: EnvironmentID
    let selectVulnerability: (String) -> Void

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedRiskPanel: RiskPanel = .score
    @State private var trendDays = 30
    @State private var rankByPrevalence = false
    @State private var displayedScore = 0.0
    @State private var hasAnimatedScore = false

    private enum RiskPanel: String, CaseIterable {
        case score = "Score"
        case trend = "Trend"
    }

    private var scoreUnavailable: Bool { overview.scoreStatus == "unavailable" }
    private var scoreTarget: Double {
        scoreUnavailable ? 0 : Double(min(max(overview.riskScore, 0), 100))
    }

    private var scoreColor: Color {
        guard !scoreUnavailable else { return .secondary }
        switch overview.riskBand {
        case "critical": return .red
        case "high": return .orange
        case "medium": return .yellow
        case "low": return .blue
        default: return .green
        }
    }

    private var bandLabel: String {
        guard !scoreUnavailable else { return "Unavailable" }
        return overview.riskBand.capitalized
    }

    private var threatDataAvailable: Bool {
        overview.threatIntel.enabled && overview.threatIntel.lastSyncedAt != nil
    }

    var body: some View {
        if overview.drivers.imagesScanned == 0 {
            Section {
                ContentUnavailableView(
                    "No scans yet",
                    systemImage: "shield.lefthalf.filled",
                    description: Text("Scan an image to see the security overview.")
                )
                .listRowBackground(Color.clear)
            }
        } else {
            Section("Risk") {
                VStack(spacing: 16) {
                    Picker("Risk view", selection: $selectedRiskPanel) {
                        ForEach(RiskPanel.allCases, id: \.self) { panel in
                            Text(panel.rawValue).tag(panel)
                        }
                    }
                    .pickerStyle(.segmented)

                    if selectedRiskPanel == .score {
                        scoreCard
                    } else {
                        trendCard
                    }
                }
            }

            Section("Findings by severity") {
                SeverityBar(
                    critical: overview.summary.critical,
                    high: overview.summary.high,
                    medium: overview.summary.medium,
                    low: overview.summary.low,
                    unknown: overview.summary.unknown
                )
                .padding(.vertical, 8)
            }

            Section("Exposure") {
                exposureRow("Running", count: overview.exposure.running, color: .orange)
                exposureRow("Stopped", count: overview.exposure.stopped, color: .yellow)
                exposureRow("Unused", count: overview.exposure.unused, color: .secondary)
                if overview.exposure.unknown > 0 {
                    exposureRow("Unknown", count: overview.exposure.unknown, color: .secondary)
                }
            }

            Section {
                driverRow("Known exploited", count: overview.drivers.knownExploited,
                          previous: overview.drivers7dAgo?.knownExploited, requiresThreatData: true)
                driverRow("High exploit probability", count: overview.drivers.highEpss,
                          previous: overview.drivers7dAgo?.highEpss, requiresThreatData: true)
                driverRow("Exposed critical and high", count: overview.drivers.exposedCriticalHigh,
                          previous: overview.drivers7dAgo?.exposedCriticalHigh)
                driverRow("Overdue known exploited", count: overview.drivers.overdueKnownExploited,
                          previous: overview.drivers7dAgo?.overdueKnownExploited, requiresThreatData: true)
                LabeledContent("Images scanned") {
                    Text(verbatim: "\(overview.drivers.imagesScanned) / \(overview.drivers.imagesTotal)")
                        .monospacedDigit()
                }
            } header: {
                Text("Risk drivers")
            } footer: {
                if !overview.threatIntel.enabled {
                    Text("Threat intelligence is disabled. Known exploited and exploit probability counts are unavailable.")
                } else if overview.threatIntel.lastSyncedAt == nil {
                    Text("Threat intelligence has not synced yet.")
                } else if overview.threatIntel.stale {
                    Text("Threat intelligence is out of date.")
                }
            }

            Section {
                Picker("Rank by", selection: $rankByPrevalence) {
                    Text("Risk").tag(false)
                    Text("Prevalence").tag(true)
                }
                .pickerStyle(.segmented)
                ForEach(rankByPrevalence ? overview.prevalentFindings : overview.riskiestFindings) { finding in
                    Button {
                        selectVulnerability(finding.vulnerabilityId)
                    } label: {
                        findingRow(finding)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Priority findings")
            } footer: {
                Text("Select a finding to see its affected images and package details.")
            }

            if !overview.riskiestImages.isEmpty {
                Section("Riskiest images") {
                    ForEach(overview.riskiestImages) { image in
                        NavigationLink {
                            ImageVulnerabilitiesView(
                                imageID: image.imageId,
                                imageDisplayName: image.imageName,
                                environmentID: environmentID
                            )
                        } label: {
                            imageRow(image)
                        }
                    }
                }
            }
        }
    }

    private var scoreCard: some View {
        VStack(spacing: 16) {
            Text("Patch priority")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 14)
                Circle()
                    .trim(from: 0, to: displayedScore / 100)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    if scoreUnavailable {
                        Text("–").font(.system(size: 54, weight: .semibold, design: .rounded))
                    } else {
                        AnimatedRiskScore(value: displayedScore)
                            .font(.system(size: 54, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("/ 100").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 170, height: 170)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(scoreUnavailable ? "Patch priority unavailable" : "Patch priority \(overview.riskScore) out of 100, \(bandLabel)")

            Text(bandLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(scoreColor)

            if let driver = overview.scoreDriver {
                Button {
                    selectVulnerability(driver.vulnerabilityId)
                } label: {
                    VStack(spacing: 4) {
                        Text("Top fix: \(driver.vulnerabilityId)")
                            .font(.subheadline.weight(.medium))
                        Text(driver.imageName)
                            .font(.caption)
                            .lineLimit(1)
                        Text("\(driver.pkgName) → \(driver.fixedVersion)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }

            Text("Higher scores mean more urgent fixes. Image use and known exploitation affect the score.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear {
            guard !hasAnimatedScore || displayedScore != scoreTarget else { return }
            hasAnimatedScore = true
            withAnimation(Motion.reduced(Motion.riskScoreReveal, reduceMotion: reduceMotion)) {
                displayedScore = scoreTarget
            }
        }
        .onChange(of: scoreTarget) { _, target in
            withAnimation(Motion.reduced(Motion.riskScoreReveal, reduceMotion: reduceMotion)) {
                displayedScore = target
            }
        }
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let delta = overview.delta7d {
                    Label(delta == 0 ? "No change in 7 days" : "\(abs(delta)) in 7 days",
                          systemImage: delta > 0 ? "arrow.up.right" : delta < 0 ? "arrow.down.right" : "minus")
                        .font(.caption)
                        .foregroundStyle(delta > 0 ? .orange : .secondary)
                }
                Spacer()
                Picker("Range", selection: $trendDays) {
                    Text("30d").tag(30)
                    Text("90d").tag(90)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }
            let points = Array(overview.trend.suffix(trendDays))
            if points.count > 1 {
                Chart(points, id: \.date) { point in
                    AreaMark(x: .value("Day", point.date), y: .value("Score", point.riskScore))
                        .foregroundStyle(scoreColor.opacity(0.14))
                    LineMark(x: .value("Day", point.date), y: .value("Score", point.riskScore))
                        .foregroundStyle(scoreColor)
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .frame(height: 130)
                HStack {
                    Text(points.first?.date ?? "")
                    Spacer()
                    Text(points.last?.date ?? "")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text("Trend appears after another daily snapshot.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .padding(.vertical, 4)
    }

    private func exposureRow(_ label: String, count: Int, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
            Spacer()
            Text(verbatim: String(count)).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func driverRow(_ label: String, count: Int, previous: Int?, requiresThreatData: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            if requiresThreatData && !threatDataAvailable {
                Text("–").foregroundStyle(.secondary)
                    .accessibilityLabel("Unavailable")
            } else {
                Text(verbatim: String(count)).monospacedDigit()
                if let previous, count != previous {
                    Image(systemName: count > previous ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                        .foregroundStyle(count > previous ? .orange : .green)
                    Text(verbatim: String(abs(count - previous)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func findingRow(_ finding: VulnerabilityRiskFinding) -> some View {
        HStack(spacing: 10) {
            SeverityBadge(severity: VulnerabilitySeverity(rawValue: finding.severity.uppercased()) ?? .unknown)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.vulnerabilityId).font(.subheadline.weight(.semibold))
                Text("\(finding.pkgName) → \(finding.fixedVersion ?? "No fix")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: "\(finding.imagesAffected) images")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: String(rankByPrevalence ? finding.imagesAffected : Int((finding.risk * 10).rounded())))
                    .font(.headline.monospacedDigit())
                Text(rankByPrevalence ? "images" : "risk")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
    }

    private func imageRow(_ image: VulnerabilityRiskImage) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(image.imageName).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(verbatim: "\(image.exposure.capitalized) · \(image.findings) findings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(image.scoreStatus == "unavailable" ? "–" : String(image.riskScore))
                .font(.headline.monospacedDigit())
                .foregroundStyle(image.scoreStatus == "unavailable" ? .secondary : scoreColor(for: image.riskBand))
        }
        .padding(.vertical, 3)
    }

    private func scoreColor(for band: String) -> Color {
        switch band {
        case "critical": .red
        case "high": .orange
        case "medium": .yellow
        case "low": .blue
        default: .green
        }
    }
}

private struct AnimatedRiskScore: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(verbatim: String(Int(min(max(value, 0), 100).rounded())))
    }
}
