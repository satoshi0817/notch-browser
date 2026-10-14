import SwiftUI
import Combine

struct NotionTaskSource: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}
struct NotionTaskMapping: Codable, Equatable {
    var status: String?
    var due: String?
    static func automatic(_ properties: [NotionDatabaseProperty]) -> Self {
        .init(status: properties.first { $0.type == "status" }?.name,
              due: properties.first { $0.type == "date" }?.name)
    }
}
enum NotionTaskStatusCategory: String, Codable, CaseIterable {
    case notStarted, inProgress, complete
    var symbol: String {
        switch self {
        case .notStarted: "circle.fill"
        case .inProgress: "circle.lefthalf.filled"
        case .complete: "checkmark"
        }
    }
}
struct NotionTask: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL?
    let status: String
    let completed: Bool
    let due: Date?
    let edited: Date
    var statusCategory: NotionTaskStatusCategory? = nil
    var statusColor: String? = nil
    var category: NotionTaskStatusCategory { statusCategory ?? (completed ? .complete : .notStarted) }
}
enum NotionTaskFilter: String, CaseIterable {
    case incomplete = "未完了", all = "すべて"
}
enum NotionTaskGroup: String, CaseIterable {
    case overdue = "期限切れ", today = "今日", upcoming = "これから", undated = "期日なし"
}
enum NotionTaskRules {
    struct Checklist: Equatable {
        let loggedIn: Bool
        let databaseURL: Bool
        var hint: String { "2つそろうと、ノッチにタスクのタブが表示されます" }
    }
    static func checklist(tokenValid: Bool, checking: Bool, url: String, confirmedURL: String?) -> Checklist {
        .init(loggedIn: tokenValid && !checking, databaseURL: available(token: true, url: url, confirmedURL: confirmedURL))
    }
    static func canConfirm(url: String, checking: Bool) -> Bool {
        !checking && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static func errorLink(_ message: String, url: String) -> URL? {
        if message == errorMessage(NotionAPIError.server(404, "")), let destination = URL(string: url),
           ["https", "http"].contains(destination.scheme?.lowercased() ?? "") {
            return destination
        }
        return nil
    }
    // Settings are always reachable, but editable only after token verification.
    static let settingsEntryVisible = true
    static func settingsEnabled(tokenValid: Bool) -> Bool { tokenValid }
    // Compatibility for callers that only have a verified connection flag.
    static func tabVisible(connected: Bool) -> Bool {
        tabVisible(state: connected ? .connected : .unconnected, hasStoredToken: connected)
    }
    static func settingsEnabled(state: NotionConnectionState) -> Bool { state == .connected }
    // Verification results never hide a saved connection; only removing the token does.
    static func tabVisible(state: NotionConnectionState, hasStoredToken: Bool) -> Bool {
        hasStoredToken
    }
    static func agentTabVisible(state: NotionConnectionState, hasStoredToken: Bool, enabled: Bool) -> Bool {
        enabled && tabVisible(state: state, hasStoredToken: hasStoredToken)
    }
    static func showsEmptySettingsButton(bannerVisible: Bool) -> Bool { !bannerVisible }
    static func showsConnectionError(state: NotionConnectionState, hasStoredToken: Bool) -> Bool {
        hasStoredToken && (state == .invalid || state == .unverified)
    }
    static func showsConnectionLoading(state: NotionConnectionState, hasStoredToken: Bool) -> Bool {
        state == .verifying && hasStoredToken
    }
    static func showsReverificationEntry(state: NotionConnectionState, hasStoredToken: Bool) -> Bool {
        hasStoredToken && [.verifying, .unverified, .invalid].contains(state)
    }
    static func connectionState(after error: Error) -> NotionConnectionState {
        if case NotionAPIError.server(401, _) = error { return .invalid }
        return .unverified
    }
    static func shouldAutoSelect(available: Bool, alreadySelected: Bool) -> Bool { available && !alreadySelected }
    static func available(token: Bool, url: String, confirmedURL: String?) -> Bool {
        token && confirmedURL == url && NotionDatabaseInput.id(from: url) != nil
    }
    static func showsSourcePicker(_ sources: [NotionTaskSource]) -> Bool { sources.count > 1 }
    static func selectedSource(_ saved: String?, sources: [NotionTaskSource]) -> String? {
        sources.first { $0.id == saved }?.id ?? sources.first?.id
    }
    static func errorMessage(_ error: Error) -> String {
        if case NotionAPIError.server(let code, _) = error {
            if code == 404 { return "このデータベースが NotchBrowser に共有されていません" }
            if code == 400 { return "URL がデータベースではありません" }
        }
        return error.localizedDescription
    }
    static func group(_ task: NotionTask, now: Date, calendar: Calendar) -> NotionTaskGroup {
        guard let due = task.due else { return .undated }
        if calendar.isDate(due, inSameDayAs: now) { return .today }
        return due < calendar.startOfDay(for: now) ? .overdue : .upcoming
    }
    static func rows(_ tasks: [NotionTask], filter: NotionTaskFilter, calendar: Calendar = .current) -> [NotionTask] {
        tasks.filter { filter == .all || !$0.completed }
        .sorted {
            let left = $0.due.map { calendar.startOfDay(for: $0) } ?? .distantFuture
            let right = $1.due.map { calendar.startOfDay(for: $0) } ?? .distantFuture
            if left != right { return left < right }
            return $0.edited == $1.edited ? $0.id < $1.id : $0.edited > $1.edited
        }
    }
    static func dateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "今日" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "明日" }
        return "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
    }
    static func parseDate(_ value: String) -> Date? {
        if value.count == 10 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: value)
        }
        return NotionMessage.parseDate(value)
    }
}
struct NotionTaskBlock: Codable, Identifiable, Hashable {
    struct Run: Codable, Hashable {
        let text: String
        let url: URL?
    }
    let id: String
    let type: String
    let text: String
    let checked: Bool
    var link: URL?
    var image: URL?
    let depth: Int
    var runs: [Run] = []
    var speaker: String? = nil
    var timestamp: String? = nil
    var listNumber = 1
    var edited: Date = .distantPast
    static func parse(_ raw: [String: Any], depth: Int) -> Self {
        let type = raw["type"] as? String ?? "unsupported"
        let value = raw[type] as? [String: Any] ?? [:]
        let rich = (value["rich_text"] ?? value["caption"]) as? [[String: Any]] ?? []
        let text = rich.map { ($0["plain_text"] as? String) ?? (($0["text"] as? [String: Any])?["content"] as? String) ?? "" }.joined()
        let imageType = value["type"] as? String ?? ""
        let link = (value["url"] as? String) ?? (rich.first?["href"] as? String)
        return .init(id: raw["id"] as? String ?? UUID().uuidString, type: type, text: text,
            checked: value["checked"] as? Bool ?? false, link: link.flatMap(URL.init(string:)),
            image: ((value[imageType] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)), depth: depth,
            runs: rich.map { item in
                let content = item["text"] as? [String: Any] ?? [:]
                let url = (item["href"] as? String) ?? ((content["link"] as? [String: Any])?["url"] as? String)
                return Run(text: item["plain_text"] as? String ?? content["content"] as? String ?? "", url: url.flatMap(URL.init(string:)))
            }, speaker: (value["speaker"] as? String) ?? ((value["speaker"] as? [String: Any])?["name"] as? String),
            timestamp: (value["timestamp"] as? String) ?? (value["start_time"] as? String),
            edited: (raw["last_edited_time"] as? String).flatMap(NotionMessage.parseDate) ?? .distantPast)
    }
}
struct NotionTaskDatabase {
    let name: String
    let sources: [NotionTaskSource]
}
extension NotionDatabaseAPI {
    func taskDatabase(_ id: String) async throws -> NotionTaskDatabase {
        let raw: [String: Any]
        do { raw = try await request("databases/\(id)") }
        catch NotionAPIError.server(let code, let message) where code == 404 {
            // A shared ordinary page is distinguishable from an inaccessible database.
            if let page = try? await request("pages/\(id)"), page["object"] as? String == "page" {
                throw NotionAPIError.server(400, "URL がデータベースではありません")
            }
            throw NotionAPIError.server(code, message)
        }
        guard raw["object"] as? String == "database", let sources = raw["data_sources"] as? [[String: Any]], !sources.isEmpty else {
            throw NotionAPIError.server(400, "URL がデータベースではありません")
        }
        let parsed = sources.compactMap { source -> NotionTaskSource? in
                guard let id = source["id"] as? String else { return nil }
                return .init(id: id, name: source["name"] as? String ?? id)
            }
        guard !parsed.isEmpty else { throw NotionAPIError.invalidResponse }
        return .init(name: NotionDatabaseValue.text(["type": "title", "title": raw["title"] ?? []]), sources: parsed)
    }
    func taskSchema(_ id: String, statusName: String?) async throws -> ([NotionDatabaseProperty], Set<String>, [String: NotionTaskStatusCategory]) {
        let raw = try await request("data_sources/\(id)")
        let properties = raw["properties"] as? [String: [String: Any]] ?? [:]
        let schema = properties.compactMap { name, value -> NotionDatabaseProperty? in
            guard let id = value["id"] as? String, let type = value["type"] as? String else { return nil }
            return .init(id: id, name: name, type: type)
        }.sorted { $0.name < $1.name }
        let name = statusName ?? schema.first { $0.type == "status" }?.name
        let status = name.flatMap { properties[$0] }?["status"] as? [String: Any] ?? [:]
        let groups = status["groups"] as? [[String: Any]] ?? []
        // Status schemas order the groups as To-do, In progress, Complete.
        let ids = groups.last?["option_ids"] as? [String] ?? []
        var categories: [String: NotionTaskStatusCategory] = [:]
        for (index, group) in groups.enumerated() {
            let category: NotionTaskStatusCategory = index == groups.count - 1 ? .complete : (index == 0 ? .notStarted : .inProgress)
            for id in group["option_ids"] as? [String] ?? [] { categories[id] = category }
        }
        return (schema, Set(ids), categories)
    }
    func tasks(source: String, mapping: NotionTaskMapping, completedIDs: Set<String>, categories: [String: NotionTaskStatusCategory] = [:], editedSince: Date? = nil) async throws -> [NotionTask] {
        var cursor: String?
        var tasks: [NotionTask] = []
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let editedSince {
                body["filter"] = ["timestamp": "last_edited_time", "last_edited_time": ["on_or_after": ISO8601DateFormatter().string(from: editedSince)]]
            }
            if let cursor { body["start_cursor"] = cursor }
            let raw = try await request("data_sources/\(source)/query", body: body)
            guard let results = raw["results"] as? [[String: Any]] else { throw NotionAPIError.invalidResponse }
            for page in results {
                guard let id = page["id"] as? String else { continue }
                let properties = page["properties"] as? [String: [String: Any]] ?? [:]
                let status = (mapping.status.flatMap { properties[$0] }?["status"] as? [String: Any]) ?? [:]
                let date = (mapping.due.flatMap { properties[$0] }?["date"] as? [String: Any])?["start"] as? String
                tasks.append(.init(id: id,
                    title: properties.values.first { $0["type"] as? String == "title" }.map(NotionDatabaseValue.text) ?? "無題",
                    url: (page["url"] as? String).flatMap(URL.init(string:)), status: status["name"] as? String ?? "",
                    completed: completedIDs.contains(status["id"] as? String ?? ""),
                    due: date.flatMap(NotionTaskRules.parseDate),
                    edited: (page["last_edited_time"] as? String).flatMap(NotionMessage.parseDate) ?? .distantPast,
                    statusCategory: categories[status["id"] as? String ?? ""],
                    statusColor: status["color"] as? String))
            }
            cursor = raw["has_more"] as? Bool == true ? raw["next_cursor"] as? String : nil
        } while cursor != nil
        return tasks
    }
    func taskBlocks(_ id: String, depth: Int = 0) async throws -> [NotionTaskBlock] {
        var blocks: [NotionTaskBlock] = []
        var cursor: String?
        var listNumber = 0
        repeat {
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let cursor { query.append(.init(name: "start_cursor", value: cursor)) }
            let raw = try await request("blocks/\(id)/children", query: query)
            guard let results = raw["results"] as? [[String: Any]] else { throw NotionAPIError.invalidResponse }
            for block in results {
                var parsed = NotionTaskBlock.parse(block, depth: depth)
                listNumber = parsed.type == "numbered_list_item" ? listNumber + 1 : 0
                parsed.listNumber = listNumber
                blocks.append(parsed)
                if block["has_children"] as? Bool == true { blocks += try await taskBlocks(parsed.id, depth: depth + 1) }
            }
            cursor = raw["has_more"] as? Bool == true ? raw["next_cursor"] as? String : nil
        } while cursor != nil
        return blocks
    }
}

