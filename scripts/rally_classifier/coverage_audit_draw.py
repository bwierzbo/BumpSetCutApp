#!/usr/bin/env python3
"""Draw the negative-coverage audit's sample (docs/ml-roadmap/RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md §4).

Reads the inventory (`coverage_audit_inventory_v2`, written by coverage_audit_inventory.py from metadata only) and
writes the frozen draw (`coverage_audit_draw_v2`) to `<out dir>/<stamp>-draw.json` before anyone opens a video.

The pilot — procedure `coverage_draw_v2`, every number fixed by the protocol and none of them a flag:

1. One generator, `random.Random(20261114)`. It is only ever asked for `random()`, the one method Python
   guarantees to reproduce for a seed across versions: a list is put in the order of one `random()` key per element.
2. The dataset's surfaces in alphabetical order. For each: the recording groups with an eligible recording on that
   surface (and not already drawn from), sorted by group id, put in drawn order; the first four are the surface's
   groups. With fewer than four, every one of them is taken and the draw says so (`whereFeasible`) — "four per
   surface where feasible". Then, for each of those groups in group-id order, its eligible recordings on the
   surface, sorted by recording id, are put in drawn order and the first is the group's recording. No group ever
   gives two.
3. The blind-repeat set: for each drawn recording in (surface, recording id) order, its interval indices put in
   drawn order; the first max(2, ⌈n/5⌉) of them (all when it has fewer than two).

Refused, and nothing written: an inventory that carries no withheld closure; any recording in it that is withheld by
name, sourceId, card or content fingerprint or alias group, or that is not a continuous recording with standard
full-video negatives; a protocol document that is not frozen, not committed or changed since its commit; an existing
draw file; a second draw of the same stage for the same dataset without `--reason`.

Stage 2 (`--stage2 --follows <pilot draw> --project <dir>`) lists every eligible recording the pilot did not draw,
every interval, with its own repeat set — from a fresh inventory, since marks may have changed. It is written only
when the pilot it follows has passed (coverage_audit_report.py evaluates the audit records; a claim is not enough).

    python3 scripts/rally_classifier/coverage_audit_draw.py <inventory.json> --out-dir <project>/manifests/coverage-audit
        [--reason "<why another draw>"]
    python3 scripts/rally_classifier/coverage_audit_draw.py <inventory.json> --out-dir <dir> --stage2
        --follows <pilot draw.json> --project <project dir>

Exit status 0 when the draw was written, 1 otherwise. Reads the inventory, the protocol document and — for stage 2 —
the pilot draw and its audit records; never a video. Standard library only.
"""

from __future__ import annotations

import argparse
import datetime
import glob
import os
import random
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import coverage_audit_inventory as inv  # noqa: E402
import coverage_audit_report as report  # noqa: E402
import validate_dataset as v  # noqa: E402

PROCEDURE = "coverage_draw_v2"
SEED = 20261114
PER_SURFACE = 4
REPEAT_ONE_IN = 5       # a fifth of each recording's intervals is reviewed again…
REPEAT_MIN = 2          # …and never fewer than two
PROTOCOL = os.path.normpath(os.path.join(_HERE, "..", "..", "docs", "ml-roadmap", "RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md"))


# ----------------------------------------------------------------------------- the protocol the draw is bound to

