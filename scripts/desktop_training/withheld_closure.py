#!/usr/bin/env python3
"""
The project's withheld closure, as a trainer away from the project is given it,
and the check of a multi-frame package against it. Standard library only: the
trainers import it on the desktop, and desktop.sh runs it on the Mac before a
package is sent or a run is started.

A package is written once and trained from for weeks; the project it came from
goes on changing. A recording can become withheld after the package was built
(D-036: three train recordings turned out to be copies of lineage-holdout
recordings), and nothing inside the package can know. So every trainer takes
the closure as it is NOW as an explicit file, and refuses when it is missing —
no closure is never "nothing withheld".

The file (`RallyLab --project P --manifest --audit-dataset --withheld-closure <file>`,
written at the time of training, not of the export):

    {"names": [...], "sourceIds": [...], "fingerprints": [...], "closureSha256": "...",
     "splitManifest": {"projectJson": ..., "sessions": ..., "validationJson": ..., "manifestJson": ...},
     "project": "...", "createdAt": "..."}

`names` are the withheld recordings (lineage and legacy holdout, final test and
candidates, and every alias), `sourceIds` their confirmed sources, `fingerprints`
the files their cards were registered with and the content of their videos.

    python withheld_closure.py <multi-frame package folder or .zip> --withheld <closure.json>

checks a package as train_heatmap_model.py does and exits 0, or says why not and exits 1.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path
from typing import Optional

CLOSURE_KEYS = ("names", "sourceIds", "fingerprints")
RECORD = "l2-manifest.json"
WINDOWS = "windows.jsonl"
HOW = "RallyLab --project <name> --manifest --audit-dataset --withheld-closure <file>"


class Refused(Exception):
    """Why nothing is trained. The trainer that catches it stops."""


def closure_sha256(closure: dict) -> str:
    """A withheld closure's hash, as RallyLab writes it and scripts/rally_classifier/validate_dataset.py
    checks it (that validator is bundled into RallyLab and cannot import this; a test holds the two together)."""
    canon = json.dumps({k: sorted(closure[k]) for k in CLOSURE_KEYS}, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


def read_closure(block, where: str) -> dict[str, set]:
    """A withheld closure as sets — or Refused: lists that are not there, an empty closure (it
    proves nothing) and a hash that is not the lists' are all refused."""
    if not isinstance(block, dict) or not all(isinstance(block.get(k), list) for k in CLOSURE_KEYS):
        raise Refused(f"{where}: no withheld closure ({', '.join(CLOSURE_KEYS)})")
    if not block["names"]:
        raise Refused(f"{where}: the withheld closure is empty — an empty closure proves nothing")
    if block.get("closureSha256") != closure_sha256(block):
        raise Refused(f"{where}: the withheld closure's closureSha256 does not match the lists it carries")
    return {k: set(block[k]) for k in CLOSURE_KEYS}


def load(path: Optional[Path]) -> dict:
    """The closure file: `closure` (the three sets), `splitManifest` (the hashes of the project state it
    was computed from, or None when the file has none) and `record` (what a run writes down about it)."""
    where = f"--withheld {path}"
    try:
        state = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as e:
        raise Refused(f"{where}: can't be read ({e}) — the project's current withheld closure is required, and without it "
                      f"nothing is known to be clear of it; write it with {HOW}") from None
    closure = read_closure(state, where)
    return {"closure": closure, "splitManifest": state.get("splitManifest"),
            "record": {"file_sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest(), "closureSha256": state["closureSha256"],
                       "createdAt": state.get("createdAt"), "project": state.get("project"), **{k: len(v) for k, v in closure.items()}}}


def withheld_identity(closure: dict[str, set], name: str, source_ids=(), fingerprints: Optional[dict] = None) -> Optional[str]:
    """Which of a recording's identities is a withheld one, or None: its name, a confirmed sourceId,
    or one of its file identities (`fingerprints`: what to call it → the fingerprint), as RallyLab's
    withheldIdentity decides it."""
    if name in closure["names"]:
        return "name"
    if any(s and s in closure["sourceIds"] for s in source_ids):
        return "sourceId"
    for label, value in (fingerprints or {}).items():
        if value and value in closure["fingerprints"]:
            return label
    return None


