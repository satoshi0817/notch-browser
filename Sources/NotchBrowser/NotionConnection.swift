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

final class NotionConnectionStore: ObservableObject {
    static let shared = NotionConnectionStore()

    @Published private(set) var tokenValid = false
    @Published private(set) var isChecking = false
    @Published private(set) var message: String?

    var hasStoredToken: Bool {
        #if DEBUG
        if previewMock { return true }
        #endif
        return NotionTokenStore.read() != nil
    }

    #if DEBUG
    private var previewMock = false
    #endif
    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOTCH_TASKS_MOCK"] != nil || CommandLine.arguments.contains(where: { $0.hasPrefix("--tasks=") }) {
            previewMock = true
            tokenValid = true
            message = "トークンを確認しました"
        }
        #endif
    }

    func verifySaved() async {
        #if DEBUG
        if previewMock { tokenValid = true; return }
        #endif
        guard !isChecking else { return }
        guard let token = NotionTokenStore.read() else {
            tokenValid = false; message = nil
            SettingsStore.shared.data.notionEnabled = false
            return
        }
        isChecking = true
        message = "接続を確認中…"
        defer { isChecking = false }
        do {
            try await NotionConnectionAPI(token: token).verify()
            guard NotionTokenStore.read() == token else { return }
            tokenValid = true
            message = "トークンを確認しました"
        } catch {
            guard NotionTokenStore.read() == token else { return }
            tokenValid = false
            message = "接続を確認できません: \(error.localizedDescription)"
            if case NotionAPIError.server(let status, _) = error, status == 401 {
                SettingsStore.shared.data.notionEnabled = false
            }
        }
        NotionAgentsStore.shared.settingsChanged()
    }

    @discardableResult
    func save(_ raw: String) async -> Bool {
        #if DEBUG
        if previewMock { tokenValid = true; return true }
        #endif
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !isChecking else { return false }
        isChecking = true
        message = "トークンを確認中…"
        defer { isChecking = false }
        do {
            try await NotionConnectionAPI(token: token).verify()
            guard NotionTokenStore.save(token) else {
                message = "トークンをキーチェーンに保存できませんでした。"; return false
            }
            NotionAgentsStore.shared.storedTokenChanged()
            await NotionTasksStore.shared.connectionChanged()
            tokenValid = true
            message = "トークンを確認しました"
            return true
        } catch {
            message = "トークンを確認できません: \(error.localizedDescription)"
            return false
        }
    }

    func disconnect() {
        #if DEBUG
        if previewMock { tokenValid = false; message = nil; return }
        #endif
        guard NotionTokenStore.save("") else {
            message = "キーチェーンの接続情報を削除できませんでした。"; return
        }
        tokenValid = false
        message = nil
        SettingsStore.shared.data.notionEnabled = false
        NotionAgentsStore.shared.storedTokenChanged()
        Task { @MainActor in NotionTasksStore.shared.connectionChanged() }
    }
}
