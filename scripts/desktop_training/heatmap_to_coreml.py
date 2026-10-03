#!/usr/bin/env python3
"""
Convert a trained multi-frame heatmap model (train_heatmap_model.py's
best.pt) to Core ML for RallyLab and the app. Runs on the Mac; RallyLab's
Models tab calls it when you add a bring_back folder.

    python heatmap_to_coreml.py <bring_back folder or best.pt> <out.mlpackage>

Input "clip": [1, 9, H, W] float, 9 consecutive grayscale frames scaled to
0–1, oldest first (portrait frames turned a quarter turn clockwise first).
Output "maps": [1, 18, H, W] — 9 heatmaps (sigmoid, 0–1) then 9 radius maps
(fraction of frame width). FP16, as Apple's Neural Engine runs it.

The input size, the package it was trained on and the scores are read from
metrics.json beside best.pt and kept in the model's metadata.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import train_heatmap_model as t  # noqa: E402  (also checks torch/numpy/cv2)


def main() -> None:
    if len(sys.argv) != 3:
        t.fail("usage: heatmap_to_coreml.py <bring_back folder or best.pt> <out.mlpackage>")
    source, out = Path(sys.argv[1]), Path(sys.argv[2])
    checkpoint = source / "best.pt" if source.is_dir() else source
    if not checkpoint.exists():
        t.fail(f"No best.pt at {checkpoint}")
    metrics_file = checkpoint.parent / "metrics.json"
    metrics = json.loads(metrics_file.read_text()) if metrics_file.exists() else {}
    width, height = metrics.get("size", t.SIZES[512])

    try:
        import coremltools as ct
    except ImportError:
        t.fail("pip install coremltools")
    import numpy as np
    import torch

    t.vballnet_source()
    from model.vballnet_v4c import VballNetV4c
    model = VballNetV4c(height=height, width=width, in_dim=t.SEQ, out_dim=t.SEQ)
    model.load_state_dict(torch.load(checkpoint, map_location="cpu")["state_dict"])
    model.eval()

    example = torch.rand(1, t.SEQ, height, width)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="clip", shape=(1, t.SEQ, height, width), dtype=np.float32)],
        outputs=[ct.TensorType(name="maps", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    best = metrics.get("best") or {}
    tracked = best.get("tracked@4") or best.get("all@4") or {}
    mlmodel.author = "RallyLab — VballNetV4c (MIT, Alexander Sigatchov), fine-tuned"
    mlmodel.short_description = f"Multi-frame volleyball heatmap, {t.SEQ} grayscale frames at {width}x{height}"
    mlmodel.user_defined_metadata.update({
        "kind": "heatmap",
        "seq": str(t.SEQ),
        "width": str(width),
        "height": str(height),
        "threshold": "0.5",
        "package": str(metrics.get("package", "")),
        "best_epoch": str(metrics.get("best_epoch", "")),
        "tracked_recall": str(tracked.get("recall", "")),
        "tracked_precision": str(tracked.get("precision", "")),
    })
    mlmodel.save(str(out))

    # Same answer as PyTorch? (FP16 moves a heatmap value by a few thousandths.)
    with torch.no_grad():
        want = model(example).numpy()
    got = mlmodel.predict({"clip": example.numpy()})["maps"]
    diff = float(np.abs(got[:, :t.SEQ] - want[:, :t.SEQ]).max())
    t.say(f"Saved {out.name} ({width}×{height}). Largest heatmap difference vs PyTorch: {diff:.4f}")
    if diff > 0.05:
        t.fail("The Core ML model doesn't match PyTorch — not using it.")


if __name__ == "__main__":
    main()
