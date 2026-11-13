"""Tests for scripts/rally_classifier/decode.py: the decode grid, the hysteresis and the raw floor on
hand-computed cases, the SegmentBuilder port against the contract's cases, and the parity check that must stop
a run when the port or the fixture is wrong. Synthetic data only.

    python3 -m unittest scripts.tests.test_rally_classifier_decode -v
"""

import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

try:
    import numpy as np
except ImportError:   # the checker's CI runner has no numpy; these run where the trainer does
    raise unittest.SkipTest("numpy is not installed: the rally-classifier trainer's tests run where it is")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rally_classifier_synthetic as syn  # noqa: E402
import decode  # noqa: E402
import validate_dataset as v  # noqa: E402

R0 = {"prerollSec": 2.0, "postrollSec": 0.5, "joinSec": 1.3513, "minSegmentSec": 2.6131}
R0_PRIME = {"prerollSec": 2.0, "postrollSec": 1.0, "joinSec": 0.0, "minSegmentSec": 1.5}
POINT = {"thetaOn": 0.7, "thetaOff": 0.3, "sustainOnSec": 0.2, "sustainOffSec": 0.8}


def spans(clips):
    return [(c["startTick"], c["endTick"]) for c in clips]


def series(*runs):
    """Ticks 20 apart (30 Hz) and their probabilities from (probability, steps) runs."""
    p = [q for q, n in runs for _ in range(n)]
    return [20 * i for i in range(len(p))], p


class Grid(unittest.TestCase):
    def test_the_grid_and_its_order(self):
        self.assertEqual(len(decode.GRID), 4 * 3 * 3 * 3)
        self.assertEqual(decode.GRID[0], {"thetaOn": 0.5, "thetaOff": 0.2, "sustainOnSec": 0.1, "sustainOffSec": 0.4})
        self.assertEqual(decode.GRID[1], {"thetaOn": 0.5, "thetaOff": 0.2, "sustainOnSec": 0.1, "sustainOffSec": 0.8})
        self.assertEqual(decode.GRID[-1], {"thetaOn": 0.8, "thetaOff": 0.4, "sustainOnSec": 0.4, "sustainOffSec": 1.2})
        self.assertEqual({(g["thetaOn"], g["thetaOff"]) for g in decode.GRID}, {(a, b) for a in (0.5, 0.6, 0.7, 0.8) for b in (0.2, 0.3, 0.4)})
        self.assertEqual(decode.RAW_FLOOR_SEC, 1.1653)


class Hysteresis(unittest.TestCase):
    def test_enter_dates_back_to_the_runs_first_step_and_exit_to_the_first_low_step(self):
        # low 10 steps, high 60, low 60: the high run starts at tick 200, the low run at tick 1400
        ticks, p = series((0.1, 10), (0.9, 60), (0.1, 60))
        self.assertEqual(decode.hysteresis(ticks, p, POINT, 9999), [(200, 1400)])

    def test_a_high_run_shorter_than_the_sustain_does_not_open(self):
        # 0.2 s = 120 ticks: 6 steps span 100 ticks (no), 7 steps span 120 (yes)
        ticks, p = series((0.1, 5), (0.9, 6), (0.1, 60))
        self.assertEqual(decode.hysteresis(ticks, p, POINT, 9999), [])
        ticks, p = series((0.1, 5), (0.9, 7), (0.1, 60))
        self.assertEqual(decode.hysteresis(ticks, p, POINT, 9999), [(100, 240)])

    def test_a_dip_shorter_than_the_sustain_does_not_close(self):
        # 0.8 s = 480 ticks: a 24-step dip spans 460 ticks and is ridden out; a 25-step dip closes at its first step
        ticks, p = series((0.9, 30), (0.1, 24), (0.9, 30), (0.1, 25), (0.9, 3))
        self.assertEqual(decode.hysteresis(ticks, p, POINT, 9999), [(0, 20 * 84)])

    def test_between_the_thresholds_nothing_changes(self):
        ticks, p = series((0.5, 40), (0.9, 10), (0.5, 40), (0.1, 30), (0.5, 40))
        # 0.5 neither opens (idle) nor counts towards a close (active); it breaks a low run
        self.assertEqual(decode.hysteresis(ticks, p, POINT, 9999), [(800, 1800)])
        ticks, p = series((0.9, 10), (0.1, 20), (0.5, 1), (0.1, 20), (0.9, 5))
        self.assertEqual(decode.hysteresis(ticks, p, POINT, 7777), [(0, 7777)])

    def test_thresholds_are_inclusive_and_an_open_interval_ends_at_the_given_tick(self):
        ticks, p = series((0.7, 10), (0.3, 30))
        self.assertEqual(decode.hysteresis(ticks, p, POINT, 9999), [(0, 200)])
        ticks, p = series((0.1, 3), (0.9, 20))
        self.assertEqual(decode.hysteresis(ticks, p, POINT, 480), [(60, 480)])

    def test_two_rallies(self):
        ticks, p = series((0.9, 60), (0.1, 60), (0.9, 60), (0.1, 60))
        self.assertEqual(decode.hysteresis(ticks, p, POINT, 9999), [(0, 1200), (2400, 3600)])


