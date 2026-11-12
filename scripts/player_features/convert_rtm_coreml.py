#!/usr/bin/env python3
"""Convert OpenMMLab RTMDet (person) and RTMPose to Core ML for the player-feasibility research (P1, Route B).

Research only (D-034, proposed): the official weights are trained on data with research terms (RTMDet person: COCO +
Objects365 v1, ImageNet-1k backbone initialisation; RTMPose: AI Challenger + COCO), so the models produced here are for
RallyLab experiments and must never be bundled in the iOS app. They live in the experiment folder, never in git.

Each network is wrapped with its own preprocessing and output decoding inside the graph, traced, and converted to an ML
program — the detector in fp16; the pose model in **fp32**, because in fp16 its SimCC maxima (the joint scores) collapse to
about 0 while the argmax positions survive (measured 2026-11-08 on the pilot's frames: fp16 scores -0.1–0.7 where PyTorch
gives 0.45–0.9; fp32 matches). fp32 runs on the CPU/GPU, not the Neural Engine — a production port would need the head
kept in fp32 (mixed precision) or retrained/calibrated, not this file:

  detector  input  image 640x640 RGB (letterboxed by the caller: scaled to fit, top-left aligned, padded with 114)
            output scores [1, 8400] (sigmoid person score per prior)
                   boxes  [1, 8400, 4] (x1, y1, x2, y2 in the 640x640 input's pixels; NMS is the caller's)
  pose      input  image 256x192 (h x w) RGB: the person box padded 1.25x, widened to 3:4, cropped and resized
            output keypoints [1, 17, 2] (x, y in the 192x256 crop's pixels; COCO-17 order)
                   scores    [1, 17] (min of the two SimCC maxima: the raw model score, not a probability)

The script then checks, on real frames:
  1. the wrapper's decoding against mmdet's / mmpose's own inference (the decoding is theirs, not a re-derivation), and
  2. the Core ML model against the PyTorch wrapper (conversion error),
and writes conversion-report.json next to the models.

Usage (in a Python 3.9/3.10 env with torch 2.1, mmcv 2.1 with ops, mmdet 3.3, mmpose 1.3, coremltools 8):
  convert_rtm_coreml.py --models <dir with *.pth and configs/> --frames <frame.jpg> [<frame.jpg> ...]
"""
import argparse
import hashlib
import json
import os
import sys
import warnings

import numpy as np
import torch

warnings.filterwarnings("ignore")

