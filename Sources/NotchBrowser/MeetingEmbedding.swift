import Foundation
import CoreML
import CryptoKit

/// All upstream-dependent pins live here. No unverified artifact is downloaded or loaded.
enum MeetingModelManifest {
    static let repository = "FluidInference/embeddinggemma-2-coreml"
    static let revision = "3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4"
    struct Artifact {
        let path: String
        let size: Int
        let sha256: String
    }
    // Pins supplied by the user from the public Hugging Face API. Text assets only.
    static let artifacts: [Artifact] = [
        .init(path: "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 7_323_423, sha256: "0df9aca02807cf490db6d4f1c68607a8c7f486ad23b376d1968fd3be5eb14677"),
        .init(path: "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 276_815_424, sha256: "75b97ab036ca87eae60560c4034a63d604201498dc4b6f6971dd0b1e4558d61f"),
        .init(path: "EmbeddingGemma2Text.mlpackage/Manifest.json", size: 617, sha256: "83eace80b69b46f8415af620ba1b40d7c490d00f7c00ba9dedd2e29da6e9ac19"),
        .init(path: "embeddings.bf16", size: 268_435_456, sha256: "56ebbdbfd706c827f3fae1d97aa39135c7ddc0f1e6d9b12f8565f84bbfbda877"),
        .init(path: "tokenizer.json", size: 32_170_510, sha256: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"),
        .init(path: "config.json", size: 2_845, sha256: "30668aba89f54a200a3fa38913f21e2a2f18aba7215de67c1806542a75b9629b")
    ]
    static let packagePath = "EmbeddingGemma2Text.mlpackage"
    static let embeddingsPath = "embeddings.bf16"
    static let tokenizerPath = "tokenizer.json"
    static let inputEmbeddings = "inputs_embeds"
    static let attentionMask = "attention_mask"
    static let output = "embedding"
    static let sequenceLengths = [32, 48, 64, 128, 256, 512]
    static let sequenceLength = 512
    static let vocabularySize = 262_144
    static let inputDimensions = 512
    static let embeddingScale: Float = sqrt(512)
    static let bos = 2
    static let eos = 1
    static let pad = 0
    static let identity = MeetingEmbeddingIdentity(model: repository, dimensions: 256,
        documentPrefix: "title: none | text: ", queryPrefix: "task: search result | query: ", revision: revision)
    static func functionLength(tokenCount: Int) -> Int {
        sequenceLengths.first { $0 >= tokenCount } ?? sequenceLength
    }
    static func downloadURL(_ artifact: Artifact) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(artifact.path)")!
    }
    static var configured: Bool {
        revision.count == 40 && revision.allSatisfy(\.isHexDigit) && !artifacts.isEmpty &&
        artifacts.allSatisfy { $0.size > 0 && $0.sha256.count == 64 && $0.sha256.allSatisfy(\.isHexDigit) && !$0.path.contains("..") && !$0.path.hasPrefix("/") }
    }
    static func verify(_ data: Data, sha256: String) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256.lowercased()
    }
    static func verify(_ data: Data, artifact: Artifact) -> Bool {
        guard data.count == artifact.size else { return false }
        return verify(data, sha256: artifact.sha256)
    }
    static func verifyFile(_ url: URL, artifact: Artifact) throws -> Bool {
        guard let stream = InputStream(url: url) else { return false }
        stream.open(); defer { stream.close() }
        var sha256 = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576); var count = 0
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read >= 0 else { throw stream.streamError ?? MeetingModelError.checksum }
            if read == 0 { break }
            count += read; guard count <= artifact.size else { return false }
            let chunk = Data(buffer.prefix(read))
            sha256.update(data: chunk)
        }
        guard count == artifact.size else { return false }
        let digest = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == artifact.sha256
    }
    /// Corrupt cached/downloaded files are removed and the current preparation fails.
    static func requireVerifiedFile(_ url: URL, artifact: Artifact) throws {
        if (try? verifyFile(url, artifact: artifact)) == true { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        throw MeetingModelError.checksum
    }
}
enum MeetingModelError: LocalizedError {
    case unconfigured, checksum, invalidEmbedding, tokenizer, unsupported
    var errorDescription: String? {
        switch self {
        case .unconfigured: "モデルの固定リビジョンと検証値が未設定です。文字一致検索を使用します"
        case .checksum: "モデルファイルの整合性検証に失敗しました"
        case .invalidEmbedding: "モデルの出力が正しくありません"
        case .tokenizer: "モデルのトークナイザーを読み込めません"
        case .unsupported: "macOS 15 以上で使えます"
        }
    }
}

