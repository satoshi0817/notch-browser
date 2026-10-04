import EventKit
import Foundation

/// Countdown to the current event's end or the next event's start.
struct CalendarBadge: Equatable {
    struct Identity: Equatable {
        let identifier: String
        let startDate: Date
    }
    let identity: Identity
    let minutes: Int
    let title: String
    let startDate: Date

    var helperText: String {
        "\(startTime) · \(title.components(separatedBy: .newlines).joined(separator: " "))"
    }

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
            badge = Self.badge(for: store.events(matching: predicate), now: now, upcomingEnd: end)
        }

        if lastValue != .some(badge) {
            lastValue = .some(badge)
            onChange?(badge)
        }
    }

    static func badge(for events: [EKEvent], now: Date, upcomingEnd: Date) -> CalendarBadge? {
        let candidates = events.filter {
            !$0.isAllDay && $0.endDate > now && $0.startDate <= upcomingEnd && !isDeclined($0)
        }
        let current = candidates.filter { $0.startDate <= now }.min { $0.startDate < $1.startDate }
        let next = current ?? candidates.min { $0.startDate < $1.startDate }
        return next.map {
            let target = $0.startDate <= now ? $0.endDate! : $0.startDate!
            return CalendarBadge(identity: .init(identifier: $0.eventIdentifier ?? $0.calendarItemIdentifier, startDate: $0.startDate),
                                 minutes: Int((target.timeIntervalSince(now) / 60).rounded(.up)),
                                 title: $0.title ?? "", startDate: $0.startDate)
        }
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }
}

/// Session-only dismissal, independent of countdown updates.
struct CalendarBadgePresentation {
    private(set) var selected: CalendarBadge?
    private var dismissedIdentity: CalendarBadge.Identity?
    var visible: CalendarBadge? {
        guard selected?.identity != dismissedIdentity else { return nil }
        return selected
    }
    mutating func update(_ event: CalendarBadge?) {
        if selected?.identity != event?.identity { dismissedIdentity = nil }
        selected = event
    }
    mutating func dismiss() { dismissedIdentity = selected?.identity }
}
