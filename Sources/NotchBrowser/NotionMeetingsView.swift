import SwiftUI

/// Shared by Settings > fixed pages and the meeting tab's gear.
@MainActor struct NotionMeetingsSettingsPage: View {
    var onOpenSettings: () -> Void = {}
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var connection = NotionConnectionStore.shared
    @ObservedObject private var store = NotionMeetingsStore.shared
    init(onOpenSettings: @escaping () -> Void = {}, settings: SettingsStore = .shared) {
        self.onOpenSettings = onOpenSettings
        _settings = ObservedObject(wrappedValue: settings)
    }
    var body: some View {
        Form {
            NotionPageDisplaySettings(page: .meetings, settings: settings)
            NotionTabConnectionSettings(onOpenSettings: onOpenSettings)
            Group {
                dataSettings
                displaySettings
            }.disabled(!NotionTaskRules.settingsEnabled(state: connection.state))
        }.formStyle(.grouped)
    }
    private var dataSettings: some View {
        Section("データ") {
            HStack(alignment: .firstTextBaseline, spacing: NotionSettingsFieldLayout.spacing) {
                Text("議事録のページ URL").fixedSize(horizontal: true, vertical: false).lineLimit(1)
                TextField("議事録のページ URL", text: $store.fallback, prompt: Text("https://www.notion.so/…"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                    .frame(maxWidth: .infinity).layoutPriority(1)
                    .accessibilityLabel("議事録のページ URL")
                Button { Task { await store.refresh() } } label: {
                    Text("確認").frame(width: NotionSettingsFieldLayout.actionWidth)
                }.buttonStyle(.bordered).controlSize(.regular).fixedSize().disabled(store.refreshing)
            }.frame(minWidth: 0, maxWidth: .infinity)
            Text("空欄のときは、参加した議事録を自動で探します").font(.caption).foregroundStyle(.secondary)
            if let message = store.message { Text(message).foregroundStyle(.red) }
        }
    }
    private var displaySettings: some View {
        Section("一覧") {
            Picker("並び順", selection: $store.newestFirst) {
                Text("新しい順").tag(true)
                Text("古い順").tag(false)
            }.pickerStyle(.menu)
            Picker("最大表示件数", selection: $store.displayLimit) {
                ForEach([10, 25, 50], id: \.self) { Text("\($0)件").tag($0) }
            }.pickerStyle(.menu)
        }
    }

}

@MainActor struct NotionMeetingsPanel: View {
    var onOpenSettings: () -> Void = {}
    @ObservedObject private var connection = NotionConnectionStore.shared
    @ObservedObject private var store = NotionMeetingsStore.shared
    @State private var showingSettings = false
    @State private var selected: NotionMeeting?
    var body: some View {
        VStack(spacing: 0) {
            NotionConnectionNotice(onOpenSettings: onOpenSettings)
            if showingSettings && !connection.showsConnectionError {
                HStack { Button("‹ 戻る") { showingSettings = false }; Spacer() }.padding(12)
            }
            panelContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            #if DEBUG
            showingSettings = store.mockState == "settings"
            if ["detail", "progress", "empty-tabs"].contains(store.mockState ?? "") { selected = store.meetings.first }
            #endif
            if connection.tokenValid { await store.refresh() }
        }
        .task(id: connection.state) {
            if connection.tokenValid { await store.refresh() } else { selected = nil }
        }
        .onChange(of: store.meetings) { _, meetings in
            if let id = selected?.id { selected = meetings.first { $0.id == id } }
        }
    }
    @ViewBuilder private var panelContent: some View {
        if connection.showsConnectionError {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showingSettings {
            NotionMeetingsSettingsPage(onOpenSettings: onOpenSettings)
        } else if connection.showsLoading {
            NotionConnectionLoading().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            splitContent
        }
    }

    private var splitContent: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                list.frame(width: (geometry.size.width - 1) / 2)
                Divider()
                Group {
                    if let selected {
                        NotionMeetingDetail(meeting: selected)
                            .id(detailIdentity(selected))
                    } else { Text("議事録を選ぶと内容が表示されます").foregroundStyle(.tertiary) }
                }.frame(width: (geometry.size.width - 1) / 2, height: geometry.size.height)
            }
        }
    }