/// SentencePiece Unigram vocabulary in Hugging Face tokenizer.json.
/// Unsupported tokenizer formats fail closed rather than silently changing embeddings.
struct MeetingUnigramTokenizer {
    let vocabulary: [String: (Int, Double)]
    init(data: Data) throws {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = raw["model"] as? [String: Any], model["type"] as? String == "Unigram",
              let rows = model["vocab"] as? [[Any]] else { throw MeetingModelError.tokenizer }
        var vocabulary: [String: (Int, Double)] = [:]
        for (id, row) in rows.enumerated() {
            guard row.count == 2, let token = row[0] as? String, let score = row[1] as? Double else { throw MeetingModelError.tokenizer }
            vocabulary[token] = (id, score)
        }
        self.vocabulary = vocabulary
    }
    func encode(_ input: String, limit: Int, preprocessed: Bool = false) throws -> [Int] {
        let characters = Array(preprocessed ? input : ("▁" + input.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: " ", with: "▁")))
        var scores = Array(repeating: -Double.infinity, count: characters.count + 1)
        var previous = Array<(Int, [Int])?>(repeating: nil, count: characters.count + 1); scores[0] = 0
        for start in characters.indices where scores[start].isFinite {
            var piece = ""
            for end in start..<min(characters.count, start + 64) {
                piece.append(characters[end])
                if let (id, score) = vocabulary[piece], scores[start] + score > scores[end + 1] {
                    scores[end + 1] = scores[start] + score; previous[end + 1] = (start, [id])
                }
            }
            // Byte fallback preserves unknown Unicode instead of substituting an unknown token.
            let bytes = Array(String(characters[start]).utf8)
            let ids = bytes.compactMap { vocabulary[String(format: "<0x%02X>", $0)]?.0 }
            if ids.count == bytes.count, scores[start] - 100 > scores[start + 1] {
                scores[start + 1] = scores[start] - 100; previous[start + 1] = (start, ids)
            }
        }
        guard scores.last?.isFinite == true else { throw MeetingModelError.tokenizer }
        var segments: [[Int]] = []; var cursor = characters.count
        while cursor > 0 {
            guard let (start, ids) = previous[cursor] else { throw MeetingModelError.tokenizer }
            segments.append(ids); cursor = start
        }
        return Array(segments.reversed().flatMap { $0 }.prefix(limit))
    }
}

/// Raw little-endian BF16 rows, memory-mapped by the provider rather than expanded in RAM.
struct MeetingEmbeddingTable {
    private let data: Data
    let rows: Int
    let dimensions: Int
    let scale: Float
    init(data: Data, rows: Int = MeetingModelManifest.vocabularySize, dimensions: Int = MeetingModelManifest.inputDimensions,
         scale: Float = MeetingModelManifest.embeddingScale) throws {
        let (elements, overflow) = rows.multipliedReportingOverflow(by: dimensions)
        let (bytes, byteOverflow) = elements.multipliedReportingOverflow(by: 2)
        guard rows > 0, dimensions > 0, !overflow, !byteOverflow, data.count == bytes, scale.isFinite else { throw MeetingModelError.invalidEmbedding }
        self.data = data; self.rows = rows; self.dimensions = dimensions; self.scale = scale
    }
    func inputValues(tokens: [Int], length: Int, pad: Int = MeetingModelManifest.pad) throws -> [UInt16] {
        guard length >= tokens.count, length <= MeetingModelManifest.sequenceLength, pad >= 0, pad < rows,
              tokens.allSatisfy({ $0 >= 0 && $0 < rows }) else { throw MeetingModelError.invalidEmbedding }
        var values: [UInt16] = []; values.reserveCapacity(length * dimensions)
        try data.withUnsafeBytes { raw in
            for index in 0..<length {
                let token = index < tokens.count ? tokens[index] : pad
                for dimension in 0..<dimensions {
                    let offset = (token * dimensions + dimension) * 2
                    let bf16 = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
                    let value = MeetingFP16.bits(Float(bitPattern: UInt32(bf16) << 16) * scale)
                    guard MeetingFP16.isFinite(value) else { throw MeetingModelError.invalidEmbedding }
                    values.append(value)
                }
            }
        }
        return values
    }
}

