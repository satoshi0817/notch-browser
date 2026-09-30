import AppKit
import Combine
import Security
import SwiftUI

// The token stays in the login Keychain; only display preferences go to UserDefaults.
enum NotionTokenStore {
    private static var service: String { "\(Bundle.main.bundleIdentifier ?? "com.satoshi0817.NotchBrowser").notion-agents" }
    private static let account = "internal-integration"

    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

struct NotionPage<T: Decodable>: Decodable {
    let results: [T]
    let has_more: Bool
    let next_cursor: String?
}

struct NotionAgent: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let agent_type: String
    let status: String
    let icon: Icon?

    struct Icon: Decodable {
        let type: String
        let emoji: String?
        let file: URLValue?
        let external: URLValue?
        let custom_emoji: URLValue?
        let custom_agent_avatar: Avatar?

        struct URLValue: Decodable { let url: String }
        struct Avatar: Decodable { let static_url: String; let animated_url: String? }

        var imageURL: String? {
            let value = custom_agent_avatar?.static_url ?? custom_emoji?.url ?? file?.url ?? external?.url
            guard let value, URLComponents(string: value)?.scheme?.lowercased() == "https" else { return nil }
            return value
        }
    }
    var glyph: String { icon?.emoji ?? "✦" }
    var iconURL: String? { icon?.imageURL }
}

struct NotionAction: Decodable, Identifiable {
    let id: String
    let title: String
    let options: [Option]
    let requirements: [Requirement]?
    struct Option: Decodable, Identifiable { let id: String; let label: String }
    struct Requirement: Decodable { let type: String; let handoff_url: String? }
}

struct NotionThread: Decodable, Identifiable {
    let id: String
    let title: String
    let status: String
    let last_edited_time: String
    let pending_user_actions: [NotionAction]?
    var isRunning: Bool { status == "pending" || status == "queued" || status == "in_progress" }
}

enum NotionThreadAlertPolicy {
    static func title(for thread: NotionThread, previousSignature: String?, hasBaseline: Bool) -> String? {
        let signature = "\(thread.status):\(thread.last_edited_time)"
        guard hasBaseline, previousSignature != signature else { return nil }
        if thread.status == "requires_action" { return "確認が必要です" }
        if thread.status == "completed" { return "返信が届きました" }
        return nil
    }
}

struct NotionMessage: Decodable, Identifiable {
    let id: String
    let role: String
    let content: String
    let created_time: String
    let pending_user_actions: [NotionAction]?

    static func oldestFirst(_ messages: [NotionMessage]) -> [NotionMessage] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        return messages.enumerated().sorted { left, right in
            let a = fractional.date(from: left.element.created_time) ?? standard.date(from: left.element.created_time)
            let b = fractional.date(from: right.element.created_time) ?? standard.date(from: right.element.created_time)
            guard let a, let b, a != b else { return left.offset < right.offset }
            return a < b
        }.map(\.element)
    }
}

private struct NotionSessionEvent: Decodable {
    let id: String
    let type: String
    let sequence: Int
    let created_at: String
    let content: [ContentBlock]?

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let name: String?
    }

    private enum CodingKeys: String, CodingKey { case id, type, sequence, created_at, content }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        sequence = try values.decode(Int.self, forKey: .sequence)
        created_at = try values.decode(String.self, forKey: .created_at)
        content = try? values.decode([ContentBlock].self, forKey: .content)
    }

    var message: NotionMessage? {
        guard type == "user.message" || type == "agent.message" else { return nil }
        let text = (content ?? []).compactMap { part -> String? in
            if part.type == "text" { return part.text }
            if part.type == "file" { return part.name.map { "添付: \($0)" } }
            return nil
        }.joined(separator: "\n")
        return NotionMessage(id: id, role: type == "user.message" ? "user" : "agent",
                             content: text, created_time: created_at, pending_user_actions: nil)
    }
}

struct NotionInvocation: Decodable { let thread_id: String; let status: String }

enum NotionAgentInput {
    static func id(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            guard let host = url.host?.lowercased(),
                  ["notion.so", "www.notion.so", "notion.com", "www.notion.com", "app.notion.com"].contains(host) else { return nil }
            candidate = url.path.split(separator: "/").last.map(String.init) ?? ""
        } else if value.contains("://") { return nil }
        else { candidate = value }
        let suffix = candidate.split(separator: "-").last.map(String.init) ?? candidate
        let compact = suffix.replacingOccurrences(of: "-", with: "")
        if compact.count == 32, compact.allSatisfy(\.isHexDigit) {
            let value = compact.lowercased()
            return "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.dropFirst(20))"
        }
        if let uuid = UUID(uuidString: candidate) { return uuid.uuidString.lowercased() }
        guard !value.contains("://"), candidate.count >= 8, candidate.count <= 128,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return candidate
    }
}

