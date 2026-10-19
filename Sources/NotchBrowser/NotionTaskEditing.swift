import Foundation

struct NotionStatusOption: Identifiable, Hashable {
    let id: String
    let name: String
    let color: String
    var category: NotionTaskStatusCategory? = nil
    static func parse(_ property: [String: Any]) -> [Self] {
        guard property["type"] as? String == "status",
              let status = property["status"] as? [String: Any] else { return [] }
        let groups = status["groups"] as? [[String: Any]] ?? []
        var categories: [String: NotionTaskStatusCategory] = [:]
        for (index, group) in groups.enumerated() {
            for id in group["option_ids"] as? [String] ?? [] {
                categories[id] = index == groups.count - 1 ? .complete : index == 0 ? .notStarted : .inProgress
            }
        }
        return (status["options"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
            return Self(id: id, name: name, color: $0["color"] as? String ?? "default", category: categories[id])
        }
    }
}

enum NotionTaskField: String, Hashable { case status, due }
enum NotionTaskEditValue: Equatable {
    case status(NotionStatusOption), due(Date?)
    var field: NotionTaskField { if case .status = self { return .status }; return .due }
    var payload: [String: Any] {
        switch self {
        case .status(let option): return ["status": ["id": option.id]]
        case .due(let date):
            guard let date else { return ["date": NSNull()] }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            return ["date": ["start": formatter.string(from: date)]]
        }
    }
}
struct NotionTaskEditKey: Equatable { let page: String; let field: NotionTaskField }
struct NotionTaskEdit {
    let revision: Int
    let value: NotionTaskEditValue
    var original: NotionTask
    let property: String
    let source: String
}
struct NotionTaskWriteFailure {
    enum Kind: Equatable { case failed, noPermission, deleted, conflict }
    let kind: Kind
    let value: NotionTaskEditValue
    var text: String {
        switch kind {
        case .noPermission: return "編集するには Notion で『Update content』をオンにしてください"
        case .deleted: return "このページは削除されたか、共有されていません"
        case .conflict: return "Notion の変更と競合しました。再試行してください"
        case .failed: return "Notion に保存できませんでした"
        }
    }
}
enum NotionTaskEditRules {
    static func dateEditable(_ value: [String: Any]?) -> Bool {
        guard let value else { return true }
        guard value["end"] == nil || value["end"] is NSNull else { return false }
        guard let start = value["start"] as? String else { return false }
        return start.count == 10 && NotionTaskRules.parseDate(start) != nil
    }
    static func validate(_ value: NotionTaskEditValue, property: NotionDatabaseProperty?) throws {
        guard let property, property.type == (value.field == .status ? "status" : "date") else {
            throw NotionAPIError.invalidResponse
        }
        if case .status(let option) = value, !property.statusOptions.contains(where: { $0.id == option.id }) {
            throw NotionAPIError.invalidResponse
        }
    }
    static func status(_ error: Error) -> (Int, String?) {
        switch error {
        case NotionAPIError.server(let status, _): return (status, nil)
        case NotionAPIError.coded(let status, let code, _): return (status, code)
        default: return (0, nil)
        }
    }
    static func replacing(_ row: NotionTask, value: NotionTaskEditValue, category: NotionTaskStatusCategory? = nil, edited: Date? = nil) -> NotionTask {
        switch value {
        case .status(let option):
            return NotionTask(id: row.id, title: row.title, url: row.url, status: option.name,
                completed: (category ?? option.category) == .complete, due: row.due, edited: edited ?? row.edited,
                dueEditable: row.dueEditable, statusCategory: category ?? option.category, statusColor: option.color)
        case .due(let date):
            return NotionTask(id: row.id, title: row.title, url: row.url, status: row.status,
                completed: row.completed, due: date, edited: edited ?? row.edited,
                dueEditable: row.dueEditable, statusCategory: row.statusCategory, statusColor: row.statusColor)
        }
    }
    static func timestamp(_ row: NotionTask, _ edited: Date) -> NotionTask {
        NotionTask(id: row.id, title: row.title, url: row.url, status: row.status, completed: row.completed,
                   due: row.due, edited: edited, dueEditable: row.dueEditable, statusCategory: row.statusCategory, statusColor: row.statusColor)
    }
}

@MainActor extension NotionTasksStore {
    var statusOptions: [NotionStatusOption] { properties.first { $0.name == configuration.mapping.status && $0.type == "status" }?.statusOptions ?? [] }
    func canEdit(_ field: NotionTaskField, task: NotionTask) -> Bool {
        !noPermission && !(writeFailures[task.id]?.values.contains { $0.kind == .deleted } ?? false)
            && properties.contains { $0.name == (field == .status ? configuration.mapping.status : configuration.mapping.due) && $0.type == (field == .status ? "status" : "date") }
            && (field != .due || task.dueEditable == true)
    }
    func resetWritePermission() { noPermission = false }
    func retryWrite(page: String, field: NotionTaskField) {
        resetWritePermission()
        guard let failure = writeFailures[page]?[field] else { return }
        writeFailures[page]?[field] = nil
        edit(page: page, value: failure.value)
        if pendingEdits[page]?[field] == nil && !isMock { writeFailures[page, default: [:]][field] = failure }
    }
    func edit(page: String, value: NotionTaskEditValue) {
        guard let row = tasks.first(where: { $0.id == page }), canEdit(value.field, task: row),
              let source = configuration.source,
              let property = value.field == .status ? configuration.mapping.status : configuration.mapping.due,
              (try? NotionTaskEditRules.validate(value, property: properties.first { $0.name == property })) != nil else { return }
        writeRevision += 1
        let original = pendingEdits[page]?[value.field]?.original ?? row
        pendingEdits[page, default: [:]][value.field] = .init(revision: writeRevision, value: value, original: original, property: property, source: source)
        let key = NotionTaskEditKey(page: page, field: value.field)
        if !writeOrder.contains(key) { writeOrder.append(key) }
        writeFailures[page]?[value.field] = nil
        replace(page: page, value: value)
        saveCache()
        #if DEBUG
        // DesignPreview is strictly offline, including interactions with the editors.
        if isMock { pendingEdits = [:]; writeOrder = []; return }
        #endif
        if !writing { writing = true; Task { await drainWrites() } }
    }
    func replace(page: String, value: NotionTaskEditValue, category: NotionTaskStatusCategory? = nil, edited: Date? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == page }) else { return }
        tasks[index] = NotionTaskEditRules.replacing(tasks[index], value: value, category: category, edited: edited)
    }
    func mergePending(previous: [NotionTask], fetched: [NotionTask], full: Bool) -> [NotionTask] {
        let existing = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let incoming = fetched.map { remote in
            // A refresh started before a successful PATCH may finish after it.
            if let local = existing[remote.id], local.edited > remote.edited { return local }
            return remote
        }
        var rows = NotionPageRefreshRules.merge(previous, fetched: incoming, full: full)
        for row in previous where pendingEdits[row.id] != nil {
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                // Preserve each pending field while accepting unrelated remote fields.
                for (field, edit) in pendingEdits[row.id] ?? [:] {
                    if rows[index].edited > edit.original.edited { pendingEdits[row.id]?[field]?.original = rows[index] }
                    rows[index] = NotionTaskEditRules.replacing(rows[index], value: edit.value, category: row.statusCategory)
                }
            } else { rows.append(row) }
        }
        guard rows.count > NotionPageRefreshRules.rowLimit else { return rows }
        // Pending rows must survive even when a full refresh fills the cache limit.
        let protected = rows.filter { pendingEdits[$0.id] != nil }
        let other = rows.filter { pendingEdits[$0.id] == nil }
        return protected + Array(other.prefix(max(0, NotionPageRefreshRules.rowLimit - protected.count)))
    }
    private func drainWrites() async {
        defer { writing = false }
        while !writeOrder.isEmpty {
            do { try await writeWait(0.35) } catch {
                for (page, fields) in pendingEdits {
                    for (field, edit) in fields {
                        rollback(page: page, field: field, original: edit.original)
                        writeFailures[page, default: [:]][field] = .init(kind: .failed, value: edit.value)
                    }
                }
                pendingEdits = [:]; writeOrder = []; saveCache()
                return
            }
            guard !writeOrder.isEmpty else { return }
            let key = writeOrder.removeFirst()
            guard var edit = pendingEdits[key.page]?[key.field] else { continue }
            let epoch = writeEpoch
            var conflictPage: [String: Any]?
            do {
                guard !noPermission, let token = tokenProvider() else { throw NotionAPIError.missingToken }
                let api = apiFactory(token)
                let (schema, _, categories) = try await api.taskSchema(edit.source, statusName: configuration.mapping.status)
                guard epoch == writeEpoch, token == tokenProvider(), !noPermission,
                      let latest = pendingEdits[key.page]?[key.field] else { continue }
                properties = schema
                // Coalesce changes made while the schema request was in flight too.
                edit = latest
                writeOrder.removeAll { $0 == key }
                try NotionTaskEditRules.validate(edit.value, property: schema.first { $0.name == edit.property })
                if key.field == .due {
                    let page = try await api.request("pages/\(key.page)")
                    guard epoch == writeEpoch, token == tokenProvider() else { continue }
                    let property = (page["properties"] as? [String: [String: Any]])?[edit.property]
                    guard property?["type"] as? String == "date",
                          NotionTaskEditRules.dateEditable(property?["date"] as? [String: Any]) else {
                        conflictPage = page
                        throw NotionAPIError.invalidResponse
                    }
                    // No PATCH of an obsolete value after an awaited preflight.
                    guard let latest = pendingEdits[key.page]?[key.field] else { continue }
                    edit = latest
                    writeOrder.removeAll { $0 == key }
                }
                guard epoch == writeEpoch, !noPermission, token == tokenProvider() else { continue }
                let result: [String: Any]
                do {
                    result = try await api.request("pages/\(key.page)", body: ["properties": [edit.property: edit.value.payload]], method: "PATCH")
                } catch {
                    let status = NotionTaskEditRules.status(error).0
                    if status == 503 || status == 409 {
                        let page = try await api.request("pages/\(key.page)")
                        guard epoch == writeEpoch, token == tokenProvider() else { continue }
                        if status == 409 { conflictPage = page; throw error }
                        let property = (page["properties"] as? [String: [String: Any]])?[edit.property] ?? [:]
                        guard property["type"] as? String == (key.field == .status ? "status" : "date") else {
                            conflictPage = page
                            throw NotionAPIError.invalidResponse
                        }
                        if matches(property, value: edit.value) { result = page }
                        else {
                            if key.field == .due, !NotionTaskEditRules.dateEditable(property["date"] as? [String: Any]) {
                                conflictPage = page
                                throw NotionAPIError.invalidResponse
                            }
                            // Confirm failure before rewriting; a newer edit supersedes this retry.
                            guard pendingEdits[key.page]?[key.field]?.revision == edit.revision else { continue }
                            try await writeWait(0.35)
                            guard epoch == writeEpoch, !noPermission, token == tokenProvider(),
                                  pendingEdits[key.page]?[key.field]?.revision == edit.revision else { continue }
                            result = try await api.request("pages/\(key.page)", body: ["properties": [edit.property: edit.value.payload]], method: "PATCH")
                        }
                    } else { throw error }
                }
                guard epoch == writeEpoch, token == tokenProvider(), let current = pendingEdits[key.page]?[key.field] else { continue }
                let category: NotionTaskStatusCategory?
                if case .status(let option) = edit.value { category = categories[option.id] }
                else { category = edit.original.statusCategory }
                let confirmed = NotionTaskEditRules.replacing(edit.original, value: edit.value, category: category)
                if current.revision == edit.revision {
                    replace(page: key.page, value: edit.value, category: category)
                    pendingEdits[key.page]?[key.field] = nil
                } else { pendingEdits[key.page]?[key.field]?.original = confirmed }
                if let date = (result["last_edited_time"] as? String).flatMap(NotionMessage.parseDate), let index = tasks.firstIndex(where: { $0.id == key.page }) {
                    tasks[index] = NotionTaskEditRules.timestamp(tasks[index], date)
                }
                writeFailures[key.page] = nil
            } catch {
                guard epoch == writeEpoch else { continue }
                let (status, code) = NotionTaskEditRules.status(error)
                let restricted = status == 403 && code == "restricted_resource"
                if restricted { noPermission = true }
                guard let current = pendingEdits[key.page]?[key.field], current.revision == edit.revision || restricted || status == 409 || conflictPage != nil else { continue }
                rollback(page: key.page, field: key.field, original: current.original)
                pendingEdits[key.page]?[key.field] = nil
                if let page = conflictPage { applyRemotePage(page, id: key.page) }
                writeFailures[key.page, default: [:]][key.field] = .init(kind: restricted ? .noPermission : status == 404 ? .deleted : status == 409 ? .conflict : .failed, value: current.value)
                if restricted {
                    for (page, fields) in pendingEdits {
                        for (field, pending) in fields {
                            rollback(page: page, field: field, original: pending.original)
                            writeFailures[page, default: [:]][field] = .init(kind: .noPermission, value: pending.value)
                        }
                    }
                    pendingEdits = [:]; writeOrder = []
                }
            }
            if pendingEdits[key.page]?.isEmpty == true { pendingEdits[key.page] = nil }
            saveCache()
        }
    }
    private func matches(_ property: [String: Any], value: NotionTaskEditValue) -> Bool {
        guard property["type"] as? String == (value.field == .status ? "status" : "date") else { return false }
        switch value {
        case .status(let option): return (property["status"] as? [String: Any])?["id"] as? String == option.id
        case .due(nil): return property["date"] is NSNull
        case .due:
            let expected = value.payload["date"] as? [String: String]
            let date = property["date"] as? [String: Any]
            return date?["start"] as? String == expected?["start"] && NotionTaskEditRules.dateEditable(date)
        }
    }
    private func rollback(page: String, field: NotionTaskField, original: NotionTask) {
        if field == .due { replace(page: page, value: .due(original.due)) }
        else { replace(page: page, value: .status(.init(id: "", name: original.status, color: original.statusColor ?? "default")), category: original.category) }
    }
    private func applyRemotePage(_ page: [String: Any], id: String) {
        let properties = page["properties"] as? [String: [String: Any]] ?? [:]
        if pendingEdits[id]?[.due] == nil, let name = configuration.mapping.due {
            let date = properties[name]?["date"] as? [String: Any]
            replace(page: id, value: .due((date?["start"] as? String).flatMap(NotionTaskRules.parseDate)))
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].dueEditable = properties[name]?["type"] as? String == "date" && NotionTaskEditRules.dateEditable(date)
            }
        }
        if pendingEdits[id]?[.status] == nil, let name = configuration.mapping.status,
           let status = properties[name]?["status"] as? [String: Any], let option = statusOptions.first(where: { $0.id == status["id"] as? String }) {
            replace(page: id, value: .status(option))
        }
        if let edited = (page["last_edited_time"] as? String).flatMap(NotionMessage.parseDate),
           let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index] = NotionTaskEditRules.timestamp(tasks[index], edited) }
    }
}
