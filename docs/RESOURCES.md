# Resources

Memory and CPU profiling, with deployment sizing recommendations.

## Measured numbers

Measured on a Linux x86_64 container during the development conversation.
These are reproducible by running `/usr/bin/time -v` on the smoke test or
CLI invocations.

### Heuristic mode

| Scenario | Pages | RAM peak (RSS) | Wall time | CPU user |
|---|---|---|---|---|
| `test2.pdf` (1 table, 1 list) | 2 | 31 MB | 0.3 s (excluding Ruby startup) | 0.16 s |
| `big.pdf` (synthetic, dense) | 40 | 210 MB | 4.66 s | 4.67 s |

Amortized: ~5 MB extra RAM per page, ~0.1 s/page CPU.

### ONNX dummy mode

| Scenario | Pages | RAM peak | Wall time |
|---|---|---|---|
| Same `test2.pdf` with dummy RT-DETR loaded | 2 | 91 MB | 2.15 s |

The ~60 MB overhead vs heuristic is the ONNX Runtime baseline (session,
threadpool, allocator). The dummy model itself is < 1 KB.

## Estimated numbers with real models

Based on weights' actual sizes from `docling-project/docling-models` and
`asmud/ds4sd-docling-models-onnx`:

### Layout RT-DETR (heron-101 or DFINE)

- ONNX fp32: 120-200 MB on disk
- ONNX int8 (quantized): 40-60 MB on disk
- RAM in inference: weight × 1.5 (activations) ≈ 250-400 MB fp32, 80-120 MB int8

### TableFormer

- ONNX fp32: 50-60 MB on disk (encoder + decoder combined)
- ONNX JPQD quantized: 15-20 MB on disk
- RAM in inference: 100-150 MB fp32, 40-60 MB int8
- Per-step decoding cost: a few MB temporary, multiplied by ~50-200 steps per table

### OCR (if added later)

- Tesseract: ~50 MB
- EasyOCR / RapidOCR: 1-2 GB (deep models)

## Deployment sizing

### Tier 1: heuristic only

```
Process: 50-100 MB resident
Per-page working: 5-10 MB transient
```

Fits in 256 MB container (Heroku eco dynos, AWS Lambda's 256 MB tier).
Suitable for low-throughput RAG indexing pipelines (< 10 PDFs/min per worker).

### Tier 2: heuristic + onnx layout (quantized)

```
Process: 200-300 MB resident
Per-page working: 50-100 MB transient (image render + tensors)
```

Fits in 512 MB container. Recommended for production RAG with quality
heading classification.

### Tier 3: full ONNX (layout + TableFormer, quantized)

```
Process: 300-450 MB resident
Per-page working: 50-150 MB transient
```

Recommended: 1 GB container, 2 vCPU. Throughput target: 0.5-1 page/s/worker on CPU.

### Tier 4: full ONNX (fp32, with OCR)

```
Process: 1.5-3 GB resident
Per-page working: 200-500 MB transient
```

4 GB RAM minimum, 4 vCPU recommended. Consider GPU for throughput.

### GPU tier (reference)

Docling on AWS L4 (24 GB VRAM):
- 4-8 GB VRAM for layout + TableFormer fp32
- 16 GB VRAM if OCR on GPU
- Throughput: 100-150 ms/page

This is **Docling's measured benchmark**; rb_docling on GPU is untested and
requires `onnxruntime-gpu` integration (not done).

## Parallelization

Ruby MRI has GIL → multi-threading is mostly useless for CPU-bound work.
For scaling out:

### Per-PDF parallelism: `Process.fork`

```ruby
def parse_many(pdf_paths, workers: 4)
  queue = Queue.new
  pdf_paths.each { |p| queue << p }
  workers.times.map do
    Process.fork do
      while (pdf = queue.pop(true) rescue nil)
        RbDocling.parse(pdf)
        # write result to disk or shared store
      end
    end
  end.each { |pid| Process.wait(pid) }
end
```

Copy-on-write means ONNX session memory is shared until first write,
significantly reducing per-worker overhead.

### Production: sidekiq workers

Recommended pattern: one job per PDF, scaled with sidekiq concurrency
matching CPU count. The job:

```ruby
class ParsePdfJob
  include Sidekiq::Job
  def perform(pdf_path, output_path)
    tree = RbDocling.parse(pdf_path)
    File.write(output_path, JSON.dump(tree.to_h))
  end
end
```

Each sidekiq worker (process) gets its own ONNX session cache. Concurrency
inside a process should be 1 if the work is CPU-bound; use threads only
for I/O-bound stages.

### Avoid: threads inside a process

Don't try to parse multiple PDFs in threads within the same process — the
GIL serializes them, and you waste the parallelism budget.

## Memory leaks

Known sources of growth in long-running workers:

1. **ONNX session cache**: `Models::Loader` doesn't evict. Add LRU if you
   load many different models. For the standard 2-model setup (layout +
   tableformer), cache grows to a fixed size and stops.
2. **rpdfium handles**: closed via the block API (`Rpdfium.open(...) do |doc|`).
   If you bypass this and use `Document#open`/`#close` manually, you can
   leak handles. **Always use the block form**.
3. **Large image buffers in OnnxLayout**: the RGBA buffer (W×H×4 bytes) is
   allocated as a Ruby String. Ruby's GC handles this fine; no manual action
   needed.

For workers processing thousands of documents, schedule `GC.start` between
batches and consider periodic `Models::Loader.reset!` if you don't need
hot model loading.

## Profiling commands

```bash
# Peak RAM
/usr/bin/time -v ruby -I lib bin/rb_docling input.pdf --out md

# CPU profile (basic)
ruby -I lib -r 'rprof' bin/rb_docling input.pdf --out md  # not implemented yet

# Memory profile per allocation
ruby -I lib -r 'memory_profiler' -e '
require "memory_profiler"
require "rb_docling"
report = MemoryProfiler.report do
  RbDocling.parse("input.pdf")
end
report.pretty_print(to_file: "memprof.txt", top: 20)
'
```

`memory_profiler` gem must be installed separately; it's not a runtime
dependency.

## When to optimize

Don't optimize speculatively. Measure first. The bottlenecks identified
so far:

1. **`OnnxLayout` preprocessing** (Ruby pixel loop): ~80% of layout-mode time
   on large pages. Fix: use `numo-narray` or C extension.
2. **`HeuristicLayout#group_into_lines`**: O(n log n) due to sort; fine for
   normal pages, can be slow on pages with thousands of words. Fix: bucket sort.
3. **Markdown serialization**: linear; no known issue.

For most users, none of these matter. Optimize only when the user shows you
a real bottleneck with a profile.
