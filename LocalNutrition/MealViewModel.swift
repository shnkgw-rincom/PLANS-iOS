import Foundation
import Combine
import UIKit
import PhotosUI
import SwiftUI

@MainActor
final class MealViewModel: ObservableObject {
    @Published var image: UIImage?
    @Published var imageName = ""
    @Published var isBusy = false
    @Published var status = "食事を撮影して記録しましょう"
    @Published var rawResponse = ""
    @Published var result: Nutrition?
    @Published var portionMultiplier = 1.0
    @Published var seconds = 0.0
    @Published var error: String?
    @Published var records: [MealRecord] = []
    @Published var saved = false
    @Published var singleServing = true
    @Published var japanesePersona = false
    // Research protocol only: weight of the food itself (container excluded), typed by the user.
    // Empty = none condition; a valid number = W condition.
    @Published var declaredWeightText = ""
    @Published var analysisMode: AnalysisMode = .consumer {
        didSet { UserDefaults.standard.set(analysisMode.rawValue, forKey: "analysisMode") }
    }
    @Published var foods: [Food] = []
    @Published var portions: [FoodPortion] = []
    @Published var mealType = "昼食"
    @Published var note = ""
    @Published var capturedAt: Date?
    @Published var selectedVariant: VLMVariant = .fourB
    @Published var installedModels: Set<VLMVariant> = []
    @Published var isInstallingModel = false
    @Published var modelInstallStatus = ""
    @Published var batchExportURL: URL?
    @Published var batchProgress = ""
    @Published var batchIsRunning = false
    // Image sets kept inside the app: Documents/images/<set>/ (same layout as the research batch application).
    @Published var imageSets: [String] = []
    @Published var selectedImageSet = ""
    @Published var imageSetLimit = 0        // 0 = all images of the set (file-name order)
    private var imageURL: URL?
    private var currentRecord: MealRecord?
    private var activeVariant: VLMVariant = .fourB
    private var activeMode: AnalysisMode = .consumer
    private var activeParseStage: String?
    private var activeRunID = UUID()
    private var activeModelInputFilename: String?
    private var activeDeclaredWeight: Double?
    private var activeGenerationSeconds: Double?
    private var activeWeightsSHA256: String?
    private let service = VLMService()
    private var task: Task<Void, Never>?
    private(set) var lastPrompt = ""

    init() {
        analysisMode = AnalysisMode(rawValue: UserDefaults.standard.string(forKey: "analysisMode") ?? "") ?? .consumer
        do {
            let loaded = try RecordStorage.load()
            let needsMigration = loaded.contains { $0.sequenceNumber == nil || $0.analyses == nil }
            records = RecordStorage.numbering(loaded).map { record in
                var updated = record
                if updated.analyses == nil {
                    if record.analysisStatus != nil && record.analysisStatus != "未解析" {
                        updated.analyses = [AnalysisRun(id: UUID(), date: record.date, modelID: record.modelID,
                            status: record.analysisStatus ?? "解析済み", nutrition: record.nutrition,
                            rawResponse: record.rawResponse, prompt: record.prompt, seconds: record.seconds,
                            portionMultiplier: record.portionMultiplier, error: record.analysisError,
                            generationSettings: record.generationSettings)]
                    } else { updated.analyses = [] }
                }
                return updated
            }
            if needsMigration { try RecordStorage.save(records) }
            refreshInstalledModels()
            refreshImageSets()
            if let url = Bundle.main.url(forResource: "foods", withExtension: "json") {
                foods = try JSONDecoder().decode([Food].self, from: Data(contentsOf: url))
            }
        } catch { self.error = LF("保存データを読み込めませんでした: %@", error.localizedDescription) }
    }

