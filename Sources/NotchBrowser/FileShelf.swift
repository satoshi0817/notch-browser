import AppKit
import Combine
import SwiftUI
import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum ShelfTrigger: String, Codable, CaseIterable {
    case automatic, nearby, manual
    var title: String {
        switch self { case .automatic: "ドラッグ開始"; case .nearby: "ノッチに接近"; case .manual: "手動" }
    }
}

enum ShelfTileSize: Int, Codable, CaseIterable {
    case small = 80, medium = 96, large = 112
    var title: String {
        switch self { case .small: "小"; case .medium: "中"; case .large: "大" }
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

final class ShelfTilesView: NSCollectionView {
    var makeDragItems: ((Set<IndexPath>, NSPoint) -> [NSDraggingItem])?
    var dragStarted: (() -> Void)?
    var dragEnded: ((NSPoint, NSDragOperation) -> Void)?
    var preview: (() -> Void)?
    var remove: (() -> Void)?
    var copyFiles: (() -> Void)?
    var pasteFiles: (() -> Void)?
    var undoClear: (() -> Void)?
    var open: (() -> Void)?
    var addFiles: (([URL]) -> Bool)?
    var selectionChanged: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = indexPathForItem(at: point) else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if shift, let anchor = selectionIndexPaths.first {
            let range = min(anchor.item, index.item)...max(anchor.item, index.item)
            selectionIndexPaths = Set(range.map { IndexPath(item: $0, section: 0) })
        } else if command {
            if selectionIndexPaths.contains(index) { selectionIndexPaths.remove(index) }
            else { selectionIndexPaths.insert(index) }
        } else if !selectionIndexPaths.contains(index) {
            selectionIndexPaths = [index]
        }
        selectionChanged?()
        if event.clickCount == 2 { open?(); return }
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                if !command && !shift { selectionIndexPaths = [index]; selectionChanged?() }
                return
            }
            let nextPoint = convert(next.locationInWindow, from: nil)
            guard hypot(nextPoint.x - point.x, nextPoint.y - point.y) > 3 else { continue }
            let items = makeDragItems?(selectionIndexPaths, point) ?? []
            guard !items.isEmpty else { return }
            dragStarted?()
            let session = beginDraggingSession(with: items, event: next, source: self)
            session.draggingFormation = .pile
            session.animatesToStartingPositionsOnCancelOrFail = true
            return
        }
    }
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.allowedOperations(for: context)
    }
    static func allowedOperations(for context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move] : .copy
    }
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragEnded?(screenPoint, operation) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource as? ShelfTilesView !== self,
              sender.draggingSourceOperationMask.contains(.copy),
              !ShelfViewController.urls(from: sender.draggingPasteboard).isEmpty else { return [] }
        return .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        addFiles?(ShelfViewController.urls(from: sender.draggingPasteboard)) ?? false
    }
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

final class ShelfTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ShelfTile")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var representedID: UUID?

    override var isSelected: Bool { didSet { updateSelection() } }

    override func loadView() {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 14
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 11, weight: .medium)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false
        count.font = .systemFont(ofSize: 10, weight: .semibold)
        count.textColor = .secondaryLabelColor
        count.alignment = .center
        count.translatesAutoresizingMaskIntoConstraints = false
        for child in [icon, name, count] as [NSView] { tile.addSubview(child) }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.topAnchor.constraint(equalTo: tile.topAnchor, constant: 6),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            name.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 5),
            name.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -5),
            name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            count.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 4),
            count.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -4),
            count.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1)
        ])
        view = tile
        updateSelection()
    }

    func configure(_ row: ShelfRow, showDetails: Bool) {
        representedID = row.id
        let entry = row.items[0]
        let exists = row.items.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }
        let symbol = row.isStack ? "square.stack.3d.up" : (entry.url.hasDirectoryPath ? "folder.fill" : "doc.fill")
        icon.image = exists && !row.isStack ? NSWorkspace.shared.icon(forFile: entry.url.path)
            : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        name.stringValue = row.title
        name.textColor = exists ? .labelColor : .secondaryLabelColor
        count.stringValue = row.isStack ? "\(row.items.count) 個\(row.items.contains(where: \.pinned) ? " · 固定" : "")" : (entry.pinned ? "固定中" : "")
        view.setAccessibilityLabel(row.title)
        view.toolTip = showDetails ? row.items.map { item in
            let path = item.url.path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            let detail = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            return "\(item.url.lastPathComponent)\n\(path)\(detail.isEmpty ? "" : " · \(detail)")"
        }.joined(separator: "\n\n") : nil
        let type = UTType(filenameExtension: entry.url.pathExtension)
        if exists && !row.isStack && (type?.conforms(to: .image) == true || type?.conforms(to: .pdf) == true || type?.conforms(to: .movie) == true) {
            let id = row.id
            let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: NSSize(width: 40, height: 40), scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] result, _ in
                guard let result else { return }
                DispatchQueue.main.async { if self?.representedID == id { self?.icon.image = result.nsImage } }
            }
        }
    }

    private func updateSelection() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.32) : NSColor.white.withAlphaComponent(0.08)).cgColor
        view.layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.12)).cgColor
        view.layer?.borderWidth = 1
    }
}

