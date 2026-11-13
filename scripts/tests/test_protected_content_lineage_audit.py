"""Tests for scripts/content_lineage/protected_audit.py on a synthetic project: which protected
recordings a scope may open, that each access is on the log before the file is opened, that
everything else stays closed, and that the result is proposals only. Standard library only.

    python3 -m unittest scripts.tests.test_protected_content_lineage_audit -v
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "content_lineage"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audit as a  # noqa: E402
import protected_audit as p  # noqa: E402
from test_content_lineage_audit import Scene, media  # noqa: E402

AUTH = "docs/decisions/2026-11-12-d036-completion-authorization.md §6"


def scope(*names, **more):
    return {"authorization": AUTH, "purpose": p.PURPOSE, "recordings": [{"name": n, "reason": "check for copies"} for n in names], **more}


class Fixture(unittest.TestCase):
    """trn_a, trn_b, dev_a ordinary; hold_a (lineage holdout) and its confirmed alias hold_copy; legacy_a;
    final_a, cand_a and final_alias (a train row sharing a confirmed sourceId with final_a); `unlisted`
    has a card and no manifest row."""

    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="protected-lineage-")
        self.project = os.path.join(self.base, "Project")
        self.out = os.path.join(self.base, "out")
        os.makedirs(os.path.join(self.project, "manifests"))
        rows = [("trn_a", "train", None), ("trn_b", "train", None), ("dev_a", "dev_val", None),
                ("hold_a", "lineage_holdout", "IMG_1"), ("hold_copy", "lineage_holdout", "IMG_1"), ("legacy_a", "legacy_holdout", None),
                ("final_a", "final_test", "IMG_9"), ("cand_a", "final_test_candidate", None), ("final_alias", "train", "IMG_9")]
        with open(os.path.join(self.project, "manifests", "manifest.json"), "w") as f:
            json.dump({"videos": [{"video": v, "split": s, "fingerprint": "file:" + v,
                                   "sourceId": {"origin": "confirmed", "value": src} if src else {"origin": "unknown"}}
                                  for v, s, src in rows]}, f)
        cards = [{"id": v, "videos": [{"kind": "file", "origin": f"/orig/{v}.mov", "fingerprint": "file:" + v, "start": 0, "length": 10,
                                       "clipFile": os.path.join(self.base, "footage", v + ".mp4"), **({"sourceId": src} if src else {})}]}
                 for v, _, src in rows]
        cards.append({"id": "unlisted", "videos": [{"kind": "file", "origin": "/orig/u.mov", "fingerprint": "file:U", "start": 0, "length": 10,
                                                    "clipFile": os.path.join(self.base, "footage", "unlisted.mp4")}]})
        with open(os.path.join(self.project, "project.json"), "w") as f:
            json.dump({"clips": cards}, f)
        os.makedirs(os.path.join(self.base, "footage"))
        for v in [r[0] for r in rows] + ["unlisted"]:
            with open(os.path.join(self.base, "footage", v + ".mp4"), "w") as f:
                f.write(v)
        # What each file "shows": hold_copy is hold_a's footage re-encoded (noise), trn_b an excerpt of legacy_a.
        hold = Scene(seed=1).frames(240)
        legacy = Scene(seed=2).frames(240)
        self.footage = {"hold_a": media("hold_a", hold), "hold_copy": media("hold_copy", hold, noise_seed=5),
                        "legacy_a": media("legacy_a", legacy), "trn_b": media("trn_b", legacy[40:200], noise_seed=6),
                        "trn_a": media("trn_a", Scene(seed=3).frames(240)), "dev_a": media("dev_a", Scene(seed=4).frames(240))}
        self.opened = []
        self.log_at_open = {}
        self.real = a.media_from_file

        def fake(name, path, cache_dir=None, **meta):
            self.opened.append(name)
            log = os.path.join(self.out, "access-log.jsonl")
            self.log_at_open[name] = []
            if os.path.exists(log):
                with open(log) as f:
                    self.log_at_open[name] = [json.loads(line) for line in f]
            if name not in self.footage:
                raise a.ReadError(f"{path}: cannot be decoded")
            m = self.footage[name]
            return a.Media(name=name, full=m.full, centre=m.centre, sha256="sha-" + name, **meta)
        a.media_from_file = fake

    def tearDown(self):
        a.media_from_file = self.real
        shutil.rmtree(self.base, ignore_errors=True)

    def log(self):
        with open(os.path.join(self.out, "access-log.jsonl")) as f:
            return [json.loads(line) for line in f]


class Scope(Fixture):
    def test_a_scope_needs_an_authorization_the_one_purpose_and_a_reason_for_every_recording(self):
        path = os.path.join(self.base, "scope.json")
        for bad in ({**scope("hold_a"), "authorization": " "}, {**scope("hold_a"), "purpose": "model evaluation"}, scope(),
                    {**scope(), "recordings": [{"name": "hold_a"}]}, {**scope(), "recordings": [{"name": "hold_a", "reason": " "}]},
                    scope("hold_a", "hold_a")):
            with open(path, "w") as f:
                json.dump(bad, f)
            with self.assertRaises(p.ScopeError, msg=bad):
                p.load_scope(path)
        with open(path, "w") as f:
            json.dump(scope("hold_a", "legacy_a"), f)
        self.assertEqual([r["name"] for r in p.load_scope(path)["recordings"]], ["hold_a", "legacy_a"])

    def test_only_lineage_and_legacy_holdouts_and_their_aliases_can_be_named(self):
        planned = p.plan(self.project, scope("hold_a", "hold_copy", "legacy_a"))
        self.assertEqual([r["name"] for r in planned["open"]], ["hold_a", "hold_copy", "legacy_a"])
        self.assertEqual([r["name"] for r in planned["against"]], ["dev_a", "trn_a", "trn_b"])
        self.assertEqual([r["name"] for r in planned["closed"]], ["cand_a", "final_a", "final_alias", "unlisted"])
        for name, why in (("trn_a", "not withheld"), ("nobody", "not a recording"), ("unlisted", "not in the split manifest"),
                          ("final_a", "final test"), ("cand_a", "final test"), ("final_alias", "final test")):
            with self.assertRaises(p.ScopeError) as caught:
                p.plan(self.project, scope("hold_a", name))
            self.assertIn(why, str(caught.exception), name)

    def test_a_scope_that_reaches_outside_opens_nothing_and_logs_nothing(self):
        with self.assertRaises(p.ScopeError):
            p.run(self.project, scope("hold_a", "final_a"), self.out, log=lambda _: None)
        self.assertEqual(self.opened, [])
        self.assertFalse(os.path.exists(os.path.join(self.out, "access-log.jsonl")))

    def test_a_final_test_recording_listed_only_in_validation_json_is_outside_too(self):
        os.makedirs(os.path.join(self.project, "pipeline_tuning"))
        with open(os.path.join(self.project, "pipeline_tuning", "validation.json"), "w") as f:
            json.dump({"holdout": [], "finalTest": [], "finalTestCandidates": ["legacy_a"]}, f)
        with self.assertRaises(p.ScopeError):
            p.plan(self.project, scope("legacy_a"))


class Run(Fixture):
    def test_every_protected_file_is_on_the_log_before_it_is_opened(self):
        p.run(self.project, scope("hold_a", "hold_copy", "legacy_a"), self.out, log=lambda _: None)
        for name in ("hold_a", "hold_copy", "legacy_a"):
            before = self.log_at_open[name]
            mine = [e for e in before if e.get("name") == name]
            self.assertEqual([e["event"] for e in mine], ["open"], name)
            self.assertEqual(mine[0]["authorization"], AUTH)
            self.assertEqual(mine[0]["reason"], "check for copies")
            self.assertTrue(mine[0]["protectedBecause"].startswith("reserved ("), mine[0])
            self.assertIn("no model run", mine[0]["operation"])
            self.assertEqual(before[0]["event"], "run")
            self.assertEqual(before[0]["configuration"]["SIGNATURE_VERSION"], a.SIGNATURE_VERSION)
            self.assertIn("protected_audit.py", before[0]["tool"]["sha256"])
        events = [(e["event"], e.get("name")) for e in self.log()]
        self.assertEqual(events, [("run", None), ("open", "hold_a"), ("read", "hold_a"), ("open", "hold_copy"), ("read", "hold_copy"),
                                  ("open", "legacy_a"), ("read", "legacy_a"), ("done", None)])
        self.assertEqual([e["sha256"] for e in self.log() if e["event"] == "read"], ["sha-hold_a", "sha-hold_copy", "sha-legacy_a"])

    def test_what_is_not_named_is_never_opened(self):
        report = p.run(self.project, scope("hold_a"), self.out, log=lambda _: None)
        self.assertEqual(sorted(self.opened), ["dev_a", "hold_a", "trn_a", "trn_b"])
        self.assertEqual([r["name"] for r in report["opened"]], ["hold_a"])
        self.assertEqual([r["name"] for r in report["notOpened"]], ["cand_a", "final_a", "final_alias", "hold_copy", "legacy_a", "unlisted"])
        self.assertEqual(report["comparedAgainst"], ["dev_a", "trn_a", "trn_b"])

    def test_copies_of_protected_footage_are_proposed_and_only_proposed(self):
        report = p.run(self.project, scope("hold_a", "hold_copy", "legacy_a"), self.out, log=lambda _: None)
        copies = {(x["a"], x["b"]): x for x in report["proposals"] if x["relation"] != "similar_scene"}
        self.assertEqual(sorted(copies), [("hold_a", "hold_copy"), ("legacy_a", "trn_b")])
        self.assertEqual(copies[("hold_a", "hold_copy")]["relation"], "re_encoded_duplicate")
        self.assertEqual(copies[("legacy_a", "trn_b")]["relation"], "excerpt")
        self.assertEqual(copies[("legacy_a", "trn_b")]["splits"], ["legacy_holdout", "train"])
        self.assertEqual(copies[("legacy_a", "trn_b")]["protected"], [True, False])
        self.assertTrue(all(x["status"] == "proposed" for x in report["proposals"]))
        self.assertTrue(all(any(x["protected"]) for x in report["proposals"]), "pairs of two ordinary recordings are the ordinary audit's")
        with open(os.path.join(self.out, "protected-content-lineage-proposals.json")) as f:
            written = json.load(f)
        self.assertEqual(written["schemaVersion"], p.SCHEMA_VERSION)
        self.assertEqual(written["authorization"], AUTH)

    def test_nothing_is_written_under_the_project(self):
        def listing():
            return sorted((os.path.join(d, f), os.path.getmtime(os.path.join(d, f))) for d, _, fs in os.walk(self.project) for f in fs)
        before = listing()
        p.run(self.project, scope("hold_a"), self.out, log=lambda _: None)
        self.assertEqual(listing(), before)
        with self.assertRaises(p.ScopeError):
            p.run(self.project, scope("hold_a"), os.path.join(self.project, "audit-out"), log=lambda _: None)
        self.assertEqual(listing(), before)

    def test_a_protected_file_that_cannot_be_read_is_logged_and_not_cleared(self):
        del self.footage["legacy_a"]
        report = p.run(self.project, scope("hold_a", "legacy_a"), self.out, log=lambda _: None)
        self.assertEqual([r["name"] for r in report["notRead"]], ["legacy_a"])
        self.assertEqual([(e["event"], e["name"]) for e in self.log() if e.get("name") == "legacy_a"], [("open", "legacy_a"), ("failed", "legacy_a")])
        os.remove(os.path.join(self.base, "footage", "hold_a.mp4"))
        self.opened.clear()
        report = p.run(self.project, scope("hold_a"), self.out, log=lambda _: None)
        self.assertNotIn("hold_a", self.opened)
        self.assertEqual(report["notRead"], [{"name": "hold_a", "why": "no video here"}])

    def test_the_log_is_appended_to_by_a_second_run(self):
        p.run(self.project, scope("hold_a"), self.out, log=lambda _: None)
        first = self.log()
        p.run(self.project, scope("hold_a"), self.out, log=lambda _: None)
        self.assertEqual(self.log()[:len(first)], first)
        self.assertEqual([e["event"] for e in self.log()].count("run"), 2)

    def test_the_cut_history_pair_says_what_the_pictures_found(self):
        real = a.cut_history_relations
        a.cut_history_relations = lambda project, origins, **kw: [
            {"a": "hold_a", "b": "hold_copy", "relation": "same_source_overlap", "evidence": {"original": "IMG_1", "sharedSec": 60.0}},
            {"a": "legacy_a", "b": "trn_a", "relation": "same_source_overlap", "evidence": {"original": "IMG_2", "sharedSec": 30.0}},
            {"a": "dev_a", "b": "trn_a", "relation": "same_source_overlap", "evidence": {"original": "IMG_3", "sharedSec": 30.0}},
            {"a": "hold_a", "b": "final_a", "relation": "same_source_overlap", "evidence": {"original": "IMG_4", "sharedSec": 30.0}}]
        try:
            report = p.run(self.project, scope("hold_a", "hold_copy", "legacy_a"), self.out, log=lambda _: None)
        finally:
            a.cut_history_relations = real
        self.assertEqual({(r["a"], r["b"]): r["pictures"] for r in report["cutHistory"]},
                         {("hold_a", "hold_copy"): "re_encoded_duplicate", ("legacy_a", "trn_a"): "no relation found by the pictures",
                          ("hold_a", "final_a"): "not compared (one of the two was not read)"})


class OrdinaryAuditStillRefuses(Fixture):
    def test_the_ordinary_audit_opens_no_protected_recording(self):
        report = a.run_project(self.project, self.out, exclude=set(), only=None, log=lambda _: None)
        self.assertEqual(sorted(self.opened), ["dev_a", "trn_a", "trn_b"])
        self.assertEqual({r["name"] for r in report["refused"]}, {"hold_a", "hold_copy", "legacy_a", "final_a", "cand_a", "final_alias", "unlisted"})


if __name__ == "__main__":
    unittest.main()
