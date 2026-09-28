import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchBrowser 設定"
        window.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(SettingsStore.shared))
        window.setContentSize(NSSize(width: 680, height: 500))
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            PinnedTabsSettings().tabItem { Label("固定タブ", systemImage: "square.stack") }
            ProfilesSettings().tabItem { Label("プロファイル", systemImage: "person.2") }
            DisplaysSettings().tabItem { Label("ディスプレイ", systemImage: "display") }
            GeneralSettings().tabItem { Label("一般", systemImage: "gearshape") }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }
}

// MARK: - Pinned tabs

struct PinnedTabsSettings: View {
    @EnvironmentObject var store: SettingsStore
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.data.pinnedTabs) { tab in
                        HStack(spacing: 8) {
                            Image(nsImage: TabIconRenderer.image(for: tab.icon, hosts: [tab.host]))
                            Text(tab.name)
                            Spacer()
                            if tab.iconOnly {
                                Image(systemName: "eye.slash").foregroundStyle(.secondary).help("アイコンのみ")
                            }
                        }
                        .tag(tab.id)
                    }
                    .onMove { store.data.pinnedTabs.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    Button { remove() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

            Group {
                if let id = selection, let binding = binding(for: id) {
                    PinnedTabEditor(tab: binding)
                } else {
                    Text("タブを選択するか、＋で追加してください")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360)
        }
        .onAppear { selection = selection ?? store.data.pinnedTabs.first?.id }
    }

    private func binding(for id: UUID) -> Binding<PinnedTab>? {
        guard store.data.pinnedTabs.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { store.pinnedTab(id) ?? PinnedTab(name: "", url: "") },
            set: { newValue in store.updatePinnedTab(id) { $0 = newValue } }
        )
    }

    private func add() {
        let tab = PinnedTab(name: "新しいタブ", url: "https://")
        store.data.pinnedTabs.append(tab)
        selection = tab.id
    }

    private func remove() {
        guard let id = selection else { return }
        store.data.pinnedTabs.removeAll { $0.id == id }
        selection = store.data.pinnedTabs.first?.id
    }
}

struct PinnedTabEditor: View {
    @EnvironmentObject var store: SettingsStore
    @Binding var tab: PinnedTab

    private enum IconKind: String, CaseIterable, Identifiable {
        case favicon = "サイトのアイコン", symbol = "シンボル", emoji = "絵文字", image = "画像"
        var id: Self { self }
    }

    private var iconKind: Binding<IconKind> {
        Binding(
            get: {
                switch tab.icon {
                case .favicon: .favicon
                case .symbol: .symbol
                case .emoji: .emoji
                case .image: .image
                }
            },
            set: { kind in
                switch kind {
                case .favicon: tab.icon = .favicon
                case .symbol: tab.icon = .symbol("star")
                case .emoji: tab.icon = .emoji("⭐️")
                case .image: chooseImage()
                }
            }
        )
    }

