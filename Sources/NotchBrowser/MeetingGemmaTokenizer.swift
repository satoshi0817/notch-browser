import Foundation

/// Reads the tokenizer's own normalization, pre-tokenization and special-token template.
/// Unsupported instructions fail closed; an approximate tokenizer must not produce cached vectors.
struct MeetingGemmaTokenizer {
    private struct Pair: Hashable { let left: String; let right: String }
    private let raw: [String: Any]
    private let vocabulary: [String: Int]
    private let ranks: [Pair: Int]
    private let unigram: MeetingUnigramTokenizer?
    private let byteFallback: Bool
    private let ignoreMerges: Bool
    init(data: Data) throws {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any], let model = raw["model"] as? [String: Any] else { throw MeetingModelError.tokenizer }
        self.raw = raw
        byteFallback = model["byte_fallback"] as? Bool ?? false
        ignoreMerges = model["ignore_merges"] as? Bool ?? false
        if model["type"] as? String == "Unigram" {
            unigram = try MeetingUnigramTokenizer(data: data); vocabulary = [:]; ranks = [:]
        } else {
            guard model["type"] as? String == "BPE", let vocabulary = model["vocab"] as? [String: Int],
                  model["dropout"] == nil || model["dropout"] is NSNull,
                  (model["continuing_subword_prefix"] as? String ?? "").isEmpty,
                  (model["end_of_word_suffix"] as? String ?? "").isEmpty else { throw MeetingModelError.tokenizer }
            var ranks: [Pair: Int] = [:]
            guard let merges = model["merges"] as? [Any] else { throw MeetingModelError.tokenizer }
            for (rank, value) in merges.enumerated() {
                let parts = (value as? [String]) ?? (value as? String)?.split(separator: " ", maxSplits: 1).map(String.init) ?? []
                guard parts.count == 2, vocabulary[parts[0] + parts[1]] != nil else { throw MeetingModelError.tokenizer }
                ranks[.init(left: parts[0], right: parts[1])] = rank
            }
            self.vocabulary = vocabulary; self.ranks = ranks; unigram = nil
        }
        // Validate the configured pipeline and postprocessor before any model is loaded.
        _ = try specialTemplate()
        _ = try pretokenize(normalize("validation", instruction: raw["normalizer"]), instruction: raw["pre_tokenizer"])
    }
    func encode(_ text: String, limit: Int = MeetingModelManifest.sequenceLength) throws -> [Int] {
        guard limit > 0 else { return [] }
        let template = try specialTemplate()
        let specialCount = template.compactMap { $0 }.reduce(0) { $0 + $1.count }
        let bodyLimit = max(0, limit - specialCount)
        if bodyLimit == 0 { return Array(template.flatMap { $0 ?? [] }.prefix(limit)) }
        var body: [Int] = []
        for (rawIndex, rawPiece) in try addedPieces(text, normalized: false).enumerated() {
            let (piece, token) = rawPiece
            if let token { body.append(token) }
            else {
                let normalized = try normalize(piece, instruction: raw["normalizer"])
                for (partIndex, normalizedPiece) in try addedPieces(normalized, normalized: true).enumerated() {
                    let (part, token) = normalizedPiece
                    if let token { body.append(token) }
                    else {
                        for chunk in try pretokenize(part, instruction: raw["pre_tokenizer"], atStart: rawIndex == 0 && partIndex == 0) {
                            if let unigram { body += try unigram.encode(chunk, limit: max(0, bodyLimit - body.count), preprocessed: true) }
                            else { body += try bpe(chunk) }
                            if body.count >= bodyLimit { break }
                        }
                    }
                    if body.count >= bodyLimit { break }
                }
            }
            if body.count >= bodyLimit { break }
        }
        body = Array(body.prefix(bodyLimit))
        return Array(template.flatMap { $0 ?? body }.prefix(limit))
    }
    /// nil marks the input sequence; other entries are explicit special-token IDs.
    private func specialTemplate() throws -> [[Int]?] {
        guard let processor = raw["post_processor"] as? [String: Any] else { return [nil] }
        if processor["type"] as? String == "ByteLevel" { return [nil] }
        guard processor["type"] as? String == "TemplateProcessing", let single = processor["single"] as? [[String: Any]],
              let specials = processor["special_tokens"] as? [String: [String: Any]] else { throw MeetingModelError.tokenizer }
        var template: [[Int]?] = []; var sequences = 0
        for entry in single {
            if let sequence = entry["Sequence"] as? [String: Any], sequence["id"] as? String == "A" { template.append(nil); sequences += 1 }
            else if let special = entry["SpecialToken"] as? [String: Any], let name = special["id"] as? String, let ids = specials[name]?["ids"] as? [Int] { template.append(ids) }
            else { throw MeetingModelError.tokenizer }
        }
        guard sequences == 1 else { throw MeetingModelError.tokenizer }; return template
    }
    private func addedPieces(_ text: String, normalized: Bool) throws -> [(String, Int?)] {
        let tokens = (raw["added_tokens"] as? [[String: Any]] ?? []).filter { ($0["normalized"] as? Bool ?? false) == normalized }
        var pieces: [(String, Int?)] = []; var cursor = text.startIndex
        while cursor < text.endIndex {
            var best: (Range<String.Index>, Int)?
            for token in tokens {
                guard let content = token["content"] as? String, !content.isEmpty, let id = token["id"] as? Int else { throw MeetingModelError.tokenizer }
                let target = normalized ? try normalize(content, instruction: raw["normalizer"]) : content
                guard !target.isEmpty else { throw MeetingModelError.tokenizer }
                var searchStart = cursor
                while searchStart < text.endIndex, var range = text.range(of: target, range: searchStart..<text.endIndex) {
                    let leftWord = range.lowerBound > text.startIndex && (text[text.index(before: range.lowerBound)].isLetter || text[text.index(before: range.lowerBound)].isNumber)
                    let rightWord = range.upperBound < text.endIndex && (text[range.upperBound].isLetter || text[range.upperBound].isNumber)
                    if token["single_word"] as? Bool == true && (leftWord || rightWord) { searchStart = range.upperBound; continue }
                    if token["lstrip"] as? Bool == true {
                        while range.lowerBound > cursor && text[text.index(before: range.lowerBound)].isWhitespace { range = text.index(before: range.lowerBound)..<range.upperBound }
                    }
                    if token["rstrip"] as? Bool == true {
                        while range.upperBound < text.endIndex && text[range.upperBound].isWhitespace { range = range.lowerBound..<text.index(after: range.upperBound) }
                    }
                    if best == nil || range.lowerBound < best!.0.lowerBound || (range.lowerBound == best!.0.lowerBound && range.upperBound > best!.0.upperBound) { best = (range, id) }
                    break
                }
            }
            guard let (range, id) = best else { pieces.append((String(text[cursor...]), nil)); break }
            if range.lowerBound > cursor { pieces.append((String(text[cursor..<range.lowerBound]), nil)) }
            pieces.append((String(text[range]), id)); cursor = range.upperBound
        }
        return pieces
    }
    private func normalize(_ text: String, instruction: Any?) throws -> String {
        guard let rule = instruction as? [String: Any] else { if instruction == nil || instruction is NSNull { return text }; throw MeetingModelError.tokenizer }
        switch rule["type"] as? String {
        case "Sequence":
            guard let rules = rule["normalizers"] as? [Any] else { throw MeetingModelError.tokenizer }
            return try rules.reduce(text) { try normalize($0, instruction: $1) }
        case "Prepend": guard let prefix = rule["prepend"] as? String else { throw MeetingModelError.tokenizer }; return prefix + text
        case "Replace":
            guard let pattern = rule["pattern"] as? [String: String], let replacement = rule["content"] as? String else { throw MeetingModelError.tokenizer }
            if let literal = pattern["String"] { return text.replacingOccurrences(of: literal, with: replacement) }
            guard let pattern = pattern["Regex"] else { throw MeetingModelError.tokenizer }
            let regex = try NSRegularExpression(pattern: pattern)
            // Replacement content is literal in tokenizers, not an ICU capture template.
            var output = text
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: output) else { throw MeetingModelError.tokenizer }
                output.replaceSubrange(range, with: replacement)
            }
            return output
        case "NFC": return text.precomposedStringWithCanonicalMapping
        case "NFKC": return text.precomposedStringWithCompatibilityMapping
        case "NFD": return text.decomposedStringWithCanonicalMapping
        case "NFKD": return text.decomposedStringWithCompatibilityMapping
        case "Lowercase": return text.lowercased()
        case "Strip":
            var output = text
            if rule["strip_left"] as? Bool == true { while output.first?.isWhitespace == true { output.removeFirst() } }
            if rule["strip_right"] as? Bool == true { while output.last?.isWhitespace == true { output.removeLast() } }
            return output
        default: throw MeetingModelError.tokenizer
        }
    }
    private func pretokenize(_ text: String, instruction: Any?, atStart: Bool = true) throws -> [String] {
        guard let rule = instruction as? [String: Any] else { if instruction == nil || instruction is NSNull { return text.isEmpty ? [] : [text] }; throw MeetingModelError.tokenizer }
        switch rule["type"] as? String {
        case "Sequence":
            guard let rules = rule["pretokenizers"] as? [Any] else { throw MeetingModelError.tokenizer }
            return try rules.reduce([text]) { pieces, rule in
                try pieces.enumerated().flatMap { try pretokenize($0.element, instruction: rule, atStart: atStart && $0.offset == 0) }
            }
        case "WhitespaceSplit": return text.split(whereSeparator: \.isWhitespace).map(String.init)
        case "Split":
            guard let pattern = rule["pattern"] as? [String: String], let behavior = rule["behavior"] as? String else { throw MeetingModelError.tokenizer }
            let expression = pattern["Regex"] ?? pattern["String"].map(NSRegularExpression.escapedPattern(for:))
            guard let expression else { throw MeetingModelError.tokenizer }
            return try split(text, expression: expression, behavior: behavior, inverted: rule["invert"] as? Bool ?? false)
        case "Metaspace":
            guard let replacement = rule["replacement"] as? String, replacement.count == 1 else { throw MeetingModelError.tokenizer }
            var output = text.replacingOccurrences(of: " ", with: replacement)
            let scheme = rule["prepend_scheme"] as? String ?? ((rule["add_prefix_space"] as? Bool ?? true) ? "always" : "never")
            guard ["always", "first", "never"].contains(scheme) else { throw MeetingModelError.tokenizer }
            if (scheme == "always" || (scheme == "first" && atStart)) && !output.hasPrefix(replacement) { output = replacement + output }
            if rule["split"] as? Bool == false { return [output] }
            return try split(output, expression: NSRegularExpression.escapedPattern(for: replacement), behavior: "MergedWithNext", inverted: false)
        default: throw MeetingModelError.tokenizer
        }
    }
    private func split(_ text: String, expression: String, behavior: String, inverted: Bool) throws -> [String] {
        let regex = try NSRegularExpression(pattern: expression)
        var units: [(String, Bool)] = []; var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard match.range.length > 0, let range = Range(match.range, in: text) else { throw MeetingModelError.tokenizer }
            if range.lowerBound > cursor { units.append((String(text[cursor..<range.lowerBound]), inverted)) }
            units.append((String(text[range]), !inverted)); cursor = range.upperBound
        }
        if cursor < text.endIndex { units.append((String(text[cursor...]), inverted)) }
        var output: [String] = []; var pending = ""; var previousDelimiter = false
        for (piece, delimiter) in units {
            switch behavior {
            case "Removed": if !delimiter { output.append(piece) }
            case "Isolated": output.append(piece)
            case "Contiguous": if delimiter && previousDelimiter && !output.isEmpty { output[output.count - 1] += piece } else { output.append(piece) }
            case "MergedWithPrevious": if delimiter && !output.isEmpty { output[output.count - 1] += piece } else { output.append(piece) }
            case "MergedWithNext": if delimiter { pending += piece } else { output.append(pending + piece); pending = "" }
            default: throw MeetingModelError.tokenizer
            }
            previousDelimiter = delimiter
        }
        if !pending.isEmpty { output.append(pending) }; return output
    }
    private struct Node { var piece: String; var previous: Int?; var next: Int?; var version = 0; var alive = true }
    private struct Candidate {
        let rank: Int; let left: Int; let right: Int; let leftVersion: Int; let rightVersion: Int
        func precedes(_ other: Self) -> Bool { rank == other.rank ? left < other.left : rank < other.rank }
    }
    private func bpe(_ text: String) throws -> [Int] {
        if ignoreMerges, let id = vocabulary[text] { return [id] }
        var pieces: [String] = []
        for scalar in text.unicodeScalars {
            let piece = String(scalar)
            if vocabulary[piece] != nil { pieces.append(piece) }
            else {
                guard byteFallback else { throw MeetingModelError.tokenizer }
                let bytes = piece.utf8.map { String(format: "<0x%02X>", $0) }
                guard bytes.allSatisfy({ vocabulary[$0] != nil }) else { throw MeetingModelError.tokenizer }
                pieces += bytes
            }
        }
        var nodes = pieces.enumerated().map { Node(piece: $0.element, previous: $0.offset > 0 ? $0.offset - 1 : nil, next: $0.offset + 1 < pieces.count ? $0.offset + 1 : nil) }
        var heap: [Candidate] = []
        func push(_ candidate: Candidate) {
            heap.append(candidate); var index = heap.count - 1
            while index > 0 { let parent = (index - 1) / 2; guard heap[index].precedes(heap[parent]) else { break }; heap.swapAt(index, parent); index = parent }
        }
        func add(_ left: Int) {
            guard nodes[left].alive, let right = nodes[left].next, let rank = ranks[.init(left: nodes[left].piece, right: nodes[right].piece)] else { return }
            push(.init(rank: rank, left: left, right: right, leftVersion: nodes[left].version, rightVersion: nodes[right].version))
        }
        func pop() -> Candidate? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let first = heap[0]; heap[0] = heap.removeLast(); var index = 0
            while index * 2 + 1 < heap.count {
                var child = index * 2 + 1
                if child + 1 < heap.count && heap[child + 1].precedes(heap[child]) { child += 1 }
                guard heap[child].precedes(heap[index]) else { break }; heap.swapAt(index, child); index = child
            }
            return first
        }
        for index in nodes.indices { add(index) }
        while let candidate = pop() {
            let left = candidate.left; let right = candidate.right
            guard nodes[left].alive, nodes[right].alive, nodes[left].next == right,
                  nodes[left].version == candidate.leftVersion, nodes[right].version == candidate.rightVersion else { continue }
            nodes[left].piece += nodes[right].piece; nodes[left].version += 1
            nodes[left].next = nodes[right].next; nodes[right].alive = false; nodes[right].version += 1
            if let next = nodes[left].next { nodes[next].previous = left }
            if let previous = nodes[left].previous { add(previous) }; add(left)
        }
        return try nodes.filter(\.alive).map { guard let id = vocabulary[$0.piece] else { throw MeetingModelError.tokenizer }; return id }
    }
}
