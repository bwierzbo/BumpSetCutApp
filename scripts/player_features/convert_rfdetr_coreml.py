#!/usr/bin/env python3
"""Export Roboflow RF-DETR (COCO checkpoints) to Core ML for the player-feasibility research (P1, licence-clean candidate).

RF-DETR's code and its Nano/Small/Medium/Large COCO checkpoints are Apache-2.0 (the package's checkpoint table; the
Atto/Femto/Pico/XLarge/2XLarge checkpoints are PML 1.0 and are not used). That makes them the shippable-without-training
candidate. Two caveats are recorded in every package's metadata rather than resolved here: the backbone is DINOv2
(Apache-2.0, trained on Meta's LVD-142M), and Roboflow's RF-DETR paper pretrains the detector on Objects365 before COCO,
whose own terms are reported as non-commercial — whether that pretraining makes the weights unusable is the owner's/legal
call, not this script's. The models produced live in the experiment folder, never in git or the app bundle.

The export is the package's own (``model.export(format="coreml")``, marked experimental upstream), so the graph is the
one a production build would use:

  input  "input" [1, 3, N, N] float32: the RGB frame stretched to N x N (no letterbox), bilinear without antialias, scaled to
         0-1 and ImageNet-normalised (mean 0.485/0.456/0.406, std 0.229/0.224/0.225). N = 512 Small, 576 Medium.
  output "boxes"  [1, 300, 4]  (cx, cy, w, h), normalised to the input
         "logits" [1, 300, 91] per-class logits, sparse COCO ids (slot 1 = person); score = sigmoid, no NMS (DETR)

Then, on real frames, it checks
  1. that slot 1 is the person class, against the package's own ``predict()`` (persons above 0.3), and
  2. the Core ML packages (fp16 and fp32) against eager PyTorch on the identical input tensor (conversion error),
picks fp16 when it matches as well as fp32 does (the Neural Engine runs fp16 only), and writes conversion-report.json.

Usage (Python 3.12, rfdetr 1.12 with the coreml extra):
  RF_HOME=<models>/weights convert_rfdetr_coreml.py --models <experiment>/models/rfdetr --frames <frame.jpg> [...]
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import warnings

import numpy as np

warnings.filterwarnings("ignore")

SIZES = {"small": ("RFDETRSmall", "rf-detr-small.pth"), "medium": ("RFDETRMedium", "rf-detr-medium.pth")}
PERSON_SLOT = 1
THRESHOLD = 0.3
MEAN = [0.485, 0.456, 0.406]
STD = [0.229, 0.224, 0.225]
TRAINING_DATA = ("COCO 2017 detection fine-tune (Roboflow); backbone DINOv2 ViT-S (Apache-2.0, Meta LVD-142M); "
                 "detector pretraining on Objects365 per the RF-DETR paper (Objects365 terms reported non-commercial: "
                 "unresolved, owner decision)")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_sha256(path):
    h = hashlib.sha256()
    for root, dirs, files in os.walk(path):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            h.update(os.path.relpath(full, path).encode())
            h.update(sha256(full).encode())
    return h.hexdigest()


def model_input(image, n):
    """The package's own inference transform (rfdetr.export.benchmark.infer_transforms) on one PIL image."""
    import torch
    import torchvision.transforms.functional as F
    t = F.to_tensor(image)
    t = F.resize(t, [n, n], antialias=False)
    t = F.normalize(t, MEAN, STD)
    return t.unsqueeze(0).contiguous().to(torch.float32)


def persons(boxes, logits, w, h, thr=THRESHOLD):
    """Person detections above `thr` from raw outputs: [(score, x1, y1, x2, y2)] in pixels, best first."""
    s = 1.0 / (1.0 + np.exp(-np.clip(logits[0, :, PERSON_SLOT], -88, 88)))
    out = []
    for q in np.nonzero(s > thr)[0]:
        cx, cy, bw, bh = boxes[0, q]
        out.append(tuple(float(v) for v in (s[q], (cx - bw / 2) * w, (cy - bh / 2) * h, (cx + bw / 2) * w, (cy + bh / 2) * h)))
    return sorted(out, reverse=True)


