import Arcane
import SwiftUI

struct EnvironmentConnectionView: View {
    @SwiftUI.Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let environment: Arcane.Environment
    let details: EnvironmentDetails?
    let managerURL: String
    var isAvailable = true

    @State private var showsSession = false

    private var live: Bool {
        isAvailable && environment.enabled
            && (environment.isEdge ? environment.connected == true : environment.status == "online")
    }

    private var connectionStatus: String {
        guard isAvailable else { return "Unavailable" }
        guard environment.enabled else { return "Disabled" }
        if live { return "Connected" }
        switch environment.status {
        case "standby": return "Standby"
        case "pending": return "Connecting"
        case "error": return "Error"
        default: return "Disconnected"
        }
    }

    private var statusTint: Color {
        if live { return .green }
        switch environment.status {
        case "standby": return .blue
        case "pending": return .orange
        default: return .secondary
        }
    }

    private var managerName: String { URL(string: managerURL)?.host ?? "Manager" }
    private var agentName: String { environment.name ?? environment.id }

    private var transport: String {
        guard environment.isEdge else {
            return URL(string: environment.apiUrl)?.scheme?.uppercased() ?? "Direct"
        }
        switch environment.edgeTransport ?? environment.lastEdgeTransport {
        case "grpc": return "gRPC"
        case "websocket": return "WebSocket"
        default: return "Edge tunnel"
        }
    }

    private var dataPlane: String? {
        switch details?.edgeDataPlane {
        case "mux": return "Multiplexed"
        case "legacy": return "Legacy"
        default: return nil
        }
    }

    private var security: String {
        if environment.isEdge {
            switch environment.edgeSecurityMode {
            case "mtls": return "mTLS"
            case "token": return "Token"
            default: return "Unknown"
            }
        }
        return URL(string: environment.apiUrl)?.scheme == "https" ? "HTTPS" : "HTTP"
    }

    private var securityIcon: String {
        if environment.edgeSecurityMode == "mtls" { return "checkmark.shield" }
        return environment.isEdge || security == "HTTPS" ? "lock" : "network"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            EnvironmentConnectionStatus(
                status: connectionStatus,
                tint: statusTint,
                live: live,
                environment: environment
            )

            connectionPath

            Divider()

            if environment.isEdge {
                if live {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(tunnelMetrics) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(item.label, systemImage: item.systemImage)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(verbatim: item.value)
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                        }
                    } else {
                        AdaptiveMetadataGrid(items: tunnelMetrics)
                    }

                    DisclosureGroup("Session Details", isExpanded: $showsSession) {
                        sessionDetails
                            .padding(.top, 12)
                    }
                    .font(.subheadline)

                    Divider()
                }
                if let certificate = environment.edgeMTLSCertificate {
                    certificateDetails(certificate)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    sessionValue(label: "API URL", value: environment.apiUrl)
                    if let date = environment.lastSeen {
                        LabeledContent("Last Seen") { Text(date, style: .relative) }
                            .font(.subheadline)
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var connectionPath: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                connectionSymbol("server.rack")
                EnvironmentPacketTrack(live: live, isEdge: environment.isEdge, leg: 0)
                    .frame(height: 10)
                connectionSymbol(securityIcon)
                EnvironmentPacketTrack(live: live, isEdge: environment.isEdge, leg: 1)
                    .frame(height: 10)
                connectionSymbol("externaldrive.connected.to.line.below")
            }

            let captionLayout: AnyLayout =
                dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
            captionLayout {
                Text(managerName)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text([transport, dataPlane].compactMap { $0 }.joined(separator: " · "))
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                    .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                Text(agentName)
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                    .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(managerName) to \(agentName), \(transport), \(security), \(connectionStatus)")
    }

    private func connectionSymbol(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
    }

    private var roundTrip: String {
        guard let value = details?.edgeRoundTripMs, value.isFinite, value >= 0 else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) ms"
    }

    private var openStreams: String {
        details?.edgeOpenStreams.map { String($0) } ?? "—"
    }

    private var connectionMode: String { environment.lastPollAt == nil ? "Persistent" : "Polling" }

