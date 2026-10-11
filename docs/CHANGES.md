# Changes for publication (2026-10-04)

Starting point: the version developed with Codex (2026-09-27 to 10-03). The inference path of the research
protocol mode was checked line by line against the research batch application (tag `paper2-ipad-run`) and found
identical in prompt string, message structure, generation parameters, pixel limits and library versions. The
following changes were then made.

## Research protocol
- **Weight (W) condition added.** An optional field "料理だけの重さ" (weight of the food only) appears in
  research protocol mode. When filled, `The total weight of the food shown is {W} g.` is appended to the prompt
  (`ResearchProtocol.promptText(declaredWeight:)`); when empty the prompt is the Appendix A string unchanged
  (none condition). Values 1–5,000 g; full-width digits and thousands separators accepted. The field is cleared
  for every new photograph. Batch analysis always uses the none condition.
- **Model input rendered in sRGB** (`UIGraphicsImageRendererFormat.preferredRange = .standard`), so that the
  JPEG given to the model no longer depends on the colour gamut of the device screen (Display P3 photographs).
  Model inputs created before this change may differ.

## User interface
- **Folder, multi-file, single-file and model-folder pickers fixed.** Four `.fileImporter` modifiers were
  attached to the same view; SwiftUI presents only one of them, so "画像フォルダを選ぶ" and the file pickers
  showed nothing. Replaced by one importer whose content types depend on the button pressed.
- **Image sets inside the app.** Folders placed in `Documents/images/<set>/` (Files › On My iPad ›
  Local Nutrition › images) are listed in the batch panel and can be analysed without a file picker, all
  images or the first N in file-name order. Same layout as the research batch application.

- **Increased memory limit entitlement** (`com.apple.developer.kernel.increased-memory-limit`), as in the
  research batch application. Without it the 4B model was terminated on iPhone. It changes the memory the system
  allows the app, not the computation.

- **English user interface.** `Localization.swift` holds the Japanese→English table; the interface follows the
  device language (Japanese if the first preferred language is Japanese, English otherwise) until the user
  switches with the "English / 日本語" button in the toolbar (kept in UserDefaults). Values stored in
  records and exports (analysis status, meal types) remain Japanese and are translated only on display. Prompts and
  computation are unchanged.

## Records
- New fields in every analysis record and in `analysis-log.jsonl`: `condition`, `declaredWeight_g`,
  `generationSeconds` (preprocessing + generation, model loading excluded, measured as in the batch application),
  `modelWeightsSHA256` (SHA-256 of each `*.safetensors` file), `deviceModel`, `osVersion`, `appVersion`,
  `libraries`.
- Changing the portion after analysis no longer drops fields of the analysis record
  (`AnalysisRun.updatingPortion`).
- `results.csv`: the row written for a photograph without analysis had one cell more than the header; fixed.
  New columns `condition`, `declared_weight_g`, `generation_seconds`.
- `generationSettings` string of the research mode updated to describe the condition and the input
  normalisation.

## Repository
- `tools/compare_acceptance.py`: pairs the app log with the batch application output by file name and reports
  identical raw responses / energy values, and checks the weight hashes. Accepts analysis-log.jsonl or a
  batch export JSON. First run (2026-10-04, iPad Air M4, iPadOS 26.6.2, 4B): 17/17 model inputs (11 photographs)
  gave identical raw responses with the research batch application.
- `prepare-models.sh`: 2B/4B/8B; writes the snapshot revision and SHA-256 of the weights; English messages.
- Removed the personal development team identifier from the Xcode project.
- Removed the development console output (`NUTRITION_SMOKE_PASS/FAIL`).
- Removed `Resources/Samples` (meal images no longer used by the app).
- Weights excluded by `.gitignore`. README rewritten in English; the first README is kept in
  `docs/README_codex_2026-09_ja.md`.

## Not changed
- Consumer mode (prompt, settings) — not part of the paper.
- Research protocol prompt, generation parameters, preprocessing limits, libraries.
