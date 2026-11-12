"""Tests for scripts/player_features/make_review_page.py: the page carries every row of both sheets, starts with no
label filled, and can't break out of its script tag.

    python3 -m unittest scripts.tests.test_make_review_page -v
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "player_features"))
import make_review_page as m  # noqa: E402


class MakeReviewPage(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="review-")
        with open(os.path.join(self.dir, "persons.csv"), "w") as f:
            f.write("recording,interval,tick,t,image,track,box_x,box_y,box_w,box_h,label,reviewer,notes\n")
            f.write("rec,a,600,1.000,frames/rec_600.jpg,3,0.1,0.2,0.05,0.2,,,</script>\n")
        with open(os.path.join(self.dir, "frames.csv"), "w") as f:
            f.write("recording,interval,tick,t,image,missed_near_players,missed_far_players,reviewer,notes\n")
            f.write("rec,a,600,1.000,frames/rec_600.jpg,,,,\n")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def test_page_holds_the_sheets_unfilled(self):
        html = open(m.build(self.dir), encoding="utf-8").read()
        script = html[html.index("<script>") + 8:html.rindex("</script>")]
        self.assertNotIn("</script>", script, "a cell can't end the script early")
        data = json.loads(script[script.index("const D = ") + 10:script.index(";\nconst KEY")].replace("<\\/", "</"))
        self.assertEqual(len(data["persons"]), 1)
        self.assertEqual(data["persons"][0]["label"], "")
        self.assertEqual(data["frames"][0]["missed_near_players"], "")
        self.assertIn("duplicate_or_not_a_person", [l[0] for l in data["labels"]])


if __name__ == "__main__":
    unittest.main()
