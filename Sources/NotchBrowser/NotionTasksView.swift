import SwiftUI

struct NotionTabListHeader<Leading: View>: View {
    let refreshing: Bool
    var failureHelp: String? = nil
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let settingsLabel: String
    let leading: () -> Leading
    init(refreshing: Bool, failureHelp: String? = nil, onRefresh: @escaping () -> Void, onSettings: @escaping () -> Void,
         settingsLabel: String, @ViewBuilder leading: @escaping () -> Leading) {
        self.refreshing = refreshing
        self.failureHelp = failureHelp
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.settingsLabel = settingsLabel
        self.leading = leading
    }
    var body: some View {
        HStack(spacing: 8) {
            leading()
            NotionRefreshButton(refreshing: refreshing, failureHelp: failureHelp, action: onRefresh)
            Button(action: onSettings) { Image(systemName: "gearshape") }
                .help(settingsLabel).accessibilityLabel("\(settingsLabel)を開く")
        }.padding()
    }
}

enum NotionSettingsFieldLayout {
    static let labelWidth: CGFloat = 200
    static let actionWidth: CGFloat = 56
    static let spacing: CGFloat = 8
}

@MainActor struct NotionTasksSettings: View {
    var title = "データ"
    @ObservedObject private var store = NotionTasksStore.shared
    @ObservedObject private var connection = NotionConnectionStore.shared
    init(title: String = "データ") { self.title = title }
    private var checklist: NotionTaskRules.Checklist {
        NotionTaskRules.checklist(tokenValid: connection.tokenValid, checking: connection.isChecking,
                                 url: store.configuration.url, confirmedURL: store.configuration.confirmedURL)
    }
    var body: some View {
        Section(title) {
            VStack(alignment: .leading, spacing: 4) {
                checklistItem("Notion に接続", complete: checklist.loggedIn)
                checklistItem("データベースの URL", complete: checklist.databaseURL)
                Text(checklist.hint).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: NotionSettingsFieldLayout.spacing) {
                Text("データベースの URL")
                    .fixedSize(horizontal: true, vertical: false)
                TextField("データベースの URL", text: $store.configuration.url,
                          prompt: Text("https://www.notion.so/…").foregroundStyle(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                    .accessibilityLabel("データベースの URL")
                    .onChange(of: store.configuration.url) { _, _ in
                        store.verified = false; store.sources = []; store.configuration.source = nil
                        store.configuration.mapping = NotionTaskMapping()
                        store.tasks = []; store.message = nil
                    }
                Button { Task { await store.configure() } } label: {
                    Text("確認").frame(width: NotionSettingsFieldLayout.actionWidth)
                }.buttonStyle(.bordered).controlSize(.regular)
                    .fixedSize()
                    .disabled(!NotionTaskRules.canConfirm(url: store.configuration.url, checking: store.checking || store.refreshing))
            }.frame(minWidth: 0, maxWidth: .infinity)
            if store.verified || !(store.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if store.verified {
                        Text("✓ \(store.name)（\(store.tasks.count)件）").font(.caption).foregroundStyle(.green)
                    }
                    if let message = store.message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(message).font(.caption).foregroundStyle(.red)
                        if let url = NotionTaskRules.errorLink(message, url: store.configuration.url) {
                            Link("Notion で開く", destination: url).font(.caption)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            if NotionTaskRules.showsSourcePicker(store.sources) {
                Picker("データソース", selection: $store.configuration.source) {
                    ForEach(store.sources) { Text($0.name).tag(Optional($0.id)) }
                }.onChange(of: store.configuration.source) { old, new in
                    if old != nil && new != nil && !store.checking { Task { await store.sourceChanged() } }
                }
            }
            DisclosureGroup("プロパティの設定") {
                mappingPicker("状態", type: "status", selection: $store.configuration.mapping.status)
                mappingPicker("期日", type: "date", selection: $store.configuration.mapping.due)
                Button("適用して更新") { Task { await store.refresh() } }
            }
            Picker("タスクの既定フィルタ", selection: $store.filter) {
                ForEach(NotionTaskFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            NotionCacheSettingsRow(updated: store.lastUpdated, clear: store.clearCache)
        }
        .task { if connection.tokenValid && store.available { await store.configure() } }
    }
    private func checklistItem(_ title: String, complete: Bool) -> some View {
        HStack(spacing: 6) {
            Text(complete ? "✓" : "○").foregroundStyle(complete ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 14)
            Text(title)
        }
    }
    private func mappingPicker(_ title: String, type: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("なし").tag(Optional<String>.none)
            ForEach(store.properties.filter { $0.type == type }) { Text($0.name).tag(Optional($0.name)) }
        }
    }
}

@MainActor struct NotionTasksPanel: View {
    @ObservedObject private var connection = NotionConnectionStore.shared
    var openingID = UUID()
    var onOpenSettings: () -> Void = {}
    @State private var showingSettings = false
    @ObservedObject private var store = NotionTasksStore.shared
    @State private var selected: NotionTask?
    @State private var selectionOrigin: NotionTaskSelectionOrigin = .keyboard
    @State private var selectionID = UUID()
    @State private var deletedSelection = false
    @Namespace private var taskRows
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            if !store.hasCache { NotionConnectionNotice(onOpenSettings: onOpenSettings) }
            if showingSettings && !connection.showsConnectionError {
                HStack { Button("‹ 戻る") { showingSettings = false }; Spacer() }.padding(12)
            } else if !connection.showsConnectionError && store.configuration.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack { Spacer(); settingsButton }.padding(12)
            }
            if connection.showsConnectionError {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { if store.hasCache { taskContent } }
            } else if showingSettings {
                NotionTasksSettingsPage(onOpenSettings: onOpenSettings)
            } else if connection.showsLoading {
                if store.hasCache { taskContent }
                else { NotionConnectionLoading().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else if store.configuration.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Text("データベースの URL が設定されていません").foregroundStyle(.secondary)
                    if connection.showsEmptySettingsButton {
                        NotionTabEmptySettingsButton { showingSettings = true }
                    }
                }
                Spacer()
            } else {
                taskContent
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.tasks)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: openingID) {
            #if DEBUG
            if ["tab-settings", "settings", "sources", "settings-error"].contains(store.mockState ?? "") { showingSettings = true }
            if ["detail", "loading", "no-body"].contains(store.mockState ?? "") || NotionTaskEditingPreview(rawValue: store.mockState ?? "")?.showsDetail == true { selectTask(store.tasks.first) }
            #endif
            if connection.tokenValid { await store.refresh(force: false) }
        }
        .onChange(of: connection.state) { _, state in
            if state == .connected { Task { await store.refresh(force: false) } }
        }
        .onChange(of: store.configuration.source) { _, _ in selected = nil; deletedSelection = false }
        .onChange(of: store.hasCache) { _, cached in if !cached { deletedSelection = false } }
        .onChange(of: store.tasks) { _, tasks in
            if let id = selected?.id {
                deletedSelection = store.hasCache && NotionPageRefreshRules.deletedSelection(id, rows: tasks)
                selected = tasks.first { $0.id == id }
            }
        }
    }
    private var taskContent: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 640 {
                    list.frame(width: (geometry.size.width - 1) / 2)
                    Divider()
                    Group {
                        if deletedSelection { NotionDeletedItemView() }
                        else if let selected { detail(selected, narrow: false) }
                        else { Text("タスクを選ぶと詳細が表示されます").foregroundStyle(.tertiary) }
                    }.frame(width: (geometry.size.width - 1) / 2, height: geometry.size.height)
                } else if deletedSelection {
                    VStack(alignment: .leading) {
                        Button("‹ 一覧") { deletedSelection = false }.buttonStyle(.plain).padding(20)
                        NotionDeletedItemView()
                    }
                } else if let selected {
                    detail(selected, narrow: true).frame(maxWidth: .infinity)
                } else {
                    list.frame(maxWidth: .infinity)
                }
            }
        }
    }
    // Default origin covers preview/programmatic/AX selection; row taps opt into pointer.
    private func selectTask(_ task: NotionTask?, origin: NotionTaskSelectionOrigin = .keyboard) {
        selectionOrigin = origin
        selectionID = UUID()
        deletedSelection = false
        selected = task
    }
    private func detail(_ task: NotionTask, narrow: Bool) -> some View {
        NotionTaskDetail(task: task, selectionOrigin: selectionOrigin, back: { selected = nil }, narrow: narrow, onOpenSettings: onOpenSettings)
            .id("\(task.id)-\(openingID)-\(selectionID)")
    }
    @ViewBuilder private var settingsButton: some View {
        if !connection.showsConnectionError {
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .help("タスク設定").accessibilityLabel("タスク設定を開く")
        }
    }
    private var list: some View {
        VStack(spacing: 0) {
            NotionTabListHeader(refreshing: store.refreshing,
                               failureHelp: store.hasCache && store.message != nil ? NotionPageRefreshRules.failureHelp(store.lastUpdated) : nil,
                               onRefresh: { Task { await store.refresh() } },
                               onSettings: { showingSettings = true }, settingsLabel: "タスク設定") {
                Picker("表示", selection: $store.filter) {
                    ForEach(NotionTaskFilter.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }.pickerStyle(.segmented)
            }
            if let message = store.message, !store.hasCache { Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            if store.refreshing && !store.hasCache { ProgressView().padding() }
            let rows = NotionTaskRules.rows(store.tasks, filter: store.filter)
            if rows.isEmpty {
                Spacer()
                Text(emptyMessage).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(NotionTaskGroup.allCases, id: \.self) { group in
                            let items = rows.filter { NotionTaskRules.group($0, now: Date(), calendar: .current) == group }
                            if !items.isEmpty {
                                Text(group.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 5)
                                ForEach(items) { task in
                                    row(task)
                                        .matchedGeometryEffect(id: task.id, in: taskRows)
                                        .contentShape(Rectangle())
                                        .onTapGesture { selectTask(task, origin: .pointer) }
                                        .accessibilityAction(.default) { selectTask(task) }
                                        .transition(.identity)
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private var emptyMessage: String {
        return store.filter == .incomplete ? "未完了のタスクはありません" : "タスクはありません"
    }
    private func taskColor(_ task: NotionTask) -> Color {
        switch task.statusColor {
        case "brown": .brown
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "blue": .blue
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "gray", "default": .secondary
        default:
            switch task.category {
            case .notStarted: .secondary
            case .inProgress: .blue
            case .complete: .green
            }
        }
    }
    private func row(_ task: NotionTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: task.category.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(taskColor(task)).frame(width: 16)
                .accessibilityLabel(task.status)
            Text(task.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            NotionTaskStatusEditor(task: task, compact: true, color: taskColor(task))
            if let failure = store.writeFailures[task.id]?.values.first {
                Button { store.retryWrite(page: task.id, field: failure.value.field) } label: {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                }.buttonStyle(.plain)
                    .help(store.noPermission ? NotionTaskWriteFailure(kind: .noPermission, value: failure.value).text : "Notion に保存できませんでした")
                    .accessibilityLabel("Notion に保存できませんでした。再試行")
            }
            Text(task.due.map { NotionTaskRules.dateLabel($0) } ?? "").font(.caption).monospacedDigit()
                .foregroundStyle(NotionTaskRules.group(task, now: Date(), calendar: .current) == .overdue ? Color.orange : Color.secondary)
                .frame(width: 46, alignment: .trailing)
        }.padding(.horizontal, 12).frame(height: 36)
            .background(selected?.id == task.id ? Color.accentColor.opacity(0.12) : .clear)
    }
}
@MainActor private struct NotionTaskDetail: View {
    let task: NotionTask
    let selectionOrigin: NotionTaskSelectionOrigin
    let back: () -> Void
    let narrow: Bool
    let onOpenSettings: () -> Void
    @ObservedObject private var store = NotionTasksStore.shared
    @State private var blocks: [NotionTaskBlock] = []
    @State private var loading = true
    @State private var error: String?
    @State private var editFocusGroup = UUID()
    @FocusState private var editFocus: NotionTaskField?
    init(task: NotionTask, selectionOrigin: NotionTaskSelectionOrigin, back: @escaping () -> Void, narrow: Bool, onOpenSettings: @escaping () -> Void) {
        self.selectionOrigin = selectionOrigin
        self.task = task; self.back = back; self.narrow = narrow; self.onOpenSettings = onOpenSettings
        let cached = NotionTasksStore.shared.bodies[task.id]
        _blocks = State(initialValue: cached ?? [])
        _loading = State(initialValue: cached == nil)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if narrow { Button("‹ 一覧", action: back).buttonStyle(.plain) }
                Text(task.title).font(.title2.weight(.semibold))
                if let url = task.url { Link("Notion で開く", destination: url) }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("状態").foregroundStyle(.secondary)
                        NotionTaskStatusEditor(task: task, detailFocus: $editFocus, detailGroup: editFocusGroup, initialSelectionOrigin: selectionOrigin)
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        Text("期日").foregroundStyle(.secondary)
                        NotionTaskDueEditor(task: task, detailFocus: $editFocus, detailGroup: editFocusGroup, initialSelectionOrigin: selectionOrigin)
                    }
                }
                NotionTaskDetailSaveNotice(page: task.id, onOpenSettings: onOpenSettings)
                Divider()
                if loading {
                    ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)).frame(height: index == 0 ? 24 : 14) }
                } else if let error { Text(error).foregroundStyle(.red) }
                else if blocks.isEmpty { Text("本文はありません").foregroundStyle(.tertiary) }
                else { ForEach(blocks) { block in NotionTaskBlockView(block: block) } }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.onChange(of: store.bodies) { _, bodies in
            if let body = bodies[task.id] { blocks = body }
        }.task {
            // Enter the detail's native key loop instead of leaving the web view as responder.
            if store.canEdit(.status, task: task) { editFocus = .status }
            else if store.canEdit(.due, task: task) { editFocus = .due }
            if let cached = store.bodies[task.id] { blocks = cached; loading = false }
            else { loading = true }
            do { blocks = try await store.blocks(for: task.id) }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}
struct NotionTaskBlockView: View {
    let block: NotionTaskBlock
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if block.type == "image", let url = block.image {
                #if DEBUG
                if url.scheme == "notch-preview" {
                    Image(nsImage: Self.previewImage).resizable().scaledToFit()
                } else {
                    AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                }
                #else
                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                #endif
            } else {
                HStack(alignment: .top) {
                    if block.type == "to_do" { Image(systemName: block.checked ? "checkmark.square" : "square") }
                    if block.type == "bulleted_list_item" { Text("•") }
                    if block.type == "numbered_list_item" { Text("\(block.listNumber).") }
                    if supported && !block.runs.isEmpty { Text(attributedText).textSelection(.enabled) }
                    else if supported, let url = block.link { Link(block.text.isEmpty ? url.absoluteString : block.text, destination: url) }
                    else { Text(block.text).textSelection(.enabled) }
                }.font(font)
            }
        }.padding(.leading, CGFloat(block.depth) * 16).frame(maxWidth: .infinity, alignment: .leading)
    }
    #if DEBUG
    private static let previewImage = NSImage(size: NSSize(width: 480, height: 180), flipped: false) { rect in
        NSColor(calibratedRed: 0.88, green: 0.93, blue: 0.98, alpha: 1).setFill()
        NSBezierPath(rect: rect).fill()
        NSColor(calibratedRed: 0.32, green: 0.53, blue: 0.78, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 180, height: 120), xRadius: 12, yRadius: 12).fill()
        NSColor(calibratedRed: 0.62, green: 0.75, blue: 0.89, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 230, y: 60, width: 220, height: 90), xRadius: 12, yRadius: 12).fill()
        return true
    }
    #endif
    private var supported: Bool {
        ["paragraph", "heading_1", "heading_2", "heading_3", "bulleted_list_item", "numbered_list_item", "to_do", "bookmark", "link_preview"].contains(block.type)
    }
    private var font: Font {
        switch block.type {
        case "heading_1": .title2.weight(.semibold)
        case "heading_2": .title3.weight(.semibold)
        case "heading_3": .headline
        default: .body
        }
    }
    private var attributedText: AttributedString {
        var result = AttributedString()
        for run in block.runs {
            var part = AttributedString(run.text)
            part.link = run.url
            result.append(part)
        }
        return result
    }
}

