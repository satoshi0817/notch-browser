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
    var groupID: UUID?

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
    @Published private(set) var lastRemoved: [ShelfEntry] = []
    private let file: URL
    private var removalOrder: [UUID] = []

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
        let incoming = Set(urls.filter(\.isFileURL).map(\.standardizedFileURL))
        for url in urls where url.isFileURL {
            let url = url.standardizedFileURL
            guard !next.contains(where: { $0.url.standardizedFileURL == url }) else { continue }
            next.append(ShelfEntry(url: url, bookmark: try? url.bookmarkData(options: .minimalBookmark)))
        }
        guard !incoming.isEmpty else { return false }
        if incoming.count > 1 {
            let group = UUID()
            for index in next.indices where incoming.contains(next[index].url.standardizedFileURL) { next[index].groupID = group }
        } else if next.count == entries.count { return true }
        return save(next)
    }

    func remove(_ ids: Set<UUID>) {
        let removed = entries.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        let order = entries.map(\.id)
        if save(entries.filter { !ids.contains($0.id) }) { lastRemoved = removed; removalOrder = order }
    }
    func finishDrag(_ ids: Set<UUID>) { remove(Set(entries.filter { ids.contains($0.id) && !$0.pinned }.map(\.id))) }
    func clearUnpinned() { remove(Set(entries.filter { !$0.pinned }.map(\.id))) }
    func clearAll() { remove(Set(entries.map(\.id))) }
    func restoreRemoved() {
        let restored = lastRemoved.filter { item in !entries.contains { $0.url.standardizedFileURL == item.url.standardizedFileURL } }
        let rank = Dictionary(uniqueKeysWithValues: removalOrder.enumerated().map { ($0.element, $0.offset) })
        let next = (entries + restored).enumerated().sorted {
            (rank[$0.element.id] ?? (removalOrder.count + $0.offset)) < (rank[$1.element.id] ?? (removalOrder.count + $1.offset))
        }.map(\.element)
        if save(next) { lastRemoved = []; removalOrder = [] }
    }
    func splitGroups(_ ids: Set<UUID>) {
        _ = save(entries.map { item in
            var item = item
            if let group = item.groupID, ids.contains(group) { item.groupID = nil }
            return item
        })
    }
    func combine(_ ids: Set<UUID>) {
        guard entries.filter({ ids.contains($0.id) }).count > 1 else { return }
        let group = UUID()
        _ = save(entries.map { item in var item = item; if ids.contains(item.id) { item.groupID = group }; return item })
    }
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


/// A group is a presentation of file references, never a directory or a ZIP archive.
struct ShelfRow: Identifiable {
    let id: UUID
    let items: [ShelfEntry]
    var child = false
    var isStack: Bool { items.count > 1 }
    var title: String { isStack ? "\(items.count)ファイル" : items[0].url.lastPathComponent }

    static func make(from entries: [ShelfEntry], expanded: Set<UUID> = []) -> [ShelfRow] {
        var rows: [ShelfRow] = []
        var seen: Set<UUID> = []
        for entry in entries {
            let group = entry.groupID ?? entry.id
            guard seen.insert(group).inserted else { continue }
            let items = entry.groupID == nil ? [entry] : entries.filter { $0.groupID == group }
            let row = ShelfRow(id: items.count > 1 ? group : items[0].id, items: items)
            rows.append(row)
            if row.isStack && expanded.contains(group) {
                rows += items.map { ShelfRow(id: $0.id, items: [$0], child: true) }
            }
        }
        return rows
    }

    static func files(in rows: [ShelfRow], at indexes: IndexSet) -> [ShelfEntry] {
        var seen: Set<UUID> = []
        return indexes.filter { rows.indices.contains($0) }.flatMap { rows[$0].items }.filter { seen.insert($0.id).inserted }
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
    var makeDragItems: ((IndexSet, NSPoint) -> [NSDraggingItem])?
    var dragStarted: (() -> Void)?
    var dragEnded: ((NSPoint, NSDragOperation) -> Void)?
    var preview: (() -> Void)?
    var remove: (() -> Void)?
    var copyFiles: (() -> Void)?
    var pasteFiles: (() -> Void)?
    var undoClear: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        guard index >= 0 else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if shift, selectedRow >= 0 {
            selectRowIndexes(IndexSet(integersIn: min(selectedRow, index)...max(selectedRow, index)), byExtendingSelection: true)
        } else if command {
            if selectedRowIndexes.contains(index) { deselectRow(index) }
            else { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true) }
        } else if !selectedRowIndexes.contains(index) {
            selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        if event.clickCount == 2 { _ = sendAction(doubleAction, to: target); return }
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                if !command && !shift { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
                return
            }
            let nextPoint = convert(next.locationInWindow, from: nil)
            guard hypot(nextPoint.x - point.x, nextPoint.y - point.y) > 3 else { continue }
            let items = makeDragItems?(selectedRowIndexes, point) ?? []
            guard !items.isEmpty else { return }
            dragStarted?()
            let session = beginDraggingSession(with: items, event: next, source: self)
            session.draggingFormation = .pile
            session.animatesToStartingPositionsOnCancelOrFail = true
            return
        }
    }
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragEnded?(screenPoint, operation) }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": selectAll(nil); return
            case "c": copyFiles?(); return
            case "v": pasteFiles?(); return
            case "z": undoClear?(); return
            default: break
            }
        }
        if event.keyCode == 49 { preview?() }
        else if event.keyCode == 51 { remove?() }
        else { super.keyDown(with: event) }
    }
}

