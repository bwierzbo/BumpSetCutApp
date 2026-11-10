"""Tests for scripts/content_lineage/audit.py on synthetic footage: a small scene with
moving blobs, rendered to the 8x8 grids the tool reads, then copied the ways a recording
gets copied (re-encoded, resized, cut to an excerpt, centre-cropped, a later stretch from
the same camera). Standard library only; the one test that decodes real video files is
skipped where ffmpeg is not installed.

    python3 -m unittest scripts.tests.test_content_lineage_audit -v
"""

import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "content_lineage"))
import audit as a  # noqa: E402

SIDE = 40   # the synthetic scene is 40x40 pixels: 5x5 per grid cell, the centre 80% is 32x32


class Scene:
    """A fixed background with blobs that wander: what a tripod camera sees."""

    def __init__(self, seed, background_seed=None, blobs=6):
        self.rng = random.Random(seed)
        bg = random.Random(seed if background_seed is None else background_seed)
        self.background = [[bg.randrange(40, 200) for _ in range(SIDE)] for _ in range(SIDE)]
        self.blobs = [[self.rng.uniform(4, SIDE - 4), self.rng.uniform(4, SIDE - 4), self.rng.choice((-90, 90))] for _ in range(blobs)]

    def frames(self, count):
        out = []
        for _ in range(count):
            for blob in self.blobs:
                blob[0] = min(SIDE - 3, max(2, blob[0] + self.rng.uniform(-3, 3)))
                blob[1] = min(SIDE - 3, max(2, blob[1] + self.rng.uniform(-3, 3)))
            frame = [row[:] for row in self.background]
            for x, y, level in self.blobs:
                for dy in range(-3, 4):
                    for dx in range(-3, 4):
                        px, py = int(x) + dx, int(y) + dy
                        if 0 <= px < SIDE and 0 <= py < SIDE:
                            frame[py][px] = min(255, max(0, frame[py][px] + level))
            out.append(frame)
        return out


def grid(frame, x0=0, y0=0, side=SIDE, noise=None):
    """Area-average a square of the frame down to 8x8, as the decoder's scaler does."""
    cell = side / a.GRID
    out = bytearray()
    for gy in range(a.GRID):
        for gx in range(a.GRID):
            xs = range(x0 + int(gx * cell), x0 + int((gx + 1) * cell))
            ys = range(y0 + int(gy * cell), y0 + int((gy + 1) * cell))
            value = sum(frame[y][x] for y in ys for x in xs) / (len(xs) * len(ys))
            if noise is not None:
                value += noise.uniform(-1, 1)   # what re-encoding does to an area average
            out.append(min(255, max(0, round(value))))
    return bytes(out)


def media(name, frames, crop=False, noise_seed=None, **meta):
    noise = random.Random(noise_seed) if noise_seed is not None else None
    inner = SIDE * 8 // 10
    margin = (SIDE - inner) // 2
    if crop:   # the file holds only the centre 80%: its whole frame is the original's centre
        full = [grid(f, margin, margin, inner, noise) for f in frames]
        centre = None
    else:
        full = [grid(f, noise=noise) for f in frames]
        centre = [grid(f, margin, margin, inner, noise) for f in frames]
    return a.Media(name=name, full=a.signature_from_grids(full), centre=a.signature_from_grids(centre) if centre else None, **meta)