@MainActor struct NotionTabConnectionSettings: View {
    @ObservedObject private var connection = NotionConnectionStore.shared
    let onOpenSettings: () -> Void
    var body: some View {
        Section("接続") {
            LabeledContent("接続状態", value: connection.stateLabel)
            Button("「Notion 接続」の設定を開く", action: onOpenSettings)
                .buttonStyle(.link).foregroundStyle(Color.accentColor)
        }
    }
}

struct NotionTabEmptySettingsButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("設定を開く").fixedSize(horizontal: true, vertical: false)
        }.buttonStyle(.bordered).controlSize(.regular)
    }
}

/// Visible in both tabs, including before their gear is opened.
struct NotionConnectionNotice: View {
    @ObservedObject private var connection: NotionConnectionStore
    let onOpenSettings: () -> Void
    init(connection: NotionConnectionStore = .shared, onOpenSettings: @escaping () -> Void) {
        _connection = ObservedObject(wrappedValue: connection)
        self.onOpenSettings = onOpenSettings
    }
    func openSettings() { onOpenSettings() }
    var body: some View {
        if connection.canReverify {
            HStack(alignment: .top, spacing: 10) {
                if connection.showsConnectionError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("接続エラー")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.bannerTitle).foregroundStyle(.primary)
                    Text(connection.bannerDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("再確認") { Task { await connection.verifySaved() } }
                    .disabled(connection.isChecking)
                Button("設定を開く", action: openSettings)
            }.padding(12)
        }
    }
}

