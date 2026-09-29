import AppKit
import XCTest
@testable import NotchBrowser

final class UpdateCheckerTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "NotchBrowserTests.Updates." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func release(_ tag: String = "v0.2.2", prerelease: Bool = false, asset: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": false, "prerelease": prerelease,
            "assets": asset ? [["name": "NotchBrowser-" + String(tag.dropFirst()) + ".zip", "state": "uploaded", "size": 123]] : []])
    }
    func testStableVersionOrderingAndReleaseValidation() throws {
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("v0.10.0")), try XCTUnwrap(ReleaseVersion("0.9.9")))
        XCTAssertEqual(ReleaseVersion("v1.2"), ReleaseVersion("1.2.0"))
        for value in ["v1.2.3-beta", "v1.2.3/path", "v1..2", "abc", "1.2.3.4", "-1.2", "1.2.99999999999999999999999999"] { XCTAssertNil(ReleaseVersion(value)) }
        let valid = try JSONDecoder().decode(GitHubRelease.self, from: release())
        XCTAssertTrue(valid.isUpdate(from: "0.2.1"))
        XCTAssertFalse(valid.isUpdate(from: "0.2.2"))
        XCTAssertFalse(valid.isUpdate(from: "1.0.0"))
        XCTAssertEqual(valid.pageURL?.absoluteString, "https://github.com/satoshi0817/notch-browser/releases/tag/v0.2.2")
        XCTAssertFalse(try JSONDecoder().decode(GitHubRelease.self, from: release(prerelease: true)).isUpdate(from: "0.2.1"))
        XCTAssertFalse(try JSONDecoder().decode(GitHubRelease.self, from: release(asset: false)).isUpdate(from: "0.2.1"))
    }
    func testScheduleSurvivesRestartAndSkipOnlyAppliesToOneRelease() {
        let defaults = defaults()
        let schedule = UpdateSchedule(defaults: defaults)
        let now = Date(timeIntervalSince1970: 100000)
        XCTAssertTrue(schedule.isDue(at: now))
        schedule.recordAttempt(at: now, succeeded: true)
        XCTAssertFalse(UpdateSchedule(defaults: defaults).isDue(at: now.addingTimeInterval(86399)))
        XCTAssertTrue(schedule.isDue(at: now.addingTimeInterval(86400)))
        schedule.remindLater("v0.2.2", at: now)
        XCTAssertFalse(schedule.shouldRemind("v0.2.2", at: now))
        XCTAssertTrue(schedule.shouldRemind("v0.2.2", at: now.addingTimeInterval(86400)))
        schedule.skip("v0.2.2")
        XCTAssertFalse(UpdateSchedule(defaults: defaults).shouldRemind("v0.2.2", at: now.addingTimeInterval(86400)))
        XCTAssertTrue(schedule.shouldRemind("v0.2.3", at: now))
        schedule.enabled = false
        XCTAssertFalse(schedule.isDue(at: now.addingTimeInterval(86400)))
    }
    @MainActor
    func testAutomaticThrottleSkipAndManualOverride() async throws {
        let defaults = defaults()
        let body = try release()
        var calls = 0
        let checker = UpdateChecker(defaults: defaults, currentVersion: "0.2.1") { request in
            calls += 1
            XCTAssertEqual(request.url, UpdateChecker.endpoint)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        var reminders = 0
        checker.onUpdate = { _, _ in reminders += 1 }
        let now = Date()
        await checker.check(manual: false, now: now)
        XCTAssertEqual(reminders, 1)
        await checker.check(manual: false, now: now.addingTimeInterval(100))
        XCTAssertEqual(calls, 1)
        checker.skip(try XCTUnwrap(checker.available))
        await checker.check(manual: false, now: now.addingTimeInterval(86400))
        XCTAssertEqual(reminders, 1)
        checker.automatic = false
        await checker.check(manual: true, now: now.addingTimeInterval(86401))
        XCTAssertEqual(reminders, 2)
        XCTAssertFalse(checker.isChecking)
    }
    @MainActor
    func testNetworkFailureBackoffAndManualErrorMessage() async {
        let defaults = defaults()
        var calls = 0
        let checker = UpdateChecker(defaults: defaults, currentVersion: "0.2.1") { _ in calls += 1; throw URLError(.notConnectedToInternet) }
        var messages = 0
        checker.onMessage = { _ in messages += 1 }
        let now = Date()
        await checker.check(manual: false, now: now)
        XCTAssertEqual(messages, 0)
        await checker.check(manual: false, now: now.addingTimeInterval(3500))
        XCTAssertEqual(calls, 1)
        await checker.check(manual: false, now: now.addingTimeInterval(3600))
        XCTAssertEqual(calls, 2)
        await checker.check(manual: true, now: now)
        XCTAssertEqual(messages, 1)
        XCTAssertFalse(checker.isChecking)
    }
    @MainActor
    func testIncompleteReleaseAndHTTPFailureAreNotReportedAsUpToDate() async throws {
        for code in [200, 403, 404, 429, 500] {
            let body = try release(asset: false)
            let checker = UpdateChecker(defaults: defaults(), currentVersion: "0.2.1") { request in
                (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
            await checker.check()
            XCTAssertTrue(checker.status.hasPrefix("確認できません"))
            XCTAssertNil(checker.available)
        }
    }
}