class RawIntervals(unittest.TestCase):
    def rec(self, **kw):
        return {"durationSec": 20.0, "cutRanges": [], "timeBreakingSpans": [], **kw}

    def test_the_raw_floor_drops_short_intervals(self):
        # 1.1653 s is 699.18 ticks: an interval of 700 ticks stays, one of 680 goes
        ticks, p = series((0.9, 35), (0.1, 60), (0.9, 34), (0.1, 60))
        kept, dropped = decode.raw_intervals(self.rec(), np.array(ticks), [(0, len(ticks))], np.array(p), POINT, 30)
        self.assertEqual((kept, dropped), ([(0, 700)], 1))

    def test_a_segment_break_closes_the_interval_and_non_footage_opens_none(self):
        ticks = np.array([20 * i for i in range(300)])
        p = np.full(300, 0.9)
        rec = self.rec(cutRanges=[{"startTick": 2000, "endTick": 4000}])
        segs = [(0, 100), (100, 200), (200, 300)]            # footage, the cut, footage
        kept, dropped = decode.raw_intervals(rec, ticks, segs, p, POINT, 30)
        self.assertEqual(kept, [(0, 2000), (4000, 6000)])   # each ends one cell after its segment's last step
        self.assertEqual(dropped, 0)
        self.assertFalse(decode.is_footage(2000, rec))
        self.assertTrue(decode.is_footage(4000, rec))
        replay = self.rec(timeBreakingSpans=[{"startTick": 2000, "endTick": 4000, "trait": "replay", "origin": "proposed"}])
        self.assertEqual(decode.raw_intervals(replay, ticks, segs, p, POINT, 30)[0], kept)

    def test_an_interval_open_at_the_end_is_clamped_to_the_duration(self):
        ticks = np.array([20 * i for i in range(100)])
        kept, _ = decode.raw_intervals(self.rec(durationSec=1990 / 600), ticks, [(0, 100)], np.full(100, 0.9), POINT, 30)
        self.assertEqual(kept, [(0, 1990)])


class Port(unittest.TestCase):
    def test_padding_by_hand(self):
        # a long raw rally: 2 s before, 0.5 s after
        self.assertEqual(spans(decode.finalize_with_raw([(6000, 9000)], R0, 36000)), [(4800, 9300)])
        # a short one (under 2.5 s): 0.5 s before
        self.assertEqual(spans(decode.finalize_with_raw([(6000, 7440)], R0, 36000)), [(5700, 7740)])
        self.assertEqual(spans(decode.finalize_with_raw([(6000, 7500)], R0, 36000)), [(4800, 7800)])    # exactly 2.5 s is not short
        # clamped to the recording at both ends
        self.assertEqual(spans(decode.finalize_with_raw([(600, 3000), (33000, 35900)], R0, 36000)), [(0, 3300), (31800, 36000)])

    def test_the_contracts_cases(self):
        # two short raws join into one clip whose start follows the first short raw, not the union
        (clip,) = decode.finalize_with_raw([(24000, 24900), (26100, 27000)], R0, 36000)
        self.assertEqual((clip["startTick"], clip["endTick"]), (23700, 27300))
        self.assertEqual(clip["rawSpans"], [{"startTick": 24000, "endTick": 24900}, {"startTick": 26100, "endTick": 27000}])
        # a short raw before a long one pads to a later start than its successor: sorted by padded start
        self.assertEqual(spans(decode.finalize_with_raw([(6000, 6720), (6840, 9000)], R0, 36000)), [(5640, 9300)])
        # the join gap is compared in seconds: 811 ticks stay apart, 810 join
        self.assertEqual(spans(decode.finalize_with_raw([(6000, 7800), (10111, 12000)], R0, 36000)), [(4800, 8100), (8911, 12300)])
        self.assertEqual(spans(decode.finalize_with_raw([(6000, 7800), (10110, 12000)], R0, 36000)), [(4800, 12300)])
        # the minimum clip length likewise: 1568 ticks stay, 1567 go
        self.assertEqual(len(decode.finalize_with_raw([(1200, 2168)], R0, 36000)), 1)
        self.assertEqual(decode.finalize_with_raw([(1200, 2167)], R0, 36000), [])

    def test_the_d029_settings(self):
        # join 0: clips that touch join, clips one tick apart do not; post-roll 1.0 s; minimum 1.5 s
        self.assertEqual(spans(decode.finalize_with_raw([(6000, 9000), (10800, 14000)], R0_PRIME, 36000)), [(4800, 14600)])
        self.assertEqual(spans(decode.finalize_with_raw([(6000, 9000), (10801, 14000)], R0_PRIME, 36000)), [(4800, 9600), (9601, 14600)])
        self.assertEqual(spans(decode.finalize_with_raw([(24000, 24900), (26100, 27000)], R0_PRIME, 36000)), [(23700, 25500), (25800, 27600)])

    def test_what_the_port_does_not_cover_is_refused(self):
        with self.assertRaises(ValueError):
            decode.finalize_with_raw([(6000, 9000)], {**R0, "prerollSec": 2.0005}, 36000)
        with self.assertRaises(ValueError):
            decode.finalize_with_raw([(6000, 36001)], R0, 36000)
        with self.assertRaises(ValueError):
            decode.finalize_with_raw([(9000, 9000)], R0, 36000)


