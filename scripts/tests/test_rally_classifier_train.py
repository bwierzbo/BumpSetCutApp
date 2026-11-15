"""Tests for scripts/rally_classifier/train.py, evaluate.py and tcn.py on a synthetic dataset: the refusals
that precede a fit, the dry run that fits nothing, the loss and its weights, the nested protocol's isolation
from the outer fold, the stored baseline scored exactly as the reference scorecard scores it, the bootstrap,
the hypotheses' wording, and a small end-to-end run of each candidate. No real recording is involved.

    python3 -m unittest scripts.tests.test_rally_classifier_train -v
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
from unittest import mock

try:
    import numpy as np
except ImportError:   # the checker's CI runner has no numpy; these run where the trainer does
    raise unittest.SkipTest("numpy is not installed: the rally-classifier trainer's tests run where it is")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rally_classifier_synthetic as syn  # noqa: E402
import decode  # noqa: E402
import evaluate  # noqa: E402
import features as ft  # noqa: E402
import folds  # noqa: E402
import train  # noqa: E402
import validate_dataset as v  # noqa: E402

try:
    import torch
    import tcn
except ImportError:
    torch = None

rs = evaluate.rs
T = v.TIMESCALE


def quiet(fn, argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = fn(argv)
        except SystemExit as e:
            code = e.code
    return code, out.getvalue(), err.getvalue()


def boom(*args, **kwargs):
    raise AssertionError("a dry run must not fit or score anything")


def make(folder, **kw):
    """A dataset, its closure file and its folds file under `folder`."""
    dataset = syn.write(folder, **kw)
    closure = syn.write_closure(folder, dataset)
    path = os.path.join(folder, "folds.json")
    code, _, err = quiet(folds.main, [dataset, "--out", path, "--withheld", closure])
    assert code == 0, err
    return dataset, closure, path


def argv(dataset, closure, folds_file, out, candidate="r1", net="present", *extra):
    return [dataset, "--folds-file", folds_file, "--withheld", closure, "--candidate", candidate, "--net", net, "--out", out, *extra]


def poisoned(prep, k):
    """The prepared data with fold k's recordings replaced by nonsense: labels flipped and all weighted,
    measurements random, truth and stored baseline swapped for others."""
    prep = copy.deepcopy(prep)
    rng = np.random.default_rng(k)
    for r in prep.of(lambda f: f == k):
        r.arr["y"] = np.where(r.arr["y"] == v.STATES["ACTIVE_RALLY"], v.STATES["NON_RALLY"], v.STATES["ACTIVE_RALLY"])
        r.arr["w"] = np.ones(len(r.arr["w"]))
        r.arr["F"] = rng.uniform(0, 1, r.arr["F"].shape)
        r.rec["rallies"] = [{"startTick": 600, "endTick": 1200}]
        r.rec["excludedSpans"] = []
        r.baseline = {name: [{"rawSpans": [{"startTick": 600, "endTick": 3000}], "startTick": 0, "endTick": 3300, "serveContactTick": None}]
                      for name in r.baseline}
        r.cache.clear()
    return prep


class Shared(unittest.TestCase):
    """One dataset and one R1 run for the tests that only read them."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="rc-train-")
        cls.dataset, cls.closure, cls.folds_file = make(cls.tmp)
        cls.manifest = v.load_manifest(cls.dataset)
        cls.prep = train.prepare(cls.dataset, cls.folds_file, cls.closure, "present")
        cls.r1 = os.path.join(cls.tmp, "run-r1")
        cls.code, cls.out, cls.err = quiet(train.main, argv(cls.dataset, cls.closure, cls.folds_file, cls.r1))
        cls.report = syn.read_json(os.path.join(cls.r1, "report.json")) if cls.code == 0 else None

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def card(self, variant, rid):
        return syn.read_json(os.path.join(self.r1, "scorecards", variant, f"{rid}.evaluation_v2.json"))

    # ---- the end-to-end R1 run -------------------------------------------------------------------
    def test_r1_run_writes_every_artefact(self):
        self.assertEqual(self.code, 0, self.err)
        self.assertIn("H1 (r1 vs r0)", self.out)
        for k in range(5):
            self.assertEqual(sorted(os.listdir(os.path.join(self.r1, f"fold{k}"))), ["calibration.json", "decode.json", "weights.json"])
            weights = syn.read_json(os.path.join(self.r1, f"fold{k}", "weights.json"))
            self.assertEqual(weights["features"], ft.R1_NAMES)
            self.assertEqual((len(weights["coefficients"]), len(weights["mean"]), weights["derived"]), (42, 42, "derived_v1"))
            self.assertIn(weights["penalty"], train.PENALTIES)
            self.assertLess(weights["gradientMax"], 1e-8)
            self.assertEqual(syn.read_json(os.path.join(self.r1, f"fold{k}", "calibration.json"))["fittedOnFold"], (k + 1) % 5)
            chosen = syn.read_json(os.path.join(self.r1, f"fold{k}", "decode.json"))
            self.assertIn(chosen["point"], decode.GRID)
            self.assertEqual((chosen["chosenOnFold"], chosen["rawFloorSec"], chosen["settings"]), ((k + 1) % 5, 1.1653, train.COMMITTED))
        rows = [json.loads(line) for line in syn.read_text(os.path.join(self.r1, "oof.jsonl")).splitlines()]
        self.assertEqual(len(rows), sum(r["stepCount"] for r in self.manifest["recordings"]))
        fold_of = syn.read_json(self.folds_file)["recordings"]
        self.assertTrue(all(row["fold"] == fold_of[row["recordingId"]] and 0.0 <= row["p"] <= 1.0 for row in rows))
        for variant in ("r0", "r0_prime", "r1"):
            self.assertEqual(sorted(os.listdir(os.path.join(self.r1, "scorecards", variant))),
                             sorted(f"{r['recordingId']}.evaluation_v2.json" for r in self.manifest["recordings"]))
        self.assertTrue(os.path.getsize(os.path.join(self.r1, "report.md")) > 1000)

    def test_report_identity_ties_the_run_to_its_inputs(self):
        ident = self.report["identity"]
        self.assertEqual(ident["dataset"], v.dataset_identity(self.dataset))
        self.assertEqual(ident["foldsFileSha256"], v.sha256_file(self.folds_file))
        self.assertEqual((ident["candidate"], ident["net"], ident["lookaheadSec"]), ("r1", "present", 2.0))
        self.assertEqual(ident["foldDraw"]["seed"], 20261103)
        self.assertEqual(ident["schemas"], {"features": "rcf_v1", "labels": "rally_activity_truth_v1", "derived": "derived_v1", "grid": "grid_v1"})
        self.assertEqual(set(ident["codeSha256"]), {"train.py", "features.py", "decode.py", "evaluate.py", "folds.py", "tcn.py",
                                                    "validate_dataset.py", "reference_scorecard.py"})
        self.assertEqual(self.report["validation"]["withheldFileSha256"], v.sha256_file(self.closure))
        self.assertEqual([f["nestedFold"] for f in self.report["folds"]], [1, 2, 3, 4, 0])

    def test_r0_scores_are_the_reference_scorecards_on_the_stored_baseline(self):
        complete = rallies = 0
        for rec in self.manifest["recordings"]:
            for variant, clips in v.read_baseline(self.dataset, rec).items():
                fixture = {
                    "duration": round(rec["durationSec"] * T) / T,
                    "truth": [{"start": r["startTick"] / T, "end": r["endTick"] / T, "kind": "rally"} for r in rec["rallies"]]
                    + [{"start": s["startTick"] / T, "end": s["endTick"] / T, "kind": s["kind"]} for s in rec["excludedSpans"]],
                    "cuts": [[s["startTick"] / T, s["endTick"] / T] for s in rec["cutRanges"] + rec["timeBreakingSpans"]],
                    "raw": [[c["rawSpans"][0]["startTick"] / T, max(q["endTick"] for q in c["rawSpans"]) / T] for c in clips],
                    "padded": [[c["startTick"] / T, c["endTick"] / T] for c in clips],
                    "fullyMarked": rec["coverage"]["state"] in ("declared_complete", "stage1_complete") and rec["eligibility"]["fullVideoNegatives"] == "standard",
                }
                direct = rs.score(fixture)
                stored = self.card(variant, rec["recordingId"])
                self.assertEqual(stored["scorecard"], json.loads(json.dumps(direct)), (variant, rec["recordingId"]))
                self.assertEqual(stored["variant"], variant)
                if variant == "r0" and not rec["restrictedUse"]:
                    complete, rallies = complete + direct["paddedExport"]["complete"], rallies + direct["paddedExport"]["rallies"]
        pooled = self.report["tables"]["pooled"]
        self.assertAlmostEqual(pooled["variants"]["r0"]["completeRallyRecall"], complete / rallies)
        self.assertEqual(pooled["sample"]["rallies"], rallies)

    def test_ticks_survive_the_scorecards_seconds(self):
        self.assertTrue(all(rs.tick(k / T) == k for k in range(0, 400000, 7)))

    def test_a_not_fully_marked_recording_has_no_dead_time_numbers(self):
        restricted = self.card("r0", "syn_bea_01")
        self.assertFalse(restricted["fullyMarked"])
        self.assertIsNone(restricted["scorecard"]["paddedExport"]["deadTimeRetention"])
        self.assertIsNone(restricted["scorecard"]["paddedExport"]["falseClips"])
        self.assertTrue(self.card("r0", "syn_bea_00")["fullyMarked"])

    def test_restricted_recordings_are_reported_apart(self):
        tables = self.report["tables"]
        standard = [r for r in self.manifest["recordings"] if not r["restrictedUse"]]
        self.assertEqual(tables["pooled"]["sample"], {"recordings": len(standard), "groups": len({r["groupId"] for r in standard}),
                                                      "rallies": sum(len(r["rallies"]) for r in standard)})
        self.assertEqual(tables["restricted"]["sample"]["recordings"], 1)
        self.assertEqual(list(tables["restrictedByRecording"]), ["syn_bea_01"])
        self.assertNotIn("g-bea-01", tables["byGroup"])
        self.assertEqual(sorted(tables["bySurface"]), ["beach", "grass", "indoor"])
        self.assertEqual(sorted(tables["byFold"]), ["0", "1", "2", "3", "4"])
        self.assertEqual(sum(t["sample"]["recordings"] for t in tables["byFold"].values()), len(standard))
        self.assertTrue(tables["bySurface"]["beach"]["indicativeOnly"])          # under 30 rallies
        self.assertFalse(tables["pooled"]["indicativeOnly"])
        self.assertIsNone(tables["byGroup"]["g-gra-00"]["differences"]["r1 - r0"]["completeRallyRecall"]["interval90"])   # one group: no interval
        self.assertEqual(set(tables["pooled"]["differences"]), {"r0_prime - r0", "r1 - r0"})

    def test_every_rally_is_in_one_class_and_missed_serves_are_counted(self):
        for rec in self.manifest["recordings"]:
            c = self.card("r1", rec["recordingId"])
            self.assertEqual(sum(c["rallyClasses"].values()), c["scorecard"]["paddedExport"]["rallies"])
            self.assertLessEqual(c["missedServeSpansEntered"], c["missedServeSpans"])
        self.assertEqual(self.card("r1", "syn_bea_02")["missedServeSpans"], 1)

    def test_the_learned_paths_diagnostics_are_reported(self):
        d = self.report["diagnostics"]
        self.assertEqual(set(d["uncertainTime"]), {r["recordingId"] for r in self.manifest["recordings"]})
        self.assertEqual(sorted(d["reliability"]), ["beach", "grass", "indoor"])
        self.assertEqual(len(d["reliability"]["beach"]), 10)
        self.assertEqual(d["onDevice"], "not measured")
        self.assertGreater(d["decodedIntervals"], 0)
        self.assertEqual(self.report["hypotheses"][0]["hypothesis"], "H1")
        self.assertIn(self.report["hypotheses"][0]["holds"], (True, False))

    def test_a_run_folder_is_never_written_over(self):
        code, _, err = quiet(train.main, argv(self.dataset, self.closure, self.folds_file, self.r1))
        self.assertEqual(code, 1)
        self.assertIn("never written over", err)

    # ---- the nested protocol ---------------------------------------------------------------------
    def test_nothing_chosen_for_a_fold_reads_that_fold(self):
        family = train.R1(self.prep, 0)
        clean = train.choose(self.prep, family, 0, train.baseline_cards(self.prep)["r0"])
        bad = poisoned(self.prep, 0)
        self.assertEqual(train.choose(bad, train.R1(bad, 0), 0, train.baseline_cards(bad)["r0"]), clean)
        self.assertEqual(clean["nestedFold"], 1)
        # … and the poison is not inert: with the nested fold poisoned instead, the choices move
        bad = poisoned(self.prep, 1)
        self.assertNotEqual(train.choose(bad, train.R1(bad, 0), 0, train.baseline_cards(bad)["r0"]), clean)

    def test_the_run_reports_what_choose_chose(self):
        family = train.R1(self.prep, 0)
        chosen = train.choose(self.prep, family, 2, train.baseline_cards(self.prep)["r0"])
        row = self.report["folds"][2]
        self.assertEqual((row["modelChoice"], row["decode"]["point"], row["decode"]["selection"]), (chosen["modelChoice"], chosen["point"], chosen["selection"]))
        self.assertAlmostEqual(row["calibration"]["temperature"], chosen["temperature"])

    # ---- the bootstrap and the hypotheses --------------------------------------------------------
    def cards(self, variant):
        return [self.card(variant, r["recordingId"]) for r in self.manifest["recordings"] if not r["restrictedUse"]]

    def test_the_bootstrap_is_deterministic_paired_and_by_group(self):
        a, b = self.cards("r1"), self.cards("r0")
        first, second = evaluate.paired_bootstrap(a, b), evaluate.paired_bootstrap(a, b)
        self.assertEqual(first, second)
        self.assertEqual(first, self.report["tables"]["pooled"]["differences"]["r1 - r0"])
        recall = first["completeRallyRecall"]
        self.assertEqual((recall["draws"], recall["units"]), (1000, len({c["groupId"] for c in a})))
        self.assertLess(recall["units"], len(a))                                   # two recordings of one group are one unit
        self.assertAlmostEqual(recall["delta"], recall["a"] - recall["b"])
        self.assertLessEqual(recall["interval90"][0], recall["interval90"][1])
        mirrored = evaluate.paired_bootstrap(b, a)["completeRallyRecall"]
        self.assertAlmostEqual(mirrored["delta"], -recall["delta"])
        np.testing.assert_allclose(mirrored["interval90"], [-recall["interval90"][1], -recall["interval90"][0]])
        same = evaluate.paired_bootstrap(a, a)
        self.assertEqual((same["completeRallyRecall"]["delta"], same["completeRallyRecall"]["interval90"]), (0.0, [0.0, 0.0]))
        self.assertIn("not told apart", same["completeRallyRecall"]["reading"])
        with self.assertRaises(ValueError):
            evaluate.paired_bootstrap(a, b[1:])

    def test_h2_needs_a_higher_recall_with_its_interval_above_zero(self):
        a, b = self.cards("r1"), self.cards("r0")
        self.assertFalse(evaluate.h2(a, a)["holds"])                               # equal recall is not higher
        result = evaluate.h2(a, b)
        recall = result["clauses"]["completeRallyRecall"]
        self.assertEqual(recall["meets"], recall["delta"] > 0 and recall["interval90"][0] > 0)
        self.assertEqual(result["holds"], all(c["meets"] for c in result["clauses"].values()))


