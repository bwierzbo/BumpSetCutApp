"""Tests for scripts/desktop_training/prepare_external_net_dataset.py on a synthetic
Roboflow-style YOLO export: smooth random images, a byte copy, a resized re-encoded
copy, label problems of every kind, an unclaimed file, a compare folder and a split
manifest with a withheld recording. Needs numpy and Pillow; skipped without them.

    ~/.venvs/heatconv/bin/python -m unittest scripts.tests.test_prepare_external_net_dataset -v
"""

import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError:   # the checker's CI runner has neither
    raise unittest.SkipTest("numpy and Pillow are needed: the dataset preparation tests run where they are (desktop, Mac)")

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "desktop_training"))
import prepare_external_net_dataset as P  # noqa: E402

NAMES = ["Player", "Volleyball", "Volleyball Net"]
NET = "2 0.5 0.4 0.6 0.1\n"
PLAYER = "0 0.3 0.7 0.07 0.3\n"


def smooth_image(seed: int, size=(320, 180)) -> Image.Image:
    rng = np.random.default_rng(seed)
    small = rng.integers(40, 200, size=(9, 16, 3), dtype=np.uint8)
    return Image.fromarray(small).resize(size, Image.BICUBIC)


def save_jpeg(img: Image.Image, path: Path, quality=92) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "JPEG", quality=quality)


def tree_hash(root: Path) -> str:
    h = hashlib.sha256()
    for p in sorted(root.rglob("*")):
        if p.is_file():
            h.update(str(p.relative_to(root)).encode())
            h.update(p.read_bytes())
    return h.hexdigest()


class Fixture:
    """An export with: good_00..good_05 (one net box each, plus a player), copy_exact
    (bytes of good_00), copy_resized (good_01 halved and re-encoded), two_nets, poly_net,
    no_net, decided (quarantined by a decision), shot_01 (a quarantined group)."""

    def __init__(self, root: Path):
        self.root = root
        self.export = root / "export"
        (self.export).mkdir(parents=True)
        (self.export / "data.yaml").write_text(f"train: ../train/images\nnc: 3\nnames: {NAMES}\n")
        self.files = {}
        for i in range(6):
            self.add(f"good_{i:02d}", smooth_image(i), NET + PLAYER, split="train" if i < 4 else "valid")
        src = self.export / "train" / "images" / self.files["good_00"]
        dst = self.export / "test" / "images" / "copy_exact_jpg.rf.aa.jpg"
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        self._label("test", dst.stem, NET)
        self.files["copy_exact"] = dst.name
        half = smooth_image(1).resize((160, 90))
        self.add("copy_resized", half, NET, split="test", quality=60)
        self.add("two_nets", smooth_image(10), NET + "2 0.48 0.56 0.02 0.11\n")
        self.add("poly_net", smooth_image(11), "2 0.2 0.35 0.8 0.35 0.8 0.45 0.2 0.45\n")
        self.add("no_net", smooth_image(12), PLAYER)
        self.add("decided", smooth_image(13), NET)
        self.add("shot_01", smooth_image(14), NET)
        self.config = {
            "dataset_id": "synthetic-net-v1",
            "net_class": "Volleyball Net",
            "source": {"augmentation": "none", "license": "CC BY 4.0"},
            "label_semantics": "synthetic",
            "near_duplicate": {"threshold": 0.99, "calibration_images": 4, "calibration_seed": 0},
            "groups": [
                {"id": "main", "match": "^(good|copy|two|poly|no|decided)_", "status": "eligible",
                 "evidence_type": "test", "confidence": "high"},
                {"id": "shots", "match": "^shot_", "status": "quarantined", "reason": "screen capture",
                 "evidence_type": "test", "confidence": "high"},
            ],
            "decisions": [{"file": self.files["decided"], "status": "quarantined", "reason": "bad box",
                           "evidence_type": "manual_inspection", "confidence": "high",
                           "proposed_correction": "drop line 1"}],
            "provenance": {"source": "synthetic", "license": "CC BY 4.0", "obtained": "2026-11-02T00:00:00Z",
                           "note": "test"},
        }
        self.config_path = root / "config.json"
        self.write_config()

    def add(self, stem, img, label, split="train", quality=92):
        name = f"{stem}_jpg.rf.{hashlib.md5(stem.encode()).hexdigest()[:8]}.jpg"
        save_jpeg(img, self.export / split / "images" / name, quality)
        self._label(split, Path(name).stem, label)
        self.files[stem] = name

    def _label(self, split, stem, text):
        d = self.export / split / "labels"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{stem}.txt").write_text(text)

    def write_config(self):
        self.config_path.write_text(json.dumps(self.config))

    def build(self, out_name="pkg", compare=None, manifest=None):
        cfg = P.load_config(self.config_path)
        records, audit = P.audit_and_decide(self.export, cfg, compare or {}, manifest)
        out = self.root / out_name
        P.write_package(out, self.export, cfg, records, audit, self.config_path)
        return out, json.loads((out / "manifest.json").read_text()), audit