def iou(a, b):
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def match(ref, got):
    """Greedy best-IoU match of `got` to `ref`: (matched count, min IoU, max score difference)."""
    used, ious, ds = set(), [], []
    for r in ref:
        best, bi = 0.0, None
        for i, g in enumerate(got):
            if i not in used and iou(r[1:], g[1:]) > best:
                best, bi = iou(r[1:], g[1:]), i
        if bi is not None and best > 0.5:
            used.add(bi)
            ious.append(best)
            ds.append(abs(r[0] - got[bi][0]))
    return len(ious), (min(ious) if ious else None), (max(ds) if ds else None)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--frames", nargs="+", required=True)
    ap.add_argument("--sizes", nargs="+", default=list(SIZES))
    a = ap.parse_args(argv)
    if not os.environ.get("RF_HOME"):
        sys.exit("set RF_HOME to the experiment's weights folder so the checkpoints land there")
    import coremltools as ct
    import rfdetr
    import torch
    from PIL import Image
    from rfdetr.assets.model_weights import ModelWeights

    os.makedirs(a.models, exist_ok=True)
    assets = {m.value.filename: m.value for m in ModelWeights}
    report = {"rfdetr": rfdetr.__version__ if hasattr(rfdetr, "__version__") else "?", "torch": torch.__version__,
              "coremltools": ct.__version__, "threshold": THRESHOLD, "personSlot": PERSON_SLOT, "models": {}}
    frames = [(os.path.basename(f), Image.open(f).convert("RGB")) for f in a.frames]
    for size in a.sizes:
        cls_name, ckpt = SIZES[size]
        model = getattr(rfdetr, cls_name)()
        n = model.model_config.resolution
        ckpt_path = os.path.join(os.environ["RF_HOME"], ckpt)
        asset = assets[ckpt]
        provenance = {"checkpoint": ckpt, "checkpointUrl": asset.url, "checkpointMd5": asset.md5_hash,
                      "checkpointSha256": sha256(ckpt_path), "license": "Apache-2.0 (code and this checkpoint, per rfdetr's checkpoint table)",
                      "trainingData": TRAINING_DATA, "resolution": str(n), "personSlot": str(PERSON_SLOT),
                      "preprocess": "stretch to NxN, bilinear no antialias, /255, ImageNet mean/std",
                      "outputs": "boxes [1,300,4] cxcywh normalised; logits [1,300,91] sparse COCO ids, sigmoid, no NMS"}
        entry = {"class": cls_name, "resolution": n, **provenance, "frames": []}
        packages = {}
        with tempfile.TemporaryDirectory() as tmp:
            for precision in ("float16", "float32"):
                p = model.export(format="coreml", output_dir=os.path.join(tmp, precision), coreml_precision=precision, verbose=False)
                packages[precision] = ct.models.MLModel(str(p))
            torch_model = model.model.model.eval()
            for name, img in frames:
                w, h = img.size
                x = model_input(img, n)
                official = model.predict(img, threshold=THRESHOLD)
                official_persons = int(np.sum(np.asarray(official.class_id) == PERSON_SLOT)) if len(official) else 0
                official_classes = sorted(set(int(c) for c in np.asarray(official.class_id)))
                with torch.no_grad():
                    out = torch_model(x.to(next(torch_model.parameters()).device))
                ref = persons(out["pred_boxes"].cpu().numpy(), out["pred_logits"].cpu().numpy(), w, h)
                row = {"frame": name, "persons_predict": official_persons, "predict_class_ids": official_classes,
                       "persons_torch": len(ref)}
                for precision, ml in packages.items():
                    spec = ml.get_spec().description
                    res = ml.predict({spec.input[0].name: x.numpy()})
                    boxes, logits = (np.asarray(res[o.name], dtype=np.float32) for o in spec.output[:2])
                    got = persons(boxes, logits, w, h)
                    matched, min_iou, max_ds = match(ref, got)
                    row[precision] = {"persons": len(got), "matched": matched, "minIoU": min_iou, "maxScoreDiff": max_ds}
                entry["frames"].append(row)
            ok16 = all(r["float16"]["persons"] == r["persons_torch"] and r["float16"]["matched"] == r["persons_torch"]
                       and (r["float16"]["minIoU"] or 1) > 0.95 for r in entry["frames"])
            chosen = "float16" if ok16 else "float32"
            entry["chosenPrecision"] = chosen
            entry["choice"] = ("fp16: every frame's persons match eager PyTorch (IoU > 0.95)" if ok16
                               else "fp32: fp16 differs from eager PyTorch on at least one frame")
            # coremltools infers the feature names (tensors / concat_2 / linear_112): name them for the app, by position.
            spec = packages[chosen].get_spec()
            for old, new in zip([spec.description.input[0].name] + [o.name for o in spec.description.output[:2]],
                                ["input", "boxes", "logits"]):
                ct.utils.rename_feature(spec, old, new)
            ml = ct.models.MLModel(spec, weights_dir=packages[chosen].weights_dir)
            ml.user_defined_metadata.update({**provenance, "precision": chosen})
            dest = os.path.join(a.models, f"rfdetr_{size}_person.mlpackage")
            if os.path.exists(dest):
                shutil.rmtree(dest)
            ml.save(dest)
            renamed = ml.predict({"input": model_input(frames[0][1], n).numpy()})
            entry["renamedCheck"] = len(persons(np.asarray(renamed["boxes"]), np.asarray(renamed["logits"]), *frames[0][1].size))
            entry["package"] = os.path.basename(dest)
            entry["packageTreeSha256"] = tree_sha256(dest)
        report["models"][size] = entry
        print(json.dumps({size: {k: entry[k] for k in ("chosenPrecision", "package")}}), flush=True)
    with open(os.path.join(a.models, "conversion-report.json"), "w") as fh:
        json.dump(report, fh, indent=1)
    print(json.dumps(report, indent=1))


if __name__ == "__main__":
    main(sys.argv[1:])
