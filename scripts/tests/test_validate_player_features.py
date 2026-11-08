"""Tests for scripts/player_features/validate_player_features.py on its own synthetic
folder: the example validates clean, and each rule of the player_features_v1 contract
refuses the mutation it exists for. Standard library only.

    python3 -m unittest scripts.tests.test_validate_player_features -v
"""

import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "player_features"))
import validate_player_features as v  # noqa: E402


class SyntheticPlayerFeatures(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="player-features-")
        self.folder = os.path.join(self.tmp, "features")
        v.write_synthetic(self.folder)
        self.mpath = os.path.join(self.folder, v.MANIFEST)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def manifest(self):
        return json.loads(v.read_bytes(self.mpath))

    def save(self, m):
        v.write_bytes(self.mpath, json.dumps(m, indent=2, sort_keys=True).encode())

    def frames(self, rid="rec_a"):
        return [json.loads(x) for x in v.read_bytes(os.path.join(self.folder, "frames", f"{rid}.jsonl")).splitlines() if x]

    def save_frames(self, frames, rid="rec_a"):
        data = "".join(json.dumps(f, sort_keys=True) + "\n" for f in frames).encode()
        v.write_bytes(os.path.join(self.folder, "frames", f"{rid}.jsonl"), data)
        m = self.manifest()
        for r in m["recordings"]:
            if r["recordingId"] == rid:
                r["framesSha256"] = hashlib.sha256(data).hexdigest()
                r["frameCount"] = len(frames)
        self.save(m)

    def refused(self, needle):
        r = v.validate(self.folder)
        self.assertFalse(r["ok"], "expected a refusal")
        self.assertTrue(any(needle in e for e in r["errors"]), r["errors"])

    def test_synthetic_is_valid(self):
        r = v.validate(self.folder)
        self.assertTrue(r["ok"], r["errors"])
        self.assertEqual((r["recordings"], r["frames"]), (2, 6))

    def test_empty_closure_is_refused(self):
        m = self.manifest()
        m["withheld"] = {"names": [], "sourceIds": [], "fingerprints": [], "closureSha256": ""}
        self.save(m)
        self.refused("withheld closure is missing or empty")

    def test_closure_hash_must_match(self):
        m = self.manifest()
        m["withheld"]["names"].append("held_2")
        self.save(m)
        self.refused("closureSha256")

    def test_withheld_recording_name_or_content_is_refused(self):
        m = self.manifest()
        m["recordings"][0]["decoded"]["fingerprint"] = "file:held_1"
        self.save(m)
        self.refused("is withheld")

    def test_non_development_split_is_refused(self):
        m = self.manifest()
        m["recordings"][0]["split"] = "lineage_holdout"
        self.save(m)
        self.refused("not a development split")

    def test_ineligible_recording_is_refused(self):
        m = self.manifest()
        m["recordings"][0]["eligibility"]["rally_classifier"] = "not_assessed"
        self.save(m)
        self.refused("not eligible")

    def test_tick_must_be_round_t_times_600(self):
        f = self.frames()
        f[1]["tick"] += 1
        self.save_frames(f)
        self.refused("round(t*600)")

    def test_frames_hash_must_match(self):
        path = os.path.join(self.folder, "frames", "rec_a.jsonl")
        v.write_bytes(path, v.read_bytes(path) + b"\n")
        self.refused("framesSha256")

    def test_track_id_never_reused_across_segments(self):
        f = self.frames()
        f[3]["persons"][0]["track"] = 1
        self.save_frames(f)
        self.refused("reused across segments")

    def test_segment_must_follow_resets(self):
        f = self.frames()
        f[1]["seg"] = 1
        self.save_frames(f)
        self.refused("inconsistent with reset")

    def test_interval_start_must_reset(self):
        f = self.frames()
        del f[4]["reset"]
        f[4]["seg"] = 2
        self.save_frames(f)
        self.refused("interval_start")

    def test_analysis_inside_a_cut_is_refused(self):
        f = self.frames()
        f[2]["masks"] = {"ran": True, "rectFailed": False, "poseFailed": False}
        self.save_frames(f)
        self.refused("analysed inside excluded time")

    def test_skipped_frame_must_lie_in_excluded_time(self):
        f = self.frames()
        f[1]["masks"] = {"ran": False, "skipped": "cut", "rectFailed": False, "poseFailed": False}
        f[1]["persons"] = []
        self.save_frames(f)
        self.refused("not inside a cut span")

    def test_court_must_stay_unknown_without_a_lane(self):
        f = self.frames("rec_b")
        f[0]["persons"][0]["court"] = "in"
        self.save_frames(f, "rec_b")
        self.refused("has no lane")

    def test_pose_needs_nineteen_slots(self):
        f = self.frames()
        f[0]["persons"][0]["pose"]["joints"] = f[0]["persons"][0]["pose"]["joints"][:18]
        self.save_frames(f)
        self.refused("19 slots")

    def test_box_may_extend_past_the_edge_but_must_overlap_the_frame(self):
        f = self.frames()
        f[0]["persons"][0]["box"] = {"x": 0.9, "y": -0.25, "w": 0.11, "h": 0.77}
        self.save_frames(f)
        self.assertTrue(v.validate(self.folder)["ok"])
        f[0]["persons"][0]["box"] = {"x": 1.02, "y": 0.2, "w": 0.1, "h": 0.2}
        self.save_frames(f)
        self.refused("does not overlap the frame")

    def test_stray_file_is_refused(self):
        v.write_bytes(os.path.join(self.folder, "frames", "extra.txt"), b"x")
        self.refused("stray file")

    def test_two_splits_in_one_group_are_refused(self):
        m = self.manifest()
        m["recordings"][1]["groupId"] = "rec_a"
        m["recordings"][1]["split"] = "dev_val"
        self.save(m)
        self.refused("has two splits")

    def test_tick_rounding_is_swift_half_away_from_zero(self):
        self.assertEqual(v.tick(2.5 / 600), 3)  # banker's rounding would give 2
        self.assertEqual(v.tick(12.4333), 7460)


if __name__ == "__main__":
    unittest.main()
