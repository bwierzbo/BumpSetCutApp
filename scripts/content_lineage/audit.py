#!/usr/bin/env python3
"""Content-lineage audit (prototype): propose recordings that show the same footage
even when their bytes differ.

The project's identity checks compare bytes (a file fingerprint) and identities a
person confirmed (sourceId / sessionId / venueId). A re-encoded copy has new bytes and,
until someone confirms it, no shared identity: on 2026-11-09 two train recordings turned
out to be re-encodes of two lineage-holdout recordings (D-036). This tool compares what
the pictures do over time instead:

* every quarter second of a recording becomes an 8x8 grid of grey levels (area-averaged);
* the *motion* over half a second (a grid against the one two samples back) is kept as two
  64-bit masks: the cells that got brighter and the cells that got darker by more than a
  threshold. Re-encoding and
  resizing leave it alone; a different moment in front of the same fixed camera does not
  reproduce it;
* the *appearance* of a grid is a 64-bit average hash, kept only to say "looks like the
  same camera position" when the motion does not match.

Two recordings are aligned by voting on the time offset at which their motion agrees and
then scoring that offset over every informative sample. A second signature of the centre
80% of the frame lets a centre crop be recognised.

What it says about a pair (`relation`):

  byte_identical          the same file (SHA-256)
  re_encoded_duplicate    the same stretch of footage, different bytes
  cropped_duplicate       one is a centre crop of the other
  excerpt                 one lies inside the other
  overlapping_ranges      they share a stretch, each has more
  same_source_disjoint    project.json says one original, stretches that do not overlap
                          (from metadata; no picture evidence needed)
  same_source_overlap     the cards' cut history says one original and stretches that overlap:
                          the same footage, whatever the bytes (from metadata alone, so it is
                          reported for reserved recordings too — nothing is decoded for it)
  similar_scene           the pictures look alike, the motion does not match: the same
                          camera position at another time, or a coincidence. Not a copy.

A proposal is never an identity. It is written with its evidence and `status: proposed`;
a person confirms it (RallyLab `--set-provenance <video> --source-id <id>`), and only
that confirmation joins two recordings in the withheld closure.

Cut history: a card registered from another project's clip (a cut of a cut) names that clip
as its origin and loses the original. `--origin-project <dir>` (repeatable) lets the tool
follow such a card back through the other project's cards to the original file and the
stretch of it. Two cards on one original with overlapping stretches are the same footage.

Withheld footage: this tool decodes video. It refuses to decode every recording the split
manifest puts in a reserved split or validation.json lists, everything that shares an identity
with one of those (the app's withheld closure), and every name passed with --exclude; comparing a
protected recording's pictures needs the owner's separate approval and is not implemented
here. The cut-history relations read project.json only and cover every card.

Limits (recorded, not hidden): a mirrored, sped-up or slowed copy, a crop that is not
about the centre, an overlay covering most of the frame, and a stretch with no motion
are not recognised. Offsets are resolved to a quarter second.

Standard library only; needs `ffmpeg` and `ffprobe` on PATH to read video.

    python3 scripts/content_lineage/audit.py --project <project dir> --out <dir> [--exclude name …] [--only name …]
    python3 scripts/content_lineage/audit.py --pair <a.mp4> <b.mp4>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field, replace
from urllib.parse import parse_qs, urlsplit

SCHEMA_VERSION = "content_lineage_proposals_v1"
SIGNATURE_VERSION = "motion8x8_v2"
STEP_SEC = 0.25         # one sample every quarter second
MOTION_LAG = 2          # motion is the change over this many samples (half a second)
GRID = 8                # 8x8 cells
CELLS = GRID * GRID
MOTION_DELTA = 3        # grey levels (0-255) a cell must change by to count as moved
MIN_ACTIVE = 4          # a sample with fewer moved cells says nothing
ANCHORS = 32            # anchors voting on the offset: at least this many when the recording has them
VOTE_SIMILARITY = 0.5   # motion agreement for an anchor's vote
MATCH_SIMILARITY = 0.5  # motion agreement for an aligned sample to count as matching
MIN_COMPARED = 40       # informative aligned samples needed to say anything (10 s)
MIN_SCORE = 0.3         # share of informative aligned samples that must match. Measured on real footage:
                        # unrelated stretches from one fixed camera score about 0.01 at their best offset,
                        # a low-bitrate 24 fps excerpt starting between two samples about 0.55.
FULL_COVER = 0.9        # share of a recording the shared stretch must cover to be "all of it"
CROP_MARGIN = 0.1       # how much better the centre must agree than the whole frame to call it a crop
SCENE_HAMMING = 10      # appearance hashes this close (of 64 bits) look alike
RESERVED_SPLITS = {"final_test", "final_test_candidate", "lineage_holdout", "legacy_holdout"}


# ---------------------------------------------------------------- signatures

@dataclass
class Signature:
    """What the audit keeps of a recording: no picture can be rebuilt from it."""
    step: float
    appearance: list[int]           # one 64-bit average hash per sample
    brighter: list[int]             # cells brighter than MOTION_LAG samples earlier
    darker: list[int]               # cells darker than MOTION_LAG samples earlier
    version: str = SIGNATURE_VERSION

    def __len__(self) -> int:
        return len(self.appearance)

    @property
    def duration(self) -> float:
        return len(self) * self.step

    def to_json(self) -> dict:
        return {"version": self.version, "step": self.step,
                "appearance": [f"{x:016x}" for x in self.appearance],
                "brighter": [f"{x:016x}" for x in self.brighter],
                "darker": [f"{x:016x}" for x in self.darker]}

    @staticmethod
    def from_json(d: dict) -> "Signature":
        if d.get("version") != SIGNATURE_VERSION:
            raise ValueError(f"signature version {d.get('version')!r}, this tool reads {SIGNATURE_VERSION!r}")
        return Signature(step=float(d["step"]), appearance=[int(x, 16) for x in d["appearance"]],
                         brighter=[int(x, 16) for x in d["brighter"]], darker=[int(x, 16) for x in d["darker"]])


def signature_from_grids(grids: list[bytes], step: float = STEP_SEC) -> Signature:
    """`grids`: one 64-byte grey grid per sample, in time order."""
    appearance, brighter, darker = [], [], []
    for n, grid in enumerate(grids):
        if len(grid) != CELLS:
            raise ValueError(f"a grid has {len(grid)} cells, expected {CELLS}")
        mean = sum(grid) / CELLS
        a = 0
        for i, value in enumerate(grid):
            if value > mean:
                a |= 1 << i
        up = down = 0
        if n >= MOTION_LAG:
            previous = grids[n - MOTION_LAG]
            for i in range(CELLS):
                change = grid[i] - previous[i]
                if change > MOTION_DELTA:
                    up |= 1 << i
                elif change < -MOTION_DELTA:
                    down |= 1 << i
        appearance.append(a)
        brighter.append(up)
        darker.append(down)
    return Signature(step=step, appearance=appearance, brighter=brighter, darker=darker)


def motion_similarity(a: Signature, i: int, b: Signature, j: int) -> float | None:
    """Agreement of the moved cells of sample i of A and sample j of B (0…1), or None
    when either sample moved too little to say anything."""
    active_a = a.brighter[i] | a.darker[i]
    active_b = b.brighter[j] | b.darker[j]
    if active_a.bit_count() < MIN_ACTIVE or active_b.bit_count() < MIN_ACTIVE:
        return None
    same = (a.brighter[i] & b.brighter[j]).bit_count() + (a.darker[i] & b.darker[j]).bit_count()
    return same / (active_a | active_b).bit_count()


# ---------------------------------------------------------------- alignment

@dataclass
class Alignment:
    offset: int          # sample j of B is sample i of A when j = i + offset
    compared: int        # aligned samples where both moved enough
    matched: int         # … of which the motion agreed
    overlap: int         # aligned samples in all

    @property
    def score(self) -> float:
        return self.matched / self.compared if self.compared else 0.0


def score_offset(a: Signature, b: Signature, offset: int) -> Alignment:
    lo, hi = max(0, -offset), min(len(a), len(b) - offset)
    compared = matched = 0
    for i in range(lo, hi):
        s = motion_similarity(a, i, b, i + offset)
        if s is None:
            continue
        compared += 1
        if s >= MATCH_SIMILARITY:
            matched += 1
    return Alignment(offset=offset, compared=compared, matched=matched, overlap=max(0, hi - lo))


def align(a: Signature, b: Signature) -> Alignment | None:
    """The time offset at which B's motion agrees with A's, or None when no offset does.
    The same answer whichever of the two is called A (the offset negated)."""
    if a.step != b.step:
        raise ValueError("signatures sampled at different steps cannot be aligned")

    def informative(sig: Signature) -> list[int]:
        return [i for i in range(len(sig)) if (sig.brighter[i] | sig.darker[i]).bit_count() >= MIN_ACTIVE]
    moved_a, moved_b = informative(a), informative(b)
    if not moved_a or not moved_b:
        return None
    # Anchors come from the recording with less to say and are searched for in the other, so a short
    # excerpt of a long recording is seeded from the excerpt. They are spread over all of it, and close
    # enough that any shared stretch long enough to judge (MIN_COMPARED) holds several of them.
    seed_is_a = len(moved_a) <= len(moved_b)
    seed = moved_a if seed_is_a else moved_b
    anchors = seed[::max(1, min(len(seed) // ANCHORS, MIN_COMPARED // 4))]
    votes: dict[int, int] = {}
    for k in anchors:
        for other in (range(len(b)) if seed_is_a else range(len(a))):
            i, j = (k, other) if seed_is_a else (other, k)
            s = motion_similarity(a, i, b, j)
            if s is not None and s >= VOTE_SIMILARITY:
                votes[j - i] = votes.get(j - i, 0) + 1
    best: Alignment | None = None
    # A neighbouring offset can win when the two samplings fall between each other's samples.
    candidates = {o + d for o, n in sorted(votes.items(), key=lambda kv: -kv[1])[:6] if n >= 2 for d in (-1, 0, 1)}
    for offset in sorted(candidates):
        al = score_offset(a, b, offset)
        if al.compared >= MIN_COMPARED and al.score >= MIN_SCORE and (best is None or al.matched > best.matched):
            best = al
    return best


def looks_alike(a: Signature, b: Signature) -> bool:
    """The same framing: the typical appearance hashes are close. Says nothing about time."""
    if not len(a) or not len(b):
        return False

    def typical(sig: Signature) -> int:
        out = 0
        for bit in range(CELLS):
            if sum((x >> bit) & 1 for x in sig.appearance) * 2 > len(sig):
                out |= 1 << bit
        return out
    return (typical(a) ^ typical(b)).bit_count() <= SCENE_HAMMING


# ---------------------------------------------------------------- classification

@dataclass
class Media:
    """One recording as the audit sees it. `centre` is the signature of the centre 80%."""
    name: str
    full: Signature
    centre: Signature | None = None
    sha256: str | None = None
    width: int | None = None
    height: int | None = None
    source_id: str | None = None      # a confirmed sourceId, or the origin (link id / original file)
    start: float | None = None        # where its stretch begins in the original, seconds
    length: float | None = None
    extra: dict = field(default_factory=dict)


def classify(a: Media, b: Media) -> dict | None:
    """What relates A and B, with the evidence, or None."""
    if a.sha256 and a.sha256 == b.sha256:
        return {"relation": "byte_identical", "evidence": {"sha256": a.sha256}}

    def describe(al: Alignment, relation: str, how: str) -> dict:
        return {"relation": relation,
                "evidence": {"compared": how, "offsetSec": al.offset * a.full.step, "sharedSec": al.overlap * a.full.step,
                             "informativeSamples": al.compared, "matchingSamples": al.matched, "score": round(al.score, 3),
                             "durationSec": [a.full.duration, b.full.duration],
                             "frameSize": [[a.width, a.height], [b.width, b.height]]}}

    al = align(a.full, b.full)
    # One the centre crop of the other: its whole frame moves like the other's centre. A crop can
    # also agree loosely frame against frame, so the crop reading wins only when it agrees clearly better.
    for whole, cropped in ((a, b), (b, a)):
        if whole.centre is None:
            continue
        crop = align(whole.centre, cropped.full)
        if crop is not None and whole is b:
            crop = replace(crop, offset=-crop.offset)     # reported as the pair is: B's sample = A's sample + offset
        if crop is not None and (al is None or crop.score > al.score + CROP_MARGIN):
            out = describe(crop, "cropped_duplicate", f"centre of {whole.name} against all of {cropped.name}")
            out["evidence"]["cropped"] = cropped.name
            return out
    if al is not None:
        cover_a = al.overlap / max(1, len(a.full))
        cover_b = al.overlap / max(1, len(b.full))
        if cover_a >= FULL_COVER and cover_b >= FULL_COVER:
            return describe(al, "re_encoded_duplicate", "full frame")
        if cover_a >= FULL_COVER or cover_b >= FULL_COVER:
            out = describe(al, "excerpt", "full frame")
            out["evidence"]["excerpt"], out["evidence"]["of"] = (a.name, b.name) if cover_a >= FULL_COVER else (b.name, a.name)
            return out
        return describe(al, "overlapping_ranges", "full frame")
    if a.source_id and a.source_id == b.source_id and None not in (a.start, a.length, b.start, b.length):
        if a.start + a.length <= b.start or b.start + b.length <= a.start:
            return {"relation": "same_source_disjoint",
                    "evidence": {"sourceId": a.source_id, "rangesSec": [[a.start, a.start + a.length], [b.start, b.start + b.length]],
                                 "from": "project.json (no picture evidence)"}}
    if looks_alike(a.full, b.full):
        return {"relation": "similar_scene", "evidence": {"note": "the framing looks alike; the motion matches at no offset. Not a copy."}}
    return None


def proposals(media: list[Media]) -> list[dict]:
    out = []
    ordered = sorted(media, key=lambda m: m.name)
    for x in range(len(ordered)):
        for y in range(x + 1, len(ordered)):
            found = classify(ordered[x], ordered[y])
            if found is not None:
                out.append({"a": ordered[x].name, "b": ordered[y].name, "status": "proposed", **found})
    return out


# ---------------------------------------------------------------- reading video

class ReadError(Exception):
    pass


def _run(cmd: list[str]) -> bytes:
    try:
        done = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except FileNotFoundError as e:
        raise ReadError(f"{cmd[0]} is not installed") from e
    if done.returncode != 0:
        raise ReadError(f"{cmd[0]} failed on {cmd[-1]}: {done.stderr.decode(errors='replace').strip()[-300:]}")
    return done.stdout


def probe(path: str) -> dict:
    raw = _run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration",
                "-of", "json", path])
    data = json.loads(raw)
    stream = (data.get("streams") or [{}])[0]
    return {"width": stream.get("width"), "height": stream.get("height"), "durationSec": float(data.get("format", {}).get("duration") or 0)}


def read_signatures(path: str, step: float = STEP_SEC) -> tuple[Signature, Signature]:
    """Decode `path` once into the full-frame and centre-80% signatures. A read that
    stops short of the file's duration is an error, never a shorter signature."""
    info = probe(path)
    with tempfile.TemporaryDirectory(prefix="content-lineage-") as tmp:
        full, centre = os.path.join(tmp, "full.gray"), os.path.join(tmp, "centre.gray")
        scale = f"scale={GRID}:{GRID}:flags=area,format=gray"
        graph = f"[0:v]fps={1 / step},split[f][c];[f]{scale}[fo];[c]crop=iw*0.8:ih*0.8,{scale}[co]"
        _run(["ffmpeg", "-v", "error", "-nostdin", "-y", "-i", path, "-filter_complex", graph,
              "-map", "[fo]", "-f", "rawvideo", full, "-map", "[co]", "-f", "rawvideo", centre])
        out = []
        for name in (full, centre):
            with open(name, "rb") as f:
                raw = f.read()
            if len(raw) % CELLS:
                raise ReadError(f"{path}: the decoder wrote a partial sample")
            grids = [raw[i:i + CELLS] for i in range(0, len(raw), CELLS)]
            expected = info["durationSec"] / step
            if expected and len(grids) < expected * 0.97 - 2:
                raise ReadError(f"{path}: read {len(grids)} samples of about {expected:.0f}; the file could not be read to its end")
            out.append(signature_from_grids(grids, step))
    return out[0], out[1]


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def media_from_file(name: str, path: str, cache_dir: str | None = None, **meta) -> Media:
    digest = sha256_of(path)
    cached = os.path.join(cache_dir, digest + ".json") if cache_dir else None
    if cached and os.path.exists(cached):
        with open(cached) as f:
            d = json.load(f)
        full, centre, info = Signature.from_json(d["full"]), Signature.from_json(d["centre"]), d["probe"]
    else:
        info = probe(path)
        full, centre = read_signatures(path)
        if cached:
            os.makedirs(cache_dir, exist_ok=True)
            with open(cached + ".tmp", "w") as f:
                json.dump({"full": full.to_json(), "centre": centre.to_json(), "probe": info}, f)
            os.replace(cached + ".tmp", cached)
    return Media(name=name, full=full, centre=centre, sha256=digest, width=info.get("width"), height=info.get("height"), **meta)


