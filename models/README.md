# models/

Questa directory ospita i pesi ONNX dei modelli Docling. I file `.onnx` non
sono versionati (vedi `.gitignore`); vanno scaricati separatamente.

> **Nota importante**: i repository HuggingFace ufficiali di IBM/ds4sd
> (`ds4sd/docling-models`, `ds4sd/docling-layout-heron-101`) pubblicano **solo
> pesi PyTorch**. rb_docling usa un **repo separato di conversioni ONNX
> pre-compilate**: [`klarolabs/rb-docling-onnx`](https://huggingface.co/klarolabs/rb-docling-onnx)
> (default; ridefinibile via `RB_DOCLING_HF_REPO`).
>
> Le conversioni le genera il maintainer con gli script in [`tools/`](../tools/README.md).

## File attesi

| Filename | Contenuto | Quando serve |
|---|---|---|
| `layout.onnx` | DocLayNet Heron RT-DETR (object detection, 11 classi) | `RbDocling.parse(pdf, layout: :onnx)` |
| `tableformer_encoder.onnx` | TableFormer encoder | `RbDocling.parse(pdf, table: :onnx)` |
| `tableformer_decoder.onnx` | TableFormer decoder autoregressivo (OTSL) | `RbDocling.parse(pdf, table: :onnx)` |
| `tableformer_vocab.json` | Vocabolario OTSL — caricato dal decoder | `table: :onnx` (richiesto col decoder) |

In assenza dei file, la pipeline funziona in modalità `:heuristic` (default).

## Come ottenerli

### Tramite rake (raccomandato)

```bash
bundle exec rake models:list            # cosa manca / cosa c'è già
bundle exec rake models:fetch           # scarica tutto
bundle exec rake models:fetch:layout    # solo layout
bundle exec rake models:fetch:tableformer
```

### Override

```bash
# Cambia repo HuggingFace (default: klarolabs/rb-docling-onnx)
RB_DOCLING_HF_REPO=tuo-user/tuo-repo bundle exec rake models:fetch

# Cambia revision (default: main)
RB_DOCLING_HF_REVISION=v1.0 bundle exec rake models:fetch

# URL completa per file singolo (bypassa il repo)
RB_DOCLING_LAYOUT_URL=https://example.com/layout.onnx \
  bundle exec rake models:fetch:layout

# Cambia destinazione locale (default: ./models)
RB_DOCLING_MODELS_DIR=/var/lib/rb_docling/models bundle exec rake models:fetch

# Riscarica anche se il file è già presente
FORCE=1 bundle exec rake models:fetch
```

### Manualmente

Scarica i file dal repo HF (sopra) o da una conversione tua e posizionali in
questa cartella con i nomi attesi (colonna "Filename").

## Conversione propria

Se vuoi auto-ospitare le conversioni (necessario almeno per il layout, che non
ha un repo pubblico ONNX) → vedi [`tools/README.md`](../tools/README.md).

Workflow rapido:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r tools/requirements.txt
python tools/export_layout.py              # → tools/_out/layout.onnx
python tools/export_tableformer.py         # → tools/_out/tableformer_*.onnx + vocab
python tools/verify_onnx.py tools/_out/layout.onnx
# Push su HF, poi: bundle exec rake models:fetch
```

## Calibrazione TableFormer

Il decoder TableFormer è autoregressivo su un vocabolario OTSL. rb_docling
carica `tableformer_vocab.json` (incluso nello scarico) e lo usa al posto
della costante `OTSL_TOKENS` placeholder in
[`lib/rb_docling/table/onnx_tableformer.rb`](../lib/rb_docling/table/onnx_tableformer.rb).

Se generi conversioni proprie con `tools/export_tableformer.py`, il vocab
viene estratto dal modello e salvato — non c'è calibrazione manuale.

## Dimensioni indicative

- `layout.onnx`: ~100–150 MB (RT-DETR-50 / Heron-101)
- `tableformer_encoder.onnx`: ~80 MB
- `tableformer_decoder.onnx`: ~30 MB
- `tableformer_vocab.json`: ~10 KB

Totale ~250 MB. **Non versionarli** (sono già esclusi in `.gitignore`).
