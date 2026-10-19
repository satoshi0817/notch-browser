import AppKit

#if DEBUG
enum TabRestDebugArguments {
    static func seconds(arguments: [String]) -> TimeInterval? {
        let prefix = "--tab-rest-seconds="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }),
              let seconds = TimeInterval(argument.dropFirst(prefix.count)),
              seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}
#endif

enum TabRestInterval: Int, Codable, CaseIterable {
    case fifteenMinutes = 900, thirtyMinutes = 1800, oneHour = 3600, never = 0
    var title: String {
        switch self {
        case .fifteenMinutes: "15分"
        case .thirtyMinutes: "30分"
        case .oneHour: "1時間"
        case .never: "休ませない"
        }
    }
}

struct WebRecoveryState {
    private(set) var terminated = false
    private(set) var automaticAttemptUsed = false
    private(set) var failed = false
    private(set) var recovering = false
    mutating func terminate() { terminated = true; recovering = false }
    mutating func beginAutomatic() -> Bool {
        guard !recovering else { return false }
        guard !automaticAttemptUsed else { failed = true; return false }
        automaticAttemptUsed = true; terminated = false; recovering = true
        return true
    }
    mutating func manualReload() {
        automaticAttemptUsed = false; terminated = false; failed = false; recovering = true
    }
    mutating func finish(success: Bool) {
        terminated = false; recovering = false; failed = !success
    }
    func reloadSymbol(isLoading: Bool, restoring: Bool, failureVisible: Bool) -> String {
        !failed && !failureVisible && !restoring && isLoading ? "xmark" : "arrow.clockwise"
    }
}

enum TabRestRules {
    static func eligible(visibleSelected: Bool, playingMedia: Bool, editing: Bool, native: Bool) -> Bool {
        !visibleSelected && !playingMedia && !editing && !native
    }
    static let activity = #"""
    (() => {
        const inspect = doc => {
            const active = doc.activeElement;
            let editing = !!active && (/^(INPUT|TEXTAREA)$/.test(active.tagName) || active.isContentEditable);
            let playing = [...doc.querySelectorAll('audio,video')].some(e => !e.paused && !e.ended);
            for (const frame of doc.querySelectorAll('iframe,frame')) {
                try {
                    if (frame.contentDocument) {
                        const nested = inspect(frame.contentDocument);
                        editing ||= nested.editing; playing ||= nested.playing;
                    } else if (active === frame) { editing = true; }
                } catch (_) { if (active === frame) editing = true; }
            }
            return {editing, playing};
        };
        return inspect(document);
    })()
    """#
}

/// Memory only: clearing or destroying the owner releases all page pixels.
final class TabSnapshot {
    private(set) var image: NSImage?
    func store(_ image: NSImage?) { self.image = image }
    func clear() { image = nil }
}

enum WebTabOperation: String {
    case rest, resume, terminate, reload
    case autoReload = "auto-reload"
}

/// Draw the fill and title ourselves: native bezels can turn white in inactive windows.
private final class WebReloadButton: NSButton {
    override var intrinsicContentSize: NSSize {
        let titleSize = attributedTitle.size()
        return NSSize(width: max(120, titleSize.width + 36), height: max(36, titleSize.height + 18))
    }

    override func draw(_ dirtyRect: NSRect) {
        let blue = NSColor.systemBlue
        let fill = cell?.isHighlighted == true ? blue.blended(withFraction: 0.15, of: .black) ?? blue : blue
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let size = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.systemBlue.cgColor
        needsDisplay = true
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

final class WebTabFailureView: NSView {
    static let backgroundColor = NSColor(white: 0.08, alpha: 1)
    // Nominal sRGB contrast: (0.420033 + 0.05) / (0.007194 + 0.05) = 8.22:1.
    static let messageColor = NSColor(white: 0.68, alpha: 1)

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.backgroundColor.cgColor
        let label = NSTextField(labelWithString: "ページを表示できませんでした")
        label.textColor = Self.messageColor
        let button = WebReloadButton(title: "再読み込み", target: target, action: action)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.systemBlue.cgColor
        button.layer?.cornerRadius = 8
        button.contentTintColor = .white
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        ])
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