# ---------------------------------------------------------------- the project

LISTED_KEYS = ("holdout", "finalTest", "lineageHoldout", "finalTestCandidates")
FINGERPRINT_CHUNK = 4 << 20


def file_fingerprint(path: str) -> str:
    """The app's file identity (`ProjectsModel.fileFingerprint`): SHA-256 of the size and the
    first and last 4 MB."""
    size = os.path.getsize(path)
    h = hashlib.sha256(size.to_bytes(8, "little"))
    with open(path, "rb") as f:
        head = f.read(FINGERPRINT_CHUNK)
        if len(head) != min(FINGERPRINT_CHUNK, size):
            raise ReadError(f"{path}: read stopped short")
        h.update(head)
        if size > FINGERPRINT_CHUNK:
            f.seek(size - min(FINGERPRINT_CHUNK, size - FINGERPRINT_CHUNK))
            h.update(f.read())
    return "file:" + h.hexdigest()


def link_fingerprint(link: str) -> str | None:
    """The app's link identity (`ProjectsModel.linkFingerprint`): the YouTube video id, else the
    address without tracking, timestamps or fragment. None for something that is not a link."""
    parts = urlsplit(link)
    host = (parts.hostname or "").lower()
    if not host:
        return None
    path = [piece for piece in parts.path.split("/") if piece]
    if host == "youtu.be" and path:
        return "youtube:" + path[0]
    if host.endswith("youtube.com"):
        video = parse_qs(parts.query).get("v")
        if video:
            return "youtube:" + video[0]
        if len(path) >= 2 and path[0] in ("shorts", "live", "embed", "v"):
            return "youtube:" + path[1]
    kept = [item for item in parts.query.split("&") if item
            and item.split("=")[0] not in ("t", "si", "feature", "start") and not item.startswith("utm_")]
    return "link:" + host.replace("www.", "") + parts.path + ("?" + "&".join(kept) if kept else "")