    var displayedResult: Nutrition? { result?.scaled(by: portionMultiplier) }
    private var declaredWeightTrimmed: String {
        let halfWidth = declaredWeightText.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? declaredWeightText
        return halfWidth.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
    }
    var declaredWeight: Double? {
        guard analysisMode == .research, !declaredWeightTrimmed.isEmpty,
              let grams = Double(declaredWeightTrimmed), grams.isFinite, grams >= 1, grams <= 5000 else { return nil }
        return grams
    }
    var declaredWeightIsInvalid: Bool {
        analysisMode == .research && !declaredWeightTrimmed.isEmpty && declaredWeight == nil
    }

    var prompt: String {
        if analysisMode == .research { return ResearchProtocol.promptText(declaredWeight: declaredWeight) }
        var text = "Estimate nutrition of the food in this image from visual appearance and portion size only. Do not read text or nutrition labels. Return exactly ONE JSON object with these five keys: energy_kcal, protein_g, fat_g, carb_g, salt_g. Quote all keys. All values must be nonnegative numbers, without units. Do not include basis, explanation, markdown, or repeated text. End immediately after the closing brace."
        if singleServing { text += " The image shows exactly one standard single serving for one person (ichinin-ikkai-bun). Estimate the nutritional content of that single serving." }
        if japanesePersona { text = "You are a Japanese registered dietitian (kanri-eiyoshi). You are deeply familiar with standard single-serving portion sizes of everyday Japanese meals. " + text }
        return text
    }

    func selectImage(data: Data, name: String) {
        guard !isBusy else { return }
        do { _ = try storeImage(data: data, name: name) }
        catch { self.error = error.localizedDescription }
    }

    @discardableResult
    private func storeImage(data: Data, name: String) throws -> MealRecord {
            guard let source = UIImage(data: data) else { throw NutritionError.invalidImage }
            let ratio = min(1, 1024 / max(source.size.width, source.size.height))
            let size = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
            // scale 1 and the standard (sRGB, 8-bit) range, so that the model input does not depend on
            // the screen of the device (e.g. Display P3 photographs on recent iPhones and iPads).
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
            let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpg = normalized.jpegData(compressionQuality: 0.88) else { throw NutritionError.invalidImage }
            // Keep a separate full-resolution photograph. Inference uses only the resized copy.
            guard let originalJPEG = source.jpegData(compressionQuality: 0.95) else { throw NutritionError.invalidImage }
            let id = UUID()
            let timestamp = Date()
            let sequenceNumber = RecordStorage.nextSequence(in: records)
            let filename = try RecordStorage.storePhoto(originalJPEG, id: id, sequenceNumber: sequenceNumber)
            let record = MealRecord(id: id, date: timestamp, nutrition: nil, rawResponse: "", prompt: "",
                                    modelID: selectedVariant.modelID, seconds: 0, portionMultiplier: 1,
                                    imageName: name, imageData: nil, imageFilename: filename,
                                    mealType: mealType, note: "", analysisStatus: "未解析",
                                    sequenceNumber: sequenceNumber, analyses: [])
            let updated = RecordStorage.upserting(record, into: records)
            try RecordStorage.save(updated)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("meal-input.jpg")
            try jpg.write(to: url, options: .atomic)
            image = normalized; imageURL = url; imageName = name
            currentRecord = record; records = updated; capturedAt = timestamp; note = ""
            result = nil; rawResponse = ""; error = nil; portionMultiplier = 1; saved = false; seconds = 0
            portions = []; declaredWeightText = ""
            status = "写真と撮影日時を保存しました"
            return record
    }

    func capture(data: Data) {
        selectImage(data: data, name: "食事の撮影")
        if error == nil { analyze() }
    }

    func reopen(_ record: MealRecord) {
        guard !isBusy else { return }
        do { try openRecord(record) }
        catch { self.error = error.localizedDescription }
    }