/// The complete task settings page is shared by pinned settings and the tab gear.
@MainActor struct NotionTasksSettingsPage: View {
    var onOpenSettings: () -> Void = {}
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var connection = NotionConnectionStore.shared
    init(onOpenSettings: @escaping () -> Void = {}, settings: SettingsStore = .shared) {
        self.onOpenSettings = onOpenSettings
        _settings = ObservedObject(wrappedValue: settings)
    }
    var body: some View {
        Form {
            NotionPageDisplaySettings(page: .tasks, settings: settings)
            NotionTabConnectionSettings(onOpenSettings: onOpenSettings)
            NotionTasksSettings(title: "タスク")
                .disabled(!NotionTaskRules.settingsEnabled(state: connection.state))
        }.formStyle(.grouped)
    }
}

struct NotionConnectionLoading: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Notion 接続を確認中…").foregroundStyle(.secondary)
        }.accessibilityLabel("Notion 接続を確認中")
    }
}

/// Shared icon chooser and display controls for all Notion fixed pages.
struct NotionPageDisplaySettings: View {
    enum Page { case agents, tasks, meetings }
    let page: Page
    @ObservedObject var settings: SettingsStore
    var body: some View {
        Section("表示") {
            NotionPageDisplayControls(page: page, settings: settings)
        }
    }
}

