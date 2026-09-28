import EventKit
import Foundation

/// Watches the system calendars (EventKit) and reports minutes until the next event
/// that starts within `thresholdMinutes`, or nil when there is none.
final class CalendarMonitor {
    var onChange: ((Int?) -> Void)?
    var isEnabled = true { didSet { refresh() } }
    var thresholdMinutes = 30 { didSet { refresh() } }

    private let store = EKEventStore()
    private var timer: Timer?
    private var hasAccess = false
    private var lastValue: Int??

    func start() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { self?.begin() }
        }
    }

    private func begin() {
        hasAccess = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .EKEventStoreChanged, object: store)
        timer = .scheduledTimer(timeInterval: 15, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        refresh()
    }

    @objc func refresh() {
        var minutes: Int?
        if hasAccess, isEnabled {
            let now = Date()
            let end = now.addingTimeInterval(TimeInterval(thresholdMinutes * 60))
            let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
            let next = store.events(matching: predicate)
                .filter { !$0.isAllDay && $0.startDate > now && !isDeclined($0) }
                .map(\.startDate)
                .min()
            minutes = next.map { Int(($0.timeIntervalSince(now) / 60).rounded(.up)) }
        }

        if lastValue != .some(minutes) {
            lastValue = .some(minutes)
            onChange?(minutes)
        }
    }

    private func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }
}
