# Environment

Setup requirements and known gotchas. Read this before debugging installation issues.

## Required

| Component | Version | Why |
|---|---|---|
| Ruby | 3.2+ | Uses keyword args, pattern matching |
| FFI (ruby gem) | 1.16+ | rpdfium and onnxruntime bindings |
| libpdfium (native) | latest | PDF parsing |
| libonnxruntime (native) | 1.17+ | ML inference |
| OS | Linux x86_64, macOS, or Windows | All ONNX Runtime supported platforms |

## Optional

| Component | Why |
|---|---|
| Python 3.10+ + reportlab | Generating test PDFs |
| Docker | Running the comparison benchmark |
| huggingface-cli | Downloading real ONNX model weights |

## Installation

### Linux (Ubuntu/Debian)

```bash
sudo apt-get install -y ruby-full ruby-ffi build-essential
gem install bundler

# libpdfium: either via apt (limited) or download prebuilt
curl -L -o pdfium.tgz \
  https://github.com/bblanchon/pdfium-binaries/releases/latest/download/pdfium-linux-x64.tgz
mkdir -p ~/pdfium && tar xzf pdfium.tgz -C ~/pdfium
echo 'export PDFIUM_LIBRARY_PATH=$HOME/pdfium/lib/libpdfium.so' >> ~/.bashrc
source ~/.bashrc

# libonnxruntime: bundled with the onnxruntime gem on supported platforms,
# otherwise install manually:
# curl -L -O https://github.com/microsoft/onnxruntime/releases/...
```

### macOS

```bash
brew install ruby
gem install bundler ffi

# libpdfium prebuilt
curl -L -o pdfium.tgz \
  https://github.com/bblanchon/pdfium-binaries/releases/latest/download/pdfium-mac-arm64.tgz
# or pdfium-mac-x64.tgz for Intel
mkdir -p ~/pdfium && tar xzf pdfium.tgz -C ~/pdfium
export PDFIUM_LIBRARY_PATH=$HOME/pdfium/lib/libpdfium.dylib
```

### Inside Docker

See `rb_docling_bench/Dockerfile` for the canonical setup. Key snippets:

```dockerfile
RUN apt-get install -y ruby-full ruby-ffi build-essential

# Get libpdfium for free via pypdfium2 (smaller than downloading separately):
RUN pip install --break-system-packages pypdfium2 onnxruntime
ENV PDFIUM_LIBRARY_PATH=/usr/local/lib/python3.12/dist-packages/pypdfium2_raw/libpdfium.so

# Get libonnxruntime via Python install too:
RUN ln -sf $(python3 -c "import onnxruntime, os; print(os.path.join(os.path.dirname(onnxruntime.__file__), 'capi', 'libonnxruntime.so.' + onnxruntime.__version__))") \
        /opt/onnxruntime-ruby/vendor/libonnxruntime.so
```

This trick (using pypdfium2's bundled libpdfium and onnxruntime's bundled .so)
is **the simplest cross-platform path** if Python is acceptable in the
environment. It saves ~50MB and avoids matching libc versions manually.

## Gemfile dependencies

```ruby
source "https://rubygems.org"

gem "rpdfium",     "~> 0.3"
gem "onnxruntime", "~> 0.11"

# In environments where RubyGems is blocked (offline, restrictive allowlists),
# load from git or local paths:
#   gem "rpdfium",     git: "https://github.com/retsef/rpdfium.git"
#   gem "onnxruntime", git: "https://github.com/ankane/onnxruntime-ruby.git"
#   gem "rpdfium",     path: "../rpdfium"

group :development do
  gem "rake", "~> 13.0"
end
```

## Network considerations

### What needs internet access at runtime

- **None** for `:heuristic` mode after install
- **HuggingFace Hub** (`huggingface.co`) for downloading real ONNX weights
  (only at setup time, not per-request)
- **Optional**: external tokenizer downloads if you pass a HF tokenizer
  via `HybridChunker.new(tokenizer: ...)`

