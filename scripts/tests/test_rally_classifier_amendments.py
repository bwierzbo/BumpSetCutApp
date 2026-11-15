"""Tests for what the owner accepted on 2026-11-14 (amendments A4, A8, A9, A10, A13 with their reporting
requirements) and for the adopted negative-coverage gate (G7, and G6 over trusted negatives), on synthetic
datasets: handheld recordings apart and the sensitivity analysis without them; the decode fallbacks said out
loud; the calibration limitation and the size of the class-balancing shift; the baseline asymmetry and the
optional matched baseline; the exposure statement; trusted negatives from Stage 1 coverage and from
reviewed-clean intervals, the refusals and the dry run's report. No real recording is involved.

    python3 -m unittest scripts.tests.test_rally_classifier_amendments -v
"""

import copy
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
from test_rally_classifier_train import argv, boom, make, quiet  # noqa: E402
import decode  # noqa: E402
import evaluate  # noqa: E402
import folds  # noqa: E402
import train  # noqa: E402
import trusted_negatives as tn  # noqa: E402
import validate_dataset as v  # noqa: E402

S = v.STATES


class Reports(unittest.TestCase):
    """Two R1 runs on the same recordings and folds: one on a dataset without the matched baseline, one with it."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="rc-amend-")
        cls.plain, cls.matched = {}, {}
        for side, name, kw in ((cls.plain, "plain", {}), (cls.matched, "matched", {"matched_baseline": True})):
            folder = os.path.join(cls.tmp, name)
            os.makedirs(folder)
            side["dataset"], side["closure"], side["folds"] = make(folder, **kw)
            side["manifest"] = v.load_manifest(side["dataset"])
            side["run"] = os.path.join(folder, "run")
            side["code"], side["out"], side["err"] = quiet(train.main, argv(side["dataset"], side["closure"], side["folds"], side["run"]))
            assert side["code"] == 0, side["err"]
            side["report"] = syn.read_json(os.path.join(side["run"], "report.json"))
            side["md"] = syn.read_text(os.path.join(side["run"], "report.md"))
        cls.prep = train.prepare(cls.plain["dataset"], cls.plain["folds"], cls.plain["closure"], "present")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def cards(self, variant, side=None, keep=lambda c: not c["restrictedUse"]):
        side = side or self.plain
        every = [syn.read_json(os.path.join(side["run"], "scorecards", variant, f"{r['recordingId']}.evaluation_v2.json")) for r in side["manifest"]["recordings"]]
        return [c for c in every if keep(c)]

    # ---- A4: handheld recordings ------------------------------------------------------------------
    def test_a_handheld_recording_is_told_by_the_camera_field(self):
        # every camera value of the clip plan (RallyLab/StandardClipPlan.swift) and of rc-v1-20261112's manifest
        cameras = {"End line, elevated (stands/tripod 2m+)": False, "End line, ground level": False, "Sideline / near net": False,
                   "Tripod / corner": False, "Handheld / corner": True, "Online (CC-licensed)": False, "Extra": False}
        for camera, handheld in cameras.items():
            self.assertEqual(evaluate.is_handheld({"camera": camera}), handheld, camera)

    def test_handheld_recordings_stay_in_training_and_in_the_headline(self):
        tables = self.plain["report"]["tables"]
        standard = [r for r in self.plain["manifest"]["recordings"] if not r["restrictedUse"]]
        self.assertIn("syn_gra_02", {r["recordingId"] for r in standard})
        self.assertEqual(tables["pooled"]["sample"]["recordings"], len(standard))          # the headline holds it
        fold = syn.read_json(self.plain["folds"])["recordings"]["syn_gra_02"]
        for k in range(5):                                                                  # and it is trained on in every other fold
            self.assertEqual("syn_gra_02" in {r.rid for r in self.prep.of(lambda f: f != k)}, k != fold)
        self.assertEqual(tables["pooled"]["handheldRecordings"], ["syn_gra_02"])            # the restricted one is not a headline recording

    def test_handheld_recordings_are_reported_apart(self):
        apart = self.plain["report"]["tables"]["handheld"]
        self.assertEqual(apart["recordings"], [{"recordingId": "syn_bea_01", "restrictedUse": True}, {"recordingId": "syn_gra_02", "restrictedUse": False}])
        self.assertEqual(apart["sample"]["recordings"], 2)
        self.assertEqual(apart["differences"]["r1 - r0"],
                         evaluate.paired_bootstrap(self.cards("r1", keep=lambda c: c["handheld"]), self.cards("r0", keep=lambda c: c["handheld"])))
        self.assertIn("### Handheld recordings (apart)", self.plain["md"])
        self.assertIn("Handheld recordings: syn_bea_01 (restricted), syn_gra_02 (standard).", self.plain["md"])

    def test_every_headline_table_has_its_sensitivity_without_handheld(self):
        tables = self.plain["report"]["tables"]
        keep = lambda c: not c["restrictedUse"] and not c["handheld"]
        pooled, without = tables["pooled"], tables["pooled"]["excludingHandheld"]
        self.assertEqual(without["sample"]["recordings"], pooled["sample"]["recordings"] - 1)
        self.assertEqual(without["differences"]["r1 - r0"], evaluate.paired_bootstrap(self.cards("r1", keep=keep), self.cards("r0", keep=keep)))
        self.assertEqual(set(without["changeFromHeadline"]), set(pooled["differences"]))    # every candidate-vs-reference comparison
        for name, change in without["changeFromHeadline"].items():
            for key, c in change.items():
                self.assertEqual(c["headline"], pooled["differences"][name][key]["delta"])
                self.assertEqual(c["excludingHandheld"], without["differences"][name][key]["delta"])
                if c["change"] is not None:
                    self.assertAlmostEqual(c["change"], c["excludingHandheld"] - c["headline"])
        self.assertNotEqual(without["changeFromHeadline"]["r1 - r0"]["completeRallyRecall"]["change"], None)
        # by surface, fold and group: the tables that hold the handheld recording, and only those
        fold = str(syn.read_json(self.plain["folds"])["recordings"]["syn_gra_02"])
        for key, holder in (("bySurface", "grass"), ("byFold", fold), ("byGroup", "g-gra-02")):
            for name, table in tables[key].items():
                self.assertEqual(table["excludingHandheld"] is not None, name == holder, (key, name))
                self.assertEqual(table["handheldRecordings"], ["syn_gra_02"] if name == holder else [])
        self.assertEqual(tables["byGroup"]["g-gra-02"]["excludingHandheld"]["sample"]["recordings"], 0)     # nothing left: said, not hidden
        self.assertNotIn("excludingHandheld", tables["restricted"])
        self.assertIn("Handheld sensitivity — without syn_gra_02: 16 recordings", self.plain["md"])
        self.assertIn("this table holds no handheld recording", self.plain["md"])
        self.assertIn("No recording is left.", self.plain["md"])

    def test_h1_is_evaluated_with_and_without_handheld_and_the_headline_verdict_stands(self):
        (h1,) = self.plain["report"]["hypotheses"]
        pooled = self.plain["report"]["tables"]["pooled"]
        without = h1["excludingHandheld"]
        self.assertEqual(without["sample"], pooled["excludingHandheld"]["sample"])
        alone = evaluate.h1({"differences": pooled["excludingHandheld"]["differences"]}, "r1")
        self.assertEqual((without["clauses"], without["holds"]), (json.loads(json.dumps(alone["clauses"])), alone["holds"]))
        self.assertIsNone(alone["excludingHandheld"])                                      # a table without the sensitivity: nothing to report
        self.assertEqual(without["verdictUnchanged"], without["holds"] == h1["holds"])
        self.assertEqual(h1["holds"], evaluate.h1({"differences": pooled["differences"]}, "r1")["holds"])   # the verdict is the headline's
        self.assertIn("Handheld sensitivity — without the handheld recordings (16 recordings", self.plain["md"])
        self.assertIn("the headline verdict stands", self.plain["md"])

    def test_h2_is_evaluated_with_and_without_handheld(self):
        a, b = self.cards("r1"), self.cards("r0")                                          # any two sets of cards on the same recordings
        result = evaluate.h2(a, b)
        keep = lambda c: not c["restrictedUse"] and not c["handheld"]
        alone = evaluate.h2(self.cards("r1", keep=keep), self.cards("r0", keep=keep))
        self.assertEqual(result["excludingHandheld"]["clauses"], alone["clauses"])
        self.assertEqual(result["excludingHandheld"]["sample"]["recordings"], len(a) - 1)
        self.assertEqual(result["excludingHandheld"]["verdictUnchanged"], alone["holds"] == result["holds"])
        self.assertIsNone(alone["excludingHandheld"])                                      # no handheld recording: nothing to exclude

    # ---- A8: the decode-point selection's fallbacks -----------------------------------------------
    def held(self, prep=None):
        prep = prep or self.prep
        return prep, prep.of(lambda f: f == 1), train.baseline_cards(prep)["r0"]

    def test_a_point_that_meets_the_constraint_uses_no_fallback(self):
        prep, held, r0 = self.held()
        _, selection = train.select_decode(prep, held, {r.rid: r.target for r in held}, r0)     # the truth as probabilities
        self.assertEqual((selection["fallbacks"], selection["constraintMet"]), ([], True))
        self.assertGreater(selection["feasiblePoints"], 0)

    def test_the_recall_fallback_is_reported_with_counts_and_why(self):
        prep, held, r0 = self.held()
        point, selection = train.select_decode(prep, held, {r.rid: np.zeros(len(r.target)) for r in held}, r0)   # no clip at any point
        (fallback,) = selection["fallbacks"]
        r0_complete = sum(r0[r.rid]["scorecard"]["paddedExport"]["complete"] for r in held)
        rallies = sum(len(r.rec["rallies"]) for r in held)
        self.assertGreater(r0_complete, 0)
        self.assertEqual(fallback["kind"], "recall_constraint_not_met")
        self.assertEqual((fallback["pointsMeetingConstraint"], fallback["gridPoints"], fallback["pointsAtBest"]), (0, 108, 108))
        self.assertEqual((fallback["r0Complete"], fallback["bestComplete"], fallback["shortBy"], fallback["rallies"]), (r0_complete, 0, r0_complete, rallies))
        self.assertEqual((fallback["r0Recall"], fallback["bestRecall"]), (r0_complete / rallies, 0.0))
        self.assertEqual(fallback["byRecording"], [{"recordingId": r.rid, "rallies": len(r.rec["rallies"]),
                                                    "r0Complete": r0[r.rid]["scorecard"]["paddedExport"]["complete"], "complete": 0} for r in held])
        self.assertIn(f"none of the 108 grid points reached R0's {r0_complete} complete rallies of {rallies}", fallback["why"])
        self.assertIn("most complete rallies", fallback["rule"])
        self.assertEqual((selection["constraintMet"], selection["feasiblePoints"], point), (False, 0, decode.GRID[0]))    # the behaviour is unchanged

    def test_the_dead_time_fallback_is_reported(self):
        prep = copy.deepcopy(self.prep)
        for r in prep.of(lambda f: f == 1):
            r.rec["eligibility"]["fullVideoNegatives"] = "not_assessed"                    # no fully marked recording in the nested fold
        prep, held, r0 = self.held(prep)
        _, selection = train.select_decode(prep, held, {r.rid: r.target for r in held}, r0)
        (fallback,) = selection["fallbacks"]
        self.assertEqual((fallback["kind"], fallback["fullyMarkedRecordings"]), ("dead_time_retention_undefined", 0))
        self.assertIn("no fully marked recording", fallback["why"])
        self.assertFalse(selection["deadTimeAvailable"])
        _, both = train.select_decode(prep, held, {r.rid: np.zeros(len(r.target)) for r in held}, r0)
        self.assertEqual([x["kind"] for x in both["fallbacks"]], ["recall_constraint_not_met", "dead_time_retention_undefined"])

    def test_a_run_without_a_fallback_says_so(self):
        fallbacks = self.plain["report"]["decodeFallbacks"]
        self.assertEqual((fallbacks["used"], fallbacks["folds"]), (False, []))
        self.assertIn("No fallback was used: in each of the 5 folds", fallbacks["statement"])
        self.assertIn(fallbacks["statement"], self.plain["md"])
        for k in range(5):
            self.assertEqual(syn.read_json(os.path.join(self.plain["run"], f"fold{k}", "decode.json"))["selection"]["fallbacks"], [])

    def test_a_run_that_used_a_fallback_says_which_in_the_folds_record_and_in_the_report(self):
        out = os.path.join(self.tmp, "run-fallback")
        with mock.patch.object(train, "probabilities", lambda logits, temperature: np.zeros(len(logits))):    # a model that decodes nothing
            report = train.run(self.prep, "r1", 20261103, out, [])
        fallbacks = report["decodeFallbacks"]
        self.assertTrue(fallbacks["used"])
        self.assertEqual([row["fold"] for row in fallbacks["folds"]], [0, 1, 2, 3, 4])
        self.assertIn("in 5 of 5 folds", fallbacks["statement"])
        md = syn.read_text(os.path.join(out, "report.md"))
        for k in range(5):
            (recorded,) = syn.read_json(os.path.join(out, f"fold{k}", "decode.json"))["selection"]["fallbacks"]
            self.assertEqual(recorded, json.loads(json.dumps(fallbacks["folds"][k]["fallbacks"][0])))
            self.assertEqual((recorded["kind"], recorded["pointsMeetingConstraint"]), ("recall_constraint_not_met", 0))
            self.assertIn(f"- outer fold {k} (chosen on nested fold {(k + 1) % 5}) — `recall_constraint_not_met`: {recorded['why']}", md)
        self.assertNotIn("No fallback was used", md)

    # ---- A9: the calibration limitation ------------------------------------------------------------
    def test_every_report_states_the_calibration_limitation_and_the_shift_per_fold(self):
        report = self.plain["report"]
        self.assertEqual(report["calibration"], {"limitation": train.CALIBRATION_LIMITATION, "classBalanced": True})
        self.assertIn(train.CALIBRATION_LIMITATION, self.plain["md"])
        for needle in ("no bias term is fitted", "δ = ln(n⁻ / n⁺)", "not calibrated class frequencies"):
            self.assertIn(needle, train.CALIBRATION_LIMITATION)
        for k, row in enumerate(report["folds"]):
            weights = syn.read_json(os.path.join(self.plain["run"], f"fold{k}", "weights.json"))
            shift = row["calibration"]["logitShift"]
            # δ is what the class weights the fit used imply: ln(positive weight / negative weight) = ln(n⁻ / n⁺)
            self.assertAlmostEqual(shift["refit"], np.log(weights["classWeights"]["positive"] / weights["classWeights"]["negative"]), places=12)
            training = train._counts(self.prep.of(lambda f: f != k))
            self.assertAlmostEqual(shift["refit"], np.log(training["negativeSteps"] / training["positiveSteps"]), places=12)
            self.assertAlmostEqual(shift["classFrequencyAtHalf"], training["positiveSteps"] / (training["positiveSteps"] + training["negativeSteps"]), places=12)
            calibration = syn.read_json(os.path.join(self.plain["run"], f"fold{k}", "calibration.json"))
            self.assertEqual((calibration["method"], calibration["limitation"]), ("temperature", train.CALIBRATION_LIMITATION))
            self.assertEqual(calibration["logitShift"], shift)
            self.assertEqual(set(weights) & {"bias", "calibrationBias"}, set())            # no bias term was added
        self.assertIn("Reliability, beach (standard recordings, steps with loss weight):", self.plain["md"])     # the table is still reported

    # ---- A10: the baseline asymmetry ---------------------------------------------------------------
    def test_every_report_states_the_asymmetry_and_what_can_be_counted(self):
        asym = self.plain["report"]["baselineAsymmetry"]
        recs = self.plain["manifest"]["recordings"]
        clips = {r["recordingId"]: len(v.read_baseline(self.plain["dataset"], r)["r0"]) for r in recs}
        no_net = sorted(r["recordingId"] for r in recs if r["net"] is None)
        self.assertEqual(no_net, ["syn_gra_00", "syn_gra_00_v2"])
        self.assertEqual((asym["primaryBaseline"], asym["statement"]), ("r0", train.ASYMMETRY))
        self.assertEqual(asym["ruleNeverRan"], {"recordings": no_net, "rallies": sum(len(r["rallies"]) for r in recs if r["net"] is None),
                                                "r0Clips": sum(clips[rid] for rid in no_net)})
        self.assertEqual(asym["ruleRan"]["recordings"], len(recs) - 2)
        self.assertEqual(asym["ruleRan"]["r0Clips"] + asym["ruleNeverRan"]["r0Clips"], sum(clips.values()))
        self.assertEqual(self.plain["report"]["tables"]["netRuleNeverRan"]["sample"]["recordings"], 2)
        for needle in ("## Baseline asymmetry (the above-net rule)", train.ASYMMETRY, "It never ran on 2", "above-net rule never ran (no detected net)"):
            self.assertIn(needle, self.plain["md"])
        self.assertIn("primary baseline", train.ASYMMETRY)
        self.assertIn("advantage", train.ASYMMETRY)

    def test_a_dataset_without_the_matched_baseline_says_so_and_what_is_missing(self):
        matched = self.plain["report"]["baselineAsymmetry"]["matchedBaseline"]
        self.assertEqual((matched["variant"], matched["present"]), ("r0_no_net_rule", False))
        self.assertIn("matched baseline not in this dataset", matched["note"].lower())
        self.assertIn("cannot be counted", matched["note"])
        self.assertNotIn("clipsRemovedByRule", matched)
        self.assertIsNone(self.plain["report"]["tablesAgainstMatchedBaseline"])
        self.assertIn("Matched baseline not in this dataset", self.plain["md"])
        self.assertNotIn("Secondary comparison", self.plain["md"])

    def test_a_stored_matched_baseline_is_a_secondary_comparison_and_counts_the_removed_clips(self):
        report, recs = self.matched["report"], self.matched["manifest"]["recordings"]
        stored = {r["recordingId"]: v.read_baseline(self.matched["dataset"], r) for r in recs}
        removed = {rid: len(b["r0_no_net_rule"]) - len(b["r0"]) for rid, b in stored.items()}
        matched = report["baselineAsymmetry"]["matchedBaseline"]
        self.assertTrue(matched["present"])
        self.assertGreater(sum(removed.values()), 0)
        self.assertEqual(matched["clipsRemovedByRule"], sum(removed.values()))
        self.assertEqual(matched["byRecording"], {rid: n for rid, n in removed.items() if n})
        self.assertEqual({removed[r["recordingId"]] for r in recs if r["net"] is None}, {0})       # no net, no rule, nothing removed
        self.assertEqual((matched["r0Clips"], matched["matchedClips"]), (sum(len(b["r0"]) for b in stored.values()), sum(len(b["r0_no_net_rule"]) for b in stored.values())))
        self.assertEqual(report["parity"]["clipsRebuilt"]["r0_no_net_rule"], matched["matchedClips"])  # the port rebuilds its clips too
        secondary = report["tablesAgainstMatchedBaseline"]
        self.assertEqual(set(secondary["pooled"]["differences"]), {"r0 - r0_no_net_rule", "r0_prime - r0_no_net_rule", "r1 - r0_no_net_rule"})
        keep = lambda c: not c["restrictedUse"]
        self.assertEqual(secondary["pooled"]["differences"]["r1 - r0_no_net_rule"],
                         evaluate.paired_bootstrap(self.cards("r1", self.matched, keep), self.cards("r0_no_net_rule", self.matched, keep)))
        advantage = secondary["pooled"]["differences"]["r0 - r0_no_net_rule"]              # R0's advantage from the rule, measured
        self.assertLess(advantage["falseClips"]["delta"], 0)
        self.assertLess(advantage["deadTimeRetention"]["delta"], 0)
        self.assertEqual(set(secondary), set(report["tables"]))                            # every table, against the matched baseline too
        for needle in ("## Secondary comparison: against the matched baseline `r0_no_net_rule`", "### Pooled (standard recordings) — vs r0_no_net_rule",
                       "The primary baseline is R0; H1 and H2 are evaluated against it above and are not re-evaluated here.",
                       f"Clips the rule removed from R0: **{sum(removed.values())}**"):
            self.assertIn(needle, self.matched["md"])

    def test_the_primary_baseline_and_h1_do_not_change_when_a_matched_baseline_is_stored(self):
        self.assertEqual(self.matched["report"]["hypotheses"], self.plain["report"]["hypotheses"])
        self.assertEqual(self.matched["report"]["hypotheses"][0]["comparison"], "r1 vs r0")
        plain, matched = self.plain["report"]["tables"]["pooled"], self.matched["report"]["tables"]["pooled"]
        self.assertEqual(matched["differences"]["r1 - r0"], plain["differences"]["r1 - r0"])
        self.assertEqual(matched["variants"]["r0"], plain["variants"]["r0"])
        self.assertEqual(set(matched["differences"]), {"r0_no_net_rule - r0", "r0_prime - r0", "r1 - r0"})
        self.assertEqual(self.matched["report"]["baselineAsymmetry"]["primaryBaseline"], "r0")

    # ---- A13: what the evidence is -----------------------------------------------------------------
    def test_every_report_opens_with_what_the_evidence_is(self):
        exposure = self.plain["report"]["exposure"]
        self.assertEqual(exposure["statement"], "Development evaluation on recordings with historical detector and decider exposure — "
                                                "not independent final-test evidence.")
        self.assertEqual((exposure["recordings"], exposure["recordingsByKind"], exposure["trainingPackages"], exposure["recordingsWithoutARow"]),
                         (18, {"training_package": 18}, {"synthetic": 18}, []))
        head = self.plain["md"].split("## Choices made inside the training folds")[0]
        self.assertIn(f"**{exposure['statement']}** Of the 18 recordings, as the manifest records the exposure ledger at export: 18 with a `training_package` row", head)
        self.assertIn(train.UNKNOWN_IS_NOT_CLEARED, head)
        self.assertIn("Development evidence only: every recording here has training and selection exposure (preregistration §1).", head)

    def test_exposure_is_counted_from_the_manifests_rows(self):
        row = lambda kind, ref: {"date": "2026-11-01", "kind": kind, "ref": ref}
        manifest = {"recordings": [
            {"recordingId": "a", "exposure": [row("training_package", "L1"), row("training_package", "L2"), row("rally_scoring", "--score-rallies")]},
            {"recordingId": "b", "exposure": [row("training_package", "L2"), row("training_package", "L2")]},
            {"recordingId": "c", "exposure": [row("ball_path", "BallPathBuilder")]},
            {"recordingId": "d", "exposure": []}]}
        got = train.exposure_summary(manifest)
        self.assertEqual(got["recordingsByKind"], {"ball_path": 1, "rally_scoring": 1, "training_package": 2})
        self.assertEqual(got["trainingPackages"], {"L1": 1, "L2": 2})
        self.assertEqual((got["recordings"], got["recordingsWithoutARow"]), (4, ["d"]))
        self.assertIn("1 with no row", "\n".join(evaluate.exposure_md(got)))

    def test_no_caveat_was_dropped(self):
        kept = ["Development evidence only: every recording is in the detectors' training packages and most carry decider-selection exposure.",
                "r0_prime is the D-029 reference: its settings were selected on these recordings; it is never the benchmark.",
                "R2 reads the 30 Hz grid view and misses the earlier of two steps that share a cell; R1 sees every step."]
        for caveat in kept:
            self.assertIn(caveat, train.CAVEATS)
        above_net = train.CAVEATS[2]
        self.assertTrue(above_net.startswith("The stored baseline clips passed the pipeline's above-net rule after SegmentBuilder; the learned candidate's "
                                             "clips go through the SegmentBuilder port only ("))
        self.assertTrue(above_net.endswith("so a clip the rule would drop stays in the candidate's export."))
        self.assertEqual(self.plain["report"]["caveats"], train.CAVEATS)
        self.assertGreaterEqual(len(train.CAVEATS), 8)
        tail = self.plain["md"].split("## Caveats")[1]
        for caveat in train.CAVEATS:
            self.assertIn(f"- {caveat}", tail)


class BalancingShift(unittest.TestCase):
    """The size of the shift class balancing gives a logistic model's intercept, on data where no hyperplane
    separates the classes (the labels are drawn from a logistic model, so both fits have a finite minimum)."""

    @classmethod
    def setUpClass(cls):
        rng = np.random.default_rng(20261114)
        n = 200_000
        cls.X = rng.normal(size=(n, 4)) * [1.0, 2.0, 0.5, 1.0] + [0.0, 1.0, -3.0, 0.0]
        true_logit = -1.6 + 1.2 * cls.X[:, 0] - 0.4 * (cls.X[:, 1] - 1.0) + 1.0 * (cls.X[:, 2] + 3.0)      # the fourth column carries nothing
        cls.t = (rng.random(n) < train.sigmoid(true_logit)).astype(float)
        cls.w = np.ones(n)
        cls.positive, cls.negative = int(cls.t.sum()), int(n - cls.t.sum())
        cls.balanced = train.fit_logistic(cls.X, cls.t, cls.w, 1e-9)
        Z = (cls.X - cls.balanced["mean"]) / cls.balanced["std"]
        theta, gradient = train.minimise(Z, cls.t, np.full(n, 1.0 / n), 1e-9)           # the same objective, every step weighing the same
        assert gradient < 1e-9 and cls.balanced["gradientMax"] < 1e-9
        cls.Z, cls.plain = Z, {"coefficients": theta[:-1], "intercept": float(theta[-1])}
        cls.delta = train.balancing_shift(cls.positive, cls.negative)

    def test_the_classes_overlap_and_are_unbalanced(self):
        self.assertGreater(self.negative, 2 * self.positive)
        self.assertAlmostEqual(self.delta, np.log(self.negative / self.positive))
        self.assertGreater(self.delta, 0.7)
        p = train.sigmoid(self.Z @ self.plain["coefficients"] + self.plain["intercept"])
        self.assertGreater(int(((p > 0.2) & (p < 0.8)).sum()), 20_000)                     # no separation: many uncertain steps

    def test_the_intercept_moves_by_ln_of_the_class_ratio_and_the_slopes_stay(self):
        self.assertAlmostEqual(self.balanced["intercept"] - self.plain["intercept"], self.delta, delta=0.03)
        np.testing.assert_allclose(self.balanced["coefficients"], self.plain["coefficients"], atol=0.03)
        # the shift is what the fit's own class weights imply
        self.assertAlmostEqual(np.log(self.balanced["positiveWeight"] / self.balanced["negativeWeight"]), self.delta, places=12)

    def test_a_temperature_cannot_remove_the_offset(self):
        logits = self.Z @ self.balanced["coefficients"] + self.balanced["intercept"]
        temperature = train.fit_temperature(logits, self.t, self.w)
        self.assertEqual(float(train.probabilities(np.zeros(1), temperature)[0]), 0.5)     # any T leaves p = 0.5 at logit 0 …
        near_half = np.abs(logits) < 0.1
        self.assertGreater(int(near_half.sum()), 2000)
        frequency = self.positive / (self.positive + self.negative)
        self.assertAlmostEqual(self.t[near_half].mean(), frequency, delta=0.04)            # … where the class frequency is n⁺ / (n⁺ + n⁻)
        self.assertLess(frequency, 0.34)
        calibrated = train.probabilities(logits, temperature)
        self.assertGreater(calibrated.mean() - self.t.mean(), 0.03)                        # the balanced model still over-states the rarer class
        unweighted = train.sigmoid(self.Z @ self.plain["coefficients"] + self.plain["intercept"])
        self.assertAlmostEqual(unweighted.mean(), self.t.mean(), delta=0.002)              # the unweighted one does not


def step(tick, y, seg=0):
    return {"t": tick / v.TIMESCALE, "tick": tick, "seg": seg, "y": y, "w": v.WEIGHTS[str(y)]}


def recording(rid="x", group="g", state="declared_complete", negatives="standard", audit=None):
    coverage = {"state": state, "verifiedCoverageSec": None}
    if audit is not None:
        coverage["audit"] = {"state": "audited_clean", "auditSha256": "0" * 64, "drawId": "draw", "cleanIntervals": [{"startTick": a, "endTick": b} for a, b in audit]}
    return {"recordingId": rid, "groupId": group, "coverage": coverage, "eligibility": {"fullVideoNegatives": negatives}}


class TrustedTime(unittest.TestCase):
    def test_trust_comes_from_stage1_coverage_or_reviewed_clean_intervals_only(self):
        self.assertEqual(tn.trusted_time(recording(state="stage1_complete"), False)[:2], (tn.STAGE1, None))
        self.assertEqual(tn.trusted_time(recording(state="stage1_complete"), True)[:2], (tn.STAGE1, None))
        source, spans, why = tn.trusted_time(recording(), False)                           # declared complete, schema v1
        self.assertEqual((source, spans), (tn.NONE, []))
        self.assertIn("declared, not audited", why)
        source, spans, why = tn.trusted_time(recording(), True)                            # schema v2, never audited
        self.assertEqual((source, spans, why), (tn.NONE, [], "coverage declared_complete: not audited"))
        self.assertEqual(tn.trusted_time(recording(audit=[(0, 600), (1200, 1800)]), True), (tn.CLEAN, [(0, 600), (1200, 1800)], None))
        self.assertEqual(tn.trusted_time(recording(audit=[(0, 600)]), False)[0], tn.NONE)  # an audit record is read under v2 only
        self.assertEqual(tn.trusted_time(recording(audit=[]), True)[0], tn.NONE)           # audited, nothing clean
        for state in ("partial", "none"):
            self.assertEqual(tn.trusted_time(recording(state=state), True)[0], tn.NONE)

    def test_an_edited_recording_supplies_no_negative_whatever_its_audit_or_coverage_says(self):
        for negatives in ("restricted", "not_assessed", "quarantined", "ineligible"):
            for rec in (recording(negatives=negatives, audit=[(0, 6000)]), recording(negatives=negatives, state="stage1_complete")):
                source, spans, why = tn.trusted_time(rec, True)
                self.assertEqual((source, spans), (tn.NONE, []))
                self.assertIn(f"full-video negatives are {negatives}", why)

    def test_an_audit_record_that_cannot_be_read_is_an_error(self):
        broken = recording(audit=[(0, 600)])
        for bad in ({"state": "audited_clean"}, {"cleanIntervals": [{"startTick": 0}]}, {"cleanIntervals": [{"startTick": 600, "endTick": 600}]},
                    {"cleanIntervals": [{"startTick": 0.5, "endTick": 600}]}, {"cleanIntervals": "all"}):
            broken["coverage"]["audit"] = bad
            with self.assertRaises(tn.CoverageError):
                tn.trusted_time(broken, True)

    def test_a_clean_interval_is_half_open_in_ticks(self):
        spans = [(600, 1200)]
        self.assertEqual([tn.inside(k, spans) for k in (599, 600, 1199, 1200)], [False, True, True, False])
        self.assertTrue(tn.inside(10 ** 9, None))                                          # the whole recording

    def test_negative_steps_are_counted_by_where_they_lie_not_by_their_label(self):
        steps = [step(0, S["NON_RALLY"]), step(300, S["NON_RALLY"]), step(600, S["UNKNOWN"]),           # clean [0, 900): the UNKNOWN step is no negative
                 step(900, S["NON_RALLY"]), step(1200, S["NON_RALLY_ACTIVITY"]), step(1500, S["ACTIVE_RALLY"]),   # outside: two untrusted negatives
                 step(3000, S["NON_RALLY"], seg=1), step(3300, S["NON_RALLY"], seg=1), step(3600, S["TRANSITION"], seg=1)]   # clean [3000, 3600)
        row = tn.coverage_of(recording(audit=[(0, 900), (3000, 3600)]), steps, True)
        self.assertEqual((row["source"], row["cleanIntervals"], row["cleanSec"]), (tn.CLEAN, 2, 2.5))
        self.assertEqual((row["trustedNegativeSteps"], row["trustedNegativeSec"]), (4, 1.0))            # a segment's first step stands for no time
        self.assertEqual((row["untrustedNegativeSteps"], row["untrustedNegativeSec"]), (2, 1.0))
        self.assertEqual(row["firstUntrusted"], {"tick": 900, "state": "NON_RALLY"})
        declared = tn.coverage_of(recording(), steps, False)                               # v1: every negative step is declared, none trusted
        self.assertEqual((declared["trustedNegativeSteps"], declared["untrustedNegativeSteps"], declared["source"]), (0, 6, tn.NONE))
        stage1 = tn.coverage_of(recording(state="stage1_complete"), steps, False)
        self.assertEqual((stage1["trustedNegativeSteps"], stage1["untrustedNegativeSteps"], stage1["cleanIntervals"]), (6, 0, None))


def rows_and_folds(trusted: dict, folds: dict, untrusted: dict = None):
    """`coverage_of` rows and a folds document for groups named in `folds` ({group: fold}); `trusted` and
    `untrusted` give a group's seconds."""
    untrusted = untrusted or {}
    rows = [{"recordingId": f"rec-{g}", "groupId": g, "source": tn.CLEAN if trusted.get(g) else tn.NONE, "whyNone": None if trusted.get(g) else "not audited",
             "trustedNegativeSteps": int(trusted.get(g, 0) * 30), "trustedNegativeSec": float(trusted.get(g, 0)),
             "untrustedNegativeSteps": int(untrusted.get(g, 0) * 30), "untrustedNegativeSec": float(untrusted.get(g, 0)),
             "firstUntrusted": {"tick": 60, "state": "NON_RALLY"} if untrusted.get(g) else None} for g in folds]
    return rows, {"folds": max(folds.values()) + 1, "groups": [{"groupId": g, "fold": f} for g, f in folds.items()]}


