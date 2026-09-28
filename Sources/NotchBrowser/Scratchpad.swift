import AppKit

/// Notes stay on this Mac and are separated by browser profile.
final class ScratchpadStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ profileID: UUID) -> String { "scratchpad.v1.\(profileID.uuidString)" }
    func text(for profileID: UUID) -> String { defaults.string(forKey: key(profileID)) ?? "" }
    func save(_ text: String, for profileID: UUID) { defaults.set(text, forKey: key(profileID)) }
    func remove(for profileID: UUID) { defaults.removeObject(forKey: key(profileID)) }
}

final class ScratchpadView: NSView, NSTextViewDelegate {
    private let editor = ScratchpadTextView()
    private let store = ScratchpadStore()
    private var profileID = Profile.defaultID
    private let subtitle = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?
    var pageLink: (() -> (String, URL)?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.16, alpha: 1).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.borderWidth = 1
        let title = NSTextField(labelWithString: "クイックメモ")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let close = NSButton(image: TabIconRenderer.symbol("xmark", size: 16)!, target: self, action: #selector(closeNote))
        close.bezelStyle = .recessed
        close.setAccessibilityLabel("メモを閉じる")
        close.toolTip = "メモを閉じる (Esc)"
        let link = NSButton(title: "ページを添付", image: TabIconRenderer.symbol("link", size: 16)!, target: self, action: #selector(appendLink))
        let copy = NSButton(title: "コピー", image: TabIconRenderer.symbol("doc.on.doc", size: 16)!, target: self, action: #selector(copyNote))
        for button in [link, copy] { button.bezelStyle = .recessed; button.font = .systemFont(ofSize: 11) }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 6, height: 10)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = self
        editor.onCancel = { [weak self] in self?.onClose?() }
        editor.setAccessibilityLabel("クイックメモの本文")
        scroll.documentView = editor
        for sub in [title, subtitle, close, link, copy, scroll] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 20), title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor), close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6), subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), scroll.bottomAnchor.constraint(equalTo: link.topAnchor, constant: -12),
            link.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), link.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            copy.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18), copy.centerYAnchor.constraint(equalTo: link.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(profile: Profile) {
        if profileID != profile.id { editor.undoManager?.removeAllActions() }
        profileID = profile.id
        editor.string = store.text(for: profile.id)
        subtitle.stringValue = "\(profile.name) · このMacに自動保存"
        isHidden = false
        window?.makeKey()
        window?.makeFirstResponder(editor)
    }
    func textDidChange(_ notification: Notification) { store.save(editor.string, for: profileID) }
    @objc private func closeNote() { onClose?() }
    @objc private func appendLink() {
        guard let (title, url) = pageLink?() else { NSSound.beep(); return }
        let suffix = (editor.string.isEmpty ? "" : "\n\n") + "\(title)\n\(url.absoluteString)"
        editor.insertText(suffix, replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        store.save(editor.string, for: profileID)
    }
    @objc private func copyNote() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(editor.string, forType: .string)
    }
}

private final class ScratchpadTextView: NSTextView {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