enum NotionAPIError: LocalizedError {
    case missingToken, invalidResponse, server(Int, String)
    var errorDescription: String? {
        switch self {
        case .missingToken: "Notionのトークンを設定してください。"
        case .invalidResponse: "Notionからの応答を読み取れませんでした。"
        case .server(let status, let message): "Notion API (\(status)): \(message)"
        }
    }
}

struct NotionAgentsAPI {
    var token: String
    var fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        guard !token.isEmpty else { throw NotionAPIError.missingToken }
        var components = URLComponents(string: "https://api.notion.com/v1/\(path)")!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await fetch(request)
        guard let response = response as? HTTPURLResponse else { throw NotionAPIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(NotionServerError.self, from: data))?.message ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw NotionAPIError.server(response.statusCode, message)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NotionAPIError.invalidResponse }
    }

    private struct NotionServerError: Decodable { let message: String }

    func agent(id: String) async throws -> NotionAgent? {
        let page: NotionPage<NotionAgent> = try await request("agents", query: [
            .init(name: "agent_ids", value: id), .init(name: "page_size", value: "1")
        ])
        return page.results.first { $0.id == id }
    }

    func searchAgents(named name: String, cursor: String? = nil) async throws -> NotionPage<NotionAgent> {
        var query = [URLQueryItem(name: "page_size", value: "50"), URLQueryItem(name: "name", value: name)]
        if let cursor { query.append(.init(name: "start_cursor", value: cursor)) }
        let page: NotionPage<NotionAgent>
        do { page = try await request("agents", query: query) }
        catch NotionAPIError.server(let status, _) where status == 400 {
            // Older agent APIs can reject the server-side name filter; scan one page locally instead.
            var fallback = [URLQueryItem(name: "page_size", value: "50")]
            if let cursor { fallback.append(.init(name: "start_cursor", value: cursor)) }
            page = try await request("agents", query: fallback)
        }
        return NotionPage(results: page.results.filter {
            ($0.agent_type == "custom" || $0.agent_type == "custom_agent") &&
                $0.name.localizedStandardContains(name)
        }, has_more: page.has_more, next_cursor: page.next_cursor)
    }

    func threads(agentID: String, allPages: Bool = true) async throws -> [NotionThread] {
        var all: [NotionThread] = [], cursor: String?
        repeat {
            var query = [URLQueryItem(name: "page_size", value: "100"),
                         URLQueryItem(name: "sort_by", value: "last_used_time"),
                         URLQueryItem(name: "sort_direction", value: "descending")]
            if let cursor { query.append(.init(name: "start_cursor", value: cursor)) }
            let page: NotionPage<NotionThread> = try await request("agents/\(agentID)/threads", query: query)
            all += page.results
            cursor = allPages && page.has_more ? page.next_cursor : nil
        } while cursor != nil
        return all
    }

    func messages(threadID: String) async throws -> [NotionMessage] {
        var all: [NotionMessage] = [], cursor: String?
        do {
            repeat {
                var query = [URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "verbose", value: "false")]
                if let cursor { query.append(.init(name: "start_cursor", value: cursor)) }
                let page: NotionPage<NotionMessage> = try await request("threads/\(threadID)/messages", query: query)
                all += page.results
                cursor = page.has_more ? page.next_cursor : nil
            } while cursor != nil
        } catch NotionAPIError.invalidResponse {
            // A session may have a newer message representation; try committed events.
        } catch NotionAPIError.server(404, _) {
            // Older threads can be available through sessions even without message listing.
        }
        if all.contains(where: { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return NotionMessage.oldestFirst(all)
        }
        // Some existing chats expose their content only through session events.
        var events: [NotionSessionEvent] = []
        cursor = nil
        repeat {
            var body: [String: Any] = ["page_size": 100,
                                       "sorts": [["property": "sequence", "direction": "ascending"]]]
            if let cursor { body["start_cursor"] = cursor }
            let page: NotionPage<NotionSessionEvent> = try await request("sessions/\(threadID)/events/query", body: body)
            events += page.results
            cursor = page.has_more ? page.next_cursor : nil
        } while cursor != nil
        let eventMessages = events.sorted { $0.sequence < $1.sequence }.compactMap(\.message)
        return eventMessages.isEmpty ? all : eventMessages
    }

    func send(_ message: String, agentID: String, threadID: String?) async throws -> NotionInvocation {
        if let threadID { return try await request("threads/\(threadID)/messages", body: ["message": message]) }
        return try await request("agents/\(agentID)/chat", body: ["message": message])
    }

    func respond(actionID: String, optionID: String, threadID: String) async throws -> NotionInvocation {
        try await request("threads/\(threadID)/continue", body: ["action_id": actionID, "option_id": optionID])
    }
}

