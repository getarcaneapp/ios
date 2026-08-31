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
    func pausedCountIncludesAllNewLines() throws {
        let store = LogViewerStore(logStream: { nil })
        store.pauseFollowing()
        store.receive([
            try makeLine(message: "api connected", service: "gateway"),
            try makeLine(message: "worker connected", service: "worker"),
        ])

        #expect(store.newLinesWhilePaused == 2)

        store.receive([try makeLine(message: "job started", service: "worker")])
        #expect(store.newLinesWhilePaused == 3)

        store.resumeFollowing()
        #expect(store.isFollowing)
        #expect(store.newLinesWhilePaused == 0)
    }

    @Test
    func exportUsesAllLinesAndOnlyVisibleTimestamps() throws {
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

        #expect(
            store.exportText(showTimestamps: false)
                == "[api] [ERROR] request failed\n[worker] [INFO] worker ready"
        )
        #expect(
            store.exportText(showTimestamps: true)
                == "[2026-08-29T12:34:56Z] [api] [ERROR] request failed\n[worker] [INFO] worker ready"
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

    @Test
    func embeddedViewerRendersCompactHeaderWithoutInlineActions() async throws {
        let fixture = NavigationStack {
            VStack(spacing: 0) {
                ScrollableTabBar(
                    selection: .constant("logs"),
                    options: [
                        ScrollableTabOption(
                            "overview",
                            title: "Overview",
                            systemImage: "info.circle.fill",
                            tint: .purple
                        ),
                        ScrollableTabOption(
                            "stats",
                            title: "Stats",
                            systemImage: "chart.xyaxis.line",
                            tint: .blue
                        ),
                        ScrollableTabOption(
                            "logs",
                            title: "Logs",
                            systemImage: "text.alignleft",
                            tint: .teal
                        ),
                    ],
                    accessibilityLabel: "Container detail sections"
                )

                LogsView(title: "arcane", logStream: { nil }, embedded: true)
            }
            .navigationTitle("arcane")
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(width: 390, height: 844)
        .background(Color(.systemBackground))
        .environment(\.dynamicTypeSize, .large)

        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: fixture)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()

        let navigationBars = descendants(of: UINavigationBar.self, in: window)
        let navigationSearchBars = descendants(of: UISearchBar.self, in: window)
        let textFields = descendants(of: UITextField.self, in: window)
        let navigationBar = try #require(navigationBars.first)

        #expect(navigationBar.bounds.height < 80)
        #expect(navigationSearchBars.isEmpty)
        #expect(textFields.isEmpty)

        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let image = renderer.image { context in
            host.view.layer.render(in: context.cgContext)
        }

        #expect(image.size == CGSize(width: 390, height: 844))
        Attachment.record(image, named: "embedded-log-viewer-header", as: .png)
    }

    @Test
    func liveViewerFollowsNewLines() async throws {
        let store = LogViewerStore(logStream: { nil })
        let fixture = LogConsole(
            store: store,
            showTimestamps: false,
            wrapLines: true,
            metadataLayout: .compact,
            jumpToLatestRequest: 0
        )
        .frame(width: 390, height: 500)
        .background(Color(.systemBackground))

        let bounds = CGRect(x: 0, y: 0, width: 390, height: 500)
        let host = UIHostingController(rootView: fixture)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = bounds
        host.view.layoutIfNeeded()

        store.receive(try (0..<80).map { index in
            try makeLine(message: longMessage(prefix: "initial", index: index))
        })
        try await settle(host)

        let scrollView = try #require(
            descendants(of: UIScrollView.self, in: window)
                .first { $0.contentSize.height > $0.bounds.height }
        )
        let offsetBeforeNewLines = scrollView.contentOffset.y

        store.receive(try (80..<100).map { index in
            try makeLine(message: longMessage(prefix: "new", index: index))
        })
        try await settle(host)

        let maximumOffset = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )

        #expect(store.isFollowing)
        #expect(scrollView.contentOffset.y > offsetBeforeNewLines)
        #expect(abs(scrollView.contentOffset.y - maximumOffset) < 2)
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

    private func settle(_ host: UIViewController) async throws {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
    }

    private func longMessage(prefix: String, index: Int) -> String {
        "\(prefix) line \(index) "
            + String(
                repeating: "container log output continues across the available width ",
                count: 4
            )
    }
}

@MainActor
private func descendants<ViewType: UIView>(
    of type: ViewType.Type,
    in root: UIView
) -> [ViewType] {
    root.subviews.flatMap { subview in
        let current = (subview as? ViewType).map { [$0] } ?? []
        return current + descendants(of: type, in: subview)
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
