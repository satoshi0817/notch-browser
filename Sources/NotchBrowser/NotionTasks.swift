import SwiftUI
import Combine

struct NotionTaskSource: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}
struct NotionTaskMapping: Codable, Equatable {
    var status: String?
    var due: String?
    var assignee: String?
    static func automatic(_ properties: [NotionDatabaseProperty]) -> Self {
        .init(status: properties.first { $0.type == "status" }?.name,
              due: properties.first { $0.type == "date" }?.name,
              assignee: properties.first { $0.type == "people" }?.name)
    }
}
struct NotionTaskPerson: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let avatar: URL?
}
struct NotionTask: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL?
    let status: String
    let completed: Bool
    let due: Date?
    let edited: Date
    let people: [NotionTaskPerson]
}
enum NotionTaskFilter: String, CaseIterable {
    case incomplete = "未完了", mine = "自分の担当", all = "すべて"
}
enum NotionTaskGroup: String, CaseIterable {
    case overdue = "期限切れ", today = "今日", upcoming = "これから", undated = "期日なし"
}
enum NotionTaskRules {
    struct Checklist: Equatable {
        let loggedIn: Bool
        let databaseURL: Bool
        var hint: String { loggedIn && databaseURL ? "ノッチにタスクのタブが表示されています" : "2つそろうと、ノッチにタスクのタブが表示されます" }
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
    static func rows(_ tasks: [NotionTask], filter: NotionTaskFilter, userID: String?, calendar: Calendar = .current) -> [NotionTask] {
        tasks.filter { filter == .all || (filter == .incomplete && !$0.completed) ||
            (filter == .mine && userID != nil && $0.people.contains { $0.id == userID }) }
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
struct NotionTaskBlock: Identifiable, Hashable {
    struct Run: Hashable {
        let text: String
        let url: URL?
    }
    let id: String
    let type: String
    let text: String
    let checked: Bool
    let link: URL?
    let image: URL?
    let depth: Int
    var runs: [Run] = []
    var listNumber = 1
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
            })
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
    func taskSchema(_ id: String, statusName: String?) async throws -> ([NotionDatabaseProperty], Set<String>) {
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
        return (schema, Set(ids))
    }
    func tasks(source: String, mapping: NotionTaskMapping, completedIDs: Set<String>) async throws -> [NotionTask] {
        var cursor: String?
        var tasks: [NotionTask] = []
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let raw = try await request("data_sources/\(source)/query", body: body)
            guard let results = raw["results"] as? [[String: Any]] else { throw NotionAPIError.invalidResponse }
            for page in results {
                guard let id = page["id"] as? String else { continue }
                let properties = page["properties"] as? [String: [String: Any]] ?? [:]
                let status = (mapping.status.flatMap { properties[$0] }?["status"] as? [String: Any]) ?? [:]
                let date = (mapping.due.flatMap { properties[$0] }?["date"] as? [String: Any])?["start"] as? String
                let people = mapping.assignee.flatMap { properties[$0] }?["people"] as? [[String: Any]] ?? []
                tasks.append(.init(id: id,
                    title: properties.values.first { $0["type"] as? String == "title" }.map(NotionDatabaseValue.text) ?? "無題",
                    url: (page["url"] as? String).flatMap(URL.init(string:)), status: status["name"] as? String ?? "",
                    completed: completedIDs.contains(status["id"] as? String ?? ""),
                    due: date.flatMap(NotionTaskRules.parseDate),
                    edited: (page["last_edited_time"] as? String).flatMap(NotionMessage.parseDate) ?? .distantPast,
                    people: people.compactMap { person in
                        guard let id = person["id"] as? String, let name = person["name"] as? String, !name.isEmpty else { return nil }
                        return .init(id: id, name: name, avatar: (person["avatar_url"] as? String).flatMap(URL.init(string:)))
                    }))
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
        var viewerID: String?
    }
    struct Cache: Codable {
        let url: String
        let source: String?
        let tasks: [NotionTask]
    }
    private let defaults: UserDefaults
    private let tokenProvider: () -> String?
    private let apiFactory: (String) -> NotionDatabaseAPI
    @Published var configuration: Configuration { didSet {
        if oldValue.url != configuration.url { configuration.confirmedURL = nil }
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
    var canShowPeople: Bool { tasks.contains { !$0.people.isEmpty } }
    var people: [NotionTaskPerson] {
        Dictionary(grouping: tasks.flatMap(\.people), by: \.id).values.compactMap(\.first)
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }
    var isMock: Bool { mock }
    var mockState: String?
    init(defaults: UserDefaults = .standard, tokenProvider: @escaping () -> String? = { NotionTokenStore.read() },
         apiFactory: @escaping (String) -> NotionDatabaseAPI = { NotionDatabaseAPI(token: $0) }, previewState: String? = nil) {
        self.defaults = defaults
        self.tokenProvider = tokenProvider
        self.apiFactory = apiFactory
        configuration = defaults.data(forKey: "notionTasks.configuration").flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
        filter = defaults.string(forKey: "notionTasks.filter").flatMap(NotionTaskFilter.init(rawValue:)) ?? .incomplete
        loadCache()
        #if DEBUG
        let argument = CommandLine.arguments.first { $0.hasPrefix("--tasks=") }.map { String($0.dropFirst("--tasks=".count)) }
        if let state = previewState ?? ProcessInfo.processInfo.environment["NOTCH_TASKS_MOCK"] ?? argument {
            mock = true
            mockState = state
            configuration.autoSelected = false
            configuration.url = "https://notion.so/0123456789abcdef0123456789abcdef"
            verified = true
            filter = .incomplete
            let now = Date()
            tasks = state == "empty" ? [] : (0..<8).map { index in
                .init(id: "mock-\(index)", title: ["デザインを確認する", "次のリリースを準備", "チームのタスクを整理"][index % 3],
                    url: URL(string: "https://www.notion.so"), status: index == 7 ? "完了" : "進行中", completed: index == 7,
                    due: index == 6 ? nil : Calendar.current.date(byAdding: .day, value: index - 2, to: now), edited: now,
                    people: [.init(id: "me", name: "田中", avatar: nil)])
            }
            configuration.viewerID = "me"
            name = "チームのタスク"
            if state == "settings" || state == "sources" {
                configuration.url = "https://notion.so/0123456789abcdef0123456789abcdef"
                sources = [.init(id: "mock-source-1", name: "チームのタスク")]
                if state == "sources" { sources.append(.init(id: "mock-source-2", name: "プロジェクト")) }
                configuration.source = sources.first?.id
                verified = true
                properties = [.init(id: "status", name: "状態", type: "status"), .init(id: "due", name: "期日", type: "date"), .init(id: "people", name: "担当者", type: "people")]
                configuration.mapping = .automatic(properties)
            }
            if state == "no-people" {
                tasks = tasks.map { .init(id: $0.id, title: $0.title, url: $0.url, status: $0.status, completed: $0.completed, due: $0.due, edited: $0.edited, people: []) }
            }
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
        #endif
    }
    private func loadCache() {
        let cache = defaults.data(forKey: "notionTasks.cache.v1").flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        tasks = cache?.url == configuration.url && cache?.source == configuration.source ? Array((cache?.tasks ?? []).prefix(1000)) : []
    }
    func connectionChanged() {
        guard !mock else { return }
        tasks = []; verified = false; message = nil
        defaults.removeObject(forKey: "notionTasks.cache.v1")
    }
    func configure() async {
        guard !mock else { return }
        guard !checking, !refreshing else { return }
        verified = false
        guard let id = NotionDatabaseInput.id(from: configuration.url) else {
            message = "URL がデータベースではありません"; verified = false; return
        }
        guard let token = tokenProvider() else { message = "Notion にログインしてください"; return }
        checking = true; verified = false; message = nil
        let input = configuration.url
        defer { checking = false }
        do {
            let db = try await apiFactory(token).taskDatabase(id)
            guard input == configuration.url, token == tokenProvider() else { return }
            name = db.name; sources = db.sources
            let oldSource = configuration.source
            configuration.source = NotionTaskRules.selectedSource(configuration.source, sources: sources)
            await refresh(remap: oldSource != configuration.source, confirming: true)
        } catch {
            guard input == configuration.url, token == tokenProvider() else { return }
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
    func refresh(remap: Bool = false, confirming: Bool = false) async {
        guard !mock, !refreshing, verified || confirming, let token = tokenProvider() else { return }
        refreshing = true
        let input = configuration.url
        defer { refreshing = false }
        do {
            let api = apiFactory(token)
            guard let databaseID = NotionDatabaseInput.id(from: input) else { return }
            let database = try await api.taskDatabase(databaseID)
            guard input == configuration.url, token == tokenProvider() else { return }
            guard let source = NotionTaskRules.selectedSource(configuration.source, sources: database.sources) else { throw NotionAPIError.invalidResponse }
            let needsMapping = remap || source != configuration.mappedSource
            name = database.name; sources = database.sources; configuration.source = source
            let (schema, completed) = try await api.taskSchema(source, statusName: needsMapping ? nil : configuration.mapping.status)
            let mapping = needsMapping ? NotionTaskMapping.automatic(schema) : configuration.mapping
            let fetched = try await api.tasks(source: source, mapping: mapping, completedIDs: completed)
            guard source == configuration.source, input == configuration.url, token == tokenProvider() else { return }
            properties = schema; configuration.mapping = mapping; configuration.mappedSource = source
            tasks = fetched; message = nil; verified = true
            defaults.set(try? JSONEncoder().encode(Cache(url: input, source: source, tasks: Array(fetched.prefix(1000)))), forKey: "notionTasks.cache.v1")
        } catch {
            guard input == configuration.url, token == tokenProvider() else { return }
            message = NotionTaskRules.errorMessage(error); verified = false
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
        guard let token = NotionTokenStore.read() else { throw NotionAPIError.missingToken }
        return try await NotionDatabaseAPI(token: token).taskBlocks(id)
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
