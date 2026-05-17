#!/usr/bin/env python3
"""
Export del modello layout Docling (DocLayNet RT-DETR / Heron) da PyTorch a ONNX.

Output: tools/_out/layout.onnx

L'output viene poi caricato in rb_docling tramite RbDocling::Layout::OnnxLayout.

ATTENZIONE - punti di calibrazione:
  Questo script è una BASE FUNZIONANTE ma le API di docling-ibm-models cambiano
  tra release. I punti contrassegnati con `# TODO[calibrate]` vanno verificati
  contro la versione installata di docling-ibm-models. Vedi tools/README.md.

Uso:
  python tools/export_layout.py [--repo ds4sd/docling-layout-heron-101]
                                [--out tools/_out/layout.onnx]
                                [--opset 17]
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import torch
from huggingface_hub import snapshot_download


def discover_model(snapshot_path: Path) -> torch.nn.Module:
    """Carica il nn.Module interno dal checkpoint scaricato.

    TODO[calibrate]: l'API esatta di `LayoutPredictor` può cambiare tra versioni
    di docling-ibm-models. Punti da verificare nel proprio venv:
      - import path (`docling_ibm_models.layoutmodel.layout_predictor` o sim.)
      - nome attributo che espone il `nn.Module` (`.model` / `._model` / `.detector`)
      - costruttore: alcune versioni vogliono `device=`, altre `device=str`,
        altre auto-detect.
    Per ispezionare a runtime:
      python -c "from docling_ibm_models.layoutmodel.layout_predictor import LayoutPredictor; \
                 p = LayoutPredictor('PATH', device='cpu'); print(dir(p))"
    """
    try:
        from docling_ibm_models.layoutmodel.layout_predictor import LayoutPredictor
    except ImportError as e:
        sys.exit(
            "Manca docling-ibm-models. Installa: pip install -r tools/requirements.txt\n"
            f"  Dettaglio: {e}"
        )

    predictor = LayoutPredictor(str(snapshot_path), device="cpu")

    # Cerca attributo nn.Module
    for candidate in ("model", "_model", "detector", "_detector", "net"):
        obj = getattr(predictor, candidate, None)
        if isinstance(obj, torch.nn.Module):
            print(f"[layout] modulo trovato come predictor.{candidate}")
            return obj

    raise RuntimeError(
        "Nessun nn.Module trovato in LayoutPredictor. "
        "Esplora con `print(dir(predictor))` e aggiorna `discover_model()`."
    )


def export(args: argparse.Namespace) -> None:
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"[layout] download repo: {args.repo}")
    snap = Path(snapshot_download(args.repo))
    print(f"[layout] snapshot: {snap}")

    model = discover_model(snap)
    model.eval()

    # TODO[calibrate]: dimensione input. RT-DETR canonico è 640x640, Heron
    # potrebbe usare 800x800 o 1024x1024. Controlla `config.json` nel snapshot.
    h = w = args.input_size
    dummy = torch.randn(1, 3, h, w, dtype=torch.float32)

    print(f"[layout] export → {out_path} (opset {args.opset})")
    torch.onnx.export(
        model,
        (dummy,),
        str(out_path),
        # TODO[calibrate]: i nomi I/O dipendono da come il forward del modulo
        # è scritto. rb_docling OnnxLayout fa autodetection — funziona sia con
        # "labels/boxes/scores" sia con "logits/pred_boxes" (RT-DETRv2).
        input_names=["image"],
        output_names=["logits", "pred_boxes"],
        dynamic_axes={
            "image": {0: "batch", 2: "h", 3: "w"},
            "logits": {0: "batch", 1: "num_queries"},
            "pred_boxes": {0: "batch", 1: "num_queries"},
        },
        opset_version=args.opset,
        do_constant_folding=True,
    )

    # Sanity check
    import onnx
    m = onnx.load(str(out_path))
    onnx.checker.check_model(m)
    size_mb = out_path.stat().st_size / (1024 * 1024)
    print(f"[layout] ok: {size_mb:.1f} MB")
    print(f"[layout] inputs:  {[i.name for i in m.graph.input]}")
    print(f"[layout] outputs: {[o.name for o in m.graph.output]}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="ds4sd/docling-layout-heron-101",
                        help="Repo HuggingFace del modello (default: Heron-101)")
    parser.add_argument("--out", default="tools/_out/layout.onnx",
                        help="Path .onnx di output")
    parser.add_argument("--input-size", type=int, default=640,
                        help="Dimensione lato input (NxN). Default 640.")
    parser.add_argument("--opset", type=int, default=17,
                        help="ONNX opset version. 17 minimo per RT-DETR.")
    args = parser.parse_args()
    export(args)


if __name__ == "__main__":
    main()
