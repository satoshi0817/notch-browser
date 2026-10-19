import AppKit
import XCTest
@testable import NotchBrowser

final class Notch021Tests: XCTestCase {
    func testFailedReloadIconIsClockwiseEvenIfWebKitStillReportsLoading() {
        var state = WebRecoveryState()
        XCTAssertEqual(state.reloadSymbol(isLoading: true, restoring: false, failureVisible: false), "xmark")
        XCTAssertEqual(state.reloadSymbol(isLoading: true, restoring: false, failureVisible: true), "arrow.clockwise")
        state.finish(success: false)
        for restoring in [false, true] {
            for failureVisible in [false, true] {
                XCTAssertEqual(state.reloadSymbol(isLoading: true, restoring: restoring, failureVisible: failureVisible), "arrow.clockwise")
            }
        }
        state.manualReload()
        XCTAssertEqual(state.reloadSymbol(isLoading: true, restoring: false, failureVisible: false), "xmark")
    }

    #if DEBUG
    func testDebugRestSecondsArgument() {
        XCTAssertEqual(TabRestDebugArguments.seconds(arguments: ["preview", "--tab-rest-seconds=20"]), 20)
        XCTAssertEqual(TabRestDebugArguments.seconds(arguments: ["preview", "--tab-rest-seconds=0.5"]), 0.5)
        for argument in ["--tab-rest-seconds=0", "--tab-rest-seconds=-1", "--tab-rest-seconds=nan",
                         "--tab-rest-seconds=inf", "--tab-rest-seconds=", "--tab-rest-seconds=abc",
                         "--tab-rest-seconds-other=20"] {
            XCTAssertNil(TabRestDebugArguments.seconds(arguments: ["preview", argument]))
        }
        XCTAssertNil(TabRestDebugArguments.seconds(arguments: ["preview"]))
    }
    #endif

    func testAutomaticReloadBudgetSurvivesSuccess() {
        var state = WebRecoveryState()
        state.terminate()
        XCTAssertTrue(state.terminated)
        XCTAssertTrue(state.beginAutomatic())
        state.finish(success: true)
        state.terminate()
        XCTAssertFalse(state.beginAutomatic())
        XCTAssertTrue(state.failed)
    }

    func testManualReloadRearmsExactlyOneAutomaticAttempt() {
        var state = WebRecoveryState()
        state.terminate()
        XCTAssertTrue(state.beginAutomatic())
        state.finish(success: false)
        XCTAssertFalse(state.beginAutomatic())
        state.manualReload()
        XCTAssertFalse(state.automaticAttemptUsed)
        XCTAssertFalse(state.failed)
        state.finish(success: true)
        state.terminate()
        XCTAssertTrue(state.beginAutomatic())
        state.finish(success: false)
        state.terminate()
        XCTAssertFalse(state.beginAutomatic())
    }

    func testBackgroundTerminationDoesNotConsumeAttemptUntilShown() {
        var state = WebRecoveryState()
        state.terminate()
        XCTAssertFalse(state.automaticAttemptUsed)
        XCTAssertTrue(state.terminated)
        XCTAssertTrue(state.beginAutomatic())
        XCTAssertTrue(state.recovering)
        XCTAssertFalse(state.terminated)
        XCTAssertFalse(state.beginAutomatic())
        XCTAssertFalse(state.failed)
    }

    func testEveryRestExclusionAndTheirCombinations() {
        for mask in 0..<16 {
            XCTAssertEqual(TabRestRules.eligible(
                visibleSelected: mask & 1 != 0, playingMedia: mask & 2 != 0,
                editing: mask & 4 != 0, native: mask & 8 != 0), mask == 0)
        }
        // Web pinned tabs follow the same eligibility rule as ordinary Web tabs.
        XCTAssertTrue(TabRestRules.eligible(visibleSelected: false, playingMedia: false, editing: false, native: false))
        for _ in [PinnedTabsSettings.notionID, PinnedTabsSettings.tasksID, PinnedTabsSettings.meetingsID] {
            XCTAssertFalse(TabRestRules.eligible(visibleSelected: false, playingMedia: false, editing: false, native: true))
        }
    }

    func testRestSettingChoicesDefaultAndPersistence() throws {
        XCTAssertEqual(TabRestInterval.allCases.map(\.title), ["15分", "30分", "1時間", "休ませない"])
        XCTAssertEqual(TabRestInterval.allCases.map(\.rawValue), [900, 1800, 3600, 0])
        XCTAssertEqual(SettingsData().tabRestInterval, .thirtyMinutes)
        XCTAssertEqual(try JSONDecoder().decode(SettingsData.self, from: Data("{}".utf8)).tabRestInterval, .thirtyMinutes)
        for interval in TabRestInterval.allCases {
            var data = SettingsData(); data.tabRestInterval = interval
            let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(data))
            XCTAssertEqual(decoded.tabRestInterval, interval)
        }
    }

    @MainActor func testSnapshotClearAndOwnerCleanupReleasePixels() {
        var snapshot: TabSnapshot? = TabSnapshot()
        weak var pixels: NSImage?
        autoreleasepool {
            let image = NSImage(size: NSSize(width: 10, height: 10))
            pixels = image
            snapshot?.store(image)
        }
        XCTAssertNotNil(pixels)
        snapshot?.clear()
        XCTAssertNil(snapshot?.image)
        XCTAssertNil(pixels)
        autoreleasepool {
            let image = NSImage(size: NSSize(width: 10, height: 10))
            pixels = image
            snapshot?.store(image)
        }
        snapshot = nil
        XCTAssertNil(pixels)
    }
}
