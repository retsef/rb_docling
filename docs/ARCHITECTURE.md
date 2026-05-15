# Architecture

Detailed walk-through of every module. Read after `CLAUDE.md`.

## Pipeline overview

```
                                  ┌─────────────────────────┐
                                  │ RbDocling.parse(path)   │
                                  │ → Pipeline#parse        │
                                  └────────────┬────────────┘
                                               │
                  ┌────────────────────────────┴────────────────────────────┐
                  ▼                                                          ▼
       Rpdfium.open(path) yields each page                       For each page:
                                                                   1. extract tables
                                                                   2. layout analyze
                                                                       (excluding table bboxes)
                                                                   3. reading order sort
                                                                   4. build Nodes
                                                                  ▼
                                                          DocumentTree(nodes)
                                                                  │
                                                                  ▼
                                                       to_md / to_h / Chunker
```

The pipeline is deliberately **page-by-page** to keep memory bounded. Cross-page
dependencies (heading inheritance) are resolved at `Tree#headings_path_for`
time, not during parse.

## Module by module

### `RbDocling::Document::BBox` (`lib/rb_docling/document/bbox.rb`)

Value object for bounding boxes in **PDF coordinates** (origin top-left, units
in typographic points). Critical methods:

- `contains?(other, tol:)` — checks if `other` is inside `self` with tolerance
- `intersects?(other)` — boolean overlap test
- `iou(other)` — intersection over union (uses `.to_f` to avoid integer division bug)
- `from_pixels(px_bbox, scale:)` — converts pixel coords to PDF points after rendering

**Convention**: `top < bottom` always (top is smaller Y), because rpdfium uses
top-down Y. This is the opposite of PDFium's *native* PDF coordinate system,
but matches how rpdfium presents it. Don't try to flip the convention — code
elsewhere assumes this orientation.

### `RbDocling::Document::Node` (`lib/rb_docling/document/node.rb`)

A typed node. `VALID_TYPES` mirrors the 11 DocLayNet labels plus `:list`
(composite) for future use:

```ruby
%i[title section_header text list_item caption footnote
   page_header page_footer table picture formula list]
```

Each node has:
- `text` — string content (nil for `:table`, `:picture`)
- `bbox`, `page_no`
- `level` — heading level (1..6); nil for non-headings
- `font`, `fontsize`, `weight` — typography metadata (for heuristic classifier)
- `table_structure` — `{ rows: [[cell, ...], ...] }` for `:table`
- `metadata` — free-form hash; `:caption`, `:image_path`, `:score`, `:split`, `:merged`

The `to_md` method is the per-node serializer. **Don't add complex Markdown
logic here**; if it grows, extract a `MarkdownSerializer` class to match
Docling's design pattern.

### `RbDocling::Document::Tree` (`lib/rb_docling/document/tree.rb`)

A flat ordered list of `Node`s with implicit hierarchy via heading levels.
**Important distinction from Docling**: Docling has true parent/child
relationships via `RefItem`; we reconstruct hierarchy on demand via
`headings_path_for(node_index)`.

Trade-off: simpler in-memory model, but **transformations that rearrange the
tree are harder**. If a future feature needs subtree extraction or
restructuring, consider whether to upgrade to a real tree model. Don't do
this preemptively.

`to_md` options:
- `strict_text: true` → no Markdown markup
- `include_furniture: false` → omits page_header/page_footer
- `associate_captions: true` → merges `:caption` nodes into adjacent
  `:picture`/`:table` (within 60pt vertical distance, same page)

### `RbDocling::Models::Loader` (`lib/rb_docling/models/loader.rb`)

Process-singleton cache of `OnnxRuntime::InferenceSession` objects keyed by
path. Thread-safe via `Mutex`. Use this anywhere you load a model — don't
instantiate `InferenceSession` directly.

```ruby
session = RbDocling::Models::Loader.session("models/layout.onnx")
```

`reset!` exists for tests.

### `RbDocling::Layout::HeuristicLayout` (`lib/rb_docling/layout/heuristic_layout.rb`)

The "no-ML" layout analyzer. Algorithm:

1. **Get words from rpdfium**: `page.words` returns hashes with `text, x0, top,
   x1, bottom, fontsize, font, weight`.
