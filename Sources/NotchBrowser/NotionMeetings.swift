import SwiftUI
import Combine

enum NotionMeetingDateLabels {
    private static func format(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        guard date != .distantPast else { return "日時なし" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
    static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, pattern: "M月d日（EEE）", timeZone: timeZone)
    }
    static func detail(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, pattern: "yyyy年M月d日（EEE）H:mm", timeZone: timeZone)
    }
    static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, pattern: "H:mm", timeZone: timeZone)
    }
}

struct NotionMeeting: Identifiable, Equatable {
    let id: String
    let title: String
    let status: String
    let calendarStart: Date?
    let calendarEnd: Date?
    let recordingStart: Date?
    let recordingEnd: Date?
    let attendees: [String]
    let summary: String?
    let notes: String?
    let transcript: String?
    let created: Date
    var start: Date { calendarStart ?? recordingStart ?? created }
    func rowMetadata(timeZone: TimeZone = .current) -> String {
        var parts = [NotionMeetingDateLabels.time(start, timeZone: timeZone)]
        if let duration { parts.append("\(duration)分") }
        parts.append("\(attendees.count)人")
        return parts.joined(separator: "・")
    }
    func detailMetadata(timeZone: TimeZone = .current) -> String {
        var parts = [NotionMeetingDateLabels.detail(start, timeZone: timeZone)]
        if let duration { parts.append("\(duration)分") }
        parts.append("\(attendees.count)人")
        return parts.joined(separator: "・")
    }
    var duration: Int? {
        let interval: (Date, Date)?
        if let start = recordingStart, let end = recordingEnd { interval = (start, end) }
        else if let start = calendarStart, let end = calendarEnd { interval = (start, end) }
        else { interval = nil }
        guard let (start, end) = interval else { return nil }
        return max(0, Int(end.timeIntervalSince(start) / 60))
    }
    var url: URL { URL(string: "https://www.notion.so")!.appendingPathComponent(id.replacingOccurrences(of: "-", with: "")) }
    var progressing: Bool { ["transcribing", "summarizing"].contains(status) }
    var label: String? {
        switch status {
        case "transcribing": "文字起こし中"
        case "summarizing": "要約作成中"
        case "failed": "作成に失敗しました"
        case "notes_ready": nil
        default: status.isEmpty ? nil : status
        }
    }
    var sections: [(String, String)] {
        [("要約", summary), ("メモ", notes), ("文字起こし", transcript)].compactMap { title, id in
            guard let id, !id.isEmpty else { return nil }; return (title, id)
        }
    }
    func visibleSections(bodies: [String: [NotionTaskBlock]]) -> [(String, String)] {
        sections.filter { !(bodies[$0.1] ?? []).isEmpty }
    }
    static func parse(_ raw: [String: Any]) -> Self? {
        guard let id = raw["id"] as? String, let type = raw["type"] as? String,
              ["meeting_notes", "transcription"].contains(type), let value = raw[type] as? [String: Any] else { return nil }
        func date(_ container: String, _ key: String) -> Date? {
            ((value[container] as? [String: Any])?[key] as? String).flatMap(NotionMessage.parseDate)
        }
        func blockID(_ key: String) -> String? {
            let children = value["children"] as? [String: Any] ?? [:]
            if let string = children["\(key)_block_id"] as? String { return string.isEmpty ? nil : string }
            if let string = value[key] as? String { return string.isEmpty ? nil : string }
            let object = value[key] as? [String: Any]
            guard let string = (object?["id"] ?? object?["block_id"]) as? String, !string.isEmpty else { return nil }
            return string
        }
        let rich = value["title"] as? [[String: Any]] ?? []
        let title = value["title"] as? String ?? rich.map {
            $0["plain_text"] as? String ?? ($0["text"] as? [String: Any])?["content"] as? String ?? ""
        }.joined()
        let attendees = (value["attendees"] as? [String]) ?? (value["attendees"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return .init(id: id, title: title.isEmpty ? "無題" : title, status: value["status"] as? String ?? "",
                     calendarStart: date("calendar", "start"), calendarEnd: date("calendar", "end"),
                     recordingStart: date("recording", "start"), recordingEnd: date("recording", "end"), attendees: attendees,
                     summary: blockID("summary"), notes: blockID("notes"), transcript: blockID("transcript"),
                     created: (raw["created_time"] as? String).flatMap(NotionMessage.parseDate) ?? .distantPast)
    }
}

extension NotionDatabaseAPI {
    func meetingNotes(fallback: String) async throws -> [NotionMeeting] {
        let raw = try await request("blocks/meeting_notes/query", body: ["page_size": 50])
        guard let results = raw["results"] as? [[String: Any]] else { throw NotionAPIError.invalidResponse }
        var meetings = Array(results.prefix(50)).compactMap(NotionMeeting.parse)
        if meetings.isEmpty, let root = NotionDatabaseInput.id(from: fallback) {
            var queue: [(String, Int)] = [(root, 0)]
            var visited = Set<String>()
            var budget = 500
            // Database pages are enumerated through their data sources.
            let database: [String: Any]?
            do { database = try await request("databases/\(root)") }
            catch NotionAPIError.server(let status, _) where status == 400 || status == 404 { database = nil }
            if let sources = database?["data_sources"] as? [[String: Any]] {
                queue = []
                for source in sources.prefix(5) {
                    guard let id = source["id"] as? String else { continue }
                    let pages = try await request("data_sources/\(id)/query", body: ["page_size": 50])
                    for page in (pages["results"] as? [[String: Any]] ?? []).prefix(50) {
                        if let id = page["id"] as? String { queue.append((id, 0)) }
                    }
                }
            }
            var requests = 0
            while !queue.isEmpty && budget > 0 && visited.count < 100 && meetings.count < 50 && requests < 100 {
                let (id, depth) = queue.removeFirst()
                guard visited.insert(id).inserted else { continue }
                var cursor: String?
                repeat {
                    var query = [URLQueryItem(name: "page_size", value: String(min(100, budget)))]
                    if let cursor { query.append(.init(name: "start_cursor", value: cursor)) }
                    requests += 1
                    let children = try await request("blocks/\(id)/children", query: query)
                    guard let blocks = children["results"] as? [[String: Any]] else { throw NotionAPIError.invalidResponse }
                    for block in blocks.prefix(budget) {
                        budget -= 1
                        if let meeting = NotionMeeting.parse(block) { meetings.append(meeting) }
                        else if depth < 4, block["has_children"] as? Bool == true, let child = block["id"] as? String { queue.append((child, depth + 1)) }
                    }
                    cursor = children["has_more"] as? Bool == true ? children["next_cursor"] as? String : nil
                } while cursor != nil && budget > 0 && meetings.count < 50 && requests < 100
            }
        }
        var seen = Set<String>()
        return Array(meetings.filter { seen.insert($0.id).inserted }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }.prefix(50))
    }
    func meetingBody(_ id: String) async throws -> [NotionTaskBlock] {
        var visited = Set<String>()
        func children(_ id: String, depth: Int) async throws -> [NotionTaskBlock] {
            try Task.checkCancellation()
            guard visited.insert(id).inserted else { return [] }
            var output: [NotionTaskBlock] = []
            var cursor: String?
            var cursors = Set<String>()
            var number = 0
            repeat {
                try Task.checkCancellation()
                var query = [URLQueryItem(name: "page_size", value: "100")]
                if let cursor { query.append(.init(name: "start_cursor", value: cursor)) }
                let raw = try await request("blocks/\(id)/children", query: query)
                guard let rows = raw["results"] as? [[String: Any]] else { throw NotionAPIError.invalidResponse }
                for row in rows {
                    var block = NotionTaskBlock.parse(row, depth: depth)
                    number = block.type == "numbered_list_item" ? number + 1 : 0
                    block.listNumber = number
                    output.append(block)
                    if row["has_children"] as? Bool == true { output += try await children(block.id, depth: depth + 1) }
                }
                if raw["has_more"] as? Bool == true {
                    guard let next = raw["next_cursor"] as? String, !next.isEmpty,
                          cursors.insert(next).inserted else { throw NotionAPIError.invalidResponse }
                    cursor = next
                } else { cursor = nil }
            } while cursor != nil
            return output
        }
        return try await children(id, depth: 0)
    }

}

@MainActor final class NotionMeetingsStore: ObservableObject {
    static let shared = NotionMeetingsStore()
    private let defaults: UserDefaults
    private let tokenProvider: () -> String?
    private let apiFactory: (String) -> NotionDatabaseAPI
    @Published var fallback: String { didSet { if !isMock { defaults.set(fallback, forKey: "notionMeetings.fallback") }; meetings = []; message = nil } }
    @Published var meetings: [NotionMeeting] = []
    @Published var refreshing = false
    @Published var message: String?
    @Published var newestFirst = true { didSet { if !isMock { defaults.set(newestFirst, forKey: "notionMeetings.newestFirst") } } }
    @Published var displayLimit = 50 { didSet { if !isMock { defaults.set(displayLimit, forKey: "notionMeetings.displayLimit") } } }
    var displayedMeetings: [NotionMeeting] {
        Array(meetings.sorted {
            if $0.start == $1.start { return $0.id < $1.id }
            return newestFirst ? $0.start > $1.start : $0.start < $1.start
        }.prefix([10, 25, 50].contains(displayLimit) ? displayLimit : 50))
    }
    private var generation = UUID()
    private(set) var mockState: String?
    var isMock: Bool { mockState != nil }
    init(defaults: UserDefaults = SettingsDefaults.current, tokenProvider: @escaping () -> String? = { NotionTokenStore.read() },
         apiFactory: @escaping (String) -> NotionDatabaseAPI = { NotionDatabaseAPI(token: $0) }, previewState: String? = nil) {
        self.defaults = defaults; self.tokenProvider = tokenProvider; self.apiFactory = apiFactory
        fallback = defaults.string(forKey: "notionMeetings.fallback") ?? ""
        newestFirst = defaults.object(forKey: "notionMeetings.newestFirst") as? Bool ?? true
        let savedLimit = defaults.integer(forKey: "notionMeetings.displayLimit")
        displayLimit = [10, 25, 50].contains(savedLimit) ? savedLimit : 50
        #if DEBUG
        mockState = previewState ?? CommandLine.arguments.first { $0.hasPrefix("--meetings=") }.map { String($0.dropFirst(11)) }
        if let state = mockState {
            meetings = state == "empty" ? [] : (0..<6).compactMap { index in
                let start = Date().addingTimeInterval(Double(-index * 86400))
                let formatter = ISO8601DateFormatter()
                var value: [String: Any] = [
                    "title": "プロジェクト定例 \(index + 1)",
                    "status": state == "progress" ? "summarizing" : ["notes_ready", "transcribing", "summarizing", "failed"][index % 4],
                    "attendees": ["a", "b", "c"],
                    "calendar": ["start": formatter.string(from: start), "end": formatter.string(from: start.addingTimeInterval(2700))]
                ]
                if state != "progress" {
                    value["summary"] = "summary"; value["notes"] = "notes"; value["transcript"] = "transcript"
                }
                return NotionMeeting.parse(["id": "mock-\(index)", "type": "meeting_notes", "created_time": ISO8601DateFormatter().string(from: start),
                    "meeting_notes": value])
            }
        }
        #endif
    }
    private func api(_ token: String) -> NotionDatabaseAPI { var api = apiFactory(token); api.version = "2026-03-11"; return api }
    func connectionChanged() { guard !isMock else { return }; generation = UUID(); meetings = []; message = nil }
    func refresh() async {
        guard !isMock, !refreshing, let token = tokenProvider() else { return }
        let generation = self.generation; let input = fallback
        refreshing = true
        defer { refreshing = false }
        do {
            let fetched = try await api(token).meetingNotes(fallback: input)
            guard generation == self.generation, input == fallback, token == tokenProvider() else { return }
            meetings = fetched; message = nil
        } catch {
            guard generation == self.generation, input == fallback, token == tokenProvider() else { return }
            message = error.localizedDescription
        }
    }
    func blocks(_ id: String) async throws -> [NotionTaskBlock] {
        #if DEBUG
        if isMock { return ["progress", "empty-tabs"].contains(mockState ?? "") ? [] : Self.previewBlocks(section: id) }
        #endif
        guard let token = tokenProvider() else { throw NotionAPIError.missingToken }
        let generation = self.generation
        let result = try await api(token).meetingBody(id)
        guard generation == self.generation, token == tokenProvider() else { throw CancellationError() }
        return result
    }
    #if DEBUG
    static func previewBlocks(section: String) -> [NotionTaskBlock] {
        let rows: [(String, String)]
        switch section {
        case "summary":
            rows = [("heading_2", "決定事項"),
                    ("bulleted_list_item", "次回リリースは10月21日。初回設定の改善を優先する。"),
                    ("bulleted_list_item", "議事録の共有先をプロジェクトページに統一する。"),
                    ("heading_2", "次のアクション"),
                    ("bulleted_list_item", "田中：金曜日までに画面案を共有。"),
                    ("bulleted_list_item", "佐藤：木曜日までに検証結果と残課題を整理。")]
        case "notes":
            rows = [("heading_2", "プロジェクト定例"),
                    ("paragraph", "参加者3名。リリース準備の進捗、初回設定で迷いやすい点、議事録の共有方法を確認した。"),
                    ("heading_3", "議論したこと"),
                    ("bulleted_list_item", "接続状態とデータの設定を同じ画面で確認できると、導入時の問い合わせが減りそう。"),
                    ("bulleted_list_item", "検索機能の追加は次回に見送り、今週は一覧と詳細の使いやすさを整える。"),
                    ("paragraph", "次回の定例では画面案と検証結果を確認し、公開範囲を決定する。")]
        case "transcript":
            rows = [("paragraph", "0:00 田中：今日はリリースの予定と、初回設定の改善について確認します。"),
                    ("paragraph", "0:18 佐藤：検証では接続の後に何を設定するか迷うケースがありました。接続状態とデータの設定をまとめたいです。"),
                    ("paragraph", "0:42 鈴木：賛成です。議事録もプロジェクトページに集約すると、後から決定事項を追いやすくなります。"),
                    ("paragraph", "1:05 田中：では、10月21日のリリースでは初回設定を優先します。画面案は金曜日までに共有します。"),
                    ("paragraph", "1:24 佐藤：木曜日までに検証結果と残課題を整理します。")]
        default: rows = []
        }
        return rows.enumerated().map { index, row in
            NotionTaskBlock.parse(["id": "\(section)-\(index)", "type": row.0,
                                   row.0: ["rich_text": [["plain_text": row.1]]]], depth: 0)
        }
    }
    #endif
}
