import Foundation
import CryptoKit
import UniformTypeIdentifiers

enum AnalysisMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case consumer = "consumer"
    case research = "research_protocol"
    var id: String { rawValue }
    var title: String { L(self == .consumer ? "通常" : "研究プロトコル") }
}

enum ResearchProtocol {
    // Verbatim BASE from the research batch application (BatchRunnerView.swift, tag paper2-ipad-run;
    // Appendix A of the paper, L0 / none condition). Do not edit: identity with that string is what
    // makes this mode comparable with the published runs.
    static let prompt =
        "Look at this food image. Estimate the nutritional content based solely on visual "
        + "appearance\u{2014}color, shape, ingredients, and portion size. Do NOT read any text, labels, "
        + "or numbers visible in the image. Use only visual information. Provide a brief one-line "
        + "explanation of your reasoning. Respond ONLY in JSON format: {energy_kcal: value, "
        + "protein_g: value, fat_g: value, carb_g: value, salt_g: value, basis: one-line reasoning}"

    // Weight (W) condition: identical to pilot_p23_local_v4.py (laptop runs of the declared-weight
    // experiment): user text + " The total weight of the food shown is {w:g} g."
    static let weightSeparator = " "
    static func weightSentence(grams: Double) -> String {
        "The total weight of the food shown is \(formatGrams(grams)) g."
    }
    static func promptText(declaredWeight: Double?) -> String {
        guard let grams = declaredWeight else { return prompt }
        return prompt + weightSeparator + weightSentence(grams: grams)
    }
    static func condition(declaredWeight: Double?) -> String { declaredWeight == nil ? "none" : "W" }
    // Same number format as the laptop runs (Python f"{w:g}", i.e. C "%g"): 350 -> "350", 352.5 -> "352.5".
    static func formatGrams(_ grams: Double) -> String {
        String(format: "%g", grams)
    }
}

// Run metadata written with every analysis so that a record can be traced to the exact software,
// weights and device that produced it.
enum Provenance {
    // Keep in sync with Package.resolved (checked against the research batch application).
    static let libraries = "mlx-swift 0.31.6; mlx-swift-lm 604fae710a4e3324346fc59e3845952350acd4b7; swift-transformers 1.3.0; swift-jinja 2.3.1"
    static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }()
    static let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()
}

struct Nutrition: Codable, Equatable, Sendable {
    var energy_kcal: Double
    var protein_g: Double
    var fat_g: Double
    var carb_g: Double
    var salt_g: Double
    var basis: String

    init(energy_kcal: Double, protein_g: Double, fat_g: Double, carb_g: Double, salt_g: Double, basis: String) {
        self.energy_kcal = energy_kcal; self.protein_g = protein_g; self.fat_g = fat_g
        self.carb_g = carb_g; self.salt_g = salt_g; self.basis = basis
    }

