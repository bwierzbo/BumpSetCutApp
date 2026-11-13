"""Tests for scripts/desktop_training/withheld_closure.py — the closure file every trainer is given and
the check of a multi-frame package against it — and for the two places that must not get past it:
train_heatmap_model.py (needs torch, cv2 and numpy to import; skipped without them) and desktop.sh
(zsh; `ssh` and `scp` are replaced by stand-ins that record a call, and no test may cause one).
Everything is synthetic: no package, closure or project of the owner's is read, nothing is trained.

    python3 -m unittest scripts.tests.test_withheld_closure -v
"""

import contextlib
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
import zipfile
from pathlib import Path

DESKTOP = Path(__file__).resolve().parent.parent / "desktop_training"
sys.path.insert(0, str(DESKTOP))
import withheld_closure as wc  # noqa: E402

# Recordings of the package: name → (split, the fingerprint its card was registered with, its video's content, confirmed source).
RECORDINGS = {
    "bch_tri_sun_land_self_01":   ("train", "file:100:aa", "file:101:a1", None),
    "grs_ele_sun_land_self_01":   ("train", "file:200:bb", "file:201:b1", "IMG_0001"),
    "ind_gnd_dim_land_self_02":   ("val",   "youtube:abc", "file:301:c1", None),
}


def closure_block(names=("grs_extra_self_06",), source_ids=("IMG_0823",), fingerprints=("file:900:held", "file:901:held-content")) -> dict:
    block = {"names": sorted(names), "sourceIds": sorted(source_ids), "fingerprints": sorted(fingerprints)}
    return {**block, "closureSha256": wc.closure_sha256(block)}


