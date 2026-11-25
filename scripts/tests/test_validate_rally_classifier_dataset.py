"""Tests for scripts/rally_classifier/validate_dataset.py on its own synthetic dataset:
the synthetic example validates clean, and every rule of the contract refuses the
mutation it exists for. Standard library only (no numpy, no torch).

    python3 -m unittest scripts.tests.test_validate_rally_classifier_dataset -v
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
import validate_dataset as v  # noqa: E402


class SyntheticDataset(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rc-dataset-")
        self.dataset = os.path.join(self.tmp, "Synthetic-rally-classifier")
        v.write_synthetic(self.dataset, seed=1)
        self.mpath = os.path.join(self.dataset, "dataset-manifest.json")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # helpers -------------------------------------------------------------------------------
    def manifest(self):
        with open(self.mpath) as fh:
            return json.load(fh)

    def save(self, m):
        with open(self.mpath, "w") as fh:
            json.dump(m, fh)

    def rewrite_steps(self, rec, mutate):
        """Apply `mutate(list of steps) -> list` to a recording's steps file and refresh its hash/counts."""
        path = os.path.join(self.dataset, rec["stepsFile"])
        with open(path) as fh:
            steps = [json.loads(line) for line in fh if line.strip()]
        steps = mutate(steps)
        with open(path, "w") as fh:
            for s in steps:
                fh.write(json.dumps(s) + "\n")
        rec["stepsSha256"] = v.sha256_file(path)
        rec["stepCount"] = len(steps)
        counts = {name: 0 for name in v.STATES}
        for s in steps:
            if s.get("y") in v.STATE_NAMES:
                counts[v.STATE_NAMES[s["y"]]] += 1
        rec["labelCounts"] = counts

    def errors(self, withheld=None):
        return v.validate(self.dataset, withheld).errors

    def assertRefused(self, fragment, withheld=None):
        errs = self.errors(withheld)
        self.assertTrue(any(fragment in e for e in errs), f"expected an error containing {fragment!r}, got {errs}")

    # the example itself ------------------------------------------------------------------
    def test_synthetic_example_is_valid(self):
        rep = v.validate(self.dataset)
        self.assertEqual(rep.errors, [])
        self.assertTrue(rep.ok)
        self.assertEqual(rep.info["recordings"], 4)
        self.assertEqual(rep.info["groups"], 3)
        self.assertEqual(rep.info["restricted"], ["syn_grs_b"])
        self.assertEqual(rep.info["baselineVariants"], ["r0", "r0_prime"])
        counts = rep.info["labelCounts"]
        for name in ("ACTIVE_RALLY", "NON_RALLY", "TRANSITION", "EXCLUDED", "UNKNOWN", "NON_RALLY_ACTIVITY"):
            self.assertGreater(counts[name], 0, name)

    def test_cli_exit_codes(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(v.main([self.dataset]), 0)
            self.assertEqual(v.main([self.dataset, "--json"]), 0)
            m = self.manifest()
            m["schemaVersion"] = "rally_classifier_dataset_v0"
            self.save(m)
            self.assertEqual(v.main([self.dataset]), 1)
        self.assertIn("OK: 0 error(s)", out.getvalue())
        self.assertIn("FAILED: 1 error(s)", out.getvalue())

    def test_write_synthetic_refuses_an_existing_folder(self):
        with self.assertRaises(FileExistsError):
            v.write_synthetic(self.dataset)

    # manifest and schemas ----------------------------------------------------------------
    def test_unknown_schema_version_is_refused_whole(self):
        m = self.manifest()
        m["schemaVersion"] = "rally_classifier_dataset_v2"
        self.save(m)
        errs = self.errors()
        self.assertEqual(len(errs), 1)
        self.assertIn("schemaVersion", errs[0])

    def test_feature_order_must_match_exactly(self):
        m = self.manifest()
        feats = m["featureSchema"]["features"]
        feats[0], feats[1] = feats[1], feats[0]
        self.save(m)
        self.assertRefused("featureSchema differs")

    def test_feature_nullability_must_match_exactly(self):
        m = self.manifest()
        m["featureSchema"]["features"][v.FEATURE_INDEX["has_ball"]]["nullable"] = True
        self.save(m)
        self.assertRefused("featureSchema differs")

    def test_label_weights_must_match_exactly(self):
        m = self.manifest()
        m["labelSchema"]["weights"]["3"] = 1.0   # UNKNOWN must never carry loss
        self.save(m)
        self.assertRefused("labelSchema differs")

    def test_boundary_ignore_must_be_positive(self):
        m = self.manifest()
        m["labelSchema"]["boundaryIgnoreSec"] = 0
        self.save(m)
        self.assertRefused("boundaryIgnoreSec")

    def test_missing_manifest_keys(self):
        m = self.manifest()
        del m["withheld"]
        self.save(m)
        self.assertRefused("missing keys")

    def test_split_manifest_hashes_required(self):
        m = self.manifest()
        m["splitManifest"]["sessions"] = "not-a-hash"
        self.save(m)
        self.assertRefused("splitManifest.sessions")

    # protected material ------------------------------------------------------------------
    def test_withheld_name_present_is_refused(self):
        m = self.manifest()
        m["withheld"]["names"].append("syn_bch_a")
        m["withheld"]["closureSha256"] = v.closure_sha256(m["withheld"]["names"], m["withheld"]["sourceIds"], m["withheld"]["fingerprints"])
        self.save(m)
        self.assertRefused("WITHHELD recording present (name")

    def test_withheld_source_id_and_fingerprint_are_refused(self):
        m = self.manifest()
        r = m["recordings"][2]
        m["withheld"]["sourceIds"].append(r["sourceId"])
        m["withheld"]["fingerprints"].append(m["recordings"][3]["fingerprint"])
        m["withheld"]["closureSha256"] = v.closure_sha256(m["withheld"]["names"], m["withheld"]["sourceIds"], m["withheld"]["fingerprints"])
        self.save(m)
        self.assertRefused("sourceId")
        self.assertRefused("fingerprint in the closure")

    def test_empty_closure_is_refused(self):
        m = self.manifest()
        m["withheld"] = {"names": [], "sourceIds": [], "fingerprints": [], "closureSha256": v.closure_sha256([], [], [])}
        self.save(m)
        self.assertRefused("withheld.names is empty")

    def test_closure_hash_must_match_lists(self):
        m = self.manifest()
        m["withheld"]["names"].append("withheld_syn_03")   # list changed, hash not
        self.save(m)
        self.assertRefused("closureSha256 does not match")

    def test_external_closure_larger_than_manifests_is_refused(self):
        ext = os.path.join(self.tmp, "closure.json")
        with open(ext, "w") as fh:
            json.dump({"names": ["withheld_syn_01", "withheld_syn_99"], "sourceIds": [], "fingerprints": []}, fh)
        self.assertRefused("external withheld closure has 1 names", withheld=ext)

    def test_external_closure_still_refuses_a_present_recording(self):
        ext = os.path.join(self.tmp, "closure.json")
        with open(ext, "w") as fh:
            json.dump({"names": [], "sourceIds": ["youtube:syn_ind_c"], "fingerprints": []}, fh)
        errs = self.errors(withheld=ext)
        self.assertTrue(any("syn_ind_c" in e and "WITHHELD" in e for e in errs), errs)

    def test_protected_split_names_are_refused(self):
        m = self.manifest()
        for split in ("lineage_holdout", "legacy_holdout", "final_test", "final_test_candidate"):
            mm = copy.deepcopy(m)
            mm["recordings"][0]["split"] = split
            self.save(mm)
            self.assertRefused("is not a development split")

    # eligibility -------------------------------------------------------------------------
    def test_ineligible_levels_are_refused(self):
        m = self.manifest()
        for level in ("not_assessed", "quarantined", "ineligible"):
            mm = copy.deepcopy(m)
            mm["recordings"][0]["eligibility"]["rallyClassifier"] = level
            self.save(mm)
            self.assertRefused("only ['restricted', 'standard'] may be in a dataset")

    def test_restricted_needs_reasons_and_flag(self):
        m = self.manifest()
        m["recordings"][2]["eligibility"]["reasons"] = []
        self.save(m)
        self.assertRefused("restricted eligibility needs at least one reason")
        m = self.manifest()
        m["recordings"][2]["restrictedUse"] = False
        self.save(m)
        self.assertRefused("restrictedUse must be true")

    def test_unknown_type_cannot_have_standard_negatives(self):
        m = self.manifest()
        m["recordings"][0]["recordingType"] = "unknown"
        self.save(m)
        self.assertRefused("unknown recording type cannot have standard full-video negatives")

    def test_edited_type_cannot_have_standard_negatives(self):
        # Codex round 2 on PR #136: TrainingEligibility makes an edited recording's full-video negatives
        # restricted; a manifest that says otherwise is an inconsistent exporter verdict and must be refused
        # even though every step label is self-consistent.
        m = self.manifest()
        self.assertEqual(m["recordings"][0]["recordingType"], "continuous")
        self.assertEqual(m["recordings"][0]["eligibility"]["fullVideoNegatives"], "standard")
        self.assertGreater(m["recordings"][0]["labelCounts"]["NON_RALLY"], 0)
        m["recordings"][0]["recordingType"] = "edited"
        self.save(m)
        self.assertRefused("an edited recording type cannot have standard full-video negatives")

    def test_negatives_not_standard_makes_non_rally_time_unknown(self):
        # Flip the first recording's negatives verdict: every NON_RALLY step must now be UNKNOWN,
        # so the stored labels are refused until the exporter re-labels them.
        m = self.manifest()
        m["recordings"][0]["eligibility"]["fullVideoNegatives"] = "not_assessed"
        self.save(m)
        self.assertRefused("y is NON_RALLY but the recording's rallies and spans say UNKNOWN")

    # rallies and spans -------------------------------------------------------------------
    def test_overlapping_rallies_are_refused(self):
        m = self.manifest()
        r = m["recordings"][0]
        r["rallies"][0]["endTick"] = r["rallies"][1]["startTick"] + 60
        self.save(m)
        self.assertRefused("rallies overlap")

    def test_rally_inside_a_cut_is_an_error(self):
        m = self.manifest()
        r = m["recordings"][1]
        r["cutRanges"].append({"startTick": r["rallies"][0]["startTick"] + 60, "endTick": r["rallies"][0]["startTick"] + 120})
        self.save(m)
        self.assertRefused("a rally mark inside non-footage")

    def test_excluded_span_kinds(self):
        m = self.manifest()
        m["recordings"][0]["excludedSpans"][0]["kind"] = "rally"
        self.save(m)
        self.assertRefused("excludedSpans[0]: kind 'rally'")

    def test_time_breaking_trait_vocabulary(self):
        m = self.manifest()
        m["recordings"][1]["timeBreakingSpans"][0]["trait"] = "handheld"
        self.save(m)
        self.assertRefused("timeBreakingSpans[0]: trait")

    def test_rally_provenance_vocabulary(self):
        m = self.manifest()
        m["recordings"][0]["rallies"][0]["provenance"] = "machine_proposed"
        self.save(m)
        self.assertRefused("provenance 'machine_proposed'")

    def test_moving_a_rally_without_relabeling_steps_is_refused(self):
        m = self.manifest()
        r = m["recordings"][0]
        r["rallies"][0]["startTick"] -= 600
        r["rallies"][0]["endTick"] -= 600
        self.save(m)
        self.assertRefused("the recording's rallies and spans say")

    # steps ---------------------------------------------------------------------------------
    def test_steps_hash_and_count_are_checked(self):
        m = self.manifest()
        r = m["recordings"][3]
        path = os.path.join(self.dataset, r["stepsFile"])
        with open(path, "a") as fh:
            fh.write("\n")   # a trailing blank line changes the hash and is itself an error
        self.save(m)
        self.assertRefused("stepsSha256")
        self.assertRefused("empty line")

    def test_time_must_increase_and_tick_must_match(self):
        m = self.manifest()
        r = m["recordings"][0]

        def swap(steps):
            steps[10]["t"], steps[11]["t"] = steps[11]["t"], steps[10]["t"]
            return steps
        self.rewrite_steps(r, swap)
        self.save(m)
        self.assertRefused("is not after the previous step")
        m = self.manifest()
        r = m["recordings"][0]

        def bad_tick(steps):
            steps[5]["tick"] += 1
            return steps
        self.rewrite_steps(r, bad_tick)
        self.save(m)
        self.assertRefused("!= round(t × 600)")

    def test_dt_must_match_the_time_difference(self):
        m = self.manifest()
        r = m["recordings"][0]

        def bad_dt(steps):
            steps[7]["f"][v.FEATURE_INDEX["dt"]] = 0.5
            return steps
        self.rewrite_steps(r, bad_dt)
        self.save(m)
        self.assertRefused("dt 0.5 != t − previous t")

    def test_null_only_where_nullable(self):
        m = self.manifest()
        r = m["recordings"][0]

        def null_has_ball(steps):
            steps[3]["f"][v.FEATURE_INDEX["has_ball"]] = None
            return steps
        self.rewrite_steps(r, null_has_ball)
        self.save(m)
        self.assertRefused("has_ball is null but not nullable")

    def test_feature_ranges(self):
        m = self.manifest()
        r = m["recordings"][0]

        def out_of_range(steps):
            steps[3]["f"][v.FEATURE_INDEX["max_conf"]] = 1.5
            steps[4]["f"][v.FEATURE_INDEX["is_projectile"]] = 2
            steps[5]["f"][v.FEATURE_INDEX["n_cands_proj"]] = 9
            steps[6]["f"][v.FEATURE_INDEX["n_dets"]] = -1
            return steps
        self.rewrite_steps(r, out_of_range)
        self.save(m)
        self.assertRefused("max_conf must lie in [0, 1]")
        self.assertRefused("is_projectile must be 0 or 1")
        self.assertRefused("n_cands_proj 9 > n_cands")
        self.assertRefused("n_dets must be a non-negative integer")

    def test_non_finite_values_are_refused(self):
        m = self.manifest()
        r = m["recordings"][0]
        path = os.path.join(self.dataset, r["stepsFile"])
        with open(path) as fh:
            lines = fh.read().splitlines()
        lines[2] = lines[2].replace('"y":', '"f":[NaN,1,1,1,0.5,0.5,0,null,null,null,null,null,0,0,0,null,0,null],"y":', 1)
        # the line now has two "f" keys; json keeps the last, so the NaN list wins
        with open(path, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        r["stepsSha256"] = v.sha256_file(path)
        self.save(m)
        self.assertRefused("dt must be a finite number")

    def test_y_above_net_null_without_a_net_and_tied_to_sel_y(self):
        m = self.manifest()
        r = m["recordings"][3]   # no net

        def set_ban(steps):
            steps[3]["f"][v.FEATURE_INDEX["y_above_net"]] = 0.1
            return steps
        self.rewrite_steps(r, set_ban)
        self.save(m)
        self.assertRefused("y_above_net must be null when the recording has no net")
        m = self.manifest()
        r = m["recordings"][0]   # with a net

        def untie(steps):
            s = next(s for s in steps if s["f"][v.FEATURE_INDEX["sel_y"]] is not None)
            s["f"][v.FEATURE_INDEX["y_above_net"]] = None
            return steps
        self.rewrite_steps(r, untie)
        self.save(m)
        self.assertRefused("y_above_net must be null exactly when sel_y is null")

    def test_segment_breaks_at_gaps_and_non_footage_boundaries(self):
        m = self.manifest()
        r = m["recordings"][0]   # has a 1 s gap at t = 15

        def flatten(steps):
            for s in steps:
                s["seg"] = 0
            return steps
        self.rewrite_steps(r, flatten)
        self.save(m)
        self.assertRefused("seg must increment to 1 at a gap")
        m = self.manifest()
        r = m["recordings"][1]   # has a cut at the start and a replay span

        def flatten2(steps):
            for s in steps:
                s["seg"] = 0
            return steps
        self.rewrite_steps(r, flatten2)
        self.save(m)
        self.assertRefused("at a cut/time-breaking boundary")
        m = self.manifest()
        r = m["recordings"][0]

        def spurious(steps):
            for s in steps[100:]:
                s["seg"] += 1
            return steps
        self.rewrite_steps(r, spurious)
        self.save(m)
        self.assertRefused("seg changed to")

    def test_a_span_between_two_processed_frames_still_breaks_the_segment(self):
        # Codex finding on PR #136: a cut or replay that falls entirely between two processed frames has
        # both endpoints outside it; the segment must still break at its boundaries.
        m = self.manifest()
        r = m["recordings"][0]   # the synthetic example carries a cut at ticks 5–10 between ticks 0 and 20
        self.assertEqual(r["cutRanges"][0], {"startTick": 5, "endTick": 10})
        self.assertEqual(self.errors(), [])

        def flatten(steps):
            steps[1]["seg"] = 0       # the step at tick 20 must be seg 1
            for s in steps[2:]:
                s["seg"] -= 1
            return steps
        self.rewrite_steps(r, flatten)
        self.save(m)
        self.assertRefused("syn_bch_a line 2: seg must increment to 1 at a cut/time-breaking boundary")
        m = self.manifest()
        r = m["recordings"][3]    # no cuts: add a replay span between two frames within the 0.5 s gap rule
        r["timeBreakingSpans"].append({"startTick": 7, "endTick": 12, "trait": "replay", "origin": "proposed"})
        self.save(m)
        self.assertRefused("syn_ind_c line 2: seg must increment to 1 at a cut/time-breaking boundary")
        self.assertTrue(v.crosses_non_footage(0, 20, r))
        self.assertFalse(v.crosses_non_footage(12, 40, r))     # starting exactly at the span's end: outside, no break
        self.assertTrue(v.crosses_non_footage(0, 7, r))        # landing exactly on the start: inside, break

    def test_serve_features_are_causal_and_tied(self):
        m = self.manifest()
        r = m["recordings"][0]

        def untie(steps):
            steps[4]["f"][v.FEATURE_INDEX["serve_emitted"]] = 1
            steps[4]["f"][v.FEATURE_INDEX["serve_contact_offset"]] = None
            steps[5]["f"][v.FEATURE_INDEX["serve_contact_offset"]] = -0.5
            return steps
        self.rewrite_steps(r, untie)
        self.save(m)
        self.assertRefused("serve_contact_offset must be null exactly when serve_emitted is 0")
        self.assertRefused("serve_contact_offset must be non-negative")
        self.assertTrue(all(f["lookaheadSec"] == 0.0 and f["kind"] == "raw" for f in v.feature_schema()["features"]))

    def test_label_state_and_weight_consistency(self):
        m = self.manifest()
        r = m["recordings"][0]

        def flip(steps):
            s = next(s for s in steps if s["y"] == v.STATES["ACTIVE_RALLY"])
            s["y"] = v.STATES["NON_RALLY"]
            return steps
        self.rewrite_steps(r, flip)
        self.save(m)
        self.assertRefused("y is NON_RALLY but the recording's rallies and spans say ACTIVE_RALLY")
        m = self.manifest()
        r = m["recordings"][0]

        def bad_weight(steps):
            s = next(s for s in steps if s["y"] == v.STATES["TRANSITION"])
            s["w"] = 1.0
            return steps
        self.rewrite_steps(r, bad_weight)
        self.save(m)
        self.assertRefused("!= the weight of TRANSITION")

    def test_label_counts_must_match(self):
        m = self.manifest()
        m["recordings"][0]["labelCounts"]["ACTIVE_RALLY"] += 1
        self.save(m)
        self.assertRefused("labelCounts")

    def test_step_keys_are_exact(self):
        m = self.manifest()
        r = m["recordings"][0]

        def extra_key(steps):
            steps[0]["label"] = 1
            return steps
        self.rewrite_steps(r, extra_key)
        self.save(m)
        self.assertRefused("keys must be exactly")

    # groups and folder ---------------------------------------------------------------------
    def test_group_split_across_splits_or_folds_is_refused(self):
        m = self.manifest()
        m["recordings"][1]["split"] = "tune"
        self.save(m)
        self.assertRefused("group g-syn-a is split across")
        m = self.manifest()
        m["recordings"][1]["fold"] = 1
        self.save(m)
        self.assertRefused("group g-syn-a is in several folds")

    def test_shared_identity_across_groups_is_refused(self):
        m = self.manifest()
        m["recordings"][2]["sourceId"] = m["recordings"][0]["sourceId"]
        self.save(m)
        self.assertRefused("shares sourceId")

    def test_duplicate_recording_id(self):
        m = self.manifest()
        m["recordings"].append(copy.deepcopy(m["recordings"][0]))
        self.save(m)
        self.assertRefused("duplicate recordingId")

    def test_stray_file_is_refused(self):
        with open(os.path.join(self.dataset, "steps", "notes.txt"), "w") as fh:
            fh.write("x")
        self.assertRefused("stray file")

    def test_missing_steps_file(self):
        m = self.manifest()
        os.remove(os.path.join(self.dataset, m["recordings"][0]["stepsFile"]))
        self.assertRefused("steps file")

    # baseline outputs (contract §3a) ---------------------------------------------------------
    def baseline(self, rec):
        with open(os.path.join(self.dataset, rec["baselineFile"])) as fh:
            return json.load(fh)

    def save_baseline(self, rec, b):
        path = os.path.join(self.dataset, rec["baselineFile"])
        with open(path, "w") as fh:
            json.dump(b, fh)
        rec["baselineSha256"] = v.sha256_file(path)

    def test_baseline_block_is_required_and_r0_must_be_the_committed_config(self):
        orig = self.manifest()
        m = copy.deepcopy(orig)
        m["baseline"]["replayer"] = "RallyDecider"
        self.save(m)
        self.assertRefused("baseline must carry replayer 'EvidenceReplayer.decidedRallies'")
        m = copy.deepcopy(orig)
        m["baseline"]["variants"][0]["configSha256"] = m["baseline"]["variants"][1]["configSha256"]
        self.save(m)
        self.assertRefused("baseline variant r0 must be replayed at the dataset's pipelineConfigSha256")
        m = copy.deepcopy(orig)
        m["baseline"]["variants"][0]["name"] = "r0_retuned"
        self.save(m)
        self.assertRefused("baseline must include the variant r0")
        m = copy.deepcopy(orig)
        m["baseline"]["variants"][1]["settings"].pop("joinSec")
        self.save(m)
        self.assertRefused("settings must carry exactly")
        m = copy.deepcopy(orig)
        del m["baseline"]
        self.save(m)
        self.assertRefused("manifest missing keys ['baseline']")

    def test_baseline_file_hash_and_variants_are_checked(self):
        m = self.manifest()
        rec = m["recordings"][0]
        b = self.baseline(rec)
        b["variants"]["r0"][0]["rawSpans"][0]["endTick"] += 1          # edit without refreshing the hash
        with open(os.path.join(self.dataset, rec["baselineFile"]), "w") as fh:
            json.dump(b, fh)
        self.assertRefused("baselineSha256")
        m = self.manifest()
        rec = m["recordings"][0]
        b = self.baseline(rec)
        del b["variants"]["r0_prime"]
        self.save_baseline(rec, b)
        self.save(m)
        self.assertRefused("variants ['r0'] != the manifest's ['r0', 'r0_prime']")
        m = self.manifest()
        rec = m["recordings"][0]
        b = self.baseline(rec)
        b["recordingId"] = "someone_else"
        self.save_baseline(rec, b)
        self.save(m)
        self.assertRefused("recordingId 'someone_else' != 'syn_bch_a'")
        m = self.manifest()
        os.remove(os.path.join(self.dataset, m["recordings"][0]["baselineFile"]))
        self.assertRefused("baseline file 'baseline/syn_bch_a.json' missing")
        m = self.manifest()
        m["recordings"][0]["baselineFile"] = "steps/syn_bch_a.json"
        self.save(m)
        self.assertRefused("missing or outside baseline/")

    def test_baseline_rallies_must_be_well_formed(self):
        m = self.manifest()
        rec = m["recordings"][0]
        b = self.baseline(rec)
        r = b["variants"]["r0"][0]
        r["startTick"] = r["rawSpans"][0]["startTick"] + 1   # padded span no longer contains its raw span
        self.save_baseline(rec, b)
        self.save(m)
        self.assertRefused("must lie inside the padded span")
        m = self.manifest()
        rec = m["recordings"][0]
        b = self.baseline(rec)
        b["variants"]["r0"][1]["startTick"] = b["variants"]["r0"][0]["endTick"] - 1
        b["variants"]["r0"][1]["rawSpans"][0]["startTick"] = b["variants"]["r0"][1]["startTick"]
        self.save_baseline(rec, b)
        self.save(m)
        self.assertRefused("padded spans must be in time order and disjoint")
        m = self.manifest()
        rec = m["recordings"][0]
        b = self.baseline(rec)
        b["variants"]["r0"][0]["rawSpans"] = []
        self.save_baseline(rec, b)
        self.save(m)
        self.assertRefused("rawSpans must be a non-empty list")
        m = self.manifest()
        rec = m["recordings"][2]
        b = self.baseline(rec)
        clip = b["variants"]["r0"][0]
        clip["rawSpans"] = [{"startTick": clip["startTick"] + 10, "endTick": clip["endTick"] - 10},
                            {"startTick": clip["startTick"] + 5, "endTick": clip["startTick"] + 20}]
        self.save_baseline(rec, b)
        self.save(m)
        self.assertRefused("raw spans must be in time order (by start)")
        # Raw spans in start order may overlap: a serve dated into the previous rally's tail
        # (RallyDecider.noteServe) opens the next raw before the previous one closed.
        m = self.manifest()
        rec = m["recordings"][2]
        b = self.baseline(rec)
        clip = b["variants"]["r0"][0]
        clip["rawSpans"] = [{"startTick": clip["startTick"] + 5, "endTick": clip["startTick"] + 20},
                            {"startTick": clip["startTick"] + 10, "endTick": clip["endTick"] - 10}]
        self.save_baseline(rec, b)
        self.save(m)
        self.assertFalse([e for e in self.errors() if e.startswith(rec["recordingId"] + " ")], self.errors())
        m = self.manifest()
        rec = m["recordings"][0]
        b = self.baseline(rec)
        b["variants"]["r0"][0]["serveContactTick"] = b["variants"]["r0"][0]["endTick"] + 600
        self.save_baseline(rec, b)
        self.save(m)
        self.assertRefused("serveContactTick must be null or an integer tick inside the padded span")
        m = self.manifest()
        rec = m["recordings"][0]
        b = self.baseline(rec)
        b["variants"]["r0"][-1]["endTick"] = round(rec["durationSec"] * v.TIMESCALE) + 1
        self.save_baseline(rec, b)
        self.save(m)
        self.assertRefused("padded span outside the recording")
        m = self.manifest()
        rec = m["recordings"][0]
        b = self.baseline(rec)
        b["variants"]["r0"][0]["padded"] = True
        self.save_baseline(rec, b)
        self.save(m)
        self.assertRefused("keys must be exactly ['endTick', 'rawSpans', 'serveContactTick', 'startTick']")

    def test_baseline_fixture_holds_a_short_segment_merge_the_raw_union_cannot_rebuild(self):
        # Codex round 3 on PR #136: SegmentBuilder caps the pre-roll at 0.5 s for a raw rally under 2.5 s *before*
        # merging, so a merged clip's padded start follows its first short raw, not the raw union's length. The
        # fixture keeps the pre-merge raws so a padding port can be checked on exactly this case.
        m = self.manifest()
        rec = next(r for r in m["recordings"] if r["recordingId"] == "syn_ind_c")
        b = self.baseline(rec)
        merged = [c for c in b["variants"]["r0"] if len(c["rawSpans"]) == 2]
        self.assertEqual(len(merged), 1)
        clip = merged[0]
        first, second = clip["rawSpans"]
        self.assertEqual((first["startTick"], first["endTick"]), (24000, 24900))      # 40.0–41.5 s: shorter than 2.5 s
        self.assertEqual((second["startTick"], second["endTick"]), (26100, 27000))    # 43.5–45.0 s
        self.assertEqual(clip["startTick"], first["startTick"] - 300)               # 0.5 s capped pre-roll, not 2.0 s
        self.assertEqual(clip["endTick"], second["endTick"] + 300)                  # 0.5 s post-roll
        self.assertEqual(v.pad_and_merge([(24000, 24900), (26100, 27000)], v.SYNTHETIC_BASELINE_VARIANTS[0]["settings"], 36000),
                         [{"rawSpans": clip["rawSpans"], "startTick": clip["startTick"], "endTick": clip["endTick"]}])
        # the raw union alone would get the full 2 s pre-roll: a port fed only the union fails the parity check
        self.assertEqual(v.pad_and_merge([(24000, 27000)], v.SYNTHETIC_BASELINE_VARIANTS[0]["settings"], 36000)[0]["startTick"], 24000 - 1200)
        # Codex round 4: a short raw rally before a longer one pads to a later start than its successor
        # (0.5 s cap vs 2 s); the builder sorts by padded start before merging, so the clip starts at the
        # longer rally's padded start and the raw spans stay in time order.
        r0 = v.SYNTHETIC_BASELINE_VARIANTS[0]["settings"]
        self.assertEqual(v.pad_and_merge([(6000, 6720), (6840, 9000)], r0, 36000),
                         [{"rawSpans": [{"startTick": 6000, "endTick": 6720}, {"startTick": 6840, "endTick": 9000}],
                           "startTick": 5640, "endTick": 9300}])
        # Codex round 4: joinSec is compared in seconds, as finalizeWithRaw compares gapSec — 1.3513 s is not 811 ticks:
        # a padded gap of 811 ticks (1.35167 s) keeps two clips, 810 ticks (1.35 s) joins them.
        self.assertEqual([c["startTick"] for c in v.pad_and_merge([(6000, 7800), (10111, 12000)], r0, 36000)], [4800, 8911])
        self.assertEqual([c["startTick"] for c in v.pad_and_merge([(6000, 7800), (10110, 12000)], r0, 36000)], [4800])
        # and minSegmentSec likewise: a 2.6131 s minimum keeps a 1568-tick padded clip (2.6133 s) and drops 1567
        # (2.6117 s) — a short raw of 968 ticks pads by 300 + 300
        self.assertEqual(len(v.pad_and_merge([(1200, 2168)], r0, 36000)), 1)
        self.assertEqual(len(v.pad_and_merge([(1200, 2167)], r0, 36000)), 0)
        # r0_prime joins nothing (joinSec 0) and keeps the two short clips apart
        prime = [c for c in b["variants"]["r0_prime"] if c["rawSpans"][0]["startTick"] in (24000, 26100)]
        self.assertEqual([len(c["rawSpans"]) for c in prime], [1, 1])

    # the label rule itself -----------------------------------------------------------------
    def test_expected_state_precedence(self):
        rec = {
            "cutRanges": [{"startTick": 0, "endTick": 600}],
            "timeBreakingSpans": [{"startTick": 30000, "endTick": 31000}],
            "excludedSpans": [{"startTick": 12000, "endTick": 13000, "kind": "missedServe"}],
            "rallies": [{"startTick": 3000, "endTick": 6000, "contactUncertaintyTicks": None, "deadUncertaintyTicks": 900},
                        {"startTick": 29800, "endTick": 30500, "contactUncertaintyTicks": None, "deadUncertaintyTicks": None}],
            "nonRallyActivitySpans": [{"startTick": 8000, "endTick": 9000}],
            "eligibility": {"fullVideoNegatives": "standard"},
            "coverage": {"state": "declared_complete"},
        }
        S = v.STATES
        ig = 300
        self.assertEqual(v.expected_state(100, rec, ig), S["EXCLUDED"])           # inside the cut
        self.assertEqual(v.expected_state(2800, rec, ig), S["TRANSITION"])        # 200 ticks before contact
        self.assertEqual(v.expected_state(3299, rec, ig), S["TRANSITION"])        # inside the rally, within the band
        self.assertEqual(v.expected_state(3300, rec, ig), S["ACTIVE_RALLY"])
        self.assertEqual(v.expected_state(5200, rec, ig), S["TRANSITION"])        # dead uncertainty 900 > 300 widens the band
        self.assertEqual(v.expected_state(5099, rec, ig), S["ACTIVE_RALLY"])
        self.assertEqual(v.expected_state(8500, rec, ig), S["NON_RALLY_ACTIVITY"])
        self.assertEqual(v.expected_state(12500, rec, ig), S["EXCLUDED"])         # missed serve
        self.assertEqual(v.expected_state(11800, rec, ig), S["TRANSITION"])       # band at the excluded span's edge
        self.assertEqual(v.expected_state(20000, rec, ig), S["NON_RALLY"])
        self.assertEqual(v.expected_state(30200, rec, ig), S["EXCLUDED"])         # replay wins over the rally it overlaps
        rec["eligibility"]["fullVideoNegatives"] = "restricted"
        self.assertEqual(v.expected_state(20000, rec, ig), S["UNKNOWN"])
        rec["eligibility"]["fullVideoNegatives"] = "standard"
        rec["coverage"]["state"] = "partial"
        self.assertEqual(v.expected_state(20000, rec, ig), S["UNKNOWN"])


if __name__ == "__main__":
    unittest.main()
