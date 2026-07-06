#!/usr/bin/env python3
"""Train and evaluate a trajectory-state (rally / no-rally) classifier from
RallyLab training-data exports, and compare it against the rule-based decider.

Input: one or more <video>.trainingdata.json files produced by RallyLab
(Export Training Data button, or `RallyLab --export-training-data <dir>`).
Each export carries raw per-frame pipeline evidence, hand-labeled rally
intervals, and the rule pipeline's raw decided intervals (the baseline).

Pipeline:
  1. Causal windowed features per processed frame (nothing from the future,
     so the model transfers to on-device streaming inference).
  2. Logistic regression (numpy gradient descent, class-balanced, L2).
  3. Out-of-fold probabilities via time-blocked cross-validation — every
     frame is predicted by a model that never saw its time block.
  4. Hysteresis decode of the probability track into intervals, mirroring
     production post-processing (gap merge + min length).
  5. Interval scoring with a port of RallySegmentationScorer (greedy IoU
     matching), reported side by side with the baseline.

Output: report to stdout + fitted weights (feature names, standardization,
coefficients) to scripts/rally_classifier_weights.json for a Swift port.

Usage:
  python3 scripts/train_rally_classifier.py [export.json ...]
  (defaults to ~/Movies/RallyLab/*.trainingdata.json)
"""

import glob
import json
import math
import os
import sys

import numpy as np

# Production post-processing constants (ProcessorConfig / RallyDecider defaults)
MIN_GAP_TO_MERGE = 1.3513
MIN_SEGMENT_LENGTH = 2.6131
MIN_RALLY_SEC = 1.1653

# Training-time exclusion around labeled boundaries (ambiguous frames)
BOUNDARY_MARGIN_SEC = 0.5

# Causal feature window
WINDOW_SEC = 1.0

# Hysteresis defaults (evaluated as-is; a small grid is also reported)
HYST_DEFAULT = dict(enter=0.7, exit=0.3, enter_sustain=0.2, exit_sustain=0.8)

MOVE_CATEGORIES = ["airborne", "carried", "rolling", "unknown"]


# ---------------------------------------------------------------- features

