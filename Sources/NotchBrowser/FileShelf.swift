import AppKit
import Combine
import SwiftUI
import Quartz
import QuickLookThumbnailing

enum ShelfTrigger: String, Codable, CaseIterable {
    case automatic, nearby, manual
    var title: String {
        switch self { case .automatic: "ドラッグ開始"; case .nearby: "ノッチに接近"; case .manual: "手動" }
    }
}

struct ShelfEntry: Codable, Identifiable {
    var id = UUID()
    var url: URL
    var bookmark: Data?
    var pinned = false

    mutating func resolve() {
        guard let bookmark else { return }
        var stale = false
        if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) {
            url = resolved
            if stale { self.bookmark = try? resolved.bookmarkData(options: .minimalBookmark) }
        }
    }
}

/// Stores references only. Removing a shelf entry never removes its file.
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore(file: AppSupport.directory("Shelf").appendingPathComponent("items.json"))
    @Published private(set) var entries: [ShelfEntry] = []
    @Published private(set) var error: String?
    private let file: URL

    init(file: URL) {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                entries = try JSONDecoder().decode([ShelfEntry].self, from: Data(contentsOf: file))
                for i in entries.indices { entries[i].resolve() }
            } catch { self.error = "棚の保存データを読み込めませんでした。" }
        }
    }

    @discardableResult func add(_ urls: [URL]) -> Bool {
        var next = entries
        for url in urls where url.isFileURL {
            let url = url.standardizedFileURL
            guard !next.contains(where: { $0.url.standardizedFileURL == url }) else { continue }
            next.append(ShelfEntry(url: url, bookmark: try? url.bookmarkData(options: .minimalBookmark)))
        }
        guard next.count != entries.count else { return !urls.isEmpty && urls.allSatisfy(\.isFileURL) }
        return save(next)
    }

    func remove(_ ids: Set<UUID>) { _ = save(entries.filter { !ids.contains($0.id) }) }
    func clearUnpinned() { _ = save(entries.filter(\.pinned)) }
    func togglePin(_ ids: Set<UUID>) {
        let pin = entries.filter { ids.contains($0.id) }.contains { !$0.pinned }
        _ = save(entries.map { entry in var entry = entry; if ids.contains(entry.id) { entry.pinned = pin }; return entry })
    }

    private func save(_ next: [ShelfEntry]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            entries = next
            error = nil
            return true
        } catch {
            self.error = "棚を保存できませんでした。ファイルは変更していません。"
            return false
        }
    }
}

/// A new drag pasteboard generation plus a pressed button identifies a fresh session.
/// A stale pasteboard must never open the shelf on the next ordinary mouse click.
struct ShelfDragState {
    private var generation: Int
    private(set) var active = false
    init(generation: Int) { self.generation = generation }
    mutating func update(generation: Int, pressed: Bool, hasFiles: Bool, cancelled: Bool = false) -> Bool {
        if !pressed || cancelled {
            active = false
            self.generation = generation
        } else if generation != self.generation {
            active = hasFiles
            if hasFiles { self.generation = generation }
        }
        return active
    }
}

final class ShelfDragMonitor {
    static let originType = NSPasteboard.PasteboardType("com.satoshi0817.NotchBrowser.shelf-drag")
    private let pasteboard = NSPasteboard(name: .drag)
    private var state: ShelfDragState
    private var timer: Timer?
    var onChange: ((Bool) -> Void)?
    private(set) var active = false

    init() { state = ShelfDragState(generation: NSPasteboard(name: .drag).changeCount) }
    deinit { timer?.invalidate() }
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func poll() {
        let next = state.update(generation: pasteboard.changeCount,
                                pressed: NSEvent.pressedMouseButtons & 1 != 0,
                                hasFiles: pasteboard.availableType(from: [.fileURL]) != nil,
                                cancelled: CGEventSource.keyState(.combinedSessionState, key: 53))
        active = next
        // Notify while active too, to follow the drag across enabled displays.
        onChange?(next)
    }
}

final class ShelfTable: NSTableView {
    var preview: (() -> Void)?
    var remove: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { preview?() }
        else if event.keyCode == 51 { remove?() }
        else { super.keyDown(with: event) }
    }
}

final class ShelfViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource {
    let store: ShelfStore
    let table = ShelfTable()
    var onClose: (() -> Void)?
    var onDrop: (() -> Void)?
    var onDrag: ((Bool) -> Void)?
    private let message = NSTextField(labelWithString: "")
    private var cancellables: Set<AnyCancellable> = []
    private var previewURLs: [URL] = []
    private var buttons: [NSButton] = []
    private var displayed: [ShelfEntry] = []

