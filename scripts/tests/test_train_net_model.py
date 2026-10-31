"""Tests for scripts/desktop_training/train_net_model.py and net_to_coreml.py on a
synthetic dataset: small noise frames with a bright band where the net is, a split
manifest with recording groups, and an extra YOLO folder. The training and
conversion tests need torch (and coremltools) and are skipped without them.

    ~/.venvs/heatconv/bin/python -m unittest scripts.tests.test_train_net_model -v
"""

import hashlib
import json
import os
import random
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "desktop_training"))
import train_net_model as t  # noqa: E402

try:
    import cv2
except ImportError:   # the data tests write PNGs with cv2; without it nothing here runs
    cv2 = None

try:
    import torch  # noqa: F401
    HAVE_TORCH = True
except ImportError:
    HAVE_TORCH = False

try:
    import coremltools  # noqa: F401
    HAVE_COREML = True
except ImportError:
    HAVE_COREML = False


def band_frame(w: int, h: int, box: tuple, seed: int) -> np.ndarray:
    """A w×h noise frame with a bright band filling `box` (cx, cy, bw, bh fractions, y down)."""
    rng = np.random.default_rng(seed)
    img = rng.integers(20, 90, (h, w, 3), dtype=np.uint8)
    l, tp, r, b = t.edges(box)
    img[int(tp * h):int(b * h), int(l * w):int(r * w)] = (235, 235, 230)
    return img


def export_corners(corners: tuple) -> dict:
    """Corners as the export writes them: by name, Vision-normalised (bottom-up)."""
    return {name: {"x": x, "y": 1 - y} for name, (x, y) in zip(t.CORNER_NAMES, corners)}


# Recordings: name → (surface, group key, box). Two clip cards share a card id → one group.
RECORDINGS = {
    "bch_ele_sun_land_self_01":    ("beach",  "card-A", (0.50, 0.42, 0.70, 0.06)),
    "bch_ele_sun_land_self_01_v2": ("beach",  "card-A", (0.50, 0.42, 0.70, 0.06)),
    "bch_onl_ovc_land_onl_02":     ("beach",  "card-B", (0.48, 0.50, 0.60, 0.05)),
    "bch_gnd_ovc_land_self_01":    ("beach",  "card-C", (0.52, 0.38, 0.80, 0.07)),
    "grs_ele_shade_land_self_02":  ("grass",  "card-D", (0.50, 0.45, 0.66, 0.05)),
    "grs_onl_sun_land_onl_01":     ("grass",  "card-E", (0.47, 0.48, 0.62, 0.06)),
    "grs_onl_sun_land_onl_01_v2":  ("grass",  "card-E", (0.47, 0.48, 0.62, 0.06)),
    "ind_ele_dim_land_self_02":    ("indoor", "card-F", (0.50, 0.40, 0.72, 0.08)),
    "ind_gnd_bright_port_self_03": ("indoor", "card-G", (0.50, 0.36, 0.90, 0.05)),
}