def build_features(export):
    """Per-frame causal feature matrix for one video export.

    Returns (X, feature_names, times, y_frame) where y_frame is the
    ground-truth in-rally indicator per frame.
    """
    frames = export["frames"]
    n = len(frames)
    t = np.array([f["t"] for f in frames])
    ball = np.array([f["ball"] for f in frames], dtype=float)
    proj = np.array([f["proj"] for f in frames], dtype=float)
    r2 = np.array([f.get("r2") if f.get("r2") is not None else np.nan for f in frames], dtype=float)
    grav = np.array([f.get("grav") if f.get("grav") is not None else np.nan for f in frames], dtype=float)
    x_pos = np.array([f.get("x") if f.get("x") is not None else np.nan for f in frames], dtype=float)
    y_pos = np.array([f.get("y") if f.get("y") is not None else np.nan for f in frames], dtype=float)
    size = np.array([f.get("size") if f.get("size") is not None else np.nan for f in frames], dtype=float)
    court_dets = np.array([f["courtDets"] for f in frames], dtype=float)
    conf = np.array([f.get("conf") if f.get("conf") is not None else 0.0 for f in frames], dtype=float)
    cands = np.array([f["cands"] for f in frames], dtype=float)
    move = [f.get("move") for f in frames]

    net_top = export.get("netTopY")
    net_top_v = net_top if net_top is not None else np.nan

    feats = {}
    feats["ball"] = ball
    feats["proj"] = proj
    feats["has_track"] = (~np.isnan(y_pos)).astype(float)
    feats["r2"] = np.nan_to_num(r2)
    feats["has_r2"] = (~np.isnan(r2)).astype(float)
    feats["grav"] = np.nan_to_num(grav)
    feats["ball_y"] = np.nan_to_num(y_pos)
    feats["ball_size"] = np.nan_to_num(size)
    feats["court_dets"] = court_dets
    feats["conf"] = conf
    feats["cands"] = cands
    if not math.isnan(net_top_v):
        feats["y_above_net"] = np.nan_to_num(y_pos - net_top_v)
        feats["above_net"] = np.nan_to_num((y_pos > net_top_v).astype(float))
    else:
        feats["y_above_net"] = np.zeros(n)
        feats["above_net"] = np.zeros(n)
    for cat in MOVE_CATEGORIES:
        feats[f"move_{cat}"] = np.array([1.0 if m == cat else 0.0 for m in move])

    # --- causal trailing-window features (time-based; frames are unevenly
    # spaced because of the dynamic detection stride)
    win_ball = np.zeros(n)
    win_proj = np.zeros(n)
    win_r2 = np.zeros(n)
    win_grav = np.zeros(n)
    vy = np.zeros(n)
    vx = np.zeros(n)
    win_max_y = np.zeros(n)
    t_since_proj = np.zeros(n)
    t_since_ball = np.zeros(n)

    start = 0
    last_proj_t = -1e9
    last_ball_t = -1e9
    # index of the oldest in-window frame with a track point, per step
    for i in range(n):
        while t[start] < t[i] - WINDOW_SEC:
            start += 1
        sl = slice(start, i + 1)
        win_ball[i] = ball[sl].mean()
        win_proj[i] = proj[sl].mean()
        r2w = r2[sl]
        win_r2[i] = np.nan_to_num(np.nanmean(r2w)) if not np.all(np.isnan(r2w)) else 0.0
        gw = grav[sl]
        win_grav[i] = np.nan_to_num(np.nanmean(gw)) if not np.all(np.isnan(gw)) else 0.0
        yw = y_pos[sl]
        win_max_y[i] = np.nan_to_num(np.nanmax(yw)) if not np.all(np.isnan(yw)) else 0.0

        # velocity from oldest→newest track point in the window
        if not np.isnan(y_pos[i]):
            idxs = np.where(~np.isnan(y_pos[sl.start:i]))[0]
            if len(idxs) > 0:
                j = sl.start + idxs[0]
                dt = t[i] - t[j]
                if dt > 1e-3:
                    vy[i] = (y_pos[i] - y_pos[j]) / dt
                    vx[i] = (x_pos[i] - x_pos[j]) / dt

        if proj[i] > 0:
            last_proj_t = t[i]
        if ball[i] > 0:
            last_ball_t = t[i]
        t_since_proj[i] = min(3.0, t[i] - last_proj_t)
        t_since_ball[i] = min(3.0, t[i] - last_ball_t)

    feats["win_ball_frac"] = win_ball
    feats["win_proj_frac"] = win_proj
    feats["win_r2"] = win_r2
    feats["win_grav"] = win_grav
    feats["win_max_y"] = win_max_y
    feats["vy"] = vy
    feats["vx"] = vx
    feats["speed"] = np.hypot(vx, vy)
    feats["t_since_proj"] = t_since_proj
    feats["t_since_ball"] = t_since_ball

    names = sorted(feats.keys())
    X = np.column_stack([feats[k] for k in names])

    labels = [(l["start"], l["end"]) for l in export["labels"]]
    y = np.zeros(n)
    for (s, e) in labels:
        y[(t >= s) & (t <= e)] = 1.0

    return X, names, t, y


def boundary_mask(times, labels, margin=BOUNDARY_MARGIN_SEC):
    """True for frames safely away from every labeled boundary (trainable)."""
    keep = np.ones(len(times), dtype=bool)
    for (s, e) in labels:
        keep &= ~((np.abs(times - s) < margin) | (np.abs(times - e) < margin))
    return keep


# ---------------------------------------------------------- logistic model

def train_logistic(X, y, l2=1e-3, iters=3000, lr=0.5):
    """Class-balanced logistic regression via full-batch gradient descent.

    X must already be standardized. Returns (w, b).
    """
    n, d = X.shape
    pos = max(1.0, y.sum())
    neg = max(1.0, (1 - y).sum())
    # inverse-frequency class weights, normalized to mean 1
    wts = np.where(y > 0.5, n / (2 * pos), n / (2 * neg))

    w = np.zeros(d)
    b = 0.0
    for _ in range(iters):
        z = X @ w + b
        p = 1.0 / (1.0 + np.exp(-np.clip(z, -30, 30)))
        g = (p - y) * wts
        gw = X.T @ g / n + l2 * w
        gb = g.mean()
        w -= lr * gw
        b -= lr * gb
    return w, b


def predict(X, w, b):
    z = X @ w + b
    return 1.0 / (1.0 + np.exp(-np.clip(z, -30, 30)))


# ------------------------------------------------------- interval decoding