@MainActor final class NotionTasksStore: ObservableObject {
    static let shared = NotionTasksStore()
    struct Configuration: Codable {
        var url = ""
        var confirmedURL: String?
        var source: String?
        var mapping = NotionTaskMapping()
        var mappedSource: String?
        var autoSelected = false
    }
    // Retain the old schema type for existing callers; v1 data is not restored.
    struct Cache: Codable {
        let url: String
        let source: String?
        let tasks: [NotionTask]
    }
    private let cache: NotionPageCache<NotionTask>
    private var generation = UUID()
    @Published private(set) var bodies: [String: [NotionTaskBlock]] = [:]
    @Published private(set) var lastUpdated: Date?
    private var fullUpdated: Date?
    var hasCache: Bool { lastUpdated != nil }
    private var scope: String { configuration.url + "|" + (configuration.source ?? "") }
    private let defaults: UserDefaults
    private let tokenProvider: () -> String?
    private let apiFactory: (String) -> NotionDatabaseAPI
    @Published var configuration: Configuration { didSet {
        if oldValue.url != configuration.url { configuration.confirmedURL = nil }
        if !mock && (oldValue.url != configuration.url || oldValue.source != configuration.source || oldValue.mapping != configuration.mapping) { clearCache() }
        if !mock { defaults.set(try? JSONEncoder().encode(configuration), forKey: "notionTasks.configuration") }
    } }
    @Published var tasks: [NotionTask] = []
    @Published var sources: [NotionTaskSource] = []
    @Published var properties: [NotionDatabaseProperty] = []
    @Published var name = ""
    @Published var message: String?
    @Published var checking = false
    @Published var refreshing = false
    var verified: Bool {
        get { NotionTaskRules.available(token: true, url: configuration.url, confirmedURL: configuration.confirmedURL) }
        set { configuration.confirmedURL = newValue ? configuration.url : nil }
    }
    @Published var filter: NotionTaskFilter { didSet { if !mock { defaults.set(filter.rawValue, forKey: "notionTasks.filter") } } }
    private var mock = false
    var available: Bool { NotionTaskRules.available(token: mock || tokenProvider() != nil, url: configuration.url, confirmedURL: configuration.confirmedURL) }
    var isMock: Bool { mock }
    var mockState: String?
    init(defaults: UserDefaults = SettingsDefaults.current, tokenProvider: @escaping () -> String? = { NotionTokenStore.read() },
         apiFactory: @escaping (String) -> NotionDatabaseAPI = { NotionDatabaseAPI(token: $0) }, previewState: String? = nil, cacheURL: URL? = nil) {
        self.defaults = defaults
        cache = NotionPageCache(name: "NotionTasksCache", url: cacheURL)
        self.tokenProvider = tokenProvider
        self.apiFactory = apiFactory
        configuration = defaults.data(forKey: "notionTasks.configuration").flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
        filter = defaults.string(forKey: "notionTasks.filter").flatMap(NotionTaskFilter.init(rawValue:)) ?? .incomplete
        #if DEBUG
        if previewState == nil && !CommandLine.arguments.contains(where: { $0.hasPrefix("--tasks=") || $0.hasPrefix("--meetings=") || $0.hasPrefix("--cache-state=") }) && ProcessInfo.processInfo.environment["NOTCH_TASKS_MOCK"] == nil { loadCache() }
        #else
        loadCache()
        #endif
        #if DEBUG
        let cacheState = CommandLine.arguments.first { $0.hasPrefix("--cache-state=") }.map { String($0.dropFirst(14)) }
        let argument = CommandLine.arguments.first { $0.hasPrefix("--tasks=") }.map { String($0.dropFirst("--tasks=".count)) }
        if let state = cacheState == "settings" ? "settings" : (previewState ?? (cacheState != nil ? "list" : nil) ?? ProcessInfo.processInfo.environment["NOTCH_TASKS_MOCK"] ?? argument ?? (CommandLine.arguments.contains(where: { $0.hasPrefix("--meetings=") }) ? "empty" : nil)) {
            mock = true
            mockState = state
            configuration.autoSelected = false
            configuration.url = "https://notion.so/0123456789abcdef0123456789abcdef"
            verified = true
            filter = .incomplete
            let now = Date()
            tasks = state == "empty" ? [] : (0..<8).map { index in
                .init(id: "mock-\(index)", title: ["デザインを確認する", "次のリリースを準備", "チームのタスクを整理"][index % 3],
                    url: URL(string: "https://www.notion.so"), status: index == 7 ? "完了" : (index % 2 == 0 ? "未着手" : "進行中"), completed: index == 7,
                    due: index == 6 ? nil : Calendar.current.date(byAdding: .day, value: index - 2, to: now), edited: now,
                    statusCategory: index == 7 ? .complete : (index % 2 == 0 ? .notStarted : .inProgress),
                    statusColor: index == 7 ? "green" : (index % 2 == 0 ? "gray" : "blue"))
            }
            name = "チームのタスク"
            if state == "settings" || state == "tab-settings" || state == "sources" {
                configuration.url = "https://notion.so/0123456789abcdef0123456789abcdef"
                sources = [.init(id: "mock-source-1", name: "チームのタスク")]
                if state == "sources" { sources.append(.init(id: "mock-source-2", name: "プロジェクト")) }
                configuration.source = sources.first?.id
                verified = true
                properties = [.init(id: "status", name: "状態", type: "status"), .init(id: "due", name: "期日", type: "date")]
                configuration.mapping = .automatic(properties)
            }
            if state == "unconfigured" { configuration.url = ""; configuration.confirmedURL = nil; tasks = []; verified = false }
            if state == "error" { verified = false; message = "このデータベースが NotchBrowser に共有されていません" }
            if state == "settings-error" {
                configuration.url = "https://notion.so/0123456789abcdef0123456789abcdef"
                configuration.source = nil
                configuration.mapping = NotionTaskMapping()
                configuration.mappedSource = nil
                tasks = []; sources = []; properties = []
                verified = false
                message = NotionTaskRules.errorMessage(NotionAPIError.server(404, "object_not_found"))
            }
        }
        if cacheState != nil {
            lastUpdated = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 1, minute: 52))
            refreshing = cacheState == "refreshing"
            if cacheState == "failed" { message = "offline" }
        }
        #endif
        if !mock, defaults.string(forKey: "notionTasks.filter") == "自分の担当" {
            defaults.set(NotionTaskFilter.incomplete.rawValue, forKey: "notionTasks.filter")
        }
    }
    private func loadCache() {
        defaults.removeObject(forKey: "notionTasks.cache.v1")
        let value = cache.load(scope: scope)
        tasks = value.rows; bodies = value.bodies; lastUpdated = value.updated; fullUpdated = value.fullUpdated
    }
    private func saveCache() {
        guard !mock else { return }
        cache.save(.init(scope: scope, rows: tasks, bodies: bodies, updated: lastUpdated, fullUpdated: fullUpdated))
    }
    func clearCache() {
        generation = UUID(); tasks = []; bodies = [:]; lastUpdated = nil; fullUpdated = nil; message = nil
        if !mock { cache.clear(); defaults.removeObject(forKey: "notionTasks.cache.v1") }
    }
    func connectionChanged() {
        guard !mock else { return }
        clearCache(); verified = false
    }
    func configure() async {
        guard !mock else { return }
        guard !checking, !refreshing else { return }
        verified = false
        guard let id = NotionDatabaseInput.id(from: configuration.url) else {
            message = "URL がデータベースではありません"; verified = false; return
        }
        guard let token = tokenProvider() else { message = "Notion に接続してください"; return }
        checking = true; verified = false; message = nil
        let input = configuration.url
        let currentGeneration = generation
        defer { checking = false }
        do {
            let db = try await apiFactory(token).taskDatabase(id)
            guard currentGeneration == generation, input == configuration.url, token == tokenProvider() else { return }
            name = db.name; sources = db.sources
            let oldSource = configuration.source
            configuration.source = NotionTaskRules.selectedSource(configuration.source, sources: sources)
            await refresh(remap: oldSource != configuration.source, confirming: true)
        } catch {
            guard currentGeneration == generation, input == configuration.url, token == tokenProvider() else { return }
            verified = false; message = NotionTaskRules.errorMessage(error)
        }
    }
    func sourceChanged() async {
        guard !mock else { return }
        loadCache()
        while refreshing {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await refresh(remap: true)
    }
    func refresh(remap: Bool = false, confirming: Bool = false, force: Bool = true) async {
        guard !mock, NotionPageRefreshRules.shouldStart(refreshing: refreshing, force: force, updated: lastUpdated, now: Date()), verified || confirming, let token = tokenProvider() else { return }
        refreshing = true
        let input = configuration.url
        var requestGeneration = generation
        let started = Date()
        let full = NotionPageRefreshRules.full(force: force || remap, updated: fullUpdated, now: started)
        defer { refreshing = false }
        do {
            let api = apiFactory(token)
            guard let databaseID = NotionDatabaseInput.id(from: input) else { return }
            let database = try await api.taskDatabase(databaseID)
            guard requestGeneration == generation, input == configuration.url, token == tokenProvider() else { return }
            guard let source = NotionTaskRules.selectedSource(configuration.source, sources: database.sources) else { throw NotionAPIError.invalidResponse }
            let needsMapping = remap || source != configuration.mappedSource
            name = database.name; sources = database.sources; configuration.source = source
            requestGeneration = generation
            let (schema, completed, categories) = try await api.taskSchema(source, statusName: needsMapping ? nil : configuration.mapping.status)
            guard requestGeneration == generation, token == tokenProvider() else { return }
            let mapping = needsMapping ? NotionTaskMapping.automatic(schema) : configuration.mapping
            configuration.mapping = mapping; configuration.mappedSource = source
            requestGeneration = generation
            let fetched = try await api.tasks(source: source, mapping: mapping, completedIDs: completed, categories: categories, editedSince: full ? nil : lastUpdated?.addingTimeInterval(-60))
            guard requestGeneration == generation, source == configuration.source, input == configuration.url, token == tokenProvider() else { return }
            properties = schema
            let previous = tasks
            let currentGeneration = generation
            var refreshedBodies = bodies
            for row in fetched where bodies[row.id] != nil && previous.first(where: { $0.id == row.id })?.edited != row.edited {
                refreshedBodies[row.id] = try await api.taskBlocks(row.id)
                guard currentGeneration == generation, token == tokenProvider() else { return }
            }
            tasks = Array(NotionPageRefreshRules.merge(previous, fetched: fetched, full: full).prefix(NotionPageRefreshRules.rowLimit))
            bodies = refreshedBodies.filter { id, _ in tasks.contains { $0.id == id } }
            message = nil; verified = true; lastUpdated = started
            if full { fullUpdated = started }
            saveCache()
        } catch {
            guard requestGeneration == generation, input == configuration.url, token == tokenProvider() else { return }
            message = NotionTaskRules.errorMessage(error); if !hasCache { verified = false }
        }
    }
    func blocks(for id: String) async throws -> [NotionTaskBlock] {
        #if DEBUG
        if mock {
            if mockState == "loading" { try await Task.sleep(for: .seconds(30)) }
            if mockState == "no-body" { return [] }
            return Self.previewBlocks()
        }
        #endif
        if let body = bodies[id] { return body }
        guard let token = tokenProvider() else { throw NotionAPIError.missingToken }
        let currentGeneration = generation
        let body = try await apiFactory(token).taskBlocks(id)
        guard currentGeneration == generation, token == tokenProvider() else { throw CancellationError() }
        bodies[id] = body; saveCache(); return body
    }
    #if DEBUG
    static func previewBlocks() -> [NotionTaskBlock] {
        func block(_ id: String, _ type: String, _ text: String, depth: Int = 0) -> NotionTaskBlock {
            NotionTaskBlock.parse(["id": id, "type": type, type: ["rich_text": [["plain_text": text]]]], depth: depth)
        }
        var first = block("number-1", "numbered_list_item", "レビューを依頼する")
        first.listNumber = 1
        var second = block("number-2", "numbered_list_item", "フィードバックを反映する")
        second.listNumber = 2
        return [block("heading", "heading_2", "タスクの詳細"),
                block("bullet-1", "bulleted_list_item", "画面の余白を確認する"),
                block("bullet-2", "bulleted_list_item", "一覧と詳細の見え方を揃える"), first, second,
                NotionTaskBlock.parse(["id": "todo", "type": "to_do", "to_do": ["checked": false, "rich_text": [["plain_text": "内容を確認する"]]]], depth: 0),
                NotionTaskBlock.parse(["id": "link", "type": "paragraph", "paragraph": ["rich_text": [["plain_text": "参考資料を Notion で開く", "href": "https://www.notion.so"]]]], depth: 0),
                NotionTaskBlock.parse(["id": "preview-image", "type": "image", "image": ["type": "external", "external": ["url": "notch-preview://task-image"]]], depth: 0)]
    }
    #endif
}

#if DEBUG
enum NotionPreviewTab: String, CaseIterable {
    case tasks, agents, meetings
    static func parse(arguments: [String]) -> NotionPreviewTab? {
        arguments.first { $0.hasPrefix("--select-tab=") }
            .flatMap { NotionPreviewTab(rawValue: String($0.dropFirst("--select-tab=".count))) }
    }
}
#endif
