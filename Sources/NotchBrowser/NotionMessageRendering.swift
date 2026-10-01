import AppKit
import SwiftUI

enum NotionPanelTheme {
    static let canvas = Color(red: 1, green: 1, blue: 1)
    static let surface = Color(red: 0.965, green: 0.961, blue: 0.957)
    static let softSurface = Color(red: 0.98, green: 0.976, blue: 0.973)
    static let hairline = Color(red: 0.898, green: 0.89, blue: 0.875)
    static let ink = Color(red: 0.216, green: 0.208, blue: 0.184)
    static let muted = Color(red: 0.471, green: 0.463, blue: 0.443)
    static let purple = Color(red: 0.337, green: 0.271, blue: 0.831)
    static let lavender = Color(red: 0.902, green: 0.878, blue: 0.961)
    static let link = NSColor(srgbRed: 0, green: 0.459, blue: 0.871, alpha: 1)
    static let text = NSColor(srgbRed: 0.216, green: 0.208, blue: 0.184, alpha: 1)
}

struct NotionAgentAvatar: View {
    let agent: SavedNotionAgent
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(NotionPanelTheme.lavender)
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

    func makeNSView(context: Context) -> NotionLinkTextView {
        let view = NotionLinkTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.appearance = NSAppearance(named: .aqua)
        view.textContainer?.widthTracksTextView = true
        view.linkTextAttributes = [.foregroundColor: NotionPanelTheme.link,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue]
        return view
    }

    func updateNSView(_ view: NotionLinkTextView, context: Context) {
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
                .background(isUser ? NotionPanelTheme.lavender.opacity(0.62) : NotionPanelTheme.canvas,
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
