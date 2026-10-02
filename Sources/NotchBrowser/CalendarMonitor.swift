import EventKit
import Foundation

/// Watches the system calendars (EventKit) and reports minutes until the next event
/// that starts within `thresholdMinutes`, or nil when there is none.
struct CalendarBadge: Equatable {
    let minutes: Int
    let title: String
    let startDate: Date

    var startTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: startDate)
    }
}

final class CalendarMonitor {
    var onChange: ((CalendarBadge?) -> Void)?
    var isEnabled = true {
        didSet {
            requestAccessIfNeeded()
            refresh()
        }
    }
    var thresholdMinutes = 30 { didSet { refresh() } }

    private let store = EKEventStore()
    private var timer: Timer?
    private var hasAccess = false
    private var isStarted = false
    private var didRequestAccess = false
    private var lastValue: CalendarBadge??

    func start() {
        isStarted = true
        requestAccessIfNeeded()
    }

    /// Calendar access is only needed for the countdown, so don't ask while it's off.
    private func requestAccessIfNeeded() {
        guard isStarted, isEnabled, !didRequestAccess else { return }
        didRequestAccess = true
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
        var badge: CalendarBadge?
        if hasAccess, isEnabled {
            let now = Date()
            let end = now.addingTimeInterval(TimeInterval(thresholdMinutes * 60))
            let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
            let next = store.events(matching: predicate)
                .filter { !$0.isAllDay && $0.startDate > now && !isDeclined($0) }
                .min { $0.startDate < $1.startDate }
            badge = next.map { CalendarBadge(minutes: Int(($0.startDate.timeIntervalSince(now) / 60).rounded(.up)), title: $0.title ?? "", startDate: $0.startDate) }
        }

        if lastValue != .some(badge) {
            lastValue = .some(badge)
            onChange?(badge)
        }
    }

    private func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }
}
