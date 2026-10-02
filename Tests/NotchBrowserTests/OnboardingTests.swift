import XCTest
import AppKit
@testable import NotchBrowser

final class OnboardingTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "NotchBrowserTests.Onboarding." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testFreshInstallResumesUntilFinishedAndExistingInstallIsNotInterrupted() {
        let fresh = defaults()
        XCTAssertTrue(OnboardingState.shouldPresent(defaults: fresh))
        OnboardingState.begin(defaults: fresh)
        fresh.set(Data("{}".utf8), forKey: "settings.v1")
        XCTAssertTrue(OnboardingState.shouldPresent(defaults: fresh), "A partially completed tour should resume")
        OnboardingState.complete(defaults: fresh)
        XCTAssertFalse(OnboardingState.shouldPresent(defaults: fresh))

        let existing = defaults()
        existing.set(Data("{}".utf8), forKey: "settings.v1")
        XCTAssertFalse(OnboardingState.shouldPresent(defaults: existing))
        let legacy = defaults()
        legacy.set(Data("[]".utf8), forKey: "savedApps")
        XCTAssertFalse(OnboardingState.shouldPresent(defaults: legacy))
        let usedDefaultsOnly = defaults()
        usedDefaultsOnly.set(Date(), forKey: "updates.nextCheck")
        XCTAssertFalse(OnboardingState.shouldPresent(defaults: usedDefaultsOnly))
    }

    func testChoicesApplyOnlyToRelatedSettings() {
        var settings = SettingsData()
        settings.toolbarActions = [.back, .settings, .quit]
        settings.pinnedTabs = [PinnedTab(name: "My page", url: "https://example.com")]
        var choices = OnboardingChoices(settings: settings)
        choices.calendarCountdown = false
        choices.notionButton = true
        choices.hideFromCapture = false
        choices.apply(to: &settings)
        XCTAssertEqual(settings.shelfTrigger, .automatic)
        XCTAssertFalse(settings.countdownEnabled)
        XCTAssertFalse(settings.hideFromScreenCapture)
        XCTAssertFalse(settings.notionEnabled, "Agent activation requires a verified Notion connection")
        XCTAssertEqual(settings.toolbarActions, [.back, .settings, .quit])
        XCTAssertEqual(settings.pinnedTabs.first?.name, "My page")
        choices.apply(to: &settings)
        XCTAssertFalse(settings.notionEnabled)
        choices.notionButton = false
        choices.apply(to: &settings)
        XCTAssertFalse(settings.notionEnabled)
        XCTAssertEqual(settings.toolbarActions, [.back, .settings, .quit])

        settings.shelfTrigger = .nearby
        choices.apply(to: &settings)
        XCTAssertEqual(settings.shelfTrigger, .nearby, "The guide must preserve dormant shelf preferences")
    }

    func testAddingPinnedPagesValidatesAndAvoidsDuplicates() {
        var choices = OnboardingChoices(settings: SettingsData(), screens: [])
        XCTAssertTrue(choices.addPage(name: "", address: "example.com"))
        XCTAssertEqual(choices.pinnedTabs.last?.name, "example.com")
        XCTAssertEqual(choices.pinnedTabs.last?.url, "https://example.com")
        XCTAssertFalse(choices.addPage(name: "Duplicate", address: "https://example.com/"))
        XCTAssertFalse(choices.addPage(name: "Script", address: "javascript:alert(1)"))
        XCTAssertFalse(choices.addPage(name: "Credentials", address: "https://user:pass@example.com"))
        XCTAssertFalse(choices.addPage(name: "Broken", address: "not a URL"))
        var settings = SettingsData()
        choices.apply(to: &settings, screens: [])
        XCTAssertEqual(settings.pinnedTabs, choices.pinnedTabs)
    }

    func testDisplayMotionAndBrowserChoicesAreApplied() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let id = screen.displayUUID
        var settings = SettingsData()
        settings.displays[id] = DisplaySettings(enabled: true, idleOpacity: 0.42, width: 700, height: 500)
        var choices = OnboardingChoices(settings: settings, screens: [screen])
        choices.setDisplay(id, enabled: false)
        XCTAssertTrue(choices.enabledDisplayIDs.contains(id), "The last enabled display cannot be turned off")
        choices.selectDisplayPreset(.spacious)
        choices.motion = MotionPreset.quick.settings
        choices.externalBrowserBundleID = "com.apple.Safari"
        choices.apply(to: &settings, screens: [screen])
        XCTAssertEqual(settings.displays[id]?.width, DisplayPreset.spacious.settings(for: screen, enabled: true).width)
        XCTAssertEqual(settings.displays[id]?.idleOpacity, 0.42)
        XCTAssertEqual(settings.motion, MotionPreset.quick.settings)
        XCTAssertEqual(settings.externalBrowserBundleID, "com.apple.Safari")
    }

    func testMotionPreviewRespectsConfiguredDelays() {
        let settings = MotionSettings()
        let beforeOpen = MotionPreviewTimeline.values(at: settings.openDelay / 2, settings: settings, playing: true, reduceMotion: false)
        XCTAssertEqual(beforeOpen.size, 0)
        let duringOpen = MotionPreviewTimeline.values(at: settings.openDelay + settings.openDuration / 2, settings: settings, playing: true, reduceMotion: false)
        XCTAssertGreaterThan(duringOpen.size, 0)
        let beforeClose = MotionPreviewTimeline.values(at: settings.openDelay + settings.openDuration + 0.2, settings: settings, playing: true, reduceMotion: false)
        XCTAssertEqual(beforeClose.size, 1)
        let afterClose = MotionPreviewTimeline.values(at: settings.openDelay + settings.openDuration + 0.65 + settings.closeDelay + settings.closeDuration, settings: settings, playing: true, reduceMotion: false)
        XCTAssertEqual(afterClose.size, 0, accuracy: 0.0001)
        let noMotion = MotionPreviewTimeline.values(at: settings.openDelay + 0.001, settings: settings, playing: true, reduceMotion: true)
        XCTAssertEqual(noMotion.size, 1)
        let instant = MotionPreset.instant.settings
        XCTAssertEqual(MotionPreviewTimeline.totalDuration(settings: instant, reduceMotion: false), 0.65)
        XCTAssertEqual(MotionPreviewTimeline.values(at: 0.01, settings: instant, playing: true, reduceMotion: false).size, 1)
        XCTAssertEqual(MotionPreviewTimeline.values(at: 0.65, settings: instant, playing: true, reduceMotion: false).size, 0)
    }
}
