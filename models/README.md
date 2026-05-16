# models/

Questa directory ospita i pesi ONNX dei modelli Docling. I file `.onnx` non
sono versionati (vedi `.gitignore`); vanno scaricati separatamente.

## File attesi

| Filename | Contenuto | Quando serve |
|---|---|---|
| `layout.onnx` | DocLayNet RT-DETR (Heron-101 o equivalente) | `RbDocling.parse(pdf, layout: :onnx)` |
| `tableformer_encoder.onnx` | TableFormer encoder | `RbDocling.parse(pdf, table: :onnx)` |
| `tableformer_decoder.onnx` | TableFormer decoder autoregressivo (OTSL) | `RbDocling.parse(pdf, table: :onnx)` |

In assenza dei file, la pipeline funziona in modalità `:heuristic` (default).

## Come ottenerli

### Tramite rake (raccomandato)

```bash
bundle exec rake models:list            # cosa manca / cosa c'è già
bundle exec rake models:fetch           # scarica tutto
bundle exec rake models:fetch:layout    # solo layout
bundle exec rake models:fetch:tableformer
```

Per puntare a URL alternative (le release ONNX di Docling cambiano):

```bash
RB_DOCLING_LAYOUT_URL=https://example.com/layout.onnx \
  bundle exec rake models:fetch:layout
```

Per cambiare la directory di destinazione:

```bash
RB_DOCLING_MODELS_DIR=/var/lib/rb_docling/models bundle exec rake models:fetch
```

Per forzare il riscaricamento di un file già presente:

```bash
FORCE=1 bundle exec rake models:fetch
```

### Manualmente

Scarica i file dai repository HuggingFace (`ds4sd/docling-*`) e posizionali in
questa cartella con i nomi sopra. Le URL "ufficiali" cambiano spesso — è
normale dover cercare la versione più recente.

## Calibrazione TableFormer

Il vocabolario OTSL in `lib/rb_docling/table/onnx_tableformer.rb` (costante
`OTSL_TOKENS`) è un PLACEHOLDER. Va sostituito con l'ordine esatto del modello
ONNX che si sta usando — si trova nel `config.json` accanto al `.onnx` sul
repo HuggingFace. Senza calibrazione, l'output del decoder è inutilizzabile.

## Dimensioni indicative

- `layout.onnx`: ~100-150 MB (RT-DETR-50)
- `tableformer_encoder.onnx`: ~80 MB
- `tableformer_decoder.onnx`: ~30 MB

Totale ~250 MB. Non versionarli.