def _git(cwd: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


def protocol_identity(path: str) -> dict:
    """The protocol document a draw is bound to: its SHA-256 and the commit it is at. Refused unless its frontmatter
    status starts with `frozen` and the file is committed and unchanged since — a draw bound to a text that can
    still move is bound to nothing."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError as e:
        raise inv.AuditError(f"protocol document unreadable: {e}")
    front = lines[1:lines.index("---", 1)] if lines[:1] == ["---"] and "---" in lines[1:] else []
    status = next((line.split(":", 1)[1].strip() for line in front if line.startswith("status:")), "")
    if not status.startswith("frozen"):
        raise inv.AuditError(f"the protocol document is not frozen (status: {status or 'none'}): nothing is drawn from a protocol that can still change")
    folder = os.path.dirname(os.path.abspath(path))
    top = _git(folder, "rev-parse", "--show-toplevel")
    if top.returncode != 0:
        raise inv.AuditError(f"the protocol document is not in a git repository: {top.stderr.strip()}")
    relative = os.path.relpath(os.path.realpath(path), os.path.realpath(top.stdout.strip()))
    if _git(top.stdout.strip(), "ls-files", "--error-unmatch", relative).returncode != 0 \
            or _git(top.stdout.strip(), "diff", "--quiet", "HEAD", "--", relative).returncode != 0:
        raise inv.AuditError("the protocol document is not committed, or differs from its committed text: commit it before drawing")
    return {"path": relative.replace(os.sep, "/"), "sha256": v.sha256_file(path),
            "gitCommit": _git(top.stdout.strip(), "rev-parse", "HEAD").stdout.strip()}


# ----------------------------------------------------------------------------- the draw

def ranked(items: list, rng: random.Random) -> list:
    """`items` in drawn order: one `rng.random()` key per element, taken in the order given."""
    return [item for _, item in sorted(((rng.random(), item) for item in items), key=lambda pair: pair[0])]


def draw_pilot(recordings: list, surfaces: list, per_surface: int, rng: random.Random) -> tuple[list, list]:
    """(the drawn recordings, what was feasible per surface). `per_surface` recordings per surface, one per recording
    group; a surface with fewer groups gives one from each and is reported, never two from a group."""
    picked, used, feasible = [], set(), []
    for surface in surfaces:
        by_group: dict = {}
        for rec in sorted(recordings, key=lambda r: r["recordingId"]):
            if rec["surface"] == surface and rec["groupId"] not in used:
                by_group.setdefault(rec["groupId"], []).append(rec)
        groups = sorted(ranked(sorted(by_group), rng)[:per_surface])
        picked += [ranked(by_group[g], rng)[0] for g in groups]
        used.update(groups)
        short = len(groups) < per_surface
        feasible.append({"surface": surface, "eligibleGroups": len(by_group), "drawn": len(groups), "asPlanned": not short,
                         "note": (f"{len(by_group)} eligible recording group(s), fewer than {per_surface}: one recording from each "
                                  f"({per_surface} per surface where feasible; never two from one group)") if short else
                                 f"{per_surface} of {len(by_group)} eligible recording group(s), one recording from each"})
    return sorted(picked, key=lambda r: (r["surface"], r["recordingId"])), feasible


def draw_repeat(intervals: list, rng: random.Random, one_in: int = REPEAT_ONE_IN, minimum: int = REPEAT_MIN) -> list:
    """The interval indices reviewed a second time: ⌈n / one_in⌉ of them, at least `minimum`, all when there are fewer."""
    indices = [iv["index"] for iv in intervals]
    count = min(len(indices), max(minimum, -(-len(indices) // one_in)))
    return sorted(ranked(indices, rng)[:count])


def _drawn(rec: dict, rng: random.Random) -> dict:
    keep = ("recordingId", "groupId", "surface", "split", "fold", "camera", "durationTicks", "fingerprint", "contentFingerprint",
            "sourceId", "marksSha256", "marksChangedSinceExport", "rallyMarks", "intervals")
    return {**{k: rec[k] for k in keep}, "repeatIndices": draw_repeat(rec["intervals"], rng)}


def _document(inventory: dict, inventory_path: str, protocol: dict, stage: str, seed: int, picked: list, rng: random.Random, now: str | None,
              in_pilot: frozenset = frozenset()) -> dict:
    """The draw's bindings — dataset, folds, inventory, split manifest, closure, protocol — and its recordings.
    `notDrawn` is every eligible recording that is neither in this draw nor (`in_pilot`) in the pilot it follows."""
    created = now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    withheld = inventory["withheld"]
    drawn_ids = {r["recordingId"] for r in picked} | in_pilot
    recordings = [_drawn(rec, rng) for rec in picked]
    return {
        "schemaVersion": report.DRAW_VERSION, "procedure": PROCEDURE, "stage": stage,
        "drawId": created.replace("-", "").replace(":", "").replace("T", "-").rstrip("Z"), "createdAt": created,
        "seed": seed, "repeatOneIn": REPEAT_ONE_IN, "repeatMin": REPEAT_MIN,
        "everyIntervalReviewed": True,
        "protocol": protocol,
        "project": inventory["project"], "dataset": inventory["dataset"], "folds": inventory["folds"],
        "inventory": {"sha256": v.sha256_file(inventory_path), "createdAt": inventory["createdAt"]},
        "splitManifest": inventory["splitManifest"],
        "withheld": {"closureSha256": withheld["closureSha256"], "closureFileSha256": withheld["closureFileSha256"],
                     **{k: len(withheld[k]) for k in ("names", "sourceIds", "fingerprints", "aliasGroups")}},
        "recordings": recordings,
        "notDrawn": [{"recordingId": r["recordingId"], "groupId": r["groupId"], "surface": r["surface"], "split": r["split"],
                      "fold": r["fold"], "intervals": len(r["intervals"]), "unmarkedSec": round(r["unmarkedTicks"] / v.TIMESCALE, 3)}
                     for r in inventory["recordings"] if r["recordingId"] not in drawn_ids],
        "leftOut": inventory["leftOut"],
        "totals": {**inv.totals(picked, inventory["dataset"]["surfaces"]), "repeatIntervals": sum(len(r["repeatIndices"]) for r in recordings)},
    }


def build_pilot(inventory_path: str, protocol_path: str = PROTOCOL, seed: int = SEED, per_surface: int = PER_SURFACE,
                now: str | None = None) -> dict:
    """The pilot draw (not written)."""
    inventory = inv.load_inventory(inventory_path)
    protocol = protocol_identity(protocol_path)
    rng = random.Random(seed)
    picked, feasible = draw_pilot(inventory["recordings"], inventory["dataset"]["surfaces"], per_surface, rng)
    draw = _document(inventory, inventory_path, protocol, "pilot", seed, picked, rng, now)
    n = draw["totals"]["rallyMarks"]
    return {**draw, "follows": None, "perSurface": per_surface, "whereFeasible": feasible,
            "criterion": {"n": n, "confidence": report.CONFIDENCE, "maxUpperBound": report.MAX_UPPER_BOUND,
                          "largestPassingM": report.largest_passing_m(n) if n else None,
                          "maxPerRecording": report.MAX_MISSED_PER_RECORDING}}


def build_stage2(inventory_path: str, pilot_path: str, project_dir: str, protocol_path: str = PROTOCOL, now: str | None = None) -> dict:
    """The stage 2 listing (not written): every eligible recording of a fresh inventory that the pilot did not draw.
    Refused unless the pilot it follows is of the same dataset, folds and protocol and has passed."""
    inventory = inv.load_inventory(inventory_path)
    pilot, pilot_sha = report.read_draw(pilot_path)
    if pilot["stage"] != "pilot":
        raise inv.AuditError(f"{pilot_path}: stage 2 follows a pilot draw (this one is {pilot['stage']})")
    protocol = protocol_identity(protocol_path)
    for label, ours, theirs in (("dataset", inventory["dataset"], pilot["dataset"]), ("folds file", inventory["folds"]["sha256"], pilot["folds"]["sha256"]),
                                ("protocol document", protocol["sha256"], pilot["protocol"]["sha256"])):
        if ours != theirs:
            raise inv.AuditError(f"the {label} is not the one the pilot was drawn for: stage 2 follows its pilot on the same dataset, folds and protocol")
    outcome = report.evaluate(pilot_path, project_dir)["pilot"]
    if outcome["outcome"] != "pass":
        raise inv.AuditError(f"stage 2 is entered only when the pilot passes; pilot {pilot['drawId']} is {outcome['outcome']}")
    in_pilot = frozenset(r["recordingId"] for r in pilot["recordings"])
    remaining = sorted((r for r in inventory["recordings"] if r["recordingId"] not in in_pilot), key=lambda r: (r["surface"], r["recordingId"]))
    if not remaining:
        raise inv.AuditError("no eligible recording remains after the pilot")
    draw = _document(inventory, inventory_path, protocol, "stage2", pilot["seed"], remaining, random.Random(pilot["seed"]), now, in_pilot)
    return {**draw, "follows": {"drawId": pilot["drawId"], "sha256": pilot_sha}, "inPilot": sorted(in_pilot),
            "pilot": {k: outcome[k] for k in ("outcome", "m", "n", "upperBound")}}


def write_draw(draw: dict, out_dir: str, reason: str | None = None) -> str:
    """Write the draw to `<out dir>/<drawId>-draw.json`, once. A draw of the same stage for the same dataset already
    in the folder is superseded only with a stated reason, recorded with the draws it supersedes."""
    earlier = []
    for path in sorted(glob.glob(os.path.join(out_dir, "*-draw.json"))):
        other, _ = report.read_draw(path)
        if other["stage"] == draw["stage"] and other["dataset"]["manifestSha256"] == draw["dataset"]["manifestSha256"]:
            earlier.append(other["drawId"])
    if earlier and not (reason and reason.strip()):
        raise inv.AuditError(f"{out_dir} already holds a {draw['stage']} draw for this dataset ({', '.join(earlier)}): "
                             "another one needs --reason, and is a new file beside it")
    path = os.path.join(out_dir, f"{draw['drawId']}-draw.json")
    inv.write_new_json(path, {**draw, "reason": reason.strip() if reason else None, "supersedes": earlier})
    return path


# ----------------------------------------------------------------------------- CLI

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("inventory", help="the inventory JSON (coverage_audit_inventory_v2)")
    ap.add_argument("--out-dir", required=True, help="the folder the draw is written to, as <stamp>-draw.json")
    ap.add_argument("--protocol", default=PROTOCOL, help="the frozen protocol document the draw is bound to")
    ap.add_argument("--reason", help="why another draw of this stage is made for the same dataset")
    ap.add_argument("--stage2", action="store_true", help="list every eligible recording the pilot did not draw")
    ap.add_argument("--follows", help="with --stage2: the pilot draw it follows")
    ap.add_argument("--project", help="with --stage2: the project folder (the pilot's audit records are read through it)")
    args = ap.parse_args(argv)
    if args.stage2 != bool(args.follows) or args.stage2 != bool(args.project):
        ap.error("--stage2, --follows and --project go together")
    try:
        if args.stage2:
            draw = build_stage2(args.inventory, args.follows, args.project, args.protocol)
        else:
            draw = build_pilot(args.inventory, args.protocol)
        path = write_draw(draw, args.out_dir, args.reason)
    except inv.AuditError as e:
        print(f"error: {e}")
        return 1
    t = draw["totals"]
    print(f"wrote {path}: {draw['stage']} draw {draw['drawId']} of {draw['dataset']['name']} — {t['recordings']} recording(s) in "
          f"{t['groups']} group(s), {t['intervals']} interval(s) to review ({t['unmarkedSec']} s), {t['repeatIntervals']} in the repeat set, "
          f"{t['rallyMarks']} rally marks; {len(draw['notDrawn'])} eligible recording(s) not drawn")
    for row in draw.get("whereFeasible", []):
        print(f"  {row['surface']}: {row['note']}")
    if draw["stage"] == "pilot":
        c = draw["criterion"]
        print(f"  pass: the one-sided {c['confidence']:.0%} upper bound on m/n ≤ {c['maxUpperBound']:.0%} — for n = {c['n']} at most "
              f"m = {c['largestPassingM']} — and no recording with more than {c['maxPerRecording']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
