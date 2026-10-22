#!/usr/bin/env python3
"""
Point a RallyLab project's footage at a read-only network share, file by file.

    python3 scripts/footage_share/link_footage.py --project Scratch --mount /Volumes/RallyLabFootage/Scratch/footage --check
    python3 scripts/footage_share/link_footage.py --project Scratch --mount /Volumes/RallyLabFootage/Scratch/footage --link
    python3 scripts/footage_share/link_footage.py --project Scratch --unlink

The project's sessions and project.json name every video by its path under
<project>/footage/ on the Mac. The footage itself lives on the desktop; the
share mounts it read-only. Rather than replacing the footage folder with the
mount (which would also replace the rally-mark sidecars next to the videos —
the Mac's are the newer ones), each *video file* becomes a symlink to the
same path on the mount, and the sidecars stay where they are.

--check  lists every video the project refers to, says which ones the mount
         has (and can read) and which it lacks, and the subtotal for the
         recordings an L2 package needs: every eligible recording with labels
         and every withheld one. Nothing is written.
--link   makes the symlinks (only where no file is in the way; an existing
         real file or a link elsewhere is reported, never replaced).
--unlink removes only the symlinks this script made: each one is recorded in
         <project>/footage/.rallylab-links.json with its target, and is removed
         only while it still points there. A link made by anything else, or
         re-pointed since, is left alone and reported.

Exit status is non-zero when any needed video is missing or unreadable, or
when anything had to be left alone.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

PROJECTS = Path.home() / "Movies/RallyLab/Projects"
LEDGER = ".rallylab-links.json"


def read_ledger(footage: Path) -> dict[str, str]:
    """{local path: target} of the links this script made, or {} when there is no ledger."""
    file = footage / LEDGER
    return json.loads(file.read_text()) if file.exists() else {}


def write_ledger(footage: Path, links: dict[str, str]) -> None:
    file = footage / LEDGER
    if links:
        file.write_text(json.dumps(dict(sorted(links.items())), indent=1) + "\n")
    elif file.exists():
        file.unlink()


def referenced_videos(project: Path) -> dict[str, dict]:
    """Every video path the project names, by session name (or clip id for
    sessionless project videos): {'path', 'session', 'ready'}."""
    videos: dict[str, dict] = {}
    for file in sorted((project / "sessions").glob("*.json")):
        s = json.loads(file.read_text())
        frames = [f for f in s.get("frames", []) if f.get("keep") and f.get("reviewed") and f.get("source") != "file"]
        tracks = s.get("tracks") or []
        ready = [t for t in tracks if t.get("done") or (t.get("machine") and t.get("isRally") is not False)]
        videos[s["name"]] = {"path": s["sourcePath"], "session": True,
                             "labels": bool(frames) or bool(ready) or s.get("ralliesMarked") is True}
    project_json = project / "project.json"
    if project_json.exists():
        for clip in json.loads(project_json.read_text()).get("clips", []):
            for video in clip.get("videos") or []:
                path = video.get("clipFile")
                if not path:
                    continue
                name = Path(path).stem
                videos.setdefault(name, {"path": path, "session": False, "labels": False})
    return videos


def l2_needs(project: Path) -> tuple[set[str], set[str]] | None:
    """(eligible, withheld) names from the newest L2 plan, or None without one."""
    plans = sorted((project / "manifests/l2").glob("*-plan.json"))
    if not plans:
        return None
    plan = json.loads(plans[-1].read_text())
    return ({e["video"] for e in plan["eligible"]}, {w["video"] for w in plan["withheld"]} | set(plan.get("withheldClosure", [])))


def readable(path: Path) -> bool:
    try:
        with open(path, "rb") as f:
            return path.stat().st_size > 0 and len(f.read(1)) == 1
    except OSError:
        return False


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--project", required=True)
    p.add_argument("--projects", type=Path, default=PROJECTS, help=f"the RallyLab projects folder (default {PROJECTS})")
    p.add_argument("--mount", type=Path, help="the mounted copy of <project>/footage (required for --check and --link)")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--link", action="store_true")
    mode.add_argument("--unlink", action="store_true")
    args = p.parse_args()
    project = args.projects / args.project
    footage = project / "footage"
    if not project.is_dir():
        sys.exit(f"No project at {project}")
    if (args.check or args.link) and not (args.mount and args.mount.is_dir()):
        sys.exit("--mount must be the mounted footage folder (e.g. /Volumes/RallyLabFootage/Scratch/footage)")

    videos = referenced_videos(project)
    needs = l2_needs(project)
    if args.unlink:
        ledger = read_ledger(footage)
        removed, kept = 0, []
        for local_path, target in list(ledger.items()):
            local = Path(local_path)
            if local.is_symlink() and os.readlink(local) == target:
                local.unlink()
                removed += 1
                del ledger[local_path]
            elif local.is_symlink():
                kept.append(f"{local} now points to {os.readlink(local)}, not {target}; left alone")
            else:
                del ledger[local_path]   # already gone, or replaced by a real file: nothing of ours to remove
        write_ledger(footage, ledger)
        print(f"Removed {removed} symlinks this script had made under {footage}; {len(kept)} left alone")
        for why in kept:
            print(f"   kept  {why}")
        sys.exit(1 if kept else 0)

    present, missing, linked, blocked = [], [], [], []
    ledger = read_ledger(footage) if args.link else {}
    for name, v in sorted(videos.items()):
        local = Path(v["path"])
        try:
            rel = local.relative_to(footage)
        except ValueError:
            blocked.append((name, f"{local} is not under {footage}"))
            continue
        remote = args.mount / rel
        if not readable(remote):
            missing.append((name, str(remote)))
            continue
        present.append(name)
        if args.link:
            if local.is_symlink():
                if os.readlink(local) != str(remote):
                    blocked.append((name, f"{local} already links to {os.readlink(local)}"))
                continue
            if local.exists():
                blocked.append((name, f"{local} is a real file; left alone"))
                continue
            local.parent.mkdir(parents=True, exist_ok=True)
            local.symlink_to(remote)
            ledger[str(local)] = str(remote)
            linked.append(name)
    if args.link:
        write_ledger(footage, ledger)

    print(f"{len(videos)} videos referenced by {args.project}: {len(present)} on the mount and readable, {len(missing)} missing")
    for name, path in missing:
        print(f"   missing  {name}  {path}")
    for name, why in blocked:
        print(f"   blocked  {name}  {why}")
    if args.link:
        print(f"{len(linked)} symlinks made, {len(blocked)} left alone")
    bad = False
    if needs:
        eligible, withheld = needs
        needed = {n for n in eligible if videos.get(n, {}).get("labels")} | withheld
        have = needed & set(present)
        lacking = sorted(needed - set(present))
        print(f"L2 package needs {len(needed)} videos ({len(needed - withheld)} eligible with labels + {len(withheld)} withheld): "
              f"{len(have)} present, {len(lacking)} missing")
        for n in lacking:
            print(f"   needed but missing  {n}")
        bad = bool(lacking)
    else:
        print("No L2 plan in manifests/l2 yet (run RallyLab --package-l2 --dry-run); checked every referenced video instead.")
        bad = bool(missing)
    sys.exit(1 if bad or blocked else 0)


if __name__ == "__main__":
    main()
