#!/usr/bin/env python3
"""
Export di TableFormer da PyTorch a ONNX.

Due modalità:
  --mode split        encoder + decoder come due .onnx separati.
                      Permette decoding autoregressivo lato Ruby (preferito).
                      rb_docling OnnxTableFormer mode :split.
  --mode monolithic   un unico .onnx con seq_len fisso. Più semplice da
                      esportare, meno flessibile. Compatibile col formato di
                      asmud/ds4sd-docling-models-onnx.
                      rb_docling OnnxTableFormer mode :monolithic.

Output:
  --mode split:       tools/_out/tableformer_encoder.onnx
                      tools/_out/tableformer_decoder.onnx
                      tools/_out/tableformer_vocab.json     ← cruciale
  --mode monolithic:  tools/_out/tableformer.onnx
                      tools/_out/tableformer_vocab.json

ATTENZIONE - punti di calibrazione:
  - Il vocabolario OTSL (`tableformer_vocab.json`) DEVE essere allineato col
    decoder. È l'ordine esatto dei token nello stato del modello PyTorch.
    rb_docling lo carica in OnnxTableFormer per detokenizzare.
  - L'export di un loop autoregressivo non funziona out-of-the-box con
    `torch.onnx.export` (cattura solo un forward). Per `--mode split` esportiamo
    encoder e decoder come due grafi separati, e ricostruiamo il loop in Ruby.

Uso:
  python tools/export_tableformer.py [--variant accurate|fast]
                                     [--mode split|monolithic]
                                     [--out-dir tools/_out]
                                     [--opset 17]
                                     [--max-seq-len 512]   # solo monolithic
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import torch
from huggingface_hub import snapshot_download


def load_tableformer(snapshot_path: Path, variant: str):
    """Ritorna (model, vocab_list, image_size).

    TODO[calibrate]: API di docling-ibm-models. Da verificare:
      - import path: `docling_ibm_models.tableformer.models.table04_rs.tablemodel04_rs`
        per la variante v0.4 RS. Versioni più recenti possono aver rinominato.
      - costruttore / metodo `load_from(path)` vs init manuale + load_state_dict.
      - dove vive il vocab OTSL (di solito in un YAML/json adiacente).
    """
    try:
        from docling_ibm_models.tableformer.models.table04_rs.tablemodel04_rs import TableModel04_rs
    except ImportError as e:
        sys.exit(
            "Manca docling-ibm-models. Installa: pip install -r tools/requirements.txt\n"
            f"  Dettaglio: {e}"
        )

    variant_dir = snapshot_path / "model_artifacts" / "tableformer" / variant
    if not variant_dir.exists():
        # Fallback: alcune release piattano la struttura
        variant_dir = snapshot_path

    model = TableModel04_rs.load_from(str(variant_dir))
    model.eval()

    # Vocab OTSL — TODO[calibrate]: nome file e formato variano
    vocab = None
    for candidate in ("word_map.json", "vocab.json", "otsl_vocab.json"):
        p = variant_dir / candidate
        if p.exists():
            vocab = json.loads(p.read_text())
            break
    if vocab is None:
        # Ultimo tentativo: estrai dal modello (alcune impl espongono `model.vocab`)
        vocab = getattr(model, "vocab", None) or getattr(model, "word_map", None)
    if vocab is None:
        raise RuntimeError(
            "Vocab OTSL non trovato nel snapshot. Cerca file *.json in "
            f"{variant_dir} e aggiorna `load_tableformer`."
        )

    # TODO[calibrate]: dimensione input. TableFormer originale 448x448.
    image_size = 448
    return model, vocab, image_size


def export_split(model, vocab, image_size: int, out_dir: Path, opset: int) -> None:
    """Encoder + decoder come due grafi separati."""
    encoder = model.encoder
    decoder = model.decoder

    # ----- Encoder -----
    dummy_img = torch.randn(1, 3, image_size, image_size)
    enc_path = out_dir / "tableformer_encoder.onnx"
    print(f"[tableformer] export encoder → {enc_path}")
    torch.onnx.export(
        encoder,
        (dummy_img,),
        str(enc_path),
        input_names=["image"],
        output_names=["memory"],
        dynamic_axes={
            "image": {0: "batch"},
            "memory": {0: "batch", 1: "seq_enc"},
        },
        opset_version=opset,
        do_constant_folding=True,
    )

    # ----- Decoder -----
    # TODO[calibrate]: la firma esatta del decoder dipende dall'implementazione.
    # Tipicamente: (prev_tokens [B, T], memory [B, S, D]) → (logits [B, T, V], bbox [B, T, 4])
    # Verifica con `print(decoder.forward.__doc__)` o leggi il sorgente.
    vocab_size = len(vocab) if isinstance(vocab, (list, dict)) else 100
    dummy_mem = torch.randn(1, 196, 256)   # 196 = (14*14) patches a 448/32, 256 = hidden dim TF
    dummy_tokens = torch.zeros((1, 1), dtype=torch.long)
    dec_path = out_dir / "tableformer_decoder.onnx"
    print(f"[tableformer] export decoder → {dec_path} (vocab_size={vocab_size})")
    torch.onnx.export(
        decoder,
        (dummy_tokens, dummy_mem),
        str(dec_path),
        input_names=["prev_tokens", "memory"],
        output_names=["logits", "bbox"],
        dynamic_axes={
            "prev_tokens": {0: "batch", 1: "seq_dec"},
            "memory":      {0: "batch", 1: "seq_enc"},
            "logits":      {0: "batch", 1: "seq_dec"},
            "bbox":        {0: "batch", 1: "seq_dec"},
        },
        opset_version=opset,
        do_constant_folding=True,
    )


def export_monolithic(model, image_size: int, out_dir: Path, opset: int,
                      max_seq_len: int) -> None:
    """Singolo grafo: image → (tokens, bboxes) con seq_len fisso."""
    dummy_img = torch.randn(1, 3, image_size, image_size)
    mono_path = out_dir / "tableformer.onnx"
    print(f"[tableformer] export monolithic → {mono_path} (seq_len={max_seq_len})")

    # TODO[calibrate]: il forward "completo" di TableModel04_rs potrebbe esporre
    # un'API tipo `predict(img, max_len=...)` che NON è tracciabile direttamente.
    # In quel caso, scrivere un wrapper:
    #
    #   class TFWrapper(torch.nn.Module):
    #       def __init__(self, m, max_len):
    #           super().__init__(); self.m = m; self.max_len = max_len
    #       def forward(self, img):
    #           return self.m.predict(img, max_len=self.max_len)
    #
    # e passare TFWrapper(model, max_seq_len) a torch.onnx.export.
    wrapper = model
    torch.onnx.export(
        wrapper,
        (dummy_img,),
        str(mono_path),
        input_names=["image"],
        output_names=["tokens", "bboxes"],
        dynamic_axes={
            "image":  {0: "batch"},
            "tokens": {0: "batch", 1: "seq"},
            "bboxes": {0: "batch", 1: "seq"},
        },
        opset_version=opset,
        do_constant_folding=True,
    )


def export(args: argparse.Namespace) -> None:
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[tableformer] download ds4sd/docling-models (variant: {args.variant})")
    snap = Path(snapshot_download(
        "ds4sd/docling-models",
        allow_patterns=[f"model_artifacts/tableformer/{args.variant}/*"],
    ))
    print(f"[tableformer] snapshot: {snap}")

    model, vocab, image_size = load_tableformer(snap, args.variant)

    # Scrivi vocab in formato canonico per rb_docling
    vocab_path = out_dir / "tableformer_vocab.json"
    vocab_path.write_text(json.dumps(vocab, indent=2, ensure_ascii=False))
    print(f"[tableformer] vocab OTSL salvato in {vocab_path} ({len(vocab)} token)")

    if args.mode == "split":
        export_split(model, vocab, image_size, out_dir, args.opset)
    else:
        export_monolithic(model, image_size, out_dir, args.opset, args.max_seq_len)

    # Sanity check tutti gli .onnx prodotti
    import onnx
    for onnx_file in out_dir.glob("tableformer*.onnx"):
        m = onnx.load(str(onnx_file))
        onnx.checker.check_model(m)
        size_mb = onnx_file.stat().st_size / (1024 * 1024)
        print(f"[tableformer] ok: {onnx_file.name} ({size_mb:.1f} MB)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=["accurate", "fast"], default="accurate")
    parser.add_argument("--mode", choices=["split", "monolithic"], default="split")
    parser.add_argument("--out-dir", default="tools/_out")
    parser.add_argument("--opset", type=int, default=17)
    parser.add_argument("--max-seq-len", type=int, default=512,
                        help="Solo per --mode monolithic")
    args = parser.parse_args()
    export(args)


if __name__ == "__main__":
    main()