def hysteresis_decode(times, probs, enter, exit_, enter_sustain, exit_sustain):
    """Causal hysteresis over an unevenly-sampled probability track."""
    intervals = []
    active = False
    above_since = None
    below_since = None
    seg_start = None
    for t, p in zip(times, probs):
        if not active:
            if p >= enter:
                if above_since is None:
                    above_since = t
                if t - above_since >= enter_sustain:
                    active = True
                    seg_start = above_since
                    below_since = None
            else:
                above_since = None
        else:
            if p <= exit_:
                if below_since is None:
                    below_since = t
                if t - below_since >= exit_sustain:
                    intervals.append((seg_start, below_since))
                    active = False
                    above_since = None
                    below_since = None
            else:
                below_since = None
    if active and seg_start is not None:
        intervals.append((seg_start, times[-1]))

    # production post-processing: merge small gaps, drop short segments
    merged = []
    for (s, e) in intervals:
        if merged and s - merged[-1][1] <= MIN_GAP_TO_MERGE:
            merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else:
            merged.append((s, e))
    return [(s, e) for (s, e) in merged
            if e - s >= max(MIN_SEGMENT_LENGTH, MIN_RALLY_SEC)]


# ---------------------------------------------------------------- scoring

def iou(a, b):
    inter = max(0.0, min(a[1], b[1]) - max(a[0], b[0]))
    union = (a[1] - a[0]) + (b[1] - b[0]) - inter
    return inter / union if union > 0 else 0.0


def score_intervals(pred, truth, iou_threshold=0.5, boundary_tol=1.0):
    """Port of RallySegmentationScorer.score (greedy IoU matching)."""
    pairs = sorted(
        ((i, j, iou(p, g)) for i, p in enumerate(pred) for j, g in enumerate(truth)
         if iou(p, g) >= iou_threshold),
        key=lambda x: -x[2])
    used_p, used_t, matches = set(), set(), []
    for (i, j, v) in pairs:
        if i in used_p or j in used_t:
            continue
        used_p.add(i)
        used_t.add(j)
        matches.append((pred[i], truth[j], v))
    tp = len(matches)
    fp = len(pred) - tp
    fn = len(truth) - tp
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    start_errs = [abs(p[0] - g[0]) for (p, g, _) in matches]
    end_errs = [abs(p[1] - g[1]) for (p, g, _) in matches]
    return dict(
        tp=tp, fp=fp, fn=fn, precision=precision, recall=recall, f1=f1,
        start_mae=float(np.mean(start_errs)) if start_errs else 0.0,
        end_mae=float(np.mean(end_errs)) if end_errs else 0.0,
        start_within=float(np.mean([e <= boundary_tol for e in start_errs])) if start_errs else 0.0,
        end_within=float(np.mean([e <= boundary_tol for e in end_errs])) if end_errs else 0.0,
        matches=matches,
    )


def frame_auc(y, p):
    """Rank-based AUC (Mann–Whitney)."""
    pos = p[y > 0.5]
    neg = p[y <= 0.5]
    if len(pos) == 0 or len(neg) == 0:
        return float("nan")
    order = np.argsort(np.concatenate([pos, neg]), kind="mergesort")
    ranks = np.empty(len(order))
    ranks[order] = np.arange(1, len(order) + 1)
    return (ranks[: len(pos)].sum() - len(pos) * (len(pos) + 1) / 2) / (len(pos) * len(neg))


# ------------------------------------------------------------------- main

def out_of_fold_probs(X, y, times, labels, n_folds=6):
    """Time-blocked CV: every frame's probability comes from a model that
    never saw that frame's time block. Returns stitched probabilities."""
    n = len(y)
    edges = np.linspace(times[0], times[-1] + 1e-9, n_folds + 1)
    probs = np.zeros(n)
    trainable = boundary_mask(times, labels)
    for k in range(n_folds):
        in_fold = (times >= edges[k]) & (times < edges[k + 1])
        train = ~in_fold & trainable
        if train.sum() == 0 or y[train].sum() == 0:
            continue
        mu = X[train].mean(axis=0)
        sd = X[train].std(axis=0)
        sd[sd < 1e-9] = 1.0
        w, b = train_logistic((X[train] - mu) / sd, y[train])
        probs[in_fold] = predict((X[in_fold] - mu) / sd, w, b)
    return probs


def fmt(s):
    return (f"P {s['precision']:.3f}  R {s['recall']:.3f}  F1 {s['f1']:.3f}  "
            f"(TP {s['tp']} FP {s['fp']} FN {s['fn']})  "
            f"startMAE {s['start_mae']:.2f}s endMAE {s['end_mae']:.2f}s")


