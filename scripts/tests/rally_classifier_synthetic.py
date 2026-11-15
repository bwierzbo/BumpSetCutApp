"""A synthetic rally-classifier dataset large enough for five grouped folds, written with the validator's own
builder (`validate_dataset.write_synthetic`), and the files a trainer run needs beside it. Shared by the
`test_rally_classifier_*` suites; nothing here touches a real recording.

Where its negatives' trust comes from is the `trust` argument of `write` (the adopted gate G7,
`trusted_negatives.py`):

- `"stage1"` (the default) — label schema v1, every continuous recording with Stage 1 verified coverage: all its
  negatives are trusted, so a run may start;
- `"declared"` — label schema v1, declared-complete recordings (one keeps Stage 1 coverage): the shape of
  `rc-v1-20261112`, negatives declared and not audited;
- `"audited"` — label schema `rally_activity_truth_v2`: the declared dataset with a coverage-audit record per
  recording (`coverage.audit`), and `NON_RALLY` kept only inside its reviewed-clean intervals; `unaudited` names
  groups that were never audited, and one recording has an interval that was not clean.

The validator on this branch reads label schema v1 only — the v2 rule is the exporter change's. `reading_v2` runs
the real validator with the schema's name and its label rule swapped for the adopted one, so a v2 dataset built
here is still checked file by file (hashes, counts, labels against the rule).
"""

import contextlib
import hashlib
import json
import os
import sys
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rally_classifier"))
import trusted_negatives as tn  # noqa: E402
import validate_dataset as v  # noqa: E402

SURFACES = ("beach", "grass", "indoor")
RALLIES = [[(4, 11), (18, 27), (36, 44)], [(6, 13), (22, 31)], [(5, 10), (16, 24), (30, 37), (45, 53)], [(8, 17), (26, 35), (44, 52)]]
HANDHELD = {"syn_bea_01": "Handheld / corner", "syn_gra_02": "Handheld / corner"}     # one restricted (edited), one standard
MATCHED = "r0_no_net_rule"
NOT_CLEAN = "syn_ind_03"        # under trust="audited": its second unmarked interval was reviewed and is not clean
TRUST = ("stage1", "declared", "audited")
_V1_RULE = v.expected_state


def v2_rule(tick: int, rec: dict, ignore_ticks: int) -> int:
    """The label rule of `rally_activity_truth_v2` as adopted (audit spec D7): the v1 state, except that NON_RALLY
    outside the recording's trusted time is UNKNOWN."""
    state = _V1_RULE(tick, rec, ignore_ticks)
    if state == v.STATES["NON_RALLY"] and not tn.inside(tick, tn.trusted_time(rec, True)[1]):
        return v.STATES["UNKNOWN"]
    return state


def specs(groups_per_surface: int = 5, trust: str = "stage1") -> list:
    """`groups_per_surface` groups on each surface; some hold a second recording, one recording is restricted
    (edited, no negatives), one has a missed serve, one a cut and a frame gap, one a replay span, one no net (and
    Stage 1 coverage with a non-rally-activity span, whatever `trust` is)."""
    out = []
    for si, surface in enumerate(SURFACES):
        for g in range(groups_per_surface):
            n = si * groups_per_surface + g
            rid, group = f"syn_{surface[:3]}_{g:02d}", f"g-{surface[:3]}-{g:02d}"
            spec = dict(rid=rid, group=group, split="train", fold=None, surface=surface, recording_type="continuous", negatives="standard",
                        coverage="stage1_complete" if trust == "stage1" else "declared_complete", rallies=RALLIES[n % len(RALLIES)])
            if n == 1:
                spec.update(recording_type="edited", negatives="restricted", restricted_reasons=["edited recording"])
            if n == 2:
                spec.update(rallies=[(4, 11), (36, 44)], excluded=[(20, 23, "missedServe")])
            if n == 3:
                spec.update(rallies=[(8, 17), (26, 35), (44, 52)], cuts=[(0, 3)], gap_at=20.0)
            if n == 4:
                spec.update(rallies=[(6, 13), (22, 31)], tb=[(50, 55, "replay", "proposed")])
            if n == 5:
                spec.update(net=False, coverage="stage1_complete", nra=[(14, 16)], short_pair=[(55.0, 56.5), (58.0, 59.5)])
            out.append(spec)
            if g == 0:          # a second recording of the same group
                out.append(dict(spec, rid=rid + "_v2", rallies=RALLIES[(n + 1) % len(RALLIES)]))
    return out


def write(folder: str, groups_per_surface: int = 5, seed: int = 7, name: str = "Synthetic-rally-classifier", trust: str = "stage1",
          unaudited: tuple = (), matched_baseline: bool = False) -> str:
    """Write the dataset under `folder` and return its path. `trust`: the module docstring; `unaudited`: group ids
    without an audit record (for `"audited"`); `matched_baseline`: also store the baseline variant `r0_no_net_rule`."""
    assert trust in TRUST, trust
    dataset = os.path.join(folder, name)
    v.write_synthetic(dataset, seed=seed, specs=specs(groups_per_surface, trust))
    manifest = v.load_manifest(dataset)
    for rec in manifest["recordings"]:
        rec["camera"] = HANDHELD.get(rec["recordingId"], rec["camera"])
    if matched_baseline:
        _add_matched_baseline(dataset, manifest)
    if trust == "audited":
        _audit(dataset, manifest, set(unaudited))
    save_manifest(dataset, manifest)
    return dataset