    private enum CodingKeys: String, CodingKey { case energy_kcal, protein_g, fat_g, carb_g, salt_g, basis }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        energy_kcal = try values.decode(Double.self, forKey: .energy_kcal)
        protein_g = try values.decode(Double.self, forKey: .protein_g)
        fat_g = try values.decode(Double.self, forKey: .fat_g)
        carb_g = try values.decode(Double.self, forKey: .carb_g)
        salt_g = try values.decode(Double.self, forKey: .salt_g)
        // Older records include a rationale; numeric-only responses do not need one.
        basis = try values.decodeIfPresent(String.self, forKey: .basis) ?? ""
    }

    static let zero = Nutrition(energy_kcal: 0, protein_g: 0, fat_g: 0, carb_g: 0, salt_g: 0, basis: "")
    var isValid: Bool {
        let values = [energy_kcal, protein_g, fat_g, carb_g, salt_g]
        return values.allSatisfy { $0.isFinite && $0 >= 0 } && energy_kcal <= 10_000
            && protein_g <= 1_000 && fat_g <= 1_000 && carb_g <= 2_000 && salt_g <= 100
    }

    static func parse(_ text: String) throws -> Nutrition {
        let cleaned = text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        guard let first = cleaned.firstIndex(of: "{"), let last = cleaned.lastIndex(of: "}"), first <= last else {
            throw NutritionError.invalidResponse
        }
        var json = String(cleaned[first...last])
        json = json.replacingOccurrences(of: "([\\{,]\\s*)(energy_kcal|protein_g|fat_g|carb_g|salt_g|basis)(\\s*:)",
                                        with: "$1\"$2\"$3", options: .regularExpression)
        guard let data = json.data(using: .utf8), let result = try? JSONDecoder().decode(Nutrition.self, from: data), result.isValid else {
            throw NutritionError.invalidResponse
        }
        return result
    }

    // Same three parsing stages as pilot_p23_local_v4.py; the app needs all five
    // numbers to display a nutrition result, while raw text is retained on failure.
    static func parseResearch(_ text: String) throws -> (nutrition: Nutrition, stage: String) {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "^```(?:json)?\\s*", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
        if let value = researchObject(cleaned) { return (value, "json") }
        if let first = cleaned.firstIndex(of: "{"), let last = cleaned.lastIndex(of: "}"), first <= last {
            let object = String(cleaned[first...last])
            let quoted = object.replacingOccurrences(of: "([{,]\\s*)([A-Za-z_][A-Za-z0-9_]*)(\\s*:)",
                with: "$1\"$2\"$3", options: .regularExpression)
            if let value = researchObject(quoted) { return (value, "rescued_keys") }
        }
        let fields = ["energy_kcal", "protein_g", "fat_g", "carb_g", "salt_g"]
        var numbers: [String: Double] = [:]
        for field in fields {
            let pattern = NSRegularExpression.escapedPattern(for: field) + "\\D*?(-?\\d+(?:\\.\\d+)?)"
            guard let match = cleaned.range(of: pattern, options: .regularExpression),
                  let numberRange = cleaned[match].range(of: "-?\\d+(?:\\.\\d+)?", options: .regularExpression),
                  let number = Double(cleaned[match][numberRange]) else { continue }
            numbers[field] = number
        }
        if let value = researchNutrition(numbers, basis: "") { return (value, "rescued_regex") }
        throw NutritionError.invalidResponse
    }

    private static func researchObject(_ text: String) -> Nutrition? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var numbers: [String: Double] = [:]
        for field in ["energy_kcal", "protein_g", "fat_g", "carb_g", "salt_g"] {
            if let value = object[field] as? NSNumber { numbers[field] = value.doubleValue }
            else if let value = object[field] as? String,
                    let range = value.range(of: "-?\\d+(?:\\.\\d+)?", options: .regularExpression) {
                numbers[field] = Double(value[range])
            }
        }
        return researchNutrition(numbers, basis: object["basis"] as? String ?? "")
    }

    private static func researchNutrition(_ numbers: [String: Double], basis: String) -> Nutrition? {
        guard let energy = numbers["energy_kcal"], let protein = numbers["protein_g"],
              let fat = numbers["fat_g"], let carb = numbers["carb_g"], let salt = numbers["salt_g"] else { return nil }
        let result = Nutrition(energy_kcal: energy, protein_g: protein, fat_g: fat, carb_g: carb,
                               salt_g: salt, basis: basis)
        return result.isValid ? result : nil
    }

    func scaled(by amount: Double) -> Nutrition {
        Nutrition(energy_kcal: energy_kcal * amount, protein_g: protein_g * amount,
                  fat_g: fat_g * amount, carb_g: carb_g * amount, salt_g: salt_g * amount, basis: basis)
    }
}

enum NutritionError: LocalizedError {
    case invalidResponse, incompleteResponse, missingModel, invalidImage, invalidModelConfig
    var errorDescription: String? {
        switch self {
        case .invalidResponse: L("AIの応答を栄養値として読み取れませんでした。生の応答を確認して、再解析してください。")
        case .incompleteResponse: L("AIの出力が完成する前に終了しました。写真と応答は保存されています。再解析してください。")
        case .missingModel: L("このモデルは端末にありません。ファイルアプリからモデルフォルダを追加してください。")
        case .invalidImage: L("画像を読み込めませんでした。別の画像を選んでください。")
        case .invalidModelConfig: L("モデルの画像処理設定を読み取れませんでした。")
        }
    }
}