class Gate(unittest.TestCase):
    V1, V2 = {"labelSchema": {"version": tn.DECLARED_LABELS}}, {"labelSchema": {"version": tn.AUDITED_LABELS}}
    FOLDS = {f"g{i:02d}": i % 5 for i in range(25)}                                        # 25 groups, five per fold, as rc-v1-20261112

    def test_two_thirds_of_the_groups_rounded_up(self):
        for groups, required in ((25, 17), (18, 12), (15, 10), (16, 11), (3, 2), (1, 1)):
            folds = {f"g{i:02d}": i % 3 for i in range(groups)}
            doc = tn.report(self.V2, *rows_and_folds({g: 10.0 for g in folds}, folds))
            self.assertEqual(doc["groupsRequired"], required, groups)

    def test_met_when_enough_groups_and_two_in_every_fold(self):
        with_negatives = {g: 30.0 for g in sorted(self.FOLDS)[:17]}                        # g00–g16: fold 0, 1 get four, the others three
        doc = tn.report(self.V2, *rows_and_folds(with_negatives, self.FOLDS))
        self.assertEqual((doc["met"], doc["g6"], doc["g7"], doc["deficiencies"]), (True, {"met": True, "deficiencies": []}, {"met": True, "deficiencies": []}, []))
        self.assertEqual((doc["groupsWithTrustedNegatives"], doc["groups"], doc["negativeLabels"]), (17, 25, "audited"))
        self.assertEqual([len(p["groupsWithTrustedNegatives"]) for p in doc["perFold"]], [4, 4, 3, 3, 3])
        self.assertEqual(doc["trustedNegativeSec"], 17 * 30.0)

    def test_too_few_groups_is_reported_with_the_exact_deficiency(self):
        with_negatives = {g: 30.0 for g in sorted(self.FOLDS)[:16]}
        doc = tn.report(self.V2, *rows_and_folds(with_negatives, self.FOLDS))
        self.assertEqual((doc["met"], doc["g6"]["met"], doc["g7"]["met"]), (False, False, True))
        (deficiency,) = doc["g6"]["deficiencies"]
        self.assertEqual(deficiency, "16 of 25 groups contribute trusted negatives; at least 17 are required (two-thirds, rounded up): 1 short. "
                                     "Groups without: g16, g17, g18, g19, g20, g21, g22, g23, g24")
        self.assertEqual(doc["deficiencies"], [f"G6: {deficiency}"])

    def test_a_fold_with_fewer_than_two_such_groups_is_reported_by_fold(self):
        # folds 0–2 whole, one group of fold 4, none of fold 3
        with_negatives = {**{g: 30.0 for g, f in self.FOLDS.items() if f < 3}, "g04": 5.0}
        doc = tn.report(self.V2, *rows_and_folds(with_negatives, self.FOLDS))
        self.assertEqual(doc["groupsWithTrustedNegatives"], 16)
        self.assertEqual(doc["g6"]["deficiencies"], [
            "16 of 25 groups contribute trusted negatives; at least 17 are required (two-thirds, rounded up): 1 short. "
            "Groups without: g03, g08, g09, g13, g14, g18, g19, g23, g24",
            "fold 3: 0 group(s) with trusted negatives (none); at least 2 are required: 2 short. Groups without: g03, g08, g13, g18, g23",
            "fold 4: 1 group(s) with trusted negatives (g04); at least 2 are required: 1 short. Groups without: g09, g14, g19, g24"])
        enough = {g: 30.0 for g, f in self.FOLDS.items() if f < 4}                         # 20 groups, none in fold 4: the count is met, a fold is not
        doc = tn.report(self.V2, *rows_and_folds(enough, self.FOLDS))
        self.assertEqual(doc["g6"]["deficiencies"], ["fold 4: 0 group(s) with trusted negatives (none); at least 2 are required: 2 short. "
                                                     "Groups without: g04, g09, g14, g19, g24"])

    def test_declared_negatives_do_not_count_and_fail_g7(self):
        declared = {g: 200.0 for g in sorted(self.FOLDS)[:18]}                             # 18 of 25 groups declare negatives, as rc-v1-20261112
        doc = tn.report(self.V1, *rows_and_folds({}, self.FOLDS, declared))
        self.assertEqual((doc["met"], doc["g7"]["met"], doc["g6"]["met"], doc["negativeLabels"]), (False, False, False, "declared, not audited"))
        self.assertEqual((doc["groupsWithTrustedNegatives"], doc["untrustedNegativeSec"], doc["untrustedNegativeSteps"]), (0, 3600.0, 18 * 6000))
        self.assertEqual(doc["g7"]["deficiencies"], ["108000 negative step(s) with loss weight (3600.0 s) in 18 recording(s) are declared, not audited: "
                                                     "they lie in no reviewed-clean interval and under no Stage 1 verified coverage"])
        self.assertEqual(len(doc["g6"]["deficiencies"]), 6)                                # the count, and each of the five folds
        self.assertIn("0 of 25 groups contribute trusted negatives; at least 17 are required (two-thirds, rounded up): 17 short", doc["g6"]["deficiencies"][0])
        md = "\n".join(tn.markdown(doc))
        for needle in ("negatives **declared, not audited**", "**G7: NOT MET**", "**G6: NOT MET** — 0 of 25 groups", "- G6: fold 4: 0 group(s)"):
            self.assertIn(needle, md)

    def test_an_untrusted_negative_in_an_audited_dataset_is_an_error(self):
        with self.assertRaises(tn.CoverageError) as ctx:
            tn.report(self.V2, *rows_and_folds({g: 30.0 for g in self.FOLDS}, self.FOLDS, {"g07": 1.0}))
        self.assertIn("30 negative step(s) with loss weight in 1 recording(s) lie outside every reviewed-clean interval", str(ctx.exception))
        self.assertIn("rec-g07 (30 step(s), first NON_RALLY at tick 60", str(ctx.exception))


