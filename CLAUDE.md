# CLAUDE.md

This file gives Claude Code the context it needs to continue work on this
repository. Read this first, then `docs/ARCHITECTURE.md` and `docs/ROADMAP.md`
before making changes.

## What this project is

`rb_docling` is a **Ruby port of a subset of [Docling](https://github.com/docling-project/docling)**
(IBM Research's document understanding toolkit). The goal is to provide a
production-grade PDF → structured document → RAG-ready chunks pipeline that
runs natively in Ruby/Rails environments, without requiring a Python sidecar
service.

```
PDF → rpdfium (text+bbox) ─┐
                           ├→ Layout (heuristic | ONNX RT-DETR) ─┐
                           ├→ Tables (heuristic | ONNX TableFormer) ─┤
                           └→ Reading order + DocumentTree ←────────┘
                                                                    │
                                                                    ↓
                                                         HybridChunker → chunks for RAG
```

## Why this approach (read before suggesting changes)

The user originally considered Docling/LangChain in Python. We did an extensive
analysis (see `docs/DESIGN_DECISIONS.md`) and concluded that for a Ruby-first
deployment:

- **rpdfium** provides solid PDF text+bbox extraction (binding to PDFium, same
  engine Chrome uses) — comparable in quality to PyPDFium2 which Docling uses.
- **onnxruntime-ruby** can run the same ML models Docling uses, provided the
  weights are exported to ONNX.
- **The hard parts are not the ML inference**: they are (a) building the
  DocLayNet-style semantic tree from raw bbox detections, (b) implementing
  TableFormer's autoregressive decoding, (c) reading order on multi-column
  layouts.

We chose **not** to pursue a Python microservice route because the user has a
Ruby/Rails stack constraint. If you (Claude Code) are tempted to suggest "just
wrap Docling in a Python service", re-read `docs/DESIGN_DECISIONS.md` first —
this was discussed and explicitly rejected.

## Current state

**Working and tested**:
- Heuristic pipeline end-to-end on real PDFs (single-page and multi-page)
- 34 smoke tests passing
- ONNX runtime integration tested with dummy models (real model weights not yet integrated)
- HybridChunker with token-aware split/merge
- Markdown export with `strict_text` option and caption-to-picture association
- CLI (`bin/rb_docling`)

**Tested in the previous Claude conversation, not necessarily in this repo yet**:
The development happened in a sandbox. The handoff bundle contains the latest
working state. Verify by running the smoke tests as the first step (see
"First steps for Claude Code" below).

**Not yet done (see `docs/ROADMAP.md` for priorities)**:
- Real model weights wiring (DocLayNet RT-DETR + TableFormer from HuggingFace)
- Calibration of OTSL vocabulary for TableFormer (placeholder values currently)
- Image physical extraction (currently emits `![image](#)` placeholder)
- Nested list support
- OCR for scanned PDFs

## Repository layout

```
.
├── CLAUDE.md                  ← you are here
├── README.md                  ← user-facing docs
├── Gemfile
├── bin/
│   └── rb_docling             ← CLI entry point
├── lib/
│   └── rb_docling/
│       ├── document/
│       │   ├── bbox.rb        ← value object for bounding boxes
│       │   ├── node.rb        ← typed nodes (title, text, table, ...)
│       │   └── tree.rb        ← DocumentTree with headings_path
│       ├── layout/
│       │   ├── heuristic_layout.rb   ← font/position-based classification
│       │   ├── onnx_layout.rb        ← RT-DETR wrapper
│       │   └── reading_order.rb      ← column clustering
│       ├── table/
│       │   ├── heuristic_table.rb    ← Rpdfium::Table::Extractor wrapper
│       │   └── onnx_tableformer.rb   ← TableFormer encoder+decoder
│       ├── chunking/
│       │   └── hybrid_chunker.rb     ← split/merge token-aware
│       ├── models/
│       │   └── loader.rb             ← ONNX session cache singleton
│       └── pipeline.rb               ← orchestrator
├── spec/
│   └── smoke_test.rb          ← 34 tests, no rspec dependency
├── models/                    ← empty by default; ONNX weights go here
└── docs/
    ├── ARCHITECTURE.md        ← detailed module-by-module design
    ├── DESIGN_DECISIONS.md    ← rationale & rejected alternatives
    ├── ROADMAP.md             ← prioritized work items
    ├── RESOURCES.md           ← memory/CPU profiling & deployment sizing
    ├── COMPARISON_DOCLING.md  ← exact gaps vs Docling, feature-by-feature
    └── ENVIRONMENT.md         ← runtime requirements, native libs, gotchas
```

## First steps for Claude Code in a new session

1. **Verify the environment**: read `docs/ENVIRONMENT.md` and ensure Ruby +
   FFI + libpdfium are available. The smoke test will tell you if anything is
   missing.
2. **Run the smoke tests**:
   ```bash
   export PDFIUM_LIBRARY_PATH=/path/to/libpdfium.so
   ruby -I lib spec/smoke_test.rb spec/fixtures/test.pdf
   ```
   All 34 tests must pass before any new work. If they don't, **fix that first**
   — don't build on a broken baseline.
3. **Read `docs/ROADMAP.md`** to see what's next.
4. **Ask the user** what they want to tackle. Don't assume.

## Critical conventions

### Honest scaffolding policy

When implementing something that depends on external resources (model weights,
APIs, libraries) that you cannot test in the current session, follow this rule:

- **Do not write code that looks complete but isn't tested**. The previous
  conversation explicitly established this: if you write 1000 lines of
  TableFormer decoder logic that you cannot run against real weights, you're
  setting the user up for days of debugging your hallucinations.
- **Use explicit TODO markers** and document the calibration points (e.g.,
  "The OTSL vocabulary order must be verified against the real .onnx file —
  see config.json in the HuggingFace repo").
- **Build the scaffold, leave honest stubs**. The user already understands
  this trade-off — they've seen it work.

### Code style

- `# frozen_string_literal: true` on every file
- Ruby 3.2+ idioms (keyword arguments, pattern matching where it helps clarity)
- No external gems beyond `rpdfium` and `onnxruntime` unless absolutely necessary
- No testing framework dependency: `spec/smoke_test.rb` is plain Ruby
- Errors raised via `RbDocling::Error` subclass; rescue `StandardError` only at
  pipeline boundaries with a `warn` message
- Public API surface is small and stable; internal modules can evolve freely

### Naming

The codebase deliberately mirrors Docling's naming where it makes sense:
- `DocumentTree` ≈ `DoclingDocument`
- `HybridChunker` (same name)
- Node types use the DocLayNet labels (`:section_header`, `:caption`, `:list_item`...)

This makes the comparison with Docling explicit. Keep this convention.

### Testing convention

`spec/smoke_test.rb` is a single file with plain assertions and a pass/fail
exit code. No rspec, no minitest. **Reasons**:
- Zero setup friction for the user
- Runs everywhere Ruby runs
- Easy for Claude Code to extend (just add `assert ...`)

Add new tests there. If it grows past ~500 lines, *then* consider splitting.

## Common pitfalls

1. **`libpdfium.so` not found**: the env var `PDFIUM_LIBRARY_PATH` must point
   to the file directly, not to its directory. If the user has `pypdfium2`
   installed in Python, that binary works (see ENVIRONMENT.md).

2. **Integer division in BBox**: Ruby's `/` is integer division when both
   operands are integers. The `iou` method was bugged for this reason. Always
   use `.to_f` when bbox coordinates might be integers.

3. **False-positive tables**: `Rpdfium::Table::Extractor` with strategy
   `:lines` can interpret bullets and section borders as tables. The
   `HeuristicTable#valid_table?` filter handles this — don't remove it.

4. **Block grouping fuses heading with following paragraph** when fontsize
   doesn't change enough. This is a *known limit of pure heuristics*; the fix
   requires either tighter ML layout or document-specific tuning.

5. **`/bin/sh` doesn't expand brace expansion**. If you run shell commands
   with `{a,b,c}` patterns from Ruby/Python `system()`, they may not expand.
   Use bash explicitly or full paths.

## How to ask the user about ambiguity

The user prefers **direct, technical conversation**. They appreciate:
- Honesty about what you cannot do or test
- Concrete trade-offs (cost A vs cost B, with numbers when possible)
- Pushback when they suggest something you think is suboptimal
- *Not* being asked redundant clarifying questions when context is already clear

They will tell you "continue" or "procedi" when they want you to keep going
on a task you already have enough context for. Don't ask for permission for
small, obvious next steps.

## Companion: benchmark harness

A separate repo/folder `rb_docling_bench` exists with a Dockerfile that runs
both `rb_docling` and Docling on the same PDFs and produces a comparison
report. If the user wants to validate quality improvements, that's the tool.
See `docs/BENCHMARK.md` in this repo for details.
