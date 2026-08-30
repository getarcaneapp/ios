import Arcane
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Arcane_Mobile

@Suite("Log viewer")
@MainActor
struct LogViewerTests {
    @Test
    func transcriptIsBoundedAndIDsRemainMonotonicAfterClear() throws {
        let store = LogViewerStore(logStream: { nil })
        let receivedCount = LogViewerStore.maximumRetainedLines + 5
        let lines = try (0..<receivedCount).map { index in
            try makeLine(message: "line-\(index)")
        }

        store.receive(lines)

        #expect(store.lines.count == LogViewerStore.maximumRetainedLines)
        #expect(store.lines.first?.id == 5)
        #expect(store.lines.last?.id == UInt64(receivedCount - 1))
        #expect(Set(store.lines.map(\.id)).count == store.lines.count)

        store.clear()
        store.receive([try makeLine(message: "after-clear")])

        #expect(store.lines.count == 1)
        #expect(store.lines.first?.id == UInt64(receivedCount))
    }

    @Test
    func searchMatchesMessageServiceSeverityAndVisibleTimestamp() throws {
        let store = LogViewerStore(logStream: { nil })
        store.receive([
            try makeLine(
                message: "HTTP server ready",
                level: "info",
                service: "api",
                timestamp: "2026-08-29T12:34:56Z"
            ),
            try makeLine(
                message: "queue depth high",
                level: "warning",
                service: "worker",
                timestamp: "2026-08-29T12:35:00Z"
            ),
        ])

        store.searchText = "worker"
        #expect(store.filteredLines.map(\.line.text) == ["queue depth high"])

        store.searchText = "WARN"
        #expect(store.filteredLines.map(\.line.text) == ["queue depth high"])

        store.searchText = "12:34:56"
        #expect(store.filteredLines.isEmpty)

        store.setTimestampVisibility(true)
        #expect(store.filteredLines.map(\.line.text) == ["HTTP server ready"])
    }

    @Test
    func pausedCountIncludesOnlyNewMatchingLines() throws {
        let store = LogViewerStore(logStream: { nil })
        store.searchText = "api"
        store.pauseFollowing()
        store.receive([
            try makeLine(message: "api connected", service: "gateway"),
            try makeLine(message: "worker connected", service: "worker"),
        ])

        #expect(store.newLinesWhilePaused == 1)

        store.searchText = "worker"
        #expect(store.newLinesWhilePaused == 0)

        store.receive([try makeLine(message: "job started", service: "worker")])
        #expect(store.newLinesWhilePaused == 1)

        store.resumeFollowing()
        #expect(store.isFollowing)
        #expect(store.newLinesWhilePaused == 0)
    }

    @Test
    func exportUsesFilteredLinesAndOnlyVisibleTimestamps() throws {
        let store = LogViewerStore(logStream: { nil })
        store.receive([
            try makeLine(
                message: "request failed",
                level: "stderr",
                service: "api",
                timestamp: "2026-08-29T12:34:56Z"
            ),
            try makeLine(message: "worker ready", level: "info", service: "worker"),
        ])
        store.searchText = "request"

        #expect(store.exportText(showTimestamps: false) == "[api] [ERROR] request failed")
        #expect(
            store.exportText(showTimestamps: true)
                == "[2026-08-29T12:34:56Z] [api] [ERROR] request failed"
        )
    }

    @Test
    func preferencesAndFormattingHaveStableFallbacks() {
        #expect(!LogViewerPreferences.showsTimestampsByDefault)
        #expect(LogViewerPreferences.wrapsLinesByDefault)
        #expect(LogViewerFormatting.severity(for: "stderr") == .error)
        #expect(LogViewerFormatting.severity(for: "warning") == .warning)
        #expect(LogViewerFormatting.severity(for: "debug") == .debug)
        #expect(LogViewerFormatting.displayTimestamp("prefix-12345678") == "12345678")
        #expect(LogViewerFormatting.sanitizedFilename("API / Logs") == "API-Logs")
    }

    @Test
    func adaptiveRowsRenderAcrossLayoutsAndAccessibilitySizes() throws {
        let line = try makeLine(
            message: "{\"request\":\"https://example.com/a/very/long/path?environment=production\",\"status\":500,\"detail\":\"upstream connection timed out while waiting for response headers\"}",
            level: "error",
            service: "extraordinarily-long-background-worker-service",
            timestamp: "2026-08-29T12:34:56.789Z"
        )
        let configurations: [RenderConfiguration] = [
            .init(
                name: "compact-wrapped-light",
                width: 390,
                height: 190,
                layout: .compact,
                wrapsLines: true,
                colorScheme: .light,
                dynamicTypeSize: .large
            ),
            .init(
                name: "wide-wrapped-dark",
                width: 820,
                height: 130,
                layout: .wide,
                wrapsLines: true,
                colorScheme: .dark,
                dynamicTypeSize: .large
            ),
            .init(
                name: "compact-accessibility",
                width: 390,
                height: 310,
                layout: .compact,
                wrapsLines: true,
                colorScheme: .light,
                dynamicTypeSize: .accessibility3
            ),
            .init(
                name: "compact-unwrapped-dark",
                width: 390,
                height: 130,
                layout: .compact,
                wrapsLines: false,
                colorScheme: .dark,
                dynamicTypeSize: .large
            ),
        ]

        for configuration in configurations {
            let fixture = LogLineView(
                line: line,
                showTimestamps: true,
                wrapLines: configuration.wrapsLines,
                metadataLayout: configuration.layout
            )
            .padding(14)
            .frame(
                width: configuration.width,
                height: configuration.height,
                alignment: .topLeading
            )
            .background(Color(.systemBackground))
            .environment(\.colorScheme, configuration.colorScheme)
            .environment(\.dynamicTypeSize, configuration.dynamicTypeSize)

            let renderer = ImageRenderer(content: fixture)
            renderer.scale = 2
            let image = try #require(renderer.uiImage)

            #expect(
                image.size == CGSize(
                    width: configuration.width,
                    height: configuration.height
                )
            )
            Attachment.record(image, named: configuration.name, as: .png)
        }
    }

    private func makeLine(
        message: String,
        level: String? = nil,
        service: String? = nil,
        timestamp: String? = nil
    ) throws -> LogLine {
        let fixture = LogLineFixture(
            text: message,
            seq: nil,
            level: level,
            service: service,
            timestamp: timestamp
        )
        let data = try JSONEncoder().encode(fixture)
        return try JSONDecoder().decode(LogLine.self, from: data)
    }
}

private struct LogLineFixture: Encodable {
    let text: String
    let seq: UInt64?
    let level: String?
    let service: String?
    let timestamp: String?
}

private struct RenderConfiguration {
    let name: String
    let width: CGFloat
    let height: CGFloat
    let layout: LogMetadataLayout
    let wrapsLines: Bool
    let colorScheme: ColorScheme
    let dynamicTypeSize: DynamicTypeSize
}
