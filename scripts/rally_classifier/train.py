#!/usr/bin/env python3
"""Train and evaluate a learned rally-activity candidate on the grouped development folds
(preregistration EXP-20261103, with the owner's 2026-11-12 requirements).

    python3 scripts/rally_classifier/train.py <dataset> --folds-file <folds.json> --withheld <closure.json> \\
        --candidate {r1,r2} --net {present,ablated} --seed 20261103 --out <run> [--dry-run] [--r1-run <run>]

Before anything is fitted, in this order, each one a refusal: the dataset validates with the external withheld
closure (no closure file, no run); the baseline's `r0` is the committed settings the preregistration names (and
`r0_prime`, when stored, the D-029 ones); the folds file was drawn for exactly this dataset and is what its
seed draws; the SegmentBuilder port rebuilds every stored clip from its pre-merge raw spans.

`--dry-run` stops there: it extracts the features, counts what every fit of the nested protocol would be given
and writes `readiness.{json,md}`. It fits nothing — no standardisation, no model, no temperature — and scores
nothing, the stored baseline included.

The nested protocol (§5), for each outer fold k of the K in the folds file:
- the nested fold is fold (k + 1) mod K; the inner folds are the other K − 2;
- **model choice**, on models fitted to the inner folds — R1: the penalty in {1e-4, 1e-3, 1e-2} with the lowest
  nested-fold loss (the fitting loss's data term, with the inner folds' class weights; a tie goes to the larger
  penalty); R2: the epoch, of at most 40, with the lowest nested-fold loss;
- **calibration**: one temperature, fitted to that inner model's logits on the nested fold's steps with w = 1;
- **decode point**: over the 108-point grid in its order, on the nested fold's recordings (restricted ones
  included), the D-007 objective — lowest pooled dead-time retention among the points whose pooled complete
  rallies are at least R0's on those recordings; ties to fewer false clips, then to the earlier point. When no
  point reaches R0's recall the point with the most complete rallies is taken (same tie-breaks) and the fold is
  reported with `constraintMet: false`;
- the model is refitted on the K − 1 training folds with the chosen penalty / number of epochs, and fold k's
  recordings are predicted, calibrated with that temperature, decoded at that point and scored.
Fold k's recordings are never read by any of those steps.

R1 is L2-regularised logistic regression over `derived_v1`: class-balanced (each class half the total weight),
standardised with the mean and standard deviation of the training steps with w = 1, the intercept not
penalised, objective Σ cᵢ·BCEᵢ + ½·penalty·‖β‖² with Σ cᵢ = 1. It is fitted on the full batch by Newton steps
with a backtracking line search to a gradient under 1e-10 — the objective is strictly convex, so this is the
one minimiser gradient descent would reach, without a step size or an iteration count to choose. R2 is `tcn.py`.

Labels: a step counts in a loss, a standardisation, a class weight or a temperature only with w = 1
(ACTIVE_RALLY is the positive; NON_RALLY and NON_RALLY_ACTIVITY the negatives). TRANSITION, UNKNOWN and EXCLUDED
steps contribute nothing.

A run folder holds, per fold, `weights.*`, `calibration.json` and `decode.json`; the out-of-fold predictions
`oof.jsonl`; `scorecards/<variant>/<recording>.evaluation_v2.json` for the candidate and each stored baseline
variant; and `report.{json,md}`.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import json
import os
import platform
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decode  # noqa: E402
import evaluate  # noqa: E402
import features as ft  # noqa: E402
import folds as fd  # noqa: E402
import validate_dataset as v  # noqa: E402

PENALTIES = (1e-4, 1e-3, 1e-2)
COMMITTED = {"prerollSec": 2.0, "postrollSec": 0.5, "joinSec": 1.3513, "minSegmentSec": 2.6131, "servePrimedStart": True}
D029 = {"prerollSec": 2.0, "postrollSec": 1.0, "joinSec": 0.0, "minSegmentSec": 1.5}
DEFAULT_SEED = 20261103
UNCERTAIN_BAND, UNCERTAIN_RUN_SEC, UNCERTAIN_LIMIT = (0.3, 0.7), 2.0, 0.2
UNPRIMED_SEC = 3.0
TEMPERATURE_RANGE = (0.01, 100.0)
RELIABILITY_BINS = 10
POSITIVE = v.STATES["ACTIVE_RALLY"]
CAVEATS = [
    "Development evidence only: every recording is in the detectors' training packages and most carry decider-selection exposure.",
    "r0_prime is the D-029 reference: its settings were selected on these recordings; it is never the benchmark.",
    "The stored baseline clips passed the pipeline's above-net rule after SegmentBuilder; the learned candidate's clips go through "
    "the SegmentBuilder port only (rcf_v1 does not hold what that rule reads), so a clip the rule would drop stays in the candidate's export.",
    "R2 reads the 30 Hz grid view and misses the earlier of two steps that share a cell; R1 sees every step.",
]


class Refused(Exception):
    """The run may not start (or go on). The message is for a person."""


@dataclasses.dataclass
class Recording:
    rec: dict            # the manifest's record
    fold: int
    arr: dict            # features.arrays (net-ablated when the run is)
    baseline: dict       # {variant: [clip]}
    segs: list           # [(start, stop)] of the segments
    cache: dict = dataclasses.field(default_factory=dict)

    @property
    def rid(self) -> str:
        return self.rec["recordingId"]

    @property
    def target(self) -> np.ndarray:
        return (self.arr["y"] == POSITIVE).astype(np.float64)


@dataclasses.dataclass
class Prepared:
    dataset_dir: str
    manifest: dict
    identity: dict
    folds_doc: dict
    folds_sha256: str
    validation: dict
    parity: dict
    recordings: list
    net: str

    @property
    def folds(self) -> int:
        return self.folds_doc["folds"]

    @property
    def sampling_hz(self):
        return self.manifest["samplingHzNominal"]

    def of(self, wanted) -> list:
        return [r for r in self.recordings if wanted(r.fold)]


def prepare(dataset_dir: str, folds_file: str, withheld: str | None, net: str) -> Prepared:
    """Every check that precedes a fit, then the recordings in memory. Raises Refused."""
    if not withheld:
        raise Refused("no withheld-closure file: the dataset is validated against the external closure before it is read")
    report = v.validate(dataset_dir, withheld)
    if not report.ok:
        raise Refused(f"the dataset does not validate ({len(report.errors)} error(s)): " + "; ".join(report.errors[:5]))
    manifest = v.load_manifest(dataset_dir)
    variants = {var["name"]: var["settings"] for var in manifest["baseline"]["variants"]}
    for name, named in (("r0", COMMITTED), ("r0_prime", D029)):
        if name in variants and {k: variants[name][k] for k in named} != named:
            raise Refused(f"the dataset's baseline {name} was replayed at {variants[name]}, not at the settings the preregistration names ({named})")
    try:
        folds_doc = fd.load(folds_file, dataset_dir)
    except fd.FoldsError as e:
        raise Refused(str(e))
    if folds_doc["folds"] < fd.MIN_FOLDS:
        raise Refused(f"the folds file holds {folds_doc['folds']} folds: the nested protocol needs at least {fd.MIN_FOLDS} "
                      "(one held out, one to choose on, the rest to train on)")
    try:
        parity = decode.parity(dataset_dir, manifest)
    except decode.ParityError as e:
        raise Refused(str(e))
    recordings = []
    for rec in manifest["recordings"]:
        arr = ft.arrays(v.read_steps(dataset_dir, rec), ablate_net=(net == "ablated"))
        recordings.append(Recording(rec, folds_doc["recordings"][rec["recordingId"]], arr, v.read_baseline(dataset_dir, rec), ft.segments(arr["seg"])))
    return Prepared(dataset_dir, manifest, v.dataset_identity(dataset_dir), folds_doc, v.sha256_file(folds_file),
                    {"errors": 0, "warnings": report.warnings, "info": report.info, "withheldFileSha256": v.sha256_file(withheld)},
                    parity, recordings, net)


# ----------------------------------------------------------------------------- R1: logistic regression

def standardise(X: np.ndarray, w: np.ndarray) -> tuple:
    """Mean and standard deviation per column over the steps with w = 1 (a constant column gets 1)."""
    rows = X[w > 0]
    std = rows.std(axis=0)
    return rows.mean(axis=0), np.where(std > 0, std, 1.0)


def balanced_weights(target: np.ndarray, w: np.ndarray) -> np.ndarray:
    """Per-step loss weights that sum to 1 with half on each class; 0 for every step with w = 0."""
    pos, neg = (w > 0) & (target == 1), (w > 0) & (target == 0)
    if not pos.any() or not neg.any():
        raise Refused(f"a fit needs both classes among its weighted steps (has {int(pos.sum())} ACTIVE_RALLY and {int(neg.sum())} negative): need data")
    return np.where(pos, 0.5 / pos.sum(), 0.0) + np.where(neg, 0.5 / neg.sum(), 0.0)


def sigmoid(z: np.ndarray) -> np.ndarray:
    return 0.5 * (1.0 + np.tanh(0.5 * z))


def objective(theta: np.ndarray, Z: np.ndarray, target: np.ndarray, c: np.ndarray, penalty: float) -> tuple:
    """Σ cᵢ·BCE(targetᵢ, σ(Zᵢ·β + b)) + ½·penalty·‖β‖² and its gradient; theta = (β, b)."""
    z = Z @ theta[:-1] + theta[-1]
    residual = c * (sigmoid(z) - target)
    loss = float(np.sum(c * (np.logaddexp(0.0, z) - target * z)) + 0.5 * penalty * theta[:-1] @ theta[:-1])
    return loss, np.concatenate((Z.T @ residual + penalty * theta[:-1], [residual.sum()]))


def fit_logistic(X: np.ndarray, target: np.ndarray, w: np.ndarray, penalty: float) -> dict:
    c_all = balanced_weights(target, w)
    keep = w > 0
    mean, std = standardise(X, w)
    Z, t, c = (X[keep] - mean) / std, target[keep], c_all[keep]
    theta = np.zeros(Z.shape[1] + 1)
    A = np.column_stack((Z, np.ones(len(Z))))
    ridge = np.diag(np.concatenate((np.full(Z.shape[1], penalty), [0.0])))
    loss, grad = objective(theta, Z, t, c, penalty)
    for _ in range(200):
        if np.max(np.abs(grad)) < 1e-10:
            break
        p = sigmoid(A @ theta)
        step = np.linalg.solve((A * (c * p * (1.0 - p))[:, None]).T @ A + ridge, grad)
        scale = 1.0
        while scale > 1e-10:
            trial_loss, trial_grad = objective(theta - scale * step, Z, t, c, penalty)
            if trial_loss <= loss - 1e-4 * scale * (grad @ step):
                break
            scale /= 2
        else:
            break                       # no descent left at this precision
        theta, loss, grad = theta - scale * step, trial_loss, trial_grad
    return {"mean": mean, "std": std, "coefficients": theta[:-1], "intercept": float(theta[-1]), "penalty": penalty,
            "positiveWeight": float(c[t == 1][0] * len(c)), "negativeWeight": float(c[t == 0][0] * len(c)), "gradientMax": float(np.max(np.abs(grad)))}


def logistic_logits(model: dict, X: np.ndarray) -> np.ndarray:
    return ((X - model["mean"]) / model["std"]) @ model["coefficients"] + model["intercept"]


def logistic_loss(model: dict, X: np.ndarray, target: np.ndarray, w: np.ndarray) -> float:
    """The fitting loss's data term on other steps, with the model's own class weights."""
    keep = w > 0
    if not keep.any():
        raise Refused("the nested fold has no step with loss weight: a penalty cannot be chosen on it")
    z, t = logistic_logits(model, X[keep]), target[keep]
    c = np.where(t == 1, model["positiveWeight"], model["negativeWeight"])
    return float(np.sum(c * (np.logaddexp(0.0, z) - t * z)) / np.sum(c))


class R1:
    name, lookahead_sec = "r1", ft.R1_LOOKAHEAD_SEC

    def __init__(self, prep: Prepared, seed: int, r2_epochs: int | None = None):
        self.hz = prep.sampling_hz

    def inputs(self, r: Recording) -> np.ndarray:
        if "r1" not in r.cache:
            r.cache["r1"] = ft.derived(r.arr, self.hz, self.lookahead_sec)
        return r.cache["r1"]

    def stack(self, recs: list) -> tuple:
        return (np.vstack([self.inputs(r) for r in recs]), np.concatenate([r.target for r in recs]), np.concatenate([r.arr["w"] for r in recs]))

    def select(self, inner: list, held: list) -> tuple:
        X, t, w = self.stack(inner)
        Xh, th, wh = self.stack(held)
        best, losses = None, {}
        for penalty in sorted(PENALTIES, reverse=True):                 # a tie goes to the larger penalty
            model = fit_logistic(X, t, w, penalty)
            losses[str(penalty)] = logistic_loss(model, Xh, th, wh)
            if best is None or losses[str(penalty)] < losses[str(best["penalty"])]:
                best = model
        return {"penalty": best["penalty"], "nestedLoss": losses}, {r.rid: self.logits(best, r) for r in held}

    def refit(self, train: list, choice: dict) -> dict:
        return fit_logistic(*self.stack(train), choice["penalty"])

    def logits(self, model: dict, r: Recording) -> np.ndarray:
        return logistic_logits(model, self.inputs(r))

    def describe(self, choice: dict) -> str:
        return f"penalty {choice['penalty']}"

    def shapes(self, recs: list) -> dict:
        return {"features": len(ft.R1_NAMES), "steps": sum(self.inputs(r).shape[0] for r in recs)}

    def save(self, model: dict, folder: str, choice: dict):
        _write_json(os.path.join(folder, "weights.json"), {
            "candidate": "r1", "featureSchema": v.FEATURE_VERSION, "derived": ft.DERIVED_VERSION, "lookaheadSec": self.lookahead_sec,
            "features": ft.R1_NAMES, "mean": model["mean"].tolist(), "std": model["std"].tolist(),
            "coefficients": model["coefficients"].tolist(), "intercept": model["intercept"], "penalty": model["penalty"],
            "classWeights": {"positive": model["positiveWeight"], "negative": model["negativeWeight"]},
            "gradientMax": model["gradientMax"], "choice": choice})


class R2:
    name = "r2"

    def __init__(self, prep: Prepared, seed: int, r2_epochs: int | None = None):
        import tcn                                          # torch is needed for R2 only
        self.tcn, self.hz, self.seed = tcn, prep.sampling_hz, seed
        self.max_epochs = tcn.MAX_EPOCHS if r2_epochs is None else r2_epochs
        self.lookahead_sec = tcn.LOOKAHEAD_SEC

    def inputs(self, r: Recording) -> list:
        if "r2" not in r.cache:
            r.cache["r2"] = ft.grid(r.arr, self.hz)
        return r.cache["r2"]

    def windows(self, recs: list) -> dict:
        ws = self.tcn.window_set([g for r in recs for g in self.inputs(r)])
        positive = ((ws["weight"] > 0) & (ws["y"] == 1)).sum()
        if not positive or positive == (ws["weight"] > 0).sum():
            raise Refused("a fit needs both classes among its weighted cells: need data")
        return ws

    def select(self, inner: list, held: list) -> tuple:
        validation = self.tcn.window_set([g for r in held for g in self.inputs(r)])
        if not (validation["weight"] > 0).any():
            raise Refused("the nested fold has no cell with loss weight: a stopping epoch cannot be chosen on it")
        fitted = self.tcn.fit(self.windows(inner), self.seed, self.max_epochs, validation)
        choice = {"epochs": fitted["epochs"], "maxEpochs": self.max_epochs, "nestedLoss": fitted["history"]}
        return choice, {r.rid: self.logits(fitted["model"], r) for r in held}

    def refit(self, train: list, choice: dict):
        return self.tcn.fit(self.windows(train), self.seed, choice["epochs"])["model"]

    def logits(self, model, r: Recording) -> np.ndarray:
        grids = self.inputs(r)
        out = np.zeros(len(r.arr["t"]))
        for g, cells in zip(grids, self.tcn.cell_logits(model, grids)):
            out[g["start"]:g["stop"]] = cells[g["cell"]]
        return out

    def describe(self, choice: dict) -> str:
        return f"{choice['epochs']} of {choice['maxEpochs']} epochs"

    def shapes(self, recs: list) -> dict:
        grids = [g for r in recs for g in self.inputs(r)]
        return {"inputs": len(ft.GRID_NAMES), "cells": sum(len(g["y"]) for g in grids), "windows": sum(len(ft.windows(len(g["y"]))) for g in grids),
                "cellsWithLossWeight": int(sum((g["w"] > 0).sum() for g in grids)), "missingCells": int(sum(g["X"][:, -1].sum() for g in grids))}

    def save(self, model, folder: str, choice: dict):
        import torch
        torch.save(model.state_dict(), os.path.join(folder, "weights.pt"))
        _write_json(os.path.join(folder, "weights.json"), {
            "candidate": "r2", "featureSchema": v.FEATURE_VERSION, "grid": ft.GRID_VERSION, "lookaheadSec": self.lookahead_sec,
            "inputs": ft.GRID_NAMES, "window": ft.WINDOW, "hop": ft.HOP, "parameters": self.tcn.parameters(model),
            "mean": model.mean.tolist(), "std": model.std.tolist(), "stateDict": "weights.pt", "choice": choice})


FAMILIES = {"r1": R1, "r2": R2}


# ----------------------------------------------------------------------------- calibration and decode selection

def fit_temperature(logits: np.ndarray, target: np.ndarray, w: np.ndarray) -> float:
    """The temperature T > 0 that minimises the mean cross-entropy of σ(logit / T) over the steps with w = 1
    (golden-section search on ln T over the range TEMPERATURE_RANGE)."""
    keep = w > 0
    if not keep.any():
        raise Refused("the nested fold has no step with loss weight: a temperature cannot be fitted on it")
    z, t = logits[keep], target[keep]
    nll = lambda log_t: float(np.mean(np.logaddexp(0.0, z / np.exp(log_t)) - t * z / np.exp(log_t)))
    lo, hi, ratio = np.log(TEMPERATURE_RANGE[0]), np.log(TEMPERATURE_RANGE[1]), (np.sqrt(5.0) - 1.0) / 2.0
    for _ in range(80):
        a, b = hi - ratio * (hi - lo), lo + ratio * (hi - lo)
        if nll(a) <= nll(b):
            hi = b
        else:
            lo = a
    return float(np.exp((lo + hi) / 2.0))


def probabilities(logits: np.ndarray, temperature: float) -> np.ndarray:
    return sigmoid(logits / temperature)


def clips_at(prep: Prepared, r: Recording, p: np.ndarray, point: dict) -> tuple:
    raw, dropped = decode.raw_intervals(r.rec, r.arr["tick"], r.segs, p, point, prep.sampling_hz)
    return decode.clips_from(r.rec, raw, COMMITTED), raw, dropped


def pick_point(rows: list, r0_complete: int) -> tuple:
    """The D-007 rule over the grid's rows ({gridIndex, complete, falseClips, deadTimeRetention}): the lowest
    dead-time retention among the rows with at least R0's complete rallies, ties to fewer false clips, then to the
    earlier grid point; when no row reaches R0, the most complete rallies with the same tie-breaks. Returns
    (row, constraint met). An undefined retention (no fully marked recording) counts as equal for every row."""
    retention = lambda x: x["deadTimeRetention"] or 0.0
    feasible = [x for x in rows if x["complete"] >= r0_complete]
    if feasible:
        return min(feasible, key=lambda x: (retention(x), x["falseClips"], x["gridIndex"])), True
    return min(rows, key=lambda x: (-x["complete"], retention(x), x["falseClips"], x["gridIndex"])), False


def select_decode(prep: Prepared, held: list, probs: dict, r0_cards: dict) -> tuple:
    """The decode grid point for one fold, chosen on the nested fold's recordings (the module docstring)."""
    r0_complete = sum(r0_cards[r.rid]["scorecard"]["paddedExport"]["complete"] for r in held)
    rallies = sum(r0_cards[r.rid]["scorecard"]["paddedExport"]["rallies"] for r in held)
    scored: dict = {}
    rows = []
    for index, point in enumerate(decode.GRID):
        complete, false_clips, dead, retained = 0, 0, 0.0, 0.0
        for r in held:
            clips, raw, _ = clips_at(prep, r, probs[r.rid], point)
            key = (r.rid, tuple(raw))
            if key not in scored:
                scored[key] = evaluate.score(r.rec, clips)["paddedExport"]
            pe = scored[key]
            complete += pe["complete"]
            if pe["fullyMarked"]:
                false_clips, dead, retained = false_clips + pe["falseClips"], dead + pe["deadSeconds"], retained + pe["deadSecondsRetained"]
        rows.append({"gridIndex": index, "complete": complete, "falseClips": false_clips, "deadTimeRetention": retained / dead if dead else None})
    best, met = pick_point(rows, r0_complete)
    return decode.GRID[best["gridIndex"]], {**best, "rallies": rallies, "r0Complete": r0_complete, "constraintMet": met,
                                            "feasiblePoints": sum(1 for x in rows if x["complete"] >= r0_complete),
                                            "deadTimeAvailable": best["deadTimeRetention"] is not None}


