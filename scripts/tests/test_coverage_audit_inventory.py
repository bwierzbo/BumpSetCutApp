"""Tests for scripts/rally_classifier/coverage_audit_inventory.py on a synthetic project: the spans and intervals
follow the exporter's rules, marks changed since the export are audited as they are now and listed, every dataset
recording is either eligible or left out with a reason, and the withheld closure is refused by every identity.
Standard library only; nothing real is read and no video exists.

    python3 -m unittest scripts.tests.test_coverage_audit_inventory -v
"""

import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rally_classifier"))
import coverage_audit_inventory as inv  # noqa: E402
import coverage_audit_synthetic as synthetic  # noqa: E402


def pairs(spans):
    return [(s["startTick"], s["endTick"]) for s in spans]


class Spans(unittest.TestCase):
    def marks(self, *rows):
        return [{"start": s, "end": e, "kind": kind, "contacts": contacts} for s, e, kind, contacts in rows]

    def test_kinds_contacts_and_ticks_follow_the_exporter(self):
        spans = inv.truth_spans(self.marks(
            (40.0, 50.0, "rally", [{"time": 41.5, "kind": "serve"}, {"time": 43.0, "kind": "pass"}]),   # starts at the serve contact
            (10.0, 20.0, None, []),                                                                    # no kind: a rally
            (60.0, 70.0, "rally", [{"time": 61.0, "kind": "pass"}]),                                   # first contact is no serve
            (80.0, 81.25, "missedServe", []), (90.0, 95.0, "other", [])), [])
        self.assertEqual(pairs(spans["rallies"]), [(6000, 12000), (24900, 30000), (36000, 42000)])
        self.assertEqual([(s["startTick"], s["endTick"], s["kind"]) for s in spans["excludedSpans"]], [(48000, 48750, "missedServe"), (54000, 57000, "other")])
        self.assertEqual(spans["cutRanges"], [])

    def test_cut_ranges_are_normalised_and_trim_excluded_marks(self):
        cuts = [(30.0, 35.0), (33.0, 40.0), (-2.0, 1.0), (50.0, 50.0), (60.0, 61.0)]
        spans = inv.truth_spans(self.marks((10.0, 20.0, "rally", []), (38.0, 45.0, "missedServe", []), (59.95, 61.5, "other", [])), cuts)
        self.assertEqual(pairs(spans["cutRanges"]), [(18000, 24000), (36000, 36600)])       # merged; negative and empty ones dropped
        # the missed serve keeps what lies outside the cut; of the other mark the 0.05 s before the cut is a sliver, dropped
        self.assertEqual([(s["startTick"], s["endTick"], s["kind"]) for s in spans["excludedSpans"]], [(24000, 27000, "missedServe"), (36600, 36900, "other")])

    def test_a_rally_inside_a_cut_and_overlapping_rallies_are_refused(self):
        with self.assertRaises(inv.AuditError) as cm:
            inv.truth_spans(self.marks((10.0, 20.0, "rally", [])), [(19.0, 25.0)])
        self.assertIn("overlaps a cut range", str(cm.exception))
        with self.assertRaises(inv.AuditError) as cm:
            inv.truth_spans(self.marks((10.0, 20.0, "rally", []), (19.0, 25.0, None, [])), [])
        self.assertIn("overlap", str(cm.exception))

    def test_unmarked_intervals_edges_gaps_merging_and_clamping(self):
        self.assertEqual([(iv["index"], iv["startTick"], iv["endTick"]) for iv in inv.unmarked_intervals([(600, 1200), (2400, 3300)], 6000)],
                         [(0, 0, 600), (1, 1200, 2400), (2, 3300, 6000)])
        # overlapping and touching spans merge; an empty or reversed one is ignored; spans are clamped to the recording
        self.assertEqual(pairs(inv.unmarked_intervals([(600, 1200), (1080, 1500), (1500, 1800), (3000, 2700), (-300, 180), (5700, 7800)], 6000)),
                         [(180, 600), (1800, 5700)])
        self.assertEqual(pairs(inv.unmarked_intervals([], 1800)), [(0, 1800)])
        self.assertEqual(inv.unmarked_intervals([(0, 1800)], 1800), [])

    def test_sub_second_and_edge_intervals_are_listed_like_any_other(self):
        # A sub-second interval can hold a missed serve and an edge interval a clipped rally: none is exempt.
        ivs = inv.unmarked_intervals([(240, 12000), (12001, 18000), (18600, 23820)], 24000)
        self.assertEqual(pairs(ivs), [(0, 240), (12000, 12001), (18000, 18600), (23820, 24000)])