def effective_fingerprint(video: dict) -> str | None:
    """A card's file identity as the app derives it (`ReservedVideos.effectiveFingerprint`): the
    stored fingerprint, else from its origin — the file's when it is here, the link's otherwise.
    Older cards stored none."""
    if video.get("fingerprint"):
        return video["fingerprint"]
    origin = (video.get("origin") or "").strip()
    if not origin:
        return None
    path = os.path.expanduser(origin)
    return file_fingerprint(path) if os.path.exists(path) else link_fingerprint(origin)


def withheld_closure(manifest: dict, project: dict, listed: set[str]) -> dict[str, str]:
    """Every project video that is withheld, with why: a manifest row in a reserved split, a name
    validation.json lists, and everything that shares an identity with one of those, to a fixed
    point — the manifest's alias group, a stored or content fingerprint, a confirmed sourceId,
    sessionId or venueId, on a manifest row or on a card. Cards with no manifest row are followed
    too, so two recordings joined only through such a card are joined here; a card that stored no
    fingerprint gets the one the app derives from its origin, and when such a card has no manifest
    row and its origin cannot be resolved here, its identity is unknown and the run stops. The same closure the
    app withholds by (`ReservedVideos.lineageWithheldNames`): the manifest puts a legacy holdout
    in its split by name, so a train row can be one's alias."""
    ids: dict[str, set[str]] = {}
    why: dict[str, str] = {}
    for row in manifest["videos"]:
        mine = ids.setdefault(row["video"], set())
        if row.get("aliasGroup"):
            mine.add("grp:" + row["aliasGroup"])
        for key in ("fingerprint", "contentFingerprint"):
            if row.get(key):
                mine.add("fp:" + row[key])
        for key in ("sourceId", "sessionId", "venueId"):
            value = row.get(key) or {}
            if value.get("origin") == "confirmed" and value.get("value"):
                mine.add(key[:3] + ":" + value["value"])
        if row["split"] in RESERVED_SPLITS:
            why[row["video"]] = f"reserved ({row['split']})"
    for clip in project.get("clips", []):
        for video in clip.get("videos", []):
            name = video.get("videoId") or clip["id"]
            listed_row = name in ids
            mine = ids.setdefault(name, set())
            fingerprint = effective_fingerprint(video)
            if fingerprint:
                mine.add("fp:" + fingerprint)
            elif not listed_row and (video.get("origin") or "").strip():
                raise ReadError(f"{name}: the card has no stored fingerprint and no manifest row, and its origin "
                                f"({video['origin']}) is not here: its identity is unknown, so what it withholds is unknown")
            for key in ("sourceId", "sessionId", "venueId"):
                if video.get(key):
                    mine.add(key[:3] + ":" + video[key])
    for name in sorted(listed):
        why.setdefault(name, "listed in validation.json")
        ids.setdefault(name, set())
    grew = True
    while grew:
        grew = False
        for name in sorted(ids):
            if name in why:
                continue
            via = next((other for other in sorted(why) if ids[name] & ids.get(other, set())), None)
            if via is not None:
                why[name] = f"withheld: shares an identity with {via} ({why[via].removeprefix('withheld: ')})"
                grew = True
    return why