def choose(prep: Prepared, family, k: int, r0_cards: dict) -> dict:
    """Everything chosen for outer fold k — the model choice, the temperature and the decode point — from the
    other folds alone."""
    nested = (k + 1) % prep.folds
    inner, held = prep.of(lambda f: f not in (k, nested)), prep.of(lambda f: f == nested)
    model_choice, logits = family.select(inner, held)
    temperature = fit_temperature(np.concatenate([logits[r.rid] for r in held]), np.concatenate([r.target for r in held]),
                                  np.concatenate([r.arr["w"] for r in held]))
    point, selection = select_decode(prep, held, {r.rid: probabilities(logits[r.rid], temperature) for r in held}, r0_cards)
    return {"fold": k, "nestedFold": nested, "modelChoice": model_choice, "temperature": temperature, "point": point, "selection": selection}


# ----------------------------------------------------------------------------- diagnostics of the learned path

def uncertain_time(r: Recording, p: np.ndarray) -> dict:
    """Runs of steps with calibrated p in [0.3, 0.7] that last at least 2 s, within footage segments."""
    seconds, steps, footage = 0.0, 0, 0
    for a, b in r.segs:
        if not decode.is_footage(int(r.arr["tick"][a]), r.rec):
            continue
        footage += b - a
        inside = (p[a:b] >= UNCERTAIN_BAND[0]) & (p[a:b] <= UNCERTAIN_BAND[1])
        edges = np.flatnonzero(np.diff(np.concatenate(([0], inside.astype(np.int8), [0]))))
        for first, past in zip(edges[::2], edges[1::2]):
            span = r.arr["t"][a + past - 1] - r.arr["t"][a + first]
            if span >= UNCERTAIN_RUN_SEC:
                seconds, steps = seconds + float(span), steps + int(past - first)
    return {"uncertainSec": round(seconds, 3), "uncertainStepFraction": round(steps / footage, 4) if footage else None}


