import Foundation
import Combine

enum MeetingSearchEscapeRules {
    static func shouldClear(meetingsVisible: Bool, text: String, hasResults: Bool) -> Bool {
        meetingsVisible && (!text.isEmpty || hasResults)
    }
}

/// Owned by each browser, shared with its SwiftUI panel; no first-responder dependency.
@MainActor final class MeetingSearchEscapeController: ObservableObject {
    @Published var input = MeetingSearchInputState()
    @Published private(set) var resetID = UUID()
    var hasResults = false
    @discardableResult func clearIfActive(meetingsVisible: Bool) -> Bool {
        guard MeetingSearchEscapeRules.shouldClear(meetingsVisible: meetingsVisible, text: input.text, hasResults: hasResults) else { return false }
        input.escape(); hasResults = false; resetID = UUID(); return true
    }
}

enum MeetingSearchRowLayout {
    static let resultHeight: CGFloat = 58
    static let lineSpacing: CGFloat = 3
}

enum MeetingSearchBlockNavigation {
    static func expandedToggleIDs(for matchID: String?, blocks: [NotionTaskBlock]) -> Set<String> {
        guard let matchID else { return [] }
        var ancestors: [NotionTaskBlock] = []
        for block in blocks {
            while let last = ancestors.last, last.depth >= block.depth { ancestors.removeLast() }
            if block.id == matchID { return Set(ancestors.filter { $0.type == "toggle" }.map(\.id)) }
            ancestors.append(block)
        }
        return []
    }
}

/// One reveal per selection. The view supplies the timer and animates only the fade transition.
struct MeetingMatchHighlightState: Equatable {
    enum Phase: Equatable { case idle, holding, fading, dismissed }
    static let holdSeconds: Double = 2
    static let fadeSeconds: Double = 1.2
    private(set) var phase: Phase = .idle
    var opacity: Double { phase == .holding ? 0.12 : 0 }
    mutating func reveal() -> Bool {
        guard phase == .idle else { return false }
        phase = .holding; return true
    }
    mutating func holdFinished(reduceMotion: Bool) {
        guard phase == .holding else { return }
        phase = reduceMotion ? .dismissed : .fading
    }
    mutating func fadeFinished() { if phase == .fading { phase = .dismissed } }
}

struct MeetingSearchInputState: Equatable {
    enum Mode: Equatable { case dateOrdered, searching }
    private(set) var text = ""
    private(set) var ignoresDateRange = false
    var mode: Mode { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .dateOrdered : .searching }
    mutating func edit(_ text: String) { self.text = text; ignoresDateRange = false }
    mutating func allPeriods() { ignoresDateRange = true }
    mutating func escape() { text = ""; ignoresDateRange = false }
    func parsed(now: Date = Date(), calendar: Calendar = .current) -> MeetingSearchQuery {
        let query = MeetingSearchQuery.parse(text, now: now, calendar: calendar)
        return .init(text: query.text, range: ignoresDateRange ? nil : query.range)
    }
}

#if DEBUG
enum MeetingSearchPreviewState: String, CaseIterable {
    case list, results, empty, detail, preparing, settings, typing
    case detailHighlight = "detail-highlight"
    var holdsHighlight: Bool { self == .detail || self == .detailHighlight }
    static func parse(arguments: [String]) -> Self? {
        arguments.first { $0.hasPrefix("--meeting-search=") }.flatMap { Self(rawValue: String($0.dropFirst("--meeting-search=".count))) }
    }
}
#endif