def save_manifest(dataset: str, manifest: dict):
    with open(os.path.join(dataset, "dataset-manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1)


def unmarked_intervals(rec: dict) -> list:
    """The maximal intervals of [0, duration) that no rally, excluded span, cut range or time-breaking span covers —
    the coverage audit's unit — as [(startTick, endTick)]."""
    marks = sorted((s["startTick"], s["endTick"]) for key in ("rallies", "excludedSpans", "cutRanges", "timeBreakingSpans") for s in rec[key])
    out, at = [], 0
    for a, b in marks + [(round(rec["durationSec"] * v.TIMESCALE), None)]:
        if a > at:
            out.append((at, a))
        at = max(at, b or a)
    return out


def _audit(dataset: str, manifest: dict, unaudited: set):
    """Turn the declared dataset into an audited one (label schema v2): an audit record per recording that
    supplies negatives by declaration, and NON_RALLY kept only in trusted time."""
    manifest["labelSchema"]["version"] = tn.AUDITED_LABELS
    for rec in manifest["recordings"]:
        declared = rec["eligibility"]["fullVideoNegatives"] == "standard" and rec["coverage"]["state"] == "declared_complete"
        rec["coverage"]["audit"] = None
        if declared and rec["groupId"] not in unaudited:
            spans = unmarked_intervals(rec)
            clean = [s for i, s in enumerate(spans) if not (rec["recordingId"] == NOT_CLEAN and i == 1)]
            rec["coverage"]["audit"] = {"state": "audited_clean" if len(clean) == len(spans) else "contaminated",
                                        "auditSha256": hashlib.sha256(f"audit:{rec['recordingId']}".encode()).hexdigest(),
                                        "drawId": "synthetic-draw", "cleanIntervals": [{"startTick": a, "endTick": b} for a, b in clean]}
        steps = v.read_steps(dataset, rec)
        for s in steps:
            s["y"] = v2_rule(s["tick"], rec, round(manifest["labelSchema"]["boundaryIgnoreSec"] * v.TIMESCALE))
            s["w"] = v.WEIGHTS[str(s["y"])]
        write_steps(dataset, rec, steps)


def write_steps(dataset: str, rec: dict, steps: list):
    """Rewrite a recording's steps file and bring its manifest record (hash, counts) in line."""
    path = os.path.join(dataset, rec["stepsFile"])
    with open(path, "w", encoding="utf-8") as fh:
        for s in steps:
            fh.write(json.dumps(s, separators=(",", ":")) + "\n")
    rec["stepsSha256"], rec["stepCount"] = v.sha256_file(path), len(steps)
    rec["labelCounts"] = {name: sum(1 for s in steps if s["y"] == code) for name, code in v.STATES.items()}


def _add_matched_baseline(dataset: str, manifest: dict):
    """Store `r0_no_net_rule`: r0's clips and, on a recording with a net and room for it, one more clip — the one
    the above-net rule removed. The extra clip stands more than r0's join apart from its neighbours, as a clip the
    rule drops does (the rule filters after the merge)."""
    r0 = next(var for var in manifest["baseline"]["variants"] if var["name"] == "r0")
    manifest["baseline"]["variants"].append({"name": MATCHED, "settings": dict(r0["settings"]),
                                             "configSha256": hashlib.sha256(b"synthetic:config:no-net-rule").hexdigest()})
    apart, pre, raw, post = 840, round(r0["settings"]["prerollSec"] * v.TIMESCALE), 1800, round(r0["settings"]["postrollSec"] * v.TIMESCALE)
    for rec in manifest["recordings"]:
        path = os.path.join(dataset, rec["baselineFile"])
        doc = read_json(path)
        clips, duration = doc["variants"]["r0"], round(rec["durationSec"] * v.TIMESCALE)
        removed = []
        if rec["net"] is not None:
            ends, starts = [0] + [c["endTick"] for c in clips], [c["startTick"] for c in clips] + [duration]
            for end, start in zip(ends, starts):
                a = end + apart + pre
                if a + raw + post + apart <= start:
                    (clip,) = v.pad_and_merge([(a, a + raw)], r0["settings"], duration)
                    removed = [{**clip, "serveContactTick": None}]
                    break
        doc["variants"][MATCHED] = sorted(clips + removed, key=lambda c: c["startTick"])
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=1)
        rec["baselineSha256"] = v.sha256_file(path)


@contextlib.contextmanager
def reading_v2():
    """The validator, reading label schema v2 (the module docstring)."""
    with mock.patch.object(v, "LABEL_VERSION", tn.AUDITED_LABELS), mock.patch.object(v, "expected_state", v2_rule):
        yield


def write_closure(folder: str, dataset: str) -> str:
    """The external withheld-closure file: the manifest's own closure, as the exporter would hand it over."""
    closure = v.load_manifest(dataset)["withheld"]
    path = os.path.join(folder, "closure.json")
    with open(path, "w") as fh:
        json.dump({k: closure[k] for k in ("names", "sourceIds", "fingerprints")}, fh)
    return path


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def read_json(path: str):
    return json.loads(read_text(path))
