# Roadmap

Prioritized work items. Order is suggested, not mandatory — pick what
the user asks for.

## Tier 1: Make it complete (high impact, well-scoped)

### 1.1 Wire real DocLayNet RT-DETR weights

**Goal**: replace the dummy ONNX in `models/layout.onnx` with the real
DocLayNet-trained RT-DETR from docling-project on Hugging Face.

**Steps**:
1. Download weights:
   ```bash
   huggingface-cli download asmud/ds4sd-docling-models-onnx layout.onnx \
     --local-dir ./models
   ```
   *or* convert from PyTorch:
   ```python
   from transformers import RTDetrV2ForObjectDetection
   import torch
   m = RTDetrV2ForObjectDetection.from_pretrained("docling-project/docling-layout-heron")
   m.eval()
   torch.onnx.export(m, torch.zeros(1,3,640,640), "models/layout.onnx",
                     input_names=["pixel_values"],
                     output_names=["logits", "pred_boxes"],
                     opset_version=18,
                     dynamic_axes={"pixel_values": {0: "batch"}})
   ```
2. Inspect the actual I/O:
   ```ruby
   sess = OnnxRuntime::InferenceSession.new("models/layout.onnx")
   puts sess.inputs.inspect
   puts sess.outputs.inspect
   ```
3. **If output is `logits` (not `labels`)**: extend `OnnxLayout#extract_lbs`
   to do argmax over the last axis. Add a unit test against a known PDF.
4. **If output bbox format differs from current `:auto` detector**: hardcode
   the format in `OnnxLayout.new(box_format: :cxcywh_norm)`.
5. Add a smoke test that loads the real model and checks at least one
   detection on `01_simple.pdf`.

**Acceptance criteria**: `RbDocling.parse(pdf, layout: :onnx, models_dir: ...)`
produces a tree where headings are correctly identified on a benchmark PDF
where heuristic mode misclassifies them.

**Estimated effort**: 4-8 hours, mostly empirical debugging.

### 1.2 Wire real TableFormer weights

**Goal**: replace the placeholder `OnnxTableFormer` with a working implementation.

**Steps**:
1. Download weights:
   ```bash
   huggingface-cli download asmud/ds4sd-docling-models-onnx \
     tableformer_encoder.onnx tableformer_decoder.onnx \
     --local-dir ./models
   ```
2. Find the OTSL vocabulary. Check files in the HF repo for `vocab.json`,
   `config.json`, or `tokenizer.json`. As fallback, read it from the
   docling-ibm-models Python package: the OTSL vocab is defined in
   `docling_ibm_models/tableformer/utils/utils.py` or similar.
3. Update `OTSL_TOKENS` in `lib/rb_docling/table/onnx_tableformer.rb` with
   the exact ordered vocabulary.
4. Inspect encoder/decoder I/O:
   ```ruby
   enc = OnnxRuntime::InferenceSession.new("models/tableformer_encoder.onnx")
   dec = OnnxRuntime::InferenceSession.new("models/tableformer_decoder.onnx")
   ```
5. Compare with the Python reference: clone docling-ibm-models, find the
   `TFPredictor` class, see what feeds it builds.
6. Match `dec_input_name`, `enc_feat_name` patterns in `decode_structure`.
7. If decoder exposes KV cache as inputs/outputs, implement caching to make
   each step O(1). Otherwise, accept O(n²) for now.
8. Test against a table-heavy PDF (use `bench/gen_test_pdfs.py` → `04_tables.pdf`).

**Acceptance criteria**: TableFormer extracts the same table structure as
heuristic mode on tables with borders, and *additionally* extracts borderless
tables that heuristic misses.

**Estimated effort**: 2-4 days. This is the most empirical part of the
project — expect debugging.

### 1.3 Physical image extraction

**Goal**: `to_md` should emit real image references, not `![image](#)` placeholder.

**Steps**:
1. `OnnxLayout#analyze` (and the heuristic equivalent if we add picture
   detection there) populates `Node#metadata[:image_bbox]` and triggers a
   render of that bbox region.
2. New method `Pipeline#extract_picture_images(tree, output_dir)`:
   - For each `:picture` node, render the page region at 2× scale
   - Save as PNG to `output_dir/figure_<page>_<index>.png`
   - Set `node.metadata[:image_path]` to the relative path
