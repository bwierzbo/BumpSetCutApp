#!/usr/bin/env python3
"""Fetch a training clip from YouTube (or any site yt-dlp supports).

Downloads only the section you need, at up to 1080p, names it by its Clip ID
from the clip checklist, files it under ~/volleyball/raw/, and logs where it
came from and on what terms in ~/volleyball/meta/sources.csv. Only use it on
footage you have the owner's permission for, or that carries a licence that
allows it (CC-BY, CC0) — the licence note is required and goes in the log.

    scripts/fetch_clip.py URL --id grs_onl_sun_land_onl_01 \
        --license "permission: J. Smith, email 2026-09-26"

    # start two minutes in, then send it straight to RallyLab's Sampler
    scripts/fetch_clip.py URL --id bch_onl_ovc_land_onl_02 --start 2:00 \
        --license CC-BY --sample

The environment folder comes from the Clip ID prefix (ind_ / bch_ / grs_,
and *_neg_* clips go to raw/negatives/); --env overrides it.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path.home() / "volleyball"
ENV_BY_PREFIX = {"ind": "indoor", "bch": "beach", "grs": "grass"}
CLIP_ID = re.compile(r"^[a-z0-9]+(_[a-z0-9]+)*$")
SOURCES_HEADER = ["clip_id", "url", "title", "uploader", "start_s", "length_s",
                  "license", "fetched_at", "file"]


def fail(message: str) -> None:
    print(f"❌ {message}", file=sys.stderr)
    sys.exit(1)


def parse_time(text: str) -> float:
    """'90', '1:30', '1:02:03' → seconds."""
    parts = text.strip().split(":")
    try:
        values = [float(p) for p in parts]
    except ValueError:
        fail(f"Can't read time '{text}' — use seconds or m:ss / h:mm:ss.")
    seconds = 0.0
    for v in values:
        seconds = seconds * 60 + v
    return seconds


def clock(seconds: float) -> str:
    s = int(round(seconds))
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}"


def yt_dlp() -> list[str]:
    exe = shutil.which("yt-dlp")
    if exe:
        return [exe]
    try:
        import yt_dlp  # noqa: F401
        return [sys.executable, "-m", "yt_dlp"]
    except ImportError:
        fail("yt-dlp isn't installed. Run: python3 -m pip install --upgrade yt-dlp")
    return []


def destination(clip_id: str, env: str | None) -> Path:
    if "_neg_" in clip_id:
        return ROOT / "raw" / "negatives" / f"{clip_id}.mp4"
    env = env or ENV_BY_PREFIX.get(clip_id.split("_")[0])
    if env not in ENV_BY_PREFIX.values():
        fail(f"Can't tell the environment from '{clip_id}'. Start the ID with ind_/bch_/grs_ or pass --env.")
    kind = "self" if "_self_" in clip_id else "online"
    return ROOT / "raw" / kind / env / f"{clip_id}.mp4"


def probe(url: str) -> dict:
    result = subprocess.run(yt_dlp() + ["--dump-single-json", "--no-playlist", "--no-warnings", url],
                            capture_output=True, text=True)
    if result.returncode != 0:
        fail("Couldn't read that link:\n" + (result.stderr.strip().splitlines() or ["(no detail)"])[-1])
    return json.loads(result.stdout)


def duration_of(path: Path) -> float:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", str(path)], capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def log_source(row: dict) -> Path:
    meta = ROOT / "meta"
    meta.mkdir(parents=True, exist_ok=True)
    path = meta / "sources.csv"
    new = not path.exists()
    with path.open("a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=SOURCES_HEADER)
        if new:
            writer.writeheader()
        writer.writerow(row)
    return path


def rallylab_binary() -> Path | None:
    builds = sorted(Path.home().glob(
        "Library/Developer/Xcode/DerivedData/BumpSetCut-*/Build/Products/Debug/RallyLab.app/Contents/MacOS/RallyLab"))
    return builds[0] if builds else None


def main() -> None:
    global ROOT
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("url")
    ap.add_argument("--id", required=True, help="Clip ID from the checklist, e.g. grs_onl_sun_land_onl_01")
    ap.add_argument("--license", required=True,
                    help='How you may use it: "CC-BY", "CC0", or "permission: <who>, <how/when>"')
    ap.add_argument("--start", default="0", help="Where the clip starts (seconds or m:ss). Default 0.")
    ap.add_argument("--length", default="300", help="Clip length in seconds or m:ss. Default 300 (5 min).")
    ap.add_argument("--env", choices=sorted(ENV_BY_PREFIX.values()), help="Override the folder from the ID.")
    ap.add_argument("--max-height", type=int, default=1080, help="Resolution cap. Default 1080.")
    ap.add_argument("--root", type=Path, default=ROOT, help="Footage root. Default ~/volleyball.")
    ap.add_argument("--force", action="store_true", help="Replace a clip that already exists.")
    ap.add_argument("--sample", action="store_true", help="Run RallyLab's Sampler on the clip afterwards.")
    args = ap.parse_args()
    ROOT = args.root.expanduser()

    if not CLIP_ID.match(args.id):
        fail("Clip IDs are lowercase letters, digits and underscores, e.g. grs_onl_sun_land_onl_01.")
    if not shutil.which("ffmpeg"):
        fail("ffmpeg isn't installed. Run: brew install ffmpeg")
    license_note = args.license.strip()
    if not license_note:
        fail("--license can't be empty.")

    out = destination(args.id, args.env)
    if out.exists() and not args.force:
        fail(f"{out} already exists. Pass --force to replace it.")
    out.parent.mkdir(parents=True, exist_ok=True)

    info = probe(args.url)
    total = float(info.get("duration") or 0)
    start = parse_time(args.start)
    length = parse_time(args.length)
    if total and start >= total:
        fail(f"--start {clock(start)} is past the end of the video ({clock(total)}).")
    end = min(start + length, total) if total else start + length

    print(f"▸ {info.get('title', '?')} — {info.get('uploader', '?')}")
    print(f"  {clock(start)} → {clock(end)} ({end - start:.0f}s) at ≤{args.max_height}p → {out}")

    # Only the section is downloaded; cutting at the exact times needs a
    # re-encode at the cut points, which --force-keyframes-at-cuts does.
    tmp = out.with_suffix(".part.mp4")
    fmt = (f"bv*[height<={args.max_height}][ext=mp4]+ba[ext=m4a]/"
           f"bv*[height<={args.max_height}]+ba/b[height<={args.max_height}]")
    cmd = yt_dlp() + [
        "--no-playlist", "--no-warnings",
        "-f", fmt,
        "--download-sections", f"*{start}-{end}",
        "--force-keyframes-at-cuts",
        "--merge-output-format", "mp4",
        "--remux-video", "mp4",
        "-o", str(tmp),
        args.url,
    ]
    if subprocess.run(cmd).returncode != 0 or not tmp.exists():
        tmp.unlink(missing_ok=True)
        fail("Download failed (details above).")
    tmp.replace(out)

    got = duration_of(out)
    if got <= 0:
        fail(f"{out} isn't a playable video.")
    print(f"✅ {out.name}: {got:.1f}s, {out.stat().st_size / 1_048_576:.0f} MB")

    csv_path = log_source({
        "clip_id": args.id,
        "url": info.get("webpage_url", args.url),
        "title": info.get("title", ""),
        "uploader": info.get("uploader", ""),
        "start_s": f"{start:.1f}",
        "length_s": f"{got:.1f}",
        "license": license_note,
        "fetched_at": dt.datetime.now().isoformat(timespec="seconds"),
        "file": str(out),
    })
    print(f"  logged in {csv_path}")

    if args.sample:
        binary = rallylab_binary()
        if not binary:
            fail("RallyLab isn't built. Run scripts/build.sh mac, then drop the clip on the Sampler tab.")
        print("▸ Sampling in RallyLab…")
        sys.exit(subprocess.run([str(binary), "--sample", str(out)]).returncode)
    else:
        print("  Next: drop it on RallyLab's Sampler tab, or re-run with --sample.")


if __name__ == "__main__":
    main()