class Fixture:
    def __init__(self, root: Path, withhold: str = None, size=(192, 108)):
        self.root = root
        self.export = root / "net-dataset"
        self.manifest = root / "manifest.json"
        (self.export / "images").mkdir(parents=True)
        (self.export / "labels").mkdir()
        w, h = size
        entries, videos = [], []
        for i, (video, (surface, card, box)) in enumerate(RECORDINGS.items()):
            img = band_frame(w, h, box, i)
            if video.endswith("port_self_03"):   # one portrait recording: the letterbox is exercised
                img = np.ascontiguousarray(img.transpose(1, 0, 2))
                box = (box[1], box[0], box[3], box[2])
            path = self.export / "images" / f"{video}.jpg"
            cv2.imwrite(str(path), cv2.cvtColor(img, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, 95])
            (self.export / "labels" / f"{video}.txt").write_text("0 %.6f %.6f %.6f %.6f\n" % box)
            fingerprint = f"fp-{video}"
            entries.append({"video": video, "clip": f"clip-{i}", "camera": "Elevated", "time": 1.0, "box": {},
                            "corners": export_corners(t.rect_corners(box)),
                            "proposed": False, "adjusted": False, "reviewedAt": "2026-10-30T00:00:00Z",
                            "image": f"images/{video}.jpg", "imageSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
                            "width": img.shape[1], "height": img.shape[0], "fingerprint": fingerprint})
            split = "lineage_holdout" if video == withhold else "train"
            videos.append({"video": video, "clipId": card, "surface": surface, "camera": "Elevated", "fingerprint": fingerprint,
                           "sourceId": None, "sessionId": None, "venueId": None, "datasetSplit": "train", "split": split,
                           "reservedAs": "listed" if video == withhold else None, "aliasGroup": None, "ralliesMarked": True,
                           "frames": 10, "reviewedFrames": 10})
        (self.export / "data.yaml").write_text("path: .\ntrain: images\nval: images\nnames:\n  0: net\n")
        (self.export / "net-dataset.json").write_text(json.dumps({"createdAt": "2026-10-30T00:00:00Z", "project": "Fixture",
                                                                  "labeled": len(entries), "entries": entries, "skipped": [], "note": ""}))
        self.manifest.write_text(json.dumps({"createdAt": "2026-10-30T00:00:00Z", "videos": videos}))

    def relabel(self, video: str, corners: tuple, box: tuple = None) -> None:
        """Give one entry these corners (y down; None removes them) and, unless `box` is
        given, the YOLO line of their bounds."""
        record = json.loads((self.export / "net-dataset.json").read_text())
        for e in record["entries"]:
            if e["video"] == video:
                if corners is None:
                    e.pop("corners", None)
                else:
                    e["corners"] = export_corners(corners)
        (self.export / "net-dataset.json").write_text(json.dumps(record))
        if corners is not None or box is not None:
            (self.export / "labels" / f"{video}.txt").write_text("0 %.6f %.6f %.6f %.6f\n" % (box or t.corners_box(corners)))

    def extra(self, name: str = "roboflow", provenance: bool = True, names: str = "['ball', 'net']") -> Path:
        folder = self.root / name
        for split in ("train", "valid"):
            (folder / split / "images").mkdir(parents=True)
            (folder / split / "labels").mkdir(parents=True)
        (folder / "data.yaml").write_text(f"train: train/images\nval: valid/images\nnc: 2\nnames: {names}\n")
        if provenance:
            (folder / "provenance.json").write_text(json.dumps({"source": "Roboflow project x/y, version 1, exported 2026-10-31",
                                                                "license": "CC BY 4.0", "obtained": "2026-10-31", "note": "owner's own project"}))
        # Two frames with a net (one also has a ball line, one has two nets), one with only a ball, one without a label file.
        frames = {"a": "1 0.5 0.4 0.6 0.05\n0 0.2 0.8 0.03 0.04\n", "b": "1 0.5 0.5 0.3 0.05\n1 0.5 0.3 0.9 0.06\n",
                  "c": "0 0.3 0.7 0.03 0.04\n", "d": None}
        for stem, label in frames.items():
            cv2.imwrite(str(folder / "train" / "images" / f"{stem}.jpg"), band_frame(160, 90, (0.5, 0.4, 0.6, 0.05), 99)[:, :, ::-1])
            if label is not None:
                (folder / "train" / "labels" / f"{stem}.txt").write_text(label)
        return folder


