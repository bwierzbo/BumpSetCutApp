#!/usr/bin/env python3
"""Train and evaluate a learned rally-activity candidate on the grouped development folds
(preregistration EXP-20261103, with the owner's 2026-11-12 requirements).

    python3 scripts/rally_classifier/train.py <dataset> --folds-file <folds.json> --withheld <closure.json> \\
        --candidate {r1,r2} --net {present,ablated} --seed 20261103 --out <run> [--dry-run] [--r1-run <run>]

Before anything is fitted, in this order, each one a refusal: the dataset validates with the external withheld
closure (no closure file, no run); its label schema is one this trainer reads; the baseline's `r0` is the
committed settings the preregistration names (and `r0_prime`, when stored, the D-029 ones; and the matched
baseline `r0_no_net_rule`, when stored, r0's settings under another config hash); the folds file was drawn for
exactly this dataset and is what its seed draws; the SegmentBuilder port rebuilds every stored clip from its
pre-merge raw spans; a stored matched baseline holds every r0 clip unchanged; under the audited label schema no
negative step with loss weight lies outside trusted time (`trusted_negatives.py`).

**The negative-coverage gate** (G7 and G6, `trusted_negatives.py`) is computed there too. `run` — the one
function that fits — refuses a dataset that does not meet it, with every deficiency: a dataset whose negatives
are declared and not audited (`rally_activity_truth_v1` with declared-complete recordings, as `rc-v1-20261112`),
or one where too few groups contribute trusted negatives. The gate is never weakened and has no override.

`--dry-run` stops before `run`: it extracts the features, counts what every fit of the nested protocol would be
given and writes `readiness.{json,md}` — with the gate's verdict and deficiencies, the exposure the manifest
records and the baseline asymmetry. It fits nothing — no standardisation, no model, no temperature — and scores
nothing, the stored baseline included.

The nested protocol (§5), for each outer fold k of the K in the folds file:
- the nested fold is fold (k + 1) mod K; the inner folds are the other K − 2;
- **model choice**, on models fitted to the inner folds — R1: the penalty in {1e-4, 1e-3, 1e-2} with the lowest
  nested-fold loss (the fitting loss's data term, with the inner folds' class weights; a tie goes to the larger
  penalty); R2: the epoch, of at most 40, with the lowest nested-fold loss;
- **calibration**: one temperature, fitted to that inner model's logits on the nested fold's steps with w = 1;
- **decode point**: over the 108-point grid in its order, on the nested fold's recordings (restricted ones
  included), the D-007 objective — lowest pooled dead-time retention among the points whose pooled complete
  rallies are at least R0's on those recordings; ties to fewer false clips, then to the earlier point. Two
  fallbacks (amendment A8), each recorded in the fold's `decode.json` and in the report whenever it is used:
  `recall_constraint_not_met` — no point reaches R0's recall, so the point with the most complete rallies is taken
  (same tie-breaks), reported with the counts (R0's complete rallies, the most any point reached, how many short,
  recording by recording) and `constraintMet: false`; `dead_time_retention_undefined` — the nested fold has no
  fully marked recording (or no dead time), so retention cannot order the points and false clips and grid order
  do. A run in which neither was used says so;
- the model is refitted on the K − 1 training folds with the chosen penalty / number of epochs, and fold k's
  recordings are predicted, calibrated with that temperature, decoded at that point and scored.
Fold k's recordings are never read by any of those steps.

R1 is L2-regularised logistic regression over `derived_v1`: class-balanced (each class half the total weight),
standardised with the mean and standard deviation of the training steps with w = 1, the intercept not
penalised, objective Σ cᵢ·BCEᵢ + ½·penalty·‖β‖² with Σ cᵢ = 1. It is fitted on the full batch by Newton steps
with a backtracking line search to a gradient under 1e-10 — the objective is strictly convex, so this is the
one minimiser gradient descent would reach, without a step size or an iteration count to choose. R2 is `tcn.py`.

Calibration (amendment A9, accepted as written: temperature alone, no bias term). Class balancing shifts R1's
logit by δ = ln(n⁻ / n⁺) (`balancing_shift`); a temperature cannot remove an offset, so R1's reported
probabilities are not calibrated class frequencies. `CALIBRATION_LIMITATION` is the statement every report
carries, with δ per fold and the reliability table.

Labels: a step counts in a loss, a standardisation, a class weight or a temperature only with w = 1
(ACTIVE_RALLY is the positive; NON_RALLY and NON_RALLY_ACTIVITY the negatives). TRANSITION, UNKNOWN and EXCLUDED
steps contribute nothing.

A run folder holds, per fold, `weights.*`, `calibration.json` and `decode.json`; the out-of-fold predictions
`oof.jsonl`; `scorecards/<variant>/<recording>.evaluation_v2.json` for the candidate and each stored baseline
variant; and `report.{json,md}`.

Every report states (amendments A4, A8, A9, A10, A13 as the owner accepted them on 2026-11-14): that it is
development evaluation on recordings with historical exposure, with the counts; handheld recordings apart and a
sensitivity analysis without them, for every headline table and for H1 / H2; the decode fallbacks used, or that
none was; the calibration limitation; and the baseline asymmetry — R0, the primary baseline, passed the
pipeline's above-net rule and a candidate's clips did not — with what the dataset allows to be counted, and a
secondary comparison against the matched baseline when the dataset stores one.
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
import trusted_negatives as tn  # noqa: E402
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
MATCHED = "r0_no_net_rule"      # the optional baseline variant: r0's config with the above-net rule off (amendment A10)
CAVEATS = [
    "Development evidence only: every recording is in the detectors' training packages and most carry decider-selection exposure.",
    "r0_prime is the D-029 reference: its settings were selected on these recordings; it is never the benchmark.",
    "The stored baseline clips passed the pipeline's above-net rule after SegmentBuilder; the learned candidate's clips go through "
    "the SegmentBuilder port only (the trainer does not apply that rule: it has no verified port of it), so a clip the rule would "
    "drop stays in the candidate's export.",
    "R2 reads the 30 Hz grid view and misses the earlier of two steps that share a cell; R1 sees every step.",
    "This is development evaluation, not independent final-test evidence: no holdout, final-test or unexposed recording is read, "
    "and nothing here supports a claim about unseen venues, cameras or recording conditions.",
    "The exposure counts are the ledger rows the manifest carried at export. A recording without a row is not cleared: a use that "
    "left no row (a detector whose training package is no longer on record) is unknown, not absent.",
    "R1's reported probabilities are decode scores, not calibrated class frequencies (class-balanced training, temperature alone).",
    "A continuous handheld recording is eligible and standard: it is trained on and is in the headline tables; handheld recordings "
    "are also reported apart, with a sensitivity analysis that leaves them out.",
]
EXPOSURE_STATEMENT = ("Development evaluation on recordings with historical detector and decider exposure — "
                      "not independent final-test evidence.")
UNKNOWN_IS_NOT_CLEARED = ("A recording without a row is not cleared: the ledger holds known uses only, and a use that left no row "
                          "is unknown, not absent.")
ASYMMETRY = (
    "R0 — the production decider's stored output — is the primary baseline and H1's benchmark; that does not change. Its stored clips "
    "passed the pipeline's above-net rule after SegmentBuilder (EvidenceReplayer.decidedRallies: a multi-contact clip whose ball never "
    "clears the net top is dropped, on recordings with a detected net). A learned candidate's clips go through the SegmentBuilder port "
    "only. The rule only removes clips, so it can lower R0's false clips and dead time (and cost it a rally) in a way the candidate is "
    "not given: a candidate clip the rule would have dropped stays in its export. Every comparison with R0 here carries that advantage "
    "of R0's; nothing is corrected for it.")
CALIBRATION_LIMITATION = (
    "Calibration is temperature scaling alone (amendment A9, accepted as written; no bias term is fitted). R1 is trained class-balanced: "
    "each ACTIVE_RALLY step weighs 0.5 / n⁺ and each negative step 0.5 / n⁻, n⁺ and n⁻ being the training steps with loss weight. Weighting "
    "the classes by a and b moves the log-odds a logistic model fits by ln(a / b); here that is δ = ln(n⁻ / n⁺), so R1's logit is the "
    "unweighted model's plus δ (exact for the minimiser of a well-specified model, slopes unchanged). A temperature divides the logit by "
    "one scalar T: it rescales about zero and leaves p = 0.5 where the logit is 0 — where the class frequency is n⁺ / (n⁺ + n⁻), not one "
    "half — so no T removes δ. The probabilities reported for R1 are therefore decode scores, not calibrated class frequencies: read the "
    "reliability table as showing that offset. The decode thresholds are chosen per fold on these same scores, so the clips do not depend "
    "on δ being removed. R2 is not class-balanced (δ = 0); its limitation is the single temperature alone.")


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
    negatives: dict      # trusted_negatives.report: the gates G7 and G6 for this dataset and fold draw

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
    labels = manifest["labelSchema"]["version"]
    if labels not in tn.LABEL_SCHEMAS:
        raise Refused(f"the dataset's label schema is {labels!r}; this trainer reads {' and '.join(tn.LABEL_SCHEMAS)}")
    variants = {var["name"]: var["settings"] for var in manifest["baseline"]["variants"]}
    # The validator holds a stored matched baseline (`r0_no_net_rule`) to r0's settings, its own config hash and every
    # r0 clip unchanged; r0 held to the committed settings here makes it the preregistration's as well.
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
    recordings, coverage = [], []
    for rec in manifest["recordings"]:
        steps = v.read_steps(dataset_dir, rec)
        baseline = v.read_baseline(dataset_dir, rec)
        arr = ft.arrays(steps, ablate_net=(net == "ablated"))
        recordings.append(Recording(rec, folds_doc["recordings"][rec["recordingId"]], arr, baseline, ft.segments(arr["seg"])))
        try:
            coverage.append(tn.coverage_of(rec, steps, labels == tn.AUDITED_LABELS))
        except tn.CoverageError as e:
            raise Refused(str(e))
    try:
        negatives = tn.report(manifest, coverage, folds_doc)
    except tn.CoverageError as e:
        raise Refused(str(e))
    return Prepared(dataset_dir, manifest, v.dataset_identity(dataset_dir), folds_doc, v.sha256_file(folds_file),
                    {"errors": 0, "warnings": report.warnings, "info": report.info, "withheldFileSha256": v.sha256_file(withheld)},
                    parity, recordings, net, negatives)


def exposure_summary(manifest: dict) -> dict:
    """The exposure the manifest records per recording (the ledger rows at export), counted by kind and, for
    training packages, by package (amendment A13)."""
    recs = manifest["recordings"]
    kinds = sorted({e["kind"] for r in recs for e in r["exposure"]})
    packages = sorted({e["ref"] for r in recs for e in r["exposure"] if e["kind"] == "training_package"})
    return {"statement": EXPOSURE_STATEMENT, "unknownIsNotCleared": UNKNOWN_IS_NOT_CLEARED, "recordings": len(recs),
            "recordingsByKind": {k: sum(1 for r in recs if any(e["kind"] == k for e in r["exposure"])) for k in kinds},
            "trainingPackages": {p: sum(1 for r in recs if any(e["kind"] == "training_package" and e["ref"] == p for e in r["exposure"])) for p in packages},
            "recordingsWithoutARow": sorted(r["recordingId"] for r in recs if not r["exposure"])}


def baseline_asymmetry(prep: Prepared) -> dict:
    """What the dataset allows to be said, without a model, about the above-net rule R0's stored clips passed
    (amendment A10): where the rule could act, where it never ran, and — only when the dataset stores the matched
    baseline — how many clips it removed."""
    def side(recs: list) -> dict:
        return {"rallies": sum(len(r.rec["rallies"]) for r in recs), "r0Clips": sum(len(r.baseline["r0"]) for r in recs)}
    ran, never = [r for r in prep.recordings if r.rec["net"] is not None], [r for r in prep.recordings if r.rec["net"] is None]
    if MATCHED in prep.parity:
        removed = {r.rid: len(r.baseline[MATCHED]) - len(r.baseline["r0"]) for r in prep.recordings}
        matched = {"variant": MATCHED, "present": True, "clipsRemovedByRule": sum(removed.values()),
                   "r0Clips": sum(len(r.baseline["r0"]) for r in prep.recordings), "matchedClips": sum(len(r.baseline[MATCHED]) for r in prep.recordings),
                   "byRecording": {rid: n for rid, n in removed.items() if n},
                   "note": f"Matched baseline `{MATCHED}` (R0's config with the rule off) is stored in this dataset: every candidate table is also "
                           "reported against it, as a secondary comparison; R0 stays the primary baseline."}
    else:
        matched = {"variant": MATCHED, "present": False,
                   "note": f"Matched baseline not in this dataset: no `{MATCHED}` variant is stored. How many raw clips the rule removed from R0 "
                           "cannot be counted here — the baseline files hold only the clips that passed, and the decider cannot be re-run from the "
                           "steps (contract §3a). A dataset exported with that variant (R0's config, enableAboveNetRequirement off) would hold them."}
    return {"primaryBaseline": "r0", "statement": ASYMMETRY,
            "ruleRan": {"recordings": len(ran), **side(ran)},
            "ruleNeverRan": {"recordings": sorted(r.rid for r in never), **side(never)},
            "matchedBaseline": matched}


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


def balancing_shift(positive: int, negative: int) -> float:
    """δ = ln(n⁻ / n⁺): how far class balancing moves a logistic model's logit from the unweighted model's.
    `balanced_weights` gives a positive step 0.5 / n⁺ and a negative step 0.5 / n⁻; a loss that weighs the classes
    by a and b is minimised, input by input, where σ(z) = a·p / (a·p + b·(1 − p)), that is z = logit(p) + ln(a / b),
    and ln((0.5 / n⁺) / (0.5 / n⁻)) = ln(n⁻ / n⁺). Positive when negatives outnumber positives: the balanced model
    then over-states ACTIVE_RALLY."""
    return float(np.log(negative / positive))


def minimise(Z: np.ndarray, t: np.ndarray, c: np.ndarray, penalty: float) -> tuple:
    """The minimiser (β, b) of `objective` for standardised inputs Z, targets t and per-step weights c, and the
    largest gradient component left: full-batch Newton steps with a backtracking line search."""
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
    return theta, float(np.max(np.abs(grad)))


def fit_logistic(X: np.ndarray, target: np.ndarray, w: np.ndarray, penalty: float) -> dict:
    c_all = balanced_weights(target, w)
    keep = w > 0
    mean, std = standardise(X, w)
    Z, t, c = (X[keep] - mean) / std, target[keep], c_all[keep]
    theta, gradient_max = minimise(Z, t, c, penalty)
    return {"mean": mean, "std": std, "coefficients": theta[:-1], "intercept": float(theta[-1]), "penalty": penalty,
            "positiveWeight": float(c[t == 1][0] * len(c)), "negativeWeight": float(c[t == 0][0] * len(c)), "gradientMax": gradient_max}


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
    name, lookahead_sec, class_balanced = "r1", ft.R1_LOOKAHEAD_SEC, True

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
    name, class_balanced = "r2", False

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
    """The decode grid point for one fold, chosen on the nested fold's recordings (the module docstring), and the
    record of the choice — `fallbacks` lists each fallback of `pick_point` that decided it (empty: none did)."""
    r0 = {r.rid: r0_cards[r.rid]["scorecard"]["paddedExport"] for r in held}
    r0_complete, rallies = sum(pe["complete"] for pe in r0.values()), sum(pe["rallies"] for pe in r0.values())
    scored: dict = {}
    rows, by_recording = [], []
    for index, point in enumerate(decode.GRID):
        complete, false_clips, dead, retained = {}, 0, 0.0, 0.0
        for r in held:
            clips, raw, _ = clips_at(prep, r, probs[r.rid], point)
            key = (r.rid, tuple(raw))
            if key not in scored:
                scored[key] = evaluate.score(r.rec, clips)["paddedExport"]
            pe = scored[key]
            complete[r.rid] = pe["complete"]
            if pe["fullyMarked"]:
                false_clips, dead, retained = false_clips + pe["falseClips"], dead + pe["deadSeconds"], retained + pe["deadSecondsRetained"]
        rows.append({"gridIndex": index, "complete": sum(complete.values()), "falseClips": false_clips, "deadTimeRetention": retained / dead if dead else None})
        by_recording.append(complete)
    best, met = pick_point(rows, r0_complete)
    fallbacks = []
    if not met:
        short = r0_complete - best["complete"]
        fallbacks.append({
            "kind": "recall_constraint_not_met", "pointsMeetingConstraint": 0, "gridPoints": len(rows),
            "r0Complete": r0_complete, "bestComplete": best["complete"], "rallies": rallies, "shortBy": short,
            "r0Recall": r0_complete / rallies if rallies else None, "bestRecall": best["complete"] / rallies if rallies else None,
            "pointsAtBest": sum(1 for x in rows if x["complete"] == best["complete"]),
            "byRecording": [{"recordingId": r.rid, "rallies": r0[r.rid]["rallies"], "r0Complete": r0[r.rid]["complete"],
                             "complete": by_recording[best["gridIndex"]][r.rid]} for r in held],
            "why": f"none of the {len(rows)} grid points reached R0's {r0_complete} complete rallies of {rallies} on the nested fold's recordings; "
                   f"the most any point reached is {best['complete']} ({short} short), at {sum(1 for x in rows if x['complete'] == best['complete'])} point(s).",
            "rule": "the point with the most complete rallies; ties to lower dead-time retention, then fewer false clips, then the earlier grid point."})
    if best["deadTimeRetention"] is None:
        marked = sum(1 for r in held if evaluate.fully_marked(r.rec))
        fallbacks.append({
            "kind": "dead_time_retention_undefined", "fullyMarkedRecordings": marked,
            "why": ("the nested fold holds no fully marked recording, so dead-time retention is undefined at every grid point." if not marked
                    else f"the nested fold's {marked} fully marked recording(s) hold no dead time, so dead-time retention is undefined at every grid point."),
            "rule": "retention counts as equal for every point: the choice falls to fewer false clips, then the earlier grid point."})
    return decode.GRID[best["gridIndex"]], {**best, "rallies": rallies, "r0Complete": r0_complete, "constraintMet": met,
                                            "feasiblePoints": sum(1 for x in rows if x["complete"] >= r0_complete),
                                            "deadTimeAvailable": best["deadTimeRetention"] is not None, "fallbacks": fallbacks}


def decode_fallbacks(fold_rows: list) -> dict:
    """The run's statement on the decode-point selection's fallbacks (amendment A8): which folds used one, or
    that none did."""
    used = [{"fold": f["fold"], "nestedFold": f["nestedFold"], "fallbacks": f["decode"]["selection"]["fallbacks"]}
            for f in fold_rows if f["decode"]["selection"]["fallbacks"]]
    if used:
        statement = (f"A fallback of the decode-point selection was used in {len(used)} of {len(fold_rows)} folds "
                     f"(outer fold {', '.join(str(u['fold']) for u in used)}); each is listed with why.")
    else:
        statement = (f"No fallback was used: in each of the {len(fold_rows)} folds at least one grid point reached R0's complete rallies on the "
                     "nested fold, and dead-time retention was defined there.")
    return {"used": bool(used), "statement": statement, "folds": used}


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
        row["logitShift"] = _logit_shift(family, row["inner"], row["training"])
        plan.append(row)
    return {"kind": "readiness (dry run): nothing was fitted and nothing was scored",
            "identity": identity(prep, family, argv), "validation": prep.validation, "parity": {"clipsRebuilt": prep.parity},
            "exposure": exposure_summary(prep.manifest), "negativeCoverage": prep.negatives, "baselineAsymmetry": baseline_asymmetry(prep),
            "calibration": {"limitation": CALIBRATION_LIMITATION, "classBalanced": family.class_balanced},
            "foldReport": prep.folds_doc["report"], "inputs": family.shapes(prep.recordings), "plan": plan,
            "problems": problems + prep.negatives["deficiencies"]}


def _logit_shift(family, inner: dict, training: dict) -> dict | None:
    """δ (`balancing_shift`) of the two models a fold fits, from their sides' counts (`_counts`): the one the
    temperature is fitted on (inner folds) and the one that is scored (training folds). None for a family that is
    not class-balanced, or a side without both classes (which cannot be fitted)."""
    sides = (inner, training)
    if not family.class_balanced or not all(side["positiveSteps"] and side["negativeSteps"] for side in sides):
        return None
    shift = [balancing_shift(side["positiveSteps"], side["negativeSteps"]) for side in sides]
    return {"inner": shift[0], "refit": shift[1], "classFrequencyAtHalf": float(sigmoid(np.array(-shift[1])))}


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
    out += ["", f"Groups with labelled negatives, as the folds file counted them (labels, not trust): {cover['groupsWithValidNegatives']} of "
                f"{cover['groups']} ({cover['fraction']}). The gate below counts trusted negatives only.", ""]
    out += tn.markdown(doc["negativeCoverage"])
    out += ["A real run on this dataset would " + ("start: both gates are met." if doc["negativeCoverage"]["met"] else "be **refused**: the gate is not met."), "",
            "## What the evidence is", ""] + evaluate.exposure_md(doc["exposure"]) + evaluate.asymmetry_md(doc["baselineAsymmetry"])
    out += ["## Calibration", "", doc["calibration"]["limitation"], ""]
    if doc["calibration"]["classBalanced"]:
        out += ["δ = ln(n⁻ / n⁺) from the counts above (nothing fitted):", "", "| fold | δ, inner folds | δ, training folds | class frequency where p = 0.5 before T |", "|---|---|---|---|"]
        out += [f"| {r['fold']} | {r['logitShift']['inner']:+.4f} | {r['logitShift']['refit']:+.4f} | {r['logitShift']['classFrequencyAtHalf']:.3f} |" if r["logitShift"]
                else f"| {r['fold']} | — | — | — |" for r in doc["plan"]] + [""]
    out += ["## Problems", ""] + ([f"- {p}" for p in doc["problems"]] or ["None found."])
    return "\n".join(out) + "\n"


# ----------------------------------------------------------------------------- the run

def identity(prep: Prepared, family, argv: list) -> dict:
    here = os.path.dirname(os.path.abspath(__file__))
    files = ["train.py", "features.py", "decode.py", "evaluate.py", "folds.py", "tcn.py", "trusted_negatives.py", "validate_dataset.py"]
    hashes = {name: v.sha256_file(os.path.join(here, name)) for name in files}
    hashes["reference_scorecard.py"] = v.sha256_file(os.path.join(here, "..", "scoring", "reference_scorecard.py"))
    versions = {"python": platform.python_version(), "numpy": np.__version__, "platform": platform.platform()}
    if family.name == "r2":
        import torch
        versions["torch"] = torch.__version__
    draw = {k: prep.folds_doc[k] for k in ("procedure", "seed", "folds", "stratify", "shuffle")}
    return {"candidate": family.name, "net": prep.net, "seed": family.seed if family.name == "r2" else None, "lookaheadSec": family.lookahead_sec,
            "dataset": prep.identity, "foldsFileSha256": prep.folds_sha256, "foldDraw": draw,
            "schemas": {"features": v.FEATURE_VERSION, "labels": prep.manifest["labelSchema"]["version"], "derived": ft.DERIVED_VERSION, "grid": ft.GRID_VERSION},
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
    """The nested protocol for one candidate; writes the run folder and returns the report. Refused, before
    anything is fitted or written, for a dataset that does not meet the negative-coverage gate."""
    if not prep.negatives["met"]:
        raise Refused(f"the negative-coverage gate is not met (label schema {prep.negatives['labelSchema']}, negatives {prep.negatives['negativeLabels']}) — "
                      + " | ".join(prep.negatives["deficiencies"]))
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
            training = prep.of(lambda f: f != k)
            model = family.refit(training, chosen["modelChoice"])
            folder = os.path.join(out, f"fold{k}")
            os.makedirs(folder)
            family.save(model, folder, chosen["modelChoice"])
            at_bound = not (TEMPERATURE_RANGE[0] * 1.01 < chosen["temperature"] < TEMPERATURE_RANGE[1] / 1.01)
            shift = _logit_shift(family, _counts(prep.of(lambda f: f not in (k, chosen["nestedFold"]))), _counts(training))
            _write_json(os.path.join(folder, "calibration.json"), {"method": "temperature", "temperature": chosen["temperature"], "fittedOnFold": chosen["nestedFold"],
                                                                    "searchRange": TEMPERATURE_RANGE, "atSearchBound": at_bound, "logitShift": shift,
                                                                    "limitation": CALIBRATION_LIMITATION})
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
                              "calibration": {"temperature": chosen["temperature"], "atSearchBound": at_bound, "logitShift": shift},
                              "decode": {"point": chosen["point"], "selection": chosen["selection"]}})
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
        "exposure": exposure_summary(prep.manifest), "negativeCoverage": prep.negatives,
        "foldReport": prep.folds_doc["report"], "folds": fold_rows, "decodeFallbacks": decode_fallbacks(fold_rows),
        "hypotheses": hypotheses, "calibration": {"limitation": CALIBRATION_LIMITATION, "classBalanced": family.class_balanced},
        "baselineAsymmetry": baseline_asymmetry(prep), "tables": tables,
        "tablesAgainstMatchedBaseline": evaluate.tables(as_lists, MATCHED) if MATCHED in as_lists else None,
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
            gate = prep.negatives
            print(f"dry run: nothing fitted, nothing scored; {len(doc['problems'])} problem(s); negatives {gate['negativeLabels']}: "
                  f"G7 {'met' if gate['g7']['met'] else 'NOT MET'}, G6 {'met' if gate['g6']['met'] else 'NOT MET'} "
                  f"({gate['groupsWithTrustedNegatives']} of {gate['groups']} groups with trusted negatives, {gate['groupsRequired']} required)"
                  + ("" if gate["met"] else " — a real run would be refused") + f"; wrote {os.path.join(args.out, 'readiness.md')}")
            return 0
        report = run(prep, args.candidate, args.seed, args.out, argv, args.r1_run)
    except Refused as e:
        print(f"refused: {e}", file=sys.stderr)
        return 1
    for h in report["hypotheses"]:
        print(f"{h['hypothesis']} ({h['comparison']}): {'not evaluable' if h.get('holds') is None else 'holds' if h['holds'] else 'does not hold'}")
    print(report["decodeFallbacks"]["statement"])
    print(f"wrote {os.path.join(args.out, 'report.md')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