3. `Node#to_md` already handles `image_path` when present — verify and adjust.
4. Alternatively, embed as base64 if `output_dir` is `:inline`.

**Acceptance criteria**: a PDF with figures produces a Markdown file that,
when rendered, shows the actual images.

**Estimated effort**: 1 day.

### 1.4 Nested list support

**Goal**: detect indentation in heuristic layout and produce nested list items.

**Steps**:
1. In `HeuristicLayout`, when a block is classified as `:list_item`, record
   its `x0` (left margin) in `metadata[:indent_x]`.
2. Add a post-processing pass on the block list that compares list-item
   indents and assigns `metadata[:list_level]` (1 = outermost).
3. `Node#to_md` already uses `metadata[:list_level]` (added in the
   conversation). Verify it works for nested cases.

**Acceptance criteria**: a PDF with `a → a.1 → a.1.1` nested bullets
produces correctly indented Markdown.

**Estimated effort**: 4-6 hours.

## Tier 2: Make it production-ready

### 2.1 Pluggable tokenizer with real BPE

**Goal**: ship an optional integration with a real tokenizer (tiktoken-style).

**Options**:
- Wrap `tiktoken_ruby` if maintained
- Wrap `hf_hub` + sentencepiece via FFI
- Document the Proc-injection pattern and stop there

**Estimated effort**: 1 day for wrapping; zero for documenting.

### 2.2 Performance: faster preprocessing

The current image preprocessing in `OnnxLayout` does nested Ruby loops over
pixels. Profile says this is the bottleneck for ONNX mode.

**Options** (in order of preference):
1. Use `numo-narray` for the resize + normalize ops (~5-10× speedup)
2. Write a C extension for the hot loop (~50× speedup but adds complexity)
3. Use ImageMagick via `mini_magick` for the resize (less control, depends on system imagemagick)

**Estimated effort**: 1-2 days for option 1.

### 2.3 Reader for non-PDF formats

Docling supports DOCX, PPTX, HTML, XLSX. Out-of-scope for v1 of `rb_docling`,
but worth a stub design:
- Each format has its own reader → produces `DocumentTree` in our model
- The rest of the pipeline (chunker, exporters) is format-agnostic

Don't implement until a user asks for it.

## Tier 3: Quality and operations

### 3.1 CI

Add `.github/workflows/test.yml`:
- Install Ruby 3.2
- Install libpdfium (via apt or download from bblanchon/pdfium-binaries)
- Bundle install
- Run smoke tests

Without CI, regressions will sneak in.

**Estimated effort**: 2-4 hours.

### 3.2 Real RAG benchmark

The `rb_docling_bench` package compares Markdown output. For real users, the
question is: **does the chunked output produce good retrieval?**

Build a benchmark that:
- Takes a corpus of PDFs and a list of test queries with known relevant pages
- Chunks via `rb_docling` and via Docling
- Embeds with the same model (e.g., text-embedding-3-small via API or all-MiniLM-L6-v2 locally)
- Measures recall@K and mean reciprocal rank for each pipeline

**Estimated effort**: 2-3 days. Highest signal for "is this actually usable?".

### 3.3 Memory management for long-running workers

Currently `Models::Loader` caches sessions forever. For a worker processing
thousands of documents, RAM grows. Add:
- LRU eviction in `Loader` (configurable)
- `Loader.reset!` exposed via CLI or RAILS_TASK
- Document the pattern in `docs/RESOURCES.md`

**Estimated effort**: 1 day.

## Tier 4: Nice-to-haves

### 4.1 DocTags export

Docling supports its `DocTags` format (XML-like, used for VLM fine-tuning).
Implement `Tree#to_doctags` if a user has a specific use case.

### 4.2 JSON Schema for `to_h`

Publish a JSON Schema so external systems can validate `rb_docling`'s output.
Useful if it becomes a standard in a multi-language environment.

### 4.3 Sorbet/RBS signatures

When the codebase passes 3000 LOC, type signatures start paying off.

## What NOT to do

- **Don't add a database/persistence layer**. The DocumentTree is in-memory;
  persistence is the user's responsibility.
- **Don't add a vector store integration**. Users already have those.
- **Don't add a Rails generator** unless a user explicitly asks. Avoid scope creep.
- **Don't try to support every PDF in existence**. The 80/20 path is to be
  excellent on programmatically-generated PDFs and "office" scans (with OCR
  upstream). Pathological PDFs are not the target.
