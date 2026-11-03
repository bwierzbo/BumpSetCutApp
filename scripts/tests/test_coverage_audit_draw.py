"""Tests for scripts/rally_classifier/coverage_audit_draw.py on synthetic inventories: interval computation, the
withheld-closure refusals, the stage 1 constraints, determinism, the repeat set, and that a draw is never overwritten.
Standard library only; nothing real is read.

    python3 -m unittest scripts.tests.test_coverage_audit_draw -v
"""

import contextlib
import copy
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rally_classifier"))
import coverage_audit_draw as d  # noqa: E402


def rec(rid, surface, split, group=None, duration=120.0, marks=None, **extra):
    r = {"recordingId": rid, "groupId": group or f"g-{rid}", "surface": surface, "split": split, "camera": "endline elevated",
         "durationSec": duration, "ralliesMarked": True, "fingerprint": f"fp:{rid}", "sourceId": None,
         "marksSha256": "0" * 64, "marks": marks if marks is not None else [{"start": 10, "end": 20, "kind": "rally"}, {"start": 40, "end": 55, "kind": "rally"}]}
    r.update(extra)
    return r


def inventory(recordings, withheld=None):
    return {"schemaVersion": d.INVENTORY_VERSION, "createdAt": "2026-11-03T00:00:00Z", "project": "Synthetic",
            "splitManifest": {k: "a" * 64 for k in ("projectJson", "sessions", "validationJson", "manifestJson")},
            "withheld": withheld or {"names": ["withheld_01"], "sourceIds": ["youtube:w1"], "fingerprints": ["fp:w1"]},
            "recordings": recordings}


def corpus():
    """Three surfaces × 6 recordings (train and tune, some sharing a group) — enough for 4 per surface."""
    recs = []
    for s in ("beach", "grass", indoor := "indoor"):
        recs += [rec(f"{s}_a", s, "train"), rec(f"{s}_a_v2", s, "train", group=f"g-{s}_a"), rec(f"{s}_b", s, "train"),
                 rec(f"{s}_c", s, "tune"), rec(f"{s}_d", s, "tune"), rec(f"{s}_e", s, "train")]
    recs.append(rec("beach_dev", "beach", "dev_val"))
    return recs


class Intervals(unittest.TestCase):
    def test_edges_and_gaps(self):
        ivs = d.unmarked_intervals([{"start": 10, "end": 20}, {"start": 40, "end": 55}], 100.0)
        self.assertEqual([(iv["start"], iv["end"]) for iv in ivs], [(0.0, 10.0), (20.0, 40.0), (55.0, 100.0)])
        self.assertEqual([iv["index"] for iv in ivs], [0, 1, 2])
        self.assertEqual(set(ivs[0]), {"index", "start", "end", "durationSec"})

    def test_overlapping_and_touching_marks_merge_and_every_kind_counts(self):
        marks = [{"start": 10, "end": 20, "kind": "rally"}, {"start": 18, "end": 25, "kind": "missedServe"},
                 {"start": 25, "end": 30, "kind": "other"}, {"start": 50, "end": 45, "kind": "rally"}]
        ivs = d.unmarked_intervals(marks, 60.0)
        self.assertEqual([(iv["start"], iv["end"]) for iv in ivs], [(0.0, 10.0), (30.0, 60.0)])

    def test_sub_second_and_edge_intervals_are_reviewed_like_any_other(self):
        # Codex on PR #138: a sub-second interval can hold a missed serve and an edge interval a clipped rally, so
        # "too short for a rally" certifies nothing — every interval is listed for review, none is exempt.
        ivs = d.unmarked_intervals([{"start": 0.4, "end": 20}, {"start": 20.5, "end": 30}, {"start": 31.0, "end": 39.7}], 40.0)
        self.assertEqual([(iv["start"], iv["end"], iv["durationSec"]) for iv in ivs],
                         [(0.0, 0.4, 0.4), (20.0, 20.5, 0.5), (30.0, 31.0, 1.0), (39.7, 40.0, 0.3)])
        rng = __import__("random").Random(0)
        self.assertEqual(len(d.draw_repeat(ivs, 0.2, 2, rng)), 2)

    def test_marks_are_clamped_to_the_recording(self):
        ivs = d.unmarked_intervals([{"start": -5, "end": 3}, {"start": 95, "end": 130}], 100.0)
        self.assertEqual([(iv["start"], iv["end"]) for iv in ivs], [(3.0, 95.0)])

    def test_no_marks_is_one_interval(self):
        ivs = d.unmarked_intervals([], 30.0)
        self.assertEqual([(iv["start"], iv["end"]) for iv in ivs], [(0.0, 30.0)])