    private func openRecord(_ record: MealRecord) throws {
            guard let data = try RecordStorage.photoData(for: record), let source = UIImage(data: data) else { throw NutritionError.invalidImage }
            let ratio = min(1, 1024 / max(source.size.width, source.size.height))
            let size = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
            // scale 1 and the standard (sRGB, 8-bit) range, so that the model input does not depend on
            // the screen of the device (e.g. Display P3 photographs on recent iPhones and iPads).
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
            let preview = UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("meal-input.jpg")
            guard let jpg = preview.jpegData(compressionQuality: 0.88) else { throw NutritionError.invalidImage }
            try jpg.write(to: url, options: .atomic)
            image = preview; imageURL = url; imageName = record.imageName
            currentRecord = record; capturedAt = record.date; mealType = record.mealType ?? "昼食"; note = record.note ?? ""
            declaredWeightText = ""
            if record.nutrition != nil, let original = try? Nutrition.parse(record.rawResponse) {
                result = original; portionMultiplier = record.portionMultiplier
            } else { result = record.nutrition; portionMultiplier = 1 }
            seconds = record.seconds
            rawResponse = record.rawResponse; lastPrompt = record.prompt; saved = true; error = record.analysisError
            status = record.analysisStatus ?? "記録を開きました"
    }

    private func persist(status: String? = nil, includeResult: Bool = false) throws {
        guard var record = currentRecord else { return }
        record.mealType = mealType; record.note = note
        if let status { record.analysisStatus = status }
        record.analysisError = error
        if status == "解析中" {
            record.nutrition = nil; record.rawResponse = ""; record.prompt = lastPrompt
            record.generationSettings = activeMode == .research ? VLMService.researchSettings : VLMService.generationSettings
            record.modelID = activeVariant.modelID
            record.modelInputFilename = activeModelInputFilename
            record.analysisMode = activeMode
        }
        if includeResult {
            record.nutrition = displayedResult; record.rawResponse = rawResponse; record.prompt = lastPrompt
            record.seconds = seconds; record.portionMultiplier = portionMultiplier
            if let status {
                record.modelInputFilename = activeModelInputFilename
                var run = AnalysisRun(id: activeRunID, date: Date(), modelID: activeVariant.modelID,
                    status: status, nutrition: displayedResult, rawResponse: rawResponse,
                    prompt: lastPrompt, seconds: seconds, portionMultiplier: portionMultiplier,
                    error: error, generationSettings: activeMode == .research ? VLMService.researchSettings : VLMService.generationSettings,
                    modelInputFilename: activeModelInputFilename, analysisMode: activeMode,
                    parseStage: activeParseStage)
                if activeMode == .research {
                    run.condition = ResearchProtocol.condition(declaredWeight: activeDeclaredWeight)
                    run.declaredWeight_g = activeDeclaredWeight
                }
                run.generationSeconds = activeGenerationSeconds
                run.modelWeightsSHA256 = activeWeightsSHA256
                run.deviceModel = Provenance.deviceModel; run.osVersion = Provenance.osVersion
                run.appVersion = Provenance.appVersion; run.libraries = Provenance.libraries
                record.analyses = (record.analyses ?? []) + [run]
            } else if var runs = record.analyses, !runs.isEmpty {
                let previous = runs.removeLast()
                runs.append(previous.updatingPortion(nutrition: displayedResult, portionMultiplier: portionMultiplier))
                record.analyses = runs
            }
        }
        let updated = RecordStorage.upserting(record, into: records)
        try RecordStorage.save(updated); currentRecord = record; records = updated
    }

    func analyze() {
        guard let imageURL, !isBusy else { return }
        guard installedModels.contains(selectedVariant) else { error = NutritionError.missingModel.localizedDescription; return }
        guard !declaredWeightIsInvalid else { error = "重さは 1〜5000 g の数値で入力してください。"; return }
        let variant = selectedVariant
        let mode = analysisMode
        let weight = declaredWeight
        let requestPrompt = prompt
        isBusy = true
        task = Task {
            defer { isBusy = false; task = nil }
            await analyzeCurrent(imageURL: imageURL, variant: variant, mode: mode, requestPrompt: requestPrompt,
                                 declaredWeight: weight)
        }
    }

