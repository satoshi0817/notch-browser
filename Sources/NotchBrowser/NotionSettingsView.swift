import SwiftUI

/// Shared Notion connection and database notifications live outside the agent page.
struct NotionSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var connection = NotionConnectionStore.shared
    @ObservedObject private var monitor = NotionDatabaseMonitor.shared
    @State private var tokenDraft = ""
    @State private var databaseInput = ""
    @State private var databaseMessage: String?
    @State private var databaseProperties: [String: [NotionDatabaseProperty]] = [:]
    @State private var isAddingDatabase = false
    @State private var pollingDraft = "90"
    @FocusState private var pollingFocused: Bool

    var body: some View {
        Form {
            Section("Notion接続") {
                SecureField("内部インテグレーションのトークン", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Notionのトークン")
                    .onSubmit { Task { await saveToken() } }
                HStack {
                    Button {
                        Task { await saveToken() }
                    } label: {
                        if connection.isChecking { ProgressView().controlSize(.small) }
                        else { Text("確認して保存") }
                    }
                    .disabled(connection.isChecking || tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if connection.hasStoredToken {
                        Button("接続を確認") { Task { await connection.verifySaved() } }
                            .disabled(connection.isChecking)
                        Button("接続を解除", role: .destructive) { connection.disconnect() }
                            .disabled(connection.isChecking)
                    }
                    Spacer()
                    Text(connection.isChecking ? "確認中" : connection.tokenValid ? "接続済み" : "未確認")
                        .foregroundStyle(connection.tokenValid ? .green : .secondary)
                }
                if let message = connection.message {
                    Text(message).font(.caption)
                        .foregroundStyle(connection.tokenValid && connection.agentAccessValid ? Color.secondary : Color.orange)
                }
                Text("トークンはMacのキーチェーンに保存します。エージェントを有効にするには、接続とエージェントAPIの両方を確認します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("データベースの更新通知") {
                Toggle("データベース更新をノッチで通知", isOn: $settings.data.notionDatabaseNotificationsEnabled)
                Picker("通知を閉じるまで", selection: $settings.data.notionDatabaseNotificationDuration) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { seconds in
                        Text("\(seconds)秒").tag(seconds)
                    }
                }
                .disabled(!settings.data.notionDatabaseNotificationsEnabled)
                Text("監視するデータベースを登録し、通知に表示するプロパティを選びます。登録前の更新は通知しません。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("NotionのデータベースURLまたはID", text: $databaseInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await addDatabase() } }
                    Button {
                        Task { await addDatabase() }
                    } label: {
                        if isAddingDatabase { ProgressView().controlSize(.small) }
                        else { Text("追加") }
                    }
                    .disabled(!connection.tokenValid || isAddingDatabase ||
                              databaseInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let databaseMessage { Text(databaseMessage).font(.caption).foregroundStyle(.orange) }
                ForEach(settings.data.notionDatabases) { database in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle(database.name, isOn: Binding(
                                get: { currentDatabase(database.id)?.enabled ?? false },
                                set: { value in updateDatabase(database.id) { $0.enabled = value } }))
                            Spacer()
                            Button(role: .destructive) { removeDatabase(database.id) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain).help("監視対象から削除")
                        }
                        Text(database.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        if let properties = databaseProperties[database.id], !properties.isEmpty {
                            Picker("通知に表示するプロパティ", selection: Binding(
                                get: { currentDatabase(database.id)?.propertyID ?? database.propertyID },
                                set: { propertyID in
                                    guard let selected = properties.first(where: { $0.id == propertyID }) else { return }
                                    updateDatabase(database.id) {
                                        $0.propertyID = selected.id
                                        $0.propertyName = selected.name
                                        $0.addedAt = .now
                                    }
                                })) {
                                ForEach(properties) { property in Text(property.name).tag(property.id) }
                            }
                        } else {
                            HStack {
                                Text("表示: \(database.propertyName)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("プロパティを再取得") { Task { await loadProperties(for: database) } }
                                    .disabled(!connection.tokenValid)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Text("確認間隔")
                    Slider(value: Binding(
                        get: { Double(settings.data.notionDatabasePollingSeconds) },
                        set: { value in
                            settings.data.notionDatabasePollingSeconds = Int(value.rounded())
                            pollingDraft = String(settings.data.notionDatabasePollingSeconds)
                        }), in: 30...300, step: 1)
                    TextField("秒", text: $pollingDraft)
                        .frame(width: 56).textFieldStyle(.roundedBorder)
                        .focused($pollingFocused)
                        .accessibilityLabel("データベースの確認間隔（秒）")
                        .onSubmit(savePollingDraft)
                        .onChange(of: pollingFocused) { _, focused in if !focused { savePollingDraft() } }
                    Text("秒").foregroundStyle(.secondary)
                }
                Text("30〜300秒。更新のあったページだけを確認します。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = monitor.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            pollingDraft = String(settings.data.notionDatabasePollingSeconds)
            if connection.hasStoredToken && !connection.tokenValid {
                Task { await connection.verifySaved() }
            }
            for database in settings.data.notionDatabases {
                Task { await loadProperties(for: database) }
            }
        }
        .onChange(of: connection.tokenValid) { _, valid in
            if valid {
                for database in settings.data.notionDatabases {
                    Task { await loadProperties(for: database) }
                }
            }
        }
    }

    private func saveToken() async {
        if await connection.save(tokenDraft) { tokenDraft = "" }
    }

    private func savePollingDraft() {
        let value = Int(pollingDraft.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? settings.data.notionDatabasePollingSeconds
        settings.data.notionDatabasePollingSeconds = min(300, max(30, value))
        pollingDraft = String(settings.data.notionDatabasePollingSeconds)
    }

    private func currentDatabase(_ id: String) -> SavedNotionDatabase? {
        settings.data.notionDatabases.first { $0.id == id }
    }

    private func updateDatabase(_ id: String, _ change: (inout SavedNotionDatabase) -> Void) {
        guard let index = settings.data.notionDatabases.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.data.notionDatabases[index])
    }

    private func removeDatabase(_ id: String) {
        settings.data.notionDatabases.removeAll { $0.id == id }
        databaseProperties[id] = nil
    }

    private func addDatabase() async {
        guard !isAddingDatabase, let token = NotionTokenStore.read() else { return }
        guard let id = NotionDatabaseInput.id(from: databaseInput) else {
            databaseMessage = "NotionのデータベースURLまたはIDを確認してください。"; return
        }
        isAddingDatabase = true
        databaseMessage = "データベースとプロパティを取得中…"
        defer { isAddingDatabase = false }
        do {
            let details = try await NotionDatabaseAPI(token: token).details(for: id)
            guard !settings.data.notionDatabases.contains(where: { $0.id == details.id }) else {
                databaseMessage = "このデータベースは登録済みです。"; return
            }
            guard let property = details.properties.first(where: { $0.type == "rich_text" }) ?? details.properties.first else {
                databaseMessage = "通知に表示できるプロパティがありません。"; return
            }
            settings.data.notionDatabases.append(SavedNotionDatabase(id: details.id, name: details.name,
                propertyID: property.id, propertyName: property.name))
            databaseProperties[details.id] = details.properties
            databaseInput = ""; databaseMessage = nil
        } catch { databaseMessage = error.localizedDescription }
    }

    private func loadProperties(for database: SavedNotionDatabase) async {
        guard let token = NotionTokenStore.read(), connection.tokenValid else { return }
        do {
            let details = try await NotionDatabaseAPI(token: token).details(for: database.id)
            databaseProperties[database.id] = details.properties
        } catch { databaseMessage = "\(database.name): \(error.localizedDescription)" }
    }
}
