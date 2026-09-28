import Foundation

struct ClosedTab {
    let url: URL
    let profileID: UUID
    let zoom: Double
}

/// Session-only history: no browsing history is written to disk.
struct ClosedTabHistory {
    private(set) var entries: [ClosedTab] = []
    var isEmpty: Bool { entries.isEmpty }
    mutating func push(_ entry: ClosedTab) {
        guard ["http", "https", "file"].contains(entry.url.scheme?.lowercased() ?? "") else { return }
        entries.append(entry)
        if entries.count > 20 { entries.removeFirst(entries.count - 20) }
    }
    mutating func pop() -> ClosedTab? { entries.popLast() }
}

enum BrowserTools {
    static func zoom(_ value: Double) -> Double { min(3, max(0.5, value)) }
    static func matches(query: String, title: String, url: String, profile: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        let haystack = "\(title) \(url) \(profile)"
        return words.allSatisfy { haystack.localizedStandardContains(String($0)) }
    }
}
