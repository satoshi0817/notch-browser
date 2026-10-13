import SwiftUI

enum NotionSettingsFieldLayout {
    static let labelWidth: CGFloat = 200
    static let actionWidth: CGFloat = 56
    static let spacing: CGFloat = 8
}

@MainActor struct NotionTasksSettings: View {
    @ObservedObject private var store = NotionTasksStore.shared
    @ObservedObject private var connection = NotionConnectionStore.shared
    private var checklist: NotionTaskRules.Checklist {
        NotionTaskRules.checklist(tokenValid: connection.tokenValid, checking: connection.isChecking,
                                 url: store.configuration.url, confirmedURL: store.configuration.confirmedURL)
    }
    var body: some View {
        Section("タスク") {
            VStack(alignment: .leading, spacing: 4) {
                checklistItem("Notion にログイン", complete: checklist.loggedIn)
                checklistItem("データベースの URL", complete: checklist.databaseURL)
                Text(checklist.hint).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: NotionSettingsFieldLayout.spacing) {
                    Text("データベースの URL")
                        .frame(width: NotionSettingsFieldLayout.labelWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                TextField("データベースの URL", text: $store.configuration.url,
                          prompt: Text("https://www.notion.so/…").foregroundStyle(.secondary))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("データベースの URL")
                    .onChange(of: store.configuration.url) { _, _ in
                        store.verified = false; store.sources = []; store.configuration.source = nil
                        store.configuration.mapping = NotionTaskMapping()
                        store.tasks = []; store.message = nil
                    }
                if store.verified {
                    Text("✓ \(store.name)（\(store.tasks.count)件）").font(.caption).foregroundStyle(.green)
                }
                if let message = store.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                    if let url = NotionTaskRules.errorLink(message, url: store.configuration.url) {
                        Link("Notion で開く", destination: url).font(.caption)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                }
                .frame(maxWidth: .infinity)
                Button("確認") { Task { await store.configure() } }
                    .frame(width: NotionSettingsFieldLayout.actionWidth)
                    .disabled(!NotionTaskRules.canConfirm(url: store.configuration.url, checking: store.checking || store.refreshing))
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
                mappingPicker("担当者", type: "people", selection: $store.configuration.mapping.assignee)
                if store.canShowPeople {
                    Picker("自分の担当者名", selection: $store.configuration.viewerID) {
                        Text("選択してください").tag(Optional<String>.none)
                        ForEach(store.people) {
                            Text($0.name).tag(Optional($0.id))
                        }
                    }
                    Text("内部インテグレーションでは利用者を判別できないため、自分の名前を選択してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("適用して更新") { Task { await store.refresh() } }
            }
        }
        .task { if store.available { await store.configure() } }
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
    var openingID = UUID()
    @ObservedObject private var store = NotionTasksStore.shared
    @State private var selected: NotionTask?
    private var effectiveFilter: NotionTaskFilter {
        store.filter == .mine && !store.canShowPeople ? .incomplete : store.filter
    }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 640 {
                    list.frame(width: (geometry.size.width - 1) / 2)
                    Divider()
                    Group {
                        if let selected { detail(selected, narrow: false) }
                        else { Text("タスクを選ぶと詳細が表示されます").foregroundStyle(.tertiary) }
                    }.frame(width: (geometry.size.width - 1) / 2, height: geometry.size.height)
                } else if let selected {
                    detail(selected, narrow: true).frame(maxWidth: .infinity)
                } else {
                    list.frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: openingID) {
            #if DEBUG
            if ["detail", "loading", "no-body"].contains(store.mockState ?? "") { selected = store.tasks.first }
            #endif
            await store.refresh()
        }
        .onChange(of: store.configuration.source) { _, _ in selected = nil }
        .onChange(of: store.tasks) { _, tasks in
            if let id = selected?.id { selected = tasks.first { $0.id == id } }
        }
    }
    private func detail(_ task: NotionTask, narrow: Bool) -> some View {
        NotionTaskDetail(task: task, back: { selected = nil }, narrow: narrow)
            .id("\(task.id)-\(openingID)")
    }
    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("表示", selection: Binding(get: { effectiveFilter }, set: { store.filter = $0 })) {
                    ForEach(NotionTaskFilter.allCases.filter { $0 != .mine || store.canShowPeople }, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }.pickerStyle(.segmented)
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.refreshing).help("更新")
            }.padding()
            if let message = store.message { Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            let rows = NotionTaskRules.rows(store.tasks, filter: effectiveFilter, userID: store.configuration.viewerID)
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
                                    Button { selected = task } label: { row(task) }.buttonStyle(.plain)
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
        if effectiveFilter == .mine && store.configuration.viewerID == nil { return "設定の「プロパティの設定」で自分の担当者名を選択してください" }
        return effectiveFilter == .incomplete ? "未完了のタスクはありません" : "タスクはありません"
    }
    private func row(_ task: NotionTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").foregroundStyle(task.completed ? .green : .secondary)
            Text(task.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if store.canShowPeople {
                HStack(spacing: -6) {
                    ForEach(Array(task.people.prefix(2))) { person in
                        NotionTaskAvatar(person: person).help(person.name)
                    }
                }.frame(width: 38, alignment: .trailing)
            }
            Text(task.due.map { NotionTaskRules.dateLabel($0) } ?? "").font(.caption).monospacedDigit()
                .foregroundStyle(NotionTaskRules.group(task, now: Date(), calendar: .current) == .overdue ? Color.orange : Color.secondary)
                .frame(width: 46, alignment: .trailing)
            Text(task.status).font(.system(size: 10)).lineLimit(1).padding(4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 64, alignment: .trailing)
        }.padding(.horizontal, 12).frame(height: 36)
            .background(selected?.id == task.id ? Color.accentColor.opacity(0.12) : .clear)
    }
}
private struct NotionTaskAvatar: View {
    let person: NotionTaskPerson
    var body: some View {
        Group {
            if let url = person.avatar {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { initials }
            } else { initials }
        }.frame(width: 22, height: 22).clipShape(Circle())
    }
    private var initials: some View { Text(String(person.name.prefix(1))).font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.accentColor.opacity(0.15)) }
}
@MainActor private struct NotionTaskDetail: View {
    let task: NotionTask
    let back: () -> Void
    let narrow: Bool
    @State private var blocks: [NotionTaskBlock] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if narrow { Button("‹ 一覧", action: back).buttonStyle(.plain) }
                Text(task.title).font(.title2.weight(.semibold))
                if let url = task.url { Link("Notion で開く", destination: url) }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow { Text("状態").foregroundStyle(.secondary); Text(task.status) }
                    GridRow { Text("期日").foregroundStyle(.secondary); Text(task.due.map { NotionTaskRules.dateLabel($0) } ?? "—") }
                    if NotionTasksStore.shared.canShowPeople {
                        GridRow { Text("担当者").foregroundStyle(.secondary); Text(task.people.map(\.name).joined(separator: ", ")) }
                    }
                }
                Divider()
                if loading {
                    ForEach(0..<5) { index in RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)).frame(height: index == 0 ? 24 : 14) }
                } else if let error { Text(error).foregroundStyle(.red) }
                else if blocks.isEmpty { Text("本文はありません").foregroundStyle(.tertiary) }
                else { ForEach(blocks) { block in NotionTaskBlockView(block: block) } }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.task {
            loading = true
            do { blocks = try await NotionTasksStore.shared.blocks(for: task.id) }
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
