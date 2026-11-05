"""Tests for scripts/train_rally_classifier.py: cut-range handling (D-030) — intervals
outside the cuts, a decision that never bridges a cut, an export with no frames (a
recording cut whole) skipped rather than crashing the run — and the marks' kinds
(2026-11-04): a schema-1 export refused, an incomplete pass refused, a negative-only
export scored for false clips, a rally the only positive.

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
        export = {"schema": 2, "video": "whole.mp4", "duration": 100.0, "netTopY": None, "netBottomY": None,
                  "labels": [], "excluded": [], "baselineRaw": [], "cuts": [{"start": 0.0, "end": 100.0}], "complete": True, "frames": []}
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "whole.trainingdata.json")
            with open(path, "w") as f:
                json.dump(export, f)
            weights = os.path.join(d, "weights.json")
            out = _run([path], weights)
            self.assertIn("skipped", out)
            self.assertFalse(os.path.exists(weights), "no weights are written for a run that trained on nothing")


def _run(paths, weights_path):
    """Run the trainer's main over `paths`, weights written to `weights_path`; the printed output."""
    out = io.StringIO()
    argv, weights = sys.argv, t.WEIGHTS_OUT
    sys.argv = ["train_rally_classifier.py"] + paths
    t.WEIGHTS_OUT = weights_path
    try:
        with contextlib.redirect_stdout(out):
            t.main()
    finally:
        sys.argv, t.WEIGHTS_OUT = argv, weights
    return out.getvalue()


def _frames(duration, step=0.25, ball_in=()):
    """Frames every `step` s; the ball seen (and flying) inside the `ball_in` spans only."""
    rows = []
    n = int(duration / step)
    for i in range(n):
        tt = i * step
        inside = any(s <= tt <= e for s, e in ball_in)
        rows.append({"t": tt, "ball": 1 if inside else 0, "proj": 1 if inside else 0, "r2": 0.95 if inside else None,
                     "grav": 1.0 if inside else None, "x": 0.5 if inside else None, "y": 0.5 if inside else None,
                     "size": 0.02 if inside else None, "dets": 1 if inside else 0, "courtDets": 1 if inside else 0,
                     "conf": 0.9 if inside else None, "move": None, "rej": None, "cands": 1 if inside else 0})
    return rows


class MarkKinds(unittest.TestCase):
    """Schema 2 (2026-11-04): labels are the rallies by kind, excluded the missed serves and other marks (masked
    like the cuts), complete says the pass is finished; a schema-1 export is refused, a negative-only export is
    read."""

    def test_a_schema_1_export_is_refused_its_labels_may_be_missed_serves(self):
        export = {"schema": 1, "video": "old.mp4", "duration": 40.0, "netTopY": None, "netBottomY": None,
                  "labels": [{"start": 10.0, "end": 20.0}], "baselineRaw": [], "cuts": [], "frames": _frames(40, ball_in=[(10, 20)])}
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "old.trainingdata.json")
            with open(path, "w") as f:
                json.dump(export, f)
            weights = os.path.join(d, "weights.json")
            out = _run([path], weights)
            self.assertIn("schema 1 export", out)
            self.assertIn("skipped", out)
            self.assertFalse(os.path.exists(weights), "nothing trained on a refused export")

    def test_an_incomplete_pass_is_refused(self):
        export = {"schema": 2, "video": "half.mp4", "duration": 40.0, "netTopY": None, "netBottomY": None,
                  "labels": [{"start": 10.0, "end": 20.0}], "excluded": [], "baselineRaw": [], "cuts": [], "complete": False,
                  "frames": _frames(40, ball_in=[(10, 20)])}
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "half.trainingdata.json")
            with open(path, "w") as f:
                json.dump(export, f)
            out = _run([path], os.path.join(d, "weights.json"))
            self.assertIn("not a complete marking pass", out)
            self.assertNotIn("frame-level", out)

    def test_a_negative_only_export_is_scored_for_false_clips_and_fits_nothing(self):
        # A complete pass with no rally: a missed serve at 10–12 (excluded), the ball flying there and in a burst
        # at 30–33 the rule decider cut as a clip — a false clip; its clip over the missed serve is unscored.
        export = {"schema": 2, "video": "neg.mp4", "duration": 40.0, "netTopY": None, "netBottomY": None,
                  "labels": [], "excluded": [{"start": 10.0, "end": 12.0}],
                  "baselineRaw": [{"start": 10.0, "end": 12.0}, {"start": 30.0, "end": 33.0}],
                  "cuts": [], "complete": True, "frames": _frames(40, ball_in=[(10, 12), (30, 33)])}
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "neg.trainingdata.json")
            with open(path, "w") as f:
                json.dump(export, f)
            weights = os.path.join(d, "weights.json")
            out = _run([path], weights)
            self.assertIn("negative-only", out)
            self.assertIn("excluded spans (missed serves, not a rally) 1", out)
            self.assertIn("AUC n/a (no rally)", out)
            self.assertIn("baseline (rule decider) : P 0.000  R 0.000", out, "the clip at 30–33 is a false clip; the one inside the missed serve is unscored")
            self.assertFalse(os.path.exists(weights), "no rally to fit: no weights from a negative-only export")

    def test_a_complete_export_with_rallies_trains_on_its_labels_only(self):
        # A rally at 10–20 and a missed serve at 30–32, both with the ball flying: only the rally is a positive;
        # the missed serve's frames are masked (neither class), and the baseline's clip over it is unscored.
        export = {"schema": 2, "video": "pass.mp4", "duration": 60.0, "netTopY": None, "netBottomY": None,
                  "labels": [{"start": 10.0, "end": 20.0}], "excluded": [{"start": 30.0, "end": 32.0}],
                  "baselineRaw": [{"start": 10.0, "end": 20.0}, {"start": 30.0, "end": 32.0}, {"start": 45.0, "end": 47.0}],
                  "cuts": [], "complete": True, "frames": _frames(60, ball_in=[(10, 20), (30, 32)])}
        X, names, times, y = t.build_features(export)
        self.assertEqual(int(y.sum()), len([f for f in export["frames"] if 10 <= f["t"] <= 20]), "in-rally frames are the rally's only")
        self.assertTrue(all(y[i] == 0 for i, tt in enumerate(times) if 30 <= tt <= 32), "the missed serve's frames are not rally frames")
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "pass.trainingdata.json")
            with open(path, "w") as f:
                json.dump(export, f)
            weights = os.path.join(d, "weights.json")
            out = _run([path], weights)
            self.assertIn("rallies 1  excluded spans (missed serves, not a rally) 1", out)
            self.assertIn("baseline (rule decider) : P 0.500  R 1.000", out,
                          "the clip over the missed serve is unscored; the one at 45–47 is the false clip")
            self.assertTrue(os.path.exists(weights))


if __name__ == "__main__":
    unittest.main()