// Braces inside JSON strings (including escaped quotes) do not end an object.
enum JSONResponse {
    static func firstCompleteObject(in text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        if cleaned.contains("<think>") { return nil }
        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for index in cleaned[start...].indices {
            let character = cleaned[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                if character == "\"" { inString = true }
                else if character == "{" { depth += 1 }
                else if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(cleaned[start...index]) }
                }
            }
        }
        return nil
    }
}

struct Food: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let energy: Double
    let protein: Double
    let fat: Double
    let carbs: Double
    let salt: Double?
    let sourceRow: Int
}

struct FoodPortion: Identifiable {
    let id = UUID()
    var food: Food
    var grams: Double = 100
    var nutrition: Nutrition {
        Nutrition(energy_kcal: food.energy, protein_g: food.protein, fat_g: food.fat,
                  carb_g: food.carbs, salt_g: food.salt ?? 0, basis: "").scaled(by: grams / 100)
    }
}

enum VLMVariant: String, CaseIterable, Identifiable, Codable, Sendable {
    case twoB = "2B", fourB = "4B", eightB = "8B"
    var id: String { rawValue }
    var modelID: String { "mlx-community/Qwen3-VL-\(rawValue)-Instruct-4bit" }
    var folderName: String { "Qwen3-VL-\(rawValue)-Instruct-4bit" }
}

struct AnalysisRun: Codable, Identifiable {
    let id: UUID
    let date: Date
    let modelID: String
    let status: String
    let nutrition: Nutrition?
    let rawResponse: String
    let prompt: String
    let seconds: Double
    let portionMultiplier: Double
    let error: String?
    let generationSettings: String?
    var modelInputFilename: String? = nil
    var analysisMode: AnalysisMode? = nil
    var parseStage: String? = nil
    // Added 2026-10 for the research protocol (all optional so that older records still decode).
    var condition: String? = nil            // "none" or "W" (research protocol only)
    var declaredWeight_g: Double? = nil      // weight typed by the user under the W condition
    var generationSeconds: Double? = nil     // image preprocessing + generation, excluding model loading
    var modelWeightsSHA256: String? = nil    // "file=sha256;..." for every *.safetensors file
    var deviceModel: String? = nil
    var osVersion: String? = nil
    var appVersion: String? = nil
    var libraries: String? = nil

    // Copy with a new portion multiplier, keeping every other field (used when the user changes the
    // portion after analysis; the raw response is never changed).
    func updatingPortion(nutrition: Nutrition?, portionMultiplier: Double) -> AnalysisRun {
        var copy = AnalysisRun(id: id, date: date, modelID: modelID, status: status, nutrition: nutrition,
                               rawResponse: rawResponse, prompt: prompt, seconds: seconds,
                               portionMultiplier: portionMultiplier, error: error,
                               generationSettings: generationSettings, modelInputFilename: modelInputFilename,
                               analysisMode: analysisMode, parseStage: parseStage)
        copy.condition = condition; copy.declaredWeight_g = declaredWeight_g
        copy.generationSeconds = generationSeconds; copy.modelWeightsSHA256 = modelWeightsSHA256
        copy.deviceModel = deviceModel; copy.osVersion = osVersion
        copy.appVersion = appVersion; copy.libraries = libraries
        return copy
    }
}

struct MealRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    var nutrition: Nutrition?
    var rawResponse: String
    var prompt: String
    var modelID: String
    var seconds: Double
    var portionMultiplier: Double
    let imageName: String
    let imageData: Data?
    var imageFilename: String? = nil
    var mealType: String? = nil
    var note: String? = nil
    var analysisStatus: String? = nil
    var analysisError: String? = nil
    var generationSettings: String? = nil
    var sequenceNumber: Int? = nil
    var analyses: [AnalysisRun]? = nil
    var modelInputFilename: String? = nil
    var analysisMode: AnalysisMode? = nil
}

