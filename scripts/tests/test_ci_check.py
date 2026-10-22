"""Tests for scripts/ci_check.py. Each test builds a throwaway git repository.

    python3 -m unittest discover -s scripts/tests -v
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ci_check  # noqa: E402

LOG = textwrap.dedent("""\
    ---
    name: decision-log
    ---

    # Decision log

    | ID | Status |
    |---|---|
    | D-001 | accepted |
    | D-002 | accepted |

    ---

    ### D-001

    **First** — 2026-10-20 — accepted — owner.

    **Decision.** Do the first thing.

    ### D-002

    **Second** — 2026-10-20 — accepted — owner.

    **Decision.** Do the second thing.
    """)

NOTE = "# Owner note\n\nVerbatim.\n"
EXP_RUNNING = "---\nid: EXP-20261020-a\nstatus: running\n---\n\n# A\n"
EXP_DONE = "---\nid: EXP-20261020-b\nstatus: done\n---\n\n# B\n"


def sha(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def registry(extra_items: str = "", note_sha: str | None = None, families: str | None = None) -> str:
    fam = families if families is not None else textwrap.dedent("""\
        [[family]]
        id = "CF-T-001"
        name = "Owner notes"
        type = "decision-record"
        patterns = ["docs/decisions/????-??-??-*.md"]
        lifecycle = "active"
        change_class = "frozen"
        approval = "owner"

        [[family]]
        id = "CF-T-002"
        name = "Experiment records"
        type = "experiment-record"
        patterns = ["docs/experiments/EXP-*.md"]
        lifecycle = "active"
        change_class = "living"
        approval = "owner"
        freeze_when = { field = "status", pattern = '^(done|abandoned)\\b' }
        """)
    return textwrap.dedent(f"""\
        schema = 1
        project = "Test"
        item_prefix = "CI-T"
        family_prefix = "CF-T"
        controlled_roots = ["docs/"]

        [[item]]
        id = "CI-T-001"
        name = "Registry"
        type = "registry"
        path = "docs/config-items.toml"
        lifecycle = "active"
        change_class = "living"
        approval = "owner"

        [[item]]
        id = "CI-T-002"
        name = "Decision log"
        type = "decision-log"
        path = "docs/decisions/DECISION_LOG.md"
        lifecycle = "active"
        change_class = "append-only"
        approval = "owner"
        entry_pattern = '^### (D-\\d{{3}})\\s*$'
        status_pattern = '^\\*\\*.+?\\*\\* — \\d{{4}}-\\d{{2}}-\\d{{2}} — (?P<status>.+?) — '
        status_note_pattern = '^\\*\\*(?:Status \\d{{4}}-\\d{{2}}-\\d{{2}}|Amendment \\([^)]*\\d{{4}}-\\d{{2}}-\\d{{2}}\\))\\.\\*\\*'

        [[item]]
        id = "CI-T-003"
        name = "Phase 0 owner note"
        type = "decision-record"
        path = "docs/decisions/2026-10-20-owner.md"
        lifecycle = "historical"
        change_class = "frozen"
        approval = "owner"
        decisions = ["D-001"]
        frozen_sha256 = "{note_sha or sha(NOTE)}"

        [[item]]
        id = "CI-T-004"
        name = "Model lineages"
        type = "model-lineage"
        path = "docs/LINEAGES.md"
        lifecycle = "active"
        change_class = "living"
        approval = "owner"
        triggers = ["src/train.py"]

        [[item]]
        id = "CI-T-005"
        name = "Index"
        type = "index"
        path = "docs/README.md"
        lifecycle = "active"
        change_class = "living"
        approval = "none"

        [[item]]
        id = "CI-T-006"
        name = "Manifest"
        type = "dataset-manifest"
        path = "docs/manifest.json"
        lifecycle = "active"
        change_class = "living"
        approval = "none"
        generated_by = "tool --audit-dataset"
        {extra_items}
        {fam}""")


BASE_FILES = {
    "docs/decisions/DECISION_LOG.md": LOG,
    "docs/decisions/2026-10-20-owner.md": NOTE,
    "docs/decisions/2026-10-19-older.md": "# Older note\n",
    "docs/LINEAGES.md": "# Lineages\n",
    "docs/README.md": "# Index\n",
    "docs/manifest.json": "{}\n",
    "docs/experiments/EXP-20261020-a.md": EXP_RUNNING,
    "docs/experiments/EXP-20261020-b.md": EXP_DONE,
    "src/train.py": "print('train')\n",
}


class Repo:
    def __init__(self):
        self.path = tempfile.mkdtemp(prefix="ci-check-")
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "t")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.path, check=True,
                              capture_output=True, text=True).stdout

    def write(self, files):
        for rel, text in files.items():
            full = os.path.join(self.path, rel)
            if text is None:
                os.remove(full)
                continue
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8") as fh:
                fh.write(text)

    def commit(self, files, msg="c"):
        self.write(files)
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", msg)
        return self.git("rev-parse", "HEAD").strip()

    def close(self):
        shutil.rmtree(self.path, ignore_errors=True)


class Base(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()
        self.base = self.repo.commit({**BASE_FILES, "docs/config-items.toml": registry()}, "base")
        self.repo.git("checkout", "-q", "-b", "pr")

    def tearDown(self):
        self.repo.close()

    def check(self, files, body=""):
        self.repo.commit(files)
        return ci_check.run_check(self.repo.path, self.base, "HEAD", body)

    def assertCode(self, report, level, code):
        self.assertIn(code, report.codes(level), ci_check.render(report, "t"))

    def assertNoErrors(self, report):
        self.assertEqual(report.codes("error"), [], ci_check.render(report, "t"))


class RegistryValidity(Base):
    def test_base_registry_is_clean(self):
        report = ci_check.run_audit(self.repo.path, self.base)
        self.assertEqual(report.findings, [], ci_check.render(report, "t"))

    def test_living_edit_passes_with_attention(self):
        r = self.check({"docs/LINEAGES.md": "# Lineages\n\nL2.\n"},
                       "### Owner approval requested\n- CI-T-004 lineages\n")
        self.assertNoErrors(r)
        self.assertCode(r, "attention", "OWNER-APPROVAL")

    def test_unlisted_owner_item_warns(self):
        r = self.check({"docs/LINEAGES.md": "# Lineages\n\nL2.\n"}, "no list")
        self.assertCode(r, "warning", "ATTENTION-UNLISTED")

    def test_duplicate_id_unknown_key_bad_enum(self):
        extra = textwrap.dedent("""\
            [[item]]
            id = "CI-T-005"
            name = "Dup"
            type = "nonsense"
            path = "docs/README.md"
            lifecycle = "active"
            change_class = "living"
            approval = "none"
            colour = "blue"
            """)
        r = self.check({"docs/config-items.toml": registry(extra)})
        for code in ("REGISTRY-DUPLICATE", "REGISTRY-ENUM", "REGISTRY-KEY"):
            self.assertCode(r, "error", code)

    def test_missing_path_and_unknown_decision(self):
        extra = textwrap.dedent("""\
            [[item]]
            id = "CI-T-009"
            name = "Ghost"
            type = "plan"
            path = "docs/GHOST.md"
            lifecycle = "active"
            change_class = "living"
            approval = "none"
            decisions = ["D-404", "D-1"]
            """)
        r = self.check({"docs/config-items.toml": registry(extra)})
        self.assertCode(r, "error", "REGISTRY-MISSING")
        self.assertCode(r, "error", "REGISTRY-REF")
        messages = " ".join(f.message for f in r.of("error"))
        self.assertIn("D-404 is not in the decision log", messages)
        self.assertIn("'D-1' is not D-NNN", messages)

    def test_planned_item_needs_no_path(self):
        extra = textwrap.dedent("""\
            [[item]]
            id = "CI-T-010"
            name = "Screenshots"
            type = "app-store-screenshot-set"
            lifecycle = "planned"
            change_class = "living"
            approval = "owner"
            sources = ["src/train.py"]
            triggers = ["src/**"]
            """)
        r = self.check({"docs/config-items.toml": registry(extra), "src/train.py": "x\n"},
                       "### Owner approval requested\n- CI-T-001\n- CI-T-004: no update needed — test\n")
        self.assertNoErrors(r)
        self.assertNotIn("CI-T-010", " ".join(f.message for f in r.of("warning")))

    def test_overlapping_families_error(self):
        extra_family = textwrap.dedent("""\
            [[family]]
            id = "CF-T-003"
            name = "All docs"
            type = "plan"
            patterns = ["docs/decisions/*.md"]
            lifecycle = "active"
            change_class = "living"
            approval = "none"
            """)
        base_families = registry().split("[[family]]", 1)[1]
        r = self.check({"docs/config-items.toml": registry(families="[[family]]" + base_families + "\n" + extra_family)})
        self.assertCode(r, "error", "REGISTRY-OVERLAP")

    def test_invalid_toml(self):
        r = self.check({"docs/config-items.toml": "schema = = 1\n"})
        self.assertCode(r, "error", "REGISTRY-PARSE")

    def test_registry_deleted(self):
        r = self.check({"docs/config-items.toml": None})
        self.assertCode(r, "error", "REGISTRY-REMOVED")


class FrozenRecords(Base):
    def test_frozen_edit_is_error(self):
        r = self.check({"docs/decisions/2026-10-20-owner.md": NOTE + "edit\n"})
        self.assertCode(r, "error", "FROZEN-CHANGED")
        self.assertCode(r, "error", "FROZEN-HASH")

    def test_repinning_the_hash_in_the_same_pr_is_still_an_error(self):
        edited = NOTE + "quietly changed\n"
        r = self.check({"docs/decisions/2026-10-20-owner.md": edited,
                        "docs/config-items.toml": registry(note_sha=sha(edited))},
                       "### Owner approval requested\n- CI-T-003\n")
        self.assertCode(r, "error", "FROZEN-CHANGED")
        self.assertCode(r, "error", "FROZEN-REGISTRY")
        self.assertNotIn("FROZEN-HASH", r.codes("error"))  # head is self-consistent; base rules still bite

    def test_reclassifying_a_frozen_record_is_an_error(self):
        reg = registry().replace('change_class = "frozen"\n        approval = "owner"\n        decisions = ["D-001"]',
                                 'change_class = "living"\n        approval = "owner"\n        decisions = ["D-001"]')
        reg = reg.replace(f'frozen_sha256 = "{sha(NOTE)}"', "")
        self.assertNotEqual(reg, registry())
        r = self.check({"docs/config-items.toml": reg, "docs/decisions/2026-10-20-owner.md": NOTE + "x\n"})
        self.assertCode(r, "error", "FROZEN-REGISTRY")
        self.assertCode(r, "error", "FROZEN-CHANGED")

    def test_removing_a_frozen_record_from_the_registry_is_an_error(self):
        reg = registry()
        start = reg.rindex("[[item]]", 0, reg.index('id = "CI-T-003"'))
        end = reg.index("[[item]]", start + 1)
        r = self.check({"docs/config-items.toml": reg[:start] + reg[end:]})
        self.assertCode(r, "error", "FROZEN-UNREGISTERED")

    def test_renaming_a_frozen_file_is_an_error(self):
        r = self.check({"docs/decisions/2026-10-20-owner.md": None,
                        "docs/decisions/2026-10-20-owner-renamed.md": NOTE})
        self.assertCode(r, "error", "FROZEN-CHANGED")

    def test_frozen_family_member_edit_is_an_error(self):
        r = self.check({"docs/decisions/2026-10-19-older.md": "# Older note, edited\n"})
        self.assertCode(r, "error", "FROZEN-CHANGED")

    def test_narrowing_a_frozen_family_does_not_unprotect_its_members(self):
        reg = registry().replace('patterns = ["docs/decisions/????-??-??-*.md"]',
                                 'patterns = ["docs/decisions/2099-*.md"]')
        r = self.check({"docs/config-items.toml": reg,
                        "docs/decisions/2026-10-19-older.md": "# Older note, edited\n"})
        self.assertCode(r, "error", "FROZEN-REGISTRY")
        self.assertCode(r, "error", "FROZEN-CHANGED")

    def test_new_family_member_is_allowed(self):
        r = self.check({"docs/decisions/2026-10-22-new.md": "# New owner note\n"},
                       "### Owner approval requested\n- `docs/decisions/2026-10-22-new.md`\n")
        self.assertNoErrors(r)
        self.assertCode(r, "attention", "FROZEN-NEW")

    def test_freeze_when_status_done(self):
        r = self.check({"docs/experiments/EXP-20261020-b.md": EXP_DONE + "rewrite\n",
                        "docs/experiments/EXP-20261020-a.md": EXP_RUNNING + "progress\n"})
        frozen = [f for f in r.of("error") if f.code == "FROZEN-CHANGED"]
        self.assertEqual(len(frozen), 1, ci_check.render(r, "t"))
        self.assertIn("EXP-20261020-b", frozen[0].message)

    def test_supersession_is_allowed_and_flagged(self):
        reg = registry().replace('lifecycle = "historical"\n        change_class = "frozen"',
                                 'lifecycle = "superseded"\n        superseded_by = "CI-T-005"\n        change_class = "frozen"')
        self.assertNotEqual(reg, registry())
        r = self.check({"docs/config-items.toml": reg}, "### Owner approval requested\n- CI-T-001 CI-T-003\n")
        self.assertNoErrors(r)
        self.assertCode(r, "attention", "SUPERSEDED")


class UnfreezeAttempts(Base):
    """Codex review of PR #81: protections must not be bypassable by registry layering or stale branches."""

    OVERRIDE = textwrap.dedent("""\
        [[item]]
        id = "CI-T-020"
        name = "Older note, re-registered"
        type = "decision-record"
        path = "{path}"
        lifecycle = "active"
        change_class = "living"
        approval = "none"
        """)

    def test_living_item_over_frozen_family_member_is_rejected(self):
        r = self.check({"docs/config-items.toml": registry(self.OVERRIDE.format(path="docs/decisions/2026-10-19-older.md"))})
        self.assertCode(r, "error", "REGISTRY-UNFREEZE")

    def test_living_item_over_done_experiment_is_rejected(self):
        r = self.check({"docs/config-items.toml": registry(self.OVERRIDE.format(path="docs/experiments/EXP-20261020-b.md"))})
        self.assertCode(r, "error", "REGISTRY-UNFREEZE")

    def test_member_stays_frozen_even_if_such_an_item_was_merged(self):
        merged = self.repo.commit({"docs/config-items.toml": registry(self.OVERRIDE.format(path="docs/decisions/2026-10-19-older.md"))})
        self.repo.commit({"docs/decisions/2026-10-19-older.md": "# rewritten\n"})
        r = ci_check.run_check(self.repo.path, merged, "HEAD", "")
        self.assertCode(r, "error", "FROZEN-CHANGED")

    def test_stale_branch_cannot_edit_a_record_frozen_on_main_after_it_branched(self):
        self.repo.git("checkout", "-q", "main")
        frozen_lineages = registry().replace(
            'change_class = "living"\n        approval = "owner"\n        triggers = ["src/train.py"]',
            f'change_class = "frozen"\n        approval = "owner"\n        frozen_sha256 = "{sha("# Lineages\n")}"\n        triggers = ["src/train.py"]')
        self.assertNotEqual(frozen_lineages, registry())
        tip = self.repo.commit({"docs/config-items.toml": frozen_lineages}, "freeze lineages on main")
        self.repo.git("checkout", "-q", "pr")
        self.repo.commit({"docs/LINEAGES.md": "# Lineages\n\nrewritten on a stale branch\n"})
        r = ci_check.run_check(self.repo.path, tip, "HEAD", "### Owner approval requested\n- CI-T-004\n")
        self.assertCode(r, "error", "FROZEN-CHANGED")

    def test_stale_branch_cannot_edit_an_experiment_marked_done_on_main(self):
        self.repo.git("checkout", "-q", "main")
        tip = self.repo.commit({"docs/experiments/EXP-20261020-a.md": EXP_RUNNING.replace("running", "done")}, "done on main")
        self.repo.git("checkout", "-q", "pr")
        self.repo.commit({"docs/experiments/EXP-20261020-a.md": EXP_RUNNING + "edited later\n"})
        r = ci_check.run_check(self.repo.path, tip, "HEAD", "")
        self.assertCode(r, "error", "FROZEN-CHANGED")

    def test_stale_branch_untouched_by_main_changes_is_clean(self):
        self.repo.git("checkout", "-q", "main")
        log = LOG + "\n### D-003\n\n**Third** — 2026-10-22 — proposed — implementer.\n\n**Decision.** Later.\n"
        tip = self.repo.commit({"docs/decisions/DECISION_LOG.md": log}, "main moves on")
        self.repo.git("checkout", "-q", "pr")
        self.repo.commit({"docs/README.md": "# Index\n\nmore\n"})
        r = ci_check.run_check(self.repo.path, tip, "HEAD", "")
        self.assertEqual(r.codes("error"), [], ci_check.render(r, "t"))