def project_recordings(project_dir: str) -> tuple[list[dict], list[dict]]:
    """(recordings this tool may decode, recordings it refuses) from the split manifest,
    validation.json and project.json. A recording the manifest does not list is refused, and so
    is every recording in the withheld closure (`withheld_closure`) — decided for all of them
    before any file is opened. Unreadable inputs raise; no validation.json means nothing is listed
    beyond the manifest's splits."""
    with open(os.path.join(project_dir, "manifests", "manifest.json")) as f:
        manifest = json.load(f)
    with open(os.path.join(project_dir, "project.json")) as f:
        project = json.load(f)
    listed: set[str] = set()
    validation = os.path.join(project_dir, "pipeline_tuning", "validation.json")
    if os.path.exists(validation):
        with open(validation) as f:
            data = json.load(f)
        listed = {name for key in LISTED_KEYS for name in data.get(key) or []}
    split = {v["video"]: v["split"] for v in manifest["videos"]}
    confirmed = {v["video"]: v["sourceId"]["value"] for v in manifest["videos"] if v.get("sourceId", {}).get("origin") == "confirmed"}
    withheld = withheld_closure(manifest, project, listed)
    allowed, refused = [], []
    for clip in project.get("clips", []):
        for video in clip.get("videos", []):
            name = video.get("videoId") or clip["id"]
            row = {"name": name, "path": video.get("clipFile"), "start": video.get("start"), "length": video.get("length"),
                   "source_id": confirmed.get(name) or (video.get("fingerprint") if video.get("kind") == "link" else video.get("origin"))}
            if name not in split:
                refused.append({**row, "why": "not in the split manifest"})
            elif name in withheld:
                refused.append({**row, "why": withheld[name]})
            else:
                allowed.append({**row, "split": split[name]})
    return allowed, refused