def difference(delta, interval):
    reading = ("interval excludes zero: higher" if interval[0] > 0 else "interval excludes zero: lower" if interval[1] < 0
               else "interval includes zero: not told apart at this sample size (not evidence of equivalence)")
    return {"a": 0.5 + delta, "b": 0.5, "delta": delta, "interval90": interval, "draws": 1000, "units": 14, "reading": reading}


class Hypotheses(unittest.TestCase):
    def h1(self, recall, dead, false_clips):
        return evaluate.h1({"differences": {"r1 - r0": {"completeRallyRecall": recall, "deadTimeRetention": dead, "falseClips": false_clips}}}, "r1")

    def test_h1_as_worded(self):
        fine = self.h1(difference(0.05, [0.01, 0.1]), difference(-0.02, [-0.05, 0.01]), difference(-1, [-3, 0]))
        self.assertTrue(fine["holds"])
        self.assertEqual(fine["notToldApart"], ["deadTimeRetention", "falseClips"])
        self.assertTrue(self.h1(difference(0.0, [-0.02, 0.02]), difference(0.0, [-0.01, 0.01]), difference(0, [-1, 1]))["holds"])   # equal meets ≥ and ≤
        self.assertFalse(self.h1(difference(-0.01, [-0.05, 0.02]), difference(-0.02, [-0.05, 0.01]), difference(-1, [-3, 0]))["holds"])   # fewer rallies
        self.assertFalse(self.h1(difference(0.05, [0.01, 0.1]), difference(0.02, [-0.01, 0.05]), difference(-1, [-3, 0]))["holds"])      # more dead time
        self.assertFalse(self.h1(difference(0.05, [0.01, 0.1]), difference(-0.02, [-0.05, 0.01]), difference(2, [0, 4]))["holds"])       # more false clips
        # a point estimate that meets its bar under an interval wholly on the wrong side does not
        self.assertFalse(self.h1(difference(0.0, [-0.1, -0.01]), difference(-0.02, [-0.05, 0.01]), difference(-1, [-3, 0]))["holds"])
        undefined = {"a": None, "b": None, "delta": None, "interval90": None, "draws": 0, "units": 14, "reading": "no interval"}
        self.assertIsNone(self.h1(difference(0.05, [0.01, 0.1]), undefined, difference(-1, [-3, 0]))["holds"])    # no fully marked recording

    def test_the_decode_points_selection_rule(self):
        row = lambda i, complete, retention, false_clips=0: {"gridIndex": i, "complete": complete, "deadTimeRetention": retention, "falseClips": false_clips}
        rows = [row(0, 10, 0.30), row(1, 9, 0.10), row(2, 11, 0.20, 3), row(3, 10, 0.20, 1), row(4, 10, 0.20, 1)]
        self.assertEqual(train.pick_point(rows, 10), (rows[3], True))      # least dead time at R0's recall; fewer false clips; earlier point
        self.assertEqual(train.pick_point(rows, 11), (rows[2], True))
        self.assertEqual(train.pick_point(rows, 12), (rows[2], False))     # no point reaches R0: the most complete rallies, flagged
        unknown = [row(0, 10, None, 0), row(1, 12, None, 0)]
        self.assertEqual(train.pick_point(unknown, 10), (unknown[0], True))  # dead time undefined: grid order decides among the feasible


