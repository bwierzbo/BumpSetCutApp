#!/usr/bin/env python3
"""Protected content-lineage audit: one bounded, logged comparison of named withheld
recordings against the rest of a project, to find copies. Proposals only.

`audit.py` never decodes a withheld recording, and still does not: this is a separate
operation with its own entry point, not a flag on that tool. It exists because the owner
authorised one audit of the currently protected recordings "for the sole purpose of
duplicate-content identification" (2026-11-12, §6), after three lineage-holdout recordings
turned out to exist as train cards under other names (D-036).

What it does, and nothing else:

* reads a **scope file** that names every protected recording that may be opened, each with
  the reason, and the authorisation the run rests on. A protected recording that is not
  named is not opened. A name that is not protected, is not in the split manifest, or is
  final test, a final-test candidate or an alias of one, stops the run before anything is
  opened: those are outside what was authorised;
* writes a line to `access-log.jsonl` **before** it opens each protected file — which
  recording, why it is protected, why it is opened, when, with which configuration and which
  revision of this tool — and a second line with what was read (the file's SHA-256, the
  number of samples) or why the read failed. The log is appended to, never rewritten;
* turns each opened file into the same 8x8 grey-level motion signature `audit.py` uses and
  compares it with every recording the ordinary audit may read and with the other opened
  recordings;
* writes `protected-content-lineage-proposals.json`. Every relation has `status: proposed`.
  A person confirms an identity with RallyLab `--set-provenance`; this tool changes no
  project file and writes nothing under the project folder.

It runs no ball, net, player, pose or rally model, reads no rally marks or labels (only
`project.json`, `manifests/manifest.json` and `pipeline_tuning/validation.json`), and keeps
no picture: a signature is 64 grey levels per quarter second, reduced to motion masks.

Limits, as for `audit.py`: a mirrored, sped-up or slowed copy, a crop that is not about the
centre, an overlay covering most of the frame, and a stretch with no motion are not
recognised. "No relation proposed" is not "no copy exists".

    python3 scripts/content_lineage/protected_audit.py --project <dir> --scope <scope.json> --out <dir> --plan
    python3 scripts/content_lineage/protected_audit.py --project <dir> --scope <scope.json> --out <dir> \
        [--origin-project <dir>] [--signature-cache <dir>]

Scope file:

    {"authorization": "<the decision record and section>",
     "purpose": "duplicate-content identification",
     "recordings": [{"name": "<recording>", "reason": "<why it is opened>"}, ...]}
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audit  # noqa: E402

SCHEMA_VERSION = "protected_content_lineage_proposals_v1"
PURPOSE = "duplicate-content identification"
FINAL_SPLITS = {"final_test", "final_test_candidate"}
FINAL_KEYS = ("finalTest", "finalTestCandidates")
OPERATION = ("SHA-256 of the file; ffmpeg decode to 8x8 grey grids every 0.25 s, kept as motion masks and an average hash "
             "(no picture kept, no model run, no marks read)")


class ScopeError(Exception):
    pass


def load_scope(path: str) -> dict:
    with open(path) as f:
        scope = json.load(f)
    if not isinstance(scope, dict) or not str(scope.get("authorization") or "").strip():
        raise ScopeError("the scope file names no authorization")
    if scope.get("purpose") != PURPOSE:
        raise ScopeError(f'the scope file\'s purpose must be "{PURPOSE}": this tool does nothing else')
    rows = scope.get("recordings")
    if not isinstance(rows, list) or not rows:
        raise ScopeError("the scope file names no recording")
    seen = set()
    for row in rows:
        name = row.get("name") if isinstance(row, dict) else None
        if not name or not str(row.get("reason") or "").strip():
            raise ScopeError(f"every recording in the scope needs a name and a reason: {row!r}")
        if name in seen:
            raise ScopeError(f"{name} is in the scope twice")
        seen.add(name)
    return scope


def _read_project(project_dir: str) -> tuple[dict, dict, dict]:
    with open(os.path.join(project_dir, "manifests", "manifest.json")) as f:
        manifest = json.load(f)
    with open(os.path.join(project_dir, "project.json")) as f:
        project = json.load(f)
    validation: dict = {}
    path = os.path.join(project_dir, "pipeline_tuning", "validation.json")
    if os.path.exists(path):
        with open(path) as f:
            validation = json.load(f)
    return manifest, project, validation


def final_test_closure(project_dir: str) -> set[str]:
    """Final test, final-test candidates and everything that shares an identity with one — by the same
    closure the ordinary audit withholds with, seeded with those alone."""
    manifest, project, validation = _read_project(project_dir)
    only_final = {**manifest, "videos": [{**row, "split": row["split"] if row["split"] in FINAL_SPLITS else "train"}
                                         for row in manifest["videos"]]}
    listed = {name for key in FINAL_KEYS for name in validation.get(key) or []}
    return set(audit.withheld_closure(only_final, project, listed))


def plan(project_dir: str, scope: dict) -> dict:
    """What a run would open, compare against and leave closed — decided for every recording before any
    file is opened. Raises `ScopeError` when the scope reaches outside the protected recordings this
    operation covers."""
    allowed, refused = audit.project_recordings(project_dir)
    manifest, _, _ = _read_project(project_dir)
    split = {row["video"]: row["split"] for row in manifest["videos"]}
    protected = {row["name"]: row for row in refused}
    ordinary = {row["name"] for row in allowed}
    final = final_test_closure(project_dir)
    wrong = []
    for item in scope["recordings"]:
        name = item["name"]
        if name in ordinary:
            wrong.append(f"{name} is not withheld: the ordinary audit compares it, and it needs no entry here")
        elif name not in protected:
            wrong.append(f"{name} is not a recording of this project")
        elif name not in split:
            wrong.append(f"{name} is not in the split manifest: what it is is unknown")
        elif name in final:
            wrong.append(f"{name} is final test, a final-test candidate or an alias of one: outside this audit")
    if wrong:
        raise ScopeError("nothing is opened:\n  " + "\n  ".join(wrong))
    reasons = {item["name"]: item["reason"] for item in scope["recordings"]}
    to_open = [{**protected[name], "split": split[name], "reason": reasons[name]} for name in sorted(reasons)]
    closed = [{"name": row["name"], "why": row["why"], "notOpened": "not named in the scope"}
              for row in sorted(refused, key=lambda r: r["name"]) if row["name"] not in reasons]
    return {"open": to_open, "against": sorted(allowed, key=lambda r: r["name"]), "closed": closed}


class AccessLog:
    """Append-only: one JSON line per event, on disk before the caller goes on."""

    def __init__(self, path: str):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)

    def record(self, **entry) -> None:
        entry = {"time": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), **entry}
        with open(self.path, "a") as f:
            f.write(json.dumps(entry, sort_keys=True) + "\n")
            f.flush()
            os.fsync(f.fileno())


def configuration() -> dict:
    names = ("SIGNATURE_VERSION", "STEP_SEC", "MOTION_LAG", "GRID", "MOTION_DELTA", "MIN_ACTIVE", "ANCHORS", "VOTE_SIMILARITY",
             "MATCH_SIMILARITY", "MIN_COMPARED", "MIN_SCORE", "FULL_COVER", "CROP_MARGIN", "SCENE_HAMMING")
    return {name: getattr(audit, name) for name in names}


def tool_identity() -> dict:
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        commit = subprocess.run(["git", "-C", here, "rev-parse", "HEAD"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                check=True).stdout.decode().strip()
    except (OSError, subprocess.CalledProcessError):
        commit = None
    return {"commit": commit, "sha256": {name: audit.sha256_of(os.path.join(here, name)) for name in ("audit.py", "protected_audit.py")}}


def _inside(path: str, folder: str) -> bool:
    path, folder = os.path.realpath(path), os.path.realpath(folder)
    return path == folder or path.startswith(folder + os.sep)


def run(project_dir: str, scope: dict, out_dir: str, origin_projects: list[str] | None = None,
        signature_cache: str | None = None, log=print) -> dict:
    if _inside(out_dir, project_dir):
        raise ScopeError("the output folder is inside the project: this audit writes nothing under the project folder")
    planned = plan(project_dir, scope)
    access = AccessLog(os.path.join(out_dir, "access-log.jsonl"))
    config, tool = configuration(), tool_identity()
    access.record(event="run", project=os.path.abspath(project_dir), authorization=scope["authorization"], purpose=scope["purpose"],
                  toOpen=[row["name"] for row in planned["open"]], configuration=config, tool=tool)

    opened, not_read = [], []
    protected_cache = os.path.join(out_dir, "signatures-protected")
    for n, row in enumerate(planned["open"], 1):
        path = row["path"]
        if not path or not os.path.exists(path):
            not_read.append({"name": row["name"], "why": "no video here"})
            access.record(event="not-opened", name=row["name"], why="no video here", path=path)
            continue
        # On the log before the file is opened — by the hash as much as by the decoder.
        access.record(event="open", name=row["name"], split=row["split"], protectedBecause=row["why"], reason=row["reason"],
                      path=path, operation=OPERATION, authorization=scope["authorization"])
        try:
            media = audit.media_from_file(row["name"], path, cache_dir=protected_cache, source_id=row["source_id"],
                                          start=row["start"], length=row["length"], extra={"split": row["split"], "protected": True})
        except (audit.ReadError, OSError) as e:
            not_read.append({"name": row["name"], "why": str(e)})
            access.record(event="failed", name=row["name"], why=str(e))
            log(f"[protected {n}/{len(planned['open'])}] {row['name']}: not read ({e})")
            continue
        opened.append(media)
        access.record(event="read", name=row["name"], sha256=media.sha256, samples=len(media.full), durationSec=round(media.full.duration, 2))
        log(f"[protected {n}/{len(planned['open'])}] {row['name']}: {len(media.full)} samples")

    others, others_unread = [], []
    cache = signature_cache or os.path.join(out_dir, "signatures")
    for n, row in enumerate(planned["against"], 1):
        path = row["path"]
        if not path or not os.path.exists(path):
            others_unread.append({"name": row["name"], "why": "no video here"})
            continue
        try:
            others.append(audit.media_from_file(row["name"], path, cache_dir=cache, source_id=row["source_id"],
                                                start=row["start"], length=row["length"], extra={"split": row["split"]}))
            log(f"[{n}/{len(planned['against'])}] {row['name']}: {len(others[-1].full)} samples")
        except (audit.ReadError, OSError) as e:
            others_unread.append({"name": row["name"], "why": str(e)})
            log(f"[{n}/{len(planned['against'])}] {row['name']}: not read ({e})")

    # Every pair with a protected recording in it; pairs of two ordinary recordings are the ordinary audit's.
    found = []
    for i, p in enumerate(opened):
        for other in opened[i + 1:] + others:
            a, b = sorted((p, other), key=lambda m: m.name)
            relation = audit.classify(a, b)
            if relation is not None:
                found.append({"a": a.name, "b": b.name, "status": "proposed", "splits": [a.extra.get("split"), b.extra.get("split")],
                              "protected": [bool(a.extra.get("protected")), bool(b.extra.get("protected"))], **relation})
    found.sort(key=lambda p: (p["a"], p["b"]))

    # The cut history names pairs from project.json alone. For each one with an opened recording in it: what the pictures say.
    by_pair = {(p["a"], p["b"]): p["relation"] for p in found}
    read_names = {m.name for m in opened} | {m.name for m in others}
    opened_names = {m.name for m in opened}
    history = []
    for r in audit.cut_history_relations(project_dir, origin_projects or []):
        if r["a"] not in opened_names and r["b"] not in opened_names:
            continue
        pictures = by_pair.get((r["a"], r["b"])) if {r["a"], r["b"]} <= read_names else "not compared (one of the two was not read)"
        history.append({**r, "pictures": pictures or "no relation found by the pictures"})

    report = {"schemaVersion": SCHEMA_VERSION, "signature": audit.SIGNATURE_VERSION, "project": os.path.abspath(project_dir),
              "authorization": scope["authorization"], "purpose": scope["purpose"], "configuration": config, "tool": tool,
              "opened": [{"name": m.name, "split": m.extra.get("split"), "sha256": m.sha256, "samples": len(m.full)} for m in opened],
              "notRead": not_read, "notOpened": planned["closed"],
              "comparedAgainst": sorted(m.name for m in others), "comparedAgainstNotRead": others_unread,
              "proposals": found, "cutHistory": history,
              "note": "A proposal is not an identity: a person confirms it with RallyLab --set-provenance. A recording in "
                      "`notRead`, `notOpened` or `comparedAgainstNotRead` was not compared and is not cleared. No relation "
                      "proposed is not proof that no copy exists: mirrored, re-timed, off-centre-cropped, heavily overlaid and "
                      "motionless footage is not recognised."}
    with open(os.path.join(out_dir, "protected-content-lineage-proposals.json"), "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    access.record(event="done", opened=len(opened), notRead=len(not_read), proposals=len(found))
    return report


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", required=True, help="project folder")
    ap.add_argument("--scope", required=True, help="the scope file: authorization, purpose, and each protected recording with its reason")
    ap.add_argument("--out", required=True, help="folder for the access log, the proposals and the signatures (outside the project)")
    ap.add_argument("--origin-project", action="append", default=[], metavar="DIR",
                    help="another project whose clips this project's cards were cut from (repeatable)")
    ap.add_argument("--signature-cache", metavar="DIR", help="signatures of ordinary recordings from an earlier audit.py run")
    ap.add_argument("--plan", action="store_true", help="print what would be opened; open nothing and write nothing")
    args = ap.parse_args(argv)
    try:
        scope = load_scope(args.scope)
        if args.plan:
            planned = plan(args.project, scope)
            print(f"would open {len(planned['open'])} protected recording(s), compare against {len(planned['against'])} ordinary one(s), "
                  f"leave {len(planned['closed'])} protected recording(s) closed")
            for row in planned["open"]:
                print(f"  open   {row['name']} ({row['split']}; {row['why']}): {row['reason']}")
            for row in planned["closed"]:
                print(f"  closed {row['name']} ({row['why']})")
            return 0
        report = run(args.project, scope, args.out, origin_projects=args.origin_project, signature_cache=args.signature_cache)
    except (ScopeError, audit.ReadError) as e:
        print(f"❌ {e}", file=sys.stderr)
        return 2
    copies = [p for p in report["proposals"] if p["relation"] not in ("similar_scene", "same_source_disjoint")]
    print(f"{len(report['opened'])} protected opened · {len(report['notRead'])} not read · {len(report['notOpened'])} left closed · "
          f"{len(report['comparedAgainst'])} ordinary compared against · {len(copies)} proposed cop(ies) · "
          f"{len(report['proposals']) - len(copies)} other relation(s)")
    for p in copies:
        print(f"  {p['relation']}: {p['a']} ({p['splits'][0]}) ~ {p['b']} ({p['splits'][1]})")
    for r in report["cutHistory"]:
        print(f"  cut history: {r['a']} ~ {r['b']} ({r['evidence']['sharedSec']:.0f} s on {r['evidence']['original']}) — pictures: {r['pictures']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