    private func detailIdentity(_ meeting: NotionMeeting) -> String {
        let parts: [String] = [meeting.id, meeting.status, meeting.summary ?? "", meeting.notes ?? "", meeting.transcript ?? ""]
        return parts.joined()
    }

    private var days: [Date] {
        let days = Array(Set(store.displayedMeetings.map { Calendar.current.startOfDay(for: $0.start) }))
        return days.sorted { store.newestFirst ? $0 > $1 : $0 < $1 }
    }
    private var list: some View {
        VStack(spacing: 0) {
            NotionTabListHeader(refreshing: store.refreshing,
                               onRefresh: { if connection.tokenValid { Task { await store.refresh() } } },
                               onSettings: { showingSettings = true }, settingsLabel: "議事録設定") { Spacer() }
            if let message = store.message { Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            if store.refreshing { ProgressView().padding() }
            if store.displayedMeetings.isEmpty {
                Spacer()
                Text("議事録はありません").foregroundStyle(.secondary)
                Button("議事録のページを指定") { showingSettings = true }.buttonStyle(.bordered).padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            dayGroup(day)
                        }
                    }
                }
            }
        }
    }
    @ViewBuilder private func dayGroup(_ day: Date) -> some View {
        Text(day == Calendar.current.startOfDay(for: .distantPast) ? "日時なし" : NotionMeetingDateLabels.day(day))
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 5)
        ForEach(store.displayedMeetings.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }) { meeting in
            meetingRow(meeting)
            Divider()
        }
    }

    private func meetingRow(_ meeting: NotionMeeting) -> some View {
        Button { selected = meeting } label: {
            HStack(spacing: 8) {
                Text(meeting.title).font(.body).foregroundStyle(.primary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(meeting.rowMetadata()).monospacedDigit()
                NotionMeetingStatusChip(meeting: meeting)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 36)
                .background(selected?.id == meeting.id ? Color.accentColor.opacity(0.12) : .clear)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .contextMenu { Link("Notion で開く", destination: meeting.url) }
    }

}

private struct NotionMeetingStatusChip: View {
    let meeting: NotionMeeting
    var body: some View {
        if let label = meeting.label {
            let color: Color = meeting.status == "failed" ? .red : .secondary
            Text(label).font(.system(size: 10)).lineLimit(1)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .foregroundStyle(color)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

@MainActor private struct NotionMeetingDetail: View {
    let meeting: NotionMeeting
    @ObservedObject private var store = NotionMeetingsStore.shared
    @State private var bodies: [String: [NotionTaskBlock]] = [:]
    @State private var selection = ""
    @State private var loading = true
    @State private var error: String?
    private var sections: [(String, String)] {
        [("要約", meeting.summary ?? "summary"), ("メモ", meeting.notes ?? "notes"),
         ("文字起こし", meeting.transcript ?? "transcript")]
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(meeting.title).font(.title2.weight(.semibold))
                    Text(meeting.detailMetadata()).lineLimit(1).foregroundStyle(.secondary)
                    Link("Notion で開く", destination: meeting.url)
                    if meeting.progressing {
                        NotionMeetingStatusChip(meeting: meeting)
                        Text("Notion で作成中です。しばらくしてから更新してください").foregroundStyle(.secondary)
                    } else if meeting.status == "failed" { NotionMeetingStatusChip(meeting: meeting) }
                    detailContent(emptyHeight: max(160, geometry.size.height - 230))
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.contextMenu { Link("Notion で開く", destination: meeting.url) }
        }
        .task { await load() }
    }
    @ViewBuilder private func detailContent(emptyHeight: CGFloat) -> some View {
        Divider()
        Picker("本文", selection: $selection) {
            ForEach(sections, id: \.1) { Text($0.0).tag($0.1) }
        }.pickerStyle(.segmented).labelsHidden()
        if loading { ProgressView() }
        else if (bodies[selection] ?? []).isEmpty {
            VStack(spacing: 12) {
                Spacer(minLength: 40)
                Text("この議事録には\(sections.first { $0.1 == selection }?.0 ?? "要約")がありません")
                    .foregroundStyle(.secondary)
                Link("Notion で開く", destination: meeting.url)
                Spacer(minLength: 40)
            }.frame(maxWidth: .infinity, minHeight: emptyHeight)
        } else {
            NotionMeetingBodyView(blocks: bodies[selection] ?? [], pageURL: meeting.url,
                                  transcript: selection == sections[2].1)
        }
        if let error {
            Text(error).font(.caption).foregroundStyle(.secondary)
            Button("再試行") { Task { await load() } }
        }
    }

    private func load() async {
        loading = true; error = nil; bodies = [:]
        selection = sections[0].1
        #if DEBUG
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--meeting-section=") }),
           let index = ["summary", "notes", "transcript"].firstIndex(of: String(argument.dropFirst(18))) {
            selection = sections[index].1
        }
        #endif
        defer { loading = false }
        guard !meeting.progressing else { return }
        for (_, id) in meeting.sections {
            do { bodies[id] = try await store.blocks(id) }
            catch {
                // One inaccessible section must not hide the other sections.
                bodies[id] = []
                if id != meeting.transcript { self.error = error.localizedDescription }
            }
        }
    }
}

struct NotionMeetingBodyView: View {
    let blocks: [NotionTaskBlock]
    let pageURL: URL
    var transcript = false
    @State private var expanded: Set<String> = []
    private var visible: [NotionTaskBlock] {
        var hiddenDepth: Int?
        return blocks.filter { block in
            if let depth = hiddenDepth {
                if block.depth > depth { return false }
                hiddenDepth = nil
            }
            if (block.type == "toggle" && !expanded.contains(block.id)) || block.type == "table" { hiddenDepth = block.depth }
            return true
        }
    }
    var body: some View {
        ForEach(visible) { block in
            if ["table", "image", "table_row"].contains(block.type) {
                Link("Notion で表示", destination: blockURL(block))
                    .foregroundStyle(.secondary).padding(.leading, CGFloat(block.depth) * 16)
            } else if block.type == "toggle" {
                Button {
                    if !expanded.insert(block.id).inserted { expanded.remove(block.id) }
                } label: {
                    HStack { Text(expanded.contains(block.id) ? "▾" : "▸"); Text(block.text) }
                }.buttonStyle(.plain).padding(.leading, CGFloat(block.depth) * 16)
            } else if block.type == "divider" { Divider() }
            else if block.type == "quote" {
                HStack(alignment: .top) {
                    Rectangle().fill(Color.secondary).frame(width: 3)
                    NotionTaskBlockView(block: block)
                }.fixedSize(horizontal: false, vertical: true)
            } else if transcript, let speech = block.speaker.map({ NotionMeetingSpeech(speaker: $0, time: block.timestamp, text: block.text) }) ?? NotionMeetingSpeech.parse(block.text) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(speech.speaker).bold()
                        if let time = speech.time { Text(time).foregroundStyle(.secondary) }
                    }
                    Text(speech.text).textSelection(.enabled)
                }.font(.body)
            } else { NotionTaskBlockView(block: block) }
        }
    }
    private func blockURL(_ block: NotionTaskBlock) -> URL {
        URL(string: pageURL.absoluteString + "#" + block.id.replacingOccurrences(of: "-", with: ""))!
    }
}

struct NotionMeetingSpeech: Equatable {
    let speaker: String
    let time: String?
    let text: String
    static func parse(_ text: String) -> Self? {
        // Notion text exports can prefix a speaker with an elapsed timestamp.
        let pieces = text.split(separator: "：", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { return nil }
        let header = pieces[0].split(separator: " ", maxSplits: 1).map(String.init)
        let timed = header.count == 2 && header[0].contains(":")
        return .init(speaker: timed ? header[1] : pieces[0], time: timed ? header[0] : nil, text: pieces[1])
    }
}