def main():
    paths = sys.argv[1:] or sorted(
        glob.glob(os.path.expanduser("~/Movies/RallyLab/*.trainingdata.json")))
    if not paths:
        print("No .trainingdata.json exports found. Run RallyLab --export-training-data first.")
        sys.exit(1)

    exports = []
    for p in paths:
        with open(p) as f:
            exports.append((p, json.load(f)))

    print(f"Loaded {len(exports)} export(s)\n")

    all_learned, all_baseline, all_truth = [], [], []
    weights_out = None

    for path, ex in exports:
        X, names, times, y = build_features(ex)
        labels = [(l["start"], l["end"]) for l in ex["labels"]]
        baseline = [(b["start"], b["end"]) for b in ex["baselineRaw"]]

        print(f"=== {ex['video']} ===")
        print(f"frames {len(times)}  duration {ex['duration']:.1f}s  "
              f"labels {len(labels)}  in-rally frames {int(y.sum())} ({y.mean() * 100:.1f}%)")

        probs = out_of_fold_probs(X, y, times, labels)
        auc = frame_auc(y, probs)
        acc = float(((probs > 0.5) == (y > 0.5)).mean())
        print(f"frame-level (out-of-fold): AUC {auc:.4f}  acc@0.5 {acc:.3f}")

        h = HYST_DEFAULT
        learned = hysteresis_decode(times, probs, h["enter"], h["exit"],
                                    h["enter_sustain"], h["exit_sustain"])
        s_learned = score_intervals(learned, labels)
        s_baseline = score_intervals(baseline, labels)
        print(f"baseline (rule decider) : {fmt(s_baseline)}")
        print(f"learned  (default hyst) : {fmt(s_learned)}")

        # small grid, reported for context (tuned on the same video → optimistic)
        best = None
        for enter in (0.6, 0.7, 0.8):
            for exit_ in (0.2, 0.3, 0.4):
                for ex_sus in (0.5, 0.8, 1.2):
                    cand = hysteresis_decode(times, probs, enter, exit_, 0.2, ex_sus)
                    sc = score_intervals(cand, labels)
                    key = (sc["f1"], -(sc["start_mae"] + sc["end_mae"]))
                    if best is None or key > best[0]:
                        best = (key, (enter, exit_, ex_sus), sc)
        (_, hp, s_grid) = best
        print(f"learned  (grid best, in-sample: enter={hp[0]} exit={hp[1]} exitSustain={hp[2]}s) : {fmt(s_grid)}")

        for (p, g, v) in s_learned["matches"]:
            print(f"   match IoU {v:.2f}: pred {p[0]:7.2f}–{p[1]:7.2f}  truth {g[0]:7.2f}–{g[1]:7.2f}")
        for (s, e) in labels:
            if not any(g == (s, e) for (_, g, _) in s_learned["matches"]):
                print(f"   MISSED rally {s:.2f}–{e:.2f}")
        print()

        all_learned.append((learned, labels))
        all_baseline.append((baseline, labels))
        all_truth.extend(labels)

        # final weights on ALL frames of all data (for the Swift port)
        trainable = boundary_mask(times, labels)
        mu = X[trainable].mean(axis=0)
        sd = X[trainable].std(axis=0)
        sd[sd < 1e-9] = 1.0
        w, b = train_logistic((X[trainable] - mu) / sd, y[trainable])
        weights_out = dict(
            schema=1, features=names, mean=mu.tolist(), std=sd.tolist(),
            weights=w.tolist(), bias=float(b),
            hysteresis=HYST_DEFAULT,
            trainedOn=[e[1]["video"] for e in exports],
        )
        contrib = sorted(zip(names, w), key=lambda kv: -abs(kv[1]))
        print("top feature weights (standardized):")
        for name, wv in contrib[:8]:
            print(f"   {name:>16s}  {wv:+.3f}")
        print()

    if len(exports) > 1:
        pooled_l = score_intervals(
            [i for (p, g) in all_learned for i in p],
            [i for (p, g) in all_learned for i in g])
        pooled_b = score_intervals(
            [i for (p, g) in all_baseline for i in p],
            [i for (p, g) in all_baseline for i in g])
        print("=== corpus (pooled) ===")
        print(f"baseline: {fmt(pooled_b)}")
        print(f"learned : {fmt(pooled_l)}")

    if weights_out:
        out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "rally_classifier_weights.json")
        with open(out, "w") as f:
            json.dump(weights_out, f, indent=2)
        print(f"weights written → {out}")


if __name__ == "__main__":
    main()
