import Combine
import Foundation

struct NotionConnectionAPI {
    let token: String
    var fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    private func search(_ path: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"page_size":1}"#.utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-09-03", forHTTPHeaderField: "Notion-Version")
        let (data, response) = try await fetch(request)
        guard let response = response as? HTTPURLResponse else { throw NotionAPIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw NotionAPIError.server(response.statusCode, message)
        }
        return (data, response)
    }

    func verify() async throws {
        guard !token.isEmpty else { throw NotionAPIError.missingToken }
        let (data, _) = try await search("search")
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["object"] as? String == "list", result["results"] is [[String: Any]] else {
            throw NotionAPIError.invalidResponse
        }
    }
}

enum NotionConnectionState: String, CaseIterable {
    case unconnected, verifying, connected, unverified, invalid
    var label: String {
        switch self {
        case .unconnected: "未接続"
        case .verifying: "確認中"
        case .connected: "接続済み"
        case .unverified: "未確認"
        case .invalid: "無効なトークン"
        }
    }
}

final class NotionConnectionStore: ObservableObject {
    static let shared = NotionConnectionStore()
    @Published private(set) var state: NotionConnectionState = .unconnected
    @Published private(set) var hasStoredToken = false
    @Published private(set) var message: String?
    @Published private var checkingNewToken = false
    var tokenValid: Bool { state == .connected }
    var isChecking: Bool { state == .verifying || checkingNewToken }
    var stateLabel: String { state.label }
    var canReverify: Bool {
        NotionTaskRules.showsReverificationEntry(state: state, hasStoredToken: hasStoredToken)
    }
    var showsEmptySettingsButton: Bool {
        NotionTaskRules.showsEmptySettingsButton(bannerVisible: canReverify)
    }
    var showsConnectionError: Bool {
        NotionTaskRules.showsConnectionError(state: state, hasStoredToken: hasStoredToken)
    }
    var bannerTitle: String {
        state == .invalid ? "Notion のトークンが無効です" :
        state == .unverified ? "Notion に接続できませんでした" : "Notion 接続を確認中…"
    }
    var bannerDetail: String {
        state == .invalid ? "設定を開いて、トークンを入れ直してください" :
        state == .unverified ? "ネットワークを確認して、再確認してください" : "接続を確認しています"
    }
    var failureMessage: String? {
        guard NotionTaskRules.showsConnectionError(state: state, hasStoredToken: hasStoredToken) else { return nil }
        return message ?? (state == .invalid ? "トークンが無効です。Notion 接続を設定し直してください" :
                           "未確認: 接続を確認できません")
    }
    var showsLoading: Bool { NotionTaskRules.showsConnectionLoading(state: state, hasStoredToken: hasStoredToken) }

    #if DEBUG
    typealias PreviewState = NotionConnectionState
    static func previewState(arguments: [String]) -> PreviewState? {
        if arguments.contains("--meetings=pinned-unconnected") { return .unconnected }
        if arguments.contains("--meetings=error") { return .unverified }
        if let explicit = arguments.first(where: { $0.hasPrefix("--notion-connection=") }) {
            return PreviewState(rawValue: String(explicit.dropFirst("--notion-connection=".count)))
        }
        if arguments.contains(where: {
            $0 == "--fixed-pages-drag" || $0.hasPrefix("--fixed-display=") ||
            $0.hasPrefix("--meeting-section=") || $0 == "--meetings=empty-tabs"
        }) { return .connected }
        return nil
    }
    static var launchPreviewState: PreviewState? { previewState(arguments: CommandLine.arguments) }
    var isPreview: Bool { previewMock }
    private var previewMock = false
    private var previewVerification: (() async throws -> Void)?
    static func preview(state: PreviewState, verification: (() async throws -> Void)? = nil) -> NotionConnectionStore {
        let store = NotionConnectionStore(initialState: state)
        store.previewVerification = verification
        return store
    }
    static func preview(connected: Bool) -> NotionConnectionStore {
        preview(state: connected ? .connected : .unverified)
    }
    #endif

