import Foundation

// Japanese / English user interface.
//
// The Japanese text is the key. The language follows the device (Japanese if its first preferred language is
// Japanese, English otherwise) until the user chooses one with the switch in the toolbar; the choice is kept.
// In English the text below is shown (or the key itself if it is missing).
// Values that are stored in records and exports (analysis status such as "解析済み", meal types such as
// "昼食", input names) stay in Japanese for compatibility and are translated only when displayed.
// Nothing here changes the prompts or the model computation.

enum AppLanguage {
    /// UserDefaults key of the in-app language switch: "ja", "en", or empty/absent = follow the device.
    static let storageKey = "uiLanguage"
    static var deviceIsJapanese: Bool { (Locale.preferredLanguages.first ?? "en").hasPrefix("ja") }
    static var isJapanese: Bool {
        switch UserDefaults.standard.string(forKey: storageKey) {
        case "ja": return true
        case "en": return false
        default: return deviceIsJapanese
        }
    }
}

/// Display text for a Japanese UI string (returns the input unchanged if it is not a known key,
/// e.g. text that is already localized or comes from the system).
func L(_ japanese: String) -> String {
    AppLanguage.isJapanese ? japanese : (englishText[japanese] ?? japanese)
}

/// Display text with format arguments (%@, %ld). The English text keeps the same specifiers in the same order.
func LF(_ japanese: String, _ arguments: CVarArg...) -> String {
    String(format: L(japanese), arguments: arguments)
}

