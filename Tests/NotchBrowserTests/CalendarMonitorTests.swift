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
}
