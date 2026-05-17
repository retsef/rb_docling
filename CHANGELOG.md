# Changelog

Tutte le modifiche notevoli a `rb_docling` sono documentate in questo file.

Formato: [Keep a Changelog](https://keepachangelog.com/it/1.1.0/).
Versioning: [SemVer](https://semver.org/lang/it/).

## [Unreleased]

## [0.2.0] — 2026-05-17

### Added

- **Packaging come Ruby gem**: `rb_docling.gemspec`, `Rakefile` con
  `bundler/gem_tasks`, `LICENSE` (Apache-2.0). La gem si costruisce con
  `bundle exec rake build` e si installa localmente con `rake install`.
- **Eseguibile `bin/rb_docling`** registrato nel gemspec — installato sul
  `PATH` insieme alla gem.
- **Rake tasks `models:*`** ([`lib/rb_docling/rake_tasks.rb`](lib/rb_docling/rake_tasks.rb))
  per scaricare i modelli ONNX di Docling on-demand:
  - `models:fetch` / `models:fetch:layout` / `models:fetch:tableformer`
    / `models:fetch:tableformer_vocab`
  - `models:list` mostra stato presente/mancante
  - `models:clean` rimuove i `.onnx` scaricati
  - Override via env var: `RB_DOCLING_HF_REPO`, `RB_DOCLING_HF_REVISION`,
    `RB_DOCLING_LAYOUT_URL`, `RB_DOCLING_TF_*_URL`, `RB_DOCLING_MODELS_DIR`,
    `FORCE=1`
- **Workflow di conversione PyTorch → ONNX** in [`tools/`](tools/README.md):
  - `tools/export_layout.py` — DocLayNet Heron RT-DETR → ONNX
  - `tools/export_tableformer.py` — TableFormer → ONNX (split + monolithic
    + estrazione vocab OTSL)
  - `tools/verify_onnx.py` — validazione `onnx.checker` + smoke inference
  - `tools/requirements.txt` — Python deps della conversione
  - `tools/hf_repo/` — template del repo HuggingFace (model card +
    `.gitattributes` LFS)
- Default source dei pesi: [`klarolabs/rb-docling-onnx`](https://huggingface.co/klarolabs/rb-docling-onnx)
  (repo HF dedicato per le conversioni pre-compilate). I repo ufficiali
  IBM/ds4sd pubblicano solo PyTorch.
- `tableformer_vocab.json` aggiunto come file scaricabile separato
  (richiesto dal decoder, contiene il vocabolario OTSL).
- `.gitignore` per artefatti di build gem (`pkg/`, `*.gem`, ecc.) e per i
  `.onnx` in `models/`.

### Changed

- `Gemfile` ora usa `gemspec` (le dipendenze runtime sono dichiarate nel
  gemspec). Override locale di rpdfium via `RPDFIUM_PATH=` env var.
- README principale: sezione installazione/uso/modelli rifatta per la gem.
- `models/README.md`: workflow aggiornato al nuovo repo HF e ai task rake.

### Notes

- Nessuna modifica al codice della pipeline core (Document, Layout,
  Table, Chunking, Pipeline). I 41 smoke test pre-esistenti restano verdi.
- Gli script Python di conversione sono **scaffolding**: i punti
  `# TODO[calibrate]` vanno verificati contro la versione installata di
  `docling-ibm-models` (vedi `tools/README.md`).

## [0.1.0] — 2026-05-15

### Added

- Pipeline iniziale PDF → DocumentTree:
  - `RbDocling::Document::{BBox, Node, Tree}` con 11 tipi DocLayNet,
    serializzazione Markdown/JSON, headings_path
  - `RbDocling::Layout::HeuristicLayout` — clustering word/line/block,
    classificazione title/section_header/list_item/text
  - `RbDocling::Layout::OnnxLayout` — wrapper RT-DETR (autodetect formato
    bbox, letterbox + ImageNet normalization)
  - `RbDocling::Layout::ReadingOrder` — column clustering geometric
  - `RbDocling::Table::HeuristicTable` — wrapper `Rpdfium::Table::Extractor`
    con filtri anti-falso-positivo
  - `RbDocling::Table::OnnxTableFormer` — scaffolding encoder/decoder
    autoregressivo OTSL (split + monolithic)
  - `RbDocling::Chunking::HybridChunker` — chunking RAG-ready con
    split/merge token-aware
  - `RbDocling::Pipeline` — orchestratore PDF → tree
- CLI `bin/rb_docling` con output `md|json|chunks`
- Smoke test in `spec/smoke_test.rb` (41 test, plain Ruby, zero rspec)
- Documentazione: ARCHITECTURE, DESIGN_DECISIONS, COMPARISON_DOCLING,
  ROADMAP, ENVIRONMENT, RESOURCES, BENCHMARK

[Unreleased]: https://github.com/retsef/rb_docling/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/retsef/rb_docling/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/retsef/rb_docling/releases/tag/v0.1.0
