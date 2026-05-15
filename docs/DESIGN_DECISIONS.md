# Design Decisions

This document captures the reasoning behind significant architectural choices.
Read this **before** suggesting major refactors.

## Decision 1: Build a Ruby port instead of using a Python sidecar

### Considered alternatives

1. **Use Docling directly from a Python microservice** consumed via HTTP from Ruby.
2. **Use LangChain via a similar microservice approach**.
3. **Port a meaningful subset of Docling to Ruby** (chosen).

### Why we chose port-to-Ruby

The user explicitly preferred a single-stack Ruby/Rails deployment. The
maintenance, packaging, and operational complexity of a Python sidecar was
considered higher than the engineering cost of a Ruby port for the *subset*
of functionality the user actually needs.

### When this decision should be revisited

- If the user's deployment constraints change to allow Python services
- If the gap to Docling on PDF quality becomes a real blocker (e.g., heavy OCR
  needs, formula extraction)
- If we encounter a problem in Ruby's ML ecosystem that has no reasonable
  workaround (so far we haven't)

If revisiting, don't propose "rewrite to Python" — propose a hybrid where the
ML-heavy parts run in a sidecar but the Ruby `DocumentTree`/`HybridChunker`
stays in-process. The Ruby chunker is genuinely useful regardless of where
parsing happens.

## Decision 2: Use rpdfium (not pdf-reader, not poppler bindings)

### Considered alternatives

- **`pdf-reader` gem** (pure Ruby): more mature, no native dependency. **Limit**:
  text extraction only; no bbox per character, no font metadata, no table support.
- **Poppler bindings**: heavyweight, GTK/glib transitive deps, awkward FFI.
- **rpdfium**: same engine Chrome uses, exposes char-level metadata + table
  extraction in pdfplumber style.

### Why rpdfium

We need bbox per character, font name + size + weight, and table extraction
out of the box. rpdfium provides all three. PDFium is also the engine Docling
uses internally (via pypdfium2), so output characteristics are compatible.

### Concerns about rpdfium

The gem is young (0 stars, no releases on RubyGems at the time of choice). We
mitigate by:
- Cloning a specific commit hash rather than depending on a published version
- Wrapping all rpdfium API calls in our own modules so the surface area is small

If rpdfium goes unmaintained, we can fork it or replace it with another PDFium
binding without changing user-visible API.

## Decision 3: ONNX Runtime, not direct PyTorch

### Why not torch.rb or libtorch bindings

- **Cross-platform**: ONNX Runtime has clean prebuilt binaries for Linux/macOS/Windows on x64 and ARM.
- **Smaller footprint**: libtorch is hundreds of MB; libonnxruntime is ~14MB.
- **Inference-only**: we never train, we only run pre-built models. ONNX Runtime is purpose-built for this.
- **Ecosystem**: most Docling weights are already published in ONNX form
  (Microsoft + Docling community both invest in ONNX).

### Why not Hugging Face Candle (Rust)

Considered. Would require either rewriting in Rust or building Ruby-Rust FFI
bindings. Adds complexity without clear gain over ONNX Runtime's mature Ruby
binding.

## Decision 4: Flat node list, not true tree

### What we chose

`DocumentTree#nodes` is a flat ordered `Array<Node>`. Hierarchy is implicit
in `level` field and reconstructed via `headings_path_for(node_index)`.

### What Docling does

`DoclingDocument` has true parent/child relationships through `RefItem`
indirection (avoiding circular references for pydantic serialization).

### Why we went flat

- **Simpler code**: no parent pointer management, no orphan handling
- **Sufficient for RAG**: the chunker walks linearly and reads parent headings;
  doesn't need O(1) parent lookup
- **Easier for heuristic layout**: pages produce blocks in order, no tree
  rebalancing needed

### When this becomes wrong

If the user needs to:
- Extract a subtree (e.g., "give me Chapter 3 and all its children as a new document")
- Restructure: move sections around
- Render to a format that requires explicit nesting (e.g., proper HTML `<section>` tags)

Then upgrading to a real tree is justified. **Don't do it preemptively** —
the conversion is mechanical once the use case exists.

## Decision 5: Smoke test in plain Ruby, not RSpec/Minitest

### Why

- Zero new dependencies for the user
- Trivial to run: `ruby spec/smoke_test.rb path.pdf`
- Trivial for Claude Code to extend (add `assert` lines)
- Output is immediately readable

### When to revisit

If the test file grows past ~500 lines or we need fixtures/mocks beyond a
PDF input, switch to Minitest (it ships with Ruby) rather than RSpec. RSpec
brings DSL overhead that doesn't pay off for this codebase.

## Decision 6: HybridChunker uses ~4 char/token approximation by default

### What we chose

Default tokenizer is `(length / 4.0).ceil`. Users pass a custom Proc for real BPE.

### Why not require a real tokenizer

- No good pure-Ruby BPE implementation exists for cl100k/o200k
- Wrapping tiktoken via FFI is doable but heavyweight
- Most users producing chunks will know their target embedding model and can
  inject the right tokenizer

### When to revisit

If we standardize on a specific embedding model family (e.g., OpenAI's
text-embedding-3-small uses cl100k), it would be worth shipping a small
tokenizer extension. Until then, the Proc injection keeps it flexible.

## Decision 7: No OCR by default

### Rationale

OCR is a significant addition:
- EasyOCR/RapidOCR are PyTorch-based; integrating them in Ruby is non-trivial
- Tesseract is C++ and shells out cleanly, but adds a system dependency
- Most early users of `rb_docling` will have programmatically-generated PDFs,
  not scans

The honest position is "OCR is out of scope v1". A scanned PDF should produce
an empty or near-empty tree, which is a clear signal to the user that they
need to OCR upstream.

### Future direction

If OCR is added, do it as a separate gem (`rb_docling-ocr`) that monkey-patches
or extends `Pipeline`. Don't bloat the core gem with PyTorch transitive deps.

## Decision 8: Honest scaffolding for TableFormer

### What it means

The `OnnxTableFormer` module has correct structure but:
- Placeholder OTSL vocabulary (`%w[<pad> <start> <end> fcel ecel lcel ucel xcel nl]`)
- Decoder I/O name heuristics that may not match a specific export
- Greedy decoding without KV cache

This was a deliberate choice: writing 500 lines of "looks complete but
hallucinated" code would have wasted the user's debugging time later.

### How to complete it

See `docs/ROADMAP.md` for the calibration checklist. The path is empirical:
load the real ONNX, inspect inputs/outputs, run inference on known tables,
iterate.

## Decision 9: Run tables-first, then layout

### What it means

`Pipeline#parse` for each page:
1. Extract tables (heuristic or ML)
2. Then run layout, excluding word inside table bboxes

### Why

If layout runs first, the table cells are interpreted as paragraphs and get
fused into surrounding text. Carving tables out first prevents this.

### Cost

Tables are extracted even on pages that have none — wasted work for many
documents. Profile shows this is fast for `HeuristicTable` (uses rpdfium's
native code). For `OnnxTableFormer`, we still need a *layout* model first to
locate tables. Hence: in `:onnx` mode, the future architecture is

1. Layout model finds Table bboxes
2. TableFormer extracts structure from each Table bbox
3. Layout model output is used for all other element classification

The current code does (1) via `HeuristicTable.new.extract(page)` even in ONNX
mode (see `Pipeline#extract_tables`). This is a known temporary shortcut;
once the real layout model is wired, switch to using its Table detections.

## Anti-patterns to avoid

These are things Claude Code might be tempted to suggest. Avoid them:

1. **"Let's add a DSL for defining new node types"** — no. The 11 DocLayNet
   types are the design surface. Adding types is a deliberate API decision,
   not a feature to make easy.

2. **"Let's introduce dry-types/dry-struct"** — no. Structs and plain hashes
   work fine, and adding dry-rb makes the gem heavier for users.

3. **"Let's use Sorbet/RBS"** — discussion-worthy, but defer. The codebase is
   small enough that type annotations would be more cost than benefit. Revisit
   when the gem hits 5K LOC.

4. **"Let's rewrite the chunker as state machine"** — the current split/merge
   loop is 50 lines of imperative code that reads top-to-bottom. Don't
   over-engineer.

5. **"Let's parallelize across pages with threads"** — Ruby's GIL plus the
   FFI calls to libpdfium make multi-threading mostly useless for CPU-bound
   work. Use `Process.fork` (or sidekiq workers in production) to parallelize
   across PDFs, not pages.

6. **"Let's add metrics/logging via a logger gem"** — start with `warn`. If
   logging becomes a real need, add it as an *optional* dependency configured
   via `RbDocling.logger = ...`.
