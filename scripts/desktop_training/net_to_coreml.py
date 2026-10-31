#!/usr/bin/env python3
"""
Convert a trained net detector (train_net_model.py's best.pt) to Core ML.
Runs on the Mac, in the same .venv as heatmap_to_coreml.py.

    python net_to_coreml.py <bring_back folder or best.pt> <out.mlpackage>

Input "frame": an RGB image of 384×216, the frame letterboxed (scaled to fit,
centred, grey 114 borders) — pixels 0–255, scaled to 0–1 inside the model.
Output "net": [1, 5] — presence (0–1), then the box's centre x, centre y,
width and height as fractions of the letterboxed image, y downwards. The
caller maps the box back through the same letterbox (train_net_model.py
`letterbox_back`). FP16, as Apple's Neural Engine runs it.

The trainer's metrics.json beside best.pt (scores, data digests, code SHA)
is kept in the model's metadata. The conversion is checked against the
PyTorch model on a random image before the file is written.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import train_net_model as t  # noqa: E402

MAX_DIFF = 0.02


def convert(checkpoint: Path, out: Path) -> float:
    """Write `out`; returns the largest difference between Core ML and PyTorch on a random frame."""
    import numpy as np
    try:
        import coremltools as ct
    except ImportError:
        t.fail("Missing coremltools. In the .venv: pip install coremltools")
    torch, _ = t.torch_modules()
    metrics_file = checkpoint.parent / "metrics.json"
    metrics = json.loads(metrics_file.read_text()) if metrics_file.exists() else {}
    NetBoxNet, Deploy = t.build_model()
    model = NetBoxNet()
    saved = torch.load(checkpoint, map_location="cpu")
    model.load_state_dict(saved["state_dict"])
    deploy = Deploy(model).eval()
    example = torch.rand(1, 3, t.HEIGHT, t.WIDTH)
    traced = torch.jit.trace(deploy, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="frame", shape=(1, 3, t.HEIGHT, t.WIDTH), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="net", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    best = metrics.get("best") or metrics.get("scored") or {}
    mlmodel.author = "BumpSetCut — train_net_model.py (from scratch, no third-party weights)"
    mlmodel.short_description = ("Net detector: presence and box (cx, cy, w, h; fractions of the 384×216 letterboxed frame, y down) "
                                 "from one upright RGB frame.")
    mlmodel.version = f"epoch {saved.get('epoch')}"
    mlmodel.user_defined_metadata["trainer"] = "train_net_model.py"
    mlmodel.user_defined_metadata["letterbox"] = f"fit in {t.WIDTH}x{t.HEIGHT}, centred, pad {t.PAD_GREY}"
    mlmodel.user_defined_metadata["output"] = "net[1,5]: presence, cx, cy, w, h"
    for key in ("code_sha", "val_digest", "train_digest", "manifest_sha256", "seed", "best_epoch", "best_sha256"):
        if metrics.get(key) is not None:
            mlmodel.user_defined_metadata[key] = str(metrics[key])
    if best:
        mlmodel.user_defined_metadata["val"] = json.dumps({k: best.get(k) for k in ("frames", "detect_rate", "top_error", "left_error",
                                                                                 "right_error", "iou_mean", "top_median_range90")})
    # Check against PyTorch on a random frame before anything is written.
    from PIL import Image
    pixels = (np.random.default_rng(0).random((t.HEIGHT, t.WIDTH, 3)) * 255).astype(np.uint8)
    with torch.no_grad():
        want = deploy(torch.from_numpy(pixels.transpose(2, 0, 1)).float().unsqueeze(0) / 255.0).numpy()[0]
    got = np.asarray(mlmodel.predict({"frame": Image.fromarray(pixels)})["net"]).reshape(-1)
    diff = float(np.abs(got - want).max())
    if diff > MAX_DIFF:
        t.fail(f"Core ML differs from PyTorch by {diff:.4f} (> {MAX_DIFF}); not written")
    mlmodel.save(str(out))
    return diff


def main() -> None:
    if len(sys.argv) != 3:
        t.fail("usage: net_to_coreml.py <bring_back folder or best.pt> <out.mlpackage>")
    source, out = Path(sys.argv[1]), Path(sys.argv[2])
    checkpoint = source / "best.pt" if source.is_dir() else source
    if not checkpoint.exists():
        t.fail(f"No best.pt at {checkpoint}")
    if out.exists():
        t.fail(f"{out} exists")
    diff = convert(checkpoint, out)
    t.say(f"✅ {out} written; Core ML vs PyTorch max diff {diff:.4f} on a random frame")


if __name__ == "__main__":
    main()
