# Conversation Log

A condensed record of the conversation that produced this codebase. Useful
context if Claude Code is asked "why was X done this way?" and the answer
isn't in the other docs.

## Phase 1: Library evaluation

**User**: needed to build a project that reads PDFs and prepares them for AI
consultation. Initial idea was Docling or LangChain, but wanted to compare
with rpdfium + ruby_llm.

**Outcome**: produced a detailed analysis (see `DESIGN_DECISIONS.md` decision
1). Concluded that the libraries operate at different abstraction levels —
Docling is a full pipeline, rpdfium is a PDF parser, ruby_llm is an LLM client.
Direct comparison was misleading.

## Phase 2: Understanding Docling's depth

**User**: asked about chunking, then HybridChunker, then DocLayNet.

**Key clarification**: `DocLayNet.py` on HuggingFace is a **dataset loader
script**, not a model. The actual layout analysis in Docling uses neural
networks trained *on* DocLayNet. This was a real misconception that needed
correcting.

**Outcome**: established that reproducing Docling in Ruby means either
training models from scratch (out of scope) or using pre-trained ONNX
weights (feasible).

## Phase 3: TableFormer deep dive

**User**: asked specifically about TableFormer.

**Key technical points**:
- TableFormer is encoder-decoder with autoregressive structure decoding (OTSL vocabulary)
- Unlike RT-DETR (single-shot detection), TableFormer requires a decoding loop
- The decoding loop is the expensive part to implement; the encoder is straightforward
- ONNX weights exist on Hugging Face (`asmud/ds4sd-docling-models-onnx`)

**Outcome**: established that TableFormer is feasible but more empirical
than the layout model.

## Phase 4: Implementation attempt

**User**: pushed back when Claude initially said "I can't test rpdfium here".
**Turned out the user was right**: with effort, the container had everything
needed.

**Process**:
1. Installed Ruby 3.2 via apt
2. Installed ffi via apt
3. Cloned rpdfium from GitHub (rubygems.org blocked)
4. Found `libpdfium.so` already on disk via Python's pypdfium2
5. Cloned onnxruntime-ruby, symlinked the Python onnxruntime's `.so`
6. Built the full pipeline iteratively, testing each module

**Lesson for Claude Code**: don't reflexively say "I can't" when the user
pushes back. Try harder. The user has context you may lack.

## Phase 5: Bug iteration

Iterated through several real bugs caught by testing:

- **Integer division in IoU**: `inter / union` returned 0 with Integer operands. Fix: `.to_f`.
- **Heading + paragraph fusion**: heuristic block grouping was too lenient. Fix: split on any significant fontsize change.
- **Table false positives**: rpdfium's `:lines` strategy found "tables" in lists. Fix: validity filters (min cols, min non-empty ratio).
- **Inline bullets fused**: "Lista: • a • b • c" came out as one block. Fix: split_inline_bullets postprocessor.
- **List item bullet duplicated in Markdown**: `to_md` emitted "- • foo". Fix: strip leading bullets from list_item text.

These were caught by writing more rigorous tests after each change. The
"36 tests passing" baseline is non-negotiable.

## Phase 6: Markdown export improvement

**User**: asked how the Markdown export compares to Docling's.

**Outcome**:
- Confirmed the architectural flow is identical (DocumentTree → per-node serializer)
- Identified specific gaps (nested lists, image extraction, formulas, DocTags)
- Added `strict_text` mode and `associate_captions` helper
- See `docs/COMPARISON_DOCLING.md` for exhaustive feature matrix

## Phase 7: Resource analysis

**User**: asked for memory and CPU estimates.

**Outcome**: produced measured numbers + estimates with real Docling weights.
Documented in `docs/RESOURCES.md`. Headline: ~50 MB heuristic, ~300 MB full
ONNX quantized, ~1.5 GB with OCR.

## Phase 8: Benchmark harness

**User**: suggested using a Dockerfile to run real comparisons.

**Outcome**: built `rb_docling_bench/` as a separate package — Dockerfile,
PDF generator, both runners, comparator producing REPORT.md side-by-side.
The docker build was not testable in the dev container (no docker
available) but the underlying scripts were validated by running them
directly.

## Phase 9: This handoff

**User**: requested a CLAUDE.md and supporting docs so the work can continue
in a new Claude Code session.

**Decision points captured**:
- Why Ruby and not Python sidecar (`DESIGN_DECISIONS.md` 1)
- Why rpdfium specifically (`DESIGN_DECISIONS.md` 2)
- Why ONNX (`DESIGN_DECISIONS.md` 3)
- Why flat tree (`DESIGN_DECISIONS.md` 4)
- Why plain Ruby smoke test (`DESIGN_DECISIONS.md` 5)
- Why approximate tokenizer default (`DESIGN_DECISIONS.md` 6)
- Why no OCR yet (`DESIGN_DECISIONS.md` 7)
- Honest scaffolding policy (`DESIGN_DECISIONS.md` 8, `CLAUDE.md`)
- Tables-first order (`DESIGN_DECISIONS.md` 9)

## Communication style observed

The user:
- Speaks Italian preferentially; Claude responded in Italian throughout the conversation
- Wants direct technical conversation
- Pushes back when Claude is too cautious (and is usually right to do so)
- Says "procedi" / "continua" when they want Claude to keep going without permission requests
- Appreciates honest scoping ("I can do this, I can't do that, here's why")
- Has a Ruby/Rails background based on context clues
- Is building a real production system, not experimenting

Claude Code should match this style: efficient, technical, honest about
limits, and willing to keep going when the path is clear.