2. **Exclude words inside table bboxes** (`exclude_bboxes:` parameter). This
   is set by `Pipeline` after tables are extracted.
3. **Group words into lines** by Y-baseline (tolerance 2.5pt).
4. **Group lines into blocks** by:
   - Significant fontsize change (>1pt) → split
   - Bold/non-bold change → split
   - Vertical gap > 1.2× line height → split
5. **Classify each block**:
   - `ratio = block.fontsize / body_median_fontsize`
   - `ratio ≥ 1.6` → `:title`, level 1
   - `ratio ≥ 1.35` (or `≥ 1.15` and bold) → `:section_header`, level by ratio
   - Single short bold line → `:section_header`
   - Starts with bullet/numbering → `:list_item`
   - Otherwise → `:text`
6. **Split inline bullets**: a block like "Lista: • a • b • c" is split into
   one `:text` + three `:list_item`.

**Tuning knobs**:
- `HEADING_FONT_RATIO` (default 1.15)
- Line tolerance `y_tol` (default 2.5)
- Gap break factor (1.2× line height)

Known limit: when a Title and a Heading1 have *identical* fontsize and weight
(e.g., reportlab's `Title` and `Heading1` both at 18pt Helvetica-Bold), they
are indistinguishable. This is a real limit, not a bug. Fix requires ML.

### `RbDocling::Layout::ReadingOrder` (`lib/rb_docling/layout/reading_order.rb`)

Column-aware reordering. Algorithm:

1. Sort blocks by `bbox.x0`.
2. Cluster x0 values: blocks within `COLUMN_TOL` (25pt) belong to the same column.
3. Order columns left-to-right (by average x0).
4. Inside each column, order top-to-bottom.

Simple and good enough for 2-3 column layouts. Fails on:
- Wraparound (text flowing around an embedded figure)
- Sidebar-style asides

For those, a more sophisticated approach is needed (XY-cut, or relying on the
ML layout model's reading order output if Docling exposes it).

### `RbDocling::Layout::OnnxLayout` (`lib/rb_docling/layout/onnx_layout.rb`)

RT-DETR wrapper. Inputs and outputs are abstracted via auto-detection because
ONNX exports of RT-DETR vary:

- **Input**: `[1, 3, H, W]` float32, ImageNet-normalized, RGB. Default `H=W=640`.
- **Output**: three tensors named `labels`/`boxes`/`scores` (or aliases).
  The `box_format` auto-detector handles `xyxy_norm`, `cxcywh_norm`, `xyxy_px`,
  `cxcywh_px`.

Preprocessing pipeline:
1. Render PDF page to RGBA bitmap via `page.render(scale:, output: :rgba)`
2. Strip alpha → RGB
3. Letterbox resize to model input size (preserving aspect ratio)
4. Normalize: `(x/255 - mean) / std` per channel
5. NCHW layout

Postprocessing:
1. For each detection above `score_threshold`: map class index → node type
2. Denormalize bbox to pixel coords of rendered image
3. Remove letterbox padding
4. Convert pixel coords → PDF points using the page's render scale
5. Extract text inside the bbox via `page.text_in_bbox(...)`

**Note on RT-DETRv2 from docling-project**: that model emits `logits` (not
hardmax labels) of shape `[1, num_queries, num_classes]` and `pred_boxes`
in `cxcywh_norm`. The current `extract_lbs` method handles `labels` directly;
if you wire RT-DETRv2, you'll need to add an argmax over logits. See TODO
comment in `parse_outputs`.

### `RbDocling::Table::HeuristicTable` (`lib/rb_docling/table/heuristic_table.rb`)

Thin wrapper over `Rpdfium::Table::Extractor`. Strategy `:lines` works well
for tables with visible borders. **False-positive filtering** is essential:

- Reject tables with < 2 columns or < 2 rows
- Reject tables where < 40% of cells are non-empty
- Reject tables where rows have inconsistent column counts

Without these filters, lists and section dividers can be interpreted as
giant single-column "tables" that swallow page content.

### `RbDocling::Table::OnnxTableFormer` (`lib/rb_docling/table/onnx_tableformer.rb`)

**This module is scaffolding**. It has the correct overall structure but
several calibration points that require real model weights:

1. **OTSL vocabulary order**: `OTSL_TOKENS` is a placeholder. The real
   vocabulary must come from the model's config.json or be inferred from
   the docling-ibm-models source. Wrong vocab order = garbage output.
2. **Decoder I/O names**: the heuristics for finding `dec_input_name` and
   `enc_feat_name` may not match the actual exported ONNX. Verify with
   `OnnxRuntime::InferenceSession#inputs` against the real model.
3. **Monolithic vs split mode**: `:auto` picks based on whether a decoder
   path is provided. The real Docling export is split (encoder + decoder).
4. **KV cache**: the current decoder loop re-feeds the full token sequence
   every step. Real implementations use KV cache for O(1) per step instead
   of O(n²). This is a 10-100× performance improvement once weights are
   wired and the decoder ONNX exposes cache state inputs/outputs.

See `docs/ROADMAP.md` item "Wire real TableFormer weights" for the calibration
checklist.

### `RbDocling::Chunking::HybridChunker` (`lib/rb_docling/chunking/hybrid_chunker.rb`)

Mirrors Docling's HybridChunker semantics:

1. **Document-based**: each non-empty node becomes a chunk candidate.
   Heading nodes themselves are skipped (they appear as `headings` metadata
   on subsequent content chunks).
2. **Splitting**: if a chunk exceeds `max_tokens`, split on sentence boundaries.
   Fallback: if no punctuation, split on word groups of ~80 characters.
3. **Merging**: adjacent chunks under the same heading whose combined token
   count is below `max_tokens` AND at least one is below `min_tokens` are merged.

Tokenizer: default is `length/4.0` (GPT/Claude rule of thumb). Pass a custom
`tokenizer:` Proc to use a real BPE.

Chunk output:
```ruby
{
  text: "...",
  token_count: 123,
  metadata: {
    type: :text,
    page_no: 2,
    bbox: [x0, top, x1, bottom],
    headings: [{ level: 1, text: "Capitolo 2" }, { level: 2, text: "2.1 …" }],
    heading_id: "Capitolo 2 > 2.1 …",
    split: true,    # if produced by splitting
    merged: true,   # if produced by merging
  }
}
```

The `heading_id` is denormalized so the chunk can be sorted/filtered in a
vector store without needing the full headings array.

### `RbDocling::Pipeline` (`lib/rb_docling/pipeline.rb`)

Orchestrator. The per-page order is:

1. Extract tables (with or without TableFormer)
2. Run layout analyzer, excluding table bboxes
3. Defense-in-depth: drop any residual block inside a table bbox
4. Append table nodes to blocks
5. Sort by reading order
6. Build `Node` instances

**Why tables-first**: if you run layout first, the layout analyzer sees table
cells as paragraphs and the table-row text gets fused into the surrounding
text blocks. Tables must be carved out first.

## The data flow, with types

```
PDF file (String path)
  │
  ▼ Rpdfium.open
Rpdfium::Document (iterable of Rpdfium::Page)
  │
  ▼ page.words
Array<Hash{x0,top,x1,bottom,fontsize,font,weight,text}>
  │
  ▼ HeuristicLayout / OnnxLayout
Array<Hash{type,text,bbox,font,fontsize,weight,level,page_no,score?}>
  │
  ▼ Pipeline merges with tables, sorts by ReadingOrder
Array<Hash> (ordered)
  │
  ▼ wrap in Node
DocumentTree{nodes: Array<Node>, metadata: Hash}
  │
  ├──▶ to_md → String (Markdown)
  ├──▶ to_h  → Hash (for JSON)
  └──▶ HybridChunker#chunk
       Array<Hash{text, token_count, metadata}>  ← for vector store ingestion
```

## Memory model

- One `Rpdfium::Page` open at a time. After the block ends, rpdfium closes it.
- Image data from `page.render` is a single allocation (W×H×4 bytes) that gets
  garbage collected after `OnnxLayout#analyze` returns.
- ONNX sessions are cached process-wide via `Models::Loader`. They are *not*
  released until process exit. If you build a long-running worker, this is fine
  (better than reloading each request). If you batch-process millions of PDFs,
  consider periodic `Loader.reset!` to release memory.

See `docs/RESOURCES.md` for measured numbers.
