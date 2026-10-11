# PLANS-iOS

On-device energy and nutrient estimation from meal photographs with a small open vision–language model
(Qwen3-VL, 4-bit, MLX Swift) on iPhone and iPad. No network connection is used for inference.

This repository is the supplementary software of:

> Nakagawa S, Yamamoto A. Development and Evaluation of an Offline Vision–Language Model System for Estimating
> Nutrients from Meal Photographs on Personal Devices: The PLANS (Personal-device Local Assessment of Nutrients
> System) Study. Submitted to *Journal of Medical Systems* (2026). <!-- update with DOI when published -->

PLANS (Personal-device Local Assessment of Nutrients System) is the system described in the paper; this
repository contains its iOS/iPadOS application, PLANS-iOS. This release (`v0.1.0-paper2`) is the version
described in the paper, with which the acceptance test and the screenshots of the paper were made; its
displayed name is "Local Nutrition". From v0.1.1 the displayed name is "PLANS", with no other change.

It is research software. It is not a medical device and its estimates must not be used for clinical decisions.

The interface is in Japanese or English: it follows the device language until a language is chosen with the
"English / 日本語" button in the toolbar (the choice is kept). Stored values (analysis status such as
`解析済み`, meal types such as `昼食`) remain in Japanese in all records and exports.

## Two analysis modes

| | **Research protocol** (evaluated in the paper) | Consumer (not evaluated) |
|---|---|---|
| Prompt | Appendix A of the paper, verbatim (`ResearchProtocol.prompt` in `Nutrition.swift`) | numeric-only JSON prompt |
| System message | empty | none |
| Optional weight | *W condition*: `The total weight of the food shown is {W} g.` appended | — |
| Temperature / max tokens | 0 / 256 | 0 / 160 |
| Repetition penalty | none | 1.1 (last 64 tokens) |
| Stopping | natural end of generation | at the first complete JSON object |
| Vision preprocessing | pixel limits from the model's `preprocessor_config.json` | resize to 512 × 512 |

Only the research protocol mode corresponds to the paper. The consumer mode is kept for development and was
not evaluated; in informal use it produced estimates concentrated in a narrow range and it should not be used
to obtain values.

In both modes the photograph is first normalised on the device: orientation corrected, scaled so that the long
edge is at most 1,024 px, rendered in sRGB, and saved as JPEG (quality 0.88). That exact file is written to
`Documents/model_inputs/` and is the file given to the model, so any result can be reproduced from it.

The research protocol mode reproduces the batch application used for the tablet runs of the paper
(mlx-swift-examples fork, tag `paper2-ipad-run`): same prompt string, same message structure, same generation
parameters, same pixel limits and the same library versions:

- mlx-swift 0.31.6
- mlx-swift-lm `604fae710a4e3324346fc59e3845952350acd4b7` (main branch; release 3.31.3 has an image-preprocessing
  defect and must not be used)
- swift-transformers 1.3.0, swift-jinja 2.3.1

For batch analysis, put image folders in `Documents/images/<set>/` (Files › On My iPad / On My iPhone › Local Nutrition ›
images); they are listed in the app and can be analysed in full or the first N images in file-name order.
Folders elsewhere (e.g. iCloud Drive) can be chosen with the folder picker; their files must be downloaded to
the device first. Batch analysis always uses the *none* condition, because one
typed weight cannot belong to several photographs.

## Requirements

- iPhone or iPad with Apple silicon and at least 8 GB of memory (developed on iPad Air 11-inch, M4, 12 GB;
  also installed on iPhone 17 Pro)
- iOS / iPadOS 18 or later
- A Mac with Xcode, and an Apple developer account to sign the app

## Build

1. Open `LocalNutrition.xcodeproj` in Xcode. Swift packages are resolved from `Package.resolved`.
2. In *Signing & Capabilities*, choose your own Team (the repository contains no team identifier) and, if
   needed, change the bundle identifier.
3. Select the connected device and Run.

## Models

The weights are not included. Download them on the Mac and prepare a folder for the device:

```sh
huggingface-cli download mlx-community/Qwen3-VL-4B-Instruct-4bit
./prepare-models.sh 4B            # also 2B or 8B
```

