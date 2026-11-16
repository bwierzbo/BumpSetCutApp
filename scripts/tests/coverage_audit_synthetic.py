"""A synthetic project, dataset, closure, folds file and frozen protocol for the coverage-audit tests, and audit
records written the way the review surface writes them. Nothing real is read; the "videos" the sessions name are
never created, so a tool that opened one would fail. Not a test module (its name does not start with `test`).
"""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rally_classifier"))
import coverage_audit_inventory as inv  # noqa: E402
import coverage_audit_report as report  # noqa: E402
import validate_dataset as v  # noqa: E402

RALLIES = 12        # rally marks per synthetic recording: 12 drawn recordings give n = 144
INTERVALS = 14      # …and each recording has 14 unmarked intervals (3 of them in its repeat set)


def marks(rallies: int = RALLIES) -> list:
    """`rallies` four-second rallies eight seconds apart from 0:05 (every other one a mark from before live tagging,
    with no kind), then a missed serve: unmarked edges at both ends and a gap between every two marks."""
    out = [{"startTime": 5.0 + 8 * i, "endTime": 9.0 + 8 * i, **({"kind": "rally"} if i % 2 else {})} for i in range(rallies)]
    return out + [{"startTime": 8.0 * rallies + 4, "endTime": 8.0 * rallies + 6, "kind": "missedServe"}]


def spec(rid, surface, group, kind="continuous", split="train", rallies=RALLIES):
    return {"rid": rid, "surface": surface, "group": group, "type": kind, "split": split,
            "marks": marks(rallies), "cuts": [], "duration": 8.0 * RALLIES + 14}


def corpus() -> list:
    """The shape of rc-v1-20261112 in small: beach 4 groups (one of two eligible recordings and an edited one), grass
    6, indoor 8, and an edited recording that is a group of its own — 24 recordings, 22 eligible, 19 groups."""
    specs = [spec("bch_a", "beach", "g-bch_a"), spec("bch_a_v2", "beach", "g-bch_a"), spec("bch_a_edit", "beach", "g-bch_a", kind="edited", rallies=1)]
    specs += [spec(f"bch_{c}", "beach", f"g-bch_{c}") for c in "bcd"]
    specs += [spec("grs_a", "grass", "g-grs_a", split="tune"), spec("grs_a_v2", "grass", "g-grs_a", split="tune")]
    specs += [spec(f"grs_{c}", "grass", f"g-grs_{c}") for c in "bcdef"]
    specs += [spec("ind_a", "indoor", "g-ind_a", split="dev_val"), spec("ind_a_v2", "indoor", "g-ind_a", split="dev_val"),
              spec("ind_a_v3", "indoor", "g-ind_a", split="dev_val")]
    specs += [spec(f"ind_{c}", "indoor", f"g-ind_{c}") for c in "bcdefgh"]
    return specs + [spec("grs_edit", "grass", "g-grs_edit", kind="edited")]


def write_json(path: str, doc) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1)