class Fixture:
    """A lineage package as `--package-l2` leaves it (the parts a trainer reads: the window list and the
    record that names its recordings), a plain multi-frame package with no record, and a closure file."""

    def __init__(self, root: Path):
        self.root = root
        self.package = root / "Fixture-L2-multiframe-20261021-1917"
        self.package.mkdir()
        windows = "".join(json.dumps({"clip": clip, "split": split, "frames": [f"frames/{clip}/000001.jpg"]}) + "\n"
                          for clip, (split, _, _, _) in RECORDINGS.items() for _ in range(2))
        (self.package / "windows.jsonl").write_text(windows)
        eligible = [{"video": clip, "split": split, "packageSplit": split, "aliasGroup": clip, "reviewedFrames": 4, "ralliesMarked": True,
                     "identities": sorted([f"fp:{stored}"] + ([f"src:{source}"] if source else [f"src:{stored}"]))}
                    for clip, (split, stored, _, source) in RECORDINGS.items()]
        # A recording the plan allowed that has no labels: named in the record, absent from the package.
        eligible.append({"video": "bch_unlabeled_01", "split": "train", "packageSplit": "train", "identities": ["fp:file:400:dd"]})
        self.record = {"plan": {"lineage": "L2", "project": "Fixture", "eligible": eligible, "withheldClosure": ["grs_extra_self_06"],
                                "manifestHashes": {"projectJson": "a1" * 32, "sessions": "b2" * 32, "validationJson": "c3" * 32}},
                       "preflight": {"package": self.package.name, "passed": True, "digest": "d4" * 32,
                                     "windowsSha256": hashlib.sha256(windows.encode()).hexdigest(),
                                     "sourceFingerprints": {clip: content for clip, (_, _, content, _) in RECORDINGS.items()}}}
        self.write_record()
        self.closure = root / "closure.json"
        self.write_closure()

    def write_record(self) -> None:
        (self.package / "l2-manifest.json").write_text(json.dumps(self.record))

    def write_closure(self, block: dict = None) -> None:
        self.closure.write_text(json.dumps({**(block or closure_block()), "project": "Fixture", "createdAt": "2026-11-12T00:00:00Z",
                                            "splitManifest": {"projectJson": "a1" * 32, "sessions": "b2" * 32, "validationJson": "c3" * 32,
                                                              "manifestJson": "e5" * 32}}))

    def zipped(self, folder: Path = None) -> Path:
        folder = folder or self.package
        path = self.root / f"{folder.name}.zip"
        with zipfile.ZipFile(path, "w") as z:
            for f in sorted(folder.rglob("*")):
                z.write(f, f"{folder.name}/{f.relative_to(folder)}")
        return path

    def plain(self) -> Path:
        """A multi-frame package from the Models tab: windows, no record of what its recordings are."""
        folder = self.root / "Fixture-multiframe-20261016-2018"
        folder.mkdir()
        shutil.copy(self.package / "windows.jsonl", folder / "windows.jsonl")
        return folder

    def check(self, package: Path = None) -> dict:
        return wc.check_lineage_package(package or self.package, wc.load(self.closure))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="withheld-closure-"))
        self.f = Fixture(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def refused(self, package: Path = None) -> str:
        with self.assertRaises(wc.Refused) as cm:
            self.f.check(package)
        return str(cm.exception)


class PackageTests(Base):
    def test_a_lineage_package_clear_of_the_current_closure_is_admitted_as_a_folder_and_as_a_zip(self):
        for package in (self.f.package, self.f.zipped()):
            found = self.f.check(package)
            self.assertEqual(found["recordings"], 3)
            self.assertEqual(found["package"], self.f.package.name)
            self.assertEqual(found["digest"], "d4" * 32)
            self.assertEqual(found["record_sha256"], hashlib.sha256((self.f.package / "l2-manifest.json").read_bytes()).hexdigest())
        now = wc.load(self.f.closure)
        self.assertEqual((now["record"]["names"], now["record"]["sourceIds"], now["record"]["fingerprints"]), (1, 1, 2))
        self.assertEqual(now["record"]["createdAt"], "2026-11-12T00:00:00Z")

    def test_a_package_that_does_not_say_what_it_holds_is_refused(self):
        plain = self.f.plain()
        for package in (plain, self.f.zipped(plain)):
            why = self.refused(package)
            self.assertIn("no l2-manifest.json", why)
            self.assertIn("nothing is trained or scored from it", why)
        (plain / "l2-manifest.json").write_text("{not a record")
        self.assertIn("can't be read as a lineage package's record", self.refused(plain))
        (plain / "l2-manifest.json").write_text(json.dumps({"plan": {}}))
        self.assertIn("can't be read as a lineage package's record", self.refused(plain))
        self.assertIn("isn't a package folder or .zip", self.refused(self.tmp / "absent.zip"))

    def test_a_record_that_is_not_this_packages_is_refused(self):
        with open(self.f.package / "windows.jsonl", "a") as w:
            w.write(json.dumps({"clip": "bch_tri_sun_land_self_01", "split": "train"}) + "\n")
        self.assertIn("windows.jsonl is not the one l2-manifest.json was written for", self.refused())
        # A recording in the windows that the record does not name (the record rewritten to match the file's hash).
        with open(self.f.package / "windows.jsonl", "a") as w:
            w.write(json.dumps({"clip": "grs_extra_self_06", "split": "train"}) + "\n")
        self.f.record["preflight"]["windowsSha256"] = hashlib.sha256((self.f.package / "windows.jsonl").read_bytes()).hexdigest()
        self.f.write_record()
        self.assertIn("it holds grs_extra_self_06, which l2-manifest.json does not name", self.refused())

    def test_a_package_whose_preflight_did_not_pass_or_recorded_no_window_hash_is_refused(self):
        self.f.record["preflight"]["passed"] = False
        self.f.write_record()
        self.assertIn("its preflight did not pass", self.refused())
        self.f.record["preflight"]["passed"] = True
        del self.f.record["preflight"]["windowsSha256"]
        self.f.write_record()
        self.assertIn("the record does not describe these windows", self.refused())

    def test_a_recording_without_a_source_fingerprint_in_the_record_is_refused(self):
        del self.f.record["preflight"]["sourceFingerprints"]["ind_gnd_dim_land_self_02"]
        self.f.write_record()
        self.assertIn("it holds ind_gnd_dim_land_self_02, which l2-manifest.json does not name with a source fingerprint", self.refused())

    def test_a_package_holding_a_recording_withheld_since_it_was_built_is_refused_by_every_identity(self):
        # The package's own record says nothing of it: the three D-036 copies were train clips of a package whose
        # preflight passed. Only the closure as it is now can tell.
        cases = {"name": (closure_block(names=("grs_extra_self_06", "grs_ele_sun_land_self_01")), "its name"),
                 "confirmed source": (closure_block(source_ids=("IMG_0823", "IMG_0001")), "its sourceId"),
                 "registered file": (closure_block(fingerprints=("file:900:held", "file:200:bb")), "its fp identity file:200:bb"),
                 "content": (closure_block(fingerprints=("file:900:held", "file:201:b1")), "its content")}
        for case, (block, expect) in cases.items():
            self.f.write_closure(block)
            for package in (self.f.package, self.f.zipped()):
                why = self.refused(package)
                self.assertIn("it holds grs_ele_sun_land_self_01, which is withheld now", why, case)
                self.assertIn(expect, why, case)
                self.assertIn("build a new one", why)
        # An inferred source is the card's fingerprint under another key: still a file identity.
        self.f.write_closure(closure_block(fingerprints=("youtube:abc",)))
        self.assertIn("it holds ind_gnd_dim_land_self_02, which is withheld now", self.refused())
        # A recording the record names but the package does not hold is no reason to refuse it.
        self.f.write_closure(closure_block(names=("bch_unlabeled_01",)))
        self.assertEqual(self.f.check()["recordings"], 3)

    def test_a_missing_unreadable_empty_or_edited_closure_file_is_refused(self):
        self.f.closure.unlink()
        why = self.refused()
        self.assertIn("can't be read", why)
        self.assertIn("--withheld-closure", why, "the refusal says how to write one")
        self.f.closure.write_text("{not json")
        self.assertIn("can't be read", self.refused())
        self.f.closure.write_text("[]")
        self.assertIn("no withheld closure", self.refused())
        self.f.write_closure(closure_block(names=(), source_ids=(), fingerprints=()))
        self.assertIn("the withheld closure is empty", self.refused(), "no closure is never 'nothing withheld'")
        edited = closure_block()
        edited["names"].append("added_by_hand")
        self.f.write_closure(edited)
        self.assertIn("closureSha256 does not match", self.refused())
        with self.assertRaises(wc.Refused):
            wc.load(None)

    def test_the_command_says_yes_or_why_not(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(wc.main([str(self.f.package), "--withheld", str(self.f.closure)]), 0)
            self.assertEqual(wc.main([str(self.f.plain()), "--withheld", str(self.f.closure)]), 1)
            self.assertEqual(wc.main([str(self.f.package), "--withheld", str(self.tmp / "absent.json")]), 1)
        self.assertIn("3 recordings, none in the withheld closure", out.getvalue())
        self.assertIn("no l2-manifest.json", err.getvalue())
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            wc.main([str(self.f.package)])   # no closure file given at all


try:
    import train_heatmap_model as heat
except (ImportError, SystemExit):   # the trainer needs torch, cv2 and numpy to import (the desktop, the Mac)
    heat = None


@unittest.skipIf(heat is None, "train_heatmap_model.py can't be imported here (torch, opencv-python and numpy)")
class HeatTrainerTests(Base):
    """The trainer stops at the gate: every case here is refused before a zip is opened, a model is
    built or anything is downloaded, so nothing is trained."""

    def run_trainer(self, *argv: str) -> str:
        out = io.StringIO()
        with unittest.mock.patch.object(sys, "argv", ["train_heatmap_model.py", *argv]), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(out), unittest.mock.patch.object(heat, "unpack", side_effect=AssertionError("unpacked")), \
                unittest.mock.patch.object(heat, "vballnet_source", side_effect=AssertionError("went on to build the model")):
            with self.assertRaises(SystemExit) as cm:
                heat.main()
        self.assertNotEqual(cm.exception.code, 0)
        return out.getvalue()

    def test_no_closure_file_no_run(self):
        self.assertIn("--withheld", self.run_trainer(str(self.f.package)))
        self.assertIn("can't be read", self.run_trainer(str(self.f.package), "--withheld", str(self.tmp / "absent.json")))

    def test_a_package_without_a_record_is_not_trained_or_scored(self):
        plain = self.f.plain()
        self.assertIn("no l2-manifest.json", self.run_trainer(str(plain), "--withheld", str(self.f.closure)))
        self.assertIn("no l2-manifest.json", self.run_trainer(str(self.f.zipped(plain)), "--withheld", str(self.f.closure),
                                                              "--score-only", str(self.tmp / "best.pt")))

    def test_a_package_holding_a_withheld_recording_is_not_trained_scored_or_resumed(self):
        self.f.write_closure(closure_block(fingerprints=("file:900:held", "file:201:b1")))
        for more in ((), ("--score-only", str(self.tmp / "best.pt")), ("--resume",)):
            why = self.run_trainer(str(self.f.package), "--withheld", str(self.f.closure), *more)
            self.assertIn("grs_ele_sun_land_self_01, which is withheld now", why)

    def test_a_clear_package_gets_past_the_gate(self):
        try:
            import onnx  # noqa: F401  (the trainer stops without it, after the gate)
        except ImportError:
            self.skipTest("onnx is not installed")
        out = io.StringIO()
        with unittest.mock.patch.object(sys, "argv", ["train_heatmap_model.py", str(self.f.package), "--withheld", str(self.f.closure)]), \
                contextlib.redirect_stdout(out), unittest.mock.patch.object(heat, "vballnet_source", side_effect=KeyboardInterrupt("past the gate")):
            with self.assertRaises(KeyboardInterrupt):
                heat.main()


@unittest.skipUnless(shutil.which("zsh"), "desktop.sh is a zsh script")
class DesktopScriptTests(Base):
    """desktop.sh decides on the Mac, before the desktop is contacted. `ssh` and `scp` are stand-ins
    that leave a mark when called: no refusal may reach them, and no test here lets a run start."""

    def setUp(self):
        super().setUp()
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.mark = self.tmp / "contacted"
        for tool in ("ssh", "scp"):
            (self.bin / tool).write_text(f"#!/bin/sh\necho \"$0 $@\" >> '{self.mark}'\nexit 1\n")
            (self.bin / tool).chmod(0o755)
        # HOME is the fixture's, so "the newest export" is looked for under it and never in a real project.
        self.exports = self.tmp / "home" / "Movies" / "RallyLab" / "Projects" / "Fixture" / "exports"
        self.exports.mkdir(parents=True)
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": str(self.tmp / "home"), "RALLYLAB_PROJECT": "Fixture",
                    "RALLYLAB_STAGING_MOUNT": str(self.tmp / "staging")}

    def desktop(self, *argv: str) -> subprocess.CompletedProcess:
        return subprocess.run(["zsh", str(DESKTOP / "desktop.sh"), *argv], env=self.env, capture_output=True, text=True, timeout=120)

    def assert_refused(self, done: subprocess.CompletedProcess, expect: str) -> None:
        self.assertNotEqual(done.returncode, 0, done.stdout)
        self.assertIn(expect, done.stdout + done.stderr)
        self.assertFalse(self.mark.exists(), "the desktop was contacted")

    def test_no_closure_file_nothing_is_sent_or_started(self):
        package = self.f.zipped()
        for command in ("train", "queue", "run", "plan"):
            self.assert_refused(self.desktop(command, str(package)), "--withheld CLOSURE.json is required")
        self.assert_refused(self.desktop("train", str(package), "--withheld", str(self.tmp / "absent.json")), "no such file")

    def test_the_newest_export_is_not_picked_without_the_check(self):
        # The newest zip in the project's exports is a plain package (as Scratch-multiframe-20261016-2018.zip is).
        plain = self.f.zipped(self.f.plain())
        shutil.move(plain, self.exports / plain.name)
        for command in ("train", "queue"):
            done = self.desktop(command, "--withheld", str(self.f.closure))
            self.assert_refused(done, "no l2-manifest.json")
            self.assertIn("Nothing was sent or started", done.stderr)

    def test_a_package_holding_a_withheld_recording_is_not_sent(self):
        self.f.write_closure(closure_block(names=("grs_extra_self_06", "grs_ele_sun_land_self_01")))
        for command in ("train", "queue", "plan"):
            self.assert_refused(self.desktop(command, str(self.f.zipped()), "--withheld", str(self.f.closure)),
                                "grs_ele_sun_land_self_01, which is withheld now")

    def test_a_clear_package_is_planned_with_the_closure_the_trainer_will_be_given(self):
        done = self.desktop("plan", str(self.f.zipped()), "--withheld", str(self.f.closure), "--name", "fixture_run")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("3 recordings, none in the withheld closure", done.stdout)
        self.assertIn("--withheld C:\\BallTraining\\fixture_run.withheld.json", done.stdout)
        self.assertFalse(self.mark.exists(), "plan contacts nothing")


if __name__ == "__main__":
    unittest.main()