class Fitting(unittest.TestCase):
    def setUp(self):
        rng = np.random.default_rng(0)
        self.X = rng.normal(size=(600, 6)) * [1, 2, 3, 1, 1, 0.5] + [0, 5, -2, 0, 1, 0]
        self.t = (self.X[:, 0] + 0.5 * rng.normal(size=600) > 0.2).astype(float)
        self.w = (rng.random(600) < 0.6).astype(float)
        self.rng = rng

    def test_class_balance_and_no_weight_without_w(self):
        c = train.balanced_weights(self.t, self.w)
        self.assertAlmostEqual(c[self.t == 1].sum(), 0.5)
        self.assertAlmostEqual(c[self.t == 0].sum(), 0.5)
        self.assertTrue((c[self.w == 0] == 0).all())
        with self.assertRaises(train.Refused):
            train.balanced_weights(np.ones(600), self.w)
        with self.assertRaises(train.Refused):
            train.balanced_weights(self.t, np.where(self.t == 0, 0.0, self.w))        # negatives exist, none carries weight

    def test_steps_without_weight_change_no_gradient_and_no_fit(self):
        theta = self.rng.normal(size=7)
        loss, grad = train.objective(theta, self.X, self.t, train.balanced_weights(self.t, self.w), 1e-3)
        X2, t2 = self.X.copy(), self.t.copy()
        dead = self.w == 0
        X2[dead] = self.rng.normal(size=(int(dead.sum()), 6)) * 50
        t2[dead] = 1 - t2[dead]
        loss2, grad2 = train.objective(theta, X2, t2, train.balanced_weights(t2, self.w), 1e-3)
        self.assertAlmostEqual(loss, loss2, places=12)
        np.testing.assert_allclose(grad, grad2, rtol=1e-12, atol=1e-15)
        only = train.objective(theta, self.X[~dead], self.t[~dead], train.balanced_weights(self.t[~dead], self.w[~dead]), 1e-3)
        np.testing.assert_allclose(grad, only[1], rtol=1e-12, atol=1e-15)
        a, b = train.fit_logistic(self.X, self.t, self.w, 1e-3), train.fit_logistic(X2, t2, self.w, 1e-3)
        np.testing.assert_allclose(a["coefficients"], b["coefficients"], rtol=1e-9, atol=1e-12)
        np.testing.assert_array_equal(a["mean"], b["mean"])
        np.testing.assert_array_equal(a["std"], b["std"])

    def test_standardisation_is_from_the_weighted_steps(self):
        mean, std = train.standardise(self.X, self.w)
        np.testing.assert_allclose(mean, self.X[self.w > 0].mean(axis=0))
        np.testing.assert_allclose(std, self.X[self.w > 0].std(axis=0))
        constant = np.column_stack((self.X, np.full(600, 3.0)))
        self.assertEqual(train.standardise(constant, self.w)[1][-1], 1.0)            # a constant column (the ablated net) divides by 1

    def test_the_gradient_is_the_objectives_and_the_fit_is_its_minimum(self):
        c = train.balanced_weights(self.t, self.w)
        theta = self.rng.normal(size=7) * 0.3
        _, grad = train.objective(theta, self.X, self.t, c, 1e-2)
        for i in range(7):
            step = np.zeros(7)
            step[i] = 1e-6
            numeric = (train.objective(theta + step, self.X, self.t, c, 1e-2)[0] - train.objective(theta - step, self.X, self.t, c, 1e-2)[0]) / 2e-6
            self.assertAlmostEqual(grad[i], numeric, places=6)
        model = train.fit_logistic(self.X, self.t, self.w, 1e-2)
        self.assertLess(model["gradientMax"], 1e-9)
        keep = self.w > 0
        Z = (self.X[keep] - model["mean"]) / model["std"]
        best = np.concatenate((model["coefficients"], [model["intercept"]]))
        at_best = train.objective(best, Z, self.t[keep], c[keep], 1e-2)[0]
        for _ in range(20):
            self.assertGreater(train.objective(best + self.rng.normal(size=7) * 0.05, Z, self.t[keep], c[keep], 1e-2)[0], at_best)
        self.assertGreater(np.abs(train.fit_logistic(self.X, self.t, self.w, 1e-4)["coefficients"]).sum(), np.abs(model["coefficients"]).sum())

    def test_temperature_recovers_a_scale_and_ignores_unweighted_steps(self):
        rng = np.random.default_rng(3)
        true = rng.normal(size=40000) * 2
        target = (rng.random(40000) < train.sigmoid(true)).astype(float)
        w = np.ones(40000)
        self.assertAlmostEqual(train.fit_temperature(3.0 * true, target, w), 3.0, delta=0.15)
        self.assertAlmostEqual(train.fit_temperature(0.5 * true, target, w), 0.5, delta=0.03)
        w[:10000] = 0
        logits = 3.0 * true
        fitted = train.fit_temperature(logits, target, w)
        logits[:10000], target[:10000] = 99.0, 0.0
        self.assertEqual(train.fit_temperature(logits, target, w), fitted)
        with self.assertRaises(train.Refused):
            train.fit_temperature(logits, target, np.zeros(40000))
        np.testing.assert_allclose(train.probabilities(np.array([0.0, 2.0, -800.0]), 2.0), [0.5, 1 / (1 + np.exp(-1)), 0.0])


