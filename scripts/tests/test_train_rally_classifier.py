"""Tests for scripts/train_rally_classifier.py's cut-range handling (D-030): intervals
outside the cuts, a decision that never bridges a cut, and an export with no frames
(a recording cut whole) skipped rather than crashing the run.

    python3 -I -m unittest scripts.tests.test_train_rally_classifier -v
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

try:
    import numpy as np
except ImportError:   # the trainer is numpy throughout; the checker's CI runner has no numpy
    raise unittest.SkipTest("numpy is not installed: the rally classifier's tests run where it is (desktop, Mac)")

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import train_rally_classifier as t  # noqa: E402


class CutRanges(unittest.TestCase):
    def test_subtract_cuts_keeps_the_pieces_outside(self):
        self.assertEqual(t.subtract_cuts([(9, 21), (30, 40), (49, 61)], [(28, 42)]), [(9, 21), (49, 61)])
        self.assertEqual(t.subtract_cuts([(10, 30)], [(18, 22)]), [(10, 18), (22, 30)])
        self.assertEqual(t.subtract_cuts([(10, 30)], []), [(10, 30)])
        self.assertEqual(t.subtract_cuts([(10, 30)], [(0, 100)]), [])

    def test_a_decision_never_bridges_a_cut(self):
        times = np.array([10, 10.3, 11, 48, 49, 50, 51, 52, 53], dtype=float)
        probs = np.ones(len(times))
        h = t.HYST_DEFAULT
        args = (h["enter"], h["exit"], h["enter_sustain"], h["exit_sustain"])
        self.assertEqual(t.hysteresis_decode(times, probs, *args), [(10.0, 53.0)])
        self.assertEqual(t.decode_outside_cuts(times, probs, [(12, 48)], *args), [(48.0, 53.0)])
        self.assertEqual(t.decode_outside_cuts(times, probs, [], *args), t.hysteresis_decode(times, probs, *args))

    def test_an_export_with_no_frames_is_skipped_not_a_crash(self):
        export = {"schema": 1, "video": "whole.mp4", "duration": 100.0, "netTopY": None, "netBottomY": None,
                  "labels": [], "baselineRaw": [], "cuts": [{"start": 0.0, "end": 100.0}], "frames": []}
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "whole.trainingdata.json")
            with open(path, "w") as f:
                json.dump(export, f)
            weights = os.path.join(os.path.dirname(t.__file__), "rally_classifier_weights.json")
            before = os.path.getmtime(weights) if os.path.exists(weights) else None
            out = io.StringIO()
            argv = sys.argv
            sys.argv = ["train_rally_classifier.py", path]
            try:
                with contextlib.redirect_stdout(out):
                    t.main()
            finally:
                sys.argv = argv
            self.assertIn("skipped", out.getvalue())
            after = os.path.getmtime(weights) if os.path.exists(weights) else None
            self.assertEqual(before, after, "no weights are written for a run that trained on nothing")


if __name__ == "__main__":
    unittest.main()
