#!/usr/bin/env python3
"""
Export di TableFormer (docling-ibm-models) da PyTorch a ONNX.

API reale di docling-ibm-models (verificata): non c'è `TableModel04_rs.load_from`.
Il path corretto è:
  1. snapshot_download("ds4sd/docling-models", allow_patterns=...)
  2. carica `tm_config.json` (contiene dataset_wordmap, model.type, ecc.)
  3. set config["model"]["save_dir"] al path della variant directory
  4. TFPredictor(config, device='cpu') → carica TableModel04_rs e safetensors
  5. predictor.get_model() → nn.Module

Output:
  tools/_out/tableformer_encoder.onnx       (immagine → encoder_out)
  tools/_out/tableformer_vocab.json         (word_map_tag — vocab OTSL)
  tools/_out/tableformer_tm_config.json     (copia del tm_config.json originale)
  tools/_out/tableformer_decoder_step.onnx  (un singolo step di decoding, se --mode split)

Note onestà:
  - L'**encoder** (CNN Encoder04 + transformer encoder) è esportabile direttamente.
  - Il **decoder** tag-transformer è autoregressivo con caching. Non è
    direttamente tracciabile con torch.onnx.export. Per --mode split esportiamo
    un wrapper "single-step" — il loop autoregressivo va ricostruito lato Ruby.
  - Per --mode monolithic l'export di model.predict(...) non funziona perché
    contiene branching dipendente da .item() (vedi tablemodel04_rs.py linee
    194-260). Lasciato come scaffolding; useremo --mode split di default.

Uso:
  python tools/export_tableformer.py [--variant accurate|fast]
                                     [--mode split|encoder-only]
                                     [--out-dir tools/_out]
                                     [--opset 17]
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

import torch
from huggingface_hub import snapshot_download


def load_predictor(snapshot_path: Path, variant: str):
    """Carica TFPredictor con il config reale dal snapshot.

    Ritorna (predictor, config, variant_dir).
    """
    try:
        from docling_ibm_models.tableformer.data_management.tf_predictor import TFPredictor
    except ImportError as e:
        sys.exit(
            "Manca docling-ibm-models. Installa: pip install -r tools/requirements.txt\n"
            f"  Dettaglio: {e}"
        )

    variant_dir = snapshot_path / "model_artifacts" / "tableformer" / variant
    if not variant_dir.exists():
        sys.exit(f"Variant dir non trovata: {variant_dir}")

    config_path = variant_dir / "tm_config.json"
    if not config_path.exists():
        sys.exit(f"tm_config.json non trovato in {variant_dir}")

    config = json.loads(config_path.read_text())

    # Il config originale ha save_dir hardcoded (path di training).
    # Lo punto alla directory locale che contiene il .safetensors.
    config.setdefault("model", {})
    config["model"]["save_dir"] = str(variant_dir)

    predictor = TFPredictor(config, device="cpu")
    return predictor, config, variant_dir


def export_encoder(model, out_path: Path, image_size: int, opset: int) -> None:
    """Esporta encoder visivo + transformer-encoder (parte one-shot del forward).

    Replica la prima metà di model.predict():
      enc_out = self._encoder(imgs)                         # CNN Encoder04
      enc_out = self._tag_transformer._input_filter(...)   # 1x1 conv proj
      encoder_out = self._tag_transformer._encoder(...)    # transformer encoder
    """
    encoder_cnn = model._encoder
    tt = model._tag_transformer

    class EncoderWrapper(torch.nn.Module):
        def __init__(self, enc, tt):
            super().__init__()
            self.enc = enc
            self.tt = tt

        def forward(self, imgs):
            enc_out = self.enc(imgs)                                   # [B, H, W, C]
            x = self.tt._input_filter(enc_out.permute(0, 3, 1, 2))     # [B, D, H, W]
            x = x.permute(0, 2, 3, 1)                                  # [B, H, W, D]
            B = x.size(0); D = x.size(-1)
            enc_in = x.view(B, -1, D).permute(1, 0, 2)                 # [S, B, D]
            # Encoder transformer "no mask" path (mask di soli True/False
            # uguali → effettivamente all-zero). Per export lo omettiamo.
            return self.tt._encoder(enc_in)

    wrapper = EncoderWrapper(encoder_cnn, tt).eval()
    dummy = torch.randn(1, 3, image_size, image_size)

    print(f"[tableformer] export encoder → {out_path}")
    torch.onnx.export(
        wrapper, (dummy,), str(out_path),
        input_names=["image"],
        output_names=["encoder_out"],
        dynamic_axes={
            "image":       {0: "batch"},
            "encoder_out": {1: "batch"},
        },
        opset_version=opset,
        do_constant_folding=True,
    )


def export_decoder_step(model, out_path: Path, opset: int,
                        encoder_dim: int, max_seq_seed: int = 8) -> None:
    """Esporta UN SOLO step del decoder tag-transformer (senza cache).

    Firma:
      input:  decoded_tags [T, 1] (int64), encoder_out [S, 1, D]
      output: logits_last  [1, V]

    Il loop autoregressivo (concatenazione tag + decisioni branching OTSL come
    `xcel→lcel`, `ucel,lcel→fcel`, `lcel` span merging, ecc.) va riprodotto
    lato Ruby usando il vocab in tableformer_vocab.json.
    """
    tt = model._tag_transformer

    class DecoderStep(torch.nn.Module):
        def __init__(self, tt):
            super().__init__()
            self.tt = tt

        def forward(self, decoded_tags, encoder_out):
            emb = self.tt._embedding(decoded_tags)
            emb = self.tt._positional_encoding(emb)
            # cache=None → ricomputa ogni step (più lento ma esportabile;
            # caching transformer non si traccia bene con torch.onnx).
            decoded, _ = self.tt._decoder(emb, encoder_out, None)
            logits = self.tt._fc(decoded[-1, :, :])    # [B, V]
            return logits

    wrapper = DecoderStep(tt).eval()
    # Dummy: T=max_seq_seed step, S=784 (28*28) tipico per enc_image_size=28
    dummy_tags = torch.zeros((max_seq_seed, 1), dtype=torch.long)
    dummy_enc  = torch.randn(784, 1, encoder_dim)

    print(f"[tableformer] export decoder step → {out_path}")
    torch.onnx.export(
        wrapper, (dummy_tags, dummy_enc), str(out_path),
        input_names=["decoded_tags", "encoder_out"],
        output_names=["logits"],
        dynamic_axes={
            "decoded_tags": {0: "seq_dec", 1: "batch"},
            "encoder_out":  {0: "seq_enc", 1: "batch"},
            "logits":       {0: "batch"},
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

    predictor, config, variant_dir = load_predictor(snap, args.variant)
    model = predictor.get_model()
    model.eval()

    # --- artifacts di config / vocab -----------------------------------
    # Vocab OTSL: word_map_tag è quello che il decoder predice.
    vocab_path = out_dir / "tableformer_vocab.json"
    vocab_path.write_text(json.dumps(
        config["dataset_wordmap"]["word_map_tag"],
        indent=2, ensure_ascii=False
    ))
    print(f"[tableformer] vocab OTSL salvato in {vocab_path} "
          f"({len(config['dataset_wordmap']['word_map_tag'])} token)")

    # Copia anche il tm_config originale: è utile a rb_docling per leggere
    # parametri di preprocessing (image_size, ecc.) e word_map_cell.
    cfg_copy = out_dir / "tableformer_tm_config.json"
    shutil.copy(variant_dir / "tm_config.json", cfg_copy)
    print(f"[tableformer] config originale copiato in {cfg_copy}")

    # --- ONNX export ---------------------------------------------------
    # image_size canonico: enc_image_size * 16 (stride resnet18). Default 28*16=448.
    enc_image_size = config["model"].get("enc_image_size", 28)
    image_size = enc_image_size * 16
    print(f"[tableformer] image_size: {image_size} (enc_image_size={enc_image_size})")

    enc_out_path = out_dir / "tableformer_encoder.onnx"
    export_encoder(model, enc_out_path, image_size, args.opset)

    if args.mode == "split":
        encoder_dim = config["model"]["hidden_dim"]
        dec_out_path = out_dir / "tableformer_decoder_step.onnx"
        export_decoder_step(model, dec_out_path, args.opset, encoder_dim)

    # Sanity check
    import onnx
    for onnx_file in sorted(out_dir.glob("tableformer*.onnx")):
        m = onnx.load(str(onnx_file))
        onnx.checker.check_model(m)
        size_mb = onnx_file.stat().st_size / (1024 * 1024)
        print(f"[tableformer] ok: {onnx_file.name} ({size_mb:.1f} MB)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=["accurate", "fast"], default="accurate")
    parser.add_argument("--mode", choices=["split", "encoder-only"], default="split",
                        help="split: encoder + decoder-step (default). "
                             "encoder-only: solo encoder (debug)")
    parser.add_argument("--out-dir", default="tools/_out")
    parser.add_argument("--opset", type=int, default=17)
    args = parser.parse_args()
    export(args)


if __name__ == "__main__":
    main()