class Datasets(unittest.TestCase):
    """The gate on whole synthetic datasets, through `prepare`, the dry run and a real run."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rc-gate-")
        self.out = os.path.join(self.tmp, "run")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def refused(self, args, *fragments):
        fits = [mock.patch.object(train, name, boom) for name in ("fit_logistic", "fit_temperature", "choose", "baseline_cards")]
        with fits[0], fits[1], fits[2], fits[3]:
            code, _, err = quiet(train.main, args)
        self.assertEqual(code, 1, err)
        for fragment in fragments:
            self.assertIn(fragment, err)
        self.assertFalse(os.path.exists(self.out))
        return err

    def test_stage1_verified_coverage_supplies_trusted_negatives(self):
        dataset, closure, folds_file = make(self.tmp)                                      # the default: every continuous recording Stage 1 verified
        gate = train.prepare(dataset, folds_file, closure, "present").negatives
        self.assertEqual((gate["met"], gate["labelSchema"], gate["negativeLabels"]), (True, tn.DECLARED_LABELS, "none declared: Stage 1 verified coverage only"))
        self.assertEqual(gate["recordingsBySource"], {tn.STAGE1: 17, tn.CLEAN: 0, tn.NONE: 1})
        self.assertEqual((gate["groupsWithTrustedNegatives"], gate["groups"], gate["groupsRequired"], gate["untrustedNegativeSteps"]), (14, 15, 10, 0))
        labelled = sum(r["labelCounts"]["NON_RALLY"] + r["labelCounts"]["NON_RALLY_ACTIVITY"] for r in v.load_manifest(dataset)["recordings"])
        self.assertEqual(gate["trustedNegativeSteps"], labelled)
        folds_report = syn.read_json(folds_file)["report"]
        self.assertAlmostEqual(gate["trustedNegativeSec"], folds_report["totals"]["validNegativeSec"], delta=0.02)   # each rounded to the millisecond

    def test_a_declared_dataset_is_reported_by_the_dry_run_and_refused_by_a_real_run(self):
        dataset, closure, folds_file = make(self.tmp, trust="declared")                    # the shape of rc-v1-20261112
        args = argv(dataset, closure, folds_file, self.out)
        err = self.refused(args, "refused: the negative-coverage gate is not met (label schema rally_activity_truth_v1, negatives declared, not audited)",
                           "G7: 15210 negative step(s) with loss weight", "are declared, not audited",
                           "G6: 1 of 15 groups contribute trusted negatives; at least 10 are required (two-thirds, rounded up): 9 short",
                           "G6: fold 1: 0 group(s) with trusted negatives (none); at least 2 are required: 2 short")
        self.assertIn("Groups without: g-bea-00, g-bea-01", err)
        prep = train.prepare(dataset, folds_file, closure, "present")                      # the guard is the run's own, not the command line's
        with mock.patch.object(train, "choose", boom), self.assertRaises(train.Refused) as ctx:
            train.run(prep, "r1", 20261103, self.out, [])
        self.assertIn("the negative-coverage gate is not met", str(ctx.exception))
        self.assertFalse(os.path.exists(self.out))
        # the dry run still works on it, and says so with the numbers
        code, out, err = quiet(train.main, args + ["--dry-run"])
        self.assertEqual(code, 0, err)
        self.assertIn("negatives declared, not audited: G7 NOT MET, G6 NOT MET (1 of 15 groups with trusted negatives, 10 required) — a real run would be refused", out)
        doc = syn.read_json(os.path.join(self.out, "readiness.json"))
        gate = doc["negativeCoverage"]
        self.assertEqual((gate["met"], gate["g7"]["met"], gate["g6"]["met"], gate["negativeLabels"]), (False, False, False, "declared, not audited"))
        self.assertEqual((gate["untrustedNegativeSteps"], gate["recordingsBySource"]), (15210, {tn.STAGE1: 2, tn.CLEAN: 0, tn.NONE: 16}))
        self.assertEqual(doc["problems"], gate["deficiencies"])                            # nothing else is wrong with it
        self.assertEqual(len(gate["deficiencies"]), 7)
        self.assertEqual(doc["parity"]["clipsRebuilt"].keys(), {"r0", "r0_prime"})         # the other checks ran and passed
        md = syn.read_text(os.path.join(self.out, "readiness.md"))
        for needle in ("negatives **declared, not audited**", "**G7: NOT MET** — 2108 trusted negative steps", "**G6: NOT MET** — 1 of 15 groups",
                       "A real run on this dataset would be **refused**", "not independent final-test evidence", "## Baseline asymmetry (the above-net rule)",
                       "Matched baseline not in this dataset", "no bias term is fitted", "δ = ln(n⁻ / n⁺) from the counts above (nothing fitted)"):
            self.assertIn(needle, md)
        for row in doc["plan"]:                                                            # δ from the counts alone: nothing was fitted
            self.assertAlmostEqual(row["logitShift"]["refit"], np.log(row["training"]["negativeSteps"] / row["training"]["positiveSteps"]))
            self.assertAlmostEqual(row["logitShift"]["inner"], np.log(row["inner"]["negativeSteps"] / row["inner"]["positiveSteps"]))

    def test_an_audited_dataset_takes_negatives_from_reviewed_clean_intervals_and_runs(self):
        dataset, closure, folds_file = make(self.tmp, trust="audited", unaudited=("g-bea-00", "g-gra-01"))
        manifest = v.load_manifest(dataset)
        prep = train.prepare(dataset, folds_file, closure, "present")
        code, out, err = quiet(train.main, argv(dataset, closure, folds_file, self.out))
        self.assertEqual(code, 0, err)
        gate = prep.negatives
        self.assertEqual((gate["met"], gate["labelSchema"], gate["negativeLabels"], gate["untrustedNegativeSteps"]), (True, tn.AUDITED_LABELS, "audited", 0))
        self.assertEqual(gate["recordingsBySource"], {tn.STAGE1: 2, tn.CLEAN: 12, tn.NONE: 4})   # none: the edited one and the three never audited
        self.assertEqual((gate["groupsWithTrustedNegatives"], gate["groupsRequired"]), (12, 10))
        rows = {r["recordingId"]: r for r in gate["perRecording"]}
        self.assertEqual({rid for rid, r in rows.items() if r["whyNone"] == "coverage declared_complete: not audited"}, {"syn_bea_00", "syn_bea_00_v2", "syn_gra_01"})
        self.assertEqual((rows["syn_bea_00"]["trustedNegativeSteps"], rows["syn_bea_00"]["source"]), (0, tn.NONE))
        not_clean = next(r for r in manifest["recordings"] if r["recordingId"] == syn.NOT_CLEAN)
        self.assertEqual((rows[syn.NOT_CLEAN]["auditState"], rows[syn.NOT_CLEAN]["cleanIntervals"], len(syn.unmarked_intervals(not_clean))), ("contaminated", 2, 3))
        for r in prep.recordings:                                                          # every weighted negative lies in trusted time
            spans = tn.trusted_time(r.rec, True)[1]
            weighted = np.flatnonzero((r.arr["w"] > 0) & (r.arr["y"] != S["ACTIVE_RALLY"]))
            self.assertTrue(all(tn.inside(int(k), spans) for k in r.arr["tick"][weighted]), r.rid)
        declared_dir = os.path.join(self.tmp, "declared")
        os.makedirs(declared_dir)
        declared = v.load_manifest(syn.write(declared_dir, trust="declared"))
        self.assertLess(gate["trustedNegativeSteps"], sum(r["labelCounts"]["NON_RALLY"] for r in declared["recordings"]))   # fewer than were declared
        report = syn.read_json(os.path.join(self.out, "report.json"))
        self.assertEqual((report["negativeCoverage"]["met"], report["identity"]["schemas"]["labels"]), (True, tn.AUDITED_LABELS))
        self.assertIn("negatives **audited**", syn.read_text(os.path.join(self.out, "report.md")))
        self.assertIn("**G6: met** — 12 of 15 groups", syn.read_text(os.path.join(self.out, "report.md")))

    def test_under_v2_only_verified_coverage_is_fully_marked(self):
        dataset, _, _ = make(self.tmp, trust="audited", unaudited=("g-bea-00",))
        recs = {r["recordingId"]: r for r in v.load_manifest(dataset)["recordings"]}
        self.assertFalse(evaluate.fully_marked(recs[syn.NOT_CLEAN]), "an interval not reviewed clean: its time is not scored as dead time")
        self.assertFalse(evaluate.fully_marked(recs["syn_bea_00"]), "declared and never audited")
        self.assertTrue(evaluate.fully_marked(recs["syn_ind_02"]), "every unmarked tick reviewed clean")
        self.assertTrue(evaluate.fully_marked(recs["syn_gra_00"]), "Stage 1 verified coverage")
        self.assertFalse(evaluate.fully_marked(recs["syn_bea_01"]), "edited footage")
        declared_dir = os.path.join(self.tmp, "declared")
        os.makedirs(declared_dir)
        declared = {r["recordingId"]: r for r in v.load_manifest(syn.write(declared_dir, trust="declared"))["recordings"]}
        self.assertTrue(evaluate.fully_marked(declared[syn.NOT_CLEAN]), "v1: the declaration is what v1 scores by")

    def test_too_few_audited_groups_is_refused_with_the_exact_deficiency(self):
        unaudited = ("g-bea-00", "g-bea-02", "g-bea-03", "g-gra-01", "g-gra-02", "g-ind-00", "g-ind-01")
        dataset, closure, folds_file = make(self.tmp, trust="audited", unaudited=unaudited)
        gate = train.prepare(dataset, folds_file, closure, "present").negatives
        fold_of = {g["groupId"]: g["fold"] for g in syn.read_json(folds_file)["groups"]}
        without = sorted(unaudited + ("g-bea-01",))                                    # and the edited recording's group
        self.assertEqual((gate["g7"]["met"], gate["g6"]["met"], gate["groupsWithTrustedNegatives"]), (True, False, 15 - len(without)))
        self.assertEqual(gate["g6"]["deficiencies"][0], f"7 of 15 groups contribute trusted negatives; at least 10 are required (two-thirds, rounded up): "
                                                        f"3 short. Groups without: {', '.join(without)}")
        thin = {f: sorted(g for g in without if fold_of[g] == f) for f in range(5)}
        expected = [f for f in range(5) if 3 - len(thin[f]) < 2]
        self.assertTrue(expected)
        self.assertEqual([d.split(":")[0] for d in gate["g6"]["deficiencies"][1:]], [f"fold {f}" for f in expected])
        for f, d in zip(expected, gate["g6"]["deficiencies"][1:]):
            self.assertIn(f"at least 2 are required: {2 - (3 - len(thin[f]))} short. Groups without: {', '.join(thin[f])}", d)
        args = argv(dataset, closure, folds_file, self.out)
        self.refused(args, "the negative-coverage gate is not met (label schema rally_activity_truth_v2, negatives audited)", f"G6: {gate['g6']['deficiencies'][0]}")
        code, out, err = quiet(train.main, args + ["--dry-run"])
        self.assertEqual(code, 0, err)
        self.assertIn("negatives audited: G7 met, G6 NOT MET (7 of 15 groups with trusted negatives, 10 required) — a real run would be refused", out)
        problems = syn.read_json(os.path.join(self.out, "readiness.json"))["problems"]
        self.assertEqual(problems[-len(gate["deficiencies"]):], gate["deficiencies"], "every deficiency of the gate is reported")
        self.assertTrue(all("no fully marked" in p for p in problems[:-len(gate["deficiencies"])]), problems)    # under v2 only verified coverage is

    def tamper(self, dataset):
        """Drop one reviewed-clean interval from the manifest and leave the labels as they were."""
        manifest = v.load_manifest(dataset)
        rec = next(r for r in manifest["recordings"] if r["recordingId"] == "syn_ind_02")
        dropped = rec["coverage"]["audit"]["cleanIntervals"].pop(0)
        syn.save_manifest(dataset, manifest)
        return dropped

    def test_an_untrusted_negative_in_an_audited_dataset_stops_the_run_and_the_dry_run(self):
        dataset, _, _ = make(self.tmp, trust="audited")
        dropped = self.tamper(dataset)
        closure, folds_file = syn.write_closure(self.tmp, dataset), os.path.join(self.tmp, "folds-2.json")   # the dataset changed: new folds
        code, _, err = quiet(folds.main, [dataset, "--out", folds_file, "--withheld", closure])
        self.assertEqual(code, 1)                                                      # the validator knows the rule and refuses it first
        self.assertIn("y is NON_RALLY outside trusted time", err)
        with mock.patch.object(v, "validate", lambda dataset_dir, withheld_path=None: v.Report()):    # one that lets it through: the trainer's own check
            code, _, err = quiet(folds.main, [dataset, "--out", folds_file, "--withheld", closure])
            self.assertEqual(code, 0, err)
            for extra in ((), ("--dry-run",)):
                self.refused(argv(dataset, closure, folds_file, self.out, "r1", "present", *extra),
                             "negative step(s) with loss weight in 1 recording(s) lie outside every reviewed-clean interval of a recording without Stage 1 verified coverage",
                             f"syn_ind_02 (", f"first NON_RALLY at tick {dropped['startTick']}", "rally_activity_truth_v2 allows none")

    def test_a_label_schema_the_trainer_does_not_know_is_refused(self):
        dataset, closure, folds_file = make(self.tmp)
        manifest = v.load_manifest(dataset)
        manifest["labelSchema"]["version"] = "rally_activity_truth_v3"
        syn.save_manifest(dataset, manifest)
        with mock.patch.object(v, "validate", lambda dataset_dir, withheld_path=None: v.Report()):    # even where a validator passes it
            self.refused(argv(dataset, closure, folds_file, self.out), "the dataset's label schema is 'rally_activity_truth_v3'; this trainer reads "
                                                                       "rally_activity_truth_v1 and rally_activity_truth_v2")


class MatchedBaselineGuards(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rc-matched-")
        self.dataset, self.closure, self.folds_file = make(self.tmp, matched_baseline=True)
        self.out = os.path.join(self.tmp, "run")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def refused(self, fragment):
        """The validator refuses a matched baseline that is not r0 with only the above-net rule off, before the folds
        file is even read; so does the trainer, which validates first, and the fold draw."""
        code, _, err = quiet(train.main, argv(self.dataset, self.closure, self.folds_file, self.out, "r1", "present", "--dry-run"))
        self.assertEqual(code, 1, err)
        self.assertIn("the dataset does not validate", err)
        self.assertIn(fragment, err)
        self.assertFalse(os.path.exists(self.out))
        code, _, err = quiet(folds.main, [self.dataset, "--out", os.path.join(self.tmp, "folds-2.json"), "--withheld", self.closure])
        self.assertEqual(code, 1)
        self.assertIn(fragment, err)

    def edit_manifest(self, change):
        manifest = v.load_manifest(self.dataset)
        change(manifest, next(var for var in manifest["baseline"]["variants"] if var["name"] == syn.MATCHED))
        syn.save_manifest(self.dataset, manifest)

    def test_the_synthetic_matched_baseline_is_accepted(self):
        prep = train.prepare(self.dataset, self.folds_file, self.closure, "present")
        self.assertEqual(set(prep.parity), {"r0", "r0_prime", "r0_no_net_rule"})
        self.assertEqual(train.MATCHED, syn.MATCHED)

    def test_a_matched_baseline_at_other_settings_is_refused(self):
        self.edit_manifest(lambda manifest, variant: variant["settings"].update(joinSec=0.0))
        self.refused("baseline variant r0_no_net_rule must carry r0's settings")

    def test_a_matched_baseline_under_r0s_config_hash_is_refused(self):
        self.edit_manifest(lambda manifest, variant: variant.update(configSha256=manifest["pipelineConfigSha256"]))
        self.refused("baseline variant r0_no_net_rule carries r0's config hash")

    def test_a_matched_baseline_that_lacks_an_r0_clip_is_refused(self):
        def drop(manifest, variant):
            rec = manifest["recordings"][0]
            path = os.path.join(self.dataset, rec["baselineFile"])
            doc = syn.read_json(path)
            kept = doc["variants"]["r0"][0]
            doc["variants"][syn.MATCHED] = [c for c in doc["variants"][syn.MATCHED] if c["startTick"] != kept["startTick"]]
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(doc, fh, indent=1)
            rec["baselineSha256"] = v.sha256_file(path)
        self.edit_manifest(drop)
        self.refused("not in r0_no_net_rule unchanged")


if __name__ == "__main__":
    unittest.main()
