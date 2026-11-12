"""Tests for scripts/player_features/import_review_rows.py: only what the owner entered is written, the blank sheets are
kept, and a label or box the sheets don't have stops the import.

    python3 -m unittest scripts.tests.test_import_review_rows -v
"""

import csv
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "player_features"))
import import_review_rows as m  # noqa: E402

PERSONS = "recording,interval,tick,t,image,track,box_x,box_y,box_w,box_h,label,reviewer,notes\n"
FRAMES = "recording,interval,tick,t,image,missed_near_players,missed_far_players,reviewer,notes\n"


class ImportReviewRows(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="review-")
        with open(os.path.join(self.dir, "persons.csv"), "w") as f:
            f.write(PERSONS + "rec,a,600,1.000,frames/rec_600.jpg,3,0.1,0.2,0.05,0.2,,,\nrec,a,600,1.000,frames/rec_600.jpg,4,0.5,0.2,0.05,0.2,,,\n"
                    "rec,a,900,1.500,frames/rec_900.jpg,1,0.5,0.2,0.05,0.2,,,\n")
        with open(os.path.join(self.dir, "frames.csv"), "w") as f:
            f.write(FRAMES + "rec,a,600,1.000,frames/rec_600.jpg,,,,\nrec,a,900,1.500,frames/rec_900.jpg,,,,\n")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def rows(self, name):
        with open(os.path.join(self.dir, name), newline="") as f:
            return list(csv.DictReader(f))

    def export(self, labels, near=1, far=0):
        return {"artifact": "https://claude.ai/artifact/x",
                "labels": [{"id": "rec_600", "image": "frames/rec_600.jpg", "labels": labels, "missedNear": near, "missedFar": far, "notes": "two\nlines"}]}

    def test_fills_only_what_was_entered_and_keeps_the_blank_sheets(self):
        boxes, counted = m.fill(self.export({"3": "spectator"}), self.dir)
        self.assertEqual((boxes, counted), (1, 1))
        p = self.rows("persons.csv")
        self.assertEqual([r["label"] for r in p], ["spectator", "", ""], "an unlabelled box stays blank")
        self.assertTrue(p[0]["reviewer"].startswith("owner"))
        f = self.rows("frames.csv")
        self.assertEqual((f[0]["missed_near_players"], f[0]["missed_far_players"], f[0]["notes"]), ("1", "0", "two lines"))
        self.assertEqual((f[1]["missed_near_players"], f[1]["reviewer"]), ("", ""), "a frame nobody reviewed stays blank")
        self.assertEqual(self.rows("persons.blank.csv")[0]["label"], "")
        # A second import starts again from the blank sheets: a label taken back on the page is gone.
        m.fill(self.export({}, near=None, far=None), self.dir)
        self.assertEqual([r["label"] for r in self.rows("persons.csv")], ["", "", ""])

    def test_refuses_unknown_labels_and_boxes(self):
        with self.assertRaises(ValueError):
            m.fill(self.export({"3": "coach"}), self.dir)
        with self.assertRaises(ValueError):
            m.fill(self.export({"99": "spectator"}), self.dir)


if __name__ == "__main__":
    unittest.main()