class AppendOnly(Base):
    def test_new_proposed_entry_is_fine(self):
        log = LOG + "\n### D-003\n\n**Third** — 2026-10-22 — proposed — implementer.\n\n**Decision.** Maybe.\n"
        r = self.check({"docs/decisions/DECISION_LOG.md": log},
                       "### Owner approval requested\n- CI-T-002 D-003\n")
        self.assertNoErrors(r)
        self.assertCode(r, "note", "ENTRY-NEW")

    def test_new_accepted_entry_needs_owner_attention(self):
        log = LOG + "\n### D-003\n\n**Third** — 2026-10-22 — accepted — owner.\n\n**Decision.** Yes.\n"
        r = self.check({"docs/decisions/DECISION_LOG.md": log}, "")
        self.assertCode(r, "attention", "ENTRY-NEW-DECIDED")

    def test_editing_a_historical_entry_is_an_error(self):
        r = self.check({"docs/decisions/DECISION_LOG.md": LOG.replace("Do the first thing.", "Do something else.")},
                       "### Owner approval requested\n- CI-T-002 D-001\n")
        self.assertCode(r, "error", "ENTRY-MODIFIED")

    def test_removing_an_entry_is_an_error(self):
        log = LOG[:LOG.index("### D-002")]
        r = self.check({"docs/decisions/DECISION_LOG.md": log})
        self.assertCode(r, "error", "ENTRY-REMOVED")

    def test_declared_status_transition_is_attention(self):
        log = LOG.replace("**First** — 2026-10-20 — accepted — owner.",
                          "**First** — 2026-10-20 — superseded by [D-003](#d-003) — owner.")
        log += "\n### D-003\n\n**Third** — 2026-10-22 — proposed — implementer.\n\n**Decision.** Replace D-001.\n"
        r = self.check({"docs/decisions/DECISION_LOG.md": log},
                       "### Owner approval requested\n- CI-T-002: D-001 status, D-003 new\n")
        self.assertNoErrors(r)
        self.assertCode(r, "attention", "STATUS-TRANSITION")

    def test_undeclared_status_transition_is_an_error(self):
        log = LOG.replace("**First** — 2026-10-20 — accepted — owner.",
                          "**First** — 2026-10-20 — retired — owner.")
        r = self.check({"docs/decisions/DECISION_LOG.md": log}, "nothing requested")
        self.assertCode(r, "error", "STATUS-UNDECLARED")

    def test_status_transition_that_also_edits_text_is_an_error(self):
        log = LOG.replace("**First** — 2026-10-20 — accepted — owner.",
                          "**First, renamed** — 2026-10-20 — superseded by D-003 — owner.")
        r = self.check({"docs/decisions/DECISION_LOG.md": log}, "### Owner approval requested\n- D-001\n")
        self.assertCode(r, "error", "ENTRY-MODIFIED")

    def test_appended_dated_status_note_is_a_controlled_change(self):
        log = LOG.replace("**Decision.** Do the first thing.\n",
                          "**Decision.** Do the first thing.\n\n**Status 2026-10-22.** Shipped.\n")
        r = self.check({"docs/decisions/DECISION_LOG.md": log}, "### Owner approval requested\n- D-001\n- CI-T-002\n")
        self.assertNoErrors(r)
        self.assertCode(r, "attention", "STATUS-TRANSITION")

    def test_appended_dated_amendment_is_a_controlled_change(self):
        log = LOG.replace("**Decision.** Do the first thing.\n",
                          "**Decision.** Do the first thing.\n\n**Amendment (owner, via independent review, 2026-10-22).** (a) narrower.\n")
        r = self.check({"docs/decisions/DECISION_LOG.md": log}, "### Owner approval requested\n- CI-T-002 D-001\n")
        self.assertNoErrors(r)
        self.assertCode(r, "attention", "STATUS-TRANSITION")
        r = self.check({"docs/decisions/DECISION_LOG.md": log + ""}, "nothing listed")
        self.assertCode(r, "error", "STATUS-UNDECLARED")

    def test_appended_free_text_is_an_error(self):
        log = LOG.replace("**Decision.** Do the first thing.\n",
                          "**Decision.** Do the first thing.\n\nAlso, a new rule.\n")
        r = self.check({"docs/decisions/DECISION_LOG.md": log}, "### Owner approval requested\n- D-001\n")
        self.assertCode(r, "error", "ENTRY-MODIFIED")

    def test_index_table_is_living(self):
        r = self.check({"docs/decisions/DECISION_LOG.md": LOG.replace("| D-002 | accepted |", "| D-002 | accepted (amended) |")},
                       "### Owner approval requested\n- CI-T-002\n")
        self.assertNoErrors(r)

    def test_relaxing_the_entry_pattern_is_an_error(self):
        reg = registry().replace("entry_pattern = '^### (D-\\d{3})\\s*$'", "entry_pattern = '^#### (D-\\d{3})\\s*$'")
        self.assertNotEqual(reg, registry())
        r = self.check({"docs/config-items.toml": reg})
        self.assertCode(r, "error", "APPEND-REGISTRY")


