# Benchmark Harness

The `rb_docling_bench` companion package (separate folder/repo) runs both
`rb_docling` and Docling on the same PDFs and produces a comparison report.

## When to use it

- Validating that a code change in `rb_docling` improved or regressed quality
- Quantifying the gap to Docling on a specific document type
- Sharing results with the user as evidence

## Quick reference

```bash
cd rb_docling_bench
docker build -t bench .
docker run --rm -v "$(pwd)/out:/work/out" bench
cat out/REPORT.md
```

## What it measures per PDF

| Metric | Source | Interpretation |
|---|---|---|
| `similarity` | `difflib.SequenceMatcher` on normalized MD | Content overlap, not structure |
| `node_count` | Docling: `iterate_items()`, rb_docling: `tree.nodes` | Granularity of parsing |
| `table_count` | Count of TableItems/`:table` nodes | True positives + false positives |
| `heading_count` | Count of heading-type items | Heading detection completeness |
| `chunk_count` | Chunker output size | Chunking granularity |
| `parse_seconds` | Time excluding chunker | Parse-only cost |
| `chunk_seconds` | Chunker time | Chunker-only cost |
| `rss_after_kb` | Process peak RSS (linux) | Memory cost |

The similarity metric is the **roughest** indicator. Reading the side-by-side
Markdown in `REPORT.md` is much more informative.

## Custom PDFs

Replace the synthetic suite with your own:

```bash
mkdir my_pdfs && cp /path/to/*.pdf my_pdfs/
docker run --rm \
  -v "$(pwd)/my_pdfs:/work/pdfs" \
  -v "$(pwd)/out:/work/out" \
  -e SKIP_GENERATE=1 \
  bench
```

## Interpreting low similarity scores

A similarity below 0.5 usually means one of:

1. **Tables not detected by rb_docling**: Docling found them, we didn't.
   Look at the table_count delta.
2. **Headings classified at different levels**: e.g., Docling sees `## 1.1`
   as level 2, we see it as level 1. Look at the heading_count delta and
   spot-check the Markdown.
3. **OCR'd text in Docling, blank in rb_docling**: the PDF has scanned pages.
   We don't OCR; that's a category-of-document mismatch.
4. **Different reading order on multi-column**: text is the same, ordering
   differs. The chunker may still produce equivalent chunks for RAG.

## Tuning the benchmark for RAG signal

The current similarity metric is good for "is the Markdown roughly the same?"
but **doesn't measure RAG quality**. To measure that:

1. Pick a corpus and a list of queries with known relevant chunks
2. Embed all chunks from each pipeline (same embedding model, e.g., MiniLM)
3. For each query: embed, retrieve top-K from each pipeline's index
4. Compute recall@K, MRR

This is the **right** benchmark for the user's actual use case. It's not
implemented yet; see `docs/ROADMAP.md` 3.2.
