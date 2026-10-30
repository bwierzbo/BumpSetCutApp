"""Tests for scripts/desktop_training/get_net_dataset.py on a synthetic COCO export.

    python3 -m unittest discover -s scripts/tests -v
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "desktop_training"))

try:
    from PIL import Image
except ImportError:  # the CI runner's system Python may not have Pillow
    Image = None

if Image is not None:
    import get_net_dataset as net  # noqa: E402


@unittest.skipIf(Image is None, "Pillow not installed")
class CleanTests(unittest.TestCase):
    def export(self, root: Path) -> Path:
        """train: an outlined net, its augmented copy, a withheld recording's frame, a frame
        with only a ball; valid: a box-only net on a 16:9 frame."""
        raw = root / "export"
        frames = {
            "train": [("clipA_0001_jpg.rf.aaa.jpg", 640, 640), ("clipA_0001_jpg.rf.bbb.jpg", 640, 640),
                      ("bch_withheld_01_f3_jpg.rf.ccc.jpg", 640, 640), ("clipB_0007_jpg.rf.ddd.jpg", 640, 640)],
            "valid": [("clipC_0002_jpg.rf.eee.jpg", 1280, 720)],
        }
        annotations = {
            "train": [{"id": 1, "image_id": 0, "category_id": 1, "bbox": [64, 192, 512, 96],
                       "segmentation": [[64, 192, 576, 192, 576, 288, 64, 288]]},
                      {"id": 2, "image_id": 1, "category_id": 1, "bbox": [64, 192, 512, 96], "segmentation": []},
                      {"id": 3, "image_id": 2, "category_id": 1, "bbox": [0, 0, 64, 64], "segmentation": []},
                      {"id": 4, "image_id": 3, "category_id": 2, "bbox": [1, 1, 8, 8], "segmentation": []}],
            "valid": [{"id": 5, "image_id": 0, "category_id": 1, "bbox": [128, 288, 1024, 144], "segmentation": []}],
        }
        for split, items in frames.items():
            (raw / split).mkdir(parents=True)
            images = []
            for i, (name, w, h) in enumerate(items):
                Image.new("RGB", (w, h), (40 * i, 90, 120)).save(raw / split / name)
                images.append({"id": i, "file_name": name, "width": w, "height": h})
            (raw / split / net.COCO_FILE).write_text(json.dumps({
                "images": images, "annotations": annotations[split],
                "categories": [{"id": 0, "name": "nets"}, {"id": 1, "name": "net"}, {"id": 2, "name": "ball"}]}))
        return raw

    def test_clean_keeps_nets_drops_copies_and_withheld(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "out"
            counts = net.clean(self.export(root), out, unstretch=True, exclude=["bch_withheld_01"])
            labels = json.loads((out / "labels.json").read_text())

            self.assertEqual(counts["images"], 3)
            self.assertEqual(counts["copies dropped"], 1)
            self.assertEqual(counts["excluded"], 1)
            self.assertEqual(counts["excluded sources"], ["bch_withheld_01_f3_jpg"])
            self.assertEqual((counts["polygon"], counts["box only"], counts["no net"]), (1, 1, 1))
            self.assertFalse(any("withheld" in k for k in labels), "a withheld recording's frame was kept")

            outlined = labels["train_clipA_0001_jpg.rf.aaa.jpg"]
            self.assertEqual(outlined["size"], [1138, 640], "a square export is un-stretched to 16:9")
            self.assertEqual(outlined["nets"][0]["box"], [0.1, 0.3, 0.8, 0.15])
            self.assertEqual(outlined["nets"][0]["polygon"], [[0.1, 0.3], [0.9, 0.3], [0.9, 0.45], [0.1, 0.45]])

            boxed = labels["valid_clipC_0002_jpg.rf.eee.jpg"]
            self.assertEqual(boxed["size"], [1280, 720], "a 16:9 frame is left as it is")
            self.assertIsNone(boxed["nets"][0]["polygon"])
            self.assertEqual(labels["train_clipB_0007_jpg.rf.ddd.jpg"]["nets"], [], "the ball class is dropped")

    def test_manifest_hashes_every_file_and_names_label_kinds(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = root / "out"
            counts = net.clean(self.export(root), out, unstretch=True, exclude=[])
            net.write_manifest(out, {"export": "x.zip", "licence": "your own"}, counts)
            manifest = json.loads((out / "manifest.json").read_text())

            self.assertEqual(manifest["labelKinds"], "mixed")
            self.assertEqual(set(manifest["files"]), {"labels.json"} | {f"images/{k}" for k in
                                                                      json.loads((out / "labels.json").read_text())})
            self.assertEqual(manifest["files"]["labels.json"], net.sha256(out / "labels.json"))


if __name__ == "__main__":
    unittest.main()
