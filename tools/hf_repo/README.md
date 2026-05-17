---
license: apache-2.0
language:
  - en
tags:
  - docling
  - document-understanding
  - layout-analysis
  - table-structure
  - onnx
  - rb_docling
library_name: onnx
inference: false
base_model:
  - ds4sd/docling-layout-heron-101
  - ds4sd/docling-models
---

# rb-docling-onnx

Pre-converted ONNX weights of [Docling](https://github.com/docling-project/docling)
models for use with [rb_docling](https://github.com/robertoscinocca/rb_docling)
(Ruby port).

These are **third-party conversions** of the official Docling PyTorch checkpoints.
For the canonical PyTorch weights see [`ds4sd/docling-models`](https://huggingface.co/ds4sd/docling-models)
and [`ds4sd/docling-layout-heron-101`](https://huggingface.co/ds4sd/docling-layout-heron-101).

## Files

| File | Source | Description |
|---|---|---|
| `layout.onnx` | `ds4sd/docling-layout-heron-101` | RT-DETR layout detector (DocLayNet, 11 classes) |
| `tableformer_encoder.onnx` | `ds4sd/docling-models` (`tableformer/accurate`) | TableFormer encoder, image → memory |
| `tableformer_decoder.onnx` | `ds4sd/docling-models` (`tableformer/accurate`) | TableFormer autoregressive decoder, (tokens, memory) → (next_token, bbox) |
| `tableformer_vocab.json` | derived | OTSL vocabulary for the decoder |

## Usage from Ruby

```ruby
# Gemfile
gem "rb_docling", "~> 0.1"
```

```bash
# Scarica i modelli ONNX di Docling
bundle exec rake models:fetch
```

```ruby
require "rb_docling"

tree = RbDocling.parse("doc.pdf",
                       layout: :onnx, table: :onnx,
                       models_dir: "./models")
puts tree.to_md
```

## Conversion details

| | |
|---|---|
| Source PyTorch version | torch 2.x |
| ONNX opset | 17 |
| Quantization | none (FP32) |
| Conversion scripts | [`tools/`](https://github.com/robertoscinocca/rb_docling/tree/main/tools) in the rb_docling repo |

To re-build from the official PyTorch weights:

```bash
git clone https://github.com/robertoscinocca/rb_docling
cd rb_docling
pip install -r tools/requirements.txt
python tools/export_layout.py
python tools/export_tableformer.py --variant accurate --mode split
```

## License

Apache-2.0, inherited from the upstream Docling models.

## Citation

If you use these conversions, please cite the original Docling work:

```bibtex
@article{Docling,
  title   = {Docling Technical Report},
  author  = {Auer, Christoph and Lysak, Maksym and others (IBM Research)},
  journal = {arXiv preprint},
  year    = {2024}
}
```