class Synthetic:
    """Everything the inventory reads, held in memory (`rows`, `cards`, `validation`, `closure`, `manifest`, `sessions`,
    `types`) and written by `save()`: a test changes what it needs and saves again."""

    def __init__(self, root: str, specs=None, folds: int = 5):
        self.root = root
        self.folds = folds
        self.project = os.path.join(root, "Project")
        self.dataset = os.path.join(root, "rc-synthetic")
        self.closure_path = os.path.join(root, "closure.json")
        self.folds_path = os.path.join(root, "folds.json")
        self.inventory_path = os.path.join(root, "inventory.json")
        self.specs = specs if specs is not None else corpus()
        names = ["withheld_01"]
        self.closure = {"names": names, "sourceIds": ["src:withheld_01"], "fingerprints": ["file:card-withheld_01", "file:content-withheld_01"]}
        self.validation = {"lineageHoldout": list(names)}
        self.rows = {"withheld_01": self.row("withheld_01", "lineage_holdout")}
        self.cards = {"withheld_01": self.card("withheld_01")}
        self.sessions, self.types, recordings = {}, {}, []
        for s in self.specs:
            rid = s["rid"]
            self.rows[rid] = self.row(rid, s["split"])
            self.cards[rid] = self.card(rid)
            self.sessions[rid] = {"name": rid, "ralliesMarked": True, "sourcePath": self.video(rid), "cuts": [{"start": a, "end": b} for a, b in s["cuts"]]}
            self.types[rid] = s["type"]
            write_json(self.marks_path(rid), s["marks"])
            spans = inv.truth_spans(inv.read_marks(self.marks_path(rid))[0], s["cuts"])
            continuous = s["type"] == "continuous"
            recordings.append({
                "recordingId": rid, "groupId": s["group"], "surface": s["surface"], "camera": "End line, elevated", "split": s["split"],
                "fold": None, "durationSec": s["duration"], "recordingType": s["type"], "restrictedUse": not continuous,
                "eligibility": {"rallyClassifier": "standard" if continuous else "restricted",
                                "fullVideoNegatives": "standard" if continuous else "restricted", "reasons": []},
                "fingerprint": f"file:card-{rid}", "sourceId": f"src:{rid}", **spans,
                "labelProvenance": {"method": "legacy_declared", "marksSha256": v.sha256_file(self.marks_path(rid))}})
        self.manifest = {"schemaVersion": v.SCHEMA_VERSION, "timescale": v.TIMESCALE, "project": "Synthetic",
                         "labelSchema": v.label_schema(0.5), "splitManifest": {}, "withheld": {}, "recordings": recordings}
        self.save()
        self.manifest["splitManifest"] = dict(inv.current_hashes(self.project))
        self.save()

    def video(self, rid):
        return os.path.join(self.root, "footage", rid + ".mp4")

    def marks_path(self, rid):
        return inv.sidecar_path(self.video(rid), "rallylabels")

    def record_path(self, rid):
        return inv.sidecar_path(self.video(rid), "coverageaudit")

    @staticmethod
    def row(rid, split):
        return {"video": rid, "split": split, "aliasGroup": rid, "fingerprint": f"file:card-{rid}", "contentFingerprint": f"file:content-{rid}",
                "sourceId": {"origin": "confirmed", "value": f"src:{rid}"}, "sessionId": {"origin": "unknown"}, "venueId": {"origin": "unknown"}}

    @staticmethod
    def card(rid):
        return {"id": rid, "videos": [{"fingerprint": f"file:card-{rid}", "sourceId": f"src:{rid}", "origin": f"/somewhere/{rid}.mov"}]}

    def save(self):
        """Write every file from memory. The split manifest records project.json's and validation.json's hashes as
        they are written, so it is current unless a test edits one of them afterwards."""
        write_json(os.path.join(self.project, "project.json"), {"name": "Synthetic", "clips": list(self.cards.values())})
        write_json(os.path.join(self.project, "pipeline_tuning", "validation.json"), self.validation)
        for rid, session in self.sessions.items():
            write_json(os.path.join(self.project, "sessions", rid + ".json"), session)
            write_json(os.path.join(self.project, "footage-properties", rid + ".json"), {"video": rid, "recordingType": self.types[rid]})
        write_json(os.path.join(self.project, "manifests", "manifest.json"),
                   {"hashes": {"projectJson": v.sha256_file(os.path.join(self.project, "project.json")),
                               "validationJson": v.sha256_file(os.path.join(self.project, "pipeline_tuning", "validation.json"))},
                    "videos": list(self.rows.values())})
        closure = {**self.closure, "closureSha256": inv.wc.closure_sha256(self.closure)}
        write_json(self.closure_path, closure)
        self.manifest["withheld"] = closure
        write_json(os.path.join(self.dataset, "dataset-manifest.json"), self.manifest)
        # The frozen folds file as folds.py writes it (without the per-fold report, which reads steps files).
        folds, groups = inv.fold_draw, inv.fold_draw.groups_of(self.manifest)
        args = {"folds": self.folds, "seed": folds.DEFAULT_SEED, "stratify": "where-feasible", "maxShuffles": folds.DEFAULT_MAX_SHUFFLES}
        drawn = folds.draw(groups, args["folds"], args["seed"], args["stratify"], args["maxShuffles"])
        self.fold = {rid: drawn["assignment"][g["groupId"]] for g in groups for rid in g["recordings"]}
        write_json(self.folds_path, {"schemaVersion": folds.SCHEMA_VERSION, "procedure": folds.PROCEDURE, **args, "shuffle": drawn["shuffle"],
                                     "dataset": v.dataset_identity(self.dataset), "recordings": self.fold,
                                     "groups": [{"groupId": g["groupId"], "fold": drawn["assignment"][g["groupId"]]} for g in groups]})

    def build(self) -> dict:
        return inv.build_inventory(self.dataset, self.project, self.closure_path, self.folds_path, now="2026-11-14T00:00:00Z")

    def write_inventory(self, mutate=None) -> str:
        """Write the inventory file (replacing an earlier one), after `mutate(inventory)` when a test tampers with it."""
        doc = self.build()
        if mutate:
            mutate(doc)
        write_json(self.inventory_path, doc)
        return self.inventory_path