def unprimed(r: Recording, raw: list) -> int:
    """Decoded intervals with no serve contact within 3 s of their start."""
    emitted = np.flatnonzero(r.arr["F"][:, v.FEATURE_INDEX["serve_emitted"]] > 0)
    contacts = (r.arr["t"][emitted] - r.arr["F"][emitted, v.FEATURE_INDEX["serve_contact_offset"]]) * v.TIMESCALE
    return sum(1 for s, _ in raw if not np.any(np.abs(contacts - s) <= UNPRIMED_SEC * v.TIMESCALE))


def reliability(recs: list, probs: dict) -> dict:
    """Per surface, over the standard recordings' steps with w = 1: ten equal bins of calibrated p."""
    out = {}
    for surface in sorted({r.rec["surface"] for r in recs}):
        chosen = [r for r in recs if r.rec["surface"] == surface and not r.rec["restrictedUse"]]
        if not chosen:
            continue
        keep = np.concatenate([r.arr["w"] > 0 for r in chosen])
        p, t = np.concatenate([probs[r.rid] for r in chosen])[keep], np.concatenate([r.target for r in chosen])[keep]
        which = np.minimum((p * RELIABILITY_BINS).astype(int), RELIABILITY_BINS - 1)
        out[surface] = [{"bin": [b / RELIABILITY_BINS, (b + 1) / RELIABILITY_BINS], "steps": int((which == b).sum()),
                         "meanP": float(p[which == b].mean()) if (which == b).any() else None,
                         "fractionActive": float(t[which == b].mean()) if (which == b).any() else None} for b in range(RELIABILITY_BINS)]
    return out


