import SwiftUI

/// A figure the Refreshed Dashboard's top card can show; the user picks up to
/// `maximum` of them, in order.
nonisolated enum DashboardTotalsTile: String, CaseIterable, Identifiable, Sendable {
    case running
    case stopped
    case images
    case volumes
    case updates
    case vulnerabilities
    case hostsOnline
    case cpuCores
    case memory

    static let preferenceKey = "arcane.dashboardTiles"
    static let defaults: [DashboardTotalsTile] = [.running, .images, .volumes]
    /// One row of tiles stays legible on an iPhone up to four.
    static let maximum = 4

    var id: String { rawValue }
    fileprivate var shownID: String { "shown.\(rawValue)" }
    fileprivate var availableID: String { "available.\(rawValue)" }

    var title: String {
        switch self {
        case .running: "Running"
        case .stopped: "Stopped"
        case .images: "Images"
        case .volumes: "Volumes"
        case .updates: "Updates"
        case .vulnerabilities: "Vulnerabilities"
        case .hostsOnline: "Online"
        case .cpuCores: "CPU Cores"
        case .memory: "Memory"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "cube.box.fill"
        case .stopped: "stop.circle.fill"
        case .images: "square.3.layers.3d.top.filled"
        case .volumes: "externaldrive.fill"
        case .updates: "arrow.triangle.2.circlepath"
        case .vulnerabilities: "exclamationmark.shield.fill"
        case .hostsOnline: "server.rack"
        case .cpuCores: "cpu.fill"
        case .memory: "memorychip.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running: .orange
        case .stopped: .gray
        case .images: .purple
        case .volumes: .blue
        case .updates: .green
        case .vulnerabilities: .red
        case .hostsOnline: .teal
        case .cpuCores: .blue
        case .memory: .purple
        }
    }

    /// Whether tapping the tile opens a screen; host-wide figures have none.
    var opensDestination: Bool {
        switch self {
        case .running, .stopped, .images, .volumes, .updates, .vulnerabilities: true
        case .hostsOnline, .cpuCores, .memory: false
        }
    }

    /// What the editor says each tile shows.
    var detail: String {
        switch self {
        case .running: "Running out of all containers"
        case .stopped: "Containers not running"
        case .images: "Images on every host"
        case .volumes: "Volumes on every host"
        case .updates: "Images with an update available"
        case .vulnerabilities: "Actionable vulnerabilities"
        case .hostsOnline: "Environments online"
        case .cpuCores: "Cores across live hosts"
        case .memory: "Memory in use across live hosts"
        }
    }

    /// Parses the stored list, dropping unknown and repeated tiles. An empty
    /// result falls back to the defaults so the card never renders blank.
    static func decode(_ raw: String) -> [DashboardTotalsTile] {
        var seen = Set<DashboardTotalsTile>()
        let tiles = raw.split(separator: ",").compactMap { DashboardTotalsTile(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
        return tiles.isEmpty ? defaults : Array(tiles.prefix(maximum))
    }

    static func encode(_ tiles: [DashboardTotalsTile]) -> String {
        tiles.map(\.rawValue).joined(separator: ",")
    }
}

/// Picks and orders the Refreshed Dashboard's top tiles.
struct DashboardTilesEditor: View {
    @AppStorage(DashboardTotalsTile.preferenceKey) private var storedTiles = DashboardTotalsTile.encode(DashboardTotalsTile.defaults)

    private var tiles: [DashboardTotalsTile] { DashboardTotalsTile.decode(storedTiles) }
    private var available: [DashboardTotalsTile] { DashboardTotalsTile.allCases.filter { !tiles.contains($0) } }

    var body: some View {
        List {
            Section {
                // Section-scoped IDs: a tile moving between sections must become a
                // new row, or List reuses the Available button and the added row
                // never gets its delete and reorder controls.
                ForEach(tiles, id: \.shownID) { tile in
                    row(tile)
                }
                .onMove { source, destination in
                    var reordered = tiles
                    reordered.move(fromOffsets: source, toOffset: destination)
                    storedTiles = DashboardTotalsTile.encode(reordered)
                }
                .onDelete { offsets in
                    var remaining = tiles
                    remaining.remove(atOffsets: offsets)
                    // Keep at least one tile; an empty list would fall back to the defaults.
                    guard !remaining.isEmpty else { return }
                    storedTiles = DashboardTotalsTile.encode(remaining)
                }
            } header: {
                Text("Shown")
            } footer: {
                Text("Up to \(DashboardTotalsTile.maximum) tiles. Drag to reorder.")
            }

            if !available.isEmpty {
                Section("Available") {
                    ForEach(available, id: \.availableID) { tile in
                        Button {
                            storedTiles = DashboardTotalsTile.encode(tiles + [tile])
                        } label: {
                            HStack {
                                row(tile)
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.title3)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(tiles.count >= DashboardTotalsTile.maximum)
                        .opacity(tiles.count >= DashboardTotalsTile.maximum ? 0.4 : 1)
                    }
                }
            }

            Section {
                Button("Reset to Defaults", systemImage: "arrow.counterclockwise") {
                    storedTiles = DashboardTotalsTile.encode(DashboardTotalsTile.defaults)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Dashboard Tiles")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ tile: DashboardTotalsTile) -> some View {
        HStack(spacing: 12) {
            RowIcon(systemImage: tile.systemImage, tint: tile.tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.title)
                Text(tile.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
