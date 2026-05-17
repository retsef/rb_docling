# tools/ — conversione modelli PyTorch → ONNX

Questa directory contiene gli script Python per **convertire i pesi ufficiali Docling
(PyTorch) in ONNX**, pubblicarli su HuggingFace e renderli scaricabili dai
rake task di `rb_docling`.

Workflow pensato per essere eseguito **una volta per ogni release Docling**:
producono i `.onnx` → si caricano nel repo HF dedicato → `rb_docling` li scarica
on-demand via `bundle exec rake models:fetch`.

> **Onestà ingegneristica**: questi script sono **scaffolding testato in modo**
> **limitato**. I punti `# TODO[calibrate]` nei sorgenti vanno verificati contro
> la versione esatta di `docling-ibm-models` installata. La conversione di un
> decoder autoregressivo non è banale — aspettatevi un'iterazione di debug
> prima che tutto fili.

## Prerequisiti

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r tools/requirements.txt
```

## Step 1 — Conversione

### Layout (DocLayNet Heron RT-DETR)

```bash
python tools/export_layout.py
# Output: tools/_out/layout.onnx
```

Override comuni:

```bash
python tools/export_layout.py \
  --repo ds4sd/docling-layout-heron-101 \
  --input-size 640 \
  --opset 17 \
  --out tools/_out/layout.onnx
```

### TableFormer

**Modalità `split` (raccomandata)** — encoder e decoder come due grafi separati;
il loop autoregressivo OTSL gira lato Ruby:

```bash
python tools/export_tableformer.py --variant accurate --mode split
# Output:
#   tools/_out/tableformer_encoder.onnx
#   tools/_out/tableformer_decoder.onnx
#   tools/_out/tableformer_vocab.json     ← caricato da OnnxTableFormer
```

**Modalità `monolithic`** — singolo grafo con `seq_len` fisso, compatibile con
il formato di `asmud/ds4sd-docling-models-onnx`:

```bash
python tools/export_tableformer.py --variant accurate --mode monolithic --max-seq-len 512
# Output:
#   tools/_out/tableformer.onnx
#   tools/_out/tableformer_vocab.json
```

## Step 2 — Verifica

```bash
python tools/verify_onnx.py tools/_out/layout.onnx
python tools/verify_onnx.py tools/_out/tableformer_encoder.onnx
python tools/verify_onnx.py tools/_out/tableformer_decoder.onnx
```

Lo script controlla validità del grafo, caricabilità con `onnxruntime` ed
esegue un forward con input dummy.

## Step 3 — Pubblicazione su HuggingFace

1. Crea il repo HuggingFace (una sola volta):
   - Vai su https://huggingface.co/new
   - Nome consigliato: **`klarolabs/rb-docling-onnx`** (allinea con quello in
     `lib/rb_docling/rake_tasks.rb` `SOURCES`)
   - Tipo: **Model** (non Dataset)
   - Visibilità: **public**

2. Copia il template (sotto `tools/hf_repo/`) nel repo clonato:

   ```bash
   git clone https://huggingface.co/klarolabs/rb-docling-onnx /tmp/hf
   cp tools/hf_repo/README.md /tmp/hf/README.md
   cp tools/hf_repo/.gitattributes /tmp/hf/.gitattributes
   ```

3. Sposta i `.onnx` prodotti:

   ```bash
   mv tools/_out/*.onnx tools/_out/tableformer_vocab.json /tmp/hf/
   cd /tmp/hf
   git lfs install
   git add .
   git commit -m "Initial release: layout + tableformer (split) ONNX"
   git push
   ```

4. Tagga la release (allinea con la versione Docling esportata):

   ```bash
   git tag docling-v2.50  # o la versione corrispondente
   git push --tags
   ```

## Step 4 — Verifica end-to-end con rb_docling

```bash
cd /path/to/rb_docling
bundle exec rake models:fetch       # scarica dal nuovo repo HF
bundle exec rake models:list        # tutti [ok]
ruby -I lib bin/rb_docling sample.pdf --layout onnx --table onnx --out md
```

## Aggiornamento

Quando Docling rilascia pesi nuovi:

1. `python tools/export_layout.py` (verifica TODO[calibrate])
2. `python tools/export_tableformer.py`
3. `python tools/verify_onnx.py ...`
4. Push su HF + nuovo tag
5. (opzionale) aggiorna `SOURCES` in `lib/rb_docling/rake_tasks.rb` se cambia
   il nome dei file

## Troubleshooting comune

| Sintomo | Causa probabile | Fix |
|---|---|---|
| `ImportError: docling_ibm_models.layoutmodel.layout_predictor` | Versione `docling-ibm-models` cambiata | Cerca il nuovo path con `python -c "import docling_ibm_models; help(docling_ibm_models)"` e aggiorna `discover_model()` |
| `RuntimeError: Tracing failed` durante export decoder | Loop autoregressivo non tracciabile | Usa `--mode monolithic` o scrivi un wrapper che esponga solo un singolo step |
| `onnx.checker.ValidationError: opset` | Opset troppo basso per qualche op | `--opset 18` (o 20) |
| Output decoder ha logits di shape sbagliata | Vocab size disallineato | Verifica `tableformer_vocab.json` — la dim degli output deve essere `len(vocab)` |
| `.onnx` enorme (>500 MB) | Constants foldate due volte | Lancia `python -m onnxsim INPUT OUTPUT` |

## Calibrazione lato rb_docling dopo l'export

Una volta pubblicati i `.onnx`, va sincronizzato **un solo punto** in Ruby:

- [`lib/rb_docling/table/onnx_tableformer.rb`](../lib/rb_docling/table/onnx_tableformer.rb)
  costante `OTSL_TOKENS` → caricala da `tableformer_vocab.json` invece che
  hardcoded. (Modifica raccomandata insieme alla prima release stabile dei
  modelli.)