class Draws(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cov-draw-")
        self.inv_path = os.path.join(self.tmp, "inventory.json")
        self.out = os.path.join(self.tmp, "draw.json")
        self.save(inventory(corpus()))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def save(self, inv):
        with open(self.inv_path, "w") as fh:
            json.dump(inv, fh)

    def load(self):
        with open(self.inv_path) as fh:
            return json.load(fh)

    def test_stage1_constraints_hold(self):
        draw = d.build_draw(self.inv_path, exclude=["beach_dev"], now="2026-11-03T00:00:00Z")
        recs = draw["recordings"]
        self.assertEqual(len(recs), 12)
        for s in ("beach", "grass", "indoor"):
            mine = [r for r in recs if r["surface"] == s]
            self.assertEqual(len(mine), 4, s)
            self.assertEqual(len({r["groupId"] for r in mine}), 4, f"{s}: one recording per group")
            self.assertTrue(any(r["split"] == "train" for r in mine) and any(r["split"] == "tune" for r in mine), s)
        self.assertNotIn("beach_dev", [r["recordingId"] for r in recs])
        self.assertEqual(draw["excluded"], ["beach_dev"])
        self.assertEqual(draw["stage"], "stage1")
        self.assertEqual(draw["inventory"]["sha256"], d.sha256_file(self.inv_path))
        self.assertEqual(draw["inventory"]["withheld"], {"names": 1, "sourceIds": 1, "fingerprints": 1})
        self.assertEqual(draw["totals"]["recordings"], 12)
        self.assertEqual(draw["totals"]["intervals"], 36)
        self.assertEqual(draw["totals"]["rallyMarks"], 24)

    def test_draw_is_deterministic_under_the_seed_and_changes_with_it(self):
        a = d.build_draw(self.inv_path, exclude=["beach_dev"], seed=7, now="2026-11-03T00:00:00Z")
        b = d.build_draw(self.inv_path, exclude=["beach_dev"], seed=7, now="2026-11-03T00:00:00Z")
        self.assertEqual(a, b)
        ids = lambda x: [r["recordingId"] for r in x["recordings"]]
        seeds = {tuple(ids(d.build_draw(self.inv_path, exclude=["beach_dev"], seed=s, now="2026-11-03T00:00:00Z"))) for s in range(6)}
        self.assertGreater(len(seeds), 1, "different seeds should draw different samples")

    def test_repeat_set_is_a_fifth_with_a_minimum_of_two(self):
        draw = d.build_draw(self.inv_path, exclude=["beach_dev"], now="2026-11-03T00:00:00Z")
        for r in draw["recordings"]:
            reviewed = [iv["index"] for iv in r["intervals"]]
            self.assertEqual(len(r["repeatIndices"]), min(len(reviewed), max(2, -(-len(reviewed) // 5))))
            self.assertTrue(set(r["repeatIndices"]) <= set(reviewed))
            self.assertEqual(r["repeatIndices"], sorted(r["repeatIndices"]))

    def test_all_lists_every_eligible_recording(self):
        draw = d.build_draw(self.inv_path, all_recordings=True, exclude=["beach_dev"], now="2026-11-03T00:00:00Z")
        self.assertEqual(draw["stage"], "all")
        self.assertEqual(len(draw["recordings"]), 18)
        self.assertIsNone(draw["perSurface"])

    def test_infeasible_surface_is_refused(self):
        inv = self.load()
        inv["recordings"] = [r for r in inv["recordings"] if not (r["surface"] == "indoor" and r["split"] == "tune")]
        self.save(inv)
        with self.assertRaises(d.DrawError) as cm:
            d.build_draw(self.inv_path, exclude=["beach_dev"])
        self.assertIn("indoor", str(cm.exception))
        inv["recordings"] = [r for r in inv["recordings"] if r["recordingId"] not in ("indoor_b", "indoor_e")]
        self.save(inv)
        with self.assertRaises(d.DrawError) as cm:
            d.build_draw(self.inv_path, exclude=["beach_dev"])
        self.assertIn("fewer than 4", str(cm.exception))

    def test_withheld_refusals(self):
        for mutate, fragment in [
            (lambda inv: inv["recordings"].append(rec("withheld_01", "beach", "train")), "WITHHELD recording 'withheld_01' present (name"),
            (lambda inv: inv["recordings"][0].update({"sourceId": "youtube:w1"}), "sourceId in the closure"),
            (lambda inv: inv["recordings"][0].update({"fingerprint": "fp:w1"}), "fingerprint in the closure"),
            (lambda inv: inv["withheld"].update({"names": []}), "withheld.names is empty"),
        ]:
            inv = inventory(corpus())
            mutate(inv)
            self.save(inv)
            with self.assertRaises(d.DrawError) as cm:
                d.build_draw(self.inv_path, exclude=["beach_dev"])
            self.assertIn(fragment, str(cm.exception))

    def test_undeclared_recording_is_refused(self):
        inv = self.load()
        inv["recordings"][3]["ralliesMarked"] = False
        self.save(inv)
        with self.assertRaises(d.DrawError) as cm:
            d.build_draw(self.inv_path, exclude=["beach_dev"])
        self.assertIn("not declared complete", str(cm.exception))

    def test_inventory_schema_and_marks_are_checked(self):
        inv = inventory(corpus())
        inv["schemaVersion"] = "coverage_audit_inventory_v0"
        self.save(inv)
        with self.assertRaises(d.DrawError) as cm:
            d.build_draw(self.inv_path)
        self.assertIn("schemaVersion must be", str(cm.exception))
        inv = inventory(corpus())
        inv["recordings"][0]["marks"][0]["kind"] = "warmup"
        self.save(inv)
        with self.assertRaises(d.DrawError) as cm:
            d.build_draw(self.inv_path)
        self.assertIn("kind 'warmup'", str(cm.exception))
        inv = inventory(corpus())
        inv["recordings"].append(copy.deepcopy(inv["recordings"][0]))
        self.save(inv)
        with self.assertRaises(d.DrawError) as cm:
            d.build_draw(self.inv_path)
        self.assertIn("duplicate recordingId", str(cm.exception))

    def test_unknown_exclude_is_refused(self):
        with self.assertRaises(d.DrawError) as cm:
            d.build_draw(self.inv_path, exclude=["nope"])
        self.assertIn("not in the inventory", str(cm.exception))

    def test_write_never_overwrites_and_cli_exit_codes(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(d.main([self.inv_path, "--out", self.out, "--exclude", "beach_dev"]), 0)
            self.assertEqual(d.main([self.inv_path, "--out", self.out, "--exclude", "beach_dev"]), 1)
            bad = os.path.join(self.tmp, "bad.json")
            with open(bad, "w") as fh:
                fh.write("{")
            self.assertEqual(d.main([bad, "--out", os.path.join(self.tmp, "x.json")]), 1)
        text = out.getvalue()
        self.assertIn("wrote", text)
        self.assertIn("a draw is never overwritten", text)
        self.assertIn("inventory unreadable", text)
        with open(self.out) as fh:
            draw = json.load(fh)
        self.assertEqual(draw["schemaVersion"], d.DRAW_VERSION)
        self.assertTrue(draw["drawId"].startswith("coverage-audit-"))


if __name__ == "__main__":
    unittest.main()