def _members(package: Path) -> dict[str, bytes]:
    """The record and the window list of a package folder or zip (each None when it is not there)."""
    package = Path(package)
    if package.is_dir():
        return {name: (package / name).read_bytes() if (package / name).is_file() else None for name in (RECORD, WINDOWS)}
    if package.suffix != ".zip" or not package.is_file():
        raise Refused(f"{package} isn't a package folder or .zip")
    out: dict[str, bytes] = {RECORD: None, WINDOWS: None}
    with zipfile.ZipFile(package) as z:
        for name in (RECORD, WINDOWS):
            found = [m for m in z.namelist() if m == name or m.endswith("/" + name)]
            if len(found) > 1:
                raise Refused(f"{package.name}: more than one {name} inside ({found}) — which package is this?")
            if found:
                out[name] = z.read(found[0])
    return out


def check_lineage_package(package: Path, now: dict) -> dict:
    """Hold a multi-frame package to the project's withheld closure as it is now (`now`: load), or
    raise Refused. A package is trained from only when it says what it holds: the record a lineage
    package carries (l2-manifest.json, written by `RallyLab --package-l2` with a passed preflight),
    which names every recording with its identities and the content of the video it was exported
    from. The window list must be the one that record was written for, every recording in it must be
    one the record names, and none may be in the closure by name, confirmed source, the fingerprint
    its card was registered with or its video's content. Returns the package's provenance for the
    run's record."""
    package = Path(package)
    files = _members(package)
    if files[RECORD] is None:
        raise Refused(f"{package.name}: no {RECORD} — the package does not say which recordings it holds or what files they are "
                      "(only a lineage package written by RallyLab --package-l2 does), so it can't be held against the withheld "
                      "closure and nothing is trained or scored from it")
    if files[WINDOWS] is None:
        raise Refused(f"{package.name}: no {WINDOWS} — not a multi-frame package")
    try:
        record = json.loads(files[RECORD])
        plan, preflight = record["plan"], record["preflight"]
        eligible = {e["video"]: e for e in plan["eligible"]}
        sources = preflight["sourceFingerprints"]
        recorded_windows = preflight.get("windowsSha256")
        passed = preflight["passed"]
    except (ValueError, KeyError, TypeError) as e:
        raise Refused(f"{package.name}: {RECORD} can't be read as a lineage package's record ({e!r})") from None
    if passed is not True:
        raise Refused(f"{package.name}: its preflight did not pass — not a package to train from")
    windows_sha = hashlib.sha256(files[WINDOWS]).hexdigest()
    if not recorded_windows or recorded_windows != windows_sha:
        raise Refused(f"{package.name}: {WINDOWS} is not the one {RECORD} was written for (SHA-256 {windows_sha[:16]}…, the record "
                      f"says {str(recorded_windows)[:16]}…) — the record does not describe these windows")
    clips: set[str] = set()
    for n, line in enumerate(files[WINDOWS].decode("utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            clips.add(json.loads(line)["clip"])
        except (ValueError, KeyError, TypeError):
            raise Refused(f"{package.name}: {WINDOWS} line {n} names no clip") from None
    closure = now["closure"]
    for clip in sorted(clips):
        if clip not in eligible or not sources.get(clip):
            raise Refused(f"{package.name}: it holds {clip}, which {RECORD} does not name with a source fingerprint — its identity "
                          "can't be held against the withheld recordings'")
        ids = [i.split(":", 1) for i in eligible[clip].get("identities", []) if ":" in i]
        stored = {f"{kind} identity {value}": value for kind, value in ids if kind in ("fp", "src")}
        hit = withheld_identity(closure, clip, [value for kind, value in ids if kind == "src"], {**stored, "content": sources[clip]})
        if hit:
            raise Refused(f"{package.name}: it holds {clip}, which is withheld now — its {hit} is in the current withheld closure "
                          f"({now['record']['names']} names, written {now['record']['createdAt']}). A package that holds a withheld "
                          "recording, or the same footage under another card, is not trained or scored from: build a new one "
                          "(RallyLab --package-l2)")
    return {"package": preflight.get("package"), "record_sha256": hashlib.sha256(files[RECORD]).hexdigest(), "digest": preflight.get("digest"),
            "windowsSha256": windows_sha, "recordings": len(clips), "manifestHashes": plan.get("manifestHashes")}


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("package", type=Path, help="A multi-frame package folder or .zip")
    p.add_argument("--withheld", type=Path, required=True, metavar="CLOSURE", help=f"The project's withheld closure as it is now ({HOW})")
    args = p.parse_args(argv)
    try:
        now = load(args.withheld)
        found = check_lineage_package(args.package, now)
    except Refused as e:
        print(f"❌ {e}", file=sys.stderr)
        return 1
    print(f"{args.package.name}: {found['recordings']} recordings, none in the withheld closure "
          f"({now['record']['names']} names, {now['record']['sourceIds']} sourceIds, {now['record']['fingerprints']} fingerprints; "
          f"written {now['record']['createdAt']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
