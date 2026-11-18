"""Tests for scripts/rally_classifier/coverage_audit_report.py: the exact binomial bound against known values, and —
on synthetic audit records — that nothing is evaluated while a pilot interval is unreviewed, what counts as a
finding, how a recording's state is derived, how the repeat is accepted and labelled, when a record is void, the
pass / fail criterion and the trusted-negative count against G6. Standard library only; nothing real is read.

    python3 -m unittest scripts.tests.test_coverage_audit_report -v
"""

import contextlib
import hashlib
import io
import os
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
import validate_dataset as v  # noqa: E402


class Bound(unittest.TestCase):
    def test_closed_forms(self):
        for n in (1, 10, 45, 144, 340):
            self.assertAlmostEqual(report.upper_bound(0, n), 1 - 0.1 ** (1 / n), places=12)      # (1 − p)^n = 0.10
            self.assertEqual(report.upper_bound(n, n), 1.0)
            if n > 1:
                self.assertAlmostEqual(report.upper_bound(n - 1, n), 0.9 ** (1 / n), places=12)   # 1 − p^n = 0.10

    def test_known_values_and_the_defining_identity(self):
        self.assertAlmostEqual(report.upper_bound(1, 20), 0.180961, places=6)      # tabulated: 1 of 20, one-sided 90 %
        self.assertAlmostEqual(report.upper_bound(5, 190), 0.048266, places=6)
        self.assertAlmostEqual(report.upper_bound(6, 190), 0.054772, places=6)
        for m, n in ((0, 30), (2, 120), (3, 144), (11, 340), (40, 90)):
            self.assertAlmostEqual(report.binomial_cdf(m, n, report.upper_bound(m, n)), 0.10, places=9)
        self.assertAlmostEqual(report.binomial_cdf(2, 5, 0.5), 0.5, places=12)
        self.assertEqual((report.binomial_cdf(5, 5, 0.3), report.binomial_cdf(1, 5, 0.0), report.binomial_cdf(1, 5, 1.0)), (1.0, 1.0, 0.0))

    def test_the_bound_grows_with_m_and_is_refused_without_marks(self):
        bounds = [report.upper_bound(m, 144) for m in range(0, 20)]
        self.assertEqual(bounds, sorted(bounds))
        self.assertGreater(report.upper_bound(3, 100), report.upper_bound(3, 150))
        with self.assertRaises(inv.AuditError):
            report.upper_bound(0, 0)

    def test_the_largest_passing_m_of_the_protocols_table(self):
        self.assertEqual({n: report.largest_passing_m(n) for n in range(100, 181, 10)},
                         {100: 1, 110: 2, 120: 2, 130: 2, 140: 3, 150: 3, 160: 4, 170: 4, 180: 4})
        self.assertEqual((report.largest_passing_m(44), report.largest_passing_m(45), report.largest_passing_m(132)), (None, 0, 3))