final class ShelfViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, NSMenuDelegate {
    let store: ShelfStore
    let table = ShelfTable()
    var onClose: (() -> Void)?
    var onDrop: (() -> Void)?
    var onDrag: ((Bool) -> Void)?
    var onSizeChange: (() -> Void)?
    var preferredShelfHeight: CGFloat { min(360, max(160, 110 + CGFloat(displayed.count) * 46)) }
    private let message = NSTextField(labelWithString: "")
    private var cancellables: Set<AnyCancellable> = []
    private var previewURLs: [URL] = []
    private var buttons: [NSButton] = []
    private var displayed: [ShelfRow] = []
    private var expandedGroups: Set<UUID> = []
    private var draggedIDs: Set<UUID> = []
    private let clearSelectionButton = NSButton()
    private let clearAllButton = NSButton()
    private let undoButton = NSButton()

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
        table.rowHeight = 46
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.preview = { [weak self] in self?.previewFiles() }
        table.remove = { [weak self] in self?.removeFiles() }
        table.makeDragItems = { [weak self] rows, point in
            guard let self else { return [] }
            return self.pasteboardItems(forRows: rows).enumerated().map { index, writer in
                let item = NSDraggingItem(pasteboardWriter: writer)
                item.setDraggingFrame(NSRect(x: point.x + CGFloat(index % 5) * 3, y: point.y, width: 28, height: 28), contents: NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
                return item
            }
        }
        table.dragStarted = { [weak self] in self?.onDrag?(true) }
        table.dragEnded = { [weak self] point, operation in self?.finishDragging(at: point, operation: operation) }
        table.copyFiles = { [weak self] in self?.copyFiles() }
        table.pasteFiles = { [weak self] in self?.pasteFiles() }
        table.undoClear = { [weak self] in self?.undoClear() }
        table.target = self; table.doubleAction = #selector(openSelection)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.addArrangedSubview(scroll)
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(message)
        let footer = NSStackView()
        for (button, title, action) in [
            (undoButton, "クリアを戻す", #selector(undoClear)),
            (clearSelectionButton, "選択をクリア", #selector(removeFiles)),
            (clearAllButton, "すべてクリア", #selector(clearAllFiles))
        ] {
            button.title = title; button.target = self; button.action = action
            button.bezelStyle = .rounded; button.controlSize = .small
            footer.addArrangedSubview(button)
        }
        stack.addArrangedSubview(footer)
        store.$lastRemoved.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateButtons() }.store(in: &cancellables)
        for item in [header, scroll, message] as [NSView] {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        store.$entries.combineLatest(store.$error).receive(on: RunLoop.main).sink { [weak self] _, _ in self?.refresh() }.store(in: &cancellables)
        refresh()
    }

    private var selection: [ShelfEntry] { ShelfRow.files(in: displayed, at: table.selectedRowIndexes) }
    private func refresh() {
        let selectedRows = Set(table.selectedRowIndexes.filter { displayed.indices.contains($0) }.map { displayed[$0].id })
        displayed = ShelfRow.make(from: store.entries, expanded: expandedGroups)
        table.reloadData()
        table.selectRowIndexes(IndexSet(displayed.indices.filter { selectedRows.contains(displayed[$0].id) }), byExtendingSelection: false)
        let stacks = ShelfRow.make(from: store.entries).filter(\.isStack).count
        message.stringValue = store.error ?? (displayed.isEmpty ? "ファイルをここにドロップ" : "\(store.entries.count)ファイル · \(stacks)スタック · Spaceでプレビュー")
        updateButtons()
        onSizeChange?()
    }
    private func updateButtons() {
        guard buttons.count >= 8 else { return }
        for index in 1...5 { buttons[index].isEnabled = !selection.isEmpty }
        buttons[6].isEnabled = store.entries.contains { !$0.pinned }
        clearSelectionButton.isEnabled = !selection.isEmpty
        clearAllButton.isEnabled = !store.entries.isEmpty
        undoButton.isEnabled = !store.lastRemoved.isEmpty
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = displayed[row]
        let entry = item.items[0]
        let exists = item.items.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }
        let cell = NSStackView()
        cell.spacing = 8
        cell.edgeInsets = NSEdgeInsets(top: 0, left: item.child ? 24 : 0, bottom: 0, right: 4)
        if item.isStack {
            let expand = NSButton(image: NSImage(systemSymbolName: expandedGroups.contains(item.id) ? "chevron.down" : "chevron.right", accessibilityDescription: "スタックの中身")!, target: self, action: #selector(toggleStack(_:)))
            expand.tag = row; expand.isBordered = false
            expand.widthAnchor.constraint(equalToConstant: 18).isActive = true
            cell.addArrangedSubview(expand)
        }
        let symbol = item.isStack ? "square.stack.3d.up" : (entry.url.hasDirectoryPath ? "folder" : "doc")
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        image.widthAnchor.constraint(equalToConstant: 28).isActive = true
        image.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let text = NSStackView(); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        let label = NSTextField(labelWithString: item.title + (exists ? "" : "（見つからないファイル）"))
        label.font = .systemFont(ofSize: 12, weight: item.isStack ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = exists ? .labelColor : .secondaryLabelColor
        text.addArrangedSubview(label)
        if item.isStack {
            let detail = NSTextField(labelWithString: item.items.map { $0.url.lastPathComponent }.joined(separator: "、"))
            detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            text.addArrangedSubview(detail)
        }
        cell.addArrangedSubview(image); cell.addArrangedSubview(text)
        if item.items.contains(where: \.pinned) { cell.addArrangedSubview(NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "ピン留め")!)) }
        cell.toolTip = item.items.map { $0.url.path }.joined(separator: "\n")
        if exists && !item.isStack {
            let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: NSSize(width: 28, height: 28), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak image] result, _ in
                if let result { DispatchQueue.main.async { image?.image = result.nsImage } }
            }
        }
        return cell
    }
    /// One visual stack supplies multiple file pasteboard items to the receiving app.
    func pasteboardItems(forRows rowIndexes: IndexSet) -> [NSPasteboardItem] {
        let items = ShelfRow.files(in: displayed, at: rowIndexes)
        // Do not silently supply only half of a stack if a source file disappeared.
        guard !items.isEmpty, items.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) else { return [] }
        draggedIDs = Set(items.map(\.id))
        return items.map { entry in
            let item = NSPasteboardItem()
            item.setString(entry.url.absoluteString, forType: .fileURL)
            item.setString("1", forType: ShelfDragMonitor.originType)
            return item
        }
    }
    private func finishDragging(at screenPoint: NSPoint, operation: NSDragOperation) {
        onDrag?(false)
        let insideShelf = view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)).contains(screenPoint) } ?? false
        if !operation.isEmpty && !insideShelf && SettingsStore.shared.data.shelfRemoveAfterDrag { store.finishDrag(draggedIDs) }
        draggedIDs = []
    }
    @objc private func toggleStack(_ sender: NSButton) {
        guard displayed.indices.contains(sender.tag) else { return }
        let id = displayed[sender.tag].id
        if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
        refresh()
    }
    @objc private func openSelection() {
        let rows = table.selectedRowIndexes.filter { displayed.indices.contains($0) }.map { displayed[$0] }
        if let stack = rows.first, rows.count == 1, stack.isStack {
            if expandedGroups.contains(stack.id) { expandedGroups.remove(stack.id) } else { expandedGroups.insert(stack.id) }
            refresh()
        } else if NSEvent.modifierFlags.contains(.command) { revealFiles() }
        else { selection.forEach { NSWorkspace.shared.open($0.url) } }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        let clicked = table.clickedRow
        if displayed.indices.contains(clicked), !table.selectedRowIndexes.contains(clicked) { table.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false) }
        menu.removeAllItems(); menu.autoenablesItems = false
        for (title, action, enabled) in [
            ("プレビュー", #selector(previewFiles), !selection.isEmpty),
            ("Finderで表示", #selector(revealFiles), !selection.isEmpty),
            ("コピー", #selector(copyFiles), !selection.isEmpty),
            ("スタックにまとめる", #selector(combineFiles), selection.count > 1),
            ("スタックを分解", #selector(splitFiles), selection.contains { $0.groupID != nil }),
            ("ピン留めを切り替え", #selector(pinFiles), !selection.isEmpty),
            ("選択をクリア", #selector(removeFiles), !selection.isEmpty),
            ("ピン留め以外をクリア", #selector(clearFiles), store.entries.contains { !$0.pinned }),
            ("すべてクリア", #selector(clearAllFiles), !store.entries.isEmpty),
            ("クリアを戻す", #selector(undoClear), !store.lastRemoved.isEmpty)
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
    }
    @objc private func combineFiles() { store.combine(Set(selection.map(\.id))) }
    @objc private func splitFiles() { store.splitGroups(Set(selection.compactMap(\.groupID))) }
    @objc private func clearAllFiles() { store.clearAll() }
    @objc private func undoClear() { store.restoreRemoved() }
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
                Toggle("取り出しに成功したファイルを棚から外す", isOn: $store.data.shelfRemoveAfterDrag)
                Text("ピン留めしたファイルは残ります。元のファイルは削除しません。").font(.caption).foregroundStyle(.secondary)
                Toggle("完了したダウンロードを棚に追加", isOn: $store.data.shelfDownloads)
                Text("棚から外しても元のファイルは削除されません。ファイルとフォルダを追加できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