class Parity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rc-decode-")
        self.dataset = syn.write(self.tmp)
        self.manifest = v.load_manifest(self.dataset)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_the_port_rebuilds_every_stored_clip(self):
        checked = decode.parity(self.dataset, self.manifest)
        self.assertEqual(set(checked), {"r0", "r0_prime"})
        self.assertGreater(checked["r0"], 30)
        self.assertGreater(checked["r0_prime"], 30)
        merged = [c for r in self.manifest["recordings"] for c in v.read_baseline(self.dataset, r)["r0"] if len(c["rawSpans"]) == 2]
        self.assertTrue(merged)                 # the short-pair merge the raw union cannot rebuild is among them

    def test_a_wrong_fixture_stops_the_run(self):
        rec = self.manifest["recordings"][0]
        path = os.path.join(self.dataset, rec["baselineFile"])
        baseline = syn.read_json(path)
        baseline["variants"]["r0"][0]["startTick"] -= 60        # still a well-formed clip, no longer what the builder pads
        with open(path, "w") as fh:
            json.dump(baseline, fh)
        rec["baselineSha256"] = v.sha256_file(path)
        with open(os.path.join(self.dataset, "dataset-manifest.json"), "w") as fh:
            json.dump(self.manifest, fh)
        self.assertEqual(v.validate(self.dataset).errors, [])   # the validator checks the shape, not the padding
        with self.assertRaises(decode.ParityError) as ctx:
            decode.parity(self.dataset, v.load_manifest(self.dataset))
        self.assertIn(f"{rec['recordingId']} r0[0]", str(ctx.exception))
        self.assertIn("does not reproduce 1 of", str(ctx.exception))

    def test_a_wrong_port_stops_the_run(self):
        right = v.pad_and_merge

        def union_port(raw_spans, settings, duration_ticks):     # pads the union of the raws: the error the fixture exists to catch
            return right([(min(a for a, _ in raw_spans), max(b for _, b in raw_spans))], settings, duration_ticks)

        with mock.patch.object(v, "pad_and_merge", union_port):
            with self.assertRaises(decode.ParityError) as ctx:
                decode.parity(self.dataset, self.manifest)
        self.assertIn("syn_gra_00 r0[2]", str(ctx.exception))    # the recording with the short pair

        def no_short_cap(raw_spans, settings, duration_ticks):   # forgets the 0.5 s cap for short raws
            return [{"rawSpans": [{"startTick": a, "endTick": b}], "startTick": max(0, a - 1200), "endTick": min(duration_ticks, b + 300)}
                    for a, b in raw_spans]

        with mock.patch.object(v, "pad_and_merge", no_short_cap):
            with self.assertRaises(decode.ParityError):
                decode.parity(self.dataset, self.manifest)


if __name__ == "__main__":
    unittest.main()
