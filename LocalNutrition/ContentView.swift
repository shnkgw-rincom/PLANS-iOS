import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import ImageIO

struct ContentView: View {
    @StateObject private var model = MealViewModel()
    @State private var photo: PhotosPickerItem?
    @State private var batchPhotos: [PhotosPickerItem] = []
    // One file importer for all four purposes: SwiftUI presents only one of several
    // .fileImporter modifiers attached to the same view, so the others silently did nothing.
    private enum ImportTarget { case image, batchFiles, batchFolder, modelFolder }
    @State private var importTarget: ImportTarget = .image
    @State private var showImporter = false
    @State private var showHistory = false
    @State private var showFoodSearch = false
    @State private var showCamera = false
    @State private var search = ""
    @State private var exportURL: URL?
    @State private var researchExportURL: URL?
    // In-app language switch (see Localization.swift). Reading it in `body` re-renders the screen when it changes.
    @AppStorage(AppLanguage.storageKey) private var uiLanguage = ""
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let green = Color(red: 0.12, green: 0.38, blue: 0.30)

    private var isJapaneseUI: Bool {
        uiLanguage == "ja" || (uiLanguage != "en" && AppLanguage.deviceIsJapanese)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("食事を撮って、栄養を知る。")).font(sizeClass == .compact ? .title.bold() : .largeTitle.bold())
                            Text(L("写真の解析も、食事の記録も、この端末の中で。"))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "leaf.circle.fill").font(.system(size: sizeClass == .compact ? 32 : 48)).foregroundStyle(green)
                    }
                    if sizeClass == .compact {
                        VStack(spacing: 24) { imagePanel; analysisPanel }
                    } else {
                      ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 24) {
                            imagePanel.frame(minWidth: 300, maxWidth: .infinity)
                            analysisPanel.frame(minWidth: 310, maxWidth: .infinity)
                        }
                        VStack(spacing: 24) { imagePanel; analysisPanel }
                      }
                    }
                    batchPanel
                    DisclosureGroup(L("食品成分表から計算する")) { calculator.padding(.top, 12) }
                    Text(L("写真からの値は概算です。食材の重量や油・調味料は写真だけでは確定できません。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(sizeClass == .compact ? 16 : 28).frame(maxWidth: 1150)
            }
            .frame(maxWidth: .infinity).background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Local Nutrition").navigationBarTitleDisplayMode(.inline)
            // Dates and numbers follow the language chosen with the switch.
            .environment(\.locale, Locale(identifier: isJapaneseUI ? "ja_JP" : "en_US"))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        uiLanguage = isJapaneseUI ? "en" : "ja"
                    } label: {
                        Text(verbatim: isJapaneseUI ? "English" : "日本語")
                    }
                    Button { showHistory = true } label: { Label(L("記録"), systemImage: "clock") }
                }
            }
            .sheet(isPresented: $showHistory) { history }
            .sheet(isPresented: $showFoodSearch) { foodPicker }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(onPhoto: { data in model.capture(data: data); showCamera = false },
                             onError: { model.error = $0; showCamera = false })
                    .ignoresSafeArea()
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: (importTarget == .image || importTarget == .batchFiles) ? [.image] : [.folder],
                          allowsMultipleSelection: importTarget == .batchFiles) { result in
                handleImport(result)
            }
            .onChange(of: photo) { _, value in
                Task {
                    do {
                        guard let data = try await value?.loadTransferable(type: Data.self) else { return }
                        model.selectImage(data: data, name: "写真ライブラリ")
                    } catch { model.error = error.localizedDescription }
                }
            }
            .onChange(of: batchPhotos) { _, items in
                guard !items.isEmpty else { return }
                model.analyzeBatchPhotos(items)
                batchPhotos = []
            }
            .alert(L("確認"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button(L("閉じる"), role: .cancel) { model.error = nil }
            } message: { Text(L(model.error ?? "")) }
        }.tint(green)
    }

    private var imagePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("1  食事の写真")).font(.title3.bold())
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(green.opacity(0.06))
                if let image = model.image {
                    Image(uiImage: image).resizable().scaledToFit().padding(8)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "fork.knife.circle").font(.system(size: 64)).foregroundStyle(green)
                        Text(L("食事全体が写るように撮影してください")).foregroundStyle(.secondary)
                    }
                }
            }.frame(height: 290).clipShape(RoundedRectangle(cornerRadius: 20))
            if !model.imageName.isEmpty { Text(L(model.imageName)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let number = model.records.first(where: { $0.date == model.capturedAt })?.sequenceNumber {
                Text(LF("写真番号 #%@", String(format: "%06d", number))).font(.subheadline.monospacedDigit()).foregroundStyle(green)
            }
            Button {
                Task {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        model.error = "この端末ではカメラを使用できません。"; return
                    }
                    let access = await AVCaptureDevice.requestAccess(for: .video)
                    if access { showCamera = true }
                    else { model.error = "設定アプリでLocal Nutritionのカメラへのアクセスを許可してください。" }
                }
            } label: {
                Label(L(model.image == nil ? "食事を撮影して記録" : "次の食事を撮影"), systemImage: "camera.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.borderedProminent).disabled(model.isBusy)
            Text(L("撮影した写真と日時は自動保存され、栄養を解析します。"))
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L("保存済みの写真を使う")) {
                HStack {
                    PhotosPicker(selection: $photo, matching: .images) { Label(L("写真"), systemImage: "photo") }
                    Button { presentImporter(.image) } label: { Label(L("ファイル"), systemImage: "folder") }
                }.buttonStyle(.bordered).disabled(model.isBusy).padding(.top, 8)
            }
            if let capturedAt = model.capturedAt {
                Divider()
                Label(L("写真を保存済み"), systemImage: "checkmark.circle.fill").foregroundStyle(green)
                Text(capturedAt, format: .dateTime.year().month().day().hour().minute()).font(.subheadline)
                Picker(L("食事"), selection: $model.mealType) {
                    ForEach(["朝食", "昼食", "夕食", "間食"], id: \.self) { Text(L($0)).tag($0) }
                }.pickerStyle(.segmented).disabled(model.isBusy)
                TextField(L("料理名やメモ"), text: $model.note, axis: .vertical)
                    .textFieldStyle(.roundedBorder).disabled(model.isBusy)
                Button(L("食事区分・メモ・分量の変更を保存")) { model.save() }
                    .buttonStyle(.bordered).disabled(model.isBusy)
                Text(L("解析に失敗しても写真は記録に残ります。")) .font(.caption).foregroundStyle(.secondary)
            }
        }.card(compact: sizeClass == .compact)
    }

    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("2  端末内で栄養を推定")).font(.title3.bold())
            Picker(L("解析モデル"), selection: $model.selectedVariant) {
                ForEach(VLMVariant.allCases) { variant in
                    Text(variant.rawValue).tag(variant)
                }
            }.pickerStyle(.segmented).disabled(model.isBusy || model.isInstallingModel)
            if model.installedModels.contains(model.selectedVariant) {
                Label(LF("Qwen3-VL %@ · 端末内で利用可能", model.selectedVariant.rawValue), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(green)
            }
            if !model.installedModels.contains(model.selectedVariant) {
                Button { presentImporter(.modelFolder) } label: { Label(LF("%@モデルのフォルダを追加", model.selectedVariant.rawValue), systemImage: "folder.badge.plus") }
                    .buttonStyle(.bordered).disabled(model.isInstallingModel)
                Text(LF("端末の「ファイル」でQwen3-VL-%@-Instruct-4bitフォルダを選択してください。", model.selectedVariant.rawValue))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L("追加済みモデルを再確認")) { model.refreshInstalledModels() }
                .font(.caption).disabled(model.isBusy || model.isInstallingModel)
            if model.isInstallingModel { ProgressView(L(model.modelInstallStatus)) }
            else if !model.modelInstallStatus.isEmpty { Text(L(model.modelInstallStatus)).font(.caption).foregroundStyle(green) }
            if model.selectedVariant == .eightB {
                Text(L("8Bは約5.4GBのモデルです。端末の空き容量とメモリにより解析できない場合があります。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker(L("解析モード"), selection: $model.analysisMode) {
                ForEach(AnalysisMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented).disabled(model.isBusy)
            if model.analysisMode == .research {
                Text(L("論文の研究プロトコル（L0）で解析します。重さが空欄なら none 条件、入力すると W 条件（重量の一文を付加）です。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(L("料理だけの重さ"))
                    TextField(L("任意"), text: $model.declaredWeightText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    Text("g")
                }.disabled(model.isBusy)
                Text(L("器や容器の重さは含めないでください。器ごと量る場合は、先に器だけを量って差し引きます。一括解析では重さは使いません。"))
                    .font(.caption).foregroundStyle(.secondary)
                if model.declaredWeightIsInvalid {
                    Text(L("重さは 1〜5000 g の数値で入力してください。")).font(.caption).foregroundStyle(.red)
                }
            }
            DisclosureGroup(L("推定の条件")) {
                VStack(alignment: .leading) {
                    Toggle(L("写真を1人分とみなす"), isOn: $model.singleServing).disabled(model.analysisMode == .research)
                    Toggle(L("日本の標準的な食事を想定"), isOn: $model.japanesePersona).disabled(model.analysisMode == .research)
                    Text(L("条件を変えた場合は再解析してください。分量は結果の倍率で調整できます。"))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8).disabled(model.isBusy)
            }
            HStack {
                Button { model.analyze() } label: { Label(L("栄養を再解析"), systemImage: "sparkles").frame(maxWidth: .infinity).padding(.vertical, 7) }
                    .buttonStyle(.borderedProminent).disabled(model.image == nil || model.isBusy || model.isInstallingModel || !model.installedModels.contains(model.selectedVariant))
                if model.isBusy { Button(L("中止")) { model.cancel() }.buttonStyle(.bordered) }
            }
            HStack {
                if model.isBusy { ProgressView() }
                Text(L(model.status)).font(.subheadline).foregroundStyle(.secondary)
            }
            if let result = model.displayedResult {
                Divider()
                Text(L("AI推定値")).font(.headline)
                nutrientGrid(result)
                if !result.basis.isEmpty { Text(result.basis).font(.subheadline).foregroundStyle(.secondary) }
                if sizeClass == .compact {
                    VStack(alignment: .leading, spacing: 8) { Text(L("食べる分量")); portionPicker }
                } else {
                    HStack { Text(L("食べる分量")); portionPicker }
                }
                Button(L(model.saved ? "栄養値を保存済み" : "分量の変更を保存")) { model.save() }
                    .buttonStyle(.bordered).disabled(model.saved || model.isBusy)
            }
            if !model.rawResponse.isEmpty {
                DisclosureGroup(L("AIの応答を確認")) {
                    Text(model.rawResponse).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            }
        }.card(compact: sizeClass == .compact)
    }

    private func presentImporter(_ target: ImportTarget) {
        importTarget = target
        showImporter = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let first = urls.first else { return }
            switch importTarget {
            case .image:
                let allowed = first.startAccessingSecurityScopedResource()
                defer { if allowed { first.stopAccessingSecurityScopedResource() } }
                model.selectImage(data: try Data(contentsOf: first), name: first.lastPathComponent)
            case .batchFiles:
                model.analyzeBatchFiles(urls)
            case .batchFolder:
                model.analyzeFolder(first)
            case .modelFolder:
                model.installModel(from: first, as: model.selectedVariant)
            }
        } catch {
            model.error = error.localizedDescription
        }
    }

    private var batchPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("3  フォルダの画像を一括解析")).font(.title3.bold())
            VStack(alignment: .leading, spacing: 10) {
                Text(L("端末内の画像セット")).font(.headline)
                Text(L("ファイルアプリの「このiPad内（iPhoneでは「このiPhone内」）› Local Nutrition › images」に置いたフォルダが一覧に出ます。数枚だけ試すときは、画像をコピーした新しいフォルダを images の中に作ってください。"))
                    .font(.caption).foregroundStyle(.secondary)
                if model.imageSets.isEmpty {
                    Text(L("images フォルダに画像セット（サブフォルダ）がありません。")).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Picker(L("画像セット"), selection: $model.selectedImageSet) {
                        ForEach(model.imageSets, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper(model.imageSetLimit == 0 ? L("枚数: 全部") : LF("枚数: 先頭 %ld 枚", model.imageSetLimit),
                            value: $model.imageSetLimit, in: 0...5000, step: 5)
                    Button { model.analyzeImageSet() } label: {
                        Label(L("このセットを一括解析"), systemImage: "play.circle")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.isInstallingModel || !model.installedModels.contains(model.selectedVariant))
                }
                Button(L("セット一覧を更新")) { model.refreshImageSets() }.font(.caption).disabled(model.isBusy)
            }
            Divider()
            Text(L("ほかの場所（iCloud Drive など）から選ぶ")).font(.headline)
            Text(LF("iCloud Driveなどのフォルダ内の画像を、選択中の%@モデルで順番に解析します。サブフォルダ内も対象です。", model.selectedVariant.rawValue))
                .font(.subheadline).foregroundStyle(.secondary)
            Button { presentImporter(.batchFolder) } label: {
                Label(L("画像フォルダを選ぶ"), systemImage: "folder")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.isInstallingModel || !model.installedModels.contains(model.selectedVariant))
            VStack(alignment: .leading, spacing: 12) {
                PhotosPicker(selection: $batchPhotos, matching: .images) {
                    Label(L("写真を複数選ぶ"), systemImage: "photo.on.rectangle")
                }
                Button { presentImporter(.batchFiles) } label: { Label(L("画像ファイルを複数選ぶ"), systemImage: "doc.on.doc") }
            }.buttonStyle(.bordered)
                .disabled(model.isBusy || model.isInstallingModel || !model.installedModels.contains(model.selectedVariant))
            if model.batchIsRunning {
                ProgressView(L(model.batchProgress))
                Button(L("一括解析を中止")) { model.cancel() }.buttonStyle(.bordered)
            } else if !model.batchProgress.isEmpty {
                Text(L(model.batchProgress)).font(.subheadline).foregroundStyle(.secondary)
            }
            if let url = model.batchExportURL {
                Text(LF("結果: %@", url.lastPathComponent)).font(.caption.monospaced()).textSelection(.enabled)
                if !model.batchIsRunning {
                    ShareLink(item: url) { Label(L("結果JSONを共有・iCloud Driveに保存"), systemImage: "square.and.arrow.up") }
                }
            }
            Text(L("JSONは1枚ごとに更新されます。同じフォルダを選び直すと未完了分から再開できます。長時間の解析中はアプリを開いたままにしてください。"))
                .font(.caption).foregroundStyle(.secondary)
        }.card(compact: sizeClass == .compact)
    }

    private var portionPicker: some View {
        Picker(L("食べる分量"), selection: $model.portionMultiplier) {
            Text(L("半分")).tag(0.5); Text(L("全部")).tag(1.0); Text(L("1.5倍")).tag(1.5); Text(L("2倍")).tag(2.0)
        }.pickerStyle(.segmented)
            .onChange(of: model.portionMultiplier) { _, _ in model.saved = false }
    }

    private func nutrientGrid(_ result: Nutrition, saltKnown: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(result.energy_kcal, format: .number.precision(.fractionLength(0))).font(.system(size: 46, weight: .bold, design: .rounded))
                Text("kcal").foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), alignment: .leading)], alignment: .leading, spacing: 14) {
                metric(L("たんぱく質"), result.protein_g, .orange)
                metric(L("脂質"), result.fat_g, .pink)
                metric(L("炭水化物"), result.carb_g, .blue)
                if saltKnown { metric(L("食塩相当量"), result.salt_g, .purple) }
                else { VStack(alignment: .leading) { Text(L("食塩相当量")).font(.caption); Text(L("データ不足")).font(.headline) } }
            }
        }
    }
    private func metric(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("\(value, specifier: "%.1f") g").font(.title3.bold()).foregroundStyle(color)
        }
    }

    private var calculator: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("食品成分表で計算")).font(.title3.bold())
                    Text(L("食品と可食部の重さを入力して、AI推定値と比べられます。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Button { showFoodSearch = true } label: { Label(L("食品を追加"), systemImage: "plus") }
            }
            ForEach($model.portions) { $portion in
                HStack {
                    Text(portion.food.name).frame(maxWidth: .infinity, alignment: .leading)
                    TextField(L("重さ"), value: $portion.grams, format: .number)
                        .keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 85)
                    Text("g")
                    Button(role: .destructive) { model.portions.removeAll { $0.id == portion.id } } label: { Image(systemName: "minus.circle") }
                }
            }
            if !model.portions.isEmpty {
                if model.portions.allSatisfy({ $0.grams.isFinite && $0.grams > 0 && $0.grams <= 10000 }) {
                    let total = model.portions.reduce(Nutrition.zero) { a, p in
                        let n = p.nutrition
                        return Nutrition(energy_kcal: a.energy_kcal + n.energy_kcal, protein_g: a.protein_g + n.protein_g,
                                         fat_g: a.fat_g + n.fat_g, carb_g: a.carb_g + n.carb_g, salt_g: a.salt_g + n.salt_g, basis: "")
                    }
                    Divider(); nutrientGrid(total, saltKnown: model.portions.allSatisfy { $0.food.salt != nil })
                } else { Text(L("重さを0より大きい10,000g以下の数値で入力してください。")) .foregroundStyle(.red) }
            }
            Link(L("出典：日本食品標準成分表（八訂）増補2023年（2026年3月訂正反映）"),
                 destination: URL(string: "https://www.mext.go.jp/a_menu/syokuhinseibun/mext_00001.html")!)
                .font(.caption)
            Text(L("成分値は可食部100g当たり。Tr（微量）は計算上0、括弧付きの推定値は数値として使用しています。"))
                .font(.caption).foregroundStyle(.secondary)
        }.card(compact: sizeClass == .compact)
    }

    private var foodPicker: some View {
        NavigationStack {
            List(model.foods.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.prefix(100)) { food in
                Button {
                    model.portions.append(FoodPortion(food: food)); showFoodSearch = false
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(food.name)
                        Text(LF("%@ kcal / 100g · 食品番号 %@", String(format: "%.0f", food.energy), "\(food.id)")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.searchable(text: $search, prompt: L("ご飯、鶏、豆腐など"))
                .navigationTitle(LF("食品を検索（%ld件）", model.foods.count))
                .toolbar { Button(L("閉じる")) { showFoodSearch = false } }
        }
    }
    private var history: some View {
        NavigationStack {
            List {
                Section {
                    Button { do { researchExportURL = try model.exportResearch() } catch { model.error = error.localizedDescription } } label: {
                        Label(L("解析用データを書き出す"), systemImage: "square.and.arrow.up.on.square")
                    }
                    if let folder = researchExportURL {
                        Text(L("「ファイル」アプリ → このiPhone / iPad内 → Local Nutrition → ResearchExport に、番号付き写真、results.csv、records.jsonを保存しました。"))
                            .font(.caption).foregroundStyle(.secondary)
                        ShareLink(item: folder.appendingPathComponent("results.csv")) { Label(L("結果CSVを共有"), systemImage: "tablecells") }
                        ShareLink(item: folder.appendingPathComponent("records.json")) { Label(L("詳細JSONを共有"), systemImage: "curlybraces") }
                    }
                    if let logURL = try? AnalysisLog.url(), FileManager.default.fileExists(atPath: logURL.path) {
                        ShareLink(item: logURL) { Label(L("解析ログJSONLを共有"), systemImage: "doc.text") }
                    }
                }
                if model.records.isEmpty { Text(L("保存した食事がここに表示されます。")) }
                ForEach(model.records) { record in
                    NavigationLink {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                if let image = storedImage(record) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 350) }
                                Text(record.date, format: .dateTime.year().month().day().hour().minute())
                                if let number = record.sequenceNumber { Text(LF("写真番号 #%@", String(format: "%06d", number))).font(.headline.monospacedDigit()) }
                                Text(L(record.mealType ?? "食事")).font(.title3.bold())
                                if let note = record.note, !note.isEmpty { Text(note) }
                                Label(L(record.analysisStatus ?? "解析済み"), systemImage: record.nutrition == nil ? "photo" : "checkmark.circle")
                                if let nutrition = record.nutrition {
                                    nutrientGrid(nutrition)
                                    if !nutrition.basis.isEmpty { Text(nutrition.basis) }
                                } else { Text(L("写真は保存されています。栄養値はまだありません。")) .foregroundStyle(.secondary) }
                                if let error = record.analysisError { Text(error).font(.subheadline).foregroundStyle(.secondary) }
                                Button(L("この記録を開いて編集・再解析")) { model.reopen(record); showHistory = false }
                                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
                                if let url = try? RecordStorage.photoURL(for: record) {
                                    ShareLink(item: url) { Label(L("元の写真を書き出す"), systemImage: "square.and.arrow.up") }
                                }
                                Text(record.modelID).font(.caption).foregroundStyle(.secondary)
                                if let input = record.modelInputFilename {
                                    Text(LF("モデル入力: model_inputs/%@", input)).font(.caption.monospaced()).textSelection(.enabled)
                                    if let folder = try? RecordStorage.modelInputDirectory() {
                                        let inputURL = folder.appendingPathComponent(input)
                                        if FileManager.default.fileExists(atPath: inputURL.path) {
                                            ShareLink(item: inputURL) { Label(L("モデル入力JPEGを書き出す"), systemImage: "square.and.arrow.up") }
                                        }
                                    }
                                }
                                Text(LF("解析時間：%@秒、分量倍率：%@", String(format: "%.1f", record.seconds), String(format: "%.1f", record.portionMultiplier)))
                                DisclosureGroup(L("プロンプトと生の応答")) { Text(record.prompt + "\n\n" + record.rawResponse).font(.caption).textSelection(.enabled) }
                                if let settings = record.generationSettings { Text(settings).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                if let runs = record.analyses, !runs.isEmpty {
                                    Divider()
                                    Text(L("モデル別の解析履歴")).font(.headline)
                                    ForEach(runs) { run in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text("\(VLMVariant.allCases.first(where: { run.modelID.contains("-\($0.rawValue)-") })?.rawValue ?? run.modelID) · \(L(run.status))").font(.subheadline.bold())
                                            Text(run.date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                            if let value = run.nutrition { Text("\(value.energy_kcal, specifier: "%.0f") kcal · P \(value.protein_g, specifier: "%.1f") g · F \(value.fat_g, specifier: "%.1f") g · C \(value.carb_g, specifier: "%.1f") g") }
                                            if let input = run.modelInputFilename { Text("model_inputs/\(input)").font(.caption.monospaced()).textSelection(.enabled) }
                                            if let error = run.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                            }.padding()
                        }.navigationTitle(L("食事の記録"))
                    } label: {
                        HStack {
                            if let image = storedThumbnail(record) { Image(uiImage: image).resizable().scaledToFit().frame(width: 65, height: 55) }
                            VStack(alignment: .leading) {
                                if let number = record.sequenceNumber { Text("#\(String(format: "%06d", number))").font(.caption.monospacedDigit()).foregroundStyle(green) }
                                Text(L(record.mealType ?? record.imageName))
                                Text(record.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                if let note = record.note, !note.isEmpty { Text(note).font(.caption).lineLimit(1) }
                            }
                            Spacer()
                            if let nutrition = record.nutrition { Text("\(nutrition.energy_kcal, specifier: "%.0f") kcal") }
                            else { Text(L(record.analysisStatus ?? "未解析")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }.navigationTitle(L("保存した食事"))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(L("閉じる")) { showHistory = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let exportURL { ShareLink(item: exportURL) { Label(L("JSON出力"), systemImage: "square.and.arrow.up") } }
                    }
                }.onAppear {
                    do { exportURL = try model.exportURL() } catch { model.error = error.localizedDescription }
                }
        }
    }
    private func storedImage(_ record: MealRecord) -> UIImage? {
        guard let data = try? RecordStorage.photoData(for: record) else { return nil }
        return UIImage(data: data)
    }
    private func storedThumbnail(_ record: MealRecord) -> UIImage? {
        guard let url = try? RecordStorage.photoURL(for: record),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return storedImage(record) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 160]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}

private extension View {
    func card(compact: Bool = false) -> some View {
        padding(compact ? 16 : 22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onPhoto: (Data) -> Void
    var onError: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController(); controller.sourceType = .camera
        controller.cameraDevice = .rear; controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) { parent.onPhoto(data) }
            else { parent.onError("撮影した写真を取得できませんでした。もう一度撮影してください。") }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