final class NotionAgentsStore: ObservableObject {
    static let shared = NotionAgentsStore()
    @Published private(set) var threads: [NotionThread] = []
    @Published private(set) var messages: [NotionMessage] = []
    @Published private(set) var busyAgentIDs: Set<String> = []
    @Published private(set) var alert: (agentID: String, threadID: String, title: String)?
    @Published private(set) var noticeText: String?
    @Published var selectedAgentID: String?
    @Published var selectedThreadID: String?
    @Published var error: String?
    @Published var isSending = false
    @Published private(set) var isResponding = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingMessages = false
    @Published private(set) var activityText: String?
    @Published private(set) var hasToken = NotionTokenStore.read() != nil
    private var timer: Timer?
    private var observed: [String: String] = [:]
    private var metadataChecked: Set<String> = []
    private var baselinedAgentIDs: Set<String> = []
    private var refreshInProgress = false
    private var refreshQueued = false

    var visibleAgents: [SavedNotionAgent] { SettingsStore.shared.data.notionSavedAgents }

    func saveToken(_ token: String) {
        guard NotionTokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "トークンをキーチェーンに保存できませんでした。"; return
        }
        hasToken = NotionTokenStore.read() != nil
        threads = []; messages = []; busyAgentIDs = []; observed = [:]; metadataChecked = []; baselinedAgentIDs = []; error = nil
        selectedAgentID = nil; selectedThreadID = nil
        if hasToken { start() }
        else { timer?.invalidate(); timer = nil }
    }

    func registrationChanged() {
        let ids = Set(visibleAgents.map(\.id))
        busyAgentIDs.formIntersection(ids)
        metadataChecked.formIntersection(ids)
        baselinedAgentIDs.formIntersection(ids)
        observed = observed.filter { ids.contains(String($0.key.split(separator: ":").first ?? "")) }
        if !ids.contains(selectedAgentID ?? "") {
            selectedAgentID = visibleAgents.first?.id
            selectedThreadID = nil; threads = []; messages = []
        }
        if hasToken {
            if refreshInProgress { refreshQueued = true }
            else { Task { @MainActor in await refresh() } }
        }
    }

    func start() {
        guard hasToken else { return }
        if timer == nil {
            timer = .scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
        Task { @MainActor in await refresh() }
    }

    func refresh() async {
        guard hasToken, !refreshInProgress, let token = NotionTokenStore.read() else { return }
        refreshInProgress = true
        isRefreshing = true
        defer {
            refreshInProgress = false; isRefreshing = false; activityText = nil
            if refreshQueued {
                refreshQueued = false
                Task { @MainActor in await refresh() }
            }
        }
        let registered = visibleAgents
        guard !registered.isEmpty else {
            busyAgentIDs = []; threads = []; messages = []; error = nil
            return
        }
        if !registered.contains(where: { $0.id == selectedAgentID }) {
            selectedAgentID = registered.first?.id
            selectedThreadID = nil; threads = []; messages = []
        }
        let api = NotionAgentsAPI(token: token)
        do {
            var running = Set<String>()
            var failures: [String] = []
            for (index, agent) in registered.enumerated() {
                guard visibleAgents.contains(where: { $0.id == agent.id }) else { continue }
                activityText = "エージェントを確認中（\(index + 1)/\(registered.count)）"
                let placeholder = "エージェント \(agent.id.prefix(8))"
                if !metadataChecked.contains(agent.id) {
                    do {
                        if let metadata = try await api.agent(id: agent.id) {
                            metadataChecked.insert(agent.id)
                            if let savedIndex = SettingsStore.shared.data.notionSavedAgents.firstIndex(where: { $0.id == agent.id }) {
                                if SettingsStore.shared.data.notionSavedAgents[savedIndex].name == placeholder {
                                    SettingsStore.shared.data.notionSavedAgents[savedIndex].name = metadata.name
                                }
                                SettingsStore.shared.data.notionSavedAgents[savedIndex].glyph = metadata.glyph
                                SettingsStore.shared.data.notionSavedAgents[savedIndex].iconURL = metadata.iconURL
                            }
                        } else {
                            failures.append("\(agent.name): NotionでIDが見つかりません。IDと共有権限を確認してください。")
                        }
                    } catch { failures.append("\(agent.name): 名前の取得に失敗しました（\(error.localizedDescription)）") }
                }
                let list: [NotionThread]
                do { list = try await api.threads(agentID: agent.id, allPages: false) }
                catch { failures.append("\(agent.name): \(error.localizedDescription)"); continue }
                if agent.id == selectedAgentID { threads = list }
                for thread in list {
                    if thread.isRunning { running.insert(agent.id) }
                    let key = "\(agent.id):\(thread.id)"
                    let signature = "\(thread.status):\(thread.last_edited_time)"
                    if SettingsStore.shared.data.notionNotificationsEnabled,
                       let title = NotionThreadAlertPolicy.title(for: thread,
                           previousSignature: observed[key], hasBaseline: baselinedAgentIDs.contains(agent.id)) {
                        let name = visibleAgents.first(where: { $0.id == agent.id })?.name ?? agent.name
                        noticeText = "\(name): \(title)"
                        alert = (agent.id, thread.id, title)
                    }
                    observed[key] = signature
                }
                baselinedAgentIDs.insert(agent.id)
            }
            busyAgentIDs = running.intersection(Set(visibleAgents.map(\.id)))
            if let selectedThreadID {
                activityText = "会話を読み込み中…"
                let fetched = try await api.messages(threadID: selectedThreadID)
                if self.selectedThreadID == selectedThreadID { messages = fetched }
            }
            error = failures.first.map { failures.count == 1 ? $0 : "\($0) ほか\(failures.count - 1)件" }
        } catch { self.error = error.localizedDescription }
    }

    func selectAgent(_ id: String) async {
        selectedAgentID = id; selectedThreadID = nil; messages = []; threads = []
        guard let token = NotionTokenStore.read() else { return }
        activityText = "チャット履歴を読み込み中…"
        defer { activityText = nil }
        do {
            let fetched = try await NotionAgentsAPI(token: token).threads(agentID: id, allPages: false)
            if selectedAgentID == id { threads = fetched }
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }

    func selectThread(_ id: String) async {
        selectedThreadID = id; messages = []
        guard let token = NotionTokenStore.read() else { return }
        isLoadingMessages = true
        activityText = "会話を読み込み中…"
        defer { isLoadingMessages = false; activityText = nil }
        do {
            let fetched = try await NotionAgentsAPI(token: token).messages(threadID: id)
            if selectedThreadID == id { messages = fetched }
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }

    func showHistory() { selectedThreadID = nil; messages = [] }

    func send(_ text: String) async {
        guard let agentID = selectedAgentID, let token = NotionTokenStore.read(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true; activityText = "メッセージを送信中…"
        defer { isSending = false; activityText = nil }
        do {
            let invocation = try await NotionAgentsAPI(token: token).send(text, agentID: agentID, threadID: selectedThreadID)
            selectedThreadID = invocation.thread_id
            busyAgentIDs.insert(agentID)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func respond(_ action: NotionAction, option: NotionAction.Option) async {
        guard let threadID = selectedThreadID, let token = NotionTokenStore.read() else { return }
        isResponding = true; activityText = "アクションを送信中…"
        defer { isResponding = false; activityText = nil }
        do {
            _ = try await NotionAgentsAPI(token: token).respond(actionID: action.id, optionID: option.id, threadID: threadID)
            alert = nil
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func clearAlert() {
        alert = nil
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            noticeText = nil
        }
    }
}

struct NotionAgentsPanel: View {
    @ObservedObject private var store = NotionAgentsStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var draft = ""
    @State private var tokenDraft = ""
    @State private var showJumpToBottom = false
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "sparkles.rectangle.stack").foregroundStyle(.purple)
                Text("Notionエージェント").font(.headline)
                Spacer()
                Button { Task { @MainActor in await store.refresh() } } label: {
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.help("登録したエージェントを更新")
                    .disabled(!store.hasToken || store.visibleAgents.isEmpty || store.isRefreshing)
                Button(action: onClose) { Image(systemName: "xmark") }.help("閉じる")
            }.buttonStyle(.plain).padding(14)
            if let notice = store.noticeText {
                HStack { Image(systemName: "bell.badge.fill"); Text(notice); Spacer() }
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider()
            if !store.hasToken {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Notionを接続", systemImage: "key").font(.headline)
                    Text("内部インテグレーションのトークンを入力してください。")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("トークンを貼り付け", text: $tokenDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Notionのトークン")
                        .onSubmit(saveToken)
                    Button("トークンを保存", action: saveToken)
                        .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("トークンはMacのキーチェーンに保存します。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(28)
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("エージェント").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 9)
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(store.visibleAgents) { agent in
                                    Button { Task { @MainActor in await store.selectAgent(agent.id) } } label: {
                                        HStack(spacing: 7) {
                                            NotionAgentAvatar(agent: agent, size: 22)
                                            Text(agent.name).lineLimit(1)
                                            Spacer(minLength: 0)
                                            if store.busyAgentIDs.contains(agent.id) { ProgressView().controlSize(.mini) }
                                        }.padding(7).background(store.selectedAgentID == agent.id ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }.frame(width: 210).padding(8)
                    Divider()
                    VStack(spacing: 0) {
                        if let agent = store.visibleAgents.first(where: { $0.id == store.selectedAgentID }) {
                            HStack {
                                Text(agent.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Button { store.showHistory() } label: { Image(systemName: "square.and.pencil") }.help("新しいチャット")
                            }.buttonStyle(.plain).padding(11)
                            Divider()
                            if store.selectedThreadID == nil {
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 4) {
                                        ForEach(store.threads) { thread in
                                            Button { Task { @MainActor in await store.selectThread(thread.id) } } label: {
                                                HStack {
                                                    Image(systemName: thread.status == "requires_action" ? "exclamationmark.circle.fill" : "bubble.left")
                                                        .foregroundStyle(thread.status == "requires_action" ? .orange : .secondary)
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(thread.title.isEmpty ? "無題のチャット" : thread.title).lineLimit(2)
                                                        Text(thread.status == "requires_action" ? "確認待ち" : thread.isRunning ? "稼働中" : "履歴").font(.caption2).foregroundStyle(.secondary)
                                                    }
                                                    Spacer()
                                                }.padding(9)
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }
                            } else {
                                ScrollViewReader { proxy in
                                GeometryReader { geometry in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 17) {
                                        Button("‹ 履歴に戻る") { store.showHistory() }.font(.caption)
                                        if store.messages.isEmpty {
                                            if store.isLoadingMessages {
                                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("会話を読み込み中…") }
                                                    .foregroundStyle(.secondary).padding(.top, 20)
                                            } else {
                                                ContentUnavailableView("メッセージがありません", systemImage: "bubble.left",
                                                                       description: Text("このチャットには表示できるメッセージがありません。"))
                                            }
                                        }
                                        ForEach(store.messages) { message in
                                            NotionMessageView(message: message, agent: agent)
                                        }
                                        if store.busyAgentIDs.contains(agent.id) {
                                            NotionThinkingView(agent: agent)
                                        }
                                        ForEach(store.threads.first(where: { $0.id == store.selectedThreadID })?.pending_user_actions ?? []) { action in
                                            VStack(alignment: .leading, spacing: 8) {
                                                Label(action.title, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                                                HStack {
                                                    ForEach(action.options) { option in
                                                        if option.id == "approve" || option.id == "reject" {
                                                            Button(option.label) { Task { @MainActor in await store.respond(action, option: option) } }
                                                                .disabled(store.isResponding)
                                                        } else if option.id == "use_connection",
                                                                  let urlString = action.requirements?.compactMap(\.handoff_url).first,
                                                                  let url = URL(string: urlString), url.scheme == "https" {
                                                            Button(option.label) { NSWorkspace.shared.open(url) }
                                                        }
                                                    }
                                                }
                                            }.padding(11).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                        }
                                        Color.clear.frame(height: 1).id("conversation-bottom")
                                            .background(GeometryReader { marker in
                                                Color.clear.preference(key: ConversationBottomKey.self,
                                                    value: marker.frame(in: .named("conversation")).maxY)
                                            })
                                    }
                                    .frame(maxWidth: 720)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 24).padding(.vertical, 18)
                                }
                                .coordinateSpace(name: "conversation")
                                .onPreferenceChange(ConversationBottomKey.self) { bottom in
                                    showJumpToBottom = bottom > geometry.size.height + 80
                                }
                                .onAppear { DispatchQueue.main.async { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
                                .onChange(of: store.selectedThreadID) { _, _ in
                                    showJumpToBottom = false
                                    DispatchQueue.main.async { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                                }
                                .onChange(of: store.messages.count) { _, _ in
                                    if !showJumpToBottom { withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
                                }
                                .overlay(alignment: .bottom) {
                                    if showJumpToBottom {
                                        Button {
                                            withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                                        } label: {
                                            Label("最新のメッセージへ", systemImage: "arrow.down")
                                                .font(.caption.weight(.medium))
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .padding(.bottom, 12)
                                    }
                                }
                                }
                                }
                            }
                            HStack(spacing: 7) {
                                if let activity = store.activityText {
                                    ProgressView().controlSize(.mini)
                                    Text(activity)
                                }
                                Spacer()
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(height: 24).padding(.horizontal, 20)
                            HStack(alignment: .bottom, spacing: 12) {
                                TextField("エージェントにメッセージ", text: $draft, axis: .vertical)
                                    .lineLimit(1...5).textFieldStyle(.plain)
                                    .onKeyPress(.return, phases: .down) { key in
                                        if key.modifiers.contains(.command) { send(); return .handled }
                                        return .ignored
                                    }
                                Button(action: send) {
                                    if store.isSending { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)) }
                                }
                                    .buttonStyle(.borderedProminent)
                                    .clipShape(Circle())
                                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSending)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 20))
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.11)))
                            .padding(.horizontal, 20)
                            Text("⌘↩ で送信")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.horizontal, 24).padding(.bottom, 12)
                        } else {
                            VStack(spacing: 10) {
                                ContentUnavailableView("エージェントが未登録です", systemImage: "sparkles", description: Text("URL・IDまたは名前検索で追加してください。"))
                                Button("エージェントを追加", action: onOpenSettings)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        .onAppear { store.start() }
    }

    private func saveToken() {
        guard !tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.saveToken(tokenDraft)
        if store.hasToken { tokenDraft = "" }
    }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draft = ""
        Task { @MainActor in await store.send(message) }
    }
}

private struct ConversationBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct NotionThinkingView: View {
    let agent: SavedNotionAgent
    @State private var phraseIndex = 0
    private let phrases = ["考えています…", "情報を確認しています…", "返信をまとめています…"]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NotionAgentAvatar(agent: agent, size: 28)
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(phrases[phraseIndex]).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 15).padding(.vertical, 12)
            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 17))
            Spacer()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { phraseIndex = (phraseIndex + 1) % phrases.count }
            }
        }
    }
}

struct NotionAgentsSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var agents = NotionAgentsStore.shared
    @State private var token = ""
    @State private var agentInput = ""
    @State private var inputMessage: String?
    @State private var searchName = ""
    @State private var searchResults: [NotionAgent] = []
    @State private var searchCursor: String?
    @State private var isSearching = false
    @State private var searchMessage: String?

    var body: some View {
        Form {
            Section("接続") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("内部インテグレーションのトークン").font(.subheadline.weight(.medium))
                    SecureField("トークンを貼り付け", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Notionのトークン")
                        .onSubmit { saveToken() }
                }
                HStack {
                    Button("トークンを保存", action: saveToken)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if agents.hasToken { Button("接続を解除", role: .destructive) { agents.saveToken("") } }
                    Spacer()
                    Text(agents.hasToken ? "接続済み" : "未接続").foregroundStyle(agents.hasToken ? .green : .secondary)
                }
                Text("Notion Custom Agents API の利用権限がある内部インテグレーションを使用します。トークンはMacのキーチェーンに保存します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("登録したエージェント") {
                Text("NotionのURLまたはエージェントIDを入力します。登録したものだけを監視します。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("NotionのエージェントURLまたはID", text: $agentInput)
                        .textFieldStyle(.roundedBorder).onSubmit(addAgent)
                    Button("追加", action: addAgent)
                        .disabled(agentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let inputMessage { Text(inputMessage).font(.caption).foregroundStyle(.orange) }
                if settings.data.notionSavedAgents.isEmpty {
                    Text("まだ登録されていません。URL・IDで追加するか、下の名前検索から選べます。")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.data.notionSavedAgents) { $agent in
                    HStack(spacing: 10) {
                        Text(agent.glyph).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("表示名", text: $agent.name).textFieldStyle(.plain)
                            Text(agent.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button { removeAgent(agent.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).help("登録リストから削除")
                            .accessibilityLabel("\(agent.name)を登録リストから削除")
                    }
                }
                HStack {
                    Button { Task { @MainActor in await agents.refresh() } } label: {
                        if agents.isRefreshing { ProgressView().controlSize(.small) }
                        else { Label("登録済みを確認", systemImage: "arrow.clockwise") }
                    }.disabled(!agents.hasToken || agents.isRefreshing || settings.data.notionSavedAgents.isEmpty)
                    if let activity = agents.activityText { Text(activity).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("名前で探す") {
                Text("名前の一部を入力して検索します。結果は50件ずつ読み込みます。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("エージェント名の一部", text: $searchName)
                        .textFieldStyle(.roundedBorder).onSubmit { Task { await search(reset: true) } }
                    Button { Task { await search(reset: true) } } label: {
                        if isSearching { ProgressView().controlSize(.small) }
                        else { Text("検索") }
                    }.disabled(!agents.hasToken || isSearching || searchName.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                }
                if let searchMessage { Text(searchMessage).font(.caption).foregroundStyle(.secondary) }
                ForEach(searchResults) { result in
                    HStack {
                        Text(result.glyph); Text(result.name)
                        Spacer()
                        Button(settings.data.notionSavedAgents.contains(where: { $0.id == result.id }) ? "追加済み" : "追加") {
                            save(result)
                        }.disabled(settings.data.notionSavedAgents.contains(where: { $0.id == result.id }))
                    }
                }
                if searchCursor != nil {
                    Button { Task { await search(reset: false) } } label: {
                        if isSearching { ProgressView().controlSize(.small) }
                        else { Text("次のページを探す") }
                    }.disabled(isSearching)
                }
            }
            Section("通知") {
                Toggle("返信・確認待ちでノッチを開く", isOn: $settings.data.notionNotificationsEnabled)
            }
            if let error = agents.error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .onAppear { agents.start() }
    }

    private func saveToken() {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        agents.saveToken(token)
        if agents.hasToken { token = "" }
    }

    private func addAgent() {
        guard let id = NotionAgentInput.id(from: agentInput) else {
            inputMessage = "NotionのエージェントURLまたはIDを確認してください。"; return
        }
        guard !settings.data.notionSavedAgents.contains(where: { $0.id == id }) else {
            inputMessage = "このエージェントは登録済みです。"; return
        }
        settings.data.notionSavedAgents.append(SavedNotionAgent(id: id, name: "エージェント \(id.prefix(8))"))
        agentInput = ""; inputMessage = nil
        agents.registrationChanged()
    }

    private func save(_ result: NotionAgent) {
        guard !settings.data.notionSavedAgents.contains(where: { $0.id == result.id }) else { return }
        settings.data.notionSavedAgents.append(SavedNotionAgent(id: result.id, name: result.name, glyph: result.glyph, iconURL: result.iconURL))
        agents.registrationChanged()
    }

    private func removeAgent(_ id: String) {
        settings.data.notionSavedAgents.removeAll { $0.id == id }
        agents.registrationChanged()
    }

    private func search(reset: Bool) async {
        guard !isSearching, let token = NotionTokenStore.read() else { return }
        let name = searchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { return }
        let cursor = reset ? nil : searchCursor
        if reset { searchResults = []; searchCursor = nil }
        isSearching = true
        searchMessage = "検索中…"
        defer { isSearching = false }
        do {
            let page = try await NotionAgentsAPI(token: token).searchAgents(named: name, cursor: cursor)
            guard searchName.trimmingCharacters(in: .whitespacesAndNewlines) == name else { return }
            let known = Set(searchResults.map(\.id))
            searchResults += page.results.filter { !known.contains($0.id) }
            searchCursor = page.has_more ? page.next_cursor : nil
            searchMessage = searchResults.isEmpty
                ? (searchCursor == nil ? "一致するエージェントは見つかりませんでした。" : "このページに一致はありません。次のページも探せます。")
                : "\(searchResults.count)件見つかりました。"
        } catch { searchMessage = error.localizedDescription }
    }
}
