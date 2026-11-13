"""Tests for scripts/rally_classifier/folds.py on synthetic datasets: the draw is a function of the seed, keeps
groups whole and surfaces in every fold, reports what the owner asked for, says so when five folds cannot be
had, and its file is written once and tied to one dataset. Standard library only.

    python3 -m unittest scripts.tests.test_rally_classifier_folds -v
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rally_classifier_synthetic as syn  # noqa: E402
import folds  # noqa: E402  (rally_classifier_synthetic put scripts/rally_classifier on the path)
import validate_dataset as v  # noqa: E402


def group(name, surface, rallies):
    return {"groupId": f"g-{name}", "firstRecording": name, "recordings": [name], "surface": surface, "surfaces": [surface], "rallies": rallies}


def groups(per_surface: dict, rallies=10):
    return [group(f"{s[:3]}_{i:02d}", s, rallies) for s, n in per_surface.items() for i in range(n)]


def quiet(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = folds.main(argv)
    return code, out.getvalue(), err.getvalue()


class Draw(unittest.TestCase):
    def test_same_seed_same_draw_and_groups_are_whole(self):
        gs = groups({"beach": 5, "grass": 6, "indoor": 7})
        a = folds.draw(copy.deepcopy(gs), 5, 20261103, "every-fold", 1000)
        b = folds.draw(list(reversed(copy.deepcopy(gs))), 5, 20261103, "every-fold", 1000)     # input order is not an input
        self.assertEqual(a, b)
        self.assertEqual(set(a["assignment"]), {g["groupId"] for g in gs})
        self.assertNotEqual(a["assignment"], folds.draw(copy.deepcopy(gs), 5, 1, "every-fold", 1000)["assignment"])

    def test_every_fold_holds_every_surface_and_three_or_four_groups(self):
        gs = groups({"beach": 5, "grass": 6, "indoor": 7})
        drawn = folds.draw(gs, 5, 20261103, "every-fold", 1000)["assignment"]
        for f in range(5):
            inside = [g for g in gs if drawn[g["groupId"]] == f]
            self.assertEqual({g["surface"] for g in inside}, {"beach", "grass", "indoor"})
            self.assertIn(len(inside), (3, 4))          # the deal carries on across surfaces: 18 groups → 4, 4, 4, 3, 3

    def test_reshuffles_until_the_rally_counts_balance(self):
        gs = groups({"beach": 5, "grass": 5, "indoor": 5})
        for i, g in enumerate(gs):
            g["rallies"] = 4 + (i * 7) % 23            # uneven groups: the first deal need not balance
        drawn = folds.draw(gs, 5, 20261103, "every-fold", 1000)
        per_fold = [sum(g["rallies"] for g in gs if drawn["assignment"][g["groupId"]] == f) for f in range(5)]
        mean = sum(per_fold) / 5
        self.assertTrue(all(abs(r - mean) <= 0.25 * mean for r in per_fold), per_fold)
        self.assertGreaterEqual(drawn["shuffle"], 1)

    def test_a_surface_with_fewer_groups_than_folds_is_reported_not_hidden(self):
        gs = groups({"beach": 5, "grass": 5, "indoor": 2})
        with self.assertRaises(folds.FoldsError) as ctx:
            folds.draw(copy.deepcopy(gs), 5, 20261103, "every-fold", 1000)
        self.assertIn("indoor has 2", str(ctx.exception))
        self.assertEqual(ctx.exception.report["groupsPerSurface"], {"beach": 5, "grass": 5, "indoor": 2})
        relaxed = folds.draw(copy.deepcopy(gs), 5, 20261103, "where-feasible", 1000)
        self.assertEqual(relaxed["surfacesNotInEveryFold"], ["indoor"])
        indoor_folds = [relaxed["assignment"][g["groupId"]] for g in gs if g["surface"] == "indoor"]
        self.assertEqual(len(set(indoor_folds)), 2)     # spread over as many folds as it has groups
        for f in range(5):
            self.assertLessEqual({"beach", "grass"}, {g["surface"] for g in gs if relaxed["assignment"][g["groupId"]] == f})

    def test_fewer_groups_than_folds_is_infeasible(self):
        with self.assertRaises(folds.FoldsError) as ctx:
            folds.draw(groups({"beach": 2, "grass": 1}), 5, 20261103, "where-feasible", 1000)
        self.assertIn("3 group(s) cannot fill 5 folds", str(ctx.exception))

    def test_fewer_than_three_folds_is_infeasible(self):
        # The trainer's nested protocol holds one fold out, chooses on a second and trains on the rest.
        with self.assertRaises(folds.FoldsError) as ctx:
            folds.draw(groups({"beach": 4, "grass": 4, "indoor": 4}), 2, 20261103, "every-fold", 1000)
        self.assertIn("at least 3 folds", str(ctx.exception))
        self.assertTrue(folds.draw(groups({"beach": 4, "grass": 4, "indoor": 4}), 3, 20261103, "every-fold", 1000))

    def test_an_unreachable_balance_is_reported_with_the_closest_attempt(self):
        gs = groups({"beach": 5, "grass": 5, "indoor": 5})
        gs[0]["rallies"] = 500                          # one group outweighs every fold's share
        with self.assertRaises(folds.FoldsError) as ctx:
            folds.draw(gs, 5, 20261103, "every-fold", 50)
        self.assertIn("no deal within 50 shuffles", str(ctx.exception))
        closest = ctx.exception.report["closestAttempt"]
        self.assertEqual(len(closest["ralliesPerFold"]), 5)
        self.assertGreater(closest["largestDeviationFromMean"], 0.25)

    def test_a_mixed_surface_group_takes_its_most_frequent_surface(self):
        manifest = {"recordings": [{"recordingId": "a", "groupId": "g", "surface": "grass", "rallies": []},
                                   {"recordingId": "a_v2", "groupId": "g", "surface": "beach", "rallies": []},
                                   {"recordingId": "a_v3", "groupId": "g", "surface": "grass", "rallies": [{}]}]}
        (g,) = folds.groups_of(manifest)
        self.assertEqual((g["surface"], g["surfaces"], g["firstRecording"], g["rallies"]), ("grass", ["beach", "grass"], "a", 1))

    def test_label_seconds_counts_time_within_segments_only(self):
        S = v.STATES
        steps = [{"t": 0.0, "seg": 0, "y": S["NON_RALLY"]}, {"t": 0.5, "seg": 0, "y": S["NON_RALLY"]},
                 {"t": 1.0, "seg": 0, "y": S["ACTIVE_RALLY"]}, {"t": 9.0, "seg": 1, "y": S["ACTIVE_RALLY"]},   # a break: no time
                 {"t": 9.5, "seg": 1, "y": S["ACTIVE_RALLY"]}, {"t": 10.0, "seg": 1, "y": S["UNKNOWN"]}]
        seconds = folds.label_seconds(steps)
        self.assertEqual((seconds["NON_RALLY"], seconds["ACTIVE_RALLY"], seconds["UNKNOWN"]), (0.5, 1.0, 0.5))


class FoldsFile(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="rc-folds-")
        cls.dataset = syn.write(cls.tmp)
        cls.closure = syn.write_closure(cls.tmp, cls.dataset)
        cls.path = os.path.join(cls.tmp, "folds.json")
        cls.before = v.dataset_identity(cls.dataset)
        cls.code, cls.out, cls.err = quiet([cls.dataset, "--out", cls.path, "--withheld", cls.closure])
        cls.doc = syn.read_json(cls.path)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_written_file_names_its_dataset_and_leaves_it_untouched(self):
        self.assertEqual(self.code, 0, self.err)
        self.assertEqual(self.doc["dataset"], self.before)
        self.assertEqual(v.dataset_identity(self.dataset), self.before)
        self.assertEqual(self.doc["dataset"]["name"], "Synthetic-rally-classifier")
        self.assertEqual((self.doc["schemaVersion"], self.doc["procedure"], self.doc["seed"], self.doc["folds"]),
                         ("rally_classifier_folds_v1", "fold_draw_v1", 20261103, 5))

    def test_build_is_deterministic(self):
        again = folds.build(self.dataset)
        self.assertEqual({k: val for k, val in again.items() if k != "createdAt"}, {k: val for k, val in self.doc.items() if k != "createdAt"})

    def test_every_recording_has_its_groups_fold(self):
        manifest = v.load_manifest(self.dataset)
        by_group = {g["groupId"]: g["fold"] for g in self.doc["groups"]}
        self.assertEqual(set(self.doc["recordings"]), {r["recordingId"] for r in manifest["recordings"]})
        for r in manifest["recordings"]:
            self.assertEqual(self.doc["recordings"][r["recordingId"]], by_group[r["groupId"]])
        self.assertTrue(all(r["fold"] is None for r in manifest["recordings"]))     # the manifest's own field plays no part

    def test_report_per_fold_and_restricted_apart(self):
        manifest = v.load_manifest(self.dataset)
        rep = self.doc["report"]
        self.assertEqual(len(rep["perFold"]), 5)
        self.assertEqual(sum(p["groups"] for p in rep["perFold"]), 15)
        self.assertEqual(sum(len(p["all"]["recordings"]) for p in rep["perFold"]), len(manifest["recordings"]))
        self.assertEqual(sum(p["all"]["rallies"] for p in rep["perFold"]), sum(len(r["rallies"]) for r in manifest["recordings"]))
        for p in rep["perFold"]:
            self.assertEqual(p["surfaces"], {"beach": 1, "grass": 1, "indoor": 1})
            self.assertEqual(p["all"]["rallies"], p["standard"]["rallies"] + p["restricted"]["rallies"])
            self.assertAlmostEqual(p["all"]["positiveSec"], p["standard"]["positiveSec"] + p["restricted"]["positiveSec"], places=2)
            self.assertGreater(p["all"]["positiveSec"], 0)
            self.assertGreater(p["all"]["validNegativeSec"], 0)
        restricted = [rid for p in rep["perFold"] for rid in p["restricted"]["recordings"]]
        self.assertEqual(restricted, ["syn_bea_01"])
        self.assertEqual(rep["totals"]["restrictedRecordings"], ["syn_bea_01"])
        holder = next(p for p in rep["perFold"] if p["restricted"]["recordings"])
        self.assertEqual(holder["restricted"]["validNegativeSec"], 0)              # an edited recording's other time is UNKNOWN

    def test_negative_coverage_is_counted_not_decided(self):
        cover = self.doc["report"]["negativeCoverage"]
        self.assertEqual((cover["groupsWithValidNegatives"], cover["groups"]), (14, 15))
        self.assertEqual(cover["groupsWithoutValidNegatives"], ["g-bea-01"])
        self.assertEqual(cover["fraction"], round(14 / 15, 4))
        self.assertTrue(cover["countAtLeast12"])
        self.assertTrue(cover["fractionAtLeast12Of18"])
        self.assertNotIn("pass", json.dumps(cover).lower())

    def test_an_existing_file_is_never_overwritten(self):
        before = syn.read_text(self.path)
        code, _, err = quiet([self.dataset, "--out", self.path, "--seed", "5"])
        self.assertEqual(code, 1)
        self.assertIn("never overwritten", err)
        self.assertEqual(syn.read_text(self.path), before)

    def test_load_accepts_its_own_dataset(self):
        self.assertEqual(folds.load(self.path, self.dataset)["recordings"], self.doc["recordings"])

    def test_load_refuses_another_dataset(self):
        other_dir = os.path.join(self.tmp, "other")
        os.makedirs(other_dir)
        other = syn.write(other_dir, seed=8)                 # same folder name, other content
        with self.assertRaises(folds.FoldsError) as ctx:
            folds.load(self.path, other)
        self.assertIn("drawn for another dataset", str(ctx.exception))
        self.assertIn("digest", str(ctx.exception))
        renamed = os.path.join(self.tmp, "Renamed-copy")     # same content under another name is another dataset
        shutil.copytree(self.dataset, renamed)
        with self.assertRaises(folds.FoldsError) as ctx:
            folds.load(self.path, renamed)
        self.assertIn("name differ", str(ctx.exception))

    def test_load_refuses_an_edited_assignment(self):
        doc = copy.deepcopy(self.doc)
        a, b = doc["groups"][0], next(g for g in doc["groups"] if g["fold"] != doc["groups"][0]["fold"])
        a["fold"], b["fold"] = b["fold"], a["fold"]
        for g in (a, b):
            for rid in g["recordings"]:
                doc["recordings"][rid] = g["fold"]
        edited = os.path.join(self.tmp, "edited.json")
        with open(edited, "w") as fh:
            json.dump(doc, fh)
        with self.assertRaises(folds.FoldsError) as ctx:
            folds.load(edited, self.dataset)
        self.assertIn("edited after it was written", str(ctx.exception))

    def test_load_refuses_another_schema(self):
        other = os.path.join(self.tmp, "schema.json")
        with open(other, "w") as fh:
            json.dump({**self.doc, "procedure": "fold_draw_v0"}, fh)
        with self.assertRaises(folds.FoldsError):
            folds.load(other, self.dataset)


class Infeasible(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rc-folds-thin-")
        self.dataset = syn.write(self.tmp, groups_per_surface=4)      # no surface can be in five folds

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_cli_reports_and_writes_nothing(self):
        path = os.path.join(self.tmp, "folds.json")
        code, out, err = quiet([self.dataset, "--out", path])
        self.assertEqual(code, 1)
        self.assertFalse(os.path.exists(path))
        self.assertIn("infeasible", err)
        self.assertIn("amended preregistration", err)
        report = json.loads(out)
        self.assertEqual(report["groupsPerSurface"], {"beach": 4, "grass": 4, "indoor": 4})
        self.assertTrue(report["infeasible"])
        code, _, _ = quiet([self.dataset, "--out", path, "--folds", "4"])           # four folds are feasible, when asked for
        self.assertEqual(code, 0)
        self.assertEqual(syn.read_json(path)["folds"], 4)

    def test_cli_refuses_a_dataset_that_does_not_validate(self):
        mpath = os.path.join(self.dataset, "dataset-manifest.json")
        manifest = v.load_manifest(self.dataset)
        manifest["recordings"][0]["split"] = "lineage_holdout"
        with open(mpath, "w") as fh:
            json.dump(manifest, fh)
        path = os.path.join(self.tmp, "folds.json")
        code, _, err = quiet([self.dataset, "--out", path, "--folds", "4"])
        self.assertEqual(code, 1)
        self.assertIn("does not validate", err)
        self.assertFalse(os.path.exists(path))


if __name__ == "__main__":
    unittest.main()