final class ShelfViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, QLPreviewPanelDataSource, NSMenuDelegate {
    let store: ShelfStore
    let tiles = ShelfTilesView()
    var onClose: (() -> Void)?
    var onDrop: (() -> Void)?
    var onDrag: ((Bool) -> Void)?
    var onSizeChange: (() -> Void)?
    var preferredShelfHeight: CGFloat { CGFloat(SettingsStore.shared.data.shelfTileSize.rawValue) + 120 }
    private let message = NSTextField(labelWithString: "")
    private var cancellables: Set<AnyCancellable> = []
    private var previewURLs: [URL] = []
    private var buttons: [NSButton] = []
    private var displayed: [ShelfRow] = []
    private var expandedGroups: Set<UUID> = []
    private var draggedIDs: Set<UUID> = []
    private var tileHeight: NSLayoutConstraint?
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
        let flow = NSCollectionViewFlowLayout()
        flow.scrollDirection = .horizontal
        let side = CGFloat(SettingsStore.shared.data.shelfTileSize.rawValue)
        flow.itemSize = NSSize(width: side, height: side)
        flow.minimumInteritemSpacing = 8
        flow.sectionInset = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        tiles.collectionViewLayout = flow
        tiles.backgroundColors = [.clear]
        tiles.isSelectable = true
        tiles.allowsMultipleSelection = true
        tiles.dataSource = self; tiles.delegate = self
        tiles.register(ShelfTileItem.self, forItemWithIdentifier: ShelfTileItem.identifier)
        tiles.registerForDraggedTypes([.fileURL])
        tiles.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        tiles.setDraggingSourceOperationMask(.copy, forLocal: true)
        tiles.preview = { [weak self] in self?.previewFiles() }
        tiles.remove = { [weak self] in self?.removeFiles() }
        tiles.makeDragItems = { [weak self] rows, point in
            guard let self else { return [] }
            return self.pasteboardItems(forRows: IndexSet(rows.map(\.item))).enumerated().map { index, writer in
                let item = NSDraggingItem(pasteboardWriter: writer)
                item.setDraggingFrame(NSRect(x: point.x + CGFloat(index % 5) * 3, y: point.y, width: 48, height: 48), contents: NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
                return item
            }
        }
        tiles.dragStarted = { [weak self] in self?.onDrag?(true) }
        tiles.dragEnded = { [weak self] point, operation in self?.finishDragging(at: point, operation: operation) }
        tiles.copyFiles = { [weak self] in self?.copyFiles() }
        tiles.pasteFiles = { [weak self] in self?.pasteFiles() }
        tiles.undoClear = { [weak self] in self?.undoClear() }
        tiles.open = { [weak self] in self?.openSelection() }
        tiles.selectionChanged = { [weak self] in self?.updateButtons() }
        tiles.addFiles = { [weak self] urls in
            guard let self else { return false }
            let result = self.store.add(urls)
            if result { self.onDrop?() }
            return result
        }
        let menu = NSMenu()
        menu.delegate = self
        tiles.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = tiles
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.drawsBackground = false
        let tileHeight = scroll.heightAnchor.constraint(equalToConstant: side + 18)
        tileHeight.isActive = true
        self.tileHeight = tileHeight
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

    func settingsChanged() {
        guard isViewLoaded else { return }
        let side = CGFloat(SettingsStore.shared.data.shelfTileSize.rawValue)
        (tiles.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize = NSSize(width: side, height: side)
        tileHeight?.constant = side + 18
        tiles.collectionViewLayout?.invalidateLayout()
        tiles.reloadData()
        onSizeChange?()
    }

    private var selection: [ShelfEntry] { ShelfRow.files(in: displayed, at: IndexSet(tiles.selectionIndexPaths.map(\.item))) }
    private func refresh() {
        let selectedRows = Set(tiles.selectionIndexPaths.map(\.item).filter { displayed.indices.contains($0) }.map { displayed[$0].id })
        displayed = ShelfRow.make(from: store.entries, expanded: expandedGroups)
        tiles.reloadData()
        tiles.selectionIndexPaths = Set(displayed.indices.filter { selectedRows.contains(displayed[$0].id) }.map { IndexPath(item: $0, section: 0) })
        let stacks = ShelfRow.make(from: store.entries).filter(\.isStack).count
        message.stringValue = store.error ?? (displayed.isEmpty ? "ファイルをここにドロップ" : "\(store.entries.count)ファイル · \(stacks)スタック · 横スクロールで移動 · Spaceでプレビュー")
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
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateButtons() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateButtons() }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { displayed.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ShelfTileItem.identifier, for: indexPath) as! ShelfTileItem
        item.configure(displayed[indexPath.item], showDetails: SettingsStore.shared.data.shelfHoverDetails)
        return item
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
    @objc private func toggleSelectedStack() {
        guard let index = tiles.selectionIndexPaths.first?.item, displayed.indices.contains(index), displayed[index].isStack else { return }
        let id = displayed[index].id
        if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
        refresh()
    }
    @objc private func openSelection() {
        let rows = tiles.selectionIndexPaths.map(\.item).filter { displayed.indices.contains($0) }.map { displayed[$0] }
        if let stack = rows.first, rows.count == 1, stack.isStack {
            if expandedGroups.contains(stack.id) { expandedGroups.remove(stack.id) } else { expandedGroups.insert(stack.id) }
            refresh()
        } else if NSEvent.modifierFlags.contains(.command) { revealFiles() }
        else { selection.forEach { NSWorkspace.shared.open($0.url) } }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let event = NSApp.currentEvent, let clicked = tiles.indexPathForItem(at: tiles.convert(event.locationInWindow, from: nil)),
           !tiles.selectionIndexPaths.contains(clicked) { tiles.selectionIndexPaths = [clicked] }
        menu.removeAllItems(); menu.autoenablesItems = false
        let hasStack = tiles.selectionIndexPaths.count == 1 && tiles.selectionIndexPaths.first.map { displayed.indices.contains($0.item) && displayed[$0.item].isStack } == true
        for (title, action, enabled) in [
            ("プレビュー", #selector(previewFiles), !selection.isEmpty),
            ("スタックを展開／閉じる", #selector(toggleSelectedStack), hasStack),
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
                Text("ピン留めしたファイルは残ります。Finderでは通常のファイルドラッグと同じ移動・コピーが適用されます。⌥でコピー、⌘で移動。ブラウザやメールへの添付では元ファイルを保持します。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("完了したダウンロードを棚に追加", isOn: $store.data.shelfDownloads)
                Text("棚から外す操作は元ファイルを変更しません。ファイルとフォルダを追加できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("表示") {
                Picker("タイルの大きさ", selection: $store.data.shelfTileSize) {
                    ForEach(ShelfTileSize.allCases, id: \.self) { size in Text(size.title).tag(size) }
                }
                .pickerStyle(.segmented)
                Toggle("ホバーでファイルの詳細を表示", isOn: $store.data.shelfHoverDetails)
                Text("タイルは横に並び、棚の幅を超えると横スクロールできます。スタックはダブルクリックで展開できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