class Inventory(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cov-inventory-")
        self.syn = synthetic.Synthetic(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def left_out(self, doc):
        return {e["recordingId"]: e["reason"] for e in doc["leftOut"]}

    def test_every_dataset_recording_is_eligible_or_left_out_with_a_reason(self):
        doc = self.syn.build()
        self.assertEqual(doc["schemaVersion"], inv.INVENTORY_VERSION)
        self.assertEqual(len(doc["recordings"]) + len(doc["leftOut"]), len(self.syn.specs))
        self.assertEqual(self.left_out(doc).keys(), {"bch_a_edit", "grs_edit"})
        self.assertTrue(all("edited recording" in why for why in self.left_out(doc).values()))
        t = doc["totals"]
        self.assertEqual((t["recordings"], t["groups"]), (22, 18))
        self.assertEqual({s: (row["recordings"], row["groups"]) for s, row in t["bySurface"].items()},
                         {"beach": (5, 4), "grass": (7, 6), "indoor": (10, 8)})
        self.assertEqual(t["intervals"], 22 * synthetic.INTERVALS)
        self.assertEqual(t["rallyMarks"], 22 * synthetic.RALLIES)
        self.assertEqual(t["missedServeMarks"], 22)
        self.assertEqual((t["marksChangedSinceExport"], t["spansChangedSinceExport"]), ([], []))
        self.assertEqual(doc["dataset"], {**inv.v.dataset_identity(self.syn.dataset), "timescale": 600, "labelSchema": "rally_activity_truth_v1",
                                          "boundaryIgnoreSec": 0.5, "recordings": 24, "groups": 19, "surfaces": ["beach", "grass", "indoor"]})
        self.assertEqual(doc["dataset"]["name"], "rc-synthetic")
        self.assertEqual(doc["folds"], {"file": "folds.json", "sha256": inv.v.sha256_file(self.syn.folds_path), "folds": 5})
        self.assertEqual(doc["splitManifest"]["changedSinceExport"], [])
        self.assertEqual(doc["withheld"]["closureFileCounts"], {"names": 1, "sourceIds": 1, "fingerprints": 2})
        self.assertEqual(doc["withheld"]["namesNotInClosureFile"], [])
        rec = doc["recordings"][0]
        self.assertEqual(set(rec), inv.RECORDING_KEYS)
        self.assertEqual((rec["recordingId"], rec["fold"], rec["durationTicks"], rec["contentFingerprint"]),
                         ("bch_a", self.syn.fold["bch_a"], 66000, "file:content-bch_a"))
        self.assertEqual({r["recordingId"]: r["fold"] for r in doc["recordings"]}, {rid: f for rid, f in self.syn.fold.items() if "edit" not in rid})
        self.assertEqual(pairs(rec["intervals"])[:3] + pairs(rec["intervals"])[-2:], [(0, 3000), (5400, 7800), (10200, 12600), (58200, 60000), (61200, 66000)])
        self.assertEqual(rec["unmarkedTicks"], 3000 + 11 * 2400 + 1800 + 4800)

    def test_no_video_is_needed(self):
        self.syn.build()
        self.assertFalse(os.path.exists(self.syn.video("bch_a")), "the inventory reads metadata only: the session's video does not even exist")

    def test_marks_changed_since_the_export_are_audited_as_they_are_now_and_listed(self):
        new = synthetic.marks()[:-2]                                    # the last rally and the missed serve are gone
        synthetic.write_json(self.syn.marks_path("grs_b"), new)
        doc = self.syn.build()
        rec = next(r for r in doc["recordings"] if r["recordingId"] == "grs_b")
        self.assertTrue(rec["marksChangedSinceExport"] and rec["spansChangedSinceExport"])
        self.assertNotEqual(rec["marksSha256"], rec["datasetMarksSha256"])
        self.assertEqual(rec["marksSha256"], inv.v.sha256_file(self.syn.marks_path("grs_b")))
        self.assertEqual((rec["rallyMarks"], rec["missedServeMarks"], len(rec["intervals"])), (11, 0, 12))
        self.assertEqual(pairs(rec["intervals"])[-1], (53400, 66000))
        self.assertEqual(doc["totals"]["marksChangedSinceExport"], ["grs_b"])
        self.assertEqual(doc["totals"]["spansChangedSinceExport"], ["grs_b"])

    def test_a_cut_range_added_since_the_export_changes_the_spans_not_the_marks(self):
        self.syn.sessions["ind_b"]["cuts"] = [{"start": 0.0, "end": 3.0}]
        self.syn.save()
        rec = next(r for r in self.syn.build()["recordings"] if r["recordingId"] == "ind_b")
        self.assertEqual((rec["marksChangedSinceExport"], rec["spansChangedSinceExport"]), (False, True))
        self.assertEqual(pairs(rec["cutRanges"]), [(0, 1800)])
        self.assertEqual(pairs(rec["intervals"])[0], (1800, 3000))

    def test_a_withheld_recording_is_left_out_by_every_identity(self):
        cases = {
            "name": lambda s: s.validation["lineageHoldout"].append("bch_b"),
            "sourceId": lambda s: s.closure["sourceIds"].append("src:bch_b"),
            "fingerprint": lambda s: s.closure["fingerprints"].append("file:card-bch_b"),
            "contentFingerprint": lambda s: s.closure["fingerprints"].append("file:content-bch_b"),
        }
        for identity, mutate in cases.items():
            with self.subTest(identity=identity):
                tmp = tempfile.mkdtemp(prefix="cov-withheld-", dir=self.tmp)
                syn = synthetic.Synthetic(tmp)
                mutate(syn)
                syn.save()
                doc = syn.build()
                self.assertNotIn("bch_b", [r["recordingId"] for r in doc["recordings"]])
                self.assertIn(f"WITHHELD: its {identity}", self.left_out(doc)["bch_b"])
                if identity == "name":
                    self.assertEqual(doc["withheld"]["namesNotInClosureFile"], ["bch_b"])
                    self.assertIn("file:content-bch_b", doc["withheld"]["fingerprints"])

    def test_a_recording_that_shares_an_identity_with_a_withheld_one_is_withheld_now(self):
        # The project's closure as it is now: an alias group or a confirmed sourceId shared with a withheld recording
        # withholds the recording by name, whatever the closure file of the export listed.
        self.syn.rows["ind_c"]["sourceId"] = {"origin": "confirmed", "value": "src:withheld_01"}
        self.syn.rows["ind_d"]["aliasGroup"] = "withheld_01"
        self.syn.save()
        doc = self.syn.build()
        self.assertIn("WITHHELD: its name", self.left_out(doc)["ind_c"])
        self.assertIn("WITHHELD: its name", self.left_out(doc)["ind_d"])
        self.assertEqual(doc["withheld"]["namesNotInClosureFile"], ["ind_c", "ind_d"])
        self.assertEqual(doc["withheld"]["aliasGroups"], ["ind_c", "withheld_01"])

    def test_closure_refusals(self):
        def empty(s):
            s.closure = {"names": [], "sourceIds": [], "fingerprints": []}

        def not_the_datasets(s):
            synthetic.write_json(s.closure_path, {"names": ["other"], "sourceIds": [], "fingerprints": [],
                                                  "closureSha256": inv.v.closure_sha256(["other"], [], [])})

        def wrong_hash(s):
            doc = inv.load_json(s.closure_path, "closure")
            synthetic.write_json(s.closure_path, {**doc, "names": doc["names"] + ["added_by_hand"]})

        for mutate, save, fragment in ((empty, True, "the withheld closure is empty"), (not_the_datasets, False, "not the closure the dataset was exported against"),
                                       (wrong_hash, False, "closureSha256 does not match")):
            with self.subTest(fragment=fragment):
                tmp = tempfile.mkdtemp(prefix="cov-closure-", dir=self.tmp)
                syn = synthetic.Synthetic(tmp)
                mutate(syn)
                if save:
                    syn.save()
                with self.assertRaises(inv.AuditError) as cm:
                    syn.build()
                self.assertIn(fragment, str(cm.exception))

    def test_folds_for_another_dataset_or_edited_and_a_stale_split_manifest_are_refused(self):
        folds = inv.load_json(self.syn.folds_path, "folds")
        synthetic.write_json(self.syn.folds_path, {**folds, "dataset": {**folds["dataset"], "manifestSha256": "0" * 64}})
        with self.assertRaises(inv.AuditError) as cm:
            self.syn.build()
        self.assertIn("drawn for another dataset", str(cm.exception))
        synthetic.write_json(self.syn.folds_path, {**folds, "recordings": {**folds["recordings"], "bch_b": (folds["recordings"]["bch_b"] + 1) % 5}})
        with self.assertRaises(inv.AuditError) as cm:
            self.syn.build()
        self.assertIn("edited after it was written", str(cm.exception))
        self.syn.save()
        self.syn.build()
        synthetic.write_json(os.path.join(self.syn.project, "pipeline_tuning", "validation.json"), {"lineageHoldout": []})
        with self.assertRaises(inv.AuditError) as cm:
            self.syn.build()
        self.assertIn("older than validation.json", str(cm.exception))

    def test_left_out_reasons(self):
        s = self.syn
        os.remove(s.marks_path("bch_b"))
        synthetic.write_json(s.marks_path("bch_c"), [{"startTime": 1.0, "endTime": 2.0, "kind": "warmup"}])
        s.sessions["bch_d"]["ralliesMarked"] = False
        s.types["grs_b"] = "edited"
        synthetic.write_json(inv.sidecar_path(s.video("grs_c"), "rallyevents"), {})
        s.rows["grs_d"]["fingerprint"] = "file:card-replaced"
        s.rows["grs_e"]["contentFingerprint"] = None
        del s.rows["grs_f"]
        s.sessions["ind_b"]["cuts"] = [{"start": 4.0, "end": 6.0}]
        s.save()
        os.remove(os.path.join(s.project, "footage-properties", "ind_c.json"))
        why = self.left_out(s.build())
        for rid, fragment in (("bch_b", "no rally marks beside the video"), ("bch_c", "rally marks unreadable: mark 0 has kind 'warmup'"),
                              ("bch_d", "no longer declared complete"), ("grs_b", "typed 'edited' now"), ("grs_c", "Stage 1 boundary record"),
                              ("grs_d", "changed since the export"), ("grs_e", "no content fingerprint"), ("grs_f", "not in the current split manifest"),
                              ("ind_b", "overlaps a cut range"), ("ind_c", "no footage-type record now")):
            self.assertIn(fragment, why[rid], rid)
        self.assertEqual(len(why), 12)

    def test_cli_writes_once(self):
        out = os.path.join(self.tmp, "out", "inventory.json")
        args = ["--dataset", self.syn.dataset, "--project", self.syn.project, "--closure", self.syn.closure_path, "--folds", self.syn.folds_path, "--out", out]
        text = io.StringIO()
        with contextlib.redirect_stdout(text):
            self.assertEqual(inv.main(args), 0)
            self.assertEqual(inv.main(args), 1)
        self.assertIn("22 eligible recording(s) in 18 group(s)", text.getvalue())
        self.assertIn("left out — grs_edit: edited recording", text.getvalue())
        self.assertIn("never overwritten", text.getvalue())
        self.assertEqual(inv.load_inventory(out)["totals"]["recordings"], 22)

    def test_load_refuses_a_tampered_inventory(self):
        def withheld(doc):
            doc["withheld"]["names"].append(doc["recordings"][0]["recordingId"])

        def edited(doc):
            doc["recordings"][1]["recordingType"] = "edited"

        def moved(doc):
            doc["recordings"][2]["intervals"][0]["endTick"] -= 600

        def emptied(doc):
            doc["withheld"]["names"] = []

        def twice(doc):
            doc["recordings"].append(json.loads(json.dumps(doc["recordings"][0])))

        for mutate, fragment in ((withheld, "WITHHELD recording 'bch_a' present (name in the closure)"), (edited, "is not a continuous recording"),
                                 (moved, "do not follow from its rallies"), (emptied, "withheld.names is empty"), (twice, "duplicate recordingId"),
                                 (lambda doc: doc.update(schemaVersion="coverage_audit_inventory_v1"), "schemaVersion must be")):
            with self.subTest(fragment=fragment):
                with self.assertRaises(inv.AuditError) as cm:
                    inv.load_inventory(self.syn.write_inventory(mutate))
                self.assertIn(fragment, str(cm.exception))


if __name__ == "__main__":
    unittest.main()