enum RecordStorage {
    static func url() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        return directory.appendingPathComponent("meals.json")
    }
    static func load(from location: URL? = nil) throws -> [MealRecord] {
        let path = try location ?? url()
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try JSONDecoder().decode([MealRecord].self, from: Data(contentsOf: path))
    }
    static func save(_ records: [MealRecord], to location: URL? = nil) throws {
        try JSONEncoder().encode(records).write(to: location ?? url(), options: .atomic)
        if location == nil { try AnalysisLog.write(records) }
    }
    static func photoDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("MealPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func modelInputDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("model_inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func storeModelInput(_ data: Data, sequenceNumber: Int, runID: UUID,
                                at date: Date = Date(), in directory: URL? = nil) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let name = "\(formatter.string(from: date))_\(String(format: "%06d", sequenceNumber))_\(runID.uuidString.prefix(8)).jpg"
        let folder = try directory ?? modelInputDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
    static func storePhoto(_ data: Data, id: UUID, sequenceNumber: Int? = nil, in directory: URL? = nil) throws -> String {
        let name = (sequenceNumber.map { String(format: "%06d_", $0) } ?? "") + id.uuidString + ".jpg"
        let folder = try directory ?? photoDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        return name
    }
    static func photoURL(for record: MealRecord) throws -> URL? {
        guard let filename = record.imageFilename, filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        return try photoDirectory().appendingPathComponent(filename)
    }
    static func photoData(for record: MealRecord) throws -> Data? {
        if let url = try photoURL(for: record) { return try Data(contentsOf: url) }
        return record.imageData
    }
    static func upserting(_ record: MealRecord, into records: [MealRecord]) -> [MealRecord] {
        var updated = records
        if let index = updated.firstIndex(where: { $0.id == record.id }) { updated[index] = record }
        else { updated.insert(record, at: 0) }
        return updated.sorted { $0.date > $1.date }
    }

    static func nextSequence(in records: [MealRecord]) -> Int {
        (records.compactMap(\.sequenceNumber).max() ?? 0) + 1
    }
    static func numbering(_ records: [MealRecord]) -> [MealRecord] {
        var numbered = records
        var next = nextSequence(in: numbered)
        for index in numbered.indices.sorted(by: { numbered[$0].date < numbered[$1].date }) where numbered[index].sequenceNumber == nil {
            numbered[index].sequenceNumber = next
            next += 1
        }
        return numbered
    }
}

enum AnalysisLog {
    struct Row: Codable {
        let photoNumber: Int?
        let photoFilename: String?
        let modelInputFilename: String?
        let recordID: UUID
        let runID: UUID
        let analyzedAt: Date
        let modelID: String
        let status: String
        let nutrition: Nutrition?
        let rawResponse: String
        let prompt: String
        let seconds: Double
        let portionMultiplier: Double
        let error: String?
        let generationSettings: String?
        let analysisMode: AnalysisMode
        let parseStage: String?
        let condition: String?
        let declaredWeight_g: Double?
        let generationSeconds: Double?
        let modelWeightsSHA256: String?
        let deviceModel: String?
        let osVersion: String?
        let appVersion: String?
        let libraries: String?
    }
    static func url() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        return documents.appendingPathComponent("analysis-log.jsonl")
    }
    static func write(_ records: [MealRecord], to location: URL? = nil) throws {
        let rows = records.flatMap { record in
            (record.analyses ?? []).map { run in
                Row(photoNumber: record.sequenceNumber, photoFilename: record.imageFilename,
                    modelInputFilename: run.modelInputFilename.map { "model_inputs/\($0)" }, recordID: record.id, runID: run.id,
                    analyzedAt: run.date, modelID: run.modelID, status: run.status,
                    nutrition: run.nutrition, rawResponse: run.rawResponse, prompt: run.prompt,
                    seconds: run.seconds, portionMultiplier: run.portionMultiplier,
                    error: run.error, generationSettings: run.generationSettings,
                    analysisMode: run.analysisMode ?? .consumer, parseStage: run.parseStage,
                    condition: run.condition, declaredWeight_g: run.declaredWeight_g,
                    generationSeconds: run.generationSeconds, modelWeightsSHA256: run.modelWeightsSHA256,
                    deviceModel: run.deviceModel, osVersion: run.osVersion,
                    appVersion: run.appVersion, libraries: run.libraries)
            }
        }.sorted { $0.analyzedAt < $1.analyzedAt }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let lines = try rows.map { try encoder.encode($0) }
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        try data.write(to: location ?? url(), options: .atomic)
    }
}