class Diagnostics(unittest.TestCase):
    def recording(self, n=200, **rec):
        steps = [{"t": i / 10, "tick": i * 60, "seg": 0, "f": [None if nullable else 0 for _, nullable, _, _ in v.FEATURES], "y": 0, "w": 1.0} for i in range(n)]
        steps[50]["f"][v.FEATURE_INDEX["serve_emitted"]], steps[50]["f"][v.FEATURE_INDEX["serve_contact_offset"]] = 1, 1.0   # contact at 4.0 s
        arr = ft.arrays(steps)
        return train.Recording({"recordingId": "x", "durationSec": n / 10, "cutRanges": [], "timeBreakingSpans": [], **rec}, 0, arr, {}, ft.segments(arr["seg"]))

    def test_uncertain_time_counts_only_long_runs(self):
        r = self.recording()
        p = np.full(200, 0.95)
        p[10:36] = 0.5          # 26 steps spanning 2.5 s: counted
        p[100:115] = 0.5        # 1.4 s: not
        p[150:171] = 0.7        # the band is closed; 2.0 s exactly: counted
        got = train.uncertain_time(r, p)
        self.assertAlmostEqual(got["uncertainSec"], 4.5)
        self.assertAlmostEqual(got["uncertainStepFraction"], (26 + 21) / 200)

    def test_unprimed_intervals_have_no_serve_contact_within_three_seconds(self):
        r = self.recording()
        self.assertEqual(train.unprimed(r, [(2400, 6000)]), 0)              # starts at the contact
        self.assertEqual(train.unprimed(r, [(4200, 6000)]), 0)              # 3 s after it
        self.assertEqual(train.unprimed(r, [(4201, 6000), (600, 590 + 1)]), 1)
        self.assertEqual(train.unprimed(r, [(9000, 9900), (10200, 11000)]), 2)


