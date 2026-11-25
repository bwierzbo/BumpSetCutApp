"""Tests for scripts/rally_classifier/validate_dataset.py under the label schema
rally_activity_truth_v2 (gate G7 of the preregistration; the negative-coverage audit
protocol §9): NON_RALLY only inside an interval a person reviewed clean, or under
Stage 1 verified coverage; the audit block, the evidence block, the matched baseline
`r0_no_net_rule`, and the checks against the project and the evidence source.
Standard library only.

    python3 -m unittest scripts.tests.test_validate_rally_classifier_dataset_v2 -v
"""

import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rally_classifier"))
import validate_dataset as v  # noqa: E402


class V2Dataset(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rc-dataset-v2-")
        self.dataset = os.path.join(self.tmp, "Synthetic-v2")
        v.write_synthetic(self.dataset, seed=1, label_version=v.LABEL_VERSION_V2)
        self.mpath = os.path.join(self.dataset, "dataset-manifest.json")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def manifest(self):
        with open(self.mpath) as fh:
            return json.load(fh)

    def save(self, m):
        with open(self.mpath, "w") as fh:
            json.dump(m, fh)

    def audited(self, m):
        return next(r for r in m["recordings"] if r["coverage"]["audit"]["cleanIntervals"])

    def steps(self, rec):
        with open(os.path.join(self.dataset, rec["stepsFile"])) as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def write_steps(self, rec, steps):
        path = os.path.join(self.dataset, rec["stepsFile"])
        with open(path, "w") as fh:
            for s in steps:
                fh.write(json.dumps(s) + "\n")
        rec["stepsSha256"] = v.sha256_file(path)
        counts = {name: 0 for name in v.STATES}
        for s in steps:
            counts[v.STATE_NAMES[s["y"]]] += 1
        rec["labelCounts"] = counts

    def errors(self, **kw):
        return v.validate(self.dataset, **kw).errors

    def assertRefused(self, fragment, **kw):
        errs = self.errors(**kw)
        self.assertTrue(any(fragment in e for e in errs), f"expected an error containing {fragment!r}, got {errs}")

    # the example ---------------------------------------------------------------------------
    def test_the_v2_example_is_valid_and_says_what_it_did_not_check(self):
        rep = v.validate(self.dataset)
        self.assertEqual(rep.errors, [])
        self.assertEqual(rep.info["labelVersion"], v.LABEL_VERSION_V2)
        self.assertIn(v.MATCHED_VARIANT, rep.info["baselineVariants"])
        self.assertTrue(any("NOT checked" in n for n in rep.notes), rep.notes)

    def test_a_v1_dataset_still_validates_and_its_negatives_are_declared(self):
        d = os.path.join(self.tmp, "Synthetic-v1")
        v.write_synthetic(d, seed=1)
        rep = v.validate(d)
        self.assertEqual(rep.errors, [])
        self.assertEqual(rep.info["negatives"], "declared, not audited")

    # the label rule --------------------------------------------------------------------------
    def test_non_rally_outside_every_clean_interval_is_refused(self):
        m = self.manifest()
        rec = self.audited(m)
        first = rec["coverage"]["audit"]["cleanIntervals"][0]
        rec["coverage"]["audit"]["cleanIntervals"] = rec["coverage"]["audit"]["cleanIntervals"][1:]
        if not rec["coverage"]["audit"]["cleanIntervals"]:
            rec["labelProvenance"]["method"] = "legacy_declared"
        self.save(m)
        self.assertRefused("NON_RALLY outside trusted time")
        self.assertTrue(first["startTick"] < first["endTick"])

    def test_a_declaration_alone_gives_no_negative(self):
        m = self.manifest()
        rec = self.audited(m)
        rec["coverage"]["audit"] = {"state": "none", "auditSha256": None, "drawId": None, "cleanIntervals": [], "findings": {}}
        rec["labelProvenance"]["method"] = "legacy_declared"
        self.save(m)
        self.assertRefused("NON_RALLY outside trusted time")

    def test_unknown_inside_a_clean_interval_is_refused_too(self):
        m = self.manifest()
        rec = self.audited(m)
        c = rec["coverage"]["audit"]["cleanIntervals"][0]
        steps = self.steps(rec)
        for s in steps:
            if c["startTick"] <= s["tick"] < c["endTick"] and s["y"] == v.STATES["NON_RALLY"]:
                s["y"] = v.STATES["UNKNOWN"]
                break
        self.write_steps(rec, steps)
        self.save(m)
        self.assertTrue(self.errors(), "a label that is not the rule's is an error in either direction")

    # the audit block -------------------------------------------------------------------------
    def test_a_clean_interval_overlapping_a_mark_is_refused(self):
        m = self.manifest()
        rec = self.audited(m)
        r = rec["rallies"][0]
        rec["coverage"]["audit"]["cleanIntervals"].append({"startTick": r["startTick"], "endTick": r["endTick"]})
        rec["coverage"]["audit"]["cleanIntervals"].sort(key=lambda c: c["startTick"])
        self.save(m)
        self.assertRefused("trusted time is unmarked time")

    def test_a_clean_interval_outside_the_recording_is_refused(self):
        m = self.manifest()
        rec = self.audited(m)
        end = round(rec["durationSec"] * v.TIMESCALE)
        rec["coverage"]["audit"]["cleanIntervals"].append({"startTick": end, "endTick": end + 600})
        self.save(m)
        self.assertRefused("leaves the recording")

    def test_clean_intervals_out_of_order_are_refused(self):
        m = self.manifest()
        rec = self.audited(m)
        cl = rec["coverage"]["audit"]["cleanIntervals"]
        self.assertGreater(len(cl), 1)
        cl.reverse()
        self.save(m)
        self.assertRefused("in time order and apart")

    def test_edited_footage_supplies_no_negative_whatever_an_audit_says(self):
        m = self.manifest()
        rec = next(r for r in m["recordings"] if r["eligibility"]["fullVideoNegatives"] != "standard")
        rec["coverage"]["audit"]["cleanIntervals"] = [{"startTick": 0, "endTick": 60}]
        self.save(m)
        self.assertRefused("edited or restricted footage supplies no negative")

    def test_declared_audited_needs_a_clean_interval_and_legacy_declared_none(self):
        m = self.manifest()
        rec = self.audited(m)
        rec["labelProvenance"]["method"] = "legacy_declared"
        self.save(m)
        self.assertRefused("not declared_audited")

    def test_the_state_must_agree_with_the_findings(self):
        m = self.manifest()
        rec = self.audited(m)
        rec["coverage"]["audit"]["findings"] = {"missed_rally": 1}
        self.save(m)
        self.assertRefused("contaminated is exactly a record with one")
        rec["coverage"]["audit"]["state"] = "audited_clean"
        rec["coverage"]["audit"]["findings"] = {"uncertain": 1}
        self.save(m)
        self.assertRefused("that is partial")

    def test_the_audit_block_must_be_whole(self):
        m = self.manifest()
        rec = self.audited(m)
        del rec["coverage"]["audit"]["drawId"]
        self.save(m)
        self.assertRefused("coverage.audit must carry exactly")

    # the evidence block and reuse -------------------------------------------------------------
    def test_evidence_reused_from_without_its_proof_is_refused(self):
        m = self.manifest()
        rec = m["recordings"][0]
        rec["evidenceReusedFrom"] = {"dataset": "rc-v1-20261112"}
        self.save(m)
        self.assertRefused("evidenceReusedFrom without its proof fields")

    def test_evidence_of_a_withheld_file_is_refused(self):
        m = self.manifest()
        m["recordings"][0]["evidence"]["sourceFingerprint"] = m["withheld"]["fingerprints"][0]
        self.save(m)
        self.assertRefused("WITHHELD recording present", withheld_path=None)

    def test_reused_evidence_is_held_against_the_source_dataset(self):
        source = os.path.join(self.tmp, "Synthetic-source")
        shutil.copytree(self.dataset, source)
        src = v.dataset_identity(source)
        m = self.manifest()
        rec = m["recordings"][0]
        with open(os.path.join(source, "dataset-manifest.json")) as fh:
            srec = next(r for r in json.load(fh)["recordings"] if r["recordingId"] == rec["recordingId"])
        rec["evidenceReusedFrom"] = {
            "dataset": "Synthetic-source", "manifestSha256": src["manifestSha256"], "digest": src["digest"],
            "stepsSha256": srec["stepsSha256"], "baselineSha256": srec["baselineSha256"], "detector": m["detector"],
            "pipelineConfigSha256": m["pipelineConfigSha256"], "featureVersion": v.FEATURE_VERSION,
            "sourceFingerprint": rec["evidence"]["sourceFingerprint"], "durationSec": rec["durationSec"], "identityProof": "manifest"}
        self.save(m)
        self.assertEqual(self.errors(evidence_source=source), [])
        # a step whose feature columns are not the source's
        steps = self.steps(rec)
        key = next(k for k in steps[0] if k not in ("t", "tick", "y", "w", "seg"))
        steps[0][key] = 0.123456 if steps[0][key] != 0.123456 else 0.654321
        self.write_steps(rec, steps)
        self.save(m)
        self.assertRefused("does not hold the source's time and feature columns", evidence_source=source)

    # the matched baseline ---------------------------------------------------------------------
    def test_the_matched_baseline_holds_every_r0_clip(self):
        m = self.manifest()
        rec = m["recordings"][0]
        path = os.path.join(self.dataset, rec["baselineFile"])
        with open(path) as fh:
            b = json.load(fh)
        self.assertTrue(b["variants"]["r0"], "the example has r0 clips")
        b["variants"][v.MATCHED_VARIANT] = b["variants"][v.MATCHED_VARIANT][1:] if b["variants"][v.MATCHED_VARIANT][0] in b["variants"]["r0"] \
            else [c for c in b["variants"][v.MATCHED_VARIANT] if c != b["variants"]["r0"][0]]
        with open(path, "w") as fh:
            json.dump(b, fh)
        rec["baselineSha256"] = v.sha256_file(path)
        self.save(m)
        self.assertRefused(f"not in {v.MATCHED_VARIANT} unchanged")

    # against the project ----------------------------------------------------------------------
    def _project_with_records(self, mutate=None):
        project = os.path.join(self.tmp, "Project")
        os.makedirs(os.path.join(project, "sessions"))
        m = self.manifest()
        for rec in m["recordings"]:
            audit = rec["coverage"]["audit"]
            if audit["state"] == "none":
                continue
            video = os.path.join(self.tmp, "footage", rec["recordingId"] + ".mp4")
            os.makedirs(os.path.dirname(video), exist_ok=True)
            with open(os.path.join(project, "sessions", rec["recordingId"] + ".json"), "w") as fh:
                json.dump({"name": rec["recordingId"], "sourcePath": video}, fh)
            record = {"annotationVersion": v.AUDIT_VERSION, "recordingId": rec["recordingId"],
                      "sourceFingerprint": rec["evidence"]["sourceFingerprint"], "drawId": audit["drawId"], "drawSha256": "0" * 64,
                      "datasetName": "Synthetic-v2", "marksSha256": rec["labelProvenance"]["marksSha256"], "timescale": v.TIMESCALE,
                      "blindToPipeline": True, "tool": "test",
                      "intervals": [{"index": i, "startTick": c["startTick"], "endTick": c["endTick"], "verdict": "clean",
                                     "reviewer": "owner", "reviewedAt": "2026-11-15T08:00:00Z", "playedAllAtMaxRate": 2.0}
                                    for i, c in enumerate(audit["cleanIntervals"])]}
            if mutate:
                mutate(rec, record)
            data = json.dumps(record).encode()
            with open(os.path.splitext(video)[0] + ".coverageaudit.json", "wb") as fh:
                fh.write(data)
            audit["auditSha256"] = hashlib.sha256(data).hexdigest()
        self.save(m)
        return project

    def test_the_records_in_the_project_back_the_manifest(self):
        project = self._project_with_records()
        rep = v.validate(self.dataset, project_dir=project)
        self.assertEqual(rep.errors, [])
        self.assertEqual(rep.info["negatives"]["auditRecordsChecked"], 2)
        self.assertFalse(any("NOT checked" in n for n in rep.notes), rep.notes)

    def test_a_trusted_interval_its_record_does_not_say_clean_is_refused(self):
        def not_clean(rec, record):
            record["intervals"][0]["verdict"] = "not_clean"
            record["intervals"][0]["findings"] = [{"kind": "missed_serve"}]
            del record["intervals"][0]["playedAllAtMaxRate"]
        project = self._project_with_records(not_clean)
        self.assertRefused("is not inside an interval its audit record says clean", project_dir=project)

    def test_a_clean_played_faster_than_3x_counts_for_nothing(self):
        def fast(rec, record):
            record["intervals"][0]["playedAllAtMaxRate"] = 4.0
        project = self._project_with_records(fast)
        self.assertRefused("is not inside an interval its audit record says clean", project_dir=project)

    def test_an_unresolved_disagreement_counts_for_nothing_and_a_resolution_does(self):
        def disputed(rec, record):
            record["repeat"] = {"method": "second_reviewer", "intervals": [
                {"index": 0, "verdict": "not_clean", "reviewer": "second", "reviewedAt": "2026-11-16T08:00:00Z",
                 "findings": [{"kind": "missed_rally"}]}]}
        project = self._project_with_records(disputed)
        self.assertRefused("is not inside an interval its audit record says clean", project_dir=project)
        shutil.rmtree(project)

        def resolved(rec, record):
            disputed(rec, record)
            record["resolutions"] = [{"index": 0, "verdict": "clean", "findings": [], "reviewer": "owner",
                                      "resolvedAt": "2026-11-17T08:00:00Z", "playedAllAtMaxRate": 1.0, "note": "a ball rolled back"}]
        project = self._project_with_records(resolved)
        self.assertEqual(self.errors(project_dir=project), [])

    def test_a_record_that_changed_since_the_export_is_refused(self):
        project = self._project_with_records()
        m = self.manifest()
        rec = self.audited(m)
        rec["coverage"]["audit"]["auditSha256"] = "f" * 64
        self.save(m)
        self.assertRefused("does not hash to coverage.audit.auditSha256", project_dir=project)

    def test_a_record_of_another_file_is_refused(self):
        def other_file(rec, record):
            record["sourceFingerprint"] = "file:another"
        project = self._project_with_records(other_file)
        self.assertRefused("of another file", project_dir=project)

    def test_audit_clean_intervals_follows_the_protocol(self):
        record = {"intervals": [
            {"index": 0, "startTick": 0, "endTick": 600, "verdict": "clean", "playedAllAtMaxRate": 2.0, "findings": []},
            {"index": 1, "startTick": 900, "endTick": 1500, "verdict": "clean", "findings": []},
            {"index": 2, "startTick": 1800, "endTick": 2400, "verdict": "not_clean", "findings": [{"kind": "non_rally_activity"}]},
            {"index": 3, "startTick": 2700, "endTick": 3000, "verdict": "clean", "playedAllAtMaxRate": 0.5, "findings": []}]}
        self.assertEqual(v.audit_clean_intervals(record), [(0, 600), (2700, 3000)],
                         "a clean needs play coverage; non-rally activity is not a negative")


if __name__ == "__main__":
    unittest.main()
