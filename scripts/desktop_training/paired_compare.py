#!/usr/bin/env python3
"""
Paired comparison of two models scored on the same val windows.

    python paired_compare.py <A>/metrics.json <B>/metrics.json [--manifest <manifest.json>] [--group tracked] [--out delta.json]

Each metrics.json comes from train_heatmap_model.py (a run's `best`, or a
checkpoint scored with --score-only, whose `scored` block is used first) and
carries the 4 px tallies per val video (`per_clip`) and the digest of the
val windows it was scored on (`val_digest`: every window record and every
frame's bytes). The two must carry the same digest; anything else is
refused, since a difference between models is only meaningful on identical
data, and the same clip names don't prove that.

ΔF1 = F1(A) − F1(B) on balls in play at 4 px, with a 90% interval from
resampling 1000 times — the *same* draw for both models each time (seed 0),
so the interval is of the paired difference, not of two independent scores.
Two resampling units are reported: whole val videos (as the trainer's own
range does) and, with --manifest (the project's split manifest the package
was built from), *recording groups*: videos of one clip card (`_v2`… variants
of a recording), of one alias group, sharing a confirmed session or venue
identity, or from one uploader are drawn together, since they are not
independent evidence of generalisation. Reported for the chosen group
(tracked-rally windows by default: every frame labeled, the trustworthy
score) and per surface.

This is an exploratory comparison. An interval that includes zero means the
two were not told apart at this sample size; it is not evidence that they
are equivalent, and nothing here is a non-inferiority test (that needs a
margin justified and preregistered before any L2 result is seen).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

DRAWS = 1000
SURFACES = {"ind": "indoor", "bch": "beach", "grs": "grass"}


def f1(t: dict[str, int]) -> float:
    p = t["tp"] / max(1, t["tp"] + t["fp"])
    r = t["tp"] / max(1, t["tp"] + t["fn"])
    return 2 * p * r / max(1e-9, p + r)


def tallies(path: Path, group: str) -> tuple[dict[str, dict[str, int]], str, str]:
    """The per-video tallies, which block they came from, and the digest of
    the val windows they were scored on."""
    m = json.loads(path.read_text())
    digest = m.get("val_digest")
    if not digest:
        sys.exit(f"{path}: no val-windows digest — scored with a trainer that didn't record one; "
                 f"score the checkpoint again with --score-only.")
    for key in ("scored", "best", "baseline"):
        block = m.get(key)
        if block and block.get("per_clip", {}).get(group):
            return block["per_clip"][group], key, digest
    sys.exit(f"{path}: no per-video tallies for group '{group}' — scored with a trainer older than --score-only, "
             f"or the package has no such windows.")


GROUP_KEYS = ("clipId", "aliasGroup", "sessionId", "venueId", "uploader")


def identity_value(field) -> str | None:
    """A manifest identity as a grouping key: a plain string, or a provenance object's value
    when it is confirmed (`{"origin": "confirmed", "value": …}`); unknown or inferred ones don't group."""
    if isinstance(field, dict):
        return str(field["value"]).strip() if field.get("origin") == "confirmed" and field.get("value") else None
    return str(field).strip() if field and str(field).strip() else None


def clusters_from_manifest(manifest_path: Path, clips: list[str]) -> dict[str, str]:
    """clip → recording-group id, from the split manifest: videos of one clip card, one alias
    group, one confirmed session or venue, or one uploader are one group (transitively)."""
    manifest = json.loads(manifest_path.read_text())
    rows = {r["video"]: r for r in manifest["videos"] if r["video"] in clips}
    missing = sorted(set(clips) - set(rows))
    if missing:
        sys.exit(f"{manifest_path}: not in this manifest: {missing}. Pass the manifest the package was built from.")
    parent = {c: c for c in clips}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(x, y):
        parent[find(x)] = find(y)

    by_key: dict[str, str] = {}
    for clip, row in rows.items():
        keys = [f"{k}:{v}" for k in GROUP_KEYS if (v := identity_value(row.get(k)))]
        for key in keys:
            if key in by_key:
                union(clip, by_key[key])
            else:
                by_key[key] = clip
    return {c: find(c) for c in clips}