# ----------------------------------------------------------------------------- the dry run

def _counts(recs: list) -> dict:
    w = np.concatenate([r.arr["w"] for r in recs]) if recs else np.zeros(0)
    t = np.concatenate([r.target for r in recs]) if recs else np.zeros(0)
    return {"recordings": len(recs), "groups": len({r.rec["groupId"] for r in recs}), "rallies": sum(len(r.rec["rallies"]) for r in recs),
            "steps": int(len(w)), "positiveSteps": int(((w > 0) & (t == 1)).sum()), "negativeSteps": int(((w > 0) & (t == 0)).sum()),
            "stepsWithoutLossWeight": int((w == 0).sum()), "restrictedRecordings": sum(1 for r in recs if r.rec["restrictedUse"]),
            "fullyMarkedRecordings": sum(1 for r in recs if evaluate.fully_marked(r.rec))}


def readiness(prep: Prepared, family, argv: list) -> dict:
    """What a run would be given, fold by fold. Fits nothing and scores nothing."""
    plan, problems = [], []
    for k in range(prep.folds):
        nested = (k + 1) % prep.folds
        sides = {"test": prep.of(lambda f: f == k), "training": prep.of(lambda f: f != k),
                 "inner": prep.of(lambda f: f not in (k, nested)), "nested": prep.of(lambda f: f == nested)}
        row = {"fold": k, "nestedFold": nested, **{name: _counts(recs) for name, recs in sides.items()}}
        for name in ("training", "inner"):
            if not row[name]["positiveSteps"] or not row[name]["negativeSteps"]:
                problems.append(f"fold {k}: the {name} folds hold {row[name]['positiveSteps']} positive and {row[name]['negativeSteps']} negative steps — a fit needs both")
        if not row["nested"]["positiveSteps"] + row["nested"]["negativeSteps"]:
            problems.append(f"fold {k}: nested fold {nested} has no step with loss weight — no model choice or temperature can be made on it")
        if not row["nested"]["fullyMarkedRecordings"]:
            problems.append(f"fold {k}: nested fold {nested} has no fully marked recording — dead-time retention is undefined there, "
                            "so the decode point would be chosen by recall and grid order alone")
        if not row["test"]["rallies"]:
            problems.append(f"fold {k}: no truth rally to score")
        plan.append(row)
    return {"kind": "readiness (dry run): nothing was fitted and nothing was scored",
            "identity": identity(prep, family, argv), "validation": prep.validation, "parity": {"clipsRebuilt": prep.parity},
            "foldReport": prep.folds_doc["report"], "inputs": family.shapes(prep.recordings), "plan": plan, "problems": problems}