class Guards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rc-guards-")
        self.dataset, self.closure, self.folds_file = make(self.tmp)
        self.out = os.path.join(self.tmp, "run")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def refused(self, fragment, args=None):
        code, _, err = quiet(train.main, args or argv(self.dataset, self.closure, self.folds_file, self.out))
        self.assertEqual(code, 1, err)
        self.assertIn(fragment, err)
        self.assertFalse(os.path.exists(self.out))

    def test_no_closure_file_no_run(self):
        args = argv(self.dataset, self.closure, self.folds_file, self.out)
        del args[3:5]
        code, _, err = quiet(train.main, args)
        self.assertEqual(code, 2)
        self.assertIn("--withheld", err)
        self.assertFalse(os.path.exists(self.out))
        with self.assertRaises(train.Refused):
            train.prepare(self.dataset, self.folds_file, None, "present")
        self.refused("withheld file unreadable", argv(self.dataset, os.path.join(self.tmp, "absent.json"), self.folds_file, self.out))

    def test_a_dataset_the_closure_refuses_is_not_read(self):
        with open(self.closure, "w") as fh:
            json.dump({"names": [], "sourceIds": ["youtube:syn_gra_02"], "fingerprints": []}, fh)
        self.refused("WITHHELD recording present")

    def test_a_folds_file_for_another_dataset_is_refused(self):
        other_dir = os.path.join(self.tmp, "other")
        os.makedirs(other_dir)
        _, _, other_folds = make(other_dir, seed=8)
        self.refused("drawn for another dataset", argv(self.dataset, self.closure, other_folds, self.out))

    def test_a_two_fold_file_is_refused_before_the_run_folder_exists(self):
        # Two folds leave nothing to train on once one is held out and one is chosen on. folds.py no longer draws
        # them; a file from elsewhere is refused by the trainer itself, before anything is fitted or written.
        with mock.patch.object(folds, "MIN_FOLDS", 2):
            two = os.path.join(self.tmp, "two-folds.json")
            code, _, err = quiet(folds.main, [self.dataset, "--out", two, "--folds", "2", "--withheld", self.closure, "--stratify", "where-feasible"])
            self.assertEqual(code, 0, err)
        self.refused("at least 3", argv(self.dataset, self.closure, two, self.out))
        real = folds.load
        with mock.patch.object(folds, "load", lambda path, dataset: {**real(self.folds_file, dataset), "folds": 2}):
            self.refused("the nested protocol needs at least 3")

    def test_a_port_that_fails_parity_stops_the_run(self):
        with mock.patch.object(v, "pad_and_merge", lambda raw_spans, settings, duration: []):
            self.refused("does not reproduce")

    def test_a_baseline_at_other_settings_is_refused(self):
        mpath = os.path.join(self.dataset, "dataset-manifest.json")
        manifest = v.load_manifest(self.dataset)
        manifest["baseline"]["variants"][0]["settings"]["joinSec"] = 0.5        # a retune under the name r0
        with open(mpath, "w") as fh:
            json.dump(manifest, fh)
        self.refused("not at the settings the preregistration names")

    def test_a_dry_run_fits_nothing_and_scores_nothing(self):
        patches = [mock.patch.object(train, name, boom) for name in ("fit_logistic", "standardise", "balanced_weights", "fit_temperature",
                                                                      "select_decode", "choose", "baseline_cards", "run")]
        patches += [mock.patch.object(evaluate, name, boom) for name in ("card", "score")] + [mock.patch.object(rs, "score", boom)]
        with contextlib.ExitStack() as stack:
            for p in patches:
                stack.enter_context(p)
            code, out, err = quiet(train.main, argv(self.dataset, self.closure, self.folds_file, self.out, "r1", "ablated", "--dry-run"))
        self.assertEqual(code, 0, err)
        self.assertIn("nothing fitted, nothing scored", out)
        self.assertEqual(sorted(os.listdir(self.out)), ["readiness.json", "readiness.md"])
        doc = syn.read_json(os.path.join(self.out, "readiness.json"))
        self.assertIn("nothing was fitted and nothing was scored", doc["kind"])
        self.assertEqual(doc["inputs"], {"features": 42, "steps": sum(r["stepCount"] for r in v.load_manifest(self.dataset)["recordings"])})
        self.assertEqual(doc["parity"]["clipsRebuilt"].keys(), {"r0", "r0_prime"})
        self.assertEqual([(row["fold"], row["nestedFold"]) for row in doc["plan"]], [(k, (k + 1) % 5) for k in range(5)])
        for row in doc["plan"]:
            self.assertEqual(row["training"]["recordings"], row["inner"]["recordings"] + row["nested"]["recordings"])
            self.assertEqual(row["test"]["recordings"] + row["training"]["recordings"], 18)
            self.assertGreater(row["inner"]["positiveSteps"], 0)
            self.assertGreater(row["inner"]["negativeSteps"], 0)
        self.assertEqual(doc["problems"], [])
        self.assertEqual(doc["identity"]["net"], "ablated")
        self.assertNotIn("tables", doc)

    def test_a_dry_run_names_the_folds_that_could_not_be_fitted(self):
        prep = train.prepare(self.dataset, self.folds_file, self.closure, "present")
        for r in prep.recordings:
            if r.fold in (0, 1):                             # fold 2's inner folds are 0, 1 and 4 …
                r.arr["w"] = np.where(r.arr["y"] == v.STATES["ACTIVE_RALLY"], r.arr["w"], 0.0)
            if r.fold == 3:
                r.rec["eligibility"]["fullVideoNegatives"] = "not_assessed"
        doc = train.readiness(prep, train.R1(prep, 0), [])
        self.assertFalse(any("fold 2: the inner folds" in p for p in doc["problems"]))      # … and 4 still has negatives
        for r in prep.of(lambda f: f == 4):
            r.arr["w"] = np.where(r.arr["y"] == v.STATES["ACTIVE_RALLY"], r.arr["w"], 0.0)
        doc = train.readiness(prep, train.R1(prep, 0), [])
        self.assertTrue(any("fold 2: the inner folds hold" in p and "0 negative" in p for p in doc["problems"]), doc["problems"])
        self.assertTrue(any("fold 2: nested fold 3 has no fully marked recording" in p for p in doc["problems"]), doc["problems"])
        with self.assertRaises(train.Refused) as ctx:       # and the real fit refuses the same thing
            train.choose(prep, train.R1(prep, 0), 2, {})
        self.assertIn("need data", str(ctx.exception))