def _cards(project_dir: str) -> list[tuple[str, dict]]:
    with open(os.path.join(project_dir, "project.json")) as f:
        project = json.load(f)
    return [(video.get("videoId") or clip["id"], video) for clip in project.get("clips", []) for video in clip.get("videos", [])]


def _link_id(video: dict) -> str:
    stored = video.get("fingerprint") or ""
    return stored if stored and not stored.startswith("file:") else video.get("origin", "")


def cut_history(project_dir: str, origin_projects: list[str]) -> dict[str, dict]:
    """Each card's original and the stretch of it the card holds, following a card registered
    from a clip (of this project or of one in `origin_projects`) back to where that clip was cut.
    An original file is named by its file name: the same recording is found under more than one
    folder (an inbox, an album export). A card whose chain cannot be followed is its own original."""
    by_clip: dict[str, dict] = {}
    for folder in [project_dir] + list(origin_projects):
        for _, video in _cards(folder):
            if video.get("clipFile"):
                by_clip[os.path.basename(video["clipFile"])] = video
    out = {}
    for name, video in _cards(project_dir):
        start, length, current, hops = float(video.get("start") or 0), float(video.get("length") or 0), video, 0
        while current.get("kind") == "file" and hops < 8:
            parent = by_clip.get(os.path.basename(current.get("origin", "")))
            if parent is None or parent is current:
                break
            start += float(parent.get("start") or 0)
            length = min(length, float(parent.get("length") or length))
            current, hops = parent, hops + 1
        original = os.path.basename(current.get("origin", "")) if current.get("kind") == "file" else _link_id(current)
        out[name] = {"original": original, "startSec": start, "endSec": start + length, "hops": hops}
    return out


