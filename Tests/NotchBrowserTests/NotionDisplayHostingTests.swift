import AppKit
import SwiftUI
import XCTest
@testable import NotchBrowser

/// Render the shared display section in the host configurations used by settings,
/// tab settings, and DesignPreview. No live stores, credentials, or network calls.
@MainActor final class NotionDisplayHostingTests: XCTestCase {
    private let pages: [NotionPageDisplaySettings.Page] = [.tasks, .meetings, .agents]

    private func isolatedSettings() throws -> (SettingsStore, UserDefaults, String) {
        _ = NSApplication.shared
        let suite = "NotionDisplayHostingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults)
        settings.data.tasksTabSymbol = "star"
        settings.data.meetingsTabSymbol = "person.2"
        settings.data.agentsTabSymbol = "bubble.left"
        settings.data.tasksTabDisplay = .titleOnly
        settings.data.meetingsTabDisplay = .iconAndTitle
        return (settings, defaults, suite)
    }

    private func render(_ view: NSView, dark: Bool = false) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if dark { window.appearance = NSAppearance(named: .darkAqua) }
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        window.contentView = nil
    }

    func testPinnedSettingsDisplaySectionRendersInHostingController() throws {
        let (settings, defaults, suite) = try isolatedSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        for page in pages {
            // SettingsWindowController uses NSHostingController with an injected
            // root environment; the display section receives its own explicit store.
            let controller = NSHostingController(rootView: Form {
                NotionPageDisplaySettings(page: page, settings: settings)
            }.formStyle(.grouped).environmentObject(settings))
            try render(controller.view)
        }
    }

    func testTabSettingsDisplaySectionRendersWithoutEnvironmentObject() throws {
        let (settings, defaults, suite) = try isolatedSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        for page in pages {
            // BrowserViewController's task/meeting panels use NSHostingView and
            // do not inject SettingsStore as an environment object.
            let host = NSHostingView(rootView: Form {
                NotionPageDisplaySettings(page: page, settings: settings)
            }.formStyle(.grouped))
            try render(host)
        }
    }

    func testDesignPreviewAndAgentDisplayControlsRenderInExistingSection() throws {
        let (settings, defaults, suite) = try isolatedSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        for page in pages {
            // Also exercise the extracted controls directly inside a section,
            // matching the agent settings composition and preview's dark window.
            let controller = NSHostingController(rootView: Form {
                Section("表示") {
                    NotionPageDisplayControls(page: page, settings: settings)
                }
            }.formStyle(.grouped))
            try render(controller.view, dark: true)
        }
    }
}
