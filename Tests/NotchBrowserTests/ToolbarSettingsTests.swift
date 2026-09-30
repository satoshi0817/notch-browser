import XCTest
@testable import NotchBrowser

final class ToolbarSettingsTests: XCTestCase {
    func testLegacySettingsEnableQuitConfirmationAndVisibleSettingsAndQuit() throws {
        let settings = try JSONDecoder().decode(SettingsData.self, from: Data(#"{"countdownMinutes":55}"#.utf8))
        XCTAssertTrue(settings.confirmBeforeQuit)
        XCTAssertTrue(settings.toolbarActions.contains(.settings))
        XCTAssertTrue(settings.toolbarActions.contains(.quit))
        XCTAssertEqual(settings.countdownMinutes, 55)
    }

    func testEmptyToolbarAndSuppressedConfirmationPersist() throws {
        var settings = SettingsData()
        settings.toolbarActions = []
        settings.confirmBeforeQuit = false
        let restored = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.toolbarActions, [])
        XCTAssertFalse(restored.confirmBeforeQuit)
    }

    func testUnknownActionsDoNotDiscardOtherPreferences() throws {
        let settings = try JSONDecoder().decode(SettingsData.self, from: Data(#"{"toolbarActions":["settings","future","settings","quit"],"confirmBeforeQuit":false,"countdownMinutes":55}"#.utf8))
        XCTAssertEqual(settings.toolbarActions, [.settings, .quit])
        XCTAssertFalse(settings.confirmBeforeQuit)
        XCTAssertEqual(settings.countdownMinutes, 55)
    }
}