    private var tunnelMetrics: [ResourceMetadataItem] {
        [
            .init(label: "Round Trip", value: roundTrip, systemImage: "arrow.left.arrow.right"),
            .init(label: "Open Streams", value: openStreams, systemImage: "point.3.connected.trianglepath.dotted"),
            .init(label: "Connection Mode", value: connectionMode, systemImage: "network"),
            .init(label: "Security", value: security, systemImage: securityIcon),
        ]
    }

    private var sessionDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let date = environment.connectedAt {
                LabeledContent("Connected Since") {
                    Text(date, format: .dateTime.month().day().hour().minute())
                }
            }
            if let date = environment.lastPollAt {
                LabeledContent("Last Poll") { Text(date, style: .relative) }
            }
            if let session = environment.edgeSessionId {
                sessionValue(label: "Session ID", value: session)
            }
            if let instance = environment.edgeAgentInstance {
                sessionValue(label: "Agent Instance", value: instance)
            }
            if let capabilities = environment.edgeCapabilities, !capabilities.isEmpty {
                let features = capabilities.filter { !$0.contains(".") }
                let commands = capabilities.count - features.count
                sessionValue(
                    label: "Capabilities",
                    value: (features + ["\(commands) commands"]).joined(separator: " · ")
                )
            }
        }
    }

    private func sessionValue(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            MonospacedValue(value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func certificateDetails(_ certificate: EdgeMTLSCertificate) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Security").font(.headline)
            LabeledContent {
                Text(certificate.expired ? "Expired" : certificate.expiringSoon ? "Expiring Soon" : "Valid")
                    .foregroundStyle(certificate.expired ? .red : certificate.expiringSoon ? .orange : .green)
            } label: {
                Label("mTLS Certificate", systemImage: "checkmark.shield")
            }
            .font(.subheadline)
            if let name = certificate.commonName {
                sessionValue(label: "Common Name", value: name)
            }
            if let expiry = certificate.expiresAt {
                LabeledContent("Expires") {
                    Text(expiry, format: .dateTime.year().month().day())
                }
                .font(.subheadline)
            }
            if let days = certificate.daysRemaining {
                LabeledContent("Days Remaining") { Text(verbatim: String(days)) }
                    .font(.subheadline)
            }
        }
    }

}

private struct EnvironmentConnectionStatus: View {
    let status: String
    let tint: Color
    let live: Bool
    let environment: Arcane.Environment

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Text(status).font(.headline)
                    if live, environment.isEdge, let heartbeat = environment.lastHeartbeat {
                        let stale = context.date.timeIntervalSince(heartbeat) > 90
                        Text(stale ? "Stale Heartbeat" : "Healthy")
                            .font(.caption)
                            .foregroundStyle(stale ? .orange : .green)
                    }
                }
                if environment.isEdge {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { timestamps }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 4) { timestamps }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var timestamps: some View {
        if live, let connected = environment.connectedAt {
            HStack(spacing: 4) {
                Text("Connected for")
                Text(connected, style: .timer).monospacedDigit()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        if let heartbeat = environment.lastHeartbeat {
            HStack(spacing: 4) {
                Text("Last heartbeat")
                Text(heartbeat, style: .relative)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Only the tiny connector redraws at animation cadence; metrics and session rows stay static.
private struct EnvironmentPacketTrack: View {
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    let live: Bool
    let isEdge: Bool
    let leg: Int

    private var tint: Color { leg == 0 ? .green : .blue }

    var body: some View {
        TimelineView(.animation(paused: !live || reduceMotion || scenePhase != .active)) { context in
            Canvas { canvas, size in
                let duration = isEdge ? Motion.edgePacketDuration : Motion.directPacketDuration
                let phase =
                    context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration
                let progress = isEdge ? 1 - phase : (phase < 0.5 ? phase * 2 : (1 - phase) * 2)
                var packetPoint: CGPoint?

                let line = CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)
                canvas.fill(
                    Path(roundedRect: line, cornerRadius: 1),
                    with: .color(live ? tint.opacity(0.3) : .secondary.opacity(0.2)))
                let position = progress * 2 - Double(leg)
                if (0...1).contains(position) {
                    packetPoint = CGPoint(x: 2.5 + max(0, size.width - 5) * position, y: size.height / 2)
                }
                if live, !reduceMotion, scenePhase == .active, let point = packetPoint {
                    let packet = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
                    canvas.fill(Path(ellipseIn: packet), with: .color(progress < 0.5 ? .green : .blue))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
