import AppKit
import EventKit
import XCTest
@testable import NotchBrowser

final class CalendarMonitorTests: XCTestCase {
    private let store = EKEventStore()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(start: TimeInterval, end: TimeInterval, allDay: Bool = false) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = "Meeting"
        event.startDate = now.addingTimeInterval(start)
        event.endDate = now.addingTimeInterval(end)
        event.isAllDay = allDay
        return event
    }

    private func badge(_ events: [EKEvent]) -> CalendarBadge? {
        CalendarMonitor.badge(for: events, now: now, upcomingEnd: now.addingTimeInterval(30 * 60))
    }

    func testCurrentUsesRemainingMinutesAndKeepsStartTime() throws {
        let current = event(start: -600, end: 601)
        let result = try XCTUnwrap(badge([event(start: 60, end: 300), current]))
        XCTAssertEqual(result.minutes, 11)
        XCTAssertEqual(result.startDate, current.startDate)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        XCTAssertEqual(result.startTime, formatter.string(from: current.startDate))
    }

    func testUpcomingStillUsesEarliestStart() throws {
        let next = event(start: 61, end: 600)
        let result = try XCTUnwrap(badge([event(start: 300, end: 900), next]))
        XCTAssertEqual(result.minutes, 2)
        XCTAssertEqual(result.startDate, next.startDate)
    }

    func testStartIsInclusiveAndEndIsExclusive() {
        XCTAssertEqual(badge([event(start: 0, end: 120)])?.minutes, 2)
        XCTAssertNil(badge([event(start: -120, end: 0)]))
        XCTAssertNil(badge([event(start: 1801, end: 2400)]))
    }

    func testAllDayEventsNeverBecomeCandidates() throws {
        let allDay = event(start: -3600, end: 86400, allDay: true)
        XCTAssertNil(badge([allDay]))
        XCTAssertNil(badge([event(start: 60, end: 86400, allDay: true)]))
        let upcoming = event(start: 120, end: 600)
        XCTAssertEqual(try XCTUnwrap(badge([allDay, upcoming])).startDate, upcoming.startDate)
    }

    func testOverlappingCurrentEventsKeepEarliestStartOrdering() throws {
        let earlier = event(start: -600, end: 120)
        let later = event(start: -300, end: 600)
        XCTAssertEqual(try XCTUnwrap(badge([later, earlier])).minutes, 2)
    }

    func testDismissalSurvivesCountdownUpdatesAndResetsOnReplacement() throws {
        let first = try XCTUnwrap(badge([event(start: 60, end: 600)]))
        var presentation = CalendarBadgePresentation()
        presentation.update(first)
        presentation.dismiss()
        XCTAssertNil(presentation.visible)
        let updated = CalendarBadge(identity: first.identity, minutes: 1, title: "Renamed", startDate: first.startDate)
        presentation.update(updated)
        XCTAssertNil(presentation.visible)
        let replacement = try XCTUnwrap(badge([event(start: 120, end: 900)]))
        presentation.update(replacement)
        XCTAssertEqual(presentation.visible, replacement)
        presentation.update(first)
        XCTAssertEqual(presentation.visible, first)
        presentation.dismiss()
        presentation.update(nil)
        presentation.update(first)
        XCTAssertEqual(presentation.visible, first)
        var relaunched = CalendarBadgePresentation()
        relaunched.update(first)
        XCTAssertEqual(relaunched.visible, first)
    }

    func testHelperStartsWithTimeAndNormalizesTitle() throws {
        let meeting = event(start: 60, end: 600)
        meeting.title = "Planning\nmeeting"
        let result = try XCTUnwrap(badge([meeting]))
        XCTAssertEqual(result.helperText, "\(result.startTime) · Planning meeting")
    }

    @MainActor
    func testCalendarWingsAndClicks() throws {
        let root = NotchRootView(frame: NSRect(x: 0, y: 0, width: 280, height: 72))
        root.setBadge(event: try XCTUnwrap(badge([event(start: 60, end: 600)])), visible: true)
        let icon = try XCTUnwrap(root.subviews.compactMap { $0 as? NSImageView }.first)
        let label = try XCTUnwrap(root.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertLessThanOrEqual(icon.frame.maxX, 40)
        XCTAssertGreaterThanOrEqual(label.frame.minX, 240)
        XCTAssertEqual(icon.frame.midY, label.frame.midY)
        XCTAssertGreaterThanOrEqual(icon.frame.minY, NotchRootView.helperHeight)
        var dismissals = 0
        var opens = 0
        root.onCalendarClick = { dismissals += 1 }
        root.onClick = { opens += 1 }
        for point in [NSPoint(x: icon.frame.midX, y: icon.frame.midY),
                      NSPoint(x: label.frame.midX, y: label.frame.midY), NSPoint(x: 10, y: 9)] {
            XCTAssertTrue(root.hitTest(point) === root)
            let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            root.mouseDown(with: click)
        }
        XCTAssertEqual(dismissals, 3)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(root.frame.width, 280)
    }
}
