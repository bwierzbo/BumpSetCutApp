"""Tests for scripts/rally_classifier/coverage_audit_draw.py on a synthetic inventory: the pilot's constraints
(four per surface where feasible, never two from a recording group), what the draw is bound to, determinism, the
repeat set, the refusals (withheld by every identity, edited, an unfrozen or uncommitted protocol, an existing draw)
and stage 2, which follows only a pilot that passed. Standard library only; nothing real is read.

    python3 -m unittest scripts.tests.test_coverage_audit_draw -v
"""

import contextlib
import io
import os
import random
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rally_classifier"))
import coverage_audit_draw as d  # noqa: E402
import coverage_audit_inventory as inv  # noqa: E402
import coverage_audit_report as report  # noqa: E402
import coverage_audit_synthetic as synthetic  # noqa: E402

NOW = "2026-11-14T18:15:00Z"


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cov-draw-")
        self.syn = synthetic.Synthetic(self.tmp)
        self.inventory = self.syn.write_inventory()
        self.protocol = synthetic.protocol_repo(self.tmp)
        self.out = os.path.join(self.tmp, "coverage-audit")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def pilot(self, **kw):
        return d.build_pilot(self.inventory, self.protocol, now=NOW, **kw)


class Pilot(Case):
    def test_four_per_surface_one_per_group(self):
        draw = self.pilot()
        recs = draw["recordings"]
        self.assertEqual(len(recs), 12)
        self.assertEqual(len({r["groupId"] for r in recs}), 12, "never two recordings from one recording group")
        for surface in ("beach", "grass", "indoor"):
            self.assertEqual(sum(r["surface"] == surface for r in recs), 4, surface)
        # beach has exactly four eligible groups: the draw is one recording from each of them
        self.assertEqual({r["groupId"] for r in recs if r["surface"] == "beach"}, {"g-bch_a", "g-bch_b", "g-bch_c", "g-bch_d"})
        self.assertEqual([(w["surface"], w["eligibleGroups"], w["drawn"], w["asPlanned"]) for w in draw["whereFeasible"]],
                         [("beach", 4, 4, True), ("grass", 6, 4, True), ("indoor", 8, 4, True)])
        self.assertEqual([(r["surface"], r["recordingId"]) for r in recs], sorted((r["surface"], r["recordingId"]) for r in recs))
        self.assertNotIn("bch_a_edit", [r["recordingId"] for r in recs])

    def test_what_the_draw_is_bound_to(self):
        draw = self.pilot()
        doc = inv.load_inventory(self.inventory)
        self.assertEqual((draw["schemaVersion"], draw["procedure"], draw["stage"], draw["drawId"], draw["seed"]),
                         ("coverage_audit_draw_v2", "coverage_draw_v2", "pilot", "20261114-181500", 20261114))
        self.assertEqual((draw["perSurface"], draw["repeatOneIn"], draw["repeatMin"], draw["everyIntervalReviewed"], draw["follows"]), (4, 5, 2, True, None))
        self.assertEqual(draw["dataset"], doc["dataset"])
        self.assertEqual(draw["folds"], doc["folds"])
        self.assertEqual(draw["splitManifest"], doc["splitManifest"])
        self.assertEqual(draw["inventory"], {"sha256": inv.v.sha256_file(self.inventory), "createdAt": doc["createdAt"]})
        self.assertEqual(draw["withheld"], {"closureSha256": doc["withheld"]["closureSha256"], "closureFileSha256": doc["withheld"]["closureFileSha256"],
                                            "names": 1, "sourceIds": 1, "fingerprints": 2, "aliasGroups": 1})
        self.assertEqual(draw["protocol"]["path"], "PROTOCOL.md")
        self.assertEqual(draw["protocol"]["sha256"], inv.v.sha256_file(self.protocol))
        self.assertEqual(len(draw["protocol"]["gitCommit"]), 40)
        by_id = {r["recordingId"]: r for r in doc["recordings"]}
        for r in draw["recordings"]:
            source = by_id[r["recordingId"]]
            for key in ("groupId", "surface", "split", "fold", "camera", "durationTicks", "fingerprint", "contentFingerprint", "sourceId",
                        "marksSha256", "marksChangedSinceExport", "rallyMarks", "intervals"):
                self.assertEqual(r[key], source[key], key)
            self.assertEqual(set(r["intervals"][0]), {"index", "startTick", "endTick"})
        drawn = {r["recordingId"] for r in draw["recordings"]}
        self.assertEqual({r["recordingId"] for r in draw["notDrawn"]}, set(by_id) - drawn)
        self.assertEqual(len(draw["notDrawn"]), 10)
        self.assertEqual({e["recordingId"] for e in draw["leftOut"]}, {"bch_a_edit", "grs_edit"})
        t = draw["totals"]
        self.assertEqual((t["recordings"], t["groups"], t["intervals"], t["rallyMarks"], t["repeatIntervals"]), (12, 12, 168, 144, 36))
        self.assertEqual(draw["criterion"], {"n": 144, "confidence": 0.9, "maxUpperBound": 0.05, "largestPassingM": 3, "maxPerRecording": 2})

    def test_the_draw_is_deterministic_under_its_seed_and_changes_with_it(self):
        self.assertEqual(self.pilot(), self.pilot())
        samples = {tuple(r["recordingId"] for r in self.pilot(seed=s)["recordings"]) for s in range(6)}
        self.assertGreater(len(samples), 1, "different seeds should draw different samples")

    def test_a_surface_with_fewer_groups_gives_one_from_each_and_says_so(self):
        specs = [s for s in synthetic.corpus() if s["surface"] != "indoor" or s["group"] in ("g-ind_a", "g-ind_b")]
        syn = synthetic.Synthetic(os.path.join(self.tmp, "few"), specs)
        draw = d.build_pilot(syn.write_inventory(), self.protocol, now=NOW)
        indoor = [r for r in draw["recordings"] if r["surface"] == "indoor"]
        self.assertEqual(sorted(r["groupId"] for r in indoor), ["g-ind_a", "g-ind_b"], "one from each group, never a second from g-ind_a")
        self.assertEqual(len(draw["recordings"]), 10)
        row = draw["whereFeasible"][2]
        self.assertEqual((row["surface"], row["eligibleGroups"], row["drawn"], row["asPlanned"]), ("indoor", 2, 2, False))
        self.assertIn("fewer than 4", row["note"])
        self.assertIn("never two from one group", row["note"])

    def test_a_surface_with_no_eligible_recording_is_reported(self):
        specs = [s for s in synthetic.corpus() if s["surface"] != "grass" or s["type"] == "edited"]
        syn = synthetic.Synthetic(os.path.join(self.tmp, "none"), specs)
        draw = d.build_pilot(syn.write_inventory(), self.protocol, now=NOW)
        self.assertEqual([(w["surface"], w["drawn"], w["asPlanned"]) for w in draw["whereFeasible"]], [("beach", 4, True), ("grass", 0, False), ("indoor", 4, True)])

    def test_the_repeat_set_is_a_fifth_with_a_minimum_of_two(self):
        for n in range(0, 23):
            intervals = [{"index": i} for i in range(n)]
            picked = d.draw_repeat(intervals, random.Random(n))
            self.assertEqual(len(picked), min(n, max(2, -(-n // 5))), n)
            self.assertEqual(picked, sorted(set(picked)))
            self.assertTrue(set(picked) <= set(range(n)))
        for r in self.pilot()["recordings"]:
            self.assertEqual(len(r["repeatIndices"]), 3)

    def test_ranked_uses_one_random_key_per_element(self):
        rng, twin = random.Random(5), random.Random(5)
        keys = [twin.random() for _ in range(4)]
        self.assertEqual(d.ranked(list("abcd"), rng), [x for _, x in sorted(zip(keys, "abcd"))])


class Refusals(Case):
    def refused(self, mutate, fragment):
        self.inventory = self.syn.write_inventory(mutate)
        with self.assertRaises(inv.AuditError) as cm:
            self.pilot()
        self.assertIn(fragment, str(cm.exception))

    def test_withheld_by_every_identity(self):
        def by(key, value, target):
            def mutate(doc):
                doc["withheld"][key].append(value)
                if target:
                    doc["recordings"][3][target] = value
            return mutate

        for mutate, identity in ((by("names", "bch_b", None), "name"), (by("sourceIds", "src:bch_b", None), "sourceId"),
                                 (by("fingerprints", "file:card-bch_b", None), "fingerprint"),
                                 (by("fingerprints", "file:content-bch_b", None), "contentFingerprint"),
                                 (by("aliasGroups", "withheld_01", "aliasGroup"), "aliasGroup")):
            with self.subTest(identity=identity):
                self.refused(mutate, f"WITHHELD recording 'bch_b' present ({identity} in the closure)")

    def test_an_empty_closure_and_an_edited_recording(self):
        self.refused(lambda doc: doc["withheld"].update(names=[]), "withheld.names is empty")
        self.refused(lambda doc: doc["recordings"][0].update(recordingType="edited", fullVideoNegatives="restricted"), "an edited recording is never audited")
        self.refused(lambda doc: doc["recordings"][0].update(fullVideoNegatives="restricted"), "standard full-video negatives")

    def test_the_protocol_must_be_frozen_committed_and_unchanged(self):
        proposed = synthetic.protocol_repo(os.path.join(self.tmp, "p1"), status="proposed — not approved")
        with self.assertRaises(inv.AuditError) as cm:
            d.build_pilot(self.inventory, proposed, now=NOW)
        self.assertIn("not frozen (status: proposed", str(cm.exception))
        with open(self.protocol, "a") as fh:
            fh.write("\nA later edit.\n")
        with self.assertRaises(inv.AuditError) as cm:
            self.pilot()
        self.assertIn("differs from its committed text", str(cm.exception))
        loose = os.path.join(os.path.dirname(self.protocol), "LOOSE.md")
        with open(loose, "w") as fh:
            fh.write("---\nstatus: frozen\n---\n")
        with self.assertRaises(inv.AuditError) as cm:
            d.build_pilot(self.inventory, loose, now=NOW)
        self.assertIn("not committed", str(cm.exception))
        with self.assertRaises(inv.AuditError) as cm:
            d.build_pilot(self.inventory, os.path.join(self.tmp, "missing.md"), now=NOW)
        self.assertIn("unreadable", str(cm.exception))

    def test_a_draw_is_written_once_and_another_needs_a_reason(self):
        draw = self.pilot()
        path = d.write_draw(draw, self.out)
        self.assertEqual(os.path.basename(path), "20261114-181500-draw.json")
        written, _ = report.read_draw(path)
        self.assertEqual((written["reason"], written["supersedes"]), (None, []))
        self.assertEqual({k: w for k, w in written.items() if k not in ("reason", "supersedes")}, draw)
        with self.assertRaises(inv.AuditError) as cm:
            d.write_draw(draw, self.out, reason="again")
        self.assertIn("never overwritten", str(cm.exception))
        later = d.build_pilot(self.inventory, self.protocol, now="2026-11-20T09:00:00Z")
        with self.assertRaises(inv.AuditError) as cm:
            d.write_draw(later, self.out)
        self.assertIn("needs --reason", str(cm.exception))
        second, _ = report.read_draw(d.write_draw(later, self.out, reason="marks corrected after the pilot failed"))
        self.assertEqual((second["reason"], second["supersedes"]), ("marks corrected after the pilot failed", ["20261114-181500"]))
        self.assertEqual(len(os.listdir(self.out)), 2)

    def test_cli(self):
        text = io.StringIO()
        with contextlib.redirect_stdout(text):
            self.assertEqual(d.main([self.inventory, "--out-dir", self.out, "--protocol", self.protocol]), 0)
            self.assertEqual(d.main([self.inventory, "--out-dir", self.out, "--protocol", self.protocol]), 1)
            self.assertEqual(d.main([os.path.join(self.tmp, "nope.json"), "--out-dir", self.out, "--protocol", self.protocol]), 1)
        out = text.getvalue()
        self.assertIn("pilot draw", out)
        self.assertIn("beach: 4 of 4 eligible recording group(s), one recording from each", out)
        self.assertIn("for n = 144 at most m = 3", out)
        self.assertIn("needs --reason", out)
        self.assertIn("inventory unreadable", out)
        self.assertEqual(len(os.listdir(self.out)), 1)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            d.main([self.inventory, "--out-dir", self.out, "--stage2"])


class Stage2(Case):
    def setUp(self):
        super().setUp()
        self.pilot_path = d.write_draw(self.pilot(), self.out)

    def stage2(self):
        return d.build_stage2(self.inventory, self.pilot_path, self.syn.project, self.protocol, now="2026-11-21T08:00:00Z")

    def test_stage_2_is_refused_until_the_pilot_passes(self):
        with self.assertRaises(inv.AuditError) as cm:
            self.stage2()
        self.assertIn("only when the pilot passes; pilot 20261114-181500 is incomplete", str(cm.exception))
        first = report.read_draw(self.pilot_path)[0]["recordings"][0]["recordingId"]
        synthetic.write_records(self.syn, self.pilot_path, findings={first: {i: [{"kind": "missed_rally"}] for i in (0, 1, 2)}})
        with self.assertRaises(inv.AuditError) as cm:
            self.stage2()
        self.assertIn("is fail", str(cm.exception))

    def test_stage_2_lists_every_remaining_recording_bound_to_its_pilot(self):
        synthetic.write_records(self.syn, self.pilot_path)
        draw = self.stage2()
        pilot, pilot_sha = report.read_draw(self.pilot_path)
        self.assertEqual((draw["stage"], draw["follows"], draw["seed"]), ("stage2", {"drawId": "20261114-181500", "sha256": pilot_sha}, pilot["seed"]))
        self.assertEqual(draw["pilot"]["outcome"], "pass")
        self.assertEqual({r["recordingId"] for r in draw["recordings"]}, {r["recordingId"] for r in pilot["notDrawn"]})
        self.assertEqual((len(draw["recordings"]), draw["notDrawn"], draw["totals"]["intervals"]), (10, [], 140))
        self.assertEqual(draw["inPilot"], sorted(r["recordingId"] for r in pilot["recordings"]))
        self.assertTrue(all(len(r["repeatIndices"]) == 3 for r in draw["recordings"]))
        self.assertEqual(draw, self.stage2())
        path = d.write_draw(draw, self.out)
        self.assertEqual(os.path.basename(path), "20261121-080000-draw.json")

    def test_stage_2_needs_the_pilots_dataset_and_a_pilot_draw(self):
        synthetic.write_records(self.syn, self.pilot_path)
        stage2_path = d.write_draw(self.stage2(), self.out)
        with self.assertRaises(inv.AuditError) as cm:
            d.build_stage2(self.inventory, stage2_path, self.syn.project, self.protocol)
        self.assertIn("stage 2 follows a pilot draw", str(cm.exception))
        self.syn.manifest["recordings"][0]["camera"] = "another export"
        self.syn.save()
        self.inventory = self.syn.write_inventory()
        with self.assertRaises(inv.AuditError) as cm:
            self.stage2()
        self.assertIn("the dataset is not the one the pilot was drawn for", str(cm.exception))

    def test_cli_stage_2(self):
        synthetic.write_records(self.syn, self.pilot_path)
        text = io.StringIO()
        with contextlib.redirect_stdout(text):
            self.assertEqual(d.main([self.inventory, "--out-dir", self.out, "--protocol", self.protocol, "--stage2", "--follows", self.pilot_path,
                                     "--project", self.syn.project]), 0)
        self.assertIn("stage2 draw", text.getvalue())
        self.assertIn("10 recording(s)", text.getvalue())


if __name__ == "__main__":
    unittest.main()
