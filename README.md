# rb_docling

Pipeline di **document understanding in Ruby** ispirata a [Docling](https://github.com/docling-project/docling) (IBM Research).
Stesso paradigma — estrazione PDF + layout analysis + table structure + chunking RAG-ready — riportato sullo
stack Ruby con `rpdfium` per il PDF parsing e `onnxruntime` per l'inferenza ML.

```
PDF → rpdfium (testo+bbox) ─┐
                            ├→ Layout (heuristic | ONNX RT-DETR) ─┐
                            ├→ Tables (heuristic | ONNX TableFormer) ─┤
                            └→ Reading order multi-strato ←──────────┘
                                  (StructTree → ML → geometric)
                                                                     │
                                                                     ↓
                                                          HybridChunker → chunks per RAG
```

## Stato

Tutto il codice è **testato e funzionante** in modalità `:heuristic` (zero modelli ML).
La modalità `:onnx` è testata con modelli dummy: la pipeline carica gli `.onnx`,
fa preprocessing letterbox/normalizzazione ImageNet, esegue inferenza, mappa le
bbox da pixel a coordinate PDF, e popola il `DocumentTree`. Per i pesi reali
di Docling vedi la sezione "Modelli" sotto.

**41 smoke test** passanti (BBox, pipeline heuristic, headings_path, chunker
split/merge, reading order multi-strato con tutte le strategie, pipeline ONNX
dummy).

## Installazione

`rb_docling` è una gem standard. Aggiungila al tuo `Gemfile`:

```ruby
# Gemfile
gem "rb_docling", "~> 0.1"
```

oppure, finché non è pubblicata su rubygems, da git/path:

```ruby
gem "rb_docling", git: "https://github.com/retsef/rb_docling"
# oppure
gem "rb_docling", path: "../rb_docling"
```

Poi `bundle install`.

### Dipendenze native

`rb_docling` richiede **due librerie native**:

1. **libpdfium** — scaricabile da [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries/releases).
   Punta `rpdfium` al file via env var:
   ```bash
   export PDFIUM_LIBRARY_PATH=/path/to/libpdfium.so   # o .dylib su macOS
   ```
   In alternativa, se hai Python con `pypdfium2` installato:
   ```bash
   export PDFIUM_LIBRARY_PATH=$(python -c "import pypdfium2_raw, os; \
     print(os.path.join(os.path.dirname(pypdfium2_raw.__file__), 'libpdfium.dylib'))")
   ```

2. **libonnxruntime** — la gem `onnxruntime` la include per le piattaforme
   supportate; in caso contrario installala dalle [release ufficiali Microsoft](https://github.com/microsoft/onnxruntime/releases).

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

Con strategia di reading order esplicita:

```ruby
pipeline = RbDocling::Pipeline.new(reading_order: :struct)   # solo tagged
# :auto (default) | :struct | :ml | :geometric
tree = pipeline.parse("doc.pdf")
```

### Chunking per RAG

```ruby
chunker = RbDocling::Chunking::HybridChunker.new(max_tokens: 512, min_tokens: 64)
chunks = chunker.chunk(tree)
# => [{ text:, token_count:, metadata: { type:, page_no:, bbox:, headings:, heading_id: } }, ...]
```

Ogni chunk porta con sé:
- `heading_id`: percorso heading completo (`"Capitolo 2 > 2.1 Parametri"`)
- `headings`: lista strutturata `[{ level:, text: }]` per filtering
- `bbox`, `page_no`: per citazioni back-to-source

### CLI

L'eseguibile `rb_docling` è installato con la gem:

```bash
rb_docling input.pdf --out md
rb_docling input.pdf --out json
rb_docling input.pdf --out chunks --max-tokens 300
rb_docling input.pdf --layout onnx --models ./models
```

Durante lo sviluppo, senza installare la gem:

```bash
ruby -I lib bin/rb_docling input.pdf --out md
```

## Modelli ONNX

I pesi non sono versionati — vanno scaricati separatamente. Sono **opzionali**:
la modalità `:heuristic` (default) non li usa.

### Scaricare via rake

```bash
bundle exec rake models:list            # cosa manca
bundle exec rake models:fetch           # scarica tutto
bundle exec rake models:fetch:layout    # solo layout
bundle exec rake models:fetch:tableformer
bundle exec rake models:clean           # rimuove i .onnx scaricati
```

Override URL (le release ONNX di Docling cambiano nel tempo):

```bash
RB_DOCLING_LAYOUT_URL=https://huggingface.co/.../model.onnx \
  bundle exec rake models:fetch:layout
```

Cambia destinazione:

```bash
RB_DOCLING_MODELS_DIR=/var/lib/rb_docling/models bundle exec rake models:fetch
```

Vedi [`models/README.md`](models/README.md) per dettagli su filename attesi,
calibrazione del vocabolario OTSL per TableFormer e dimensioni indicative.

### Sorgenti

| Modello | Repo HuggingFace | Filename atteso |
|---|---|---|
| Layout (DocLayNet RT-DETR) | `ds4sd/docling-layout-heron-101` | `layout.onnx` |
| TableFormer encoder | `ds4sd/docling-tableformer-accurate` | `tableformer_encoder.onnx` |
| TableFormer decoder | `ds4sd/docling-tableformer-accurate` | `tableformer_decoder.onnx` |

**Nota**: queste URL sono il default best-effort; verificare sempre la
disponibilità su HuggingFace. In caso di URL invalida, scaricare manualmente
e posizionare il file con il nome atteso in `models/`.

## Reading order: tre strategie a cascata

Una delle differenze con Docling: rb_docling supporta **3 strategie** in
cascata, scelte automaticamente:

1. **Struct-tree** (PDF tagged): legge l'ordine d'autore dal `/StructTreeRoot`
   via `Rpdfium::Structure::Tree`. Su PDF/UA e export Word/InDesign
   accessibility-friendly **siamo strettamente superiori a Docling**, che
   ignora i tag PDF.
2. **ML**: usa l'ordine delle detection box di RT-DETR (quando i pesi sono
   caricati). Equivale all'approccio di Docling.
3. **Geometric** (fallback): clustering 1D delle colonne, top-to-bottom.
   Sempre disponibile.

Vedi [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) per i dettagli algoritmici.

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
- Letterbox + ImageNet normalization
- Auto-detect del formato bbox (`xyxy_norm`, `cxcywh_norm`, `xyxy_px`, `cxcywh_px`)
- Resolve nomi output via convenzione (`labels`/`boxes`/`scores`) o per shape
- Mappa coord pixel di rendering → punti PDF
- Espone `:detection_index` per il reading order ML

### Table engines

**`HeuristicTable`** — wrapper su `Rpdfium::Table::Extractor` (strategia `:lines`)
con filtri anti-falso-positivo: min 2 colonne, min 2 righe, ≥ 40% celle non vuote,
consistenza del numero di colonne.

**`OnnxTableFormer`** — scaffolding per modelli TableFormer (encoder-decoder
autoregressivo, vocabolario OTSL). Supporta due modi:
- `:monolithic` (singolo grafo che produce tokens+bboxes in un colpo)
- `:split` (encoder + decoder loop autoregressivo greedy)

### HybridChunker

Replica del comportamento dell'`HybridChunker` di Docling:
1. **Document-based**: ogni nodo diventa un chunk candidato con heading path
2. **Token-aware splitting**: se un chunk > `max_tokens`, spezza su confini di frase
3. **Token-aware merging**: chunk adiacenti < `min_tokens` sotto lo stesso heading
   vengono fusi se il risultato sta sotto `max_tokens`

Il tokenizer di default è un'approssimazione `~4 char/token`. Passa un `Proc`
personalizzato per usare un tokenizer reale:

```ruby
my_tokenizer = ->(text) { my_bpe.encode(text).size }
RbDocling::Chunking::HybridChunker.new(tokenizer: my_tokenizer)
```

## Sviluppo

```bash
bundle install                       # con rpdfium 0.3.13 locale: bundle config set local.rpdfium /path
bundle exec rake -T                  # lista task disponibili
bundle exec rake test                # smoke test (PDFIUM_LIBRARY_PATH richiesta)
bundle exec rake models:list         # stato modelli ONNX
bundle exec rake build               # costruisce la .gem
bundle exec rake install             # installa la .gem localmente
```

Per i test:

```bash
export PDFIUM_LIBRARY_PATH=/usr/local/lib/libpdfium.dylib
PDF=spec/fixtures/test.pdf bundle exec rake test
# o direttamente:
ruby -I lib spec/smoke_test.rb spec/fixtures/test.pdf
```

## Limiti noti (modalità heuristic)

- Layout multi-colonna gestito dal `ReadingOrder`, ma su layout con
  sovrapposizioni verticali complesse può sbagliare. Su PDF tagged il tier
  struct-tree risolve il problema senza modelli ML.
- Title vs Heading1 dello stesso fontsize/weight sono indistinguibili
  visivamente.
- Tabelle senza bordi: la strategia `:lines` di rpdfium le manca. Per quelle
  serve `table: :onnx` con TableFormer + pesi calibrati.
- Niente OCR: PDF scansionati non sono supportati nativamente.

Vedi [`docs/COMPARISON_DOCLING.md`](docs/COMPARISON_DOCLING.md) per la matrice
completa di gap rispetto a Docling.

## Struttura del progetto

```
.
├── rb_docling.gemspec
├── Rakefile                   # task: build/install/test/models:*
├── Gemfile                    # bundler usa gemspec
├── LICENSE                    # Apache-2.0
├── CLAUDE.md                  # istruzioni per Claude Code
├── bin/rb_docling             # CLI installato con la gem
├── lib/rb_docling/
│   ├── version.rb
│   ├── document/
│   │   ├── bbox.rb            # value object con contains/iou
│   │   ├── node.rb            # 11 tipi DocLayNet + composti
│   │   └── tree.rb            # serializzazione md/json, headings_path
│   ├── models/
│   │   └── loader.rb          # cache singleton per OnnxRuntime::InferenceSession
│   ├── layout/
│   │   ├── heuristic_layout.rb # word→line→block + classificazione
│   │   ├── onnx_layout.rb      # RT-DETR wrapper
│   │   └── reading_order.rb    # struct-tree → ml → geometric
│   ├── table/
│   │   ├── heuristic_table.rb  # wrapper Rpdfium::Table + filtri FP
│   │   └── onnx_tableformer.rb # encoder + decoding autoregressivo
│   ├── chunking/
│   │   └── hybrid_chunker.rb   # split/merge token-aware
│   ├── rake_tasks.rb           # task `models:*` per scaricare i pesi
│   └── pipeline.rb             # orchestratore
├── models/                    # pesi .onnx (non versionati, vedi models/README.md)
├── spec/
│   ├── smoke_test.rb          # 41 test (no rspec, plain Ruby)
│   └── fixtures/              # PDF di esempio
└── docs/                      # ARCHITECTURE, COMPARISON_DOCLING, ROADMAP, ecc.
```

## Documentazione

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — design modulo per modulo
- [`docs/DESIGN_DECISIONS.md`](docs/DESIGN_DECISIONS.md) — perché Ruby invece di Python
- [`docs/COMPARISON_DOCLING.md`](docs/COMPARISON_DOCLING.md) — gap vs Docling, feature per feature
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — prossimi step prioritizzati
- [`docs/RESOURCES.md`](docs/RESOURCES.md) — profilo memoria/CPU, sizing deploy
- [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md) — runtime requirements, native libs

## Licenza

Apache-2.0 — vedi [`LICENSE`](LICENSE). Stessa licenza di rpdfium e Docling.
