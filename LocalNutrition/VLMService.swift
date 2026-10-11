import Foundation
import CryptoKit
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

// Adapter follows the MIT-licensed MLX Swift LM tokenizer bridge.
private struct LocalTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do { return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext) }
        catch Tokenizers.TokenizerError.missingChatTemplate { throw MLXLMCommon.TokenizerError.missingChatTemplate }
    }
}
private struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        LocalTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

actor VLMService {
    static let generationSettings = "numeric-json-v2; maxTokens=160; temperature=0; repetitionPenalty=1.1; repetitionContextSize=64; resize=512; stop=complete-json"
    static let researchSettings = "appendix-a-L0; condition=none|W (weight sentence appended); system=empty; maxTokens=256; temperature=0; repetitionPenalty=none; stop=natural; pixels=preprocessor_config; input=jpeg<=1024px,sRGB,q0.88"
    private var model: ModelContainer?
    private var loadedVariant: VLMVariant?
    private var weightHashes: [VLMVariant: String] = [:]

    func load(_ variant: VLMVariant) async throws {
        guard model == nil || loadedVariant != variant else { return }
        guard let directory = try ModelStore.url(for: variant) else { throw NutritionError.missingModel }
        model = nil; loadedVariant = nil
        Memory.clearCache()
        Memory.cacheLimit = 32 * 1024 * 1024
        model = try await VLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
        loadedVariant = variant
    }

    // SHA-256 of every *.safetensors file of the model folder, as "file=hash;file=hash".
    // Computed once per variant (a few seconds for the 4B weights) and compared with
    // `shasum -a 256 *.safetensors` on the computer that prepared the folder.
    func weightsSHA256(for variant: VLMVariant) -> String? {
        if let cached = weightHashes[variant] { return cached }
        guard let directory = try? ModelStore.url(for: variant),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var parts: [String] = []
        for name in names.filter({ $0.hasSuffix(".safetensors") }).sorted() {
            guard let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent(name)) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            var finished = false
            while !finished {
                autoreleasepool {
                    if let chunk = try? handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                        hasher.update(data: chunk)
                    } else {
                        finished = true
                    }
                }
            }
            parts.append(name + "=" + hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: ";")
        weightHashes[variant] = joined
        return joined
    }

    /// Runs one analysis and returns the time spent on image preprocessing and generation
    /// (model loading excluded), measured as in the research batch application.
    @discardableResult
    func generate(imageURL: URL, prompt: String, variant: VLMVariant, mode: AnalysisMode,
                  onResponse: @escaping @Sendable (String) async -> Void) async throws -> Double {
        try await load(variant)
        guard let model else { throw NutritionError.missingModel }
        if mode == .research {
            guard let directory = try ModelStore.url(for: variant) else { throw NutritionError.missingModel }
            let configURL = directory.appendingPathComponent("preprocessor_config.json")
            let data = try Data(contentsOf: configURL)
            guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let size = config["size"] as? [String: Any] else { throw NutritionError.invalidModelConfig }
            let minPixels = config["min_pixels"] as? Int ?? size["shortest_edge"] as? Int
            let maxPixels = config["max_pixels"] as? Int ?? size["longest_edge"] as? Int
            guard let minPixels, let maxPixels else { throw NutritionError.invalidModelConfig }
            let started = Date()
            let raw = try await model.perform { (context: ModelContext) in
                let input = UserInput(chat: [.system(""), .user(prompt, images: [.url(imageURL)])],
                                      processing: .init(minPixels: minPixels, maxPixels: maxPixels))
                let prepared = try await context.processor.prepare(input: input)
                var parameters = GenerateParameters(temperature: 0)
                parameters.maxTokens = 256
                return try MLXLMCommon.generate(input: prepared, parameters: parameters,
                                               context: context) { (_: [Int]) in .more }.output
            }
            let elapsed = Date().timeIntervalSince(started)
            try Task.checkCancellation()
            await onResponse(raw)
            return elapsed
        }
        // A fresh session prevents information from the previous meal leaking into this image.
        let session = ChatSession(model, generateParameters: .init(maxTokens: 160, temperature: 0,
                                  repetitionPenalty: 1.1, repetitionContextSize: 64),
                                  processing: .init(resize: CGSize(width: 512, height: 512)))
        var response = ""
        let started = Date()
        for try await chunk in session.streamResponse(to: prompt, images: [.url(imageURL)]) {
            try Task.checkCancellation()
            response += chunk
            if let object = JSONResponse.firstCompleteObject(in: response) {
                // Emit only the complete first object, then drop the stream to cancel its producer.
                await onResponse(object)
                try Task.checkCancellation()
                return Date().timeIntervalSince(started)
            }
            await onResponse(response)
        }
        try Task.checkCancellation()
        throw NutritionError.incompleteResponse
    }
}

enum ModelStore {
    static func modelsDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let models = documents.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        return models
    }
    static func url(for variant: VLMVariant) throws -> URL? {
        let models = try modelsDirectory()
        let direct = models.deletingLastPathComponent().appendingPathComponent(variant.folderName, isDirectory: true)
        if valid(direct) { return direct }
        let local = models.appendingPathComponent(variant.folderName, isDirectory: true)
        if valid(local) { return local }
        if variant == .twoB, let bundled = Bundle.main.url(forResource: "Model", withExtension: nil), valid(bundled) { return bundled }
        return nil
    }
    static func valid(_ folder: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folder.appendingPathComponent("config.json").path),
              manager.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path) else { return false }
        if manager.fileExists(atPath: folder.appendingPathComponent("model.safetensors").path) { return true }
        return manager.fileExists(atPath: folder.appendingPathComponent("model.safetensors.index.json").path)
            && manager.fileExists(atPath: folder.appendingPathComponent("model-00001-of-00002.safetensors").path)
            && manager.fileExists(atPath: folder.appendingPathComponent("model-00002-of-00002.safetensors").path)
    }
    static func install(from source: URL, as variant: VLMVariant) throws {
        guard valid(source) else { throw NutritionError.missingModel }
        let target = try modelsDirectory().appendingPathComponent(variant.folderName, isDirectory: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: source, to: staging)
            guard valid(staging) else { throw NutritionError.missingModel }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: staging, to: target)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}