DET_CONFIG = "configs/rtmdet_m_640-8xb32_coco-person.py"
DET_CKPT = "rtmdet_m_8xb32-100e_coco-obj365-person-235e8209.pth"
POSE_CONFIG = "configs/rtmpose-m_8xb256-420e_coco-256x192.py"
POSE_CKPT = "rtmpose-m_simcc-aic-coco_pt-aic-coco_420e-256x192-63eb25f7_20230126.pth"
DET_SIZE = 640
POSE_W, POSE_H = 192, 256
PAD = 114.0
COCO17 = ["nose", "left_eye", "right_eye", "left_ear", "right_ear", "left_shoulder", "right_shoulder", "left_elbow",
          "right_elbow", "left_wrist", "right_wrist", "left_hip", "right_hip", "left_knee", "right_knee", "left_ankle",
          "right_ankle"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class DetWrapper(torch.nn.Module):
    """RTMDet with BGR normalisation in front and prior decoding behind (RTMDetSepBNHead, exp_on_reg)."""

    def __init__(self, model):
        super().__init__()
        self.model = model
        pre = model.data_preprocessor
        self.register_buffer("mean", torch.tensor(pre.mean).view(1, 3, 1, 1).float())
        self.register_buffer("std", torch.tensor(pre.std).view(1, 3, 1, 1).float())
        self.strides = [s[0] for s in model.bbox_head.prior_generator.strides]

    def forward(self, rgb):
        bgr = rgb[:, [2, 1, 0], :, :]  # the model was trained on BGR (bgr_to_rgb=False)
        x = (bgr - self.mean) / self.std
        cls_scores, bbox_preds = self.model.bbox_head(self.model.extract_feat(x))
        scores, boxes = [], []
        for cls, reg, stride in zip(cls_scores, bbox_preds, self.strides):
            _, _, h, w = cls.shape
            ys, xs = torch.meshgrid(torch.arange(h, dtype=torch.float32), torch.arange(w, dtype=torch.float32), indexing="ij")
            px, py = (xs * stride).reshape(-1), (ys * stride).reshape(-1)  # MlvlPointGenerator, offset 0
            d = reg.reshape(4, -1)  # distances left, top, right, bottom (already x stride)
            boxes.append(torch.stack([px - d[0], py - d[1], px + d[2], py + d[3]], dim=-1))
            scores.append(cls.sigmoid().reshape(-1))
        return torch.cat(scores)[None], torch.cat(boxes)[None]


class PoseWrapper(torch.nn.Module):
    """RTMPose with RGB normalisation in front and SimCC decoding (argmax / split ratio, min of maxima) behind."""

    def __init__(self, model):
        super().__init__()
        self.model = model
        pre = model.data_preprocessor
        self.register_buffer("mean", torch.tensor(pre.mean).view(1, 3, 1, 1).float())
        self.register_buffer("std", torch.tensor(pre.std).view(1, 3, 1, 1).float())
        self.split = float(model.head.decoder.simcc_split_ratio)

    def forward(self, rgb):
        x = (rgb - self.mean) / self.std
        feats = self.model.backbone(x)
        if self.model.with_neck:
            feats = self.model.neck(feats)
        sx, sy = self.model.head(feats)
        vx, ix = sx.max(dim=-1)
        vy, iy = sy.max(dim=-1)
        kp = torch.stack([ix.float(), iy.float()], dim=-1) / self.split
        return kp, torch.minimum(vx, vy)


def letterbox(img_rgb):
    """mmdet test pipeline: Resize keep_ratio to 640, Pad bottom/right to 640x640 with 114."""
    import cv2
    h, w = img_rgb.shape[:2]
    s = DET_SIZE / max(h, w)
    nw, nh = int(round(w * s)), int(round(h * s))
    out = np.full((DET_SIZE, DET_SIZE, 3), PAD, dtype=np.float32)
    out[:nh, :nw] = cv2.resize(img_rgb, (nw, nh), interpolation=cv2.INTER_LINEAR)
    return out, s


def nms(boxes, scores, thr=0.6, score_thr=0.05, top=100):
    keep = []
    idx = np.argsort(-scores)
    idx = idx[scores[idx] > score_thr][:1000]
    while idx.size and len(keep) < top:
        i = idx[0]
        keep.append(i)
        xx1 = np.maximum(boxes[i, 0], boxes[idx[1:], 0]); yy1 = np.maximum(boxes[i, 1], boxes[idx[1:], 1])
        xx2 = np.minimum(boxes[i, 2], boxes[idx[1:], 2]); yy2 = np.minimum(boxes[i, 3], boxes[idx[1:], 3])
        inter = np.clip(xx2 - xx1, 0, None) * np.clip(yy2 - yy1, 0, None)
        area = lambda b: (b[..., 2] - b[..., 0]) * (b[..., 3] - b[..., 1])
        iou = inter / (area(boxes[i]) + area(boxes[idx[1:]]) - inter + 1e-9)
        idx = idx[1:][iou <= thr]
    return np.array(keep, dtype=int)


def crop_for_pose(img_rgb, box):
    """mmpose GetBBoxCenterScale (padding 1.25) + TopdownAffine (aspect 3:4, no rotation), border 0."""
    import cv2
    x1, y1, x2, y2 = box
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    w, h = (x2 - x1) * 1.25, (y2 - y1) * 1.25
    aspect = POSE_W / POSE_H
    if w > h * aspect:
        h = w / aspect
    else:
        w = h * aspect
    src = np.float32([[cx - w / 2, cy - h / 2], [cx + w / 2, cy - h / 2], [cx - w / 2, cy + h / 2]])
    dst = np.float32([[0, 0], [POSE_W, 0], [0, POSE_H]])
    m = cv2.getAffineTransform(src, dst)
    crop = cv2.warpAffine(img_rgb, m, (POSE_W, POSE_H), flags=cv2.INTER_LINEAR, borderValue=0)
    return crop.astype(np.float32), (cx - w / 2, cy - h / 2, w / POSE_W, h / POSE_H)


def to_tensor(img):
    return torch.from_numpy(img.transpose(2, 0, 1)[None].copy())


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--frames", nargs="+", required=True)
    args = ap.parse_args(argv)
    import cv2
    import coremltools as ct
    from mmdet.apis import inference_detector, init_detector
    from mmengine.registry import DefaultScope
    from mmpose.apis import inference_topdown, init_model
    from PIL import Image

    d = args.models
    det = init_detector(os.path.join(d, DET_CONFIG), os.path.join(d, DET_CKPT), device="cpu").eval()
    pose = init_model(os.path.join(d, POSE_CONFIG), os.path.join(d, POSE_CKPT), device="cpu").eval()
    dw, pw = DetWrapper(det).eval(), PoseWrapper(pose).eval()

    with torch.no_grad():
        tdet = torch.jit.trace(dw, torch.rand(1, 3, DET_SIZE, DET_SIZE) * 255)
        tpose = torch.jit.trace(pw, torch.rand(1, 3, POSE_H, POSE_W) * 255)
    provenance = {
        "researchOnly": "true",
        "licence": "code Apache-2.0 (OpenMMLab); weights carry their training data's terms: research use only, never in the iOS app",
    }
    det_ml = ct.convert(tdet, inputs=[ct.ImageType(name="image", shape=(1, 3, DET_SIZE, DET_SIZE), color_layout=ct.colorlayout.RGB)],
                        outputs=[ct.TensorType(name="scores"), ct.TensorType(name="boxes")],
                        convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
    det_ml.short_description = "RTMDet-m person (OpenMMLab), research only — COCO + Objects365 v1 training, ImageNet-1k backbone init"
    det_ml.user_defined_metadata.update({**provenance, "checkpoint": DET_CKPT, "checkpointSha256": sha256(os.path.join(d, DET_CKPT)),
                                         "trainingData": "COCO train2017 + Objects365 v1 (person); backbone CSPNeXt-m ImageNet-1k (RSB-A1)"})
    pose_ml = ct.convert(tpose, inputs=[ct.ImageType(name="image", shape=(1, 3, POSE_H, POSE_W), color_layout=ct.colorlayout.RGB)],
                         outputs=[ct.TensorType(name="keypoints"), ct.TensorType(name="scores")],
                         convert_to="mlprogram", compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.macOS14)
    pose_ml.short_description = "RTMPose-m COCO-17 (OpenMMLab), research only — AI Challenger + COCO training"
    pose_ml.user_defined_metadata.update({**provenance, "checkpoint": POSE_CKPT, "checkpointSha256": sha256(os.path.join(d, POSE_CKPT)),
                                          "trainingData": "AI Challenger + COCO person keypoints", "keypoints": ",".join(COCO17)})
    det_path, pose_path = os.path.join(d, "rtmdet_m_person.mlpackage"), os.path.join(d, "rtmpose_m_coco17.mlpackage")
    det_ml.save(det_path)
    pose_ml.save(pose_path)

    report = {"detector": {"package": os.path.basename(det_path), "checkpointSha256": det_ml.user_defined_metadata["checkpointSha256"], "precision": "fp16"},
              "pose": {"package": os.path.basename(pose_path), "checkpointSha256": pose_ml.user_defined_metadata["checkpointSha256"], "precision": "fp32"},
              "frames": []}
    for path in args.frames:
        bgr = cv2.imread(path)
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB).astype(np.float32)
        lb, s = letterbox(rgb)
        with torch.no_grad():
            pt_scores, pt_boxes = [t[0].numpy() for t in dw(to_tensor(lb))]
        ml = det_ml.predict({"image": Image.fromarray(lb.astype(np.uint8))})
        ml_scores, ml_boxes = ml["scores"][0], ml["boxes"][0]
        keep = nms(pt_boxes, pt_scores)
        keep_ml = nms(ml_boxes, ml_scores)
        # mmdet's own inference on the same letterboxed image (it resizes nothing further: 640x640 in, keep-ratio no-op).
        with DefaultScope.overwrite_default_scope("mmdet"):  # loading mmpose switched the registry scope
            ref = inference_detector(det, cv2.cvtColor(lb.astype(np.uint8), cv2.COLOR_RGB2BGR)).pred_instances
        ref_boxes, ref_scores = ref.bboxes.numpy(), ref.scores.numpy()
        ref_keep = ref_scores > 0.3
        mine = keep[pt_scores[keep] > 0.3]
        match = []
        for b in ref_boxes[ref_keep]:
            ious = [iou(b, pt_boxes[k]) for k in mine]
            match.append(max(ious) if ious else 0.0)
        frame = {"frame": os.path.basename(path), "persons_mmdet_gt0.3": int(ref_keep.sum()), "persons_wrapper_gt0.3": int(len(mine)),
                 "wrapper_vs_mmdet_min_iou": float(min(match)) if match else None,
                 "coreml_vs_torch_score_maxabs_kept": float(np.max(np.abs(ml_scores[mine] - pt_scores[mine]))) if len(mine) else None,
                 "coreml_vs_torch_box_maxabs_px_top": float(np.max(np.abs(ml_boxes[keep[:20]] - pt_boxes[keep[:20]]))) if len(keep) else None,
                 "persons_coreml_gt0.3": int((ml_scores[keep_ml] > 0.3).sum())}
        # Pose on the highest-scoring person, against mmpose's inference_topdown on the same box.
        if len(mine):
            box = pt_boxes[mine[0]] / s  # back to the frame
            crop, (ox, oy, sx, sy) = crop_for_pose(rgb, box)
            with torch.no_grad():
                kp, sc = [t[0].numpy() for t in pw(to_tensor(crop))]
            mlp = pose_ml.predict({"image": Image.fromarray(crop.astype(np.uint8))})
            kp_frame = np.stack([ox + kp[:, 0] * sx, oy + kp[:, 1] * sy], -1)
            with DefaultScope.overwrite_default_scope("mmpose"):
                ref_pose = inference_topdown(pose, cv2.cvtColor(rgb.astype(np.uint8), cv2.COLOR_RGB2BGR), bboxes=box[None], bbox_format="xyxy")[0]
            ref_kp = ref_pose.pred_instances.keypoints[0]
            frame.update({"pose_wrapper_vs_mmpose_maxabs_px": float(np.max(np.abs(kp_frame - ref_kp))),
                          "pose_coreml_vs_torch_maxabs_px_crop": float(np.max(np.abs(mlp["keypoints"][0] - kp))),
                          "pose_coreml_vs_torch_score_maxabs": float(np.max(np.abs(mlp["scores"][0] - sc))),
                          "pose_scores_range": [float(sc.min()), float(sc.max())]})
        report["frames"].append(frame)
        print(json.dumps(frame))
    with open(os.path.join(d, "conversion-report.json"), "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    return 0


def iou(a, b):
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0])); iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / ua if ua > 0 else 0.0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
