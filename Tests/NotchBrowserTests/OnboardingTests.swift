import XCTest
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
        choices.automaticShelf = false
        choices.calendarCountdown = false
        choices.notionButton = true
        choices.hideFromCapture = false
        choices.apply(to: &settings)
        XCTAssertEqual(settings.shelfTrigger, .manual)
        XCTAssertFalse(settings.countdownEnabled)
        XCTAssertFalse(settings.hideFromScreenCapture)
        XCTAssertEqual(settings.toolbarActions, [.back, .notion, .settings, .quit])
        XCTAssertEqual(settings.pinnedTabs.first?.name, "My page")
        choices.apply(to: &settings)
        XCTAssertEqual(settings.toolbarActions.filter { $0 == .notion }.count, 1)
        choices.notionButton = false
        choices.apply(to: &settings)
        XCTAssertFalse(settings.toolbarActions.contains(.notion))

        settings.shelfTrigger = .nearby
        choices.automaticShelf = true
        choices.apply(to: &settings)
        XCTAssertEqual(settings.shelfTrigger, .nearby, "Reopening the guide must preserve a more specific shelf preference")
    }
}