`prepare-models.sh` copies the cached snapshot to `../ModelTransfer/Qwen3-VL-4B-Instruct-4bit/` and writes
the snapshot revision (`*.revision.txt`) and the SHA-256 of the weight files (`*.sha256.txt`). Copy the folder to
the device with Finder (device › Files › Local Nutrition) and tap *追加済みモデルを再確認* (re-check installed
models). The app records the SHA-256 of the weights it actually used with every analysis.

The paper used `mlx-community/Qwen3-VL-4B-Instruct-4bit`, revision `2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b`
(`model.safetensors` SHA-256 `90eeb02604181dbcccd0a30a1f550a4a8928ca7dcbee4aee1449239306cfdfca`, identical to the
weights recorded on the tablet). The 2B model: revision `9c4f5209e57b31f4b9dfba735de3fb983739c9cc`.

## Records and exports (in the app's Documents folder, visible in the Files app)

| Path | Content |
|---|---|
| `MealPhotos/` | original photographs |
| `model_inputs/` | the normalised JPEG given to the model, one per analysis |
| `analysis-log.jsonl` | one line per analysis (see below) |
| `ResearchExport/` | `results.csv`, `records.json`, `analysis-log.jsonl`, `photos/` (created from the history screen) |
| `BatchExports/` | one JSON file per batch run |

Fields of `analysis-log.jsonl`: `analysisMode` (`research_protocol` / `consumer`), `condition` (`none` / `W`),
`declaredWeight_g`, `prompt` (full text sent), `rawResponse` (model output, unchanged), `parseStage`
(`json` / `rescued_keys` / `rescued_regex`), `nutrition` (parsed values **multiplied by the portion factor the
user selected**; use `rawResponse` for analysis), `portionMultiplier`, `modelID`, `modelWeightsSHA256`,
`modelInputFilename`, `generationSeconds` (image preprocessing and generation, model loading excluded),
`seconds` (whole analysis including model loading), `deviceModel`, `osVersion`, `appVersion`, `libraries`,
`generationSettings`, `photoNumber`, `photoFilename`, `recordID`, `runID`, `analyzedAt`, `status`, `error`.

## Acceptance test (identity with the research batch application)

1. In the app, research protocol mode, 4B, take 10 or more photographs of different meals (no weight).
2. Copy `model_inputs/` and `analysis-log.jsonl` from the device.
3. Put the JPEGs into `Documents/images/appcheck/` of the research batch application (tag `paper2-ipad-run`) on
   the **same device**, with the same model folder, and run the `none` condition.
4. Compare:

```sh
# --app also accepts a batch export JSON (BatchExports/*.json)
python3 tools/compare_acceptance.py --app analysis-log.jsonl \
    --ref appcheck_Qwen3-VL-4B-Instruct-4bit_L0.jsonl \
    --weights-sha ../ModelTransfer/Qwen3-VL-4B-Instruct-4bit.sha256.txt
```

The script pairs the two outputs by file name and reports the proportion of identical raw responses and
identical energy values (expected: 100 %, same device, same bytes, temperature 0). It exits with status 1 if
any pair differs.

The batch application has no weight condition, so the W condition is verified by its prompt text only.

## Known issues

- Selecting several photographs at once from the photo library may fail to load them; select one photograph
  at a time. This does not affect the research protocol mode or the results of the paper.

## Privacy

Photographs, model inputs and results stay in the app's container on the device. Inference makes no network
request; the app contains no analytics. Exports are shared only when the user chooses a destination.

## Food composition data

`Resources/foods.json` (used only by the optional manual calculator, not by the model):
「日本食品標準成分表（八訂）増補2023年から引用」 — *Standard Tables of Food Composition in Japan 2020 (Eighth
Revised Edition), Supplement 2023*, Ministry of Education, Culture, Sports, Science and Technology, Japan
(https://www.mext.go.jp/a_menu/syokuhinseibun/mext_00001.html). Values are per 100 g edible portion. MEXT states that the food composition data may be used freely, including in
applications, provided the source is cited as above.

## Licence

MIT License, © 2026 Shin-ichi Nakagawa (see `LICENSE`). The food composition data and the model files are not
covered by this licence (see the end of `LICENSE`). Third-party components: see `THIRD_PARTY_NOTICES.txt`. Model weights: see the model card of each
`mlx-community/Qwen3-VL-*-Instruct-4bit` repository.

## History

`docs/CHANGES.md` lists the changes made for publication. The development notes of the first version are
kept in `docs/README_codex_2026-09_ja.md` (Japanese).