def cut_history_relations(project_dir: str, origin_projects: list[str], min_shared_sec: float = 1.0) -> list[dict]:
    """Pairs of cards that hold overlapping stretches of one original, with each one's split
    (from the manifest; None for a card with no dataset session). project.json only."""
    history = cut_history(project_dir, origin_projects)
    with open(os.path.join(project_dir, "manifests", "manifest.json")) as f:
        rows = {v["video"]: v for v in json.load(f)["videos"]}
    by_original: dict[str, list[str]] = {}
    for name, h in history.items():
        if h["original"]:
            by_original.setdefault(h["original"], []).append(name)
    out = []
    for original, names in sorted(by_original.items()):
        names.sort()
        for x in range(len(names)):
            for y in range(x + 1, len(names)):
                a, b = history[names[x]], history[names[y]]
                shared = min(a["endSec"], b["endSec"]) - max(a["startSec"], b["startSec"])
                if shared < min_shared_sec:
                    continue
                ra, rb = rows.get(names[x], {}), rows.get(names[y], {})
                group_a, group_b = ra.get("aliasGroup"), rb.get("aliasGroup")
                out.append({"a": names[x], "b": names[y], "status": "proposed", "relation": "same_source_overlap",
                            "splits": [ra.get("split"), rb.get("split")],
                            "sameAliasGroup": bool(group_a) and group_a == group_b,
                            "evidence": {"original": original, "sharedSec": round(shared, 3),
                                         "rangesSec": [[a["startSec"], a["endSec"]], [b["startSec"], b["endSec"]]],
                                         "hops": [a["hops"], b["hops"]], "from": "project.json cut history (no picture evidence)"}})
    return out


