import XCTest
@testable import NotchBrowser

final class MotionSettingsTests: XCTestCase {
    func testExistingSettingsKeepTabsProfilesAndDisplayPreferences() throws {
        var original = SettingsData()
        let profileID = UUID()
        original.profiles.append(Profile(id: profileID, name: "仕事"))
        original.pinnedTabs = [PinnedTab(name: "Docs", url: "https://example.com", profileID: profileID)]
        original.displays["display"] = DisplaySettings(enabled: true, idleOpacity: 0.5, width: 800, height: 500)
        original.openTabBehavior = .pinned(original.pinnedTabs[0].id)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "motion")
        let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.profiles, original.profiles)
        XCTAssertEqual(decoded.pinnedTabs, original.pinnedTabs)
        XCTAssertEqual(decoded.displays, original.displays)
        XCTAssertEqual(decoded.openTabBehavior, original.openTabBehavior)
        XCTAssertEqual(decoded.motion, MotionSettings())
    }

    func testMotionOptionsPersistIncludingImmediateHoverAndNoAnimation() throws {
        for style in NotchAnimationStyle.allCases {
            var settings = SettingsData()
            settings.motion.openDelay = 0
            settings.motion.closeDelay = 2.75
            settings.motion.openDuration = 0.15
            settings.motion.closeDuration = 1.2
            settings.motion.style = style
            let restored = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(restored.motion, settings.motion)
        }
    }

    func testInvalidAndFutureMotionValuesDoNotResetOtherSettings() throws {
        let json = #"{"countdownMinutes":55,"motion":{"openDelay":-1,"closeDelay":99,"openDuration":"bad","closeDuration":0,"style":"future-style"}}"#
        let decoded = try JSONDecoder().decode(SettingsData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.countdownMinutes, 55)
        XCTAssertEqual(decoded.motion.openDelay, 0)
        XCTAssertEqual(decoded.motion.closeDelay, 3)
        XCTAssertEqual(decoded.motion.openDuration, 0.28)
        XCTAssertEqual(decoded.motion.closeDuration, 0.05)
        XCTAssertEqual(decoded.motion.style, .responsive)
    }
}
