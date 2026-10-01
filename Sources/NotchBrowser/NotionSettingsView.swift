import SwiftUI

private enum DatabasePollingFrequency: String, CaseIterable, Identifiable {
    case high, medium, low, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .high: "高頻度"
        case .medium: "中頻度"
        case .low: "低頻度"
        case .custom: "カスタム"
        }
    }
    var detail: String {
        switch self {
        case .high: "30秒ごと"
        case .medium: "90秒ごと"
        case .low: "5分ごと"
        case .custom: "30秒〜5分"
        }
    }
    var seconds: Int? {
        switch self {
        case .high: 30
        case .medium: 90
        case .low: 300
        case .custom: nil
        }
    }
    static func matching(_ seconds: Int) -> Self {
        allCases.first { $0.seconds == seconds } ?? .custom
    }
}

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
    @State private var pollingFrequency = DatabasePollingFrequency.medium
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
                        .foregroundStyle(connection.tokenValid ? Color.secondary : Color.orange)
                }
                if connection.tokenValid && !settings.data.notionEnabled {
                    Button("カスタムエージェントを有効にする") {
                        settings.data.notionEnabled = true
                    }
                }
                Text("トークンはMacのキーチェーンに保存します。エージェントを有効にするには、Notionへの接続を確認します。")
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
                VStack(alignment: .leading, spacing: 10) {
                    Text("確認間隔").font(.subheadline.weight(.medium))
                    HStack(spacing: 8) {
                        ForEach(DatabasePollingFrequency.allCases) { frequency in
                            frequencyCard(frequency)
                        }
                    }
                    if pollingFrequency == .custom {
                        HStack {
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
                    }
                }
                Text("初期値は中頻度。間隔を短くするとNotionへの問い合わせが増えます。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = monitor.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            pollingDraft = String(settings.data.notionDatabasePollingSeconds)
            pollingFrequency = .matching(settings.data.notionDatabasePollingSeconds)
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

    private func frequencyCard(_ frequency: DatabasePollingFrequency) -> some View {
        let selected = pollingFrequency == frequency
        return Button {
            pollingFrequency = frequency
            if let seconds = frequency.seconds {
                settings.data.notionDatabasePollingSeconds = seconds
                pollingDraft = String(seconds)
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(frequency.title).font(.system(size: 13, weight: .semibold))
                Text(frequency.detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.horizontal, 10)
            .background(selected ? Color.blue.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.blue : Color.secondary.opacity(0.2), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(frequency.title)、\(frequency.detail)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