class Warnings(Base):
    def test_watched_path_without_update_warns(self):
        r = self.check({"src/train.py": "print('changed')\n"})
        self.assertCode(r, "warning", "WATCH-STALE")

    def test_watched_path_waiver(self):
        r = self.check({"src/train.py": "print('changed')\n"},
                       "CI-T-004: no update needed — refactor only, same behaviour\n")
        self.assertNotIn("WATCH-STALE", r.codes())
        self.assertCode(r, "note", "WATCH-WAIVED")

    def test_waiver_needs_a_reason(self):
        r = self.check({"src/train.py": "print('changed')\n"}, "CI-T-004: no update needed —   \n")
        self.assertCode(r, "warning", "WATCH-STALE")

    def test_waiver_without_reason_does_not_borrow_the_next_line(self):
        r = self.check({"src/train.py": "print('changed')\n"}, "CI-T-004: no update needed —\nNext paragraph.\n")
        self.assertCode(r, "warning", "WATCH-STALE")

    def test_watched_path_with_update_is_quiet(self):
        r = self.check({"src/train.py": "print('changed')\n", "docs/LINEAGES.md": "# Lineages\n\nupdated\n"},
                       "### Owner approval requested\n- CI-T-004\n")
        self.assertEqual(r.codes("warning"), [], ci_check.render(r, "t"))

    def test_unregistered_new_document_warns(self):
        r = self.check({"docs/NEW_PLAN.md": "# Plan\n"})
        self.assertCode(r, "warning", "UNREGISTERED")

    def test_unregistered_declared(self):
        r = self.check({"docs/NEW_PLAN.md": "# Plan\n"}, "- unregistered: `docs/NEW_PLAN.md` — scratch notes, removed next PR\n")
        self.assertNotIn("UNREGISTERED", r.codes("warning"))

    def test_generated_artefact_hand_edit_warns(self):
        r = self.check({"docs/manifest.json": '{"edited": true}\n'})
        self.assertCode(r, "warning", "GENERATED-EDIT")
        r2 = ci_check.run_check(self.repo.path, self.base, "HEAD", "Ran `tool --audit-dataset`, output below")
        self.assertNotIn("GENERATED-EDIT", r2.codes())

    def test_no_body_means_declarations_unchecked(self):
        self.repo.commit({"docs/LINEAGES.md": "# Lineages\n\nL2.\n"})
        r = ci_check.run_check(self.repo.path, self.base, "HEAD", None)
        self.assertCode(r, "note", "BODY-ABSENT")
        self.assertCode(r, "attention", "OWNER-APPROVAL")