/// Reusable controls also fit inside the agent page's existing display section.
struct NotionPageDisplayControls: View {
    let page: NotionPageDisplaySettings.Page
    @ObservedObject var settings: SettingsStore
    @State private var choosingIcon = false
    private var symbol: Binding<String> {
        switch page {
        case .agents: $settings.data.agentsTabSymbol
        case .tasks: $settings.data.tasksTabSymbol
        case .meetings: $settings.data.meetingsTabSymbol
        }
    }
    private var display: Binding<NotionTabDisplay> {
        switch page {
        case .agents: $settings.data.notionTabDisplay
        case .tasks: $settings.data.tasksTabDisplay
        case .meetings: $settings.data.meetingsTabDisplay
        }
    }
    var body: some View {
        Group {
            LabeledContent("アイコン") {
                Button { choosingIcon = true } label: {
                    if symbol.wrappedValue.isEmpty {
                        Image(nsImage: NotionTabIcon.image(for: NSAppearance(named: .darkAqua)!))
                    } else { Image(systemName: symbol.wrappedValue) }
                }.popover(isPresented: $choosingIcon) {
                    VStack {
                        SymbolGrid(selected: symbol.wrappedValue) {
                            symbol.wrappedValue = $0; choosingIcon = false
                        }
                        Button("標準のアイコン") {
                            switch page {
                            case .agents: symbol.wrappedValue = ""
                            case .tasks: symbol.wrappedValue = "checklist"
                            case .meetings: symbol.wrappedValue = "person.2"
                            }
                            choosingIcon = false
                        }
                    }.padding()
                }
            }
            Picker("タブに表示", selection: display) {
                ForEach([NotionTabDisplay.iconOnly, .titleOnly, .iconAndTitle]) { option in
                    Text(option == .iconOnly ? "アイコン" : option == .titleOnly ? "タイトル" : "両方").tag(option)
                }
            }
        }
    }
}
