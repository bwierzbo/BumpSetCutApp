"""Tests for scripts/player_features/summarize_pilot.py: the run's own summary rows grouped
by interval kind, accuracy only from a filled audit sheet, an unfilled audit row counting
for nothing.

    python3 -m unittest scripts.tests.test_summarize_player_pilot -v
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "player_features"))
import summarize_pilot as s  # noqa: E402
import validate_player_features as v  # noqa: E402


class SummarizePilot(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="player-summary-")
        v.write_synthetic(os.path.join(self.tmp, "features"))
        os.makedirs(os.path.join(self.tmp, "diagnostics"))
        rows = [{"recording": "rec_a", "interval": "active_1", "kind": "active_play", "poseShare": 0.6, "meanSpeedInCourt": 0.2},
                {"recording": "rec_b", "interval": "active_1", "kind": "active_play", "poseShare": 0.8, "meanSpeedInCourt": None},
                {"recording": "rec_a", "interval": "between_1", "kind": "between_rallies", "poseShare": 0.5, "meanSpeedInCourt": 0.05}]
        v.write_bytes(os.path.join(self.tmp, "diagnostics", "summary.json"), json.dumps(rows).encode())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_rows_grouped_by_interval_kind(self):
        out = s.summarize(self.tmp)
        self.assertEqual(len(out["rows"]), 3)
        self.assertAlmostEqual(out["byIntervalKind"]["active_play"]["poseShare"], 0.7)
        self.assertAlmostEqual(out["byIntervalKind"]["active_play"]["meanSpeedInCourt"], 0.2, msg="a null is left out, not counted as 0")
        self.assertAlmostEqual(out["byIntervalKind"]["between_rallies"]["meanSpeedInCourt"], 0.05)
        self.assertNotIn("audit", out)

    def test_audit_counts_only_filled_rows(self):
        path = os.path.join(self.tmp, "audit.csv")
        v.write_bytes(path, (
            "recording,interval,tick,t,overlay,persons,in_court,poses,unmatched_poses,visible_on_court_players,detected_on_court_players,"
            "missed_on_court_players,false_on_court_detections,off_court_detections,identity_switches_vs_previous_sampled,poses_plausible,reviewer,notes\n"
            "rec_a,active_1,6000,10.0,x,1,1,1,0,4,3,1,0,2,0,yes,r,\n"
            "rec_a,active_1,6120,10.2,x,1,1,1,0,4,2,2,1,0,1,no,r,\n"
            "rec_a,between_1,18000,30.0,x,0,0,0,0,2,0,2,0,0,,na,r,\n"
            "rec_b,active_1,3000,5.0,x,1,0,0,0,,,,,,,,,\n").encode())
        a = s.summarize(self.tmp, path)["audit"]
        self.assertEqual(a["ALL"]["frames"], 3)
        self.assertAlmostEqual(a["ALL"]["recall"], 5 / 10)
        self.assertAlmostEqual(a["ALL"]["falseOnCourtPerFrame"], 1 / 3)
        self.assertEqual(a["ALL"]["identitySwitches"], 1)
        self.assertAlmostEqual(a["ALL"]["posesPlausibleShare"], 0.5, msg="the na row leaves the denominator")
        self.assertNotIn("rec_b", a)

    def test_unfilled_identity_column_is_not_assessed(self):
        path = os.path.join(self.tmp, "audit.csv")
        v.write_bytes(path, (
            "recording,interval,tick,t,overlay,persons,in_court,poses,unmatched_poses,visible_on_court_players,detected_on_court_players,"
            "missed_on_court_players,false_on_court_detections,off_court_detections,identity_switches_vs_previous_sampled,poses_plausible,reviewer,notes\n"
            "rec_a,active_1,6000,10.0,x,1,1,1,0,4,3,1,0,0,,yes,r,\n").encode())
        self.assertIsNone(s.summarize(self.tmp, path)["audit"]["ALL"]["identitySwitches"])


if __name__ == "__main__":
    unittest.main()
