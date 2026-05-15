# Comparison with Docling

This is the **definitive reference** for what `rb_docling` does vs what
Docling does. Update this file whenever a gap is closed.

## Architectural mapping

| Concept | Docling | rb_docling |
|---|---|---|
| Top-level orchestrator | `DocumentConverter` | `RbDocling::Pipeline` |
| Document data model | `DoclingDocument` (Pydantic, true tree with `RefItem`) | `RbDocling::Document::Tree` (flat list + headings_path) |
| Node base | `DocItem` (typed Pydantic subclasses) | `RbDocling::Document::Node` (single class, type enum) |
| Layout analysis | DocLayNet RT-DETR (PyTorch + ONNX) | Heuristic OR ONNX RT-DETR |
| Table structure | TableFormer (autoregressive transformer) | Heuristic (pdfplumber-style) OR ONNX TableFormer (scaffolded) |
| OCR | EasyOCR / RapidOCR / Tesseract | ❌ Not implemented |
| Formula recognition | Custom VLM | ❌ Not implemented |
| Picture description | VLM (configurable) | ❌ Not implemented |
| Reading order | DocLayNet output + post-processing | Geometric column clustering |
| Chunker | `HybridChunker` (tokenizer-aware) | `RbDocling::Chunking::HybridChunker` (same approach) |
| Markdown export | `MarkdownDocSerializer` family | `Node#to_md` + `Tree#to_md` |
| HTML export | Yes | ❌ Not implemented |
| JSON export | Lossless via `export_to_dict()` | Partial via `Tree#to_h` |
| DocTags export | Yes | ❌ Not implemented |

## Feature parity matrix

Legend: ✅ full parity / ⚠️ partial / ❌ missing

### Input formats

| Format | Docling | rb_docling |
|---|---|---|
| PDF (digital) | ✅ | ✅ |
| PDF (scanned) | ✅ via OCR | ❌ |
| DOCX | ✅ | ❌ |
| PPTX | ✅ | ❌ |
| XLSX | ✅ | ❌ |
| HTML | ✅ | ❌ |
| Markdown | ✅ | ❌ |
| Audio (ASR) | ✅ | ❌ |

### PDF parsing capabilities

| Capability | Docling | rb_docling |
|---|---|---|
| Text extraction with bbox | ✅ | ✅ |
| Reading order (single column) | ✅ | ✅ |
| Reading order (multi-column) | ✅ | ⚠️ basic |
| Reading order (complex/wraparound) | ✅ via ML | ❌ |
| Heading detection (heuristic) | ❌ (not needed, uses ML) | ✅ |
| Heading detection (ML) | ✅ | ⚠️ scaffolded |
| Table detection (with borders) | ✅ | ✅ |
| Table detection (borderless) | ✅ via TableFormer | ⚠️ scaffolded |
| Table cell structure (colspan/rowspan) | ✅ | ⚠️ scaffolded |
| List detection (flat) | ✅ | ✅ |
| List detection (nested) | ✅ | ❌ |
| Picture extraction (bbox) | ✅ | ⚠️ placeholder |
| Picture extraction (binary content) | ✅ | ❌ |
| Caption-to-figure association | ✅ | ✅ |
| Code blocks | ✅ | ❌ |
| Formula extraction | ✅ | ❌ |
| Page header/footer detection | ✅ | ⚠️ types defined, heuristic incomplete |

### Markdown export