enum ResearchExport {
    static func create(records: [MealRecord], in directory: URL? = nil, photoDirectory: URL? = nil) throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = directory ?? documents.appendingPathComponent("ResearchExport", isDirectory: true)
        let photos = folder.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let ordered = records.sorted { ($0.sequenceNumber ?? 0) < ($1.sequenceNumber ?? 0) }
        let header = ["photo_number", "photo_file", "model_input_file", "captured_at", "meal_type", "note",
                      "run_id", "run_at", "model_id", "analysis_mode", "condition", "declared_weight_g", "status",
                      "energy_kcal", "protein_g", "fat_g", "carb_g", "salt_g", "portion_multiplier",
                      "seconds", "generation_seconds", "error"]
        var rows = [header.joined(separator: ",")]
        let stamp = ISO8601DateFormatter()
        for record in ordered {
            let number = String(format: "%06d", record.sequenceNumber ?? 0)
            let photoName = "\(number).jpg"
            let destination = photos.appendingPathComponent(photoName)
            let source = record.imageFilename.map { (photoDirectory ?? (try? RecordStorage.photoDirectory()) ?? documents).appendingPathComponent($0) }
            if let source, FileManager.default.fileExists(atPath: source.path) {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: source, to: destination)
            } else if let data = record.imageData {
                try data.write(to: destination, options: .atomic)
            } else {
                throw NutritionError.invalidImage
            }
            let runs = record.analyses ?? []
            if runs.isEmpty {
                var cells = Array(repeating: "", count: header.count)
                cells[0] = number; cells[1] = "photos/\(photoName)"; cells[3] = stamp.string(from: record.date)
                cells[4] = record.mealType ?? ""; cells[5] = record.note ?? ""; cells[12] = record.analysisStatus ?? "未解析"
                rows.append(row(cells))
            }
            for run in runs {
                let n = run.nutrition
                let cells: [String] = [
                    number, "photos/\(photoName)", run.modelInputFilename.map { "model_inputs/\($0)" } ?? "",
                    stamp.string(from: record.date), record.mealType ?? "", record.note ?? "",
                    run.id.uuidString, stamp.string(from: run.date), run.modelID,
                    (run.analysisMode ?? .consumer).rawValue, run.condition ?? "",
                    run.declaredWeight_g.map { ResearchProtocol.formatGrams($0) } ?? "", run.status,
                    n.map { String($0.energy_kcal) } ?? "", n.map { String($0.protein_g) } ?? "",
                    n.map { String($0.fat_g) } ?? "", n.map { String($0.carb_g) } ?? "",
                    n.map { String($0.salt_g) } ?? "", String(run.portionMultiplier), String(run.seconds),
                    run.generationSeconds.map { String($0) } ?? "", run.error ?? ""]
                assert(cells.count == header.count)
                rows.append(row(cells))
            }
        }
        try (rows.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("results.csv"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ordered).write(to: folder.appendingPathComponent("records.json"), options: .atomic)
        try AnalysisLog.write(ordered, to: folder.appendingPathComponent("analysis-log.jsonl"))
        return folder
    }
    private static func row(_ cells: [String]) -> String {
        cells.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
    }
}

struct BatchItem: Codable {
    let selectionIndex: Int
    let inputName: String
    let sourceSHA256: String?
    let photoNumber: Int?
    let photoFilename: String?
    let modelInputFilename: String?
    let recordID: UUID?
    let analyzedAt: Date?
    let modelID: String
    let analysisMode: AnalysisMode?
    let status: String
    let nutrition: Nutrition?
    let rawResponse: String?
    let prompt: String?
    let seconds: Double?
    let error: String?
    let parseStage: String?
    let condition: String?
    let generationSeconds: Double?

    init(selectionIndex: Int, inputName: String, modelID: String, analysisMode: AnalysisMode = .consumer,
         sourceSHA256: String? = nil,
         record: MealRecord? = nil,
         error: String? = nil) {
        self.selectionIndex = selectionIndex
        self.inputName = inputName
        self.sourceSHA256 = sourceSHA256
        self.modelID = modelID
        self.analysisMode = analysisMode
        photoNumber = record?.sequenceNumber
        photoFilename = record?.imageFilename
        recordID = record?.id
        let run = record?.analyses?.last
        modelInputFilename = run == nil ? record?.modelInputFilename : run?.modelInputFilename
        analyzedAt = run?.date
        status = record?.analysisStatus ?? "読込失敗"
        nutrition = run?.nutrition
        rawResponse = run?.rawResponse
        prompt = run?.prompt
        seconds = run?.seconds
        self.error = error ?? run?.error
        parseStage = run?.parseStage
        condition = run?.condition
        generationSeconds = run?.generationSeconds
    }
}