class DataTests(unittest.TestCase):
    def setUp(self):
        if cv2 is None:
            self.skipTest("opencv-python is not installed")
        self.tmp = Path(tempfile.mkdtemp(prefix="net-trainer-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_export_reads_every_frame_with_its_group_and_surface(self):
        f = Fixture(self.tmp)
        _, rows = t.load_manifest(f.manifest)
        samples, info = t.read_rallylab_export(f.export, rows)
        t.group_samples(samples, f.manifest)
        self.assertEqual(len(samples), len(RECORDINGS))
        self.assertEqual(info["entries"], len(RECORDINGS))
        by = {s.video: s for s in samples}
        self.assertEqual(by["bch_ele_sun_land_self_01"].group, by["bch_ele_sun_land_self_01_v2"].group, "one clip card, one group")
        self.assertNotEqual(by["bch_ele_sun_land_self_01"].group, by["bch_onl_ovc_land_onl_02"].group)
        self.assertEqual(by["grs_onl_sun_land_onl_01"].surface, "grass")
        self.assertEqual(len({s.group for s in samples}), 7)
        self.assertAlmostEqual(by["bch_gnd_ovc_land_self_01"].box[2], 0.80)
        # The corners come back y-down, in label order, and span the YOLO box.
        s = by["bch_gnd_ovc_land_self_01"]
        for a, b in zip(s.corners, t.rect_corners(s.box)):
            self.assertAlmostEqual(a[0], b[0], places=6); self.assertAlmostEqual(a[1], b[1], places=6)
        self.assertLess(s.corners[0][1], s.corners[3][1], "top-left is above bottom-left")

    def test_corners_are_the_label_and_the_box_must_be_their_bounds(self):
        f = Fixture(self.tmp)
        # A perspective net: the right tape end lower than the left, the right post further right.
        tilted = ((0.12, 0.30), (0.92, 0.36), (0.93, 0.44), (0.11, 0.37))
        f.relabel("grs_onl_sun_land_onl_01", tilted)
        _, rows = t.load_manifest(f.manifest)
        samples, _ = t.read_rallylab_export(f.export, rows)
        s = {s.video: s for s in samples}["grs_onl_sun_land_onl_01"]
        for a, b in zip(s.corners, tilted):
            self.assertAlmostEqual(a[0], b[0], places=6); self.assertAlmostEqual(a[1], b[1], places=6)
        for a, b in zip(s.box, (0.52, 0.37, 0.82, 0.14)):
            self.assertAlmostEqual(a, b, places=5)
        # The YOLO line disagreeing with the corners is an inconsistent export, not a label.
        f.relabel("grs_onl_sun_land_onl_01", tilted, box=(0.47, 0.48, 0.62, 0.06))
        with self.assertRaises(SystemExit) as cm:
            t.read_rallylab_export(f.export, rows)
        self.assertIn("grs_onl_sun_land_onl_01: the YOLO box", str(cm.exception))
        # No corners (a box-only label from before) stops the run naming the recording.
        f.relabel("grs_onl_sun_land_onl_01", None)
        with self.assertRaises(SystemExit) as cm:
            t.read_rallylab_export(f.export, rows)
        self.assertIn("grs_onl_sun_land_onl_01: no corners", str(cm.exception))

    def test_corners_flip_with_the_frame_and_stay_ordered_under_augmentation(self):
        tilted = ((0.12, 0.30), (0.92, 0.36), (0.93, 0.44), (0.11, 0.37))
        img = band_frame(160, 90, t.corners_box(tilted), 5)
        flipped = mirrored = 0
        for seed in range(30):
            out, c = t.augment(img, tilted, random.Random(seed))
            self.assertEqual(out.shape[2], 3)
            tl, tr, br, bl = c
            self.assertLess(tl[0], tr[0], "top-left stays left of top-right")
            self.assertLess(bl[0], br[0])
            self.assertLess(tl[1], bl[1], "top stays above bottom")
            self.assertTrue(all(0 <= v <= 1 for p in c for v in p))
            # Mirrored: the lower tape end is now on the left.
            if tl[1] > tr[1]:
                mirrored += 1
            flipped += 1
        self.assertGreater(mirrored, 0); self.assertLess(mirrored, flipped)
        plain, c = t.augment(img, None, random.Random(1))
        self.assertIsNone(c)

    def test_a_withheld_recording_in_the_export_stops_the_run(self):
        f = Fixture(self.tmp, withhold="grs_ele_shade_land_self_02")
        _, rows = t.load_manifest(f.manifest)
        with self.assertRaises(SystemExit) as cm:
            t.read_rallylab_export(f.export, rows)
        self.assertIn("grs_ele_shade_land_self_02: withheld", str(cm.exception))

    def test_a_recording_missing_from_the_manifest_stops_the_run(self):
        f = Fixture(self.tmp)
        _, rows = t.load_manifest(f.manifest)
        del rows["ind_ele_dim_land_self_02"]
        with self.assertRaises(SystemExit) as cm:
            t.read_rallylab_export(f.export, rows)
        self.assertIn("ind_ele_dim_land_self_02: not in the manifest", str(cm.exception))

    def test_a_fingerprint_or_image_that_changed_stops_the_run(self):
        f = Fixture(self.tmp)
        _, rows = t.load_manifest(f.manifest)
        rows["bch_onl_ovc_land_onl_02"]["fingerprint"] = "another file"
        with self.assertRaises(SystemExit) as cm:
            t.read_rallylab_export(f.export, rows)
        self.assertIn("bch_onl_ovc_land_onl_02: the export's fingerprint is not the manifest's", str(cm.exception))
        _, rows = t.load_manifest(f.manifest)
        (f.export / "images" / "bch_gnd_ovc_land_self_01.jpg").write_bytes(b"not the frame")
        with self.assertRaises(SystemExit) as cm:
            t.read_rallylab_export(f.export, rows)
        self.assertIn("bch_gnd_ovc_land_self_01: bch_gnd_ovc_land_self_01.jpg is not the file the export recorded", str(cm.exception))

    def test_yolo_lines_keep_only_the_net_class_and_the_largest_net(self):
        box, count = t.parse_yolo("1 0.5 0.4 0.6 0.05\n0 0.2 0.8 0.03 0.04\n", net_index=1)
        self.assertEqual((box, count), ((0.5, 0.4, 0.6, 0.05), 1))
        box, count = t.parse_yolo("1 0.5 0.5 0.3 0.05\n1 0.5 0.3 0.9 0.06\n", net_index=1)
        self.assertEqual((box, count), ((0.5, 0.3, 0.9, 0.06), 2))
        self.assertEqual(t.parse_yolo("0 0.3 0.7 0.03 0.04\n", net_index=1), (None, 0))
        with self.assertRaises(ValueError):
            t.parse_yolo("1 0.5 0.5 0.3\n", net_index=1)
        with self.assertRaises(ValueError):
            t.parse_yolo("1 1.5 0.5 0.3 0.1\n", net_index=1)

    def test_an_extra_folder_needs_provenance_and_a_net_class(self):
        f = Fixture(self.tmp)
        with self.assertRaises(SystemExit) as cm:
            t.read_extra_folder(f.extra("no-prov", provenance=False))
        self.assertIn("no provenance.json", str(cm.exception))
        with self.assertRaises(SystemExit) as cm:
            t.read_extra_folder(f.extra("no-net", names="['ball', 'player']"))
        self.assertIn("no class named `net`", str(cm.exception))
        samples, info = t.read_extra_folder(f.extra())
        self.assertEqual(len(samples), 4)
        self.assertEqual(info["no_net_images"], 2, "the ball-only frame and the unlabeled one")
        self.assertEqual(info["multi_net_images"], 1)
        self.assertEqual(info["provenance"]["license"], "CC BY 4.0")
        self.assertTrue(all(s.source == "roboflow" and s.surface == "extra" for s in samples))

    def test_split_holds_out_whole_groups_per_surface_and_extras_only_train(self):
        f = Fixture(self.tmp)
        _, rows = t.load_manifest(f.manifest)
        samples, _ = t.read_rallylab_export(f.export, rows)
        t.group_samples(samples, f.manifest)
        extra, _ = t.read_extra_folder(f.extra())
        samples += extra
        train, val, groups = t.split_by_group(samples, 0.3, random.Random(3))
        self.assertTrue(val)
        self.assertFalse({s.group for s in train} & {s.group for s in val}, "no group on both sides")
        self.assertTrue(all(s.source == "rallylab" for s in val))
        self.assertEqual(sum(s.source == "roboflow" for s in train), 4)
        self.assertEqual(sorted({s.surface for s in val}), ["beach", "grass", "indoor"])
        for surface in ("beach", "grass", "indoor"):
            self.assertTrue(any(s.surface == surface for s in train), f"{surface} still trains")
        again = t.split_by_group(samples, 0.3, random.Random(3))
        self.assertEqual(again[2], groups, "the same seed draws the same groups")
        pinned = t.split_by_group(samples, 0.3, random.Random(99), set(groups))
        self.assertEqual([s.video for s in pinned[1]], [s.video for s in val], "--split pins the val groups")
        with self.assertRaises(SystemExit):
            t.split_by_group(samples, 0.3, random.Random(0), {"not-a-group"})

    def test_a_group_spanning_surfaces_never_empties_a_surface_from_training(self):
        """Two groups, each with a beach and a grass frame (a session with two courts): per-surface
        picking would take one group for beach and the other for grass and leave nothing to train."""
        def sample(video, group, surface):
            return t.Sample(image=Path(f"/nonexistent/{video}.jpg"), video=video, group=group, surface=surface, source="rallylab",
                            box=(0.5, 0.4, 0.6, 0.05), corners=t.rect_corners((0.5, 0.4, 0.6, 0.05)))
        two = [sample("b1", "g1", "beach"), sample("r1", "g1", "grass"), sample("b2", "g2", "beach"), sample("r2", "g2", "grass")]
        for seed in range(20):
            train, val, groups = t.split_by_group(two, 0.5, random.Random(seed))
            self.assertEqual(len(groups), 1, f"seed {seed}: one group val, one train")
            self.assertEqual(len(train), 2); self.assertEqual(len(val), 2)
            self.assertEqual({s.surface for s in train}, {"beach", "grass"}, "both surfaces still train")
        # Three groups, two of them cross-surface and one beach-only: beach may hold out two groups
        # (half its frames) only while grass keeps a group in train.
        three = two + [sample("b3", "g3", "beach"), sample("b4", "g3", "beach")]
        for seed in range(20):
            train, val, groups = t.split_by_group(three, 0.5, random.Random(seed))
            self.assertTrue({s.surface for s in train} >= {"beach", "grass"}, f"seed {seed}: {groups}")
        # A pinned split that empties a surface is refused.
        with self.assertRaises(SystemExit) as cm:
            t.split_by_group(two, 0.5, random.Random(0), {"g1", "g2"})
        self.assertIn("would not train", str(cm.exception))

    def test_an_entry_as_the_swift_export_writes_it_is_read(self):
        """The shape `NetDatasetExport.Entry` encodes (JSONEncoder, sorted keys, ISO dates): corners by
        name with x/y, the box as TrackCandidate's x/y/w/h/confidence, Vision-normalised (bottom-up)."""
        f = Fixture(self.tmp)
        entry = json.loads("""
        {"adjusted": true, "box": {"confidence": 1, "h": 0.14, "w": 0.65, "x": 0.2, "y": 0.36},
         "camera": "End line, elevated (stands/tripod 2m+)", "clip": "grs_onl_sun_land_onl_01",
         "corners": {"bottomLeft": {"x": 0.2, "y": 0.4}, "bottomRight": {"x": 0.85, "y": 0.36},
                     "topLeft": {"x": 0.2, "y": 0.5}, "topRight": {"x": 0.85, "y": 0.45}},
         "fingerprint": "fp-grs_onl_sun_land_onl_01", "frameHeight": 108, "frameWidth": 192,
         "image": "images/grs_onl_sun_land_onl_01.jpg", "imageSHA256": "", "proposed": true,
         "reviewedAt": "2026-10-31T16:02:10Z", "time": 45.0, "video": "grs_onl_sun_land_onl_01"}
        """)
        record = json.loads((f.export / "net-dataset.json").read_text())
        for i, e in enumerate(record["entries"]):
            if e["video"] == entry["video"]:
                entry["imageSHA256"] = e["imageSHA256"]
                record["entries"][i] = entry
        (f.export / "net-dataset.json").write_text(json.dumps(record))
        # The YOLO line the export writes for it: the corners' bounds, top-down.
        (f.export / "labels" / f"{entry['video']}.txt").write_text("0 0.525000 0.570000 0.650000 0.140000\n")
        _, rows = t.load_manifest(f.manifest)
        samples, _ = t.read_rallylab_export(f.export, rows)
        s = {s.video: s for s in samples}[entry["video"]]
        # y-down: the top-left is (0.2, 0.5) from the bottom → 0.5 from the top.
        for a, b in zip(s.corners, ((0.2, 0.5), (0.85, 0.55), (0.85, 0.64), (0.2, 0.6))):
            self.assertAlmostEqual(a[0], b[0], places=6); self.assertAlmostEqual(a[1], b[1], places=6)
        for a, b in zip(s.box, (0.525, 0.57, 0.65, 0.14)):
            self.assertAlmostEqual(a, b, places=5)

    def test_letterbox_maps_boxes_there_and_back(self):
        for w, h in ((1920, 1080), (1080, 1920), (640, 640), (160, 90)):
            box = (0.5, 0.42, 0.7, 0.06)
            canvas = t.letterbox_box(box, w, h)
            self.assertTrue(all(0 <= v <= 1 for v in canvas))
            back = t.letterbox_back(canvas, w, h)
            for a, b in zip(box, back):
                self.assertAlmostEqual(a, b, places=6)
            corners = t.rect_corners(box)
            canvas_corners = t.letterbox_corners(corners, w, h)
            self.assertTrue(all(0 <= v <= 1 for p in canvas_corners for v in p))
            for a, b in zip(t.letterbox_corners_back(canvas_corners, w, h), corners):
                self.assertAlmostEqual(a[0], b[0], places=6); self.assertAlmostEqual(a[1], b[1], places=6)
            for a, b in zip(t.corners_box(canvas_corners), canvas):
                self.assertAlmostEqual(a, b, places=6, msg="the letterboxed corners span the letterboxed box")
        self.assertEqual(t.unflat(t.flat(corners)), corners)
        img, (scale, ox, oy) = t.letterbox_image(np.zeros((1920, 1080, 3), dtype=np.uint8))
        self.assertEqual(img.shape, (t.HEIGHT, t.WIDTH, 3))
        self.assertEqual(int(img[0, 0, 0]), t.PAD_GREY, "portrait: grey at the sides")
        self.assertEqual(int(img[t.HEIGHT // 2, t.WIDTH // 2, 0]), 0)

    def test_scores_measure_the_edges_the_gates_read(self):
        truth = (0.5, 0.40, 0.70, 0.06)
        tc = t.rect_corners(truth)
        rows = []
        for i, (group, dx, dtop) in enumerate((("g1", 0.0, 0.01), ("g1", 0.02, -0.02), ("g2", -0.01, 0.03), ("g3", 0.0, 0.0))):
            pred = tuple((x + dx, y + dtop) for x, y in tc)   # a whole-net shift: the tape moves by dtop, the sides by dx
            rows.append({"video": f"v{i}", "group": group, "surface": "beach", "has_net": True, "presence": 0.9,
                         "pred": t.letterbox_corners(pred, 1920, 1080), "truth": t.letterbox_corners(tc, 1920, 1080), "w": 1920, "h": 1080})
        rows.append({"video": "miss", "group": "g3", "surface": "grass", "has_net": True, "presence": 0.2,
                     "pred": t.letterbox_corners(tc, 1920, 1080), "truth": t.letterbox_corners(tc, 1920, 1080), "w": 1920, "h": 1080})
        rows.append({"video": "empty", "group": "x", "surface": "extra", "has_net": False, "presence": 0.1, "pred": ((0, 0),) * 4,
                     "truth": None, "w": 1920, "h": 1080})
        m = t.summarize(rows, draws=50)
        self.assertEqual((m["frames"], m["detected"]), (5, 4))
        self.assertAlmostEqual(m["detect_rate"], 0.8)
        self.assertAlmostEqual(m["top_error"]["median"], 0.015, places=5)
        self.assertAlmostEqual(m["top_error"]["mean"], 0.015, places=5)
        self.assertAlmostEqual(m["left_error"]["median"], 0.005, places=5)
        self.assertAlmostEqual(m["corner_error"]["median"], (0.01 + (0.02 ** 2 + 0.02 ** 2) ** 0.5) / 2, places=5)
        # A tilted prediction over a flat truth: the top error is the tape ends' mean, not the box top.
        tilt = tuple((x, y + (0.04 if i == 1 else 0.0)) for i, (x, y) in enumerate(tc))
        one = t.summarize([{"video": "v", "group": "g", "surface": "beach", "has_net": True, "presence": 0.9,
                            "pred": t.letterbox_corners(tilt, 1920, 1080), "truth": t.letterbox_corners(tc, 1920, 1080), "w": 1920, "h": 1080}], draws=5)
        self.assertAlmostEqual(one["top_error"]["median"], 0.02, places=5)
        self.assertAlmostEqual(one["corner_error"]["median"], 0.01, places=5)
        self.assertAlmostEqual(m["top_error_mean_with_misses"], (0.01 + 0.02 + 0.03 + 0.0 + 1.0) / 5, places=5)
        self.assertEqual(m["no_net_frames"], 1)
        self.assertAlmostEqual(m["no_net_correct"], 1.0)
        self.assertEqual(m["by_surface"]["grass"]["detected"], 0)
        self.assertIsNone(m["by_surface"]["grass"]["top_error"]["median"])
        self.assertEqual(sorted(m["by_group"]), ["g1", "g2", "g3"])
        self.assertEqual(m["by_group"]["g3"]["frames"], 2)
        self.assertEqual(m["top_median_range90"]["groups"], 3)
        self.assertLessEqual(m["top_median_range90"]["low"], m["top_median_range90"]["high"])
        self.assertGreater(m["iou_mean"], 0.5)

    def test_names_are_read_from_both_yaml_shapes(self):
        y = self.tmp / "a.yaml"
        y.write_text("names: ['ball', 'net']\n")
        self.assertEqual(t.read_names(y), {0: "ball", 1: "net"})
        y.write_text("path: .\nnames:\n  0: net\n  1: ball\n")
        self.assertEqual(t.read_names(y), {0: "net", 1: "ball"})
        y.write_text("names:\n  - ball\n  - net\n")
        self.assertEqual(t.read_names(y), {0: "ball", 1: "net"})


@unittest.skipUnless(HAVE_TORCH, "torch is not installed")
class TrainingTests(unittest.TestCase):
    def setUp(self):
        if cv2 is None:
            self.skipTest("opencv-python is not installed")
        self.tmp = Path(tempfile.mkdtemp(prefix="net-trainer-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def train(self, f: Fixture, name: str, extra=(), epochs: int = 3, more=()):
        argv = [str(f.export), "--manifest", str(f.manifest), "--epochs", str(epochs), "--batch", "4", "--workers", "0",
                "--seed", "1", "--name", name, "--runs", str(self.tmp / "runs"), "--bring-back", str(self.tmp / "bring_back")]
        for e in extra:
            argv += ["--extra", str(e)]
        t.main(argv + list(more))
        return self.tmp / "runs" / name

    def test_a_run_writes_its_record_and_score_only_reproduces_the_best(self):
        f = Fixture(self.tmp)
        run = self.train(f, "fixture", extra=[f.extra()])
        for name in ("best.pt", "best.onnx", "metrics.json", "log.csv", "split.json"):
            self.assertTrue((run / name).exists(), name)
            self.assertTrue((self.tmp / "bring_back" / "fixture" / name).exists(), f"bring_back/{name}")
        m = json.loads((run / "metrics.json").read_text())
        self.assertEqual(m["train_frames"] + m["val_frames"], len(RECORDINGS) + 4)
        self.assertEqual(m["extras"][0]["provenance"]["license"], "CC BY 4.0")
        self.assertEqual(m["dataset"]["entries"], len(RECORDINGS))
        self.assertEqual(len(m["manifest_sha256"]), 64)
        self.assertIn(m["best_epoch"], (1, 2, 3))
        self.assertEqual(m["best"]["frames"], m["val_frames"])
        self.assertEqual(len(m["best"]["per_frame"]), m["val_frames"])
        self.assertEqual(len(m["best"]["per_frame"][0]["top"]), 2, "the two tape ends")
        self.assertIsNotNone(m["best"]["corner_error"]["median"])
        self.assertEqual(sorted(m["val_groups"]), m["val_groups"])
        split = json.loads((run / "split.json").read_text())
        self.assertEqual(split["val_groups"], m["val_groups"])
        with self.assertRaises(SystemExit):   # the same name again is refused
            self.train(f, "fixture")
        # Scoring the kept checkpoint on the same split gives the same numbers it was kept for.
        scored = self.train(f, "fixture-scored", more=["--score-only", str(run / "best.pt"), "--split", str(run / "split.json")])
        s = json.loads((scored / "metrics.json").read_text())
        self.assertEqual(s["val_digest"], m["val_digest"])
        self.assertEqual(s["scored_weights"]["sha256"], m["best_sha256"])
        self.assertAlmostEqual(s["scored"]["top_error_mean_with_misses"], m["best"]["top_error_mean_with_misses"], places=5)
        self.assertEqual([r["video"] for r in s["scored"]["per_frame"]], [r["video"] for r in m["best"]["per_frame"]])
        self.assertFalse((scored / "best.pt").exists(), "nothing is trained")

    def test_augmentation_is_fresh_each_epoch_and_repeatable(self):
        f = Fixture(self.tmp)
        _, rows = t.load_manifest(f.manifest)
        samples, _ = t.read_rallylab_export(f.export, rows)
        frames = t.Frames(samples, True, seed=1)
        frames.epoch = 1
        x1, t1, _, _ = frames[0]
        x1_again, t1_again, _, _ = frames[0]
        frames.epoch = 2
        x2, t2, _, _ = frames[0]
        self.assertTrue((x1 == x1_again).all() and (t1 == t1_again).all(), "the same seed, epoch and index: the same augmentation")
        self.assertFalse((x1 == x2).all() and (t1 == t2).all(), "another epoch: another augmentation of the same frame")
        plain = t.Frames(samples, False, seed=1)
        self.assertTrue((plain[0][0] == plain[0][0]).all())
        self.assertFalse((plain[0][0] == x1).all(), "validation frames are not augmented")

    def test_a_withheld_recording_stops_the_run_before_anything_is_written(self):
        f = Fixture(self.tmp, withhold="bch_onl_ovc_land_onl_02")
        with self.assertRaises(SystemExit) as cm:
            self.train(f, "withheld")
        self.assertIn("withheld", str(cm.exception))
        self.assertFalse((self.tmp / "runs").exists())

    def test_a_longer_run_learns_the_band(self):
        """Not a benchmark: twelve frames with a plain bright band are learnable in a few
        dozen epochs on the CPU, and the point is that the loss, the scores and the
        checkpoint choice all point the same way (the kept epoch is the best one seen)."""
        f = Fixture(self.tmp, size=(160, 90))
        run = self.train(f, "learns", epochs=30, more=["--lr", "3e-3"])
        m = json.loads((run / "metrics.json").read_text())
        rows = list(__import__("csv").reader((run / "log.csv").open()))[1:]
        keys = [float(r[6]) for r in rows]
        self.assertAlmostEqual(min(keys), m["best"]["top_error_mean_with_misses"], places=6)
        self.assertEqual(keys.index(min(keys)) + 1, m["best_epoch"])
        self.assertLess(m["best"]["top_error_mean_with_misses"], keys[0], "better than after the first epoch")

    @unittest.skipUnless(HAVE_COREML, "coremltools is not installed")
    def test_core_ml_conversion_matches_torch(self):
        import net_to_coreml
        f = Fixture(self.tmp)
        run = self.train(f, "coreml", epochs=1)
        out = self.tmp / "net.mlpackage"
        diff = net_to_coreml.convert(run / "best.pt", out)
        self.assertTrue(out.exists())
        self.assertLessEqual(diff, net_to_coreml.MAX_DIFF)


if __name__ == "__main__":
    unittest.main()