let englishText: [String: String] = [
    // Header and general
    "食事を撮って、栄養を知る。": "Photograph a meal, see its nutrients.",
    "写真の解析も、食事の記録も、この端末の中で。": "Analysis and records stay on this device.",
    "食品成分表から計算する": "Calculate from the food composition table",
    "写真からの値は概算です。食材の重量や油・調味料は写真だけでは確定できません。":
        "Values from a photograph are approximate. Weights, oil and seasonings cannot be determined from a photograph alone.",
    "記録": "History",
    "確認": "Notice",
    "閉じる": "Close",
    "中止": "Cancel",

    // 1 Photo
    "1  食事の写真": "1  Meal photo",
    "食事全体が写るように撮影してください": "Take the photo so that the whole meal is visible",
    "写真番号 #%@": "Photo #%@",
    "この端末ではカメラを使用できません。": "The camera is not available on this device.",
    "設定アプリでLocal Nutritionのカメラへのアクセスを許可してください。": "Allow camera access for Local Nutrition in the Settings app.",
    "食事を撮影して記録": "Photograph and record a meal",
    "次の食事を撮影": "Photograph the next meal",
    "撮影した写真と日時は自動保存され、栄養を解析します。": "The photo and its date are saved automatically, then analysed.",
    "保存済みの写真を使う": "Use a saved photo",
    "写真": "Photos",
    "ファイル": "Files",
    "写真を保存済み": "Photo saved",
    "食事": "Meal",
    "朝食": "Breakfast",
    "昼食": "Lunch",
    "夕食": "Dinner",
    "間食": "Snack",
    "料理名やメモ": "Dish name or note",
    "食事区分・メモ・分量の変更を保存": "Save meal, note and portion",
    "解析に失敗しても写真は記録に残ります。": "The photo stays in the history even if the analysis fails.",
    "撮影した写真を取得できませんでした。もう一度撮影してください。": "The photo could not be obtained. Please take it again.",

    // 2 Analysis
    "2  端末内で栄養を推定": "2  On-device nutrient estimation",
    "解析モデル": "Model",
    "Qwen3-VL %@ · 端末内で利用可能": "Qwen3-VL %@ · available on this device",
    "%@モデルのフォルダを追加": "Add the %@ model folder",
    "端末の「ファイル」でQwen3-VL-%@-Instruct-4bitフォルダを選択してください。":
        "Select the Qwen3-VL-%@-Instruct-4bit folder in Files.",
    "追加済みモデルを再確認": "Re-check installed models",
    "8Bは約5.4GBのモデルです。端末の空き容量とメモリにより解析できない場合があります。":
        "The 8B model is about 5.4 GB. It may not run, depending on free storage and memory.",
    "解析モード": "Analysis mode",
    "通常": "Consumer",
    "研究プロトコル": "Research protocol",
    "論文の研究プロトコル（L0）で解析します。重さが空欄なら none 条件、入力すると W 条件（重量の一文を付加）です。":
        "Analyses with the research protocol of the paper (L0). Empty weight: none condition; with a weight: W condition (a weight sentence is appended).",
    "料理だけの重さ": "Weight of the food only",
    "任意": "optional",
    "器や容器の重さは含めないでください。器ごと量る場合は、先に器だけを量って差し引きます。一括解析では重さは使いません。":
        "Do not include the plate or container. If you weigh it on the plate, weigh the plate alone first and subtract. Batch analysis does not use the weight.",
    "重さは 1〜5000 g の数値で入力してください。": "Enter a weight between 1 and 5,000 g.",
    "推定の条件": "Estimation settings",
    "写真を1人分とみなす": "Treat the photo as one serving",
    "日本の標準的な食事を想定": "Assume a standard Japanese meal",
    "条件を変えた場合は再解析してください。分量は結果の倍率で調整できます。":
        "Analyse again after changing the settings. The portion can be adjusted with the multiplier.",
    "栄養を再解析": "Analyse again",
    "AI推定値": "AI estimate",
    "食べる分量": "Portion eaten",
    "半分": "Half",
    "全部": "All",
    "1.5倍": "1.5×",
    "2倍": "2×",
    "栄養値を保存済み": "Nutrients saved",
    "分量の変更を保存": "Save portion",
    "AIの応答を確認": "Show the model response",
    "たんぱく質": "Protein",
    "脂質": "Fat",
    "炭水化物": "Carbohydrate",
    "食塩相当量": "Salt equivalent",
    "データ不足": "No data",

    // 3 Batch
    "3  フォルダの画像を一括解析": "3  Batch analysis of a folder",
    "端末内の画像セット": "Image sets on this device",
    "ファイルアプリの「このiPad内（iPhoneでは「このiPhone内」）› Local Nutrition › images」に置いたフォルダが一覧に出ます。数枚だけ試すときは、画像をコピーした新しいフォルダを images の中に作ってください。":
        "Folders placed in Files › On My iPad (On My iPhone) › Local Nutrition › images are listed here. To try a few images, make a new folder inside images and copy them into it.",
    "images フォルダに画像セット（サブフォルダ）がありません。": "There are no image sets (subfolders) in the images folder.",
    "画像セット": "Image set",
    "枚数: 全部": "Images: all",
    "枚数: 先頭 %ld 枚": "Images: first %ld",
    "このセットを一括解析": "Analyse this set",
    "セット一覧を更新": "Refresh the list",
    "ほかの場所（iCloud Drive など）から選ぶ": "Choose from another location (e.g. iCloud Drive)",
    "iCloud Driveなどのフォルダ内の画像を、選択中の%@モデルで順番に解析します。サブフォルダ内も対象です。":
        "Analyses the images of a folder (e.g. in iCloud Drive), subfolders included, one by one with the selected %@ model.",
    "画像フォルダを選ぶ": "Choose an image folder",
    "写真を複数選ぶ": "Choose several photos",
    "画像ファイルを複数選ぶ": "Choose several image files",
    "一括解析を中止": "Stop batch analysis",
    "結果: %@": "Result: %@",
    "結果JSONを共有・iCloud Driveに保存": "Share the result JSON or save it to iCloud Drive",
    "JSONは1枚ごとに更新されます。同じフォルダを選び直すと未完了分から再開できます。長時間の解析中はアプリを開いたままにしてください。":
        "The JSON is updated after every image. Choosing the same folder again resumes from the unfinished images. Keep the app open during long runs.",
    "フォルダ内の画像を探しています…": "Looking for images in the folder…",
    "0 / %ld 枚": "0 / %ld images",
    "%ld / %ld 枚が完了（続きから実行）": "%ld / %ld images done (resuming)",
    "%ld / %ld 枚を解析中": "Analysing %ld / %ld",
    "%ld / %ld 枚が完了": "%ld / %ld images done",
    "%ld / %ld 枚を処理、成功 %ld 枚": "%ld / %ld images processed, %ld succeeded",
    "一括解析を中止しました。完了分のJSONは保存済みです。": "Batch analysis stopped. The JSON of the finished images has been saved.",
    "一括解析が完了しました。": "Batch analysis finished.",
    "選択した場所に解析できる画像がありません。": "There are no images to analyse in the selected location.",
    "images フォルダに画像セットがありません。": "There are no image sets in the images folder.",
    "フォルダを読み取れませんでした: %@": "The folder could not be read: %@",
    "画像セットを読み取れませんでした: %@": "The image set could not be read: %@",
    "一括結果の保存先を作れませんでした: %@": "The folder for batch results could not be created: %@",
    "一括結果を保存できませんでした: %@": "The batch results could not be saved: %@",

    // Calculator
    "食品成分表で計算": "Food composition calculator",
    "食品と可食部の重さを入力して、AI推定値と比べられます。": "Enter foods and edible weights to compare with the AI estimate.",
    "食品を追加": "Add food",
    "重さ": "Weight",
    "重さを0より大きい10,000g以下の数値で入力してください。": "Enter a weight greater than 0 and up to 10,000 g.",
    "出典：日本食品標準成分表（八訂）増補2023年（2026年3月訂正反映）":
        "Source: Standard Tables of Food Composition in Japan 2020 (8th ed.), Supplement 2023 (corrections of March 2026)",
    "成分値は可食部100g当たり。Tr（微量）は計算上0、括弧付きの推定値は数値として使用しています。":
        "Values per 100 g edible portion. Tr (trace) is counted as 0; estimated values in parentheses are used as numbers.",
    "%@ kcal / 100g · 食品番号 %@": "%@ kcal / 100 g · food no. %@",
    "ご飯、鶏、豆腐など": "e.g. ご飯, 鶏, 豆腐 (Japanese food names)",
    "食品を検索（%ld件）": "Search foods (%ld)",

    // History
    "解析用データを書き出す": "Export data for analysis",
    "「ファイル」アプリ → このiPhone / iPad内 → Local Nutrition → ResearchExport に、番号付き写真、results.csv、records.jsonを保存しました。":
        "Numbered photos, results.csv and records.json were saved to Files › On My iPhone / iPad › Local Nutrition › ResearchExport.",
    "結果CSVを共有": "Share results CSV",
    "詳細JSONを共有": "Share detailed JSON",
    "解析ログJSONLを共有": "Share analysis log (JSONL)",
    "保存した食事がここに表示されます。": "Saved meals appear here.",
    "写真は保存されています。栄養値はまだありません。": "The photo is saved. There are no nutrient values yet.",
    "この記録を開いて編集・再解析": "Open this record to edit or analyse again",
    "元の写真を書き出す": "Export the original photo",
    "モデル入力: model_inputs/%@": "Model input: model_inputs/%@",
    "モデル入力JPEGを書き出す": "Export the model input JPEG",
    "解析時間：%@秒、分量倍率：%@": "Analysis time: %@ s, portion multiplier: %@",
    "プロンプトと生の応答": "Prompt and raw response",
    "モデル別の解析履歴": "Analyses by model",
    "食事の記録": "Meal record",
    "保存した食事": "Saved meals",
    "JSON出力": "Export JSON",

    // Status (some are stored values, translated on display)
    "食事を撮影して記録しましょう": "Photograph a meal to record it",
    "写真と撮影日時を保存しました": "Photo and date saved",
    "記録を開きました": "Record opened",
    "モデルを読み込んでいます…": "Loading the model…",
    "端末内で食事を解析しています…": "Analysing the meal on this device…",
    "解析完了（%ld秒）": "Analysis finished (%ld s)",
    "解析を中止しました": "Analysis cancelled",
    "解析できませんでした": "Analysis failed",
    "中止しています…": "Cancelling…",
    "食事の記録を更新しました": "Meal record updated",
    "%@モデルをコピーしています…": "Copying the %@ model…",
    "%@モデルを追加しました": "The %@ model was added",
    "未解析": "Not analysed",
    "解析中": "Analysing",
    "解析済み": "Analysed",
    "解析中止": "Cancelled",
    "解析失敗": "Failed",
    "読込失敗": "Could not be read",
    "食事の撮影": "Camera photo",
    "写真ライブラリ": "Photo library",

    // Errors
    "保存データを読み込めませんでした: %@": "The saved data could not be read: %@",
    "記録の更新に失敗しました: %@": "The record could not be updated: %@",
    "保存できませんでした: %@": "Could not be saved: %@",
    "モデルを追加できませんでした: %@": "The model could not be added: %@",
    "AIの応答を栄養値として読み取れませんでした。生の応答を確認して、再解析してください。":
        "The model response could not be read as nutrient values. Check the raw response and analyse again.",
    "AIの出力が完成する前に終了しました。写真と応答は保存されています。再解析してください。":
        "The model output ended before it was complete. The photo and response are saved. Please analyse again.",
    "このモデルは端末にありません。ファイルアプリからモデルフォルダを追加してください。":
        "This model is not on the device. Add the model folder with the Files app.",
    "画像を読み込めませんでした。別の画像を選んでください。": "The image could not be read. Please choose another image.",
    "モデルの画像処理設定を読み取れませんでした。": "The image settings of the model could not be read.",
]
