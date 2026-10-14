import Foundation
import SwiftUI

enum MeetingSearchDateLabels {
    static func updated(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "未更新" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 H:mm"
        return formatter.string(from: date)
    }
}

struct MeetingSearchRange: Equatable {
    let start: Date
    let end: Date
    func contains(_ date: Date?) -> Bool { date.map { $0 >= start && $0 < end } ?? false }
    func label(calendar: Calendar = .current) -> String {
        let last = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        func day(_ date: Date) -> String { "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日" }
        return "\(day(start))〜\(day(last))"
    }
}
struct MeetingSearchQuery: Equatable {
    let text: String
    let range: MeetingSearchRange?
    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> Self {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var range: MeetingSearchRange?
        for (word, component, offset) in [("先月", Calendar.Component.month, -1), ("今月", .month, 0), ("先週", .weekOfYear, -1), ("今週", .weekOfYear, 0)] {
            if text.contains(word), let date = calendar.date(byAdding: component, value: offset, to: now), let interval = calendar.dateInterval(of: component, for: date) {
                range = .init(start: interval.start, end: interval.end); text = text.replacingOccurrences(of: word, with: ""); break
            }
        }
        if range == nil, let regex = try? NSRegularExpression(pattern: "(?<![0-9])(?:(\\d{4})年)?(1[0-2]|[1-9])月"),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let full = Range(match.range, in: text), let monthRange = Range(match.range(at: 2), in: text), let month = Int(text[monthRange]) {
            let year = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? calendar.component(.year, from: now)
            if let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)), let end = calendar.date(byAdding: .month, value: 1, to: start) { range = .init(start: start, end: end) }
            text.removeSubrange(full)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("の") { text.removeFirst() }
        return .init(text: text, range: range)
    }
}
protocol MeetingEmbeddingProvider {
    var identity: MeetingEmbeddingIdentity { get }
    func prepare() async throws
    func embedding(_ text: String, isQuery: Bool) async throws -> [Float]
}
struct MeetingEmbeddingIdentity: Codable, Equatable {
    let model: String
    let dimensions: Int
    let documentPrefix: String
    let queryPrefix: String
    var revision: String = ""
}
struct MeetingSearchSentence: Codable, Equatable {
    let meetingID: String
    let sectionID: String
    let blockID: String
    let text: String
    let edited: Date
    var vector: [Float]
}
struct MeetingSearchCache: Codable {
    let identity: MeetingEmbeddingIdentity
    var sentences: [MeetingSearchSentence]
    var updated: Date?
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
    static let threshold: Float = 0.45
    static func normalized(_ values: [Float]) -> [Float] {
        guard values.count >= 256, values.allSatisfy(\.isFinite) else { return [] }
        let slice = Array(values.prefix(256)); let norm = sqrt(slice.reduce(Float(0)) { $0 + $1 * $1 })
        return norm > 0 ? slice.map { $0 / norm } : []
    }
    static func hits(meetings: [NotionMeeting], sentences: [MeetingSearchSentence], query: MeetingSearchQuery, queryVector: [Float]? = nil) -> [MeetingSearchHit] {
        let eligible = meetings.filter { $0.status == "notes_ready" && (query.range?.contains($0.calendarStart) ?? true) }
        let terms = query.text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var best: [String: MeetingSearchHit] = [:]
        for meeting in eligible {
            let rows = sentences.filter { $0.meetingID == meeting.id }
            for row in rows.isEmpty ? [MeetingSearchSentence(meetingID: meeting.id, sectionID: "", blockID: "", text: "", edited: meeting.edited, vector: [])] : rows {
                let score: Float
                if terms.isEmpty { score = 1 }
                else if let queryVector, queryVector.count == 256, row.vector.count == 256 {
                    score = zip(queryVector, row.vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                } else {
                    let haystack = (meeting.title + " " + row.text).lowercased()
                    score = Float(terms.filter { haystack.contains($0) }.count) / Float(terms.count)
                }
                guard score >= threshold else { continue }
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
                .init(meetingID: meeting.id, sectionID: section, blockID: block.id, text: $0, edited: max(meeting.edited, block.edited), vector: [])
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
    @Published private(set) var preparing = false
    @Published private(set) var ready = false
    @Published private(set) var modelPrepared = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var updated: Date?
    @Published private(set) var error: String?
    var supported: Bool { if #available(macOS 15, *) { return true }; return false }
    var progressLabel: String { "意味検索を準備中・\(completed)/\(total)件" }
    var modelStatus: String { preparing ? "準備中" : modelPrepared ? "使える" : "未ダウンロード" }
    private let provider: any MeetingEmbeddingProvider
    private let cacheURL: URL?
    private var generation = UUID()
    private var indexing = false
    init(provider: any MeetingEmbeddingProvider = CoreMLMeetingEmbeddingProvider(), cacheURL: URL? = nil, persist: Bool = true) {
        self.provider = provider
        #if DEBUG
        let preview = CommandLine.arguments.contains(where: { $0.hasPrefix("--meeting-search=") })
        #else
        let preview = false
        #endif
        self.cacheURL = persist && !preview ? (cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("NotchBrowser/meeting-search/cache.json")) : nil
        if let url = self.cacheURL, let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(MeetingSearchCache.self, from: data), cache.identity == provider.identity {
            sentences = cache.sentences.map { row in
                var row = row
                if row.vector.count != 256 { row.vector = [] }
                return row
            }; updated = cache.updated
        }
    }
    func clear() {
        generation = UUID(); sentences = []; completed = 0; total = 0; updated = nil; ready = false; preparing = false; error = nil
        if let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) {
            do { try FileManager.default.removeItem(at: cacheURL) }
            catch { self.error = "検索キャッシュを消去できませんでした" }
        }
    }
    func index(meetings: [NotionMeeting], load: (String) async throws -> [NotionTaskBlock]) async {
        guard !indexing else { return }; indexing = true
        defer { indexing = false }
        let generation = self.generation
        let eligible = meetings.filter { $0.status == "notes_ready" }
        total = eligible.count; completed = 0; preparing = supported; ready = false; error = nil
        sentences.removeAll { row in !eligible.contains { $0.id == row.meetingID } }
        // Re-fetch even within the same edited minute, including child blocks.
        for meeting in eligible {
            do {
                var fresh: [MeetingSearchSentence] = []
                for section in [meeting.summary, meeting.notes].compactMap({ $0 }) {
                    fresh += MeetingSearchRanking.sentences(meeting: meeting, section: section, blocks: try await load(section))
                }
                guard generation == self.generation, !Task.isCancelled else { return }
                let old = sentences.filter { $0.meetingID == meeting.id }
                for i in fresh.indices {
                    if let previous = old.first(where: { $0.blockID == fresh[i].blockID && $0.text == fresh[i].text && $0.edited == fresh[i].edited }) { fresh[i].vector = previous.vector }
                }
                sentences.removeAll { $0.meetingID == meeting.id }; sentences += fresh; completed += 1
            } catch {
                guard generation == self.generation else { return }
                sentences.removeAll { $0.meetingID == meeting.id }
                self.error = "議事録の取り込みに失敗しました"
            }
        }
        guard generation == self.generation else { return }
        updated = Date(); save()
        if supported {
            do {
                try await provider.prepare()
                guard generation == self.generation, !Task.isCancelled else { return }
                modelPrepared = true
                for i in sentences.indices where sentences[i].vector.isEmpty {
                    let vector = MeetingSearchRanking.normalized(try await provider.embedding(sentences[i].text, isQuery: false))
                    guard generation == self.generation, !Task.isCancelled else { return }
                    guard vector.count == 256 else { throw MeetingModelError.invalidEmbedding }
                    sentences[i].vector = vector
                }
                ready = true; preparing = false; save()
            } catch {
                guard generation == self.generation else { return }
                self.error = error.localizedDescription; ready = false; preparing = false
            }
        }
    }
    private func save() {
        guard let cacheURL, let data = try? JSONEncoder().encode(MeetingSearchCache(identity: provider.identity, sentences: sentences, updated: updated)) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch { self.error = "検索キャッシュを保存できませんでした" }
    }
    func search(meetings: [NotionMeeting], query: MeetingSearchQuery) async -> [MeetingSearchHit] {
        var vector: [Float]?
        if ready && !query.text.isEmpty {
            if let values = try? await provider.embedding(query.text, isQuery: true) { vector = MeetingSearchRanking.normalized(values) }
            if vector?.count != 256 { vector = nil }
        }
        return MeetingSearchRanking.hits(meetings: meetings, sentences: sentences, query: query, queryVector: vector)
    }
    #if DEBUG
    func preview(state: String, meetings: [NotionMeeting]) {
        total = 48; completed = 12; preparing = state == "preparing"; ready = !preparing; modelPrepared = !preparing; updated = Date()
        sentences = meetings.flatMap { MeetingSearchRanking.sentences(meeting: $0, section: "notes", blocks: NotionMeetingsStore.previewBlocks(section: "notes")) }
    }
    #endif
}

struct MeetingSearchSettingsPage: View {
    @ObservedObject private var search = MeetingSearchStore.shared
    var body: some View {
        Form {
            Section("意味検索") {
                if search.supported {
                    LabeledContent("モデル状態", value: search.modelStatus)
                    LabeledContent("取り込んだ件数", value: "\(Set(search.sentences.map(\.meetingID)).count)件")
                    LabeledContent("最終更新", value: MeetingSearchDateLabels.updated(search.updated))
                    Button("キャッシュを消去") { search.clear() }
                    if let error = search.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                } else { Text("macOS 15 以上で使えます").foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped)
        .task {
            #if DEBUG
            if CommandLine.arguments.contains("--meeting-search=settings") {
                search.preview(state: "settings", meetings: NotionMeetingsStore.shared.meetings)
            }
            #endif
        }
    }
}
