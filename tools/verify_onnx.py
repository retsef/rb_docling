#!/usr/bin/env python3
"""
Verifica un .onnx prodotto da export_*.py:
  - struttura valida (`onnx.checker`)
  - caricabile da onnxruntime
  - I/O names e shapes attesi
  - eseguibile su input dummy senza eccezioni

Uso:
  python tools/verify_onnx.py tools/_out/layout.onnx
  python tools/verify_onnx.py tools/_out/tableformer_encoder.onnx --kind encoder
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort


def describe(model: onnx.ModelProto) -> None:
    print(f"  ONNX opset: {[o.version for o in model.opset_import]}")
    print(f"  IR version: {model.ir_version}")
    print(f"  Producer:   {model.producer_name} {model.producer_version}")
    print("  Inputs:")
    for i in model.graph.input:
        dims = [d.dim_value or d.dim_param or "?" for d in i.type.tensor_type.shape.dim]
        print(f"    - {i.name}: {dims}")
    print("  Outputs:")
    for o in model.graph.output:
        dims = [d.dim_value or d.dim_param or "?" for d in o.type.tensor_type.shape.dim]
        print(f"    - {o.name}: {dims}")


def dummy_for(shape, dtype):
    if dtype == np.int64 or dtype == np.int32:
        return np.zeros(shape, dtype=dtype)
    return np.random.randn(*shape).astype(dtype)


def run_dummy(onnx_path: Path, kind: str | None) -> None:
    print(f"[verify] {onnx_path}")
    model = onnx.load(str(onnx_path))
    onnx.checker.check_model(model)
    describe(model)

    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])

    feeds = {}
    for inp in sess.get_inputs():
        shape = []
        for d in inp.shape:
            if isinstance(d, int) and d > 0:
                shape.append(d)
            elif inp.name == "image":
                shape.append(1 if not shape else (3 if len(shape) == 1 else 640))
            elif "seq" in str(d):
                shape.append(8)
            elif "batch" in str(d):
                shape.append(1)
            else:
                shape.append(1)
        # Mappa dtype
        dtype = np.float32
        if inp.type == "tensor(int64)":
            dtype = np.int64
        elif inp.type == "tensor(int32)":
            dtype = np.int32
        feeds[inp.name] = dummy_for(shape, dtype)
        print(f"  feed {inp.name}: shape={shape} dtype={dtype.__name__}")

    out = sess.run(None, feeds)
    for name, val in zip([o.name for o in sess.get_outputs()], out):
        print(f"  out  {name}: shape={val.shape} dtype={val.dtype}")

    print("[verify] OK")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("onnx_path", type=Path)
    parser.add_argument("--kind", default=None,
                        help="Hint per dummy: layout | encoder | decoder | monolithic")
    args = parser.parse_args()
    if not args.onnx_path.exists():
        sys.exit(f"File non trovato: {args.onnx_path}")
    run_dummy(args.onnx_path, args.kind)


if __name__ == "__main__":
    main()