def split_manifest(path: Path, withheld: str, alias: str) -> Path:
    videos = [
        {"video": withheld, "clipId": withheld, "aliasGroup": withheld, "split": "legacy_holdout"},
        {"video": alias, "clipId": alias, "aliasGroup": withheld, "split": "train"},
        {"video": "free_rec", "clipId": "free_rec", "aliasGroup": "free_rec", "split": "train"},
    ]
    path.write_text(json.dumps({"videos": videos}))
    return path


class PrepareTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.fx = Fixture(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def status(self, manifest):
        return {e["file"]: (e["status"], e["evidence_type"]) for e in manifest["entries"]}

    def test_statuses_package_contents_and_untouched_source(self):
        before = tree_hash(self.fx.export)
        out, m, audit = self.fx.build()
        self.assertEqual(tree_hash(self.fx.export), before, "the export must not be written to")
        st, f = self.status(m), self.fx.files
        # same size: the first by name stays (copy_exact sorts before good_00)
        self.assertEqual(st[f["copy_exact"]][0], "eligible")
        self.assertEqual(st[f["good_00"]], ("excluded", "exact_hash"))
        # different sizes: the larger original stays, the downsized copy goes
        self.assertEqual(st[f["copy_resized"]], ("excluded", "near_duplicate"))
        self.assertEqual(st[f["good_01"]][0], "eligible")
        for stem in ("two_nets", "poly_net", "no_net", "decided", "shot_01"):
            self.assertEqual(st[f[stem]][0], "quarantined", stem)
        self.assertEqual(sum(s == "eligible" for s, _ in st.values()), 6)
        self.assertEqual(audit["images_with_more_than_one_net"], 1)
        self.assertEqual(audit["images_without_a_net"], 1)
        self.assertEqual(audit["annotation_kinds_by_class"]["Volleyball Net"]["polygon"], 1)
        self.assertEqual(sorted(p.name for p in (out / "images").iterdir()),
                         sorted([f["copy_exact"]] + [f[f"good_{i:02d}"] for i in range(1, 6)]))
        label = (out / "labels" / f"{Path(f['good_02']).stem}.txt").read_text()
        self.assertEqual(label, "0 0.5 0.4 0.6 0.1\n", "net lines only, class 0, the source's numbers as written")
        raw = (out / "labels" / f"{Path(f['good_02']).stem}.txt").read_bytes()
        self.assertEqual(raw, b"0 0.5 0.4 0.6 0.1\n", "LF only, whatever the platform: the recorded hash is of these bytes")
        self.assertNotIn(b"\r", (out / "data.yaml").read_bytes())
        self.assertNotIn(str(self.tmp), (out / "audit.json").read_text(), "no machine path in the outputs")
        src = self.fx.export / "train" / "images" / f["good_02"]
        self.assertEqual((out / "images" / f["good_02"]).read_bytes(), src.read_bytes())
        decided = next(e for e in m["entries"] if e["file"] == f["decided"])
        self.assertEqual(decided["proposed_correction"], "drop line 1")
        self.assertNotIn("package_image", decided)
        self.assertEqual(P.read_names(out / "data.yaml"), ["net"])
        self.assertIn("NOT four corners", m["label_kind"])
        ex = json.loads((out / "exclusions.json").read_text())
        self.assertEqual(ex["package_manifest_digest"], m["digest"])
        self.assertEqual(sorted(e["file"] for e in ex["entries"]),
                         sorted(f[k] for k in ("good_00", "copy_resized", "two_nets", "poly_net", "no_net", "decided", "shot_01")))
        self.assertEqual([g["id"] for g in ex["excluded_groups"]], ["shots"])
        self.assertEqual(P.verify(out), [])
        (out / "exclusions.json").write_text("{}")
        self.assertIn("exclusions.json does not match the manifest", P.verify(out))

    def test_second_build_is_byte_identical(self):
        a, ma, _ = self.fx.build("a")
        b, mb, _ = self.fx.build("b")
        self.assertEqual(ma["digest"], mb["digest"])
        for name in ("manifest.json", "provenance.json", "data.yaml"):
            self.assertEqual((a / name).read_bytes(), (b / name).read_bytes())
        self.assertEqual(tree_hash(a / "images"), tree_hash(b / "images"))
        self.assertEqual(tree_hash(a / "labels"), tree_hash(b / "labels"))

    def test_unclaimed_image_stops_the_build(self):
        self.fx.add("stranger", smooth_image(20), NET)
        with self.assertRaisesRegex(P.PrepError, "matched by 0 source groups"):
            self.fx.build()

    def test_decision_for_a_missing_file_stops_the_build(self):
        self.fx.config["decisions"][0]["file"] = "nope.jpg"
        self.fx.write_config()
        with self.assertRaisesRegex(P.PrepError, "no such image"):
            self.fx.build()

    def test_threshold_that_misses_a_calibrated_copy_is_refused(self):
        self.fx.config["near_duplicate"]["threshold"] = 0.99999999
        self.fx.write_config()
        with self.assertRaisesRegex(P.PrepError, "misses synthetic copies"):
            self.fx.build()

    def test_existing_package_is_never_overwritten(self):
        self.fx.build("pkg")
        with self.assertRaisesRegex(P.PrepError, "already exists"):
            self.fx.build("pkg")

    def test_cross_source_copy_is_excluded(self):
        other = self.tmp / "other"
        other.mkdir()
        shutil.copyfile(self.fx.export / "train" / "images" / self.fx.files["good_02"], other / "free_rec.jpg")
        save_jpeg(smooth_image(3).resize((200, 112)), other / "free_rec_2.jpg", quality=50)
        manifest = split_manifest(self.tmp / "manifest.json", "held_rec", "held_rec_v2")
        _, m, audit = self.fx.build(compare={"ours": other}, manifest=manifest)
        st = self.status(m)
        self.assertEqual(st[self.fx.files["good_02"]], ("excluded", "exact_hash"))
        self.assertEqual(st[self.fx.files["good_03"]], ("excluded", "near_duplicate"))
        self.assertEqual(len(audit["cross_source"]["ours"]["matches"]), 2)

    def test_withheld_compare_image_is_refused_before_it_is_opened(self):
        other = self.tmp / "other"
        other.mkdir()
        (other / "other_cam.jpg").write_bytes(b"not an image")   # train split, but in the withheld alias group
        manifest = split_manifest(self.tmp / "manifest.json", "held_rec", "other_cam")
        with self.assertRaisesRegex(P.PrepError, "withheld recording other_cam — not opened"):
            self.fx.build(compare={"ours": other}, manifest=manifest)

    def test_undecodable_compare_image_is_named(self):
        other = self.tmp / "other"
        other.mkdir()
        (other / "free_rec.jpg").write_bytes(b"not an image")
        manifest = split_manifest(self.tmp / "manifest.json", "held_rec", "other_cam")
        with self.assertRaisesRegex(P.PrepError, "free_rec.jpg: cannot be decoded"):
            self.fx.build(compare={"ours": other}, manifest=manifest)

    def test_compare_needs_a_readable_manifest(self):
        other = self.tmp / "other"
        other.mkdir()
        save_jpeg(smooth_image(30), other / "free_rec.jpg")
        with self.assertRaisesRegex(P.PrepError, "needs --manifest"):
            self.fx.build(compare={"ours": other})
        rowless = self.tmp / "rowless.json"
        rowless.write_text(json.dumps({"videos": [{"video": "x", "split": "legacy_holdout"}]}))   # no aliasGroup
        with self.assertRaisesRegex(P.PrepError, "unreadable split manifest"):
            self.fx.build(compare={"ours": other}, manifest=rowless)
        bad = self.tmp / "bad.json"
        bad.write_text("{")
        with self.assertRaisesRegex(P.PrepError, "unreadable split manifest"):
            self.fx.build(compare={"ours": other}, manifest=bad)

    def test_verify_catches_tampering(self):
        out, m, _ = self.fx.build()
        stem = Path(self.fx.files["good_04"]).stem
        (out / "labels" / f"{stem}.txt").write_text("0 0.5 0.4 0.6 0.1\n0 0.9 0.9 0.5 0.5\n")
        shutil.copyfile(self.fx.export / "train" / "images" / self.fx.files["two_nets"], out / "images" / "extra.jpg")
        problems = P.verify(out)
        self.assertTrue(any("missing or changed" in p for p in problems), problems)
        self.assertTrue(any("not in the manifest" in p for p in problems), problems)
        data = json.loads((out / "manifest.json").read_text())
        data["counts"]["eligible"] = 999
        (out / "manifest.json").write_text(json.dumps(data))
        self.assertTrue(any("digest" in p for p in P.verify(out)))

    def test_trainer_reads_the_package(self):
        try:
            import train_net_model as t
        except ImportError as e:
            self.skipTest(f"trainer not importable here: {e}")
        out, _, _ = self.fx.build()
        samples, info = t.read_extra_folder(out)
        self.assertEqual(info["images"], 6)
        self.assertEqual(info["no_net_images"], 0)
        self.assertEqual(info["net_class_index"], 0)
        self.assertTrue(all(s.box is not None and s.source == out.name for s in samples))

    def test_non_ascii_config_round_trips_under_a_cp1252_default(self):
        """Codex P2 on 7420931: a Windows locale (cp1252) must not change what is read."""
        self.fx.config["provenance"]["note"] = "boxes — not corners; Główny sponsor"
        self.fx.config["groups"][0]["evidence"] = "boards — GALERIA WARMIŃSKA, façade"
        self.fx.config_path.write_bytes(json.dumps(self.fx.config, ensure_ascii=False).encode("utf-8"))
        original = Path.read_text

        def cp1252_default(path, encoding=None, errors=None, *args, **kwargs):
            return original(path, encoding or "cp1252", errors or "replace", *args, **kwargs)
        from unittest import mock
        with mock.patch.object(Path, "read_text", cp1252_default):
            out, m, _ = self.fx.build()
            self.assertEqual(P.verify(out), [])
            self.assertIn("Główny", m["groups"][0].get("evidence", "") + json.loads(
                (out / "provenance.json").read_text(encoding="utf-8"))["note"])
        for name in ("manifest.json", "provenance.json", "exclusions.json", "audit.json"):
            (out / name).read_bytes().decode("ascii")   # raises if any non-ASCII byte was written

    def test_trusted_negatives_round_trip(self):
        """Codex P2 on 964f182: a negative the config trusts is packaged and verifies."""
        self.fx.config["negatives_trusted"] = True
        self.fx.write_config()
        out, m, _ = self.fx.build()
        self.assertTrue(m["negatives_trusted"])
        neg = next(e for e in m["entries"] if e["file"] == self.fx.files["no_net"])
        self.assertEqual((neg["status"], neg["net_boxes"]), ("eligible", 0))
        self.assertEqual((out / neg["package_label"]).read_bytes(), b"")
        self.assertEqual(P.verify(out), [])
        try:
            import train_net_model as t
        except ImportError:
            return
        _, info = t.read_extra_folder(out)
        self.assertEqual(info["no_net_images"], 1)

    def test_untrusted_empty_label_fails_verify(self):
        out, m, _ = self.fx.build()
        self.assertFalse(m["negatives_trusted"])
        e = next(e for e in m["entries"] if e["status"] == "eligible")
        (out / e["package_label"]).write_bytes(b"")
        # a self-consistent manifest that claims a negative without the policy: only the policy check can refuse it
        e["package_label_sha256"], e["net_boxes"] = hashlib.sha256(b"").hexdigest(), 0
        m.pop("digest")
        m["digest"] = P.sha256_bytes(P.canonical(m))
        (out / "manifest.json").write_bytes(P.canonical(m))
        (out / "exclusions.json").write_bytes(P.canonical(P.exclusions(m)))
        problems = P.verify(out)
        self.assertEqual(len(problems), 1, problems)
        self.assertTrue(any("does not trust negatives" in p for p in problems), problems)

    def test_cli_verify_exit_codes(self):
        out, _, _ = self.fx.build()
        self.assertEqual(P.main(["verify", str(out)]), 0)
        (out / "data.yaml").write_text("names: ['ball']\n")
        self.assertEqual(P.main(["verify", str(out)]), 1)


if __name__ == "__main__":
    unittest.main()