def compare(a: dict[str, dict[str, int]], b: dict[str, dict[str, int]], clips: list[str],
            groups: dict[str, str] | None = None) -> dict:
    """ΔF1 over `clips`, resampling whole videos, or whole recording groups when `groups` maps
    each clip to its group (a draw takes every clip of a drawn group)."""
    rng = np.random.default_rng(0)
    total = lambda t, picks: {k: sum(t[c][k] for c in picks) for k in ("tp", "fp", "fn")}
    units = sorted({groups[c] for c in clips}) if groups else list(clips)
    members = {u: [c for c in clips if (groups[c] if groups else c) == u] for u in units}
    deltas = []
    for _ in range(DRAWS):
        picks = [c for k in rng.integers(0, len(units), len(units)) for c in members[units[k]]]
        deltas.append(f1(total(a, picks)) - f1(total(b, picks)))
    fa, fb = f1(total(a, clips)), f1(total(b, clips))
    low, high = (float(np.percentile(deltas, 5)), float(np.percentile(deltas, 95)))
    return {"videos": len(clips), "units": len(units), "unit": "recording group" if groups else "video",
            "f1_a": round(fa, 4), "f1_b": round(fb, 4), "delta": round(fa - fb, 4),
            "delta_range": [round(low, 4), round(high, 4)],
            "reading": ("interval excludes zero: A higher" if low > 0 else
                        "interval excludes zero: A lower" if high < 0 else
                        "interval includes zero: not told apart at this sample size (not evidence of equivalence)")}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("a", type=Path, help="metrics.json of model A")
    p.add_argument("b", type=Path, help="metrics.json of model B")
    p.add_argument("--group", default="tracked", choices=("tracked", "all", "sampled"))
    p.add_argument("--manifest", type=Path, default=None,
                   help="the split manifest.json the package was built from: adds the recording-group resampling")
    p.add_argument("--out", type=Path, default=None, help="Write the result as JSON here too")
    args = p.parse_args()
    a, key_a, digest_a = tallies(args.a, args.group)
    b, key_b, digest_b = tallies(args.b, args.group)
    if digest_a != digest_b:
        sys.exit(f"Not the same val windows: digest {digest_a[:16]}… vs {digest_b[:16]}… (the records or frames differ, "
                 f"even if the clip names agree). Score both on one package.")
    if set(a) != set(b):
        only_a, only_b = sorted(set(a) - set(b)), sorted(set(b) - set(a))
        sys.exit(f"Not the same val videos: only in A {only_a}; only in B {only_b}. Score both on one package.")
    clips = sorted(a)
    if len(clips) < 2:
        sys.exit("Fewer than two val videos — nothing to resample.")
    groups = clusters_from_manifest(args.manifest, clips) if args.manifest else None
    result = {"a": {"path": str(args.a), "block": key_a}, "b": {"path": str(args.b), "block": key_b},
              "val_digest": digest_a, "group": args.group, "draws": DRAWS, "seed": 0, "exploratory": True,
              "by_video": {"all": compare(a, b, clips), "by_surface": {}}}
    for prefix, surface in SURFACES.items():
        subset = [c for c in clips if c.startswith(prefix)]
        if len(subset) >= 2:
            result["by_video"]["by_surface"][surface] = compare(a, b, subset)
    if groups:
        result["recording_groups"] = {c: g for c, g in sorted(groups.items())}
        result["by_recording_group"] = {"all": compare(a, b, clips, groups), "by_surface": {}}
        for prefix, surface in SURFACES.items():
            subset = [c for c in clips if c.startswith(prefix)]
            if len({groups[c] for c in subset}) >= 2:
                result["by_recording_group"]["by_surface"][surface] = compare(a, b, subset, groups)
    print(f"ΔF1 = F1(A) − F1(B) on balls in play at 4 px, {args.group} windows, {DRAWS} paired draws (exploratory)")
    for title, block in (("resampling whole videos", result["by_video"]),
                         ("resampling recording groups (clip card / alias / session / venue / uploader)", result.get("by_recording_group"))):
        if not block:
            continue
        print(f" {title}:")
        rows = [("all", block["all"])] + list(block["by_surface"].items())
        print(f"   {'':8} {'videos':>6} {'units':>5} {'F1 A':>7} {'F1 B':>7} {'ΔF1':>8}  {'90% range':>17}  reading")
        for name, r in rows:
            print(f"   {name:8} {r['videos']:6} {r['units']:5} {r['f1_a']:7.3f} {r['f1_b']:7.3f} {r['delta']:+8.3f}  "
                  f"[{r['delta_range'][0]:+.3f}, {r['delta_range'][1]:+.3f}]  {r['reading']}")
    if not groups:
        print(" (pass --manifest <manifest.json> for the recording-group resampling; video variants are not independent)")
    if args.out:
        args.out.write_text(json.dumps(result, indent=2))
        print(f"Written to {args.out}")


if __name__ == "__main__":
    main()
