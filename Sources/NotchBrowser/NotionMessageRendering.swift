import AppKit
import SwiftUI

struct NotionAgentAvatar: View {
    let agent: SavedNotionAgent
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.16))
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

private struct NotionReplyText: View {
    let source: String
    var body: some View {
        let value = (try? AttributedString(markdown: source,
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        Text(value).textSelection(.enabled).tint(.cyan)
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
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(isUser ? Color.accentColor.opacity(0.24) : Color.white.opacity(0.075),
                            in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17)
                    .stroke(.white.opacity(isUser ? 0.12 : 0.06)))
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