    private init(initialState: NotionConnectionState? = nil) {
        #if DEBUG
        let fixture = initialState ?? Self.launchPreviewState
        let legacyFixture = ProcessInfo.processInfo.environment["NOTCH_TASKS_MOCK"] != nil ||
            CommandLine.arguments.contains { $0.hasPrefix("--tasks=") || $0.hasPrefix("--agents=") || $0.hasPrefix("--meetings=") }
        let effectiveFixture: NotionConnectionState? = fixture ?? (legacyFixture ? .connected : nil)
        if let fixture = effectiveFixture {
            previewMock = true
            hasStoredToken = fixture != .unconnected
            state = fixture
            if fixture == .unverified { message = "未確認: 接続を確認できません" }
            if fixture == .invalid { message = "トークンが無効です。Notion 接続を設定し直してください" }
            return
        }
        #endif
        hasStoredToken = NotionTokenStore.read() != nil
        state = hasStoredToken ? .unverified : .unconnected
    }

    func verifySaved() async {
        #if DEBUG
        if previewMock {
            guard !isChecking, hasStoredToken, let verification = previewVerification else { return }
            state = .verifying
            message = "接続を確認中…"
            do { try await verification(); state = .connected; message = "トークンを確認しました" }
            catch { verificationFailed(error) }
            return
        }
        #endif
        guard !isChecking else { return }
        guard let token = NotionTokenStore.read() else {
            hasStoredToken = false
            state = .unconnected
            message = nil
            SettingsStore.shared.data.notionEnabled = false
            return
        }
        hasStoredToken = true
        state = .verifying
        message = "接続を確認中…"
        do {
            try await NotionConnectionAPI(token: token).verify()
            guard NotionTokenStore.read() == token else { return }
            state = .connected
            message = "トークンを確認しました"
        } catch {
            guard NotionTokenStore.read() == token else { return }
            verificationFailed(error)
        }
        NotionAgentsStore.shared.settingsChanged()
    }

    private func verificationFailed(_ error: Error) {
        state = NotionTaskRules.connectionState(after: error)
        message = state == .invalid ? "トークンが無効です。Notion 接続を設定し直してください" :
            "未確認: 接続を確認できません: \(error.localizedDescription)"
        // Keep the agent feature preference on authentication and network failures.
    }

    @discardableResult
    func save(_ raw: String) async -> Bool {
        #if DEBUG
        if previewMock { hasStoredToken = true; state = .connected; message = "接続済み"; return true }
        #endif
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !isChecking else { return false }
        checkingNewToken = true
        message = "トークンを確認中…"
        defer { checkingNewToken = false }
        do {
            try await NotionConnectionAPI(token: token).verify()
            guard NotionTokenStore.save(token) else {
                message = "トークンをキーチェーンに保存できませんでした。"; return false
            }
            hasStoredToken = true
            state = .connected
            message = "トークンを確認しました"
            NotionAgentsStore.shared.storedTokenChanged()
            await NotionTasksStore.shared.connectionChanged()
            await NotionMeetingsStore.shared.connectionChanged()
            return true
        } catch {
            // A rejected replacement must not invalidate a previously saved connection.
            message = "トークンを確認できません: \(error.localizedDescription)"
            return false
        }
    }

    func disconnect() {
        #if DEBUG
        if previewMock { hasStoredToken = false; state = .unconnected; message = nil; return }
        #endif
        guard NotionTokenStore.save("") else {
            message = "キーチェーンの接続情報を削除できませんでした。"; return
        }
        hasStoredToken = false
        state = .unconnected
        message = nil
        SettingsStore.shared.data.notionEnabled = false
        NotionAgentsStore.shared.storedTokenChanged()
        Task { @MainActor in NotionTasksStore.shared.connectionChanged(); NotionMeetingsStore.shared.connectionChanged() }
    }
}