### Air-gapped deployments

Fully supported with `:heuristic` mode. For `:onnx`:
1. Download weights on a connected machine
2. Copy `models/*.onnx` to the air-gapped target
3. Set `models_dir:` accordingly

## Verifying the installation

```bash
git clone <your-repo>
cd <your-repo>
bundle install
export PDFIUM_LIBRARY_PATH=/path/to/libpdfium.so

# Smoke test
ruby -I lib spec/smoke_test.rb spec/fixtures/test.pdf
```

Expected output:
```
=== BBox value object ===
✓ width
✓ height
... (34 tests total)
✓ 34 test passati
```

If you see `✗` lines, **stop and debug**. The most common causes:

| Symptom | Cause | Fix |
|---|---|---|
| `LoadError: rpdfium` | rpdfium gem not installed | `bundle install` |
| `pdfium library failed to load` | `PDFIUM_LIBRARY_PATH` not set or wrong | Check `ls -l $PDFIUM_LIBRARY_PATH` |
| `libonnxruntime.so: cannot open shared object` | ONNX native lib missing | Either install via gem (which bundles it) or symlink manually |
| `ArgumentError: type invalido` | Code bug; new node type added without updating `VALID_TYPES` | Add to `Node::VALID_TYPES` |
| Tests fail with `0/x passed` | PDF fixture missing | Generate via `bench/gen_test_pdfs.py /tmp` first |

## Known gotchas

### 1. `PDFIUM_LIBRARY_PATH` must point to the FILE, not the directory

```bash
# WRONG
export PDFIUM_LIBRARY_PATH=/opt/pdfium/lib

# RIGHT
export PDFIUM_LIBRARY_PATH=/opt/pdfium/lib/libpdfium.so
```

### 2. Symlinks vs copies for libonnxruntime

If you symlink the .so from a Python install, **don't delete the Python
package later** — the symlink will break silently.

### 3. macOS Apple Silicon

PDFium binaries come in `pdfium-mac-arm64.tgz` (M1/M2/M3) and `pdfium-mac-x64.tgz`
(Intel). Get the right one. Mixed-architecture loading produces unhelpful
error messages.

### 4. Ruby and integer division

The codebase has a known historical bug class: `inter / union` returns 0
when both are Integer and inter < union. Always use `.to_f` for ratio
calculations. Grep for `\/` in any new math code and audit.

### 5. /bin/sh brace expansion

Subshells invoked from Ruby `system()` or backticks may use `/bin/sh`, which
does not expand `{a,b,c}` patterns. Use explicit paths or `bash -c "..."`.

### 6. rpdfium API surface

rpdfium's API was inspected at commit (clone the repo and read `lib/rpdfium.rb`
for the latest). Key methods we rely on:

- `Rpdfium.open(path) { |doc| ... }` — yields a Document
- `doc.metadata` → Hash with `:title`, `:author`, etc.
- `doc.page_count`, `doc.each`
- `page.width`, `page.height` (in points)
- `page.text` (full string), `page.chars` (per-char metadata), `page.words` (grouped)
- `page.text_in_bbox(left:, top:, right:, bottom:)`
- `page.render(scale:, output: :rgba)` → `[w, h, bytes, stride]`
- `Rpdfium::Table::Extractor.new(page, vertical_strategy:, horizontal_strategy:)`

If rpdfium evolves and breaks any of these, that's a one-file shim: update
the wrappers, don't propagate the change throughout the codebase.

## Recommended dev workflow

```bash
# 1. Make changes
$EDITOR lib/rb_docling/...

# 2. Run smoke tests
ruby -I lib spec/smoke_test.rb spec/fixtures/test.pdf

# 3. Quick interactive check on a real PDF
ruby -I lib bin/rb_docling /path/to/your.pdf --out md | less

# 4. Run benchmark if relevant change
# (see ../rb_docling_bench/)
cd ../rb_docling_bench
docker build -t bench . && docker run --rm -v $(pwd)/out:/work/out bench
```