def readiness_markdown(doc: dict) -> str:
    ident = doc["identity"]
    out = [f"# Rally classifier readiness — {ident['candidate']} ({ident['net']} net)", "",
           "Dry run: **nothing was fitted and nothing was scored.**", "",
           f"Dataset `{ident['dataset']['name']}` · digest `{ident['dataset']['digest']}` · manifest `{ident['dataset']['manifestSha256']}`  ",
           f"Folds file `{ident['foldsFileSha256']}` · validator 0 errors, {len(doc['validation']['warnings'])} warning(s) · "
           f"SegmentBuilder port rebuilt {doc['parity']['clipsRebuilt']} stored clips", "",
           f"Inputs: {doc['inputs']}", "",
           "| fold | nested | test rec / rallies | training + / − steps | inner + / − steps | nested + / − steps | nested fully marked |", "|---|---|---|---|---|---|---|"]
    for r in doc["plan"]:
        out.append(f"| {r['fold']} | {r['nestedFold']} | {r['test']['recordings']} / {r['test']['rallies']} | "
                   f"{r['training']['positiveSteps']} / {r['training']['negativeSteps']} | {r['inner']['positiveSteps']} / {r['inner']['negativeSteps']} | "
                   f"{r['nested']['positiveSteps']} / {r['nested']['negativeSteps']} | {r['nested']['fullyMarkedRecordings']} |")
    cover = doc["foldReport"]["negativeCoverage"]
    out += ["", f"Groups with valid negatives: {cover['groupsWithValidNegatives']} of {cover['groups']} ({cover['fraction']}); {cover['preregistrationG6']}.", "",
            "## Problems", ""] + ([f"- {p}" for p in doc["problems"]] or ["None found."])
    return "\n".join(out) + "\n"