    private func analyzeCurrent(imageURL: URL, variant: VLMVariant, mode: AnalysisMode, requestPrompt: String,
                                declaredWeight: Double? = nil) async {
        activeVariant = variant
        activeMode = mode
        activeDeclaredWeight = mode == .research ? declaredWeight : nil
        activeGenerationSeconds = nil
        activeParseStage = nil
        activeRunID = UUID()
        activeModelInputFilename = nil
        result = nil; rawResponse = ""; error = nil; saved = false; portionMultiplier = 1
        lastPrompt = requestPrompt
        let start = Date()
        do {
            try Task.checkCancellation()
            guard let sequenceNumber = currentRecord?.sequenceNumber else { throw NutritionError.invalidImage }
            let bytes = try Data(contentsOf: imageURL)
            let persistedInput = try RecordStorage.storeModelInput(bytes, sequenceNumber: sequenceNumber,
                                                                    runID: activeRunID)
            activeModelInputFilename = persistedInput.lastPathComponent
            try persist(status: "解析中")
            status = "モデルを読み込んでいます…"
            try await service.load(variant)
            activeWeightsSHA256 = await service.weightsSHA256(for: variant)
            try Task.checkCancellation()
            status = "端末内で食事を解析しています…"
            activeGenerationSeconds = try await service.generate(imageURL: persistedInput, prompt: requestPrompt,
                                                                 variant: variant, mode: mode) { [weak self] response in
                await self?.updateResponse(response)
            }
            seconds = Date().timeIntervalSince(start)
            if mode == .research {
                activeParseStage = "fail"
                let parsed = try Nutrition.parseResearch(rawResponse)
                result = parsed.nutrition
                activeParseStage = parsed.stage
            } else {
                result = try Nutrition.parse(rawResponse)
            }
            try persist(status: "解析済み", includeResult: true)
            saved = true
            status = LF("解析完了（%ld秒）", Int(seconds))
        } catch is CancellationError {
            seconds = Date().timeIntervalSince(start)
            result = nil; status = "解析を中止しました"
            do { try persist(status: "解析中止", includeResult: true) } catch { self.error = error.localizedDescription }
        } catch {
            seconds = Date().timeIntervalSince(start)
            self.error = error.localizedDescription; status = "解析できませんでした"
            result = nil
            do { try persist(status: "解析失敗", includeResult: true) } catch { self.error = LF("記録の更新に失敗しました: %@", error.localizedDescription) }
        }
    }
    private func updateResponse(_ response: String) { rawResponse = response }
    func cancel() { status = "中止しています…"; task?.cancel() }

    func analyzeBatchPhotos(_ items: [PhotosPickerItem]) {
        let names = items.indices.map { String(format: "写真ライブラリ_%02d", $0 + 1) }
        startBatch(names: names) { index in
            guard let data = try await items[index].loadTransferable(type: Data.self) else {
                throw NutritionError.invalidImage
            }
            return data
        }
    }

