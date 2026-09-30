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
    let agentName: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(message.role == "user" ? "あなた" : agentName)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(NotionReplyFormatter.copyText(message.content), forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "コピーしました" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                .help("返信をコピー")
            }
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
            .padding(message.role == "user" ? 12 : 0)
            .background(message.role == "user" ? Color.blue.opacity(0.2) : .clear,
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}