| Element | Docling MD | rb_docling MD |
|---|---|---|
| `# Title` | ✅ | ✅ |
| `## Heading` (multi-level) | ✅ | ✅ |
| Paragraphs | ✅ | ✅ |
| Tables with header row | ✅ | ✅ |
| Tables with colspan/rowspan (linearized) | ✅ | ❌ |
| Flat bullet list | ✅ | ✅ |
| Nested list | ✅ | ❌ |
| Numbered list | ✅ | ⚠️ same as bullet |
| Images `![alt](path)` | ✅ | ⚠️ placeholder URL |
| Image captions | ✅ | ✅ |
| Code fences ` ``` ` | ✅ | ❌ |
| LaTeX formulas `$$ ... $$` | ✅ | ❌ |
| Plain text mode (`strict_text`) | ✅ | ✅ |
| HTML mode | ✅ | ❌ |
| DocTags mode | ✅ | ❌ |

### Chunking

| Feature | Docling | rb_docling |
|---|---|---|
| Document-based chunking | ✅ | ✅ |
| Token-aware splitting | ✅ | ✅ |
| Token-aware merging | ✅ | ✅ |
| Heading path in chunk metadata | ✅ | ✅ |
| Page number in chunk metadata | ✅ | ✅ |
| Bbox per chunk | ✅ | ✅ |
| Pluggable tokenizer | ✅ (HF tokenizers) | ✅ (Proc injection) |
| Default real BPE tokenizer | ✅ (MiniLM) | ❌ (4-char approximation) |
| Caption included in image chunk | ✅ | ✅ |
| Table as chunk (Markdown serialized) | ✅ | ✅ |

### Operational

| Aspect | Docling | rb_docling |
|---|---|---|
| Native Python | ✅ | n/a |
| Native Ruby | ❌ | ✅ |
| ONNX inference | ✅ | ✅ |
| CUDA acceleration | ✅ | ⚠️ (depends on onnxruntime-gpu in Ruby; not tested) |
| MLX (Apple) acceleration | ✅ | ❌ |
| RAM (no ML) | ~200MB | ~50MB |
| RAM (with ML, quantized) | ~500MB | ~300MB (target) |
| RAM (with ML + OCR) | 1.5-3GB | n/a |
| Speed (no ML, per page) | ~0.2s | ~0.1s (smaller scope, no OCR check) |
| Speed (with ML, per page, CPU) | ~0.8s | ~1-2s (target, slower preprocessing) |
| Speed (with ML + GPU) | ~0.1s | ❌ |
| Parallelism strategy | multiprocessing | Process.fork (GIL avoidance) |

## What we got from this conversation

The current state was iterated through these milestones:

1. **Initial analysis**: weighed rpdfium+ruby_llm vs docling+langchain, decided
   on Ruby port with ONNX (`docs/DESIGN_DECISIONS.md` decision 1).
2. **Layout heuristic**: built font/position-based classifier; works on
   "clean" PDFs.
3. **Reading order**: column clustering for multi-column.
4. **Heuristic table extraction**: rpdfium wrapper with false-positive filters.
5. **Hybrid chunker**: split/merge with heading path metadata.
6. **ONNX scaffold for layout**: RT-DETR-style with auto-detect of bbox format.
7. **ONNX scaffold for TableFormer**: encoder + autoregressive decoder structure,
   placeholder OTSL vocabulary.
8. **Bugfixes**: integer division in IoU, false-positive tables, heading-paragraph
   fusion, inline bullet split, list bullet duplication in Markdown.
9. **Markdown export improvements**: `strict_text` mode, caption association.
10. **Benchmark harness** (`rb_docling_bench/`): Dockerfile + comparison script.

## Honest assessment as of handoff

- **For programmatically-generated PDFs with bordered tables**: heuristic
  mode produces output close to Docling's quality (~70-85% similarity on the
  benchmark suite when run against real Docling).
- **For complex scanned PDFs**: we don't do OCR, so we produce nothing useful.
- **For PDFs with borderless tables**: we miss them in heuristic mode;
  TableFormer scaffolding is ready but uncalibrated.
- **For multi-column scientific papers**: heuristic reading order is OK for
  2-column journal style, breaks on complex sidebar layouts.

The gap that **matters most** for the user's actual goal (RAG over Italian
technical documents) is probably borderless tables and nested lists. Headings
are usually well-classified. Reading order on Italian business documents
(single column) is rarely an issue.