struct BatchReport: Codable {
    let id: UUID
    let createdAt: Date
    let timeZone: String
    let modelID: String
    let analysisMode: AnalysisMode?
    let sourceFolderName: String?
    let sourceFolderID: String?
    let selectedInputs: [String]?
    let selectedCount: Int
    var items: [BatchItem]
    var completedAt: Date?
    var cancelled: Bool

    init(modelID: String, analysisMode: AnalysisMode = .consumer, selectedCount: Int, sourceFolderName: String? = nil,
         sourceFolderID: String? = nil, selectedInputs: [String]? = nil,
         id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id; self.createdAt = createdAt; self.timeZone = TimeZone.current.identifier
        self.modelID = modelID; self.selectedCount = selectedCount; self.sourceFolderName = sourceFolderName
        self.analysisMode = analysisMode
        self.sourceFolderID = sourceFolderID; self.selectedInputs = selectedInputs
        items = []; completedAt = nil; cancelled = false
    }
    mutating func upsert(_ item: BatchItem) {
        if let index = items.firstIndex(where: { $0.selectionIndex == item.selectionIndex }) { items[index] = item }
        else { items.append(item) }
        items.sort { $0.selectionIndex < $1.selectionIndex }
    }
}

enum BatchExport {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func makeURL(for report: BatchReport, in directory: URL? = nil) throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let folder = directory ?? documents.appendingPathComponent("BatchExports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: report.timeZone) ?? .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let size = VLMVariant.allCases.first { $0.modelID == report.modelID }?.rawValue ?? "unknown"
        let name = "Qwen3-VL-\(size)_\((report.analysisMode ?? .consumer).rawValue)_\(formatter.string(from: report.createdAt))_\(report.id.uuidString.prefix(8)).json"
        return folder.appendingPathComponent(name)
    }
    static func resumable(modelID: String, analysisMode: AnalysisMode = .consumer,
                          sourceFolderID: String, selectedInputs: [String],
                          in directory: URL? = nil) throws -> (BatchReport, URL)? {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let folder = directory ?? documents.appendingPathComponent("BatchExports", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let candidates = urls.compactMap { url -> (BatchReport, URL)? in
            guard let data = try? Data(contentsOf: url),
                  let report = try? decoder.decode(BatchReport.self, from: data),
                  report.modelID == modelID, (report.analysisMode ?? .consumer) == analysisMode,
                  report.sourceFolderID == sourceFolderID,
                  report.selectedInputs == selectedInputs,
                  report.completedAt == nil || report.cancelled else { return nil }
            return (report, url)
        }
        return candidates.max { $0.0.createdAt < $1.0.createdAt }
    }
    static func save(_ report: BatchReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}

struct FolderImage: Sendable {
    let url: URL
    let relativePath: String
}

enum FolderImageLoader {
    static func images(in folder: URL) throws -> [FolderImage] {
        var listingError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in listingError = error; return false }) else {
            throw NutritionError.invalidImage
        }
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        var images: [FolderImage] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
            let ext = url.pathExtension.lowercased()
            let extensionType = UTType(filenameExtension: ext)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let isFile = values?.isRegularFile ?? (exists ? !isDirectory.boolValue : !url.hasDirectoryPath)
            let knownImageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]
            guard isFile,
                  values?.contentType?.conforms(to: .image) == true || extensionType?.conforms(to: .image) == true || knownImageExtensions.contains(ext) else { continue }
            let relative = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            images.append(FolderImage(url: url, relativePath: relative))
        }
        if let listingError { throw listingError }
        return images.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    static func read(_ url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result { try Data(contentsOf: readable) }
        }
        if let result, let data = try? result.get() { return data }
        if let data = try? Data(contentsOf: url) { return data }
        if let coordinationError { throw coordinationError }
        throw NutritionError.invalidImage
    }
}