    func analyzeBatchFiles(_ urls: [URL]) {
        startBatch(names: urls.map(\.lastPathComponent)) { index in
            let url = urls[index]
            return try await Task.detached(priority: .utility) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try FolderImageLoader.read(url)
            }.value
        }
    }

    func analyzeFolder(_ folder: URL) {
        guard !isBusy && !isInstallingModel else { return }
        guard installedModels.contains(selectedVariant) else { error = NutritionError.missingModel.localizedDescription; return }
        let scoped = folder.startAccessingSecurityScopedResource()
        isBusy = true; batchIsRunning = true; batchProgress = "フォルダ内の画像を探しています…"
        task = Task {
            do {
                let images = try await Task.detached(priority: .utility) {
                    try FolderImageLoader.images(in: folder)
                }.value
                try Task.checkCancellation()
                isBusy = false; batchIsRunning = false; task = nil
                let sourceID = BatchExport.sha256(Data(folder.standardizedFileURL.path.utf8))
                let started = startBatch(names: images.map(\.relativePath),
                                         sourceFolderName: folder.lastPathComponent, sourceFolderID: sourceID,
                                         onFinish: { if scoped { folder.stopAccessingSecurityScopedResource() } }) { index in
                    let url = images[index].url
                    return try await Task.detached(priority: .utility) {
                        try FolderImageLoader.read(url)
                    }.value
                }
                if !started && scoped { folder.stopAccessingSecurityScopedResource() }
            } catch {
                if scoped { folder.stopAccessingSecurityScopedResource() }
                isBusy = false; batchIsRunning = false; task = nil
                if !(error is CancellationError) { self.error = LF("フォルダを読み取れませんでした: %@", error.localizedDescription) }
            }
        }
    }

    @discardableResult
    private func startBatch(names: [String], sourceFolderName: String? = nil, sourceFolderID: String? = nil,
                            onFinish: @escaping @MainActor () -> Void = {},
                            load: @escaping @MainActor (Int) async throws -> Data) -> Bool {
        guard !isBusy && !isInstallingModel else { return false }
        guard !names.isEmpty else { error = "選択した場所に解析できる画像がありません。"; return false }
        guard installedModels.contains(selectedVariant) else { error = NutritionError.missingModel.localizedDescription; return false }
        let variant = selectedVariant
        let mode = analysisMode
        // Batch analysis is always the none condition in research mode: a typed weight belongs to one photo.
        let requestPrompt = mode == .research ? ResearchProtocol.prompt : prompt
        batchExportURL = nil; batchIsRunning = true; isBusy = true
        batchProgress = LF("0 / %ld 枚", names.count)
        task = Task {
            defer { onFinish(); isBusy = false; batchIsRunning = false; task = nil }
            var report: BatchReport
            let url: URL
            do {
                if let sourceFolderID,
                   let previous = try BatchExport.resumable(modelID: variant.modelID, analysisMode: mode,
                                                            sourceFolderID: sourceFolderID,
                                                            selectedInputs: names) {
                    report = previous.0
                    report.cancelled = false; report.completedAt = nil
                    url = previous.1
                } else {
                    report = BatchReport(modelID: variant.modelID, analysisMode: mode, selectedCount: names.count,
                                         sourceFolderName: sourceFolderName, sourceFolderID: sourceFolderID,
                                         selectedInputs: sourceFolderID == nil ? nil : names)
                    url = try BatchExport.makeURL(for: report)
                }
                try BatchExport.save(report, to: url)
                batchExportURL = url
            } catch {
                self.error = LF("一括結果の保存先を作れませんでした: %@", error.localizedDescription)
                return
            }
            let unfinishedStatuses: Set<String> = ["未解析", "解析中", "解析中止"]
            let processed = Set(report.items.filter { !unfinishedStatuses.contains($0.status) }.map(\.selectionIndex))
            batchProgress = LF("%ld / %ld 枚が完了（続きから実行）", processed.count, names.count)
            for index in names.indices {
                if processed.contains(index + 1) { continue }
                if Task.isCancelled { report.cancelled = true; break }
                batchProgress = LF("%ld / %ld 枚を解析中", index + 1, names.count)
                do {
                    let unfinished = report.items.first { $0.selectionIndex == index + 1 }
                    let record: MealRecord
                    let sourceSHA256: String?
                    if let unfinished, let recordID = unfinished.recordID,
                       let existing = records.first(where: { $0.id == recordID }) {
                        try openRecord(existing)
                        record = existing
                        sourceSHA256 = unfinished.sourceSHA256
                    } else {
                        let data = try await load(index)
                        try Task.checkCancellation()
                        sourceSHA256 = BatchExport.sha256(data)
                        record = try storeImage(data: data, name: names[index])
                        report.upsert(BatchItem(selectionIndex: index + 1, inputName: names[index],
                                                modelID: variant.modelID, analysisMode: mode, sourceSHA256: sourceSHA256,
                                                record: record))
                        try BatchExport.save(report, to: url)
                    }
                    guard let inputURL = imageURL else { throw NutritionError.invalidImage }
                    await analyzeCurrent(imageURL: inputURL, variant: variant, mode: mode, requestPrompt: requestPrompt)
                    let latest = records.first(where: { $0.id == record.id }) ?? record
                    report.upsert(BatchItem(selectionIndex: index + 1, inputName: names[index],
                                            modelID: variant.modelID, analysisMode: mode, sourceSHA256: sourceSHA256,
                                            record: latest, error: self.error))
                    self.error = nil
                } catch is CancellationError {
                    report.cancelled = true
                    break
                } catch {
                    report.upsert(BatchItem(selectionIndex: index + 1, inputName: names[index],
                                            modelID: variant.modelID, analysisMode: mode, error: error.localizedDescription))
                }
                do { try BatchExport.save(report, to: url) }
                catch {
                    self.error = LF("一括結果を保存できませんでした: %@", error.localizedDescription)
                    report.cancelled = true
                    break
                }
                batchProgress = LF("%ld / %ld 枚が完了", report.items.count, names.count)
            }
            report.completedAt = Date()
            do { try BatchExport.save(report, to: url) }
            catch { self.error = LF("一括結果を保存できませんでした: %@", error.localizedDescription) }
            let success = report.items.filter { $0.status == "解析済み" }.count
            batchProgress = LF("%ld / %ld 枚を処理、成功 %ld 枚", report.items.count, names.count, success)
            status = report.cancelled ? "一括解析を中止しました。完了分のJSONは保存済みです。" : "一括解析が完了しました。"
        }
        return true
    }

    func save() {
        guard currentRecord != nil, !isBusy else { return }
        if let result = displayedResult, !result.isValid { return }
        do {
            try persist(includeResult: result != nil); saved = true; status = "食事の記録を更新しました"
        } catch { self.error = LF("保存できませんでした: %@", error.localizedDescription) }
    }
    func exportURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nutrition-records.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: url, options: .atomic)
        return url
    }
    func exportResearch() throws -> URL { try ResearchExport.create(records: records) }
    static func imageSetsDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func refreshImageSets() {
        guard let directory = try? Self.imageSetsDirectory(),
              let names = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles]) else { imageSets = []; return }
        imageSets = names.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if !imageSets.contains(selectedImageSet) { selectedImageSet = imageSets.first ?? "" }
    }

    // Batch analysis of Documents/images/<set>/ (subfolders included), first `imageSetLimit` images in
    // file-name order (0 = all). No file picker or security-scoped access is needed for these folders.
    func analyzeImageSet() {
        guard !isBusy && !isInstallingModel else { return }
        guard !selectedImageSet.isEmpty, let root = try? Self.imageSetsDirectory() else {
            error = "images フォルダに画像セットがありません。"; return
        }
        let folder = root.appendingPathComponent(selectedImageSet, isDirectory: true)
        do {
            var images = try FolderImageLoader.images(in: folder)
            if imageSetLimit > 0 { images = Array(images.prefix(imageSetLimit)) }
            let sourceID = BatchExport.sha256(Data("images/\(selectedImageSet)".utf8))
            startBatch(names: images.map(\.relativePath), sourceFolderName: selectedImageSet,
                       sourceFolderID: sourceID) { index in
                let url = images[index].url
                return try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
            }
        } catch {
            self.error = LF("画像セットを読み取れませんでした: %@", error.localizedDescription)
        }
    }

    func refreshInstalledModels() {
        installedModels = Set(VLMVariant.allCases.filter { (try? ModelStore.url(for: $0)) != nil })
    }
    func installModel(from url: URL, as variant: VLMVariant) {
        guard !isInstallingModel && !isBusy else { return }
        isInstallingModel = true; modelInstallStatus = LF("%@モデルをコピーしています…", variant.rawValue)
        Task {
            do {
                try await Task.detached {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try ModelStore.install(from: url, as: variant)
                }.value
                refreshInstalledModels()
                modelInstallStatus = LF("%@モデルを追加しました", variant.rawValue)
            } catch {
                modelInstallStatus = ""
                self.error = LF("モデルを追加できませんでした: %@", error.localizedDescription)
            }
            isInstallingModel = false
        }
    }
}