    var body: some View {
        Form {
            TextField("名前", text: $tab.name)
            TextField("URL", text: $tab.url)
            Picker("プロファイル", selection: $tab.profileID) {
                ForEach(store.data.profiles) { Text($0.name).tag($0.id) }
            }
            Toggle("タブにアイコンのみ表示", isOn: $tab.iconOnly)

            Section("アイコン") {
                Picker("種類", selection: iconKind) {
                    ForEach(IconKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch tab.icon {
                case .favicon:
                    LabeledContent("プレビュー") {
                        Image(nsImage: TabIconRenderer.image(for: .favicon, hosts: [tab.host], size: 24))
                    }
                    Text("一度開くとサイトのアイコンが取得されます").font(.caption).foregroundStyle(.secondary)
                case .symbol(let current):
                    SymbolGrid(selected: current) { tab.icon = .symbol($0) }
                case .emoji(let current):
                    TextField("絵文字", text: Binding(
                        get: { current },
                        set: { tab.icon = .emoji(String($0.prefix(2))) }
                    ))
                    Text("⌃⌘Space で絵文字ピッカーを開けます").font(.caption).foregroundStyle(.secondary)
                case .image:
                    HStack {
                        Image(nsImage: TabIconRenderer.image(for: tab.icon, hosts: [], size: 32))
                        Button("画像を選択…") { chooseImage() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let fileName = IconStore.importImage(from: url) else { return }
        tab.icon = .image(fileName)
    }
}

struct SymbolGrid: View {
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30)), count: 8), spacing: 6) {
            ForEach(TabIconRenderer.presetSymbols, id: \.self) { name in
                Button { onSelect(name) } label: {
                    Image(systemName: name)
                        .frame(width: 28, height: 28)
                        .background(name == selected ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(name)
            }
        }
    }
}

// MARK: - Profiles

struct ProfilesSettings: View {
    @EnvironmentObject var store: SettingsStore
    @State private var confirmDelete: Profile?
    @State private var confirmClear: Profile?

    var body: some View {
        Form {
            Section {
                ForEach($store.data.profiles) { $profile in
                    HStack {
                        Image(systemName: profile.isDefault ? "person.crop.circle.fill" : "person.crop.circle")
                        TextField("名前", text: $profile.name).labelsHidden()
                        Text("\(usage(of: profile.id)) タブ").foregroundStyle(.secondary).font(.caption)
                        Menu {
                            Button("ログイン情報を消去…") { confirmClear = profile }
                            if !profile.isDefault {
                                Button("削除…", role: .destructive) { confirmDelete = profile }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                    }
                }
                Button("プロファイルを追加") {
                    store.data.profiles.append(Profile(id: UUID(), name: "プロファイル \(store.data.profiles.count + 1)"))
                }
            } header: {
                Text("プロファイル")
            } footer: {
                Text("Cookie とログイン状態はプロファイルごとに分かれます。同じプロファイルのタブ同士はログインを共有します。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("新規タブのプロファイル", selection: $store.data.newTabProfileID) {
                    ForEach(store.data.profiles) { Text($0.name).tag($0.id) }
                }
            } footer: {
                Text("リンクから開いたタブは、元のタブのプロファイルを引き継ぎます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("「\(confirmDelete?.name ?? "")」を削除しますか？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("削除", role: .destructive) { if let p = confirmDelete { store.deleteProfile(p.id) } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このプロファイルのログイン情報も削除されます。使っていた固定タブはデフォルトに戻ります。")
        }
        .alert("「\(confirmClear?.name ?? "")」のログイン情報を消去しますか？", isPresented: Binding(get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } })) {
            Button("消去", role: .destructive) { if let p = confirmClear { ProfileDataStores.clearData(for: p.id) } }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func usage(of id: UUID) -> Int {
        store.data.pinnedTabs.filter { $0.profileID == id }.count
    }
}

// MARK: - Displays

struct DisplaysSettings: View {
    @EnvironmentObject var store: SettingsStore
    @State private var screens = NSScreen.screens

    var body: some View {
        Form {
            ForEach(screens, id: \.displayUUID) { screen in
                DisplayRow(screen: screen)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }
}

struct DisplayRow: View {
    @EnvironmentObject var store: SettingsStore
    let screen: NSScreen

    private var settings: Binding<DisplaySettings> {
        Binding(
            get: { store.displaySettings(for: screen) },
            set: { store.setDisplaySettings($0, for: screen) }
        )
    }

    var body: some View {
        Section {
            Toggle("このディスプレイに表示", isOn: settings.enabled)
            if settings.wrappedValue.enabled {
                LabeledContent("待機時の不透明度") {
                    HStack {
                        Slider(value: settings.idleOpacity, in: 0...1)
                        Text("\(Int(settings.wrappedValue.idleOpacity * 100))%")
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("開いたときの幅") {
                    HStack {
                        Slider(value: settings.width, in: 600...max(601, screen.frame.width - 40), step: 10)
                        Text("\(Int(settings.wrappedValue.width))").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("開いたときの高さ") {
                    HStack {
                        Slider(value: settings.height, in: 400...max(401, screen.frame.height - 40), step: 10)
                        Text("\(Int(settings.wrappedValue.height))").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
        } header: {
            HStack {
                Text(screen.localizedName)
                if screen.hasNotch { Text("ノッチあり").font(.caption).foregroundStyle(.secondary) }
                if screen == NSScreen.screens.first { Text("メイン").font(.caption).foregroundStyle(.secondary) }
            }
        } footer: {
            if !screen.hasNotch, settings.wrappedValue.enabled {
                Text("ノッチがないディスプレイでは、画面上端の中央に表示されます。0% にすると見えなくなりますが、カーソルを乗せれば開けます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("ノッチを開いたときのタブ", selection: $store.data.openTabBehavior) {
                    Text("前回見ていたタブ").tag(OpenTabBehavior.lastViewed)
                    if !store.data.pinnedTabs.isEmpty {
                        Divider()
                        ForEach(store.data.pinnedTabs) { tab in
                            Text(tab.name).tag(OpenTabBehavior.pinned(tab.id))
                        }
                    }
                }
                Toggle("アイコンをグレースケールで表示", isOn: $store.data.grayscaleIcons)
                Toggle("選択中のタブはカラーで表示", isOn: $store.data.colorSelectedIcon)
                    .disabled(!store.data.grayscaleIcons)
            } header: {
                Text("タブ")
            } footer: {
                Text("タブはノッチ上でドラッグして並べ替えられます（固定タブと通常タブはそれぞれのグループ内で移動します）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("次の予定") {
                Toggle("次の予定までの分数をノッチに表示", isOn: $store.data.countdownEnabled)
                Stepper(value: $store.data.countdownMinutes, in: 5...120, step: 5) {
                    LabeledContent("表示し始めるタイミング", value: "\(store.data.countdownMinutes) 分前から")
                }
                .disabled(!store.data.countdownEnabled)
                Text("Mac の「カレンダー」アプリの予定を使うため、オンのときだけカレンダーへのアクセスを求めます。タブで開くカレンダーのサイトとは別です。Google カレンダーは システム設定 › インターネットアカウント で追加できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("画面共有・スクリーンショットに表示しない", isOn: $store.data.hideFromScreenCapture)
            } header: {
                Text("プライバシー")
            } footer: {
                Text("Zoom や Google Meet などで画面を共有しているとき、ノッチのブラウザは相手に映りません。一部の録画・共有アプリでは効かない場合があります。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NotchBrowser を終了")
                        Text("メニューバーのアイコン、ノッチの右クリック、ブラウザ右上の電源ボタンからも終了できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("終了") { NSApp.terminate(nil) }
                }
            }

            Section("ショートカット") {
                LabeledContent("開く / 閉じる", value: "⌃⌥N")
                LabeledContent("設定", value: "⌘,")
            }
        }
        .formStyle(.grouped)
    }
}
