import Foundation
import SwiftUI
import UIKit
import WhatsNewKit
import XCTest

@testable import Arcane_Mobile

@MainActor
final class ReleaseNotesTests: XCTestCase {
    func testPresentationSectionsPreserveCategoryOrderAndContent() {
        let note = ReleaseNote(
            version: "1.2.3",
            new: [.init("New feature")],
            changed: [.init("Changed behavior", badge: .premium)],
            fixed: [.init("Fixed bug")]
        )

        XCTAssertEqual(note.presentationSections.map(\.title), [
            "New",
            "Changed",
            "Fixed",
        ])
        XCTAssertEqual(note.presentationSections.map(\.subtitle), [
            "• New feature",
            "• Changed behavior · Premium",
            "• Fixed bug",
        ])
        XCTAssertEqual(note.presentationSections.map(\.category), [.new, .changed, .fixed])
        XCTAssertEqual(
            note.presentationSections.map { $0.category.systemImage },
            ["sparkles", "paintbrush.fill", "ladybug.fill"]
        )
    }

    func testPresentationSectionsOmitEmptyCategoriesAndKeepEveryBullet() {
        let note = ReleaseNote(
            version: "1.2.3",
            new: [.init("First"), .init("Second", badge: .premium)],
            fixed: [.init("Third")]
        )

        XCTAssertEqual(note.presentationSections.map(\.category), [.new, .fixed])
        XCTAssertEqual(note.presentationSections.flatMap(\.bullets), note.new + note.fixed)
        XCTAssertEqual(note.presentationSections.first?.subtitle, "• First\n• Second · Premium")
    }

    func testWhatsNewConversionPreservesVersionAndFeatureContent() {
        let note = ReleaseNote(
            version: "1.2.3",
            new: [.init("New feature")],
            fixed: [.init("Fixed bug")]
        )

        let whatsNew = note.whatsNew()

        XCTAssertEqual(whatsNew.version.description, "1.2.3")
        XCTAssertEqual(whatsNew.title.text.attributedString.string, "What's New in 1.2.3")
        XCTAssertEqual(
            whatsNew.features.map { $0.title.attributedString.string },
            ["New", "Fixed"]
        )
        XCTAssertEqual(
            whatsNew.features.map { $0.subtitle.attributedString.string },
            ["• New feature", "• Fixed bug"]
        )
        XCTAssertEqual(whatsNew.primaryAction.title.attributedString.string, "Continue")
        XCTAssertNil(whatsNew.secondaryAction)
        XCTAssertEqual(
            ReleaseNotes.whatsNewLayout.footerPrimaryActionButtonCornerRadius,
            Radius.standard
        )
    }

    func testCollectionAddsHistoryOnlyToLatestRelease() {
        let collection = ReleaseNotes.whatsNewCollection

        XCTAssertEqual(collection.count, ReleaseNotes.all.count)
        XCTAssertNotNil(collection.first?.secondaryAction)
        XCTAssertNil(collection.dropFirst().first?.secondaryAction)
    }

    func testLatestReleaseRendersAtStandardAndAccessibilitySizes() async throws {
        let latest = try XCTUnwrap(ReleaseNotes.latestWhatsNew)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )

        let configurations: [(
            name: String,
            colorScheme: ColorScheme,
            dynamicTypeSize: DynamicTypeSize,
            interfaceStyle: UIUserInterfaceStyle
        )] = [
            ("Light Standard", .light, .large, .light),
            ("Dark Accessibility", .dark, .accessibility3, .dark),
        ]

        for configuration in configurations {
            let content = WhatsNewPresentationView(whatsNew: latest)
            .environment(\.colorScheme, configuration.colorScheme)
            .environment(\.dynamicTypeSize, configuration.dynamicTypeSize)
            let hostingController = UIHostingController(rootView: content)
            hostingController.overrideUserInterfaceStyle = configuration.interfaceStyle
            let window = UIWindow(windowScene: windowScene)
            window.frame = frame
            window.rootViewController = hostingController
            window.makeKeyAndVisible()
            hostingController.view.frame = frame
            hostingController.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))

            let image = UIGraphicsImageRenderer(bounds: frame).image { _ in
                window.drawHierarchy(in: frame, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "What's New \(configuration.name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }

    func testFreshInstallPresentsCurrentVersionOnlyOnce() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let latest = try XCTUnwrap(ReleaseNotes.latest)
        let currentVersion = WhatsNew.Version(stringLiteral: latest.version)
        let environment = ReleaseNotes.makeWhatsNewEnvironment(
            userDefaults: defaults,
            currentVersion: currentVersion
        )

        XCTAssertEqual(environment.whatsNew()?.version, currentVersion)

        environment.whatsNewVersionStore.save(presentedVersion: currentVersion)

        XCTAssertNil(environment.whatsNew())
    }

    func testLegacyCurrentVersionMigratesWithoutDuplicatePresentation() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let latest = try XCTUnwrap(ReleaseNotes.latest)
        let currentVersion = WhatsNew.Version(stringLiteral: latest.version)
        defaults.set(latest.version, forKey: ReleaseNotes.legacyLastSeenVersionKey)

        let environment = ReleaseNotes.makeWhatsNewEnvironment(
            userDefaults: defaults,
            currentVersion: currentVersion
        )

        XCTAssertNil(defaults.object(forKey: ReleaseNotes.legacyLastSeenVersionKey))
        XCTAssertTrue(environment.whatsNewVersionStore.hasPresented(currentVersion))
        XCTAssertNil(environment.whatsNew())
    }

    func testLegacyOlderVersionStillPresentsCurrentVersion() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let latest = try XCTUnwrap(ReleaseNotes.latest)
        let previous = try XCTUnwrap(ReleaseNotes.previous.first)
        let currentVersion = WhatsNew.Version(stringLiteral: latest.version)
        let previousVersion = WhatsNew.Version(stringLiteral: previous.version)
        defaults.set(previous.version, forKey: ReleaseNotes.legacyLastSeenVersionKey)

        let environment = ReleaseNotes.makeWhatsNewEnvironment(
            userDefaults: defaults,
            currentVersion: currentVersion
        )

        XCTAssertNil(defaults.object(forKey: ReleaseNotes.legacyLastSeenVersionKey))
        XCTAssertTrue(environment.whatsNewVersionStore.hasPresented(previousVersion))
        XCTAssertEqual(environment.whatsNew()?.version, currentVersion)
    }

    private func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "ReleaseNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
