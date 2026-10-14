import Foundation
import Combine

struct MeetingSearchQuery: Equatable {
    let text: String
    static func parse(_ input: String) -> Self { .init(text: input.trimmingCharacters(in: .whitespacesAndNewlines)) }
}
struct MeetingSearchSentence: Equatable {
    let meetingID: String
    let sectionID: String
    let blockID: String
    let text: String
    let edited: Date
}
struct MeetingSearchHit: Identifiable, Equatable {
    var id: String { meetingID }
    let meetingID: String
    let sectionID: String
    let blockID: String
    let sentence: String
    let score: Float
}
enum MeetingSearchRanking {
    static func hits(meetings: [NotionMeeting], sentences: [MeetingSearchSentence], query: MeetingSearchQuery) -> [MeetingSearchHit] {
        let terms = query.text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        var best: [String: MeetingSearchHit] = [:]
        for meeting in meetings where meeting.status == "notes_ready" {
            let rows = sentences.filter { $0.meetingID == meeting.id }
            let candidates = rows.isEmpty ? [MeetingSearchSentence(meetingID: meeting.id, sectionID: "", blockID: "", text: "", edited: meeting.edited)] : rows
            for row in candidates {
                let haystack = (meeting.title + " " + row.text).lowercased()
                let score = Float(terms.filter { haystack.contains($0) }.count) / Float(terms.count)
                guard score >= 0.45 else { continue }
                let hit = MeetingSearchHit(meetingID: meeting.id, sectionID: row.sectionID, blockID: row.blockID, sentence: row.text, score: score)
                if score > (best[meeting.id]?.score ?? -1) { best[meeting.id] = hit }
            }
        }
        return Array(best.values.sorted { $0.score == $1.score ? $0.meetingID < $1.meetingID : $0.score > $1.score }.prefix(20))
    }

    static func sentences(meeting: NotionMeeting, section: String, blocks: [NotionTaskBlock]) -> [MeetingSearchSentence] {
        guard meeting.status == "notes_ready", section == meeting.summary || section == meeting.notes else { return [] }
        return blocks.filter { $0.type != "image" && $0.image == nil && !$0.text.isEmpty }.flatMap { block in
            sentenceTexts(block.text).map {
                .init(meetingID: meeting.id, sectionID: section, blockID: block.id, text: $0, edited: max(meeting.edited, block.edited))
            }
        }
    }
    private static func sentenceTexts(_ text: String) -> [String] {
        var sentences: [String] = []; var current = ""
        func append() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }
        for character in text {
            if character == "\n" { append() }
            else {
                current.append(character)
                if "。！？!?".contains(character) { append() }
            }
        }
        append(); return sentences
    }
}

@MainActor final class MeetingSearchStore: ObservableObject {
    static let shared = MeetingSearchStore()
    @Published private(set) var sentences: [MeetingSearchSentence] = []
    private var generation = UUID()
    func clear() { generation = UUID(); sentences = [] }
    func index(meetings: [NotionMeeting], load: (String) async throws -> [NotionTaskBlock]) async {
        let current = UUID(); generation = current
        var fresh: [MeetingSearchSentence] = []
        for meeting in meetings where meeting.status == "notes_ready" {
            do {
                var rows: [MeetingSearchSentence] = []
                for section in [meeting.summary, meeting.notes].compactMap({ $0 }) {
                    rows += MeetingSearchRanking.sentences(meeting: meeting, section: section, blocks: try await load(section))
                }
                fresh += rows
            } catch { /* Failed bodies must not retain stale matches. */ }
            guard generation == current, !Task.isCancelled else { return }
        }
        sentences = fresh
    }
    func search(meetings: [NotionMeeting], query: MeetingSearchQuery) async -> [MeetingSearchHit] {
        MeetingSearchRanking.hits(meetings: meetings, sentences: sentences, query: query)
    }
    #if DEBUG
    func preview(state: String, meetings: [NotionMeeting]) {
        sentences = meetings.flatMap { MeetingSearchRanking.sentences(meeting: $0, section: "notes", blocks: NotionMeetingsStore.previewBlocks(section: "notes")) }
    }
    #endif
}