actor CoreMLMeetingEmbeddingProvider: MeetingEmbeddingProvider {
    nonisolated let identity = MeetingModelManifest.identity
    private var compiledURL: URL?
    private var models: [Int: MLModel] = [:]
    private var tokenizer: MeetingGemmaTokenizer?
    private var table: MeetingEmbeddingTable?
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBrowser/meeting-search/model/" + MeetingModelManifest.revision)
    }
    func prepare() async throws {
        guard #available(macOS 15, *) else { throw MeetingModelError.unsupported }
        guard MeetingModelManifest.configured else { throw MeetingModelError.unconfigured }
        if compiledURL != nil { return }
        for artifact in MeetingModelManifest.artifacts {
            let destination = directory.appendingPathComponent(artifact.path)
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                try MeetingModelManifest.requireVerifiedFile(destination, artifact: artifact)
                continue
            }
            let (download, response) = try await URLSession.shared.download(from: MeetingModelManifest.downloadURL(artifact))
            defer { try? FileManager.default.removeItem(at: download) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MeetingModelError.checksum }
            try MeetingModelManifest.requireVerifiedFile(download, artifact: artifact)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".download")
            try FileManager.default.copyItem(at: download, to: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else { try FileManager.default.moveItem(at: staging, to: destination) }
        }
        // Recheck every file immediately before compilation/loading.
        for artifact in MeetingModelManifest.artifacts {
            try MeetingModelManifest.requireVerifiedFile(directory.appendingPathComponent(artifact.path), artifact: artifact)
        }
        let tokenizer = try MeetingGemmaTokenizer(data: Data(contentsOf: directory.appendingPathComponent(MeetingModelManifest.tokenizerPath)))
        let table = try MeetingEmbeddingTable(data: Data(contentsOf: directory.appendingPathComponent(MeetingModelManifest.embeddingsPath), options: .mappedIfSafe))
        let compiled = try await MLModel.compileModel(at: directory.appendingPathComponent(MeetingModelManifest.packagePath))
        let first = try loadModel(compiled: compiled, length: 32)
        self.tokenizer = tokenizer; self.table = table; models = [32: first]; compiledURL = compiled
    }
    @available(macOS 15, *)
    private func loadModel(compiled: URL, length: Int) throws -> MLModel {
        let configuration = MLModelConfiguration(); configuration.computeUnits = .all; configuration.functionName = "embed_\(length)"
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        let inputs = model.modelDescription.inputDescriptionsByName
        let embedding = inputs[MeetingModelManifest.inputEmbeddings]?.multiArrayConstraint
        let mask = inputs[MeetingModelManifest.attentionMask]?.multiArrayConstraint
        let output = model.modelDescription.outputDescriptionsByName[MeetingModelManifest.output]?.multiArrayConstraint
        guard embedding?.dataType == .float16, embedding?.shape.map(\.intValue) == [1, length, 512],
              mask?.dataType == .float16, mask?.shape.map(\.intValue) == [1, length], output?.shape.map(\.intValue) == [1, 768] else { throw MeetingModelError.invalidEmbedding }
        return model
    }
    func embedding(_ text: String, isQuery: Bool) async throws -> [Float] {
        guard #available(macOS 15, *) else { throw MeetingModelError.unsupported }
        guard let compiledURL, let tokenizer, let table else { throw MeetingModelError.invalidEmbedding }
        let tokens = try tokenizer.encode((isQuery ? identity.queryPrefix : identity.documentPrefix) + text, limit: MeetingModelManifest.sequenceLength)
        let length = MeetingModelManifest.functionLength(tokenCount: tokens.count)
        let model: MLModel
        if let existing = models[length] { model = existing }
        else { model = try loadModel(compiled: compiledURL, length: length); models[length] = model }
        let values = try table.inputValues(tokens: tokens, length: length)
        let embeds = try MLMultiArray(shape: [1, NSNumber(value: length), 512], dataType: .float16)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .float16)
        let buffer = embeds.dataPointer.bindMemory(to: UInt16.self, capacity: values.count)
        for index in values.indices { buffer[index] = values[index] }
        let maskBuffer = mask.dataPointer.bindMemory(to: UInt16.self, capacity: length)
        for index in 0..<length {
            maskBuffer[index] = index < tokens.count ? 0x3c00 : 0x0000 // fp16 1 / 0
        }
        let inputs = try MLDictionaryFeatureProvider(dictionary: [MeetingModelManifest.inputEmbeddings: embeds, MeetingModelManifest.attentionMask: mask])
        let result = try await model.prediction(from: inputs)
        guard let output = result.featureValue(for: MeetingModelManifest.output)?.multiArrayValue, output.count == 768 else { throw MeetingModelError.invalidEmbedding }
        return MeetingSearchRanking.normalized((0..<output.count).map { output[$0].floatValue })
    }
}
