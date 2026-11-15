#!/usr/bin/env python3
"""Draw the grouped development folds of a rally-classifier dataset and freeze them in their own file.

    python3 scripts/rally_classifier/folds.py <dataset> --out <folds.json> [--folds 5] [--seed 20261103]
                                              [--withheld closure.json] [--stratify every-fold|where-feasible]

The folds file (`rally_classifier_folds_v1`) is an experiment input of its own: it names the dataset it was
drawn for (folder name, manifest SHA-256, digest), the seed and the procedure, the fold of every group and
recording, and the per-fold report. It is written once (an existing file is never overwritten) and the dataset
is not touched — the manifest's own `fold` field is ignored. `load` is what the trainer reads it with: it
refuses a file whose dataset identity is not the dataset's, and one whose assignment is not what the recorded
seed and procedure draw.

The procedure, `fold_draw_v1` — the preregistration's §2 made exact (EXP-20261103, with the owner's
2026-11-12 requirements). Where §2 left a choice, the choice is stated:

1. A group is a `groupId` of the dataset manifest: every recording of a group lands in one fold. Its name
   for sorting is its first recording's (the smallest `recordingId`); its surface is its recordings' (a group
   whose recordings disagree takes the most frequent, ties to the alphabetically first, and is listed under
   `mixedSurfaceGroups`).
2. The groups, sorted by that name, are shuffled with `random.Random(seed)`. A re-shuffle shuffles the same
   list again with the same generator, so the n-th attempt is a function of the seed alone.
3. Deal: the surfaces in alphabetical order, each surface's groups in the shuffled order, one group per fold
   in turn. **The turn carries on from one surface to the next** (it does not restart at fold 0), so the folds
   hold equal numbers of groups to within one — §2's "5 folds of 3–4 groups" for 18 — and a surface with at
   least `folds` groups is in every fold by construction.
4. A deal is accepted when every fold holds a group of every surface that must be in every fold and no fold's
   rally count (truth rallies of all its recordings, restricted ones included) is further than 25 % from the
   mean. The first accepted attempt is the draw; its number is recorded.
5. Infeasible, reported and nothing written: fewer groups than folds; a surface with fewer groups than folds
   (under `--stratify every-fold`, the preregistration's wording: every fold holds every surface); no accepted
   deal within `--max-shuffles` (the closest attempt is reported). `--stratify where-feasible` is the owner's
   "stratify where feasible": a surface with fewer groups than folds is spread over as many folds as it has
   groups and listed under `surfacesNotInEveryFold`; it is opt-in so that an amended protocol is a recorded
   choice, never a silent one.

Durations in the report are step time: a step stands for the time since the previous step of its segment
(the first step of a segment for none), summed by label — `positiveSec` over ACTIVE_RALLY steps,
`validNegativeSec` over NON_RALLY and NON_RALLY_ACTIVITY steps (the only labels with loss weight).
Standard library only.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import validate_dataset as v  # noqa: E402

SCHEMA_VERSION = "rally_classifier_folds_v1"
PROCEDURE = "fold_draw_v1"
DEFAULT_FOLDS = 5
MIN_FOLDS = 3        # an outer fold, a nested fold and at least one fold to train on (the trainer's protocol)
DEFAULT_SEED = 20261103
DEFAULT_MAX_SHUFFLES = 1000
BALANCE_TOLERANCE = 0.25
STRATIFY = ("every-fold", "where-feasible")
POSITIVE = {v.STATES["ACTIVE_RALLY"]}
NEGATIVE = {v.STATES["NON_RALLY"], v.STATES["NON_RALLY_ACTIVITY"]}
# Gate G6 of the preregistration (§2a), stated for the 18 groups of 2026-11-03. Reported against, never decided here.
G6_COUNT, G6_OF = 12, 18


class FoldsError(Exception):
    """The folds cannot be drawn, or a folds file cannot be used. `report` says why, for a person."""

    def __init__(self, message: str, report: dict | None = None):
        super().__init__(message)
        self.report = report or {}


def groups_of(manifest: dict) -> list:
    """The dataset's groups, sorted by their first recording's name."""
    by_group: dict = {}
    for rec in manifest["recordings"]:
        by_group.setdefault(rec["groupId"], []).append(rec)
    out = []
    for gid, recs in by_group.items():
        names = sorted(r["recordingId"] for r in recs)
        surfaces = sorted({r["surface"] for r in recs})
        counts = {s: sum(1 for r in recs if r["surface"] == s) for s in surfaces}
        out.append({"groupId": gid, "firstRecording": names[0], "recordings": names,
                    "surface": max(surfaces, key=lambda s: counts[s]), "surfaces": surfaces,
                    "rallies": sum(len(r["rallies"]) for r in recs)})
    return sorted(out, key=lambda g: g["firstRecording"])


def _deal(order: list, surfaces: list, folds: int) -> dict:
    assignment, turn = {}, 0
    for s in surfaces:
        for g in order:
            if g["surface"] == s:
                assignment[g["groupId"]] = turn % folds
                turn += 1
    return assignment


def _rallies_per_fold(groups: list, assignment: dict, folds: int) -> list:
    out = [0] * folds
    for g in groups:
        out[assignment[g["groupId"]]] += g["rallies"]
    return out


def draw(groups: list, folds: int, seed: int, stratify: str, max_shuffles: int) -> dict:
    """`fold_draw_v1` (the module docstring). Returns {assignment: {groupId: fold}, shuffle, surfacesNotInEveryFold};
    raises FoldsError with the reasons when the folds are infeasible."""
    if stratify not in STRATIFY:
        raise FoldsError(f"stratify must be one of {STRATIFY}")
    order = sorted(groups, key=lambda g: g["firstRecording"])
    surfaces = sorted({g["surface"] for g in order})
    per_surface = {s: sum(1 for g in order if g["surface"] == s) for s in surfaces}
    thin = [s for s in surfaces if per_surface[s] < folds]
    total = sum(g["rallies"] for g in order)
    facts = {"folds": folds, "groups": len(order), "groupsPerSurface": per_surface, "rallies": total,
             "seed": seed, "stratify": stratify, "maxShuffles": max_shuffles}
    problems = []
    if folds < MIN_FOLDS:
        problems.append(f"at least {MIN_FOLDS} folds are needed: the nested protocol holds one fold out, chooses on a second "
                        "and trains on the rest")
    if len(order) < folds:
        problems.append(f"{len(order)} group(s) cannot fill {folds} folds")
    if thin and stratify == "every-fold":
        problems.append("a surface with fewer groups than folds cannot be in every fold: "
                        + ", ".join(f"{s} has {per_surface[s]}" for s in thin)
                        + f" (of {folds} needed); --stratify where-feasible spreads it over the folds it can reach, "
                          "which is an amendment of the preregistration's §2")
    if problems:
        raise FoldsError("; ".join(problems), {**facts, "infeasible": problems})
    required = [s for s in surfaces if s not in thin]
    rng = random.Random(seed)
    closest = None
    for attempt in range(1, max_shuffles + 1):
        rng.shuffle(order)
        assignment = _deal(order, surfaces, folds)
        rallies = _rallies_per_fold(order, assignment, folds)
        held = [{g["surface"] for g in order if assignment[g["groupId"]] == f} for f in range(folds)]
        stratified = all(s in held[f] for f in range(folds) for s in required)
        # |rallies − mean| ≤ 25 % of the mean, in integers: mean = total / folds.
        deviation = max(abs(r * folds - total) for r in rallies)
        balanced = deviation * 4 <= total
        if stratified and balanced:
            return {"assignment": assignment, "shuffle": attempt, "surfacesNotInEveryFold": thin}
        if stratified and (closest is None or deviation < closest[0]):
            closest = (deviation, attempt, rallies)
    why = (f"no deal within {max_shuffles} shuffles keeps every fold's rally count within "
           f"{round(BALANCE_TOLERANCE * 100)} % of the mean ({total / folds:.1f})")
    report = {**facts, "infeasible": [why]}
    if closest:
        report["closestAttempt"] = {"shuffle": closest[1], "ralliesPerFold": closest[2],
                                    "largestDeviationFromMean": round(closest[0] / folds / (total / folds), 4) if total else None}
    raise FoldsError(why, report)


def label_seconds(steps: list) -> dict:
    """Step time by label state: each step stands for the time since the previous step of its segment."""
    out = {name: 0.0 for name in v.STATES}
    prev = None
    for s in steps:
        if prev is not None and prev["seg"] == s["seg"]:
            out[v.STATE_NAMES[s["y"]]] += s["t"] - prev["t"]
        prev = s
    return out


def _tally(recs: list, seconds: dict) -> dict:
    return {"recordings": sorted(r["recordingId"] for r in recs),
            "rallies": sum(len(r["rallies"]) for r in recs),
            "positiveSec": round(sum(sum(seconds[r["recordingId"]][v.STATE_NAMES[y]] for y in POSITIVE) for r in recs), 3),
            "validNegativeSec": round(sum(sum(seconds[r["recordingId"]][v.STATE_NAMES[y]] for y in NEGATIVE) for r in recs), 3)}


def report(dataset_dir: str, manifest: dict, groups: list, assignment: dict, folds: int) -> dict:
    """The per-fold counts and the readiness numbers. Reads every steps file once."""
    recs = manifest["recordings"]
    seconds = {r["recordingId"]: label_seconds(v.read_steps(dataset_dir, r)) for r in recs}
    negatives = {g["groupId"]: sum(seconds[rid][v.STATE_NAMES[y]] for rid in g["recordings"] for y in NEGATIVE) for g in groups}
    per_fold = []
    for f in range(folds):
        inside = [r for r in recs if assignment[r["groupId"]] == f]
        in_groups = [g for g in groups if assignment[g["groupId"]] == f]
        per_fold.append({
            "fold": f, "groups": len(in_groups), "groupIds": [g["groupId"] for g in in_groups],
            "surfaces": {s: sum(1 for g in in_groups if g["surface"] == s) for s in sorted({g["surface"] for g in groups})},
            "all": _tally(inside, seconds),
            "standard": _tally([r for r in inside if not r["restrictedUse"]], seconds),
            "restricted": _tally([r for r in inside if r["restrictedUse"]], seconds),
            "groupsWithValidNegatives": sum(1 for g in in_groups if negatives[g["groupId"]] > 0),
        })
    with_negatives = sum(1 for g in groups if negatives[g["groupId"]] > 0)
    fraction = with_negatives / len(groups)
    return {
        "perFold": per_fold,
        "totals": {"groups": len(groups), **_tally(recs, seconds),
                   "restrictedRecordings": sorted(r["recordingId"] for r in recs if r["restrictedUse"])},
        "negativeCoverage": {
            "groupsWithValidNegatives": with_negatives, "groups": len(groups), "fraction": round(fraction, 4),
            "groupsWithoutValidNegatives": [g["groupId"] for g in groups if negatives[g["groupId"]] <= 0],
            "preregistrationG6": f"at least {G6_COUNT} of the {G6_OF} groups contribute negatives (stated for the groups of 2026-11-03)",
            "countAtLeast12": with_negatives >= G6_COUNT,
            "fractionAtLeast12Of18": with_negatives * G6_OF >= G6_COUNT * len(groups),
            "foldsWithoutValidNegatives": [p["fold"] for p in per_fold if p["all"]["validNegativeSec"] <= 0],
        },
        "mixedSurfaceGroups": [g["groupId"] for g in groups if len(g["surfaces"]) > 1],
    }


def build(dataset_dir: str, folds: int = DEFAULT_FOLDS, seed: int = DEFAULT_SEED, stratify: str = "every-fold",
          max_shuffles: int = DEFAULT_MAX_SHUFFLES) -> dict:
    """The folds document for a dataset (not written). Raises FoldsError when the folds are infeasible."""
    manifest = v.load_manifest(dataset_dir)
    groups = groups_of(manifest)
    drawn = draw(groups, folds, seed, stratify, max_shuffles)
    assignment = drawn["assignment"]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "createdAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "dataset": v.dataset_identity(dataset_dir),
        "procedure": PROCEDURE, "seed": seed, "folds": folds, "stratify": stratify, "maxShuffles": max_shuffles,
        "balanceTolerance": BALANCE_TOLERANCE, "shuffle": drawn["shuffle"],
        "surfacesNotInEveryFold": drawn["surfacesNotInEveryFold"],
        "groups": [{"groupId": g["groupId"], "firstRecording": g["firstRecording"], "surface": g["surface"],
                    "fold": assignment[g["groupId"]], "recordings": g["recordings"]} for g in groups],
        "recordings": {rid: assignment[g["groupId"]] for g in groups for rid in g["recordings"]},
        "report": report(dataset_dir, manifest, groups, assignment, folds),
    }


def load(path: str, dataset_dir: str) -> dict:
    """Read a folds file for use with `dataset_dir`. Refuses (FoldsError) a file drawn for another dataset — the
    folder name, the manifest SHA-256 and the digest must all be this dataset's — and one whose assignment is not
    what its recorded seed and procedure draw from this dataset's groups. Never writes."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        raise FoldsError(f"folds file unreadable: {e}")
    if not isinstance(doc, dict) or doc.get("schemaVersion") != SCHEMA_VERSION or doc.get("procedure") != PROCEDURE:
        raise FoldsError(f"folds file is not {SCHEMA_VERSION} / {PROCEDURE}")
    identity = v.dataset_identity(dataset_dir)
    theirs = doc.get("dataset")
    if theirs != identity:
        differing = [k for k in identity if not isinstance(theirs, dict) or theirs.get(k) != identity[k]]
        raise FoldsError(f"the folds file was drawn for another dataset ({', '.join(differing)} differ): "
                         f"it names {theirs}, this dataset is {identity}")
    try:
        groups = groups_of(v.load_manifest(dataset_dir))
        drawn = draw(groups, doc["folds"], doc["seed"], doc["stratify"], doc["maxShuffles"])
        expected = {rid: drawn["assignment"][g["groupId"]] for g in groups for rid in g["recordings"]}
        recorded_groups = {g["groupId"]: g["fold"] for g in doc["groups"]}
    except (KeyError, TypeError) as e:
        raise FoldsError(f"folds file is missing a field: {e}")
    if doc["recordings"] != expected or recorded_groups != drawn["assignment"] or doc["shuffle"] != drawn["shuffle"]:
        raise FoldsError(f"the folds file's assignment is not what seed {doc['seed']} draws for this dataset under {PROCEDURE}: "
                         "it was edited after it was written")
    return doc


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dataset", help="the dataset folder")
    ap.add_argument("--out", required=True, help="the folds file to write (must not exist)")
    ap.add_argument("--folds", type=int, default=DEFAULT_FOLDS)
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    ap.add_argument("--stratify", choices=STRATIFY, default="every-fold")
    ap.add_argument("--max-shuffles", type=int, default=DEFAULT_MAX_SHUFFLES)
    ap.add_argument("--withheld", help="the external withheld-closure file, passed to the validator")
    args = ap.parse_args(argv)
    if os.path.exists(args.out):
        print(f"refused: {args.out} exists; a folds file is never overwritten", file=sys.stderr)
        return 1
    validation = v.validate(args.dataset, args.withheld)
    if not validation.ok:
        for e in validation.errors:
            print(f"error: {e}", file=sys.stderr)
        print(f"refused: the dataset does not validate ({len(validation.errors)} error(s)); no folds drawn", file=sys.stderr)
        return 1
    try:
        doc = build(args.dataset, args.folds, args.seed, args.stratify, args.max_shuffles)
    except FoldsError as e:
        print(json.dumps(e.report, indent=1))
        print(f"infeasible: {e}. Nothing written; the protocol needs an amended preregistration.", file=sys.stderr)
        return 1
    with open(args.out, "x", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1)
        fh.write("\n")
    cover = doc["report"]["negativeCoverage"]
    print(f"wrote {args.out}: {doc['folds']} folds of {len(doc['groups'])} groups for {doc['dataset']['name']} "
          f"(digest {doc['dataset']['digest'][:16]}…), seed {doc['seed']}, shuffle {doc['shuffle']}")
    for p in doc["report"]["perFold"]:
        print(f"  fold {p['fold']}: {p['groups']} groups {p['surfaces']}, {len(p['all']['recordings'])} recordings "
              f"({len(p['restricted']['recordings'])} restricted), {p['all']['rallies']} rallies, "
              f"{p['all']['positiveSec']} s positive, {p['all']['validNegativeSec']} s valid negative")
    print(f"  groups with valid negatives: {cover['groupsWithValidNegatives']} of {cover['groups']} ({cover['fraction']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
