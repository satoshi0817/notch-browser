import AppKit
import Combine
import CryptoKit
import Foundation

struct NotionDatabaseProperty: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
}

struct NotionDatabaseDetails {
    let id: String
    let name: String
    let properties: [NotionDatabaseProperty]
}

enum NotionDatabaseInput {
    static func id(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            guard let host = url.host?.lowercased(), NotionChatLink.isNotionHost(host) else { return nil }
            candidate = url.path.split(separator: "/").last.map(String.init) ?? ""
        } else if value.contains("://") { return nil }
        else { candidate = value }
        let tail = String(candidate.suffix(36))
        if let uuid = UUID(uuidString: tail) { return uuid.uuidString.lowercased() }
        let compact = String(candidate.suffix(32))
        guard compact.count == 32, compact.allSatisfy(\.isHexDigit) else { return nil }
        let hex = compact.lowercased()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }
}

struct NotionDatabaseNotice {
    let databaseID: String
    let databaseName: String
    let propertyName: String
    let preview: String
    let pageURL: URL?
}

struct NotionDatabaseRow {
    let id: String
    let editedAt: Date
    let pageURL: URL?
    let text: String
}

enum NotionDatabaseValue {
    static func text(_ property: [String: Any]) -> String {
        let type = property["type"] as? String ?? ""
        let value = property[type]
        switch type {
        case "title", "rich_text":
            return (value as? [[String: Any]] ?? []).compactMap { $0["plain_text"] as? String }.joined()
        case "select", "status":
            return (value as? [String: Any])?["name"] as? String ?? ""
        case "multi_select":
            return (value as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        case "number":
            return (value as? NSNumber)?.stringValue ?? ""
        case "checkbox":
            return (value as? Bool).map { $0 ? "はい" : "いいえ" } ?? ""
        case "date":
            guard let date = value as? [String: Any], let start = date["start"] as? String else { return "" }
            return [start, date["end"] as? String].compactMap { $0 }.joined(separator: " 〜 ")
        case "url", "email", "phone_number":
            return value as? String ?? ""
        case "formula":
            guard let formula = value as? [String: Any], let formulaType = formula["type"] as? String else { return "" }
            switch formulaType {
            case "string": return formula["string"] as? String ?? ""
            case "number": return (formula["number"] as? NSNumber)?.stringValue ?? ""
            case "boolean": return (formula["boolean"] as? Bool).map { $0 ? "はい" : "いいえ" } ?? ""
            case "date": return ((formula["date"] as? [String: Any])?["start"] as? String) ?? ""
            default: return ""
            }
        default: return ""
        }
    }

    static let supportedTypes: Set<String> = ["title", "rich_text", "select", "status", "multi_select",
                                              "number", "checkbox", "date", "url", "email", "phone_number", "formula"]
}

struct NotionDatabaseAPI {
    let token: String
    var fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    private func request(_ path: String, body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> [String: Any] {
        guard !token.isEmpty else { throw NotionAPIError.missingToken }
        var components = URLComponents(string: "https://api.notion.com/v1/\(path)")!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        for attempt in 0..<3 {
            let (data, response) = try await fetch(request)
            guard let response = response as? HTTPURLResponse else { throw NotionAPIError.invalidResponse }
            if (response.statusCode == 429 || response.statusCode == 529) && attempt < 2 {
                let seconds = max(1, Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? (1 << attempt))
                try await Task.sleep(for: .seconds(seconds))
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                    ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
                throw NotionAPIError.server(response.statusCode, message)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NotionAPIError.invalidResponse
            }
            return object
        }
        throw NotionAPIError.invalidResponse
    }

    func details(for inputID: String) async throws -> NotionDatabaseDetails {
        let source: [String: Any]
        do { source = try await request("data_sources/\(inputID)") }
        catch NotionAPIError.server(let status, _) where status == 400 || status == 404 {
            let database = try await request("databases/\(inputID)")
            guard let first = (database["data_sources"] as? [[String: Any]])?.first,
                  let id = first["id"] as? String else { throw NotionAPIError.invalidResponse }
            source = try await request("data_sources/\(id)")
        }
        guard let id = source["id"] as? String,
              let rawProperties = source["properties"] as? [String: [String: Any]] else {
            throw NotionAPIError.invalidResponse
        }
        let properties = rawProperties.compactMap { name, value -> NotionDatabaseProperty? in
            guard let propertyID = value["id"] as? String, let type = value["type"] as? String,
                  NotionDatabaseValue.supportedTypes.contains(type) else { return nil }
            return NotionDatabaseProperty(id: propertyID, name: name, type: type)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let title = (source["title"] as? [[String: Any]] ?? [])
            .compactMap { $0["plain_text"] as? String }.joined()
        let name = title.isEmpty ? "データベース \(id.prefix(8))" : title
        return NotionDatabaseDetails(id: id, name: name, properties: properties)
    }

    func changedRows(database: SavedNotionDatabase, since: Date) async throws -> [NotionDatabaseRow] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var cursor: String?
        var rows: [NotionDatabaseRow] = []
        repeat {
            var body: [String: Any] = [
                "page_size": 100,
                "sorts": [["timestamp": "last_edited_time", "direction": "descending"]],
                "filter": ["timestamp": "last_edited_time", "last_edited_time": ["on_or_after": formatter.string(from: since)]]
            ]
            if let cursor { body["start_cursor"] = cursor }
            let page = try await request("data_sources/\(database.id)/query", body: body,
                                         query: [.init(name: "filter_properties[]", value: database.propertyID)])
            guard let results = page["results"] as? [[String: Any]] else { throw NotionAPIError.invalidResponse }
            for result in results {
                guard let id = result["id"] as? String,
                      let timestamp = result["last_edited_time"] as? String,
                      let editedAt = NotionMessage.parseDate(timestamp),
                      let properties = result["properties"] as? [String: [String: Any]],
                      let property = properties.values.first(where: { ($0["id"] as? String) == database.propertyID })
                        ?? properties[database.propertyName] else { continue }
                rows.append(NotionDatabaseRow(id: id, editedAt: editedAt,
                    pageURL: (result["url"] as? String).flatMap(URL.init(string:)),
                    text: NotionDatabaseValue.text(property)))
            }
            cursor = (page["has_more"] as? Bool == true) ? page["next_cursor"] as? String : nil
        } while cursor != nil
        return rows.sorted { $0.editedAt < $1.editedAt }
    }
}

final class NotionDatabaseMonitor: ObservableObject {
    static let shared = NotionDatabaseMonitor()

