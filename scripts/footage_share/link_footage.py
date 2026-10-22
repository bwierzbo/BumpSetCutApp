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
--unlink removes the symlinks this script makes (real files are never touched).

Exit status is non-zero when any needed video is missing or unreadable.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

PROJECTS = Path.home() / "Movies/RallyLab/Projects"


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
    p.add_argument("--mount", type=Path, help="the mounted copy of <project>/footage (required for --check and --link)")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--link", action="store_true")
    mode.add_argument("--unlink", action="store_true")
    args = p.parse_args()
    project = PROJECTS / args.project
    footage = project / "footage"
    if not project.is_dir():
        sys.exit(f"No project at {project}")
    if (args.check or args.link) and not (args.mount and args.mount.is_dir()):
        sys.exit("--mount must be the mounted footage folder (e.g. /Volumes/RallyLabFootage/Scratch/footage)")

    videos = referenced_videos(project)
    needs = l2_needs(project)
    if args.unlink:
        removed = 0
        for v in videos.values():
            local = Path(v["path"])
            if local.is_symlink():
                local.unlink()
                removed += 1
        print(f"Removed {removed} symlinks under {footage}")
        return

    present, missing, linked, blocked = [], [], [], []
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
            linked.append(name)

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