    init(store: ShelfStore = .shared) { self.store = store; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let glass = GlassSurface()
        view = glass
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: glass.content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: glass.content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: glass.content.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: glass.content.bottomAnchor, constant: -10)
        ])
        let header = NSStackView()
        let title = NSTextField(labelWithString: "ファイル棚")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        header.addArrangedSubview(title)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)
        for (label, symbol, action) in [
            ("クリップボードから追加", "plus", #selector(pasteFiles)),
            ("選択したファイルをコピー", "doc.on.doc", #selector(copyFiles)),
            ("プレビュー", "eye", #selector(previewFiles)),
            ("ピン留めを切り替え", "pin", #selector(pinFiles)),
            ("Finderで表示", "folder", #selector(revealFiles)),
            ("棚から外す（元ファイルは保持）", "minus.circle", #selector(removeFiles)),
            ("ピン留め以外を棚から外す", "tray", #selector(clearFiles)),
            ("棚を閉じる", "xmark", #selector(closeShelf))
        ] {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
            button.bezelStyle = .inline
            button.isBordered = false
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            header.addArrangedSubview(button)
            buttons.append(button)
        }
        stack.addArrangedSubview(header)
        let column = NSTableColumn(identifier: .init("file"))
        column.title = "ファイル"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.preview = { [weak self] in self?.previewFiles() }
        table.remove = { [weak self] in self?.removeFiles() }
        table.target = self; table.doubleAction = #selector(previewFiles)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.addArrangedSubview(scroll)
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(message)
        for item in [header, scroll, message] as [NSView] {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        store.$entries.combineLatest(store.$error).receive(on: RunLoop.main).sink { [weak self] _, _ in self?.refresh() }.store(in: &cancellables)
        refresh()
    }

    private var selection: [ShelfEntry] { table.selectedRowIndexes.compactMap { displayed.indices.contains($0) ? displayed[$0] : nil } }
    private func refresh() {
        let ids = Set(selection.map(\.id))
        displayed = store.entries
        table.reloadData()
        table.selectRowIndexes(IndexSet(displayed.indices.filter { ids.contains(displayed[$0].id) }), byExtendingSelection: false)
        message.stringValue = store.error ?? (displayed.isEmpty ? "ファイルをここにドロップ" : "\(displayed.count)項目 · 選択してドラッグ / Spaceでプレビュー")
        updateButtons()
    }
    private func updateButtons() {
        for index in 1...5 { buttons[index].isEnabled = !selection.isEmpty }
        buttons[6].isEnabled = displayed.contains { !$0.pinned }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = displayed[row]
        let exists = FileManager.default.fileExists(atPath: entry.url.path)
        let cell = NSStackView()
        cell.spacing = 8
        // File previews are content, while all operation icons use SF Symbols.
        let image = NSImageView(image: NSImage(systemSymbolName: entry.pinned ? "pin.fill" : (entry.url.hasDirectoryPath ? "folder" : "doc"), accessibilityDescription: nil)!)
        image.widthAnchor.constraint(equalToConstant: 24).isActive = true
        image.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let label = NSTextField(labelWithString: entry.url.lastPathComponent + (exists ? "" : "（見つかりません）"))
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = exists ? .labelColor : .secondaryLabelColor
        cell.addArrangedSubview(image); cell.addArrangedSubview(label)
        cell.toolTip = entry.url.path
        if exists && !entry.pinned {
            let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: NSSize(width: 24, height: 24), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak image] result, _ in
                if let result { DispatchQueue.main.async { image?.image = result.nsImage } }
            }
        }
        return cell
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let url = displayed[row].url
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString("1", forType: ShelfDragMonitor.originType)
        return item
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) { onDrag?(true) }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onDrag?(false) }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView !== table, info.draggingSourceOperationMask.contains(.copy),
              !Self.urls(from: info.draggingPasteboard).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let result = store.add(Self.urls(from: info.draggingPasteboard))
        if result { onDrop?() }
        return result
    }
    static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    @objc private func pasteFiles() { _ = store.add(Self.urls(from: .general)) }
    @objc private func copyFiles() {
        let urls = selection.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }
    @objc private func pinFiles() { store.togglePin(Set(selection.map(\.id))) }
    @objc private func removeFiles() { store.remove(Set(selection.map(\.id))) }
    @objc private func clearFiles() { store.clearUnpinned() }
    @objc private func revealFiles() { NSWorkspace.shared.activateFileViewerSelecting(selection.map(\.url)) }
    @objc private func closeShelf() { onClose?() }
    @objc private func previewFiles() {
        previewURLs = selection.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !previewURLs.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.sharingType = SettingsStore.shared.data.hideFromScreenCapture ? .none : .readOnly
        panel.reloadData(); panel.makeKeyAndOrderFront(nil)
        // Quick Look resets its window level when it is first shown.
        panel.level = NSWindow.Level(rawValue: NotchController.level.rawValue + 1)
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible else { return }
            panel.level = NSWindow.Level(rawValue: NotchController.level.rawValue + 1)
        }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs[index] as NSURL }
}

struct ShelfSettingsView: View {
    @EnvironmentObject var store: SettingsStore
    var body: some View {
        Form {
            Section("棚を開くタイミング") {
                HStack(spacing: 12) {
                    ForEach(ShelfTrigger.allCases, id: \.self) { trigger in
                        PresetCard(title: trigger.title,
                                   subtitle: trigger == .automatic ? "ファイルを持ち上げると表示" : trigger == .nearby ? "画面上部に近づけると表示" : "メニューから開く",
                                   symbol: trigger == .automatic ? "cursorarrow.motionlines" : trigger == .nearby ? "rectangle.topthird.inset.filled" : "hand.point.up",
                                   selected: store.data.shelfTrigger == trigger) { store.data.shelfTrigger = trigger }
                    }
                }
            }
            Section {
                Toggle("完了したダウンロードを棚に追加", isOn: $store.data.shelfDownloads)
                Text("棚から外しても元のファイルは削除されません。ファイルとフォルダを追加できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