class Relations(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.frames = Scene(seed=7).frames(600)          # 150 s at four samples a second
        cls.original = media("original", cls.frames)

    def relation(self, other):
        found = a.classify(self.original, other)
        return found["relation"] if found else None

    def test_a_re_encoded_copy_is_proposed_as_a_duplicate(self):
        copy = media("copy", self.frames, noise_seed=1)
        found = a.classify(self.original, copy)
        self.assertEqual(found["relation"], "re_encoded_duplicate")
        self.assertEqual(found["evidence"]["offsetSec"], 0)
        self.assertGreaterEqual(found["evidence"]["score"], 0.8)

    def test_the_same_bytes_are_byte_identical_without_looking_at_pictures(self):
        x = media("x", self.frames[:50], sha256="ab")
        y = media("y", Scene(seed=99).frames(50), sha256="ab")
        self.assertEqual(a.classify(x, y)["relation"], "byte_identical")

    def test_an_excerpt_is_found_wherever_it_starts(self):
        for start in (0, 163, 360):
            piece = media("piece", self.frames[start:start + 240], noise_seed=2)
            found = a.classify(self.original, piece)
            self.assertEqual(found["relation"], "excerpt", start)
            self.assertEqual(found["evidence"]["offsetSec"], -start * a.STEP_SEC)
            self.assertEqual((found["evidence"]["excerpt"], found["evidence"]["of"]), ("piece", "original"))

    def test_two_stretches_that_share_a_part_overlap(self):
        longer = Scene(seed=7).frames(900)
        first, second = media("first", longer[:600], noise_seed=3), media("second", longer[400:900], noise_seed=4)
        found = a.classify(first, second)
        self.assertEqual(found["relation"], "overlapping_ranges")
        self.assertEqual(found["evidence"]["sharedSec"], 200 * a.STEP_SEC)

    def test_a_centre_crop_is_proposed_as_a_cropped_duplicate(self):
        cropped = media("cropped", self.frames, crop=True, noise_seed=5)
        found = a.classify(self.original, cropped)
        self.assertEqual(found["relation"], "cropped_duplicate")
        self.assertEqual(found["evidence"]["cropped"], "cropped")
        found = a.classify(cropped, self.original)     # whichever way round they are given
        self.assertEqual((found["relation"], found["evidence"]["cropped"]), ("cropped_duplicate", "cropped"))

    def test_another_time_in_front_of_the_same_camera_is_not_a_copy(self):
        later = media("later", Scene(seed=8, background_seed=7).frames(600))
        self.assertEqual(self.relation(later), "similar_scene")
        self.assertIsNone(a.align(self.original.full, later.full))

    def test_unrelated_footage_is_nothing(self):
        self.assertIsNone(self.relation(media("other", Scene(seed=21).frames(600))))

    def test_a_shared_stretch_too_short_to_judge_is_not_proposed(self):
        short = media("short", self.frames[100:100 + a.MIN_COMPARED // 2], noise_seed=6)
        self.assertNotIn(self.relation(short), ("excerpt", "re_encoded_duplicate", "overlapping_ranges"))

    def test_footage_that_never_moves_matches_nothing(self):
        still = [self.frames[0]] * 400
        x, y = media("x", still), media("y", still, noise_seed=7)
        self.assertIsNone(a.align(x.full, y.full))     # no motion, no evidence: never a proposal from stillness
        self.assertEqual(a.classify(x, y)["relation"], "similar_scene")

    def test_one_original_with_stretches_apart_is_said_from_the_metadata(self):
        x = media("x", Scene(seed=31).frames(200), source_id="youtube:abc", start=0, length=300)
        y = media("y", Scene(seed=32).frames(200), source_id="youtube:abc", start=300, length=300)
        found = a.classify(x, y)
        self.assertEqual(found["relation"], "same_source_disjoint")
        self.assertEqual(found["evidence"]["rangesSec"], [[0, 300], [300, 600]])
        z = media("z", Scene(seed=33).frames(200), source_id="youtube:other", start=0, length=300)
        self.assertIsNone(a.classify(x, z))

    def test_every_proposal_is_only_proposed(self):
        found = a.proposals([self.original, media("copy", self.frames, noise_seed=1), media("other", Scene(seed=21).frames(600))])
        self.assertEqual([(p["a"], p["b"], p["relation"], p["status"]) for p in found], [("copy", "original", "re_encoded_duplicate", "proposed")])


class Signatures(unittest.TestCase):
    def test_a_signature_round_trips_and_an_older_version_is_refused(self):
        sig = media("x", Scene(seed=3).frames(20)).full
        self.assertEqual(a.Signature.from_json(json.loads(json.dumps(sig.to_json()))), sig)
        old = sig.to_json() | {"version": "motion8x8_v0"}
        with self.assertRaises(ValueError):
            a.Signature.from_json(old)

    def test_a_grid_of_the_wrong_size_is_refused(self):
        with self.assertRaises(ValueError):
            a.signature_from_grids([bytes(63)])

    def test_signatures_sampled_differently_are_not_aligned(self):
        x = media("x", Scene(seed=3).frames(20)).full
        y = a.signature_from_grids([bytes(64)] * 20, step=1.0)
        with self.assertRaises(ValueError):
            a.align(x, y)


class Project(unittest.TestCase):
    """What the tool may decode is decided from the split manifest, before any file is opened."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="content-lineage-")
        os.makedirs(os.path.join(self.tmp, "manifests"))
        videos = [("trn_a", "train"), ("trn_b", "train"), ("dev_a", "dev_val"), ("hold_a", "lineage_holdout"),
                  ("legacy_a", "legacy_holdout"), ("final_a", "final_test"), ("cand_a", "final_test_candidate")]
        with open(os.path.join(self.tmp, "manifests", "manifest.json"), "w") as f:
            json.dump({"videos": [{"video": v, "split": s, "sourceId": {"origin": "unknown"}} for v, s in videos]}, f)
        clips = [{"id": v, "videos": [{"kind": "file", "origin": f"/orig/{v}.mov", "clipFile": os.path.join(self.tmp, v + ".mp4"), "start": 0, "length": 10}]}
                 for v, _ in videos] + [{"id": "unlisted", "videos": [{"kind": "file", "origin": "/orig/u.mov", "clipFile": os.path.join(self.tmp, "u.mp4"), "start": 0, "length": 10}]}]
        with open(os.path.join(self.tmp, "project.json"), "w") as f:
            json.dump({"clips": clips}, f)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_reserved_and_unlisted_recordings_are_refused(self):
        allowed, refused = a.project_recordings(self.tmp)
        self.assertEqual(sorted(r["name"] for r in allowed), ["dev_a", "trn_a", "trn_b"])
        self.assertEqual({r["name"]: r["why"] for r in refused},
                         {"hold_a": "reserved (lineage_holdout)", "legacy_a": "reserved (legacy_holdout)", "final_a": "reserved (final_test)",
                          "cand_a": "reserved (final_test_candidate)", "unlisted": "not in the split manifest"})

    def test_an_excluded_or_refused_recording_is_never_opened(self):
        opened = []
        real = a.media_from_file
        a.media_from_file = lambda name, path, **kw: opened.append(name) or media(name, Scene(seed=len(opened)).frames(60))
        try:
            for name in ("trn_a", "trn_b", "dev_a", "hold_a", "legacy_a", "final_a", "cand_a", "u"):
                open(os.path.join(self.tmp, name + ".mp4"), "w").close()
            report = a.run_project(self.tmp, os.path.join(self.tmp, "out"), exclude={"trn_b"}, only=None, log=lambda _: None)
        finally:
            a.media_from_file = real
        self.assertEqual(sorted(opened), ["dev_a", "trn_a"])
        self.assertEqual(report["compared"], ["dev_a", "trn_a"])
        self.assertEqual({r["name"] for r in report["refused"]}, {"trn_b", "hold_a", "legacy_a", "final_a", "cand_a", "unlisted"})
        with open(os.path.join(self.tmp, "out", "content-lineage-proposals.json")) as f:
            self.assertEqual(json.load(f)["schemaVersion"], a.SCHEMA_VERSION)

    def test_a_recording_with_no_video_here_is_reported_not_cleared(self):
        report = a.run_project(self.tmp, os.path.join(self.tmp, "out"), exclude=set(), only=None, log=lambda _: None)
        self.assertEqual(report["compared"], [])
        self.assertEqual(sorted(r["name"] for r in report["notRead"]), ["dev_a", "trn_a", "trn_b"])

    def test_an_unreadable_manifest_stops_the_run(self):
        with open(os.path.join(self.tmp, "manifests", "manifest.json"), "w") as f:
            f.write("{")
        with self.assertRaises(ValueError):
            a.project_recordings(self.tmp)


class CutHistory(unittest.TestCase):
    """The case of 2026-11-10 (D-036): a train card registered from another project's cut of an
    original, and a holdout card cut from that original again. Nothing they store is shared."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="content-lineage-history-")
        self.scratch, self.older = os.path.join(self.tmp, "Scratch"), os.path.join(self.tmp, "Older")

        def card(name, origin, start, length, kind="file", fingerprint=None):
            return {"id": name, "videos": [{"kind": kind, "origin": origin, "start": start, "length": length,
                                            "clipFile": f"/clips/{name}.mp4", "fingerprint": fingerprint}]}
        for folder, clips, rows in (
            (self.older, [card("grs_t", "/movies/IMG_1.MOV", 211, 300.01)], []),
            (self.scratch, [
                card("grs_t", "/older/footage/grs_t.mp4", 0, 300.0),                   # a cut of the older project's cut
                card("grs_h", "/inbox/album/IMG_1.MOV", 211, 300.01),                   # the original, cut again
                card("grs_far", "/inbox/album/IMG_1.MOV", 900, 300),                    # the same original, another stretch
                card("grs_part", "/inbox/album/IMG_1.MOV", 400, 300),                   # overlaps 111 s of both
                card("yt_a", "https://youtu.be/abc", 0, 300, kind="link", fingerprint="youtube:abc"),
                card("yt_b", "https://www.youtube.com/watch?v=abc", 250, 300, kind="link", fingerprint="youtube:abc"),
                card("lost", "/gone/project/footage/unknown.mp4", 0, 300),
            ], [("grs_t", "train", "grs_t"), ("grs_h", "lineage_holdout", "grs_h"), ("grs_far", "train", "grs_far"),
                ("grs_part", "train", "grs_part"), ("yt_a", "train", "yt"), ("yt_b", "dev_val", "yt")]),
        ):
            os.makedirs(os.path.join(folder, "manifests"))
            with open(os.path.join(folder, "project.json"), "w") as f:
                json.dump({"clips": clips}, f)
            with open(os.path.join(folder, "manifests", "manifest.json"), "w") as f:
                json.dump({"videos": [{"video": v, "split": s, "aliasGroup": g, "sourceId": {"origin": "unknown"}} for v, s, g in rows]}, f)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_cut_of_a_cut_is_followed_back_to_the_original(self):
        history = a.cut_history(self.scratch, [self.older])
        self.assertEqual(history["grs_t"], {"original": "IMG_1.MOV", "startSec": 211.0, "endSec": 511.0, "hops": 1})
        self.assertEqual(history["grs_h"]["original"], "IMG_1.MOV")
        self.assertEqual(history["lost"], {"original": "unknown.mp4", "startSec": 0.0, "endSec": 300.0, "hops": 0}, "not followed, not guessed")

    def test_a_train_card_and_a_holdout_on_one_stretch_are_reported_with_nothing_decoded(self):
        found = {(r["a"], r["b"]): r for r in a.cut_history_relations(self.scratch, [self.older])}
        pair = found[("grs_h", "grs_t")]
        self.assertEqual((pair["relation"], pair["status"], pair["splits"], pair["sameAliasGroup"]),
                         ("same_source_overlap", "proposed", ["lineage_holdout", "train"], False))
        self.assertEqual(pair["evidence"]["sharedSec"], 300.0)
        self.assertEqual(found[("grs_h", "grs_part")]["evidence"]["sharedSec"], 111.01)
        self.assertNotIn(("grs_far", "grs_h"), found, "another stretch of the original is another recording")
        self.assertTrue(found[("yt_a", "yt_b")]["sameAliasGroup"], "a link's video ID is its original; 50 s shared, already one group")
        self.assertEqual(len(found), 4)

    def test_without_the_older_project_the_chain_cannot_be_followed(self):
        found = {(r["a"], r["b"]) for r in a.cut_history_relations(self.scratch, [])}
        self.assertNotIn(("grs_h", "grs_t"), found, "the limit: a card whose origin's project is gone is not traced")


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg is not installed")
class RealFiles(unittest.TestCase):
    """The reader itself, on generated video: a test pattern that moves, re-encoded smaller."""

    def test_a_re_encoded_smaller_copy_of_a_file_is_a_duplicate_and_a_short_read_is_an_error(self):
        tmp = tempfile.mkdtemp(prefix="content-lineage-video-")
        try:
            one, two, cut = (os.path.join(tmp, n) for n in ("one.mp4", "two.mp4", "cut.mp4"))
            make = ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=24:duration=30", "-pix_fmt", "yuv420p"]
            subprocess.run(make + [one], check=True)
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", one, "-vf", "scale=160:120", "-crf", "32", two], check=True)
            found = a.classify(a.media_from_file("one", one), a.media_from_file("two", two))
            self.assertEqual(found["relation"], "re_encoded_duplicate")
            self.assertEqual(found["evidence"]["frameSize"], [[320, 240], [160, 120]])
            with open(one, "rb") as f:
                data = f.read()
            with open(cut, "wb") as f:      # the tail of the file is missing
                f.write(data[:len(data) // 2])
            with self.assertRaises(a.ReadError):
                a.read_signatures(cut)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