def protocol_repo(root: str, status: str = "frozen 2026-11-14 on the owner's authorisation; pilot not yet reviewed") -> str:
    """A git repository holding a committed protocol document with the given frontmatter status; returns its path."""
    repo = os.path.join(root, "repo")
    os.makedirs(repo)
    path = os.path.join(repo, "PROTOCOL.md")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"---\nname: synthetic-protocol\nstatus: {status}\n---\n\n# Synthetic protocol\n")
    for args in (["init", "-q"], ["add", "PROTOCOL.md"],
                 ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "protocol"]):
        subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)
    return path


def write_records(syn: Synthetic, draw_path: str, findings=None, repeat="second_reviewer", repeat_findings=None, resolutions=None,
                  skip=(), first_at="2026-11-15T10:00:00Z", repeat_at="2026-11-17T10:00:00Z", **overrides) -> None:
    """One audit record per drawn recording, as the review surface writes it. Every interval is `clean` unless
    `findings[recordingId][index]` lists findings; the repeat set (the draw's, plus every interval first left
    `uncertain`) repeats the first verdict unless `repeat_findings` says otherwise; `repeat=None` leaves the repeat
    out; `resolutions[recordingId][index]` lists the resolved findings; `skip` names recordings with no record."""
    draw, draw_sha = report.read_draw(draw_path)

    def verdict(found):
        return {"verdict": "not_clean", "findings": found, "playedAllAtMaxRate": 2.0} if found else {"verdict": "clean", "playedAllAtMaxRate": 2.0}

    for rec in draw["recordings"]:
        rid = rec["recordingId"]
        if rid in skip:
            continue
        mine = (findings or {}).get(rid, {})
        again = (repeat_findings or {}).get(rid, {})
        record = {"annotationVersion": report.RECORD_VERSION, "recordingId": rid, "sourceFingerprint": rec["contentFingerprint"],
                  "drawId": draw["drawId"], "drawSha256": draw_sha, "datasetName": draw["dataset"]["name"], "marksSha256": rec["marksSha256"],
                  "timescale": v.TIMESCALE, "blindToPipeline": True, "tool": "RallyLab synthetic",
                  "intervals": [{"index": iv["index"], "startTick": iv["startTick"], "endTick": iv["endTick"], "reviewer": "owner",
                                 "reviewedAt": first_at, **verdict(mine.get(iv["index"]))} for iv in rec["intervals"]],
                  "resolutions": [{"index": i, "reviewer": "owner", "resolvedAt": "2026-11-18T10:00:00Z", "note": "third look", **verdict(found)}
                                  for i, found in (resolutions or {}).get(rid, {}).items()]}
        if repeat:
            wanted = set(rec["repeatIndices"]) | {i for i, found in mine.items() if any(f["kind"] == "uncertain" for f in found)} | set(again)
            record["repeat"] = {"method": repeat, "intervals": [
                {"index": i, "reviewer": "owner" if repeat == "same_reviewer_after_24h" else "second", "reviewedAt": repeat_at,
                 **verdict(again.get(i, mine.get(i)))} for i in sorted(wanted)]}
        record.update(overrides)
        write_json(syn.record_path(rid), record)
