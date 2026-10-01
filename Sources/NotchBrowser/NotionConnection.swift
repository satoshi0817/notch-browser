import Combine
import Foundation

struct NotionConnectionAPI {
    let token: String
    var fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/\(path)")!)
        request.httpMethod = "GET"
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
        let (userData, _) = try await get("users/me")
        guard let user = try JSONSerialization.jsonObject(with: userData) as? [String: Any],
              user["object"] as? String == "user", user["id"] as? String != nil else {
            throw NotionAPIError.invalidResponse
        }
    }
}

final class NotionConnectionStore: ObservableObject {
    static let shared = NotionConnectionStore()

    @Published private(set) var tokenValid = false
    @Published private(set) var isChecking = false
    @Published private(set) var message: String?

    var hasStoredToken: Bool { NotionTokenStore.read() != nil }

    private init() {}

    func verifySaved() async {
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
            tokenValid = true
            message = "トークンを確認しました"
            return true
        } catch {
            message = "トークンを確認できません: \(error.localizedDescription)"
            return false
        }
    }

    func disconnect() {
        guard NotionTokenStore.save("") else {
            message = "キーチェーンの接続情報を削除できませんでした。"; return
        }
        tokenValid = false
        message = nil
        SettingsStore.shared.data.notionEnabled = false
        NotionAgentsStore.shared.storedTokenChanged()
    }
}
