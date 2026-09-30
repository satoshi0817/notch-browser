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

    struct Icon: Decodable { let type: String; let emoji: String? }
    var glyph: String { icon?.emoji ?? "✦" }
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

struct NotionMessage: Decodable, Identifiable {
    let id: String
    let role: String
    let content: String
    let created_time: String
    let pending_user_actions: [NotionAction]?
}

struct NotionInvocation: Decodable { let thread_id: String; let status: String }

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

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: [String: String]? = nil) async throws -> T {
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

    func agents() async throws -> [NotionAgent] {
        var all: [NotionAgent] = [], cursor: String?
        repeat {
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let cursor { query.append(.init(name: "start_cursor", value: cursor)) }
            let page: NotionPage<NotionAgent> = try await request("agents", query: query)
            all += page.results
            cursor = page.has_more ? page.next_cursor : nil
        } while cursor != nil
        return all.filter { $0.agent_type == "custom" || $0.agent_type == "custom_agent" }
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
        repeat {
            var query = [URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "verbose", value: "false")]
            if let cursor { query.append(.init(name: "start_cursor", value: cursor)) }
            let page: NotionPage<NotionMessage> = try await request("threads/\(threadID)/messages", query: query)
            all += page.results
            cursor = page.has_more ? page.next_cursor : nil
        } while cursor != nil
        return all.sorted { $0.created_time < $1.created_time }
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
    @Published private(set) var agents: [NotionAgent] = []
    @Published private(set) var threads: [NotionThread] = []
    @Published private(set) var messages: [NotionMessage] = []
    @Published private(set) var busyAgentIDs: Set<String> = []
    @Published private(set) var alert: (agentID: String, threadID: String, title: String)?
    @Published private(set) var noticeText: String?
    @Published var selectedAgentID: String?
    @Published var selectedThreadID: String?
    @Published var error: String?
    @Published var isSending = false
    @Published private(set) var hasToken = NotionTokenStore.read() != nil
    private var timer: Timer?
    private var observed: [String: String] = [:]
    private var hasBaseline = false
    private var refreshInProgress = false

    var visibleAgents: [NotionAgent] {
        agents.filter { !SettingsStore.shared.data.notionHiddenAgentIDs.contains($0.id) }
    }

    func saveToken(_ token: String) {
        guard NotionTokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "トークンをキーチェーンに保存できませんでした。"; return
        }
        hasToken = NotionTokenStore.read() != nil
        agents = []; threads = []; messages = []; observed = [:]; hasBaseline = false
        if hasToken { Task { @MainActor in await refresh() } }
        else { timer?.invalidate(); timer = nil }
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
        defer { refreshInProgress = false }
        let api = NotionAgentsAPI(token: token)
        do {
            let fetched = try await api.agents()
            agents = fetched
            if !visibleAgents.contains(where: { $0.id == selectedAgentID }) {
                selectedAgentID = visibleAgents.first?.id
                selectedThreadID = nil
                messages = []
            }
            var running = Set<String>()
            for agent in visibleAgents {
                let list = try await api.threads(agentID: agent.id, allPages: agent.id == selectedAgentID)
                if agent.id == selectedAgentID { threads = list }
                for thread in list {
                    if thread.isRunning { running.insert(agent.id) }
                    let key = "\(agent.id):\(thread.id)"
                    let signature = "\(thread.status):\(thread.last_edited_time)"
                    if hasBaseline, let old = observed[key], old != signature,
                       SettingsStore.shared.data.notionNotificationsEnabled,
                       thread.status == "requires_action" || thread.status == "completed" {
                        var isReply = false
                        if thread.status == "completed" {
                            isReply = (try? await api.messages(threadID: thread.id).last?.role) == "agent"
                        }
                        if thread.status == "requires_action" || isReply {
                            let title = thread.status == "requires_action" ? "確認が必要です" : "返信が届きました"
                            noticeText = "\(agent.name): \(title)"
                            alert = (agent.id, thread.id, title)
                        }
                    }
                    observed[key] = signature
                }
            }
            busyAgentIDs = running
            hasBaseline = true
            if let selectedThreadID { messages = try await api.messages(threadID: selectedThreadID) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func selectAgent(_ id: String) async {
        selectedAgentID = id; selectedThreadID = nil; messages = []; threads = []
        guard let token = NotionTokenStore.read() else { return }
        do { threads = try await NotionAgentsAPI(token: token).threads(agentID: id); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func selectThread(_ id: String) async {
        selectedThreadID = id; messages = []
        guard let token = NotionTokenStore.read() else { return }
        do { messages = try await NotionAgentsAPI(token: token).messages(threadID: id); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func showHistory() { selectedThreadID = nil; messages = [] }

    func send(_ text: String) async {
        guard let agentID = selectedAgentID, let token = NotionTokenStore.read(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true; defer { isSending = false }
        do {
            let invocation = try await NotionAgentsAPI(token: token).send(text, agentID: agentID, threadID: selectedThreadID)
            selectedThreadID = invocation.thread_id
            busyAgentIDs.insert(agentID)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func respond(_ action: NotionAction, option: NotionAction.Option) async {
        guard let threadID = selectedThreadID, let token = NotionTokenStore.read() else { return }
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
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "sparkles.rectangle.stack").foregroundStyle(.purple)
                Text("Notionエージェント").font(.headline)
                Spacer()
                Button { Task { @MainActor in await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("更新")
                Button(action: onClose) { Image(systemName: "xmark") }.help("閉じる")
            }.buttonStyle(.plain).padding(14)
            if let notice = store.noticeText {
                HStack { Image(systemName: "bell.badge.fill"); Text(notice); Spacer() }
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider()
            if !store.hasToken {
                ContentUnavailableView("Notionを接続", systemImage: "key", description: Text("設定で内部インテグレーションのトークンを保存してください。"))
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("エージェント").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 9)
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(store.visibleAgents) { agent in
                                    Button { Task { @MainActor in await store.selectAgent(agent.id) } } label: {
                                        HStack(spacing: 7) {
                                            Text(agent.glyph).frame(width: 22)
                                            Text(agent.name).lineLimit(1)
                                            Spacer(minLength: 0)
                                            if store.busyAgentIDs.contains(agent.id) { ProgressView().controlSize(.mini) }
                                        }.padding(7).background(store.selectedAgentID == agent.id ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }.frame(width: 170).padding(8)
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
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 11) {
                                        Button("‹ 履歴に戻る") { store.showHistory() }.font(.caption)
                                        ForEach(store.messages) { message in
                                            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 3) {
                                                Text(message.role == "user" ? "あなた" : agent.name).font(.caption2).foregroundStyle(.secondary)
                                                Text(message.content).textSelection(.enabled)
                                                    .padding(10)
                                                    .background(message.role == "user" ? Color.blue.opacity(0.24) : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                                            }.frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                                        }
                                        ForEach(store.threads.first(where: { $0.id == store.selectedThreadID })?.pending_user_actions ?? []) { action in
                                            VStack(alignment: .leading, spacing: 8) {
                                                Label(action.title, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                                                HStack {
                                                    ForEach(action.options) { option in
                                                        if option.id == "approve" || option.id == "reject" {
                                                            Button(option.label) { Task { @MainActor in await store.respond(action, option: option) } }
                                                        } else if option.id == "use_connection",
                                                                  let urlString = action.requirements?.compactMap(\.handoff_url).first,
                                                                  let url = URL(string: urlString), url.scheme == "https" {
                                                            Button(option.label) { NSWorkspace.shared.open(url) }
                                                        }
                                                    }
                                                }
                                            }.padding(11).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                                        }
                                    }.padding(12)
                                }
                            }
                            Divider()
                            HStack(alignment: .bottom) {
                                TextField("エージェントにメッセージ", text: $draft, axis: .vertical)
                                    .lineLimit(1...4).textFieldStyle(.plain)
                                    .onSubmit(send)
                                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSending)
                            }.padding(11)
                        } else {
                            ContentUnavailableView("表示するエージェントがありません", systemImage: "sparkles", description: Text("設定で表示するエージェントを選んでください。"))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        .onAppear { store.start() }
        .onChange(of: settings.data.notionHiddenAgentIDs) { _, _ in
            if !store.visibleAgents.contains(where: { $0.id == store.selectedAgentID }),
               let first = store.visibleAgents.first {
                Task { @MainActor in await store.selectAgent(first.id) }
            }
        }
    }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draft = ""
        Task { @MainActor in await store.send(message) }
    }
}

struct NotionAgentsSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var agents = NotionAgentsStore.shared
    @State private var token = ""

    var body: some View {
        Form {
            Section("接続") {
                SecureField("内部インテグレーションのトークン", text: $token)
                HStack {
                    Button("トークンを保存") { agents.saveToken(token); token = "" }.disabled(token.isEmpty)
                    if agents.hasToken { Button("接続を解除", role: .destructive) { agents.saveToken("") } }
                    Spacer()
                    Text(agents.hasToken ? "接続済み" : "未接続").foregroundStyle(agents.hasToken ? .green : .secondary)
                }
                Text("Notion Custom Agents API の利用権限がある内部インテグレーションを使用します。トークンはMacのキーチェーンに保存します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("表示するエージェント") {
                if agents.agents.isEmpty { Text("接続後にエージェント一覧が表示されます。") }
                ForEach(agents.agents) { agent in
                    Toggle(isOn: Binding(
                        get: { !settings.data.notionHiddenAgentIDs.contains(agent.id) },
                        set: { shown in
                            if shown { settings.data.notionHiddenAgentIDs.remove(agent.id) }
                            else { settings.data.notionHiddenAgentIDs.insert(agent.id) }
                        })) {
                        HStack { Text(agent.glyph); Text(agent.name) }
                    }
                }
                Button("一覧を更新") { Task { @MainActor in await agents.refresh() } }.disabled(!agents.hasToken)
            }
            Section("通知") {
                Toggle("返信・確認待ちでノッチを開く", isOn: $settings.data.notionNotificationsEnabled)
            }
            if let error = agents.error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .onAppear { agents.start() }
    }
}
