# rb_docling

Pipeline di **document understanding in Ruby** ispirata a [Docling](https://github.com/docling-project/docling) (IBM Research).
Stesso paradigma — estrazione PDF + layout analysis + table structure + chunking RAG-ready — riportato sullo
stack Ruby con `rpdfium` per il PDF parsing e `onnxruntime` per l'inferenza ML.

```
PDF → rpdfium (testo+bbox) ─┐
                            ├→ Layout (heuristic | ONNX RT-DETR) ─┐
                            ├→ Tables (heuristic | ONNX TableFormer) ─┤
                            └→ Reading order + DocumentTree ←────────┘
                                                                     │
                                                                     ↓
                                                          HybridChunker → chunks per RAG
```

## Stato

Tutto il codice è **testato e funzionante** in modalità `:heuristic` (zero modelli ML).
La modalità `:onnx` è testata con modelli dummy generati a runtime: la pipeline carica
gli `.onnx`, fa preprocessing letterbox/normalizzazione ImageNet, esegue inferenza,
mappa le bbox da pixel a coordinate PDF, e popola il `DocumentTree`. Per i pesi reali
di Docling consulta la sezione "Modelli reali" sotto.

Test inclusi: 34 smoke test passanti (BBox, pipeline heuristic, headings_path, chunker
split/merge, pipeline ONNX).

## Installazione

```ruby
# Gemfile
gem "rpdfium",     "~> 0.3"
gem "onnxruntime", "~> 0.11"
gem "rb_docling",  path: "."  # finché non è pubblicato
```

Servono inoltre **due librerie native**:

1. **libpdfium** — scaricabile da [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries/releases).
   Linkala via env var:
   ```bash
   export PDFIUM_LIBRARY_PATH=/path/to/libpdfium.so
   ```
   In alternativa, se hai Python con `pypdfium2`, puoi puntare al suo binario:
   ```bash
   export PDFIUM_LIBRARY_PATH=$(python -c "import pypdfium2_raw, os; print(os.path.join(os.path.dirname(pypdfium2_raw.__file__), 'libpdfium.so'))")
   ```

2. **libonnxruntime** — la gem `onnxruntime` la include via wheel per le piattaforme
   supportate; in caso contrario va installata separatamente (es. via
   [release ufficiali Microsoft](https://github.com/microsoft/onnxruntime/releases)).

## Uso

### API top-level

```ruby
require "rb_docling"

tree = RbDocling.parse("doc.pdf")
puts tree.to_md
```

Con modelli ONNX:

```ruby
tree = RbDocling.parse("doc.pdf",
                       layout: :onnx, table: :onnx,
                       models_dir: "./models")
```

### Chunking per RAG

```ruby
chunker = RbDocling::Chunking::HybridChunker.new(max_tokens: 512, min_tokens: 64)
chunks = chunker.chunk(tree)
# => [{ text:, token_count:, metadata: { type:, page_no:, bbox:, headings:, heading_id: } }, ...]
```

Ogni chunk porta con sé:
- `heading_id`: percorso heading completo (es. `"Capitolo 2 > 2.1 Parametri"`)
- `headings`: lista strutturata `[{ level:, text: }]` per filtering
- `bbox`, `page_no`: per citazioni back-to-source

### CLI

```bash
ruby -I lib bin/rb_docling input.pdf --out md
ruby -I lib bin/rb_docling input.pdf --out json
ruby -I lib bin/rb_docling input.pdf --out chunks --max-tokens 300
ruby -I lib bin/rb_docling input.pdf --layout onnx --models ./models
```

## Architettura

### Document model

`RbDocling::Document::Tree` è una lista ordinata (in reading order) di
`RbDocling::Document::Node`. Ogni nodo ha:
- `type`: una delle 11 etichette DocLayNet (`:title`, `:section_header`, `:text`,
  `:list_item`, `:caption`, `:footnote`, `:page_header`, `:page_footer`,
  `:table`, `:picture`, `:formula`)
- `bbox`, `page_no`, `level`, `font`, `fontsize`, `weight`
- `table_structure: { rows: [[cell, ...], ...] }` per i nodi tabella
- `metadata`: hash libero (`:score` per detection ML, ecc.)

### Layout engines

**`HeuristicLayout`** — euristiche pure su font/posizione:
- Word clustering in linee (tolleranza Y)
- Linee in blocchi (spezza su cambio font-size > 1pt, cambio weight, gap > 1.2 line-height)
- Classificazione: `title` (ratio fs/body ≥ 1.6), `section_header` (≥ 1.35),
  `list_item` (inizia con bullet o numerazione), altrimenti `text`
- Split di list-item inline (`"Lista: • a • b • c"` → 4 nodi)

**`OnnxLayout`** — wrapper per modelli RT-DETR addestrati su DocLayNet:
- Letterbox + ImageNet normalization (mean/std standard)
- Auto-detect del formato bbox (`xyxy_norm`, `cxcywh_norm`, `xyxy_px`, `cxcywh_px`)
- Resolve nomi output via convenzione (`labels`/`boxes`/`scores`) o per shape
- Mappa coord pixel di rendering → punti PDF

### Table engines

**`HeuristicTable`** — wrapper su `Rpdfium::Table::Extractor` (strategia `:lines`)
con filtri anti-falso-positivo: min 2 colonne, min 2 righe, ≥ 40% celle non vuote,
consistenza del numero di colonne.

**`OnnxTableFormer`** — scaffolding per modelli TableFormer (encoder-decoder
autoregressivo, vocabolario OTSL). Supporta due modi:
- `:monolithic` (singolo grafo che produce tokens+bboxes in un colpo)
- `:split` (encoder + decoder loop autoregressivo greedy)

### Reading order

`ReadingOrder.sort` — clustering 1D delle posizioni `x0` con tolleranza 25pt per
identificare colonne, poi top-to-bottom dentro ogni colonna, left-to-right tra colonne.

### HybridChunker

Replica del comportamento dell'`HybridChunker` di Docling:
1. **Document-based**: ogni nodo diventa un chunk candidato con heading path
2. **Token-aware splitting**: se un chunk > `max_tokens`, spezza su confini di frase
   (con fallback a word-group split se manca punteggiatura)
3. **Token-aware merging**: chunk adiacenti < `min_tokens` sotto lo stesso heading
   vengono fusi se il risultato sta sotto `max_tokens`

Il tokenizer di default è un'approssimazione `~4 char/token` (regola pollice
GPT/Claude). Passa un `Proc` personalizzato per usare un tokenizer reale:

```ruby
my_tokenizer = ->(text) { my_bpe.encode(text).size }
RbDocling::Chunking::HybridChunker.new(tokenizer: my_tokenizer)
```

## Limiti noti (modalità heuristic)

- Layout multi-colonna gestito a posteriori dal `ReadingOrder`, ma se i blocchi
  si sovrappongono verticalmente in modo complesso può sbagliare.
- Title vs Heading1 dello stesso fontsize/weight risultano indistinguibili
  visivamente: l'euristica li classifica entrambi come `:title`.
- Lista contenuta dentro un paragrafo con stesso font: spezzata solo se i bullet
  sono caratteri Unicode (`• · ▪`) e separati da spazio.
- Tabelle senza bordi visibili: la strategia `:lines` di rpdfium le manca. Per
  quelle serve `table: :onnx` con TableFormer.
- Niente OCR: PDF scansionati non sono supportati nativamente. Va integrato
  separatamente (es. tesseract via shell prima del parsing).

## Modelli reali

Questo repo include solo modelli **dummy** generati a runtime per validare la
pipeline. Per i pesi reali:

**Layout RT-DETR su DocLayNet**:
- Pesi PyTorch: `docling-project/docling-models` su Hugging Face
- Conversione ONNX: usare `optimum-cli export onnx --model ... --task object-detection`
  oppure cercare release già esportate

**TableFormer**:
- Pesi PyTorch: stesso repo `docling-models`
- Versione ONNX pronta: `asmud/ds4sd-docling-models-onnx` su Hugging Face
  (variante JPQD quantizzata)

Sostituendo i file `.onnx` in `models/`, la pipeline si attiva automaticamente.
**Nota**: il vocabolario OTSL placeholder in `OnnxTableFormer::OTSL_TOKENS` va
sostituito con quello reale del modello, e i nomi I/O del decoder vanno calibrati
sul file `.onnx` specifico (input naming convention).

## Test

```bash
ruby -I lib spec/smoke_test.rb /tmp/test.pdf
```

## Struttura del progetto

```
lib/rb_docling/
├── version.rb
├── document/
│   ├── bbox.rb       # value object con contains/iou
│   ├── node.rb       # 11 tipi DocLayNet + composti
│   └── tree.rb       # serializzazione md/json, headings_path
├── models/
│   └── loader.rb     # cache singleton per OnnxRuntime::InferenceSession
├── layout/
│   ├── heuristic_layout.rb  # word→line→block + classificazione
│   ├── onnx_layout.rb       # RT-DETR wrapper
│   └── reading_order.rb     # column clustering
├── table/
│   ├── heuristic_table.rb   # wrapper Rpdfium::Table + filtri FP
│   └── onnx_tableformer.rb  # encoder + decoding autoregressivo
├── chunking/
│   └── hybrid_chunker.rb    # split/merge token-aware
└── pipeline.rb              # orchestratore
```

## Licenza

Apache-2.0 (stessa di rpdfium e Docling).
