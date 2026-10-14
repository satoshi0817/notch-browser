import Foundation

/// Authentication is deliberately absent from the serialized content schema.
struct NotionPageSnapshot<Row: Codable>: Codable {
    var version = 1
    var scope: String
    var rows: [Row] = []
    var bodies: [String: [NotionTaskBlock]] = [:]
    var updated: Date?
    var fullUpdated: Date?
}
final class NotionPageCache<Row: Codable> {
    let url: URL
    init(name: String, url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBrowser/\(name).json")
    }
    func load(scope: String) -> NotionPageSnapshot<Row> {
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(NotionPageSnapshot<Row>.self, from: data),
           value.version == 1, value.scope == scope {
            var bounded = value
            bounded.rows = Array(value.rows.prefix(NotionPageRefreshRules.rowLimit))
            if bounded.rows.count != value.rows.count { save(bounded) }
            return bounded
        }
        clear()
        return .init(scope: scope)
    }
    func save(_ value: NotionPageSnapshot<Row>) {
        var safe = value
        safe.rows = Array(value.rows.prefix(NotionPageRefreshRules.rowLimit))
        safe.bodies = safe.bodies.mapValues { $0.map { block in
            var block = block; block.image = nil
            if block.type == "image" { block.link = nil; block.runs = [] }
            return block
        } }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(safe).write(to: url, options: .atomic)
        } catch { /* Keep the visible snapshot if persistence fails. */ }
    }
    func clear() { try? FileManager.default.removeItem(at: url) }
}
enum NotionPageRefreshRules {
    static let rowLimit = 1000
    static func shouldStart(refreshing: Bool, force: Bool, updated: Date?, now: Date) -> Bool {
        !refreshing && (force || updated == nil || now.timeIntervalSince(updated!) >= 60)
    }
    static func full(force: Bool, updated: Date?, now: Date) -> Bool {
        force || updated == nil || now.timeIntervalSince(updated!) >= 86400
    }
    static func merge<Row: Identifiable & Equatable>(_ old: [Row], fetched: [Row], full: Bool) -> [Row] where Row.ID == String {
        let incoming = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var result = old.compactMap { row -> Row? in
            if let new = incoming[row.id] { return new == row ? row : new }
            return full ? nil : row
        }
        let known = Set(old.map(\.id))
        result += fetched.filter { !known.contains($0.id) }
        return result
    }
    static func deletedSelection<Row: Identifiable>(_ id: String?, rows: [Row]) -> Bool where Row.ID == String {
        id.map { id in !rows.contains { $0.id == id } } ?? false
    }
    static func meetingBodyChanged(old: NotionMeeting, new: NotionMeeting) -> Bool {
        old.edited != new.edited || (old.status != "notes_ready" && new.status == "notes_ready")
    }
    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "未更新" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP"); formatter.dateFormat = "M月d日 H:mm"
        return formatter.string(from: date)
    }
    static func failureHelp(_ date: Date?) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "H:mm"
        return "更新できませんでした。保存した内容を表示しています（\(date.map { formatter.string(from: $0) } ?? "未更新") 時点）"
    }
}