    private struct SeenPage: Codable { var hash: String; var editedAt: Date }
    private struct State: Codable {
        var checkedAt: Date
        var propertyID: String
        var seen: [String: SeenPage] = [:]
    }
    @Published private(set) var latestNotice: NotionDatabaseNotice?
    @Published private(set) var lastError: String?
    private let stateKey = "notionDatabaseMonitor.v1"
    private var states: [String: State]
    private var timer: Timer?
    private var isRefreshing = false
    private var activeInterval = 0
    private var activeSignature = ""
    private var queuedNotices: [NotionDatabaseNotice] = []
    private var deliveringNotice = false

    private init() {
        states = UserDefaults.standard.data(forKey: stateKey)
            .flatMap { try? JSONDecoder().decode([String: State].self, from: $0) } ?? [:]
    }

    func start() { settingsChanged() }

    func tokenChanged() {
        let now = Date()
        states = Dictionary(uniqueKeysWithValues: SettingsStore.shared.data.notionDatabases.map {
            ($0.id, State(checkedAt: now, propertyID: $0.propertyID))
        })
        save()
        settingsChanged()
    }

    func settingsChanged() {
        let settings = SettingsStore.shared.data
        let enabled = settings.notionDatabaseNotificationsEnabled &&
            !settings.notionDatabases.filter(\.enabled).isEmpty && NotionTokenStore.read() != nil
        let interval = settings.notionDatabasePollingSeconds
        let signature = settings.notionDatabases.filter(\.enabled)
            .map { "\($0.id):\($0.propertyID):\($0.addedAt.timeIntervalSince1970)" }.joined(separator: "|")
        guard enabled else {
            timer?.invalidate(); timer = nil; activeInterval = 0; activeSignature = ""
            queuedNotices = []; latestNotice = nil; deliveringNotice = false
            return
        }
        if timer != nil && activeInterval == interval && activeSignature == signature { return }
        let shouldRefresh = timer == nil || activeSignature != signature
        activeSignature = signature
        timer?.invalidate()
        activeInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        if shouldRefresh { Task { @MainActor in await refresh() } }
    }

    func refresh() async {
        guard !isRefreshing, SettingsStore.shared.data.notionDatabaseNotificationsEnabled,
              let token = NotionTokenStore.read() else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let databases = SettingsStore.shared.data.notionDatabases.filter(\.enabled)
        let currentIDs = Set(databases.map(\.id))
        states = states.filter { currentIDs.contains($0.key) }
        for (index, database) in databases.enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            var state = states[database.id]
            if state?.propertyID != database.propertyID {
                state = State(checkedAt: database.addedAt, propertyID: database.propertyID)
            }
            guard var state else { continue }
            let startedAt = Date()
            let since = max(database.addedAt, state.checkedAt.addingTimeInterval(-120))
            do {
                let rows = try await NotionDatabaseAPI(token: token).changedRows(database: database, since: since)
                for row in rows {
                    let value = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { continue }
                    let hash = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
                    let stillActive = SettingsStore.shared.data.notionDatabaseNotificationsEnabled &&
                        SettingsStore.shared.data.notionDatabases.contains {
                            $0.id == database.id && $0.propertyID == database.propertyID && $0.enabled
                        }
                    if stillActive && state.seen[row.id]?.hash != hash && row.editedAt >= database.addedAt {
                        enqueue(NotionDatabaseNotice(databaseID: database.id, databaseName: database.name,
                            propertyName: database.propertyName, preview: String(value.prefix(220)), pageURL: row.pageURL))
                    }
                    state.seen[row.id] = SeenPage(hash: hash, editedAt: row.editedAt)
                }
                state.checkedAt = startedAt
                if state.seen.count > 500 {
                    state.seen = Dictionary(uniqueKeysWithValues: state.seen.sorted { $0.value.editedAt > $1.value.editedAt }
                        .prefix(500).map { ($0.key, $0.value) })
                }
                states[database.id] = state
                lastError = nil
                save()
            } catch {
                lastError = "\(database.name): \(error.localizedDescription)"
            }
        }
    }

    func clearNotice() {
        latestNotice = nil
        let delay = TimeInterval(SettingsStore.shared.data.notionDatabaseNotificationDuration) + 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.deliveringNotice = false
            self?.showNextNotice()
        }
    }

    private func enqueue(_ notice: NotionDatabaseNotice) {
        queuedNotices.append(notice)
        showNextNotice()
    }

    private func showNextNotice() {
        guard !deliveringNotice, !queuedNotices.isEmpty else { return }
        deliveringNotice = true
        latestNotice = queuedNotices.removeFirst()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(states), forKey: stateKey)
    }
}
