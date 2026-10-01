import AppKit
import SwiftUI

enum NotionPanelTheme {
    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                           green: CGFloat((value >> 8) & 0xff) / 255,
                           blue: CGFloat(value & 0xff) / 255, alpha: 1)
        }
    }

    static let canvas = Color(nsColor: adaptive(light: 0xffffff, dark: 0x191919))
    static let surface = Color(nsColor: adaptive(light: 0xf7f7f5, dark: 0x202020))
    static let softSurface = Color(nsColor: adaptive(light: 0xf9f9f8, dark: 0x292929))
    static let hairline = Color(nsColor: adaptive(light: 0xe9e9e7, dark: 0x383838))
    static let ink = Color(nsColor: adaptive(light: 0x37352f, dark: 0xe9e9e7))
    static let muted = Color(nsColor: adaptive(light: 0x787774, dark: 0x9b9b99))
    static let blue = Color(nsColor: adaptive(light: 0x2383e2, dark: 0x529cca))
    static let blueWash = Color(nsColor: adaptive(light: 0xe8f2fc, dark: 0x25394a))
    static let notice = Color(nsColor: adaptive(light: 0xfff4ce, dark: 0x3c3320))
    static let link = adaptive(light: 0x0075de, dark: 0x529cca)
    static let text = adaptive(light: 0x37352f, dark: 0xe9e9e7)
}

struct NotionAgentAvatar: View {
    let agent: SavedNotionAgent
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(NotionPanelTheme.blueWash)
            if let value = agent.iconURL, let url = URL(string: value) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Text(agent.glyph).font(.system(size: size * 0.65))
                }
            } else {
                Text(agent.glyph).font(.system(size: size * 0.65))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("\(agent.name)のアイコン")
    }
}

enum NotionReplyBlock: Equatable {
    case paragraph(String)
    case bullet(String)
    case numbered(String, String)
    case artifact
}

enum NotionReplyFormatter {
    private static let mention = try! NSRegularExpression(pattern: #"<mention\s+url="([^"]+)"[^>]*>(.*?)</mention>"#, options: .dotMatchesLineSeparators)
    private static let citation = try! NSRegularExpression(pattern: #"\[\^(https?://[^\]]+)\]"#)
    private static let artifact = try! NSRegularExpression(pattern: #"<data_artifact\b[^>]*/>"#)
    private static let numbered = try! NSRegularExpression(pattern: #"^(\d+)\.\s+(.+)$"#)
    private static let markdownLink = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(https?://[^)]+\)"#)

    static func markdown(_ raw: String) -> String {
        var value = replace(mention, in: raw) { match, source in
            let url = source.substring(with: match.range(at: 1))
            let title = source.substring(with: match.range(at: 2))
            guard URLComponents(string: url)?.scheme?.lowercased() == "https" else { return title }
            return "[\(title)](\(url))"
        }
        value = replace(citation, in: value) { match, source in
            let url = source.substring(with: match.range(at: 1))
            return "[出典](\(url))"
        }
        return artifact.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                                 withTemplate: "\n:::notion-artifact:::\n")
    }

    static func blocks(_ raw: String) -> [NotionReplyBlock] {
        markdown(raw).components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if trimmed == ":::notion-artifact:::" { return .artifact }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return .bullet(String(trimmed.dropFirst(2))) }
            let source = trimmed as NSString
            if let match = numbered.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
                return .numbered(source.substring(with: match.range(at: 1)), source.substring(with: match.range(at: 2)))
            }
            return .paragraph(trimmed)
        }
    }

    static func copyText(_ raw: String) -> String {
        markdown(raw).replacingOccurrences(of: ":::notion-artifact:::", with: "表データ（Notionで確認）")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func preview(_ raw: String) -> String {
        var value = markdown(raw).replacingOccurrences(of: ":::notion-artifact:::", with: "")
        value = replace(markdownLink, in: value) { match, source in source.substring(with: match.range(at: 1)) }
        value = value.replacingOccurrences(of: "**", with: "")
        return String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(140))
    }

    private static func replace(_ expression: NSRegularExpression, in text: String,
                                using transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let source = text as NSString
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(match, source))
        }
        return result
    }
}

private final class NotionLinkTextView: NSTextView {
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let layoutManager, let textContainer, let textStorage else { return }
        let location = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let point = NSPoint(x: location.x - origin.x, y: location.y - origin.y)
        let index = layoutManager.characterIndex(for: point, in: textContainer,
                                                  fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < textStorage.length else { NSCursor.iBeam.set(); return }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                                   in: textContainer)
        let isLink = glyphRect.contains(point) && textStorage.attribute(.link, at: index, effectiveRange: nil) != nil
        (isLink ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSCursor.arrow.set()
    }
}

private struct NotionReplyText: NSViewRepresentable {
    let source: String
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NotionLinkTextView {
        let view = NotionLinkTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.linkTextAttributes = [.foregroundColor: NotionPanelTheme.link,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue]
        return view
    }

    func updateNSView(_ view: NotionLinkTextView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let value = (try? AttributedString(markdown: source,
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        let text = NSMutableAttributedString(attributedString: NSAttributedString(value))
        text.addAttributes([.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NotionPanelTheme.text],
                           range: NSRange(location: 0, length: text.length))
        if view.attributedString() != text { view.textStorage?.setAttributedString(text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NotionLinkTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 500)
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let textContainer = view.textContainer, let layoutManager = view.layoutManager {
            layoutManager.ensureLayout(for: textContainer)
            return CGSize(width: width, height: max(18, ceil(layoutManager.usedRect(for: textContainer).height)))
        }
        return CGSize(width: width, height: 18)
    }
}

struct NotionMessageView: View {
    let message: NotionMessage
    let agent: SavedNotionAgent
    @State private var copied = false
    private var isUser: Bool { message.role == "user" }

    private var timestamp: String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: message.created_time) ?? ISO8601DateFormatter().date(from: message.created_time)
        guard let date else { return "" }
        return date.formatted(Date.FormatStyle().month(.abbreviated).day().hour().minute())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 45) }
            else { NotionAgentAvatar(agent: agent, size: 28) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(NotionReplyFormatter.blocks(message.content).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let text): NotionReplyText(source: text)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            NotionReplyText(source: text)
                        }
                    case .numbered(let number, let text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(number).").foregroundStyle(.secondary)
                            NotionReplyText(source: text)
                        }
                    case .artifact:
                        Label("表データはNotionで確認できます", systemImage: "tablecells")
                            .font(.caption).foregroundStyle(NotionPanelTheme.muted)
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(NotionPanelTheme.softSurface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(isUser ? NotionPanelTheme.blueWash : NotionPanelTheme.canvas,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(NotionPanelTheme.hairline))
                HStack(spacing: 8) {
                    Text(timestamp).font(.caption2).foregroundStyle(.tertiary)
                    if !isUser {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(NotionReplyFormatter.copyText(message.content), forType: .string)
                            copied = true
                        } label: {
                            Label(copied ? "コピーしました" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                        .help("返信をコピー")
                    }
                }.padding(.horizontal, 3)
            }
            if !isUser { Spacer(minLength: 45) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
    }
}