class Records(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cov-report-")
        self.syn = synthetic.Synthetic(self.tmp)
        self.inventory = self.syn.write_inventory()
        self.protocol = synthetic.protocol_repo(self.tmp)
        self.out = os.path.join(self.tmp, "coverage-audit")
        self.draw_path = d.write_draw(d.build_pilot(self.inventory, self.protocol, now="2026-11-14T18:15:00Z"), self.out)
        self.draw, self.draw_sha = report.read_draw(self.draw_path)
        self.ids = [r["recordingId"] for r in self.draw["recordings"]]
        self.first = self.ids[0]
        self.free = next(i for i in range(synthetic.INTERVALS) if i not in self.draw["recordings"][0]["repeatIndices"])   # not in the repeat set
        self.again = self.draw["recordings"][0]["repeatIndices"][0]                                                    # in the repeat set

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def evaluate(self, **kw):
        synthetic.write_records(self.syn, self.draw_path, **kw)
        return report.evaluate(self.draw_path, self.syn.project)

    def row(self, result, rid=None):
        return next(r for r in result["pilot"]["recordings"] if r["recordingId"] == (rid or self.first))

    # completeness ---------------------------------------------------------------------------------------------

    def test_nothing_is_evaluated_without_records(self):
        result = report.evaluate(self.draw_path, self.syn.project)
        pilot = result["pilot"]
        self.assertEqual(pilot["outcome"], "incomplete")
        self.assertFalse({"m", "upperBound", "boundMet"} & set(pilot))
        self.assertEqual(set(pilot["missing"]["notReviewed"]), set(self.ids))
        self.assertEqual(pilot["missing"]["notReviewed"][self.first], list(range(synthetic.INTERVALS)))
        self.assertEqual((pilot["totals"]["reviewed"], pilot["totals"]["notReviewed"], pilot["totals"]["intervals"]), (0, 168, 168))
        self.assertEqual(pilot["totals"]["states"], {"partial": 12})
        self.assertEqual(self.row(result)["record"], "missing")
        self.assertEqual((result["trustedNegatives"]["usable"], result["trustedNegatives"]["groupCount"]), (False, 0))

    def test_one_missing_record_or_interval_keeps_the_pilot_incomplete(self):
        result = self.evaluate(skip=(self.ids[5],))
        self.assertEqual(result["pilot"]["outcome"], "incomplete")
        self.assertEqual(list(result["pilot"]["missing"]["notReviewed"]), [self.ids[5]])
        record = inv.load_json(self.syn.record_path(self.first), "record")
        record["intervals"] = [iv for iv in record["intervals"] if iv["index"] != self.free]
        synthetic.write_json(self.syn.record_path(self.first), record)
        result = report.evaluate(self.draw_path, self.syn.project)
        self.assertEqual(result["pilot"]["missing"]["notReviewed"][self.first], [self.free])
        self.assertEqual((self.row(result)["state"], self.row(result)["reviewed"]), ("partial", synthetic.INTERVALS - 1))

    def test_a_finding_given_before_its_interval_played_whole_keeps_the_pilot_incomplete(self):
        self.evaluate()
        record = inv.load_json(self.syn.record_path(self.first), "record")
        iv = next(i for i in record["intervals"] if i["index"] == self.free)
        iv.update(verdict="not_clean", findings=[{"kind": "non_rally_activity", "approxStartSec": 1.0}])
        iv.pop("playedAllAtMaxRate")
        synthetic.write_json(self.syn.record_path(self.first), record)
        result = report.evaluate(self.draw_path, self.syn.project)
        self.assertEqual(result["pilot"]["outcome"], "incomplete")
        self.assertEqual(result["pilot"]["missing"]["unfinished"], {self.first: [self.free]})
        row = self.row(result)
        self.assertEqual((row["state"], row["unfinished"], row["findings"]["non_rally_activity"]["count"]), ("partial", [self.free], 1),
                         "the finding stands; the interval waits for the rest of its look")
        # Played to its end: the look is finished and the pilot can be evaluated.
        iv["playedAllAtMaxRate"] = 2.0
        synthetic.write_json(self.syn.record_path(self.first), record)
        self.assertEqual(report.evaluate(self.draw_path, self.syn.project)["pilot"]["outcome"], "pass")

    def test_a_clean_look_at_three_times_counts_and_is_reported_apart(self):
        # Amendment 1 (D-040): clean may be given over an interval played whole at up to 3×; faster than 2× is counted apart.
        self.assertEqual(self.evaluate()["pilot"]["totals"]["cleanFastIntervals"], 0, "every synthetic look is at 2×")
        record = inv.load_json(self.syn.record_path(self.first), "record")
        iv = next(i for i in record["intervals"] if i["index"] == self.free)
        iv["playedAllAtMaxRate"] = 3.0
        synthetic.write_json(self.syn.record_path(self.first), record)
        result = report.evaluate(self.draw_path, self.syn.project)
        row, t = self.row(result), result["pilot"]["totals"]
        self.assertEqual(result["pilot"]["outcome"], "pass")
        self.assertEqual((row["cleanIntervals"], row["cleanFastIntervals"]), (synthetic.INTERVALS, 1))
        self.assertEqual(t["cleanFastIntervals"], 1)
        self.assertAlmostEqual(t["cleanFastSeconds"], row["cleanFastSeconds"])
        self.assertIn("played faster than 2× (amendment 1): 1 interval(s)", report.render(result))

    def test_each_recording_carries_the_hash_of_its_record_as_evaluated(self):
        result = self.evaluate()
        row = self.row(result)
        self.assertEqual(row["recordSha256"], v.sha256_file(self.syn.record_path(self.first)))
        os.remove(self.syn.record_path(self.ids[5]))
        missing = self.row(self.evaluate(skip=(self.ids[5],)), self.ids[5])
        self.assertIsNone(missing["recordSha256"])

    def test_the_hash_is_of_the_bytes_evaluated_even_if_the_record_is_saved_meanwhile(self):
        self.evaluate()
        path = self.syn.record_path(self.first)
        with open(path, "rb") as fh:
            evaluated = fh.read()
        real = report.review_recording

        def saved_meanwhile(rec, *args):
            row = real(rec, *args)
            if rec["recordingId"] == self.first:          # RallyLab saves the sidecar while the report runs
                with open(path, "w") as fh:
                    fh.write(evaluated.decode().replace('"clean"', '"clean" ', 1))
            return row
        report.review_recording = saved_meanwhile
        try:
            row = self.row(report.evaluate(self.draw_path, self.syn.project))
        finally:
            report.review_recording = real
        self.assertEqual(row["recordSha256"], hashlib.sha256(evaluated).hexdigest())
        self.assertNotEqual(row["recordSha256"], v.sha256_file(path))

    def test_a_record_with_repeats_by_both_reviewers_is_read_by_who_made_each(self):
        self.evaluate()
        record = inv.load_json(self.syn.record_path(self.first), "record")
        repeats = record["repeat"]["intervals"]
        self.assertGreater(len(repeats), 1)
        # RallyLab labels the block same_reviewer_after_24h when any repeat is the first reviewer's.
        record["repeat"]["method"] = "same_reviewer_after_24h"
        repeats[0]["reviewer"] = "owner"
        synthetic.write_json(self.syn.record_path(self.first), record)
        result = report.evaluate(self.draw_path, self.syn.project)
        row = self.row(result)
        self.assertEqual(row["problems"], [])
        self.assertEqual((row["agreement"]["same_reviewer_after_24h"]["compared"], row["agreement"]["second_reviewer"]["compared"]),
                         (1, len(repeats) - 1))
        self.assertEqual(result["pilot"]["outcome"], "pass")
        self.assertFalse(result["pilot"]["totals"]["agreement"]["same_reviewer_after_24h"]["independent"])
        # A block that claims second_reviewer never holds a repeat of the first reviewer's.
        record["repeat"]["method"] = "second_reviewer"
        synthetic.write_json(self.syn.record_path(self.first), record)
        row = self.row(report.evaluate(self.draw_path, self.syn.project))
        self.assertTrue(any("calls it second_reviewer" in p for p in row["problems"]), row["problems"])

    def test_the_repeat_set_must_be_done_before_the_pilot_is_evaluated(self):
        result = self.evaluate(repeat=None)
        self.assertEqual(result["pilot"]["outcome"], "incomplete")
        self.assertEqual(result["pilot"]["missing"]["notReviewed"], {})
        self.assertEqual(result["pilot"]["missing"]["repeatPending"][self.first], self.draw["recordings"][0]["repeatIndices"])
        self.assertEqual(self.row(result)["state"], "audited_clean", "a pending repeat does not change the first verdicts' state")

    # a clean pilot ----------------------------------------------------------------------------------------------

    def test_a_clean_pilot_passes_and_counts_trusted_negatives_against_g6(self):
        result = self.evaluate()
        pilot = result["pilot"]
        self.assertEqual((pilot["outcome"], pilot["m"], pilot["n"], pilot["largestPassingM"]), ("pass", 0, 144, 3))
        self.assertAlmostEqual(pilot["upperBound"], 1 - 0.1 ** (1 / 144), places=12)
        self.assertTrue(pilot["boundMet"] and pilot["perRecordingMet"])
        t = pilot["totals"]
        self.assertEqual((t["reviewed"], t["notReviewed"], t["repeatPending"], t["unresolved"], t["cleanIntervals"]), (168, 0, 0, 0, 168))
        self.assertAlmostEqual(t["secondsReviewed"], 12 * (5 + 11 * 4 + 3 + 8))
        self.assertAlmostEqual(t["cleanSeconds"], t["secondsDrawn"])
        self.assertEqual(t["states"], {"audited_clean": 12})
        self.assertEqual(t["agreement"]["second_reviewer"]["independent"], True)
        self.assertEqual((t["agreement"]["second_reviewer"]["compared"], t["agreement"]["second_reviewer"]["identical"]), (36, 36))
        self.assertEqual(t["agreement"]["second_reviewer"]["byClass"]["clean"], {"both": 36, "firstOnly": 0, "repeatOnly": 0})
        tn = result["trustedNegatives"]
        self.assertEqual((tn["usable"], tn["groupCount"]), (True, 12))
        self.assertEqual(sum(tn["groupsPerFold"].values()), 12)
        self.assertEqual(tn["g6"]["groupsRequired"], 13, "two-thirds of the dataset's 19 groups, rounded up")
        self.assertFalse(tn["g6"]["met"])
        self.assertIn("1 group(s) short of 13 (two-thirds of 19)", tn["g6"]["deficiency"])

    # findings ---------------------------------------------------------------------------------------------------

    def test_each_finding_kind_is_counted_apart_with_its_seconds(self):
        f = self.free
        other = self.ids[1]
        result = self.evaluate(findings={
            self.first: {f: [{"kind": "missed_rally", "approxStartSec": 10.0, "approxEndSec": 16.5, "edge": "start"},
                             {"kind": "missed_serve", "approxStartSec": 20.0, "approxEndSec": 21.0}]},
            other: {0: [{"kind": "non_rally_activity", "approxStartSec": 1.0, "approxEndSec": 4.0}], 1: [{"kind": "edited_footage", "note": "replay"}]},
            self.ids[2]: {0: [{"kind": "boundary_error", "edge": "trailing", "approxStartSec": 3.0, "approxEndSec": 4.5}]},
            self.ids[3]: {0: [{"kind": "uncertain", "note": "court hidden by a spectator"}]}})
        pilot, t = result["pilot"], result["pilot"]["totals"]
        self.assertEqual((pilot["outcome"], pilot["m"], pilot["missedRallies"], pilot["missedServes"]), ("pass", 2, 1, 1))
        self.assertEqual(t["findings"]["missed_rally"], {"count": 1, "seconds": 6.5, "withoutTimes": 0})
        self.assertEqual(t["findings"]["missed_serve"], {"count": 1, "seconds": 1.0, "withoutTimes": 0})
        self.assertEqual(t["findings"]["non_rally_activity"], {"count": 1, "seconds": 3.0, "withoutTimes": 0})
        self.assertEqual(t["findings"]["edited_footage"], {"count": 1, "seconds": 0.0, "withoutTimes": 1}, "seconds unknown, not zero: counted apart")
        self.assertEqual(t["findings"]["boundary_error"], {"count": 1, "seconds": 1.5, "withoutTimes": 0})
        self.assertEqual(t["findings"]["uncertain"], {"count": 1, "seconds": 5.0, "withoutTimes": 0}, "an uncertain finding without times takes its interval")
        self.assertEqual(t["cleanIntervals"], 168 - 5)
        self.assertEqual({rid: self.row(result, rid)["state"] for rid in self.ids[:5]},
                         {self.first: "contaminated", other: "audited_clean", self.ids[2]: "partial", self.ids[3]: "partial", self.ids[4]: "audited_clean"})
        self.assertEqual(t["states"], {"contaminated": 1, "partial": 2, "audited_clean": 9})
        # negatives come from clean intervals, not the recording's state — but not from a recording with edited footage in it
        self.assertTrue(self.row(result)["suppliesTrustedNegatives"])
        self.assertFalse(self.row(result, other)["suppliesTrustedNegatives"])
        self.assertEqual(result["trustedNegatives"]["recordingsWithEditedFootage"], [other])
        self.assertEqual(result["trustedNegatives"]["groupCount"], 11)

    def test_a_contaminated_recording_that_is_also_partial_shows_both(self):
        result = self.evaluate(findings={self.first: {self.free: [{"kind": "missed_serve"}, {"kind": "boundary_error", "edge": "leading"}]}})
        row = self.row(result)
        self.assertEqual((row["state"], row["contaminated"], row["partial"]), ("contaminated", True, True))
        self.assertEqual(result["pilot"]["totals"]["alsoPartial"], 1)
        self.assertIn("contaminated + partial", report.render(result))

    def test_the_bound_fails_the_pilot(self):
        result = self.evaluate(findings={rid: {self.free_of(rid): [{"kind": "missed_rally"}]} for rid in self.ids[:4]})
        pilot = result["pilot"]
        self.assertEqual((pilot["outcome"], pilot["m"], pilot["boundMet"], pilot["perRecordingMet"]), ("fail", 4, False, True))
        self.assertGreater(pilot["upperBound"], 0.05)
        self.assertFalse(result["trustedNegatives"]["usable"])
        self.assertIn("no negative is used until the pilot passes", result["trustedNegatives"]["note"])

    def test_three_in_one_recording_fail_the_pilot_though_the_bound_holds(self):
        result = self.evaluate(findings={self.first: {self.free: [{"kind": "missed_rally"}, {"kind": "missed_rally"}, {"kind": "missed_serve"}]}})
        pilot = result["pilot"]
        self.assertEqual((pilot["outcome"], pilot["m"], pilot["boundMet"], pilot["perRecordingMet"]), ("fail", 3, True, False))
        self.assertEqual(pilot["mostInOneRecording"], {"recordingId": self.first, "missed": 3})

    def free_of(self, rid):
        rec = next(r for r in self.draw["recordings"] if r["recordingId"] == rid)
        return next(i for i in range(synthetic.INTERVALS) if i not in rec["repeatIndices"])

    # the repeat -------------------------------------------------------------------------------------------------

    def test_an_uncertain_interval_joins_the_repeat_set(self):
        uncertain = {self.first: {self.free: [{"kind": "uncertain", "note": "glare"}]}}
        synthetic.write_records(self.syn, self.draw_path, findings=uncertain)
        record = inv.load_json(self.syn.record_path(self.first), "record")
        record["repeat"]["intervals"] = [e for e in record["repeat"]["intervals"] if e["index"] != self.free]
        synthetic.write_json(self.syn.record_path(self.first), record)
        result = report.evaluate(self.draw_path, self.syn.project)
        self.assertEqual(result["pilot"]["outcome"], "incomplete")
        self.assertEqual(result["pilot"]["missing"]["repeatPending"], {self.first: [self.free]})

    def test_a_same_reviewer_repeat_needs_24_hours_and_is_never_called_independent(self):
        result = self.evaluate(repeat="same_reviewer_after_24h", repeat_at="2026-11-16T09:59:59Z")
        self.assertEqual(result["pilot"]["outcome"], "incomplete")
        self.assertIn("less than 24 h after the first verdict", " ".join(self.row(result)["problems"]))
        self.assertEqual(len(result["pilot"]["missing"]["repeatPending"]), 12)
        result = self.evaluate(repeat="same_reviewer_after_24h", repeat_at="2026-11-16T10:00:00Z")
        self.assertEqual(result["pilot"]["outcome"], "pass")
        agreement = result["pilot"]["totals"]["agreement"]
        self.assertEqual(list(agreement), ["same_reviewer_after_24h"])
        self.assertFalse(agreement["same_reviewer_after_24h"]["independent"])
        self.assertIn("repeat by the same reviewer after 24 h — not independent inter-rater agreement", report.render(result))

    def test_a_repeat_labelled_with_the_wrong_method_is_not_accepted(self):
        synthetic.write_records(self.syn, self.draw_path)
        record = inv.load_json(self.syn.record_path(self.first), "record")
        for entry in record["repeat"]["intervals"]:
            entry["reviewer"] = "owner"                     # the first reviewer, under the label second_reviewer
        synthetic.write_json(self.syn.record_path(self.first), record)
        result = report.evaluate(self.draw_path, self.syn.project)
        self.assertIn("by the first reviewer but the record calls it second_reviewer", " ".join(self.row(result)["problems"]))
        self.assertEqual(list(result["pilot"]["missing"]["repeatPending"]), [self.first])
        record["repeat"]["method"] = "third_opinion"
        synthetic.write_json(self.syn.record_path(self.first), record)
        self.assertIn("method 'third_opinion'", " ".join(self.row(report.evaluate(self.draw_path, self.syn.project))["problems"]))

    def test_a_disagreement_needs_a_resolution_and_the_resolution_counts(self):
        missed = [{"kind": "missed_rally", "approxStartSec": 12.0, "approxEndSec": 15.0}]
        result = self.evaluate(repeat_findings={self.first: {self.again: missed}})
        self.assertEqual(result["pilot"]["outcome"], "incomplete")
        self.assertEqual(result["pilot"]["missing"]["unresolved"], {self.first: [self.again]})
        row = self.row(result)
        self.assertEqual((row["state"], row["cleanIntervals"]), ("partial", synthetic.INTERVALS - 1), "an unresolved interval is not clean")
        self.assertEqual(row["agreement"]["second_reviewer"]["byClass"]["missed_rally"], {"both": 0, "firstOnly": 0, "repeatOnly": 1})
        self.assertEqual(row["agreement"]["second_reviewer"]["byClass"]["clean"], {"both": 2, "firstOnly": 1, "repeatOnly": 0})
        self.assertEqual((row["agreement"]["second_reviewer"]["compared"], row["agreement"]["second_reviewer"]["identical"]), (3, 2))

        result = self.evaluate(repeat_findings={self.first: {self.again: missed}}, resolutions={self.first: {self.again: missed}})
        self.assertEqual((result["pilot"]["outcome"], result["pilot"]["m"]), ("pass", 1))
        self.assertEqual(self.row(result)["state"], "contaminated")
        result = self.evaluate(repeat_findings={self.first: {self.again: missed}}, resolutions={self.first: {self.again: []}})
        self.assertEqual((result["pilot"]["outcome"], result["pilot"]["m"], self.row(result)["state"]), ("pass", 0, "audited_clean"))

    def test_two_looks_differing_in_the_number_of_findings_disagree(self):
        one, two = [{"kind": "missed_rally"}], [{"kind": "missed_rally"}, {"kind": "missed_rally"}]
        result = self.evaluate(findings={self.first: {self.again: one}}, repeat_findings={self.first: {self.again: two}})
        self.assertEqual(result["pilot"]["missing"]["unresolved"], {self.first: [self.again]})

    def test_a_resolution_without_a_disagreement_is_not_taken(self):
        result = self.evaluate(resolutions={self.first: {self.again: [{"kind": "missed_rally"}]}})
        self.assertEqual((result["pilot"]["outcome"], result["pilot"]["m"]), ("pass", 0))
        self.assertIn("a resolution without a disagreement", " ".join(self.row(result)["problems"]))

    # records that cannot be used --------------------------------------------------------------------------------

    def test_a_record_for_another_draw_file_or_review_is_void(self):
        for overrides, fragment in (({"drawSha256": "0" * 64}, "drawSha256"), ({"drawId": "20260101-000000"}, "drawId"),
                                    ({"sourceFingerprint": "file:another-file"}, "sourceFingerprint"), ({"blindToPipeline": False}, "blindToPipeline"),
                                    ({"datasetName": "rc-other"}, "datasetName"), ({"annotationVersion": "coverage_audit_v1"}, "annotationVersion")):
            with self.subTest(fragment=fragment):
                synthetic.write_records(self.syn, self.draw_path)
                record = inv.load_json(self.syn.record_path(self.first), "record")
                synthetic.write_json(self.syn.record_path(self.first), {**record, **overrides})
                result = report.evaluate(self.draw_path, self.syn.project)
                row = self.row(result)
                self.assertEqual((row["record"], row["reviewed"], row["state"]), ("void", 0, "partial"))
                self.assertIn(f"record void: {fragment}", row["problems"][0])
                self.assertEqual(result["pilot"]["outcome"], "incomplete")
                self.assertFalse(row["suppliesTrustedNegatives"])

    def test_verdicts_that_are_not_accepted(self):
        def change(mutate):
            synthetic.write_records(self.syn, self.draw_path)
            record = inv.load_json(self.syn.record_path(self.first), "record")
            mutate(record["intervals"])
            synthetic.write_json(self.syn.record_path(self.first), record)
            return self.row(report.evaluate(self.draw_path, self.syn.project))

        f = self.free
        cases = (
            (lambda ivs: ivs[f].pop("playedAllAtMaxRate"), "the whole interval must have been played"),
            (lambda ivs: ivs[f].update(playedAllAtMaxRate=4.0), "the whole interval must have been played"),
            (lambda ivs: ivs[f].update(endTick=ivs[f]["endTick"] + 600), "are not the draw's"),
            (lambda ivs: ivs[f].update(verdict="not_clean"), "not_clean without a finding"),
            (lambda ivs: ivs[f].update(findings=[{"kind": "missed_rally"}]), "clean with findings"),
            (lambda ivs: ivs[f].update(verdict="not_clean", findings=[{"kind": "play_bleeds"}]), "finding kind 'play_bleeds'"),
            (lambda ivs: ivs[f].update(verdict="not_clean", findings=[{"kind": "uncertain"}]), "uncertain without a note"),
            (lambda ivs: ivs[f].update(verdict="not_clean", findings=[{"kind": "missed_rally", "edge": "leading"}]), "edge 'leading'"),
            (lambda ivs: ivs[f].update(verdict="not_clean", findings=[{"kind": "missed_rally", "approxStartSec": 9.0, "approxEndSec": 4.0}]), "approxEndSec before"),
            (lambda ivs: ivs[f].update(reviewer=" "), "no reviewer"),
            (lambda ivs: ivs[f].update(reviewedAt="yesterday"), "reviewedAt is not a UTC time"),
            (lambda ivs: ivs.append(dict(ivs[f])), f"interval {f} is recorded more than once"),
        )
        for mutate, fragment in cases:
            with self.subTest(fragment=fragment):
                row = change(mutate)
                self.assertEqual(row["notReviewed"], [f])
                self.assertIn(fragment, " ".join(row["problems"]))
        row = change(lambda ivs: ivs.append({**ivs[f], "index": 99}))
        self.assertEqual(row["notReviewed"], [])
        self.assertIn("interval 99 is not in the draw", row["problems"])

    def test_an_unreadable_record_stops_the_report(self):
        synthetic.write_records(self.syn, self.draw_path)
        with open(self.syn.record_path(self.first), "w") as fh:
            fh.write("{")
        with self.assertRaises(inv.AuditError) as cm:
            report.evaluate(self.draw_path, self.syn.project)
        self.assertIn("audit record unreadable", str(cm.exception))

    def test_marks_changed_between_the_draw_and_the_review_are_flagged(self):
        result = self.evaluate(marksSha256="f" * 64)
        self.assertTrue(all(r["marksChangedSinceDraw"] for r in result["pilot"]["recordings"]))
        self.assertIn("marks changed since the draw", report.render(result))

    # stage 2 and the command ------------------------------------------------------------------------------------

    def test_stage_2_adds_its_groups_to_the_trusted_negatives(self):
        synthetic.write_records(self.syn, self.draw_path)
        stage2_path = d.write_draw(d.build_stage2(self.inventory, self.draw_path, self.syn.project, self.protocol, now="2026-11-21T08:00:00Z"), self.out)
        result = report.evaluate(self.draw_path, self.syn.project, stage2_path)
        self.assertEqual(result["stage2"]["totals"]["notReviewed"], 140)
        self.assertEqual(result["trustedNegatives"]["groupCount"], 12)
        synthetic.write_records(self.syn, stage2_path)
        result = report.evaluate(self.draw_path, self.syn.project, stage2_path)
        self.assertEqual((result["stage2"]["totals"]["reviewed"], result["stage2"]["totals"]["states"]), (140, {"audited_clean": 10}))
        tn = result["trustedNegatives"]
        self.assertEqual((tn["groupCount"], tn["g6"]["groupsRequired"]), (18, 13))
        eligible_groups = {s["group"]: self.syn.fold[s["rid"]] for s in self.syn.specs if s["type"] == "continuous"}
        self.assertEqual(tn["groupsPerFold"], {str(f): sum(1 for fold in eligible_groups.values() if fold == f) for f in range(5)})
        self.assertEqual(sum(tn["groupsPerFold"].values()), 18)
        self.assertTrue(tn["g6"]["met"])
        self.assertEqual(result["pilot"]["outcome"], "pass", "the pilot's verdict is the pilot's alone")
        with self.assertRaises(inv.AuditError) as cm:
            report.evaluate(stage2_path, self.syn.project)
        self.assertIn("starts from the pilot draw", str(cm.exception))
        with self.assertRaises(inv.AuditError) as cm:
            report.evaluate(self.draw_path, self.syn.project, self.draw_path)
        self.assertIn("not the stage 2 draw that follows", str(cm.exception))

    def test_cli_exit_status_follows_the_outcome(self):
        text = io.StringIO()
        out = os.path.join(self.tmp, "report.json")
        with contextlib.redirect_stdout(text):
            self.assertEqual(report.main([self.draw_path, "--project", self.syn.project]), 1)
            synthetic.write_records(self.syn, self.draw_path)
            self.assertEqual(report.main([self.draw_path, "--project", self.syn.project, "--json-out", out]), 0)
            self.assertEqual(report.main([self.draw_path, "--project", self.syn.project, "--json-out", out]), 1)
            self.assertEqual(report.main([self.inventory, "--project", self.syn.project]), 1)
        printed = text.getvalue()
        self.assertIn("PILOT INCOMPLETE", printed)
        self.assertIn("no first verdict — " + self.first, printed)
        self.assertIn("PILOT PASS — m = 0 (0 missed rallies, 0 missed serves) of n = 144 rally marks", printed)
        self.assertIn("G6 needs 13 groups and 2 per fold — NOT met", printed)
        self.assertIn("never overwritten", printed)
        self.assertIn("not a coverage_audit_draw_v2 draw", printed)
        self.assertEqual(inv.load_json(out, "report")["pilot"]["outcome"], "pass")


if __name__ == "__main__":
    unittest.main()