def run_project(project_dir: str, out_dir: str, exclude: set[str], only: set[str] | None, log=print,
                origin_projects: list[str] | None = None) -> dict:
    allowed, refused = project_recordings(project_dir)
    for row in list(allowed):
        if row["name"] in exclude:
            allowed.remove(row)
            refused.append({**row, "why": "excluded on the command line"})
    if only is not None:
        allowed = [r for r in allowed if r["name"] in only]
    media, unread = [], []
    cache = os.path.join(out_dir, "signatures")
    for n, row in enumerate(sorted(allowed, key=lambda r: r["name"]), 1):
        path = row["path"]
        if not path or not os.path.exists(path):
            unread.append({"name": row["name"], "why": "no video here"})
            continue
        try:
            media.append(media_from_file(row["name"], path, cache_dir=cache, source_id=row["source_id"],
                                         start=row["start"], length=row["length"], extra={"split": row["split"]}))
            log(f"[{n}/{len(allowed)}] {row['name']}: {len(media[-1].full)} samples")
        except (ReadError, OSError) as e:
            unread.append({"name": row["name"], "why": str(e)})
            log(f"[{n}/{len(allowed)}] {row['name']}: not read ({e})")
    found = proposals(media)
    splits = {m.name: m.extra.get("split") for m in media}
    for p in found:
        p["splits"] = [splits.get(p["a"]), splits.get(p["b"])]
    report = {"schemaVersion": SCHEMA_VERSION, "signature": SIGNATURE_VERSION, "project": os.path.abspath(project_dir),
              "compared": sorted(m.name for m in media), "notRead": unread,
              "refused": sorted(({"name": r["name"], "why": r["why"]} for r in refused), key=lambda r: r["name"]),
              "proposals": found,
              "cutHistory": cut_history_relations(project_dir, origin_projects or []),
              "note": "A proposal is not an identity. A person confirms it with RallyLab --set-provenance; "
                      "recordings in `refused` and `notRead` were not compared and are not cleared."}
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "content-lineage-proposals.json"), "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    return report


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project", help="project folder (reads manifests/manifest.json and project.json)")
    ap.add_argument("--out", help="folder for the proposals and the signature cache")
    ap.add_argument("--exclude", nargs="*", default=[], help="recordings never to decode, whatever the manifest says")
    ap.add_argument("--only", nargs="*", help="compare only these recordings")
    ap.add_argument("--origin-project", action="append", default=[], metavar="DIR",
                    help="another project whose clips this project's cards were cut from (repeatable)")
    ap.add_argument("--cut-history-only", action="store_true", help="read project.json only; decode nothing")
    ap.add_argument("--pair", nargs=2, metavar=("A", "B"), help="compare two video files and print the result")
    args = ap.parse_args(argv)
    if args.pair:
        if not shutil.which("ffmpeg"):
            print("ffmpeg is not installed", file=sys.stderr)
            return 2
        a, b = (media_from_file(os.path.basename(p), p) for p in args.pair)
        print(json.dumps(classify(a, b) or {"relation": None}, indent=2))
        return 0
    if not args.project or not args.out:
        ap.error("--project and --out, or --pair")
    if args.cut_history_only:
        relations = cut_history_relations(args.project, args.origin_project)
        os.makedirs(args.out, exist_ok=True)
        with open(os.path.join(args.out, "cut-history-relations.json"), "w") as f:
            json.dump({"schemaVersion": SCHEMA_VERSION, "project": os.path.abspath(args.project), "cutHistory": relations}, f, indent=2)
            f.write("\n")
        for r in relations:
            print(f"  {r['a']} ({r['splits'][0]}) ~ {r['b']} ({r['splits'][1]}): {r['evidence']['original']}, {r['evidence']['sharedSec']:.0f} s shared"
                  + ("" if r["sameAliasGroup"] else " — NO IDENTITY IN COMMON"))
        print(f"{len(relations)} pair(s) on one original with overlapping stretches; {sum(not r['sameAliasGroup'] for r in relations)} with no identity in common")
        return 0
    report = run_project(args.project, args.out, set(args.exclude), set(args.only) if args.only is not None else None,
                         origin_projects=args.origin_project)
    copies = [p for p in report["proposals"] if p["relation"] not in ("similar_scene", "same_source_disjoint")]
    print(f"{len(report['compared'])} compared · {len(report['refused'])} refused · {len(report['notRead'])} not read · "
          f"{len(copies)} proposed cop(ies) · {len(report['proposals']) - len(copies)} other relation(s)")
    for p in copies:
        print(f"  {p['relation']}: {p['a']} ({p['splits'][0]}) ~ {p['b']} ({p['splits'][1]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