@unittest.skipUnless(torch, "torch is not installed: R2's tests run where it is")
class TCN(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="rc-tcn-")
        cls.dataset, cls.closure, cls.folds_file = make(cls.tmp)
        cls.prep = train.prepare(cls.dataset, cls.folds_file, cls.closure, "present")
        cls.family = train.R2(cls.prep, 20261103, r2_epochs=1)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def windows(self, fold):
        return self.family.windows(self.prep.of(lambda f: f == fold))

    def test_the_architecture(self):
        model = tcn.TCN(np.zeros(19), np.ones(19))
        self.assertEqual(tcn.parameters(model), 26433)
        self.assertEqual(model(torch.zeros(2, 600, 19)).shape, (2, 600))
        # the receptive field is ±62 cells: a change 63 cells away does not reach, one 62 away does
        model.eval()
        x = torch.zeros(1, 600, 19)
        base = model(x)[0, 300].item()
        for offset, reaches in ((63, False), (-63, False), (62, True), (-62, True)):
            y = x.clone()
            y[0, 300 + offset] = 5.0
            self.assertEqual(model(y)[0, 300].item() != base, reaches, offset)

    def test_cells_without_weight_change_no_loss_and_no_gradient(self):
        ws = self.windows(0)
        tcn.deterministic(1)
        model = tcn.TCN(*tcn.standardisation(ws))
        model.eval()

        def loss_and_gradients(data):
            model.zero_grad()
            loss = tcn.loss_of(model, data, slice(None))
            loss.backward()
            return loss.item(), [p.grad.clone() for p in model.parameters()]

        loss, grads = loss_and_gradients(ws)
        flipped = {**ws, "y": np.where(ws["weight"] == 0, 1 - ws["y"], ws["y"]).astype(np.float32)}
        self.assertGreater(int((ws["weight"] == 0).sum()), 1000)
        loss2, grads2 = loss_and_gradients(flipped)
        self.assertEqual(loss, loss2)
        for a, b in zip(grads, grads2):
            self.assertTrue(torch.equal(a, b))

    def test_a_window_carries_weight_only_where_it_answers(self):
        grids = self.family.inputs(self.prep.recordings[0])
        ws = tcn.window_set(grids)
        total = sum(float(g["w"].sum()) for g in grids)
        self.assertEqual(float(ws["weight"].sum()), total)                 # every weighted cell exactly once
        self.assertEqual(ws["X"].shape[1:], (600, 19))
        mean, std = tcn.standardisation(ws)
        self.assertEqual((mean[-1], std[-1]), (0.0, 1.0))                  # no missing cell carries weight

    def test_windowed_logits_are_the_whole_segments(self):
        tcn.deterministic(2)
        g = max(self.family.inputs(self.prep.recordings[0]), key=lambda g: len(g["y"]))
        self.assertGreater(len(g["y"]), 1200)
        model = tcn.TCN(*tcn.standardisation(tcn.window_set([g])))
        model.eval()
        with torch.no_grad():
            whole = model(torch.from_numpy(g["X"].astype(np.float32))[None])[0].numpy()
        (windowed,) = tcn.cell_logits(model, [g])
        cells = len(g["y"])
        np.testing.assert_allclose(windowed[:cells - 62], whole[:cells - 62], atol=1e-5)   # the last 62 see the repeated last cell

    def test_augmentation(self):
        rng = np.random.default_rng(0)
        X = np.zeros((400, 600, 19), dtype=np.float32)
        for name in ("has_ball", "is_projectile", "n_court_dets", "n_dets", "n_cands", "n_cands_proj"):
            X[:, :, v.FEATURE_INDEX[name]] = 1.0
        for name in ("max_conf", "ball_y_any", "sel_x", "sel_y", "sel_size", "r2", "grav", "y_above_net"):
            X[:, :, v.FEATURE_INDEX[name]] = 0.5
        X[:, :, v.FEATURE_INDEX["dt"]] = 1 / 30
        before = X.copy()
        out = tcn.augment(X, rng)
        np.testing.assert_array_equal(X, before)
        dropped = out[:, :, v.FEATURE_INDEX["has_ball"]] == 0
        runs = dropped.sum(axis=1)
        self.assertTrue(set(runs.tolist()) <= {0, *range(3, 16)})          # none, or one run of 0.1–0.5 s
        self.assertTrue(20 <= int((runs > 0).sum()) <= 65)                # about one window in ten
        for i in np.flatnonzero(runs > 0)[:20]:
            where = np.flatnonzero(dropped[i])
            self.assertEqual(where[-1] - where[0] + 1, len(where))         # contiguous
            self.assertTrue((out[i][where][:, tcn._NULLED] == 0).all())
        conf = out[:, :, v.FEATURE_INDEX["max_conf"]][~dropped]
        self.assertTrue(((conf >= 0.45) & (conf <= 0.55)).all())
        self.assertGreater(conf.std(), 0.02)
        untouched = [i for i in range(19) if i not in tcn._NULLED]
        np.testing.assert_array_equal(out[:, :, untouched], X[:, :, untouched])
        blank = np.zeros((4, 600, 19), dtype=np.float32)                   # no detection: no confidence to jitter
        self.assertEqual(float(np.abs(tcn.augment(blank, rng)[:, :, v.FEATURE_INDEX["max_conf"]]).sum()), 0.0)

    def test_training_is_deterministic_and_stops_at_the_best_epoch(self):
        train_ws, val_ws = self.windows(0), self.windows(1)
        a, b = tcn.fit(train_ws, 5, 2, val_ws), tcn.fit(train_ws, 5, 2, val_ws)
        self.assertEqual(a["history"], b["history"])
        for p, q in zip(a["model"].state_dict().values(), b["model"].state_dict().values()):
            self.assertTrue(torch.equal(p, q))
        self.assertEqual(a["epochs"], 1 + int(np.argmin(a["history"])))
        self.assertEqual(a["validationLoss"], min(a["history"]))
        other = tcn.fit(train_ws, 6, 2, val_ws)
        self.assertNotEqual(other["history"], a["history"])
        refit = tcn.fit(train_ws, 5, 1)
        self.assertEqual((refit["epochs"], refit["history"]), (1, []))

    def test_nothing_chosen_for_a_fold_reads_that_fold(self):
        clean = train.choose(self.prep, self.family, 0, train.baseline_cards(self.prep)["r0"])
        bad = poisoned(self.prep, 0)
        self.assertEqual(train.choose(bad, train.R2(bad, 20261103, r2_epochs=1), 0, train.baseline_cards(bad)["r0"]), clean)

    def test_r2_end_to_end_with_h2_against_an_r1_run(self):
        r1_out, r2_out = os.path.join(self.tmp, "run-r1"), os.path.join(self.tmp, "run-r2")
        train.run(self.prep, "r1", 20261103, r1_out, [])
        ablated = train.prepare(self.dataset, self.folds_file, self.closure, "ablated")
        with self.assertRaises(train.Refused):               # an R1 run of the other net condition is not the comparison
            train.run(ablated, "r2", 20261103, os.path.join(self.tmp, "run-r2-ablated"), [], r1_run=r1_out, r2_epochs=1)
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "run-r2-ablated")))
        report = train.run(self.prep, "r2", 20261103, r2_out, [], r1_run=r1_out, r2_epochs=1)
        self.assertEqual(sorted(os.listdir(os.path.join(r2_out, "fold3"))), ["calibration.json", "decode.json", "weights.json", "weights.pt"])
        weights = syn.read_json(os.path.join(r2_out, "fold3", "weights.json"))
        self.assertEqual((weights["parameters"], weights["grid"], weights["lookaheadSec"], weights["inputs"]), (26433, "grid_v1", 2.1, ft.GRID_NAMES))
        self.assertEqual(weights["choice"]["epochs"], 1)
        state = torch.load(os.path.join(r2_out, "fold3", "weights.pt"))
        self.assertEqual(state["inp.weight"].shape, (32, 19))
        self.assertEqual((report["identity"]["candidate"], report["identity"]["seed"], report["identity"]["versions"]["torch"]), ("r2", 20261103, torch.__version__))
        (h2,) = report["hypotheses"]
        self.assertEqual((h2["hypothesis"], h2["comparison"]), ("H2", "r2 vs r1"))
        self.assertIn(h2["holds"], (True, False))
        self.assertEqual(set(report["tables"]["pooled"]["variants"]), {"r0", "r0_prime", "r2"})
        self.assertEqual(len(syn.read_text(os.path.join(r2_out, "oof.jsonl")).splitlines()), sum(len(r.arr["t"]) for r in self.prep.recordings))

    def test_a_dry_run_of_r2_fits_nothing(self):
        out = os.path.join(self.tmp, "dry-r2")
        with mock.patch.object(tcn, "fit", boom), mock.patch.object(tcn, "standardisation", boom), mock.patch.object(tcn, "cell_logits", boom), \
                mock.patch.object(evaluate, "card", boom), mock.patch.object(rs, "score", boom):
            code, _, err = quiet(train.main, argv(self.dataset, self.closure, self.folds_file, out, "r2", "present", "--dry-run"))
        self.assertEqual(code, 0, err)
        doc = syn.read_json(os.path.join(out, "readiness.json"))
        self.assertEqual(doc["inputs"]["inputs"], 19)
        self.assertGreater(doc["inputs"]["windows"], 18)
        self.assertGreater(doc["inputs"]["cellsWithLossWeight"], 0)
        self.assertEqual(sorted(os.listdir(out)), ["readiness.json", "readiness.md"])


if __name__ == "__main__":
    unittest.main()