class FirstAdoption(unittest.TestCase):
    """The PR that introduces the registry has no base registry to protect."""

    def test_introducing_registry(self):
        repo = Repo()
        try:
            base = repo.commit(BASE_FILES, "before registry")
            repo.commit({"docs/config-items.toml": registry()})
            r = ci_check.run_check(repo.path, base, "HEAD", "### Owner approval requested\n- CI-T-001\n")
            self.assertEqual(r.codes("error"), [], ci_check.render(r, "t"))
            self.assertIn("OWNER-APPROVAL", r.codes("attention"))
        finally:
            repo.close()

    def test_no_registry_anywhere(self):
        repo = Repo()
        try:
            base = repo.commit({"README.md": "x\n"})
            repo.commit({"README.md": "y\n"})
            r = ci_check.run_check(repo.path, base, "HEAD", "")
            self.assertEqual(r.codes(), ["REGISTRY-ABSENT"])
        finally:
            repo.close()

    def test_bad_revision_fails_closed(self):
        repo = Repo()
        try:
            repo.commit({"README.md": "x\n"})
            self.assertEqual(ci_check.main(["--repo", repo.path, "--base", "nope", "--head", "HEAD"]), 2)
        finally:
            repo.close()


class Matching(unittest.TestCase):
    def test_globs(self):
        g = ci_check.matches
        self.assertTrue(g(["docs/decisions/????-??-??-*.md"], "docs/decisions/2026-10-20-x.md"))
        self.assertFalse(g(["docs/decisions/????-??-??-*.md"], "docs/decisions/DECISION_LOG.md"))
        self.assertTrue(g(["docs/ml/*/l2/**"], "docs/ml/Scratch/l2/a/b.json"))
        self.assertFalse(g(["docs/ml/*.md"], "docs/ml/experiments/EXP-1.md"))
        self.assertTrue(g(["scripts/footage_share/"], "scripts/footage_share/link.py"))
        self.assertTrue(g(["**/*.storekit"], "a/b/c.storekit"))


if __name__ == "__main__":
    unittest.main()