# ----------------------------------------------------------------------------- the run

def identity(prep: Prepared, family, argv: list) -> dict:
    here = os.path.dirname(os.path.abspath(__file__))
    files = ["train.py", "features.py", "decode.py", "evaluate.py", "folds.py", "tcn.py", "validate_dataset.py"]
    hashes = {name: v.sha256_file(os.path.join(here, name)) for name in files}
    hashes["reference_scorecard.py"] = v.sha256_file(os.path.join(here, "..", "scoring", "reference_scorecard.py"))
    versions = {"python": platform.python_version(), "numpy": np.__version__, "platform": platform.platform()}
    if family.name == "r2":
        import torch
        versions["torch"] = torch.__version__
    draw = {k: prep.folds_doc[k] for k in ("procedure", "seed", "folds", "stratify", "shuffle")}
    return {"candidate": family.name, "net": prep.net, "seed": family.seed if family.name == "r2" else None, "lookaheadSec": family.lookahead_sec,
            "dataset": prep.identity, "foldsFileSha256": prep.folds_sha256, "foldDraw": draw,
            "schemas": {"features": v.FEATURE_VERSION, "labels": v.LABEL_VERSION, "derived": ft.DERIVED_VERSION, "grid": ft.GRID_VERSION},
            "decodeSettings": COMMITTED, "rawFloorSec": decode.RAW_FLOOR_SEC, "codeSha256": hashes, "versions": versions, "argv": argv,
            "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}


def _write_json(path: str, doc: dict):
    with open(path, "x", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1)
        fh.write("\n")


def _open_run(out: str):
    if os.path.exists(out) and os.listdir(out):
        raise Refused(f"{out} exists and is not empty; a run folder is never written over")
    os.makedirs(out, exist_ok=True)


def baseline_cards(prep: Prepared) -> dict:
    """{variant: {recordingId: card}} for the stored decider outputs."""
    return {name: {r.rid: evaluate.card(r.rec, r.fold, evaluate.baseline_clips(r.baseline, name)) for r in prep.recordings}
            for name in sorted(prep.parity)}


def run(prep: Prepared, candidate: str, seed: int, out: str, argv: list, r1_run: str | None = None, r2_epochs: int | None = None) -> dict:
    """The nested protocol for one candidate; writes the run folder and returns the report."""
    family = FAMILIES[candidate](prep, seed, r2_epochs)
    r1_cards = _r1_cards(prep, r1_run) if candidate == "r2" and r1_run else None     # refused before anything is fitted
    _open_run(out)
    cards = baseline_cards(prep)
    r0 = cards["r0"]
    cards[candidate] = {}
    fold_rows, probs, raws, dropped = [], {}, {}, 0
    with open(os.path.join(out, "oof.jsonl"), "x", encoding="utf-8") as oof:
        for k in range(prep.folds):
            chosen = choose(prep, family, k, r0)
            model = family.refit(prep.of(lambda f: f != k), chosen["modelChoice"])
            folder = os.path.join(out, f"fold{k}")
            os.makedirs(folder)
            family.save(model, folder, chosen["modelChoice"])
            at_bound = not (TEMPERATURE_RANGE[0] * 1.01 < chosen["temperature"] < TEMPERATURE_RANGE[1] / 1.01)
            _write_json(os.path.join(folder, "calibration.json"), {"method": "temperature", "temperature": chosen["temperature"], "fittedOnFold": chosen["nestedFold"],
                                                                    "searchRange": TEMPERATURE_RANGE, "atSearchBound": at_bound})
            _write_json(os.path.join(folder, "decode.json"), {"point": chosen["point"], "selection": chosen["selection"], "chosenOnFold": chosen["nestedFold"],
                                                               "rawFloorSec": decode.RAW_FLOOR_SEC, "settings": COMMITTED})
            for r in prep.of(lambda f: f == k):
                logits = family.logits(model, r)
                p = probabilities(logits, chosen["temperature"])
                clips, raw, lost = clips_at(prep, r, p, chosen["point"])
                probs[r.rid], raws[r.rid], dropped = p, raw, dropped + lost
                cards[candidate][r.rid] = evaluate.card(r.rec, k, clips)
                for tick, z, q in zip(r.arr["tick"].tolist(), logits.tolist(), p.tolist()):
                    oof.write(json.dumps({"recordingId": r.rid, "fold": k, "tick": tick, "logit": z, "p": q}) + "\n")
            fold_rows.append({"fold": k, "nestedFold": chosen["nestedFold"], "model": family.describe(chosen["modelChoice"]), "modelChoice": chosen["modelChoice"],
                              "calibration": {"temperature": chosen["temperature"], "atSearchBound": at_bound}, "decode": {"point": chosen["point"], "selection": chosen["selection"]}})
    os.makedirs(os.path.join(out, "scorecards"))
    scorer = {"contract": "SCORING_CONTRACT v1", "dataset": prep.identity, "foldsFileSha256": prep.folds_sha256}
    for name, by_recording in cards.items():
        os.makedirs(os.path.join(out, "scorecards", name))
        for rid, c in by_recording.items():
            _write_json(os.path.join(out, "scorecards", name, f"{rid}.evaluation_v2.json"), {"variant": name, **scorer, **c})
    as_lists = {name: [by_recording[r.rid] for r in prep.recordings] for name, by_recording in cards.items()}
    tables = evaluate.tables(as_lists)
    if candidate == "r1":
        hypotheses = [evaluate.h1(tables["pooled"], "r1")]
    elif r1_cards:
        hypotheses = [evaluate.h2(as_lists["r2"], r1_cards)]
    else:
        hypotheses = [{"hypothesis": "H2", "comparison": "r2 vs r1", "holds": None,
                       "note": "Not evaluated: give --r1-run <the R1 run on this dataset, folds file and net condition>."}]
    uncertain = {r.rid: uncertain_time(r, probs[r.rid]) for r in prep.recordings}
    report = {
        "identity": identity(prep, family, argv), "validation": prep.validation, "parity": {"clipsRebuilt": prep.parity},
        "foldReport": prep.folds_doc["report"], "folds": fold_rows, "hypotheses": hypotheses, "tables": tables,
        "diagnostics": {
            "decodedIntervals": sum(len(x) for x in raws.values()), "droppedByRawFloor": dropped,
            "unprimedIntervals": sum(unprimed(r, raws[r.rid]) for r in prep.recordings),
            "uncertainTime": uncertain,
            "recordingsOverUncertainLimit": sorted(rid for rid, u in uncertain.items() if (u["uncertainStepFraction"] or 0) > UNCERTAIN_LIMIT),
            "reliability": reliability(prep.recordings, probs), "onDevice": "not measured"},
        "caveats": CAVEATS,
    }
    _write_json(os.path.join(out, "report.json"), report)
    with open(os.path.join(out, "report.md"), "x", encoding="utf-8") as fh:
        fh.write(evaluate.markdown(report))
    return report


def _r1_cards(prep: Prepared, r1_run: str) -> list:
    """The R1 run's cards for H2, refused unless that run is on this dataset, these folds and this net condition."""
    with open(os.path.join(r1_run, "report.json"), "r", encoding="utf-8") as fh:
        theirs = json.load(fh)["identity"]
    ours = {"candidate": "r1", "net": prep.net, "dataset": prep.identity, "foldsFileSha256": prep.folds_sha256}
    if {k: theirs.get(k) for k in ours} != ours:
        raise Refused(f"--r1-run is not the R1 run on this dataset, folds file and net condition: {r1_run}")
    out = []
    for r in prep.recordings:
        with open(os.path.join(r1_run, "scorecards", "r1", f"{r.rid}.evaluation_v2.json"), "r", encoding="utf-8") as fh:
            out.append(json.load(fh))
    return out


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dataset", help="the dataset folder")
    ap.add_argument("--folds-file", required=True, help="the frozen folds file drawn for this dataset (folds.py)")
    ap.add_argument("--withheld", required=True, help="the external withheld-closure file; the dataset is validated against it first")
    ap.add_argument("--candidate", required=True, choices=sorted(FAMILIES))
    ap.add_argument("--net", required=True, choices=("present", "ablated"), help="ablated: y_above_net is null everywhere")
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    ap.add_argument("--out", required=True, help="the run folder (new or empty)")
    ap.add_argument("--dry-run", action="store_true", help="check and count everything, fit and score nothing; writes readiness.{json,md}")
    ap.add_argument("--r1-run", help="for --candidate r2: the R1 run to evaluate H2 against")
    args = ap.parse_args(argv)
    try:
        prep = prepare(args.dataset, args.folds_file, args.withheld, args.net)
        if args.dry_run:
            _open_run(args.out)
            doc = readiness(prep, FAMILIES[args.candidate](prep, args.seed), argv)
            _write_json(os.path.join(args.out, "readiness.json"), doc)
            with open(os.path.join(args.out, "readiness.md"), "x", encoding="utf-8") as fh:
                fh.write(readiness_markdown(doc))
            print(f"dry run: nothing fitted, nothing scored; {len(doc['problems'])} problem(s); wrote {os.path.join(args.out, 'readiness.md')}")
            return 0
        report = run(prep, args.candidate, args.seed, args.out, argv, args.r1_run)
    except Refused as e:
        print(f"refused: {e}", file=sys.stderr)
        return 1
    for h in report["hypotheses"]:
        print(f"{h['hypothesis']} ({h['comparison']}): {'not evaluable' if h.get('holds') is None else 'holds' if h['holds'] else 'does not hold'}")
    print(f"wrote {os.path.join(args.out, 'report.md')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
