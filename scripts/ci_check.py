#!/usr/bin/env python3
"""Configuration-item impact check for docs/config-items.toml (schema 1).

Compares a pull request's head with its base and reports, without editing
anything:

  errors     invalid registry; a change to a frozen record (including a
             frozen record re-pinned, renamed, reclassified or removed in the
             same PR); an edit or removal of an existing append-only entry
             other than a declared status transition.
  attention  changes the owner must explicitly authorise (approval = "owner",
             decision status transitions, new non-proposed decisions,
             supersessions). The PR's request list is a request, not an
             authorisation; this script never infers approval.
  warnings   watched paths changed without an update or waiver; new
             unregistered documents; hand edits to generated artefacts.

Protections are taken from the BASE registry, so a PR cannot relax the rules
it is checked against. Standard library only (Python 3.11+). Never writes
files, never posts anything. Exit 0 = no errors, 1 = errors, 2 = could not run.

  python3 scripts/ci_check.py --base origin/main [--pr-body-file body.md]
  python3 scripts/ci_check.py --audit            # registry validity at HEAD only
"""

from __future__ import annotations

import argparse
import dataclasses
import functools
import hashlib
import os
import re
import subprocess
import sys
import tomllib

REGISTRY_PATH = "docs/config-items.toml"
SCHEMA = 1

TYPES = {
    # engineering documents and records
    "registry", "index", "process", "template", "agent-instructions", "plan",
    "roadmap", "roadmap-amendments", "decision-log", "decision-record",
    "owner-questions", "baseline", "model-lineage", "model-registry",
    "experiment-registry", "experiment-record", "dataset-manifest", "split",
    "validation-record", "audit", "metric-report",
    # structured visualisation (milestone 3)
    "architecture-diagram", "timeline", "dependency-map",
    "model-performance-chart", "feature-matrix",
    # product and release assets (milestone 4)
    "app-store-screenshot-set", "marketing-copy", "subscription-config",
    "legal-disclosure", "privacy-manifest", "release-asset", "release-notes",
}
LIFECYCLES = {"planned", "draft", "active", "historical", "superseded", "retired"}
INACTIVE = {"planned", "superseded", "retired"}
CHANGE_CLASSES = {"living", "append-only", "frozen"}
APPROVALS = {"none", "owner"}
MAINTAINERS = {"owner", "implementer"}

TOP_KEYS = {"schema", "project", "item_prefix", "family_prefix",
            "controlled_roots", "item", "family"}
ITEM_REQUIRED = {"id", "name", "type", "lifecycle", "change_class", "approval"}
ITEM_OPTIONAL = {"path", "maintainer", "decisions", "experiments", "sources",
                 "triggers", "generated_by", "superseded_by", "frozen_sha256",
                 "entry_pattern", "status_pattern", "status_note_pattern",
                 "notes"}
FAMILY_REQUIRED = {"id", "name", "type", "patterns", "lifecycle",
                   "change_class", "approval"}
FAMILY_OPTIONAL = {"exclude", "maintainer", "decisions", "sources", "triggers",
                   "generated_by", "freeze_when", "notes"}

DECISION_RE = re.compile(r"^D-\d{3}$")
EXPERIMENT_RE = re.compile(r"^EXP-\d{8}-[a-z0-9][a-z0-9-]*$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
WAIVER_RE = re.compile(r"\b((?:CI|CF)-[A-Z]+-\d{3}):[ \t]*no update needed[ \t]*[—–-]+[ \t]*(\S.*)$", re.M)
UNREGISTERED_RE = re.compile(r"^[ \t]*[-*]?[ \t]*unregistered:[ \t]*`?([^`\s]+)`?[ \t]*[—–-]+[ \t]*(\S.*)$", re.M)
APPROVAL_HEADING_RE = re.compile(r"^(#{2,4})\s*Owner approval requested\b.*$", re.M | re.I)

# fields of a frozen item that no PR may change; lifecycle may only move to
# superseded/historical and superseded_by may be set (supersession)
FROZEN_PROTECTED = ("path", "type", "change_class", "frozen_sha256")
APPEND_PROTECTED = ("path", "change_class", "entry_pattern", "status_pattern",
                    "status_note_pattern")


class CheckError(Exception):
    """The check could not run (git failure, unreadable input)."""


# ---------------------------------------------------------------- git access

class Git:
    def __init__(self, repo: str):
        self.repo = repo

    def run(self, *args: str) -> bytes:
        try:
            proc = subprocess.run(
                ["git", "-c", "core.quotepath=off", *args], cwd=self.repo,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, check=False)
        except OSError as exc:
            raise CheckError(f"cannot run git: {exc}") from exc
        if proc.returncode != 0:
            raise CheckError(f"git {' '.join(args)} failed: "
                             f"{proc.stderr.decode(errors='replace').strip()}")
        return proc.stdout

    def rev(self, rev: str) -> str:
        return self.run("rev-parse", "--verify", f"{rev}^{{commit}}").decode().strip()

    def merge_base(self, a: str, b: str) -> str:
        return self.run("merge-base", a, b).decode().strip()

    def files(self, rev: str) -> list[str]:
        out = self.run("ls-tree", "-r", "-z", "--name-only", rev)
        return [p.decode("utf-8", "surrogateescape") for p in out.split(b"\0") if p]

    def read(self, rev: str, path: str, tree: set[str]) -> bytes | None:
        if path not in tree:
            return None
        return self.run("cat-file", "blob", f"{rev}:{path}")

    def changes(self, base: str, head: str) -> dict[str, str]:
        out = self.run("diff", "--name-status", "-z", "--no-renames", base, head)
        parts = [p.decode("utf-8", "surrogateescape") for p in out.split(b"\0") if p]
        return {parts[i + 1]: parts[i][0] for i in range(0, len(parts) - 1, 2)}


# ---------------------------------------------------------------- findings

@dataclasses.dataclass
class Finding:
    level: str          # error | attention | warning | note
    code: str
    message: str
    keys: tuple[str, ...] = ()


@dataclasses.dataclass
class Report:
    findings: list[Finding] = dataclasses.field(default_factory=list)
    touched: list[tuple[str, str, str, str]] = dataclasses.field(default_factory=list)

    def add(self, level: str, code: str, message: str, *keys: str) -> None:
        self.findings.append(Finding(level, code, message, tuple(keys)))

    def of(self, level: str) -> list[Finding]:
        return [f for f in self.findings if f.level == level]

    def codes(self, level: str | None = None) -> list[str]:
        return [f.code for f in self.findings if level is None or f.level == level]


# ---------------------------------------------------------------- matching

@functools.lru_cache(maxsize=None)
def glob_regex(pattern: str) -> re.Pattern[str]:
    """`**` crosses directories, `*` and `?` do not; a trailing `/` means the whole tree."""
    if pattern.endswith("/"):
        pattern += "**"
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?"); i += 3
        elif pattern.startswith("**", i):
            out.append(".*"); i += 2
        elif pattern[i] == "*":
            out.append("[^/]*"); i += 1
        elif pattern[i] == "?":
            out.append("[^/]"); i += 1
        else:
            out.append(re.escape(pattern[i])); i += 1
    return re.compile("".join(out) + r"\Z")


def matches(patterns, path: str) -> bool:
    return any(glob_regex(p).match(path) for p in patterns or ())


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def frontmatter_field(data: bytes, field: str) -> str | None:
    text = data.decode("utf-8", "replace")
    if not text.startswith("---\n"):
        return None
    end = text.find("\n---", 4)
    if end < 0:
        return None
    m = re.search(rf"^{re.escape(field)}:\s*(.*)$", text[4:end], re.M)
    return m.group(1).strip().strip("'\"") if m else None


# ---------------------------------------------------------------- registry

@dataclasses.dataclass
class Registry:
    raw: dict
    items: dict[str, dict]
    families: dict[str, dict]

    def item_at(self, path: str) -> dict | None:
        for item in self.items.values():
            if item.get("path") == path:
                return item
        return None

    def families_for(self, path: str) -> list[dict]:
        return [f for f in self.families.values()
                if matches(f["patterns"], path) and not matches(f.get("exclude"), path)]

    def owner_of(self, path: str) -> tuple[str, dict] | None:
        """('item'|'family', record) governing a path; individual items win."""
        item = self.item_at(path)
        if item is not None:
            return "item", item
        fams = self.families_for(path)
        return ("family", fams[0]) if fams else None

    def by_type(self, kind: str) -> list[dict]:
        return [i for i in self.items.values() if i["type"] == kind]


def parse_registry(data: bytes | None, where: str, report: Report | None) -> Registry | None:
    """Parse and structurally validate. Structural problems are errors in `report`."""
    def err(code, msg, *keys):
        if report is not None:
            report.add("error", code, f"{where}: {msg}", *keys)

    if data is None:
        return None
    try:
        raw = tomllib.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        err("REGISTRY-PARSE", f"not valid TOML: {exc}")
        return Registry({}, {}, {})
    if raw.get("schema") != SCHEMA:
        err("REGISTRY-SCHEMA", f"schema must be {SCHEMA}, found {raw.get('schema')!r}")
    for key in sorted(set(raw) - TOP_KEYS):
        err("REGISTRY-KEY", f"unknown top-level key {key!r}")
    item_prefix = raw.get("item_prefix", "")
    family_prefix = raw.get("family_prefix", "")
    for key, val in (("item_prefix", item_prefix), ("family_prefix", family_prefix)):
        if not isinstance(val, str) or not re.fullmatch(r"(CI|CF)-[A-Z]+", val):
            err("REGISTRY-PREFIX", f"{key} must look like CI-XYZ / CF-XYZ")

    def check_common(rec, kind, required, optional, prefix):
        rid = rec.get("id", "<missing id>")
        for key in sorted(required - set(rec)):
            err("REGISTRY-REQUIRED", f"{rid}: missing {key!r}", rid)
        for key in sorted(set(rec) - required - optional):
            err("REGISTRY-KEY", f"{rid}: unknown key {key!r}", rid)
        if not re.fullmatch(rf"{re.escape(prefix)}-\d{{3}}", str(rid)):
            err("REGISTRY-ID", f"{rid}: {kind} ids are {prefix}-NNN", rid)
        for key, allowed in (("type", TYPES), ("lifecycle", LIFECYCLES),
                             ("change_class", CHANGE_CLASSES), ("approval", APPROVALS)):
            if key in rec and rec[key] not in allowed:
                err("REGISTRY-ENUM", f"{rid}: {key} {rec[key]!r} is not one of {sorted(allowed)}", rid)
        if "maintainer" in rec and rec["maintainer"] not in MAINTAINERS:
            err("REGISTRY-ENUM", f"{rid}: maintainer must be one of {sorted(MAINTAINERS)}", rid)
        for key in ("decisions", "experiments", "sources", "triggers", "patterns", "exclude"):
            if key in rec and not (isinstance(rec[key], list) and all(isinstance(x, str) for x in rec[key])):
                err("REGISTRY-TYPE", f"{rid}: {key} must be a list of strings", rid)
                rec[key] = []
        for d in rec.get("decisions", []):
            if not DECISION_RE.match(d):
                err("REGISTRY-REF", f"{rid}: decision {d!r} is not D-NNN", rid)
        for e in rec.get("experiments", []):
            if not EXPERIMENT_RE.match(e):
                err("REGISTRY-REF", f"{rid}: experiment {e!r} is not EXP-YYYYMMDD-slug", rid)
        if rec.get("lifecycle") == "superseded" and not rec.get("superseded_by"):
            err("REGISTRY-SUPERSEDED", f"{rid}: lifecycle superseded needs superseded_by", rid)
        return rid

    items: dict[str, dict] = {}
    for rec in raw.get("item", []) if isinstance(raw.get("item", []), list) else []:
        rid = check_common(rec, "item", ITEM_REQUIRED, ITEM_OPTIONAL, item_prefix)
        if rid in items:
            err("REGISTRY-DUPLICATE", f"duplicate id {rid}", rid)
        items[rid] = rec
        cls = rec.get("change_class")
        if rec.get("lifecycle") != "planned" and not rec.get("path"):
            err("REGISTRY-PATH", f"{rid}: path is required unless lifecycle is planned", rid)
        if cls == "frozen" and not SHA256_RE.match(rec.get("frozen_sha256", "")):
            err("REGISTRY-FROZEN", f"{rid}: frozen items pin frozen_sha256 (64 hex)", rid)
        if cls != "frozen" and "frozen_sha256" in rec:
            err("REGISTRY-FROZEN", f"{rid}: frozen_sha256 only applies to frozen items", rid)
        if cls == "append-only":
            for key in ("entry_pattern", "status_pattern"):
                if not rec.get(key):
                    err("REGISTRY-APPEND", f"{rid}: append-only items need {key}", rid)
        for key in ("entry_pattern", "status_pattern", "status_note_pattern"):
            if rec.get(key):
                try:
                    pat = re.compile(rec[key])
                except re.error as exc:
                    err("REGISTRY-PATTERN", f"{rid}: {key} is not a valid regex: {exc}", rid)
                    rec[key] = ""
                    continue
                if key == "entry_pattern" and pat.groups < 1:
                    err("REGISTRY-PATTERN", f"{rid}: entry_pattern needs a group for the entry id", rid)
                if key == "status_pattern" and "status" not in pat.groupindex:
                    err("REGISTRY-PATTERN", f"{rid}: status_pattern needs a (?P<status>…) group", rid)
    families: dict[str, dict] = {}
    for rec in raw.get("family", []) if isinstance(raw.get("family", []), list) else []:
        rid = check_common(rec, "family", FAMILY_REQUIRED, FAMILY_OPTIONAL, family_prefix)
        if rid in families or rid in items:
            err("REGISTRY-DUPLICATE", f"duplicate id {rid}", rid)
        families[rid] = rec
        if not rec.get("patterns"):
            err("REGISTRY-PATTERNS", f"{rid}: families need at least one pattern", rid)
            rec["patterns"] = []
        if rec.get("change_class") == "append-only":
            err("REGISTRY-FAMILY", f"{rid}: families are living or frozen", rid)
        fw = rec.get("freeze_when")
        if fw is not None:
            if not (isinstance(fw, dict) and set(fw) == {"field", "pattern"}
                    and all(isinstance(v, str) for v in fw.values())):
                err("REGISTRY-FREEZE-WHEN", f"{rid}: freeze_when is {{field, pattern}}", rid)
                rec.pop("freeze_when")
            else:
                try:
                    re.compile(fw["pattern"])
                except re.error as exc:
                    err("REGISTRY-PATTERN", f"{rid}: freeze_when.pattern invalid: {exc}", rid)
                    rec.pop("freeze_when")
    return Registry(raw, items, families)


def validate_against_tree(reg: Registry, git: Git, rev: str, tree: set[str], report: Report) -> None:
    """Checks that need the files at `rev`: paths, pins, references, overlaps."""
    known = set(reg.items) | set(reg.families)
    paths: dict[str, str] = {}
    for rid, item in reg.items.items():
        path = item.get("path")
        if path:
            if path in paths:
                report.add("error", "REGISTRY-PATH", f"{rid} and {paths[path]} both register {path}", rid)
            paths[path] = rid
            if path not in tree and item.get("lifecycle") not in ("planned", "retired"):
                report.add("error", "REGISTRY-MISSING", f"{rid}: {path} does not exist", rid)
            if item.get("change_class") == "frozen" and path in tree and SHA256_RE.match(item.get("frozen_sha256", "")):
                actual = sha256(git.read(rev, path, tree))
                if actual != item["frozen_sha256"]:
                    report.add("error", "FROZEN-HASH",
                               f"{rid}: {path} sha256 {actual[:12]}… does not match the pinned "
                               f"{item['frozen_sha256'][:12]}…", rid)
        for ref in [item.get("superseded_by")] if item.get("superseded_by") else []:
            if ref not in known:
                report.add("error", "REGISTRY-REF", f"{rid}: superseded_by {ref} is not registered", rid)
    for rid, rec in list(reg.items.items()) + list(reg.families.items()):
        for src in rec.get("sources", []):
            if re.fullmatch(r"(CI|CF)-[A-Z]+-\d{3}", src):
                if src not in known:
                    report.add("error", "REGISTRY-REF", f"{rid}: source {src} is not registered", rid)
            elif not any(glob_regex(src).match(p) for p in tree):
                report.add("warning", "SOURCE-MISSING", f"{rid}: source {src} matches no file", rid)
    # one family per file; files registered individually are exempt
    for path in sorted(tree):
        if path in paths:
            continue
        fams = reg.families_for(path)
        if len(fams) > 1:
            report.add("error", "REGISTRY-OVERLAP",
                       f"{path} matches families {', '.join(f['id'] for f in fams)}; add an exclude",
                       *[f["id"] for f in fams])
    # decision references must exist in the decision log
    logs = reg.by_type("decision-log")
    if logs and logs[0].get("path") in tree and logs[0].get("entry_pattern"):
        text = git.read(rev, logs[0]["path"], tree).decode("utf-8", "replace")
        ids = set(e[0] for e in split_entries(text, logs[0]["entry_pattern"])[1])
        for rid, rec in list(reg.items.items()) + list(reg.families.items()):
            for d in rec.get("decisions", []):
                if DECISION_RE.match(d) and d not in ids:
                    report.add("error", "REGISTRY-REF", f"{rid}: {d} is not in the decision log", rid, d)
    regs = reg.by_type("experiment-registry")
    if regs and regs[0].get("path") in tree:
        text = git.read(rev, regs[0]["path"], tree).decode("utf-8", "replace")
        for rid, rec in reg.items.items():
            for e in rec.get("experiments", []):
                if EXPERIMENT_RE.match(e) and e not in text:
                    report.add("warning", "EXPERIMENT-UNKNOWN", f"{rid}: {e} is not in the experiment registry", rid)


# ---------------------------------------------------------------- append-only entries

def split_entries(text: str, entry_pattern: str) -> tuple[list[str], list[tuple[str, list[str]]]]:
    """(preamble lines, [(entry id, lines)]); an entry runs to the next entry header."""
    pat = re.compile(entry_pattern)
    pre: list[str] = []
    entries: list[tuple[str, list[str]]] = []
    for line in text.splitlines():
        m = pat.match(line)
        if m:
            entries.append((m.group(1), [line]))
        elif entries:
            entries[-1][1].append(line)
        else:
            pre.append(line)
    return pre, entries


def _trim(lines: list[str]) -> list[str]:
    out = [l.rstrip() for l in lines]
    while out and out[-1] in ("", "---"):
        out.pop()
    return out


def compare_entry(base: list[str], head: list[str], status_pat: re.Pattern, note_pat: re.Pattern | None):
    """-> (kind, old_status, new_status, notes_added). kind: same | status | modified."""
    b, h = _trim(base), _trim(head)
    if len(h) < len(b):
        return "modified", None, None, 0
    old = new = None
    for i, line in enumerate(b):
        if line == h[i]:
            m = status_pat.search(line)
            if m and old is None:
                old = new = m.group("status")
            continue
        mb, mh = status_pat.search(line), status_pat.search(h[i])
        if not (mb and mh) or old is not None:
            return "modified", None, None, 0
        masked_b = line[:mb.start("status")] + "\0" + line[mb.end("status"):]
        masked_h = h[i][:mh.start("status")] + "\0" + h[i][mh.end("status"):]
        if masked_b != masked_h:
            return "modified", None, None, 0
        old, new = mb.group("status"), mh.group("status")
    extra = h[len(b):]
    notes = 0
    para_start = True
    for line in extra:
        if line == "":
            para_start = True
            continue
        if para_start:
            if note_pat is None or not note_pat.match(line):
                return "modified", None, None, 0
            notes += 1
        para_start = False
    if old != new or notes:
        return "status", old, new, notes
    return "same", old, new, 0


def check_append_only(rid, item, base_text, head_text, report, declared):
    entry_pat = item["entry_pattern"]
    status_pat = re.compile(item["status_pattern"])
    note_pat = re.compile(item["status_note_pattern"]) if item.get("status_note_pattern") else None
    _, base_entries = split_entries(base_text, entry_pat)
    _, head_entries = split_entries(head_text, entry_pat)
    head_map: dict[str, list[str]] = {}
    for eid, lines in head_entries:
        if eid in head_map:
            report.add("error", "ENTRY-DUPLICATE", f"{rid}: entry {eid} appears twice", rid, eid)
        head_map[eid] = lines
    base_ids = [e for e, _ in base_entries]
    for eid, lines in base_entries:
        if eid not in head_map:
            report.add("error", "ENTRY-REMOVED", f"{rid}: historical entry {eid} was removed", rid, eid)
            continue
        kind, old, new, notes = compare_entry(lines, head_map[eid], status_pat, note_pat)
        if kind == "modified":
            report.add("error", "ENTRY-MODIFIED",
                       f"{rid}: historical entry {eid} was edited. Existing entries are append-only; "
                       f"correct them with a new entry, or (status only) a status transition", rid, eid)
        elif kind == "status":
            what = []
            if old != new:
                what.append(f"status {old!r} → {new!r}")
            if notes:
                what.append(f"{notes} dated status note(s) appended")
            msg = f"{rid}: {eid} controlled status change ({'; '.join(what)})"
            if declared is None or eid in declared:
                report.add("attention", "STATUS-TRANSITION", msg, rid, eid)
            else:
                report.add("error", "STATUS-UNDECLARED",
                           msg + f" — not listed under 'Owner approval requested'", rid, eid)
    head_order = [e for e, _ in head_entries]
    kept = [e for e in head_order if e in set(base_ids)]
    if kept != [e for e in base_ids if e in head_map]:
        report.add("error", "ENTRY-REORDERED", f"{rid}: historical entries were reordered", rid)
    if base_ids:
        last_base = max((head_order.index(e) for e in base_ids if e in head_order), default=-1)
        for idx, eid in enumerate(head_order):
            if eid in base_ids:
                continue
            if idx < last_base:
                report.add("warning", "ENTRY-INSERTED", f"{rid}: new entry {eid} is inserted before existing entries", rid, eid)
            status = None
            for line in head_map[eid]:
                m = status_pat.search(line)
                if m:
                    status = m.group("status")
                    break
            if status is None:
                report.add("error", "ENTRY-NO-STATUS", f"{rid}: new entry {eid} has no status line", rid, eid)
            elif not status.lower().startswith("proposed"):
                report.add("attention", "ENTRY-NEW-DECIDED",
                           f"{rid}: new entry {eid} is recorded as {status!r}; it needs the owner's explicit "
                           f"authorisation quoted in the PR (otherwise record it as proposed)", rid, eid)
            else:
                report.add("note", "ENTRY-NEW", f"{rid}: new entry {eid} ({status})", rid, eid)


# ---------------------------------------------------------------- PR body

def parse_body(body: str | None):
    if body is None:
        return None, {}, {}
    declared: set[str] = set()
    m = APPROVAL_HEADING_RE.search(body)
    if m:
        level = len(m.group(1))
        rest = body[m.end():]
        stop = re.search(rf"^#{{1,{level}}}\s", rest, re.M)
        section = rest[:stop.start()] if stop else rest
        section = re.sub(r"<!--.*?-->", "", section, flags=re.S)
        declared |= set(re.findall(r"\b(?:CI|CF)-[A-Z]+-\d{3}\b|\bD-\d{3}\b", section))
        declared |= set(re.findall(r"`([^`]+)`", section))
    waivers = {k: v.strip() for k, v in WAIVER_RE.findall(body) if v.strip()}
    unregistered = {k: v.strip() for k, v in UNREGISTERED_RE.findall(body) if v.strip()}
    return declared, waivers, unregistered


# ---------------------------------------------------------------- the check

def protected_frozen_paths(reg: Registry, git: Git, rev: str, tree: set[str]) -> dict[str, str]:
    """path -> governing id for every file frozen at `rev` according to `reg`."""
    out: dict[str, str] = {}
    for rid, item in reg.items.items():
        if item.get("change_class") == "frozen" and item.get("path") in tree:
            out[item["path"]] = rid
    for path in tree:
        if path in out or reg.item_at(path) is not None:
            continue
        for fam in reg.families_for(path):
            if fam.get("change_class") == "frozen":
                out[path] = fam["id"]
            elif fam.get("freeze_when"):
                value = frontmatter_field(git.read(rev, path, tree) or b"", fam["freeze_when"]["field"])
                if value is not None and re.search(fam["freeze_when"]["pattern"], value):
                    out[path] = f"{fam['id']} (status {value!r})"
    return out


def run_check(repo: str, base: str, head: str, body: str | None) -> Report:
    git = Git(repo)
    report = Report()
    head_sha = git.rev(head)
    base_sha = git.merge_base(git.rev(base), head_sha)
    base_tree, head_tree = set(git.files(base_sha)), set(git.files(head_sha))
    changes = git.changes(base_sha, head_sha)
    declared, waivers, unregistered = parse_body(body)
    if body is None:
        report.add("note", "BODY-ABSENT", "no PR body supplied: declarations and waivers were not checked")

    base_reg = parse_registry(git.read(base_sha, REGISTRY_PATH, base_tree), f"base {REGISTRY_PATH}", None)
    head_reg = parse_registry(git.read(head_sha, REGISTRY_PATH, head_tree), REGISTRY_PATH, report)
    if head_reg is None:
        if base_reg is not None:
            report.add("error", "REGISTRY-REMOVED", f"{REGISTRY_PATH} was deleted")
        else:
            report.add("note", "REGISTRY-ABSENT", f"no {REGISTRY_PATH} on either side; nothing to check")
        return report
    validate_against_tree(head_reg, git, head_sha, head_tree, report)

    # ---- immutable records: rules come from the base registry (amendment A)
    if base_reg is not None:
        for rid, b in base_reg.items.items():
            h = head_reg.items.get(rid)
            cls = b.get("change_class")
            if cls == "frozen":
                if h is None:
                    report.add("error", "FROZEN-UNREGISTERED", f"{rid} (frozen) was removed from the registry", rid)
                    continue
                for key in FROZEN_PROTECTED:
                    if b.get(key) != h.get(key):
                        report.add("error", "FROZEN-REGISTRY",
                                   f"{rid}: frozen record's {key} changed ({b.get(key)!r} → {h.get(key)!r}); "
                                   f"supersede it with a new record instead", rid)
                if h.get("lifecycle") != b.get("lifecycle") and h.get("lifecycle") not in ("superseded", "historical"):
                    report.add("error", "FROZEN-REGISTRY",
                               f"{rid}: frozen record's lifecycle may only move to superseded or historical", rid)
                if h.get("superseded_by") and h.get("superseded_by") != b.get("superseded_by"):
                    report.add("attention", "SUPERSEDED",
                               f"{rid} is superseded by {h['superseded_by']}", rid, h["superseded_by"])
            elif cls == "append-only":
                if h is None:
                    report.add("error", "APPEND-UNREGISTERED", f"{rid} (append-only) was removed from the registry", rid)
                    continue
                for key in APPEND_PROTECTED:
                    if b.get(key) != h.get(key):
                        report.add("error", "APPEND-REGISTRY",
                                   f"{rid}: append-only record's {key} changed; its history rules are fixed", rid)
            elif h is None:
                report.add("attention", "ITEM-REMOVED",
                           f"{rid} was removed from the registry (prefer lifecycle = retired)", rid)
            elif b.get("approval") == "owner" and h.get("approval") != "owner":
                report.add("attention", "APPROVAL-RELAXED", f"{rid}: approval relaxed from owner to none", rid)
        for fid, b in base_reg.families.items():
            h = head_reg.families.get(fid)
            if b.get("change_class") == "frozen" or b.get("freeze_when"):
                if h is None:
                    report.add("error", "FROZEN-UNREGISTERED", f"{fid} (protected family) was removed", fid)
                    continue
                if h.get("change_class") != b.get("change_class") or h.get("freeze_when") != b.get("freeze_when"):
                    report.add("error", "FROZEN-REGISTRY", f"{fid}: protected family's freeze rule changed", fid)
                if not set(b.get("patterns", [])) <= set(h.get("patterns", [])) or \
                        not set(h.get("exclude", [])) <= set(b.get("exclude", [])):
                    report.add("error", "FROZEN-REGISTRY",
                               f"{fid}: protected family's coverage was narrowed (patterns removed or excludes added)", fid)
        frozen = protected_frozen_paths(base_reg, git, base_sha, base_tree)
        for path, gid in sorted(frozen.items()):
            status = changes.get(path)
            if status:
                verb = {"D": "deleted (or renamed)", "M": "modified", "T": "changed type"}.get(status, "changed")
                report.add("error", "FROZEN-CHANGED",
                           f"{path} is frozen ({gid}) and was {verb}. Historical records are corrected "
                           f"by a new superseding record, never edited", gid.split()[0], path)
        for rid, b in base_reg.items.items():
            h = head_reg.items.get(rid)
            if b.get("change_class") != "append-only" or h is None or b.get("path") not in changes:
                continue
            if b["path"] not in head_tree:
                report.add("error", "APPEND-DELETED", f"{rid}: {b['path']} was deleted", rid)
                continue
            check_append_only(rid, b,
                              git.read(base_sha, b["path"], base_tree).decode("utf-8", "replace"),
                              git.read(head_sha, b["path"], head_tree).decode("utf-8", "replace"),
                              report, declared)

    # ---- touched items, owner attention, generated artefacts
    seen: set[str] = set()
    for path, status in sorted(changes.items()):
        gov = head_reg.owner_of(path) or (base_reg.owner_of(path) if base_reg else None)
        if gov is None:
            continue
        kind, rec = gov
        rid = rec["id"]
        label = rid if kind == "item" else f"{rid} {path}"
        change = {"A": "new", "D": "deleted", "M": "updated"}.get(status, "changed")
        report.touched.append((rid, rec["name"], rec.get("change_class", ""), f"{change}: {path}"))
        seen.add(rid)
        if rec.get("approval") == "owner" and rec.get("change_class") != "frozen":
            keys = {rid, path}
            msg = f"{label} ({rec['name']}) {change} — owner authorisation needed"
            if declared is not None and not keys & declared:
                report.add("warning", "ATTENTION-UNLISTED", msg + "; not listed under 'Owner approval requested'", rid, path)
            else:
                report.add("attention", "OWNER-APPROVAL", msg, rid, path)
        if rec.get("generated_by") and status != "D":
            if body is None or rec["generated_by"] not in body:
                report.add("warning", "GENERATED-EDIT",
                           f"{path} is generated by `{rec['generated_by']}`; paste that command and its "
                           f"output in the PR's validation evidence (hand edits are not allowed)", rid, path)
        if status == "A" and rec.get("change_class") == "frozen":
            report.add("attention", "FROZEN-NEW", f"{rid}: new frozen record {path} — pinned on merge", rid, path)

    # ---- watched paths (warnings for now; promotion is the owner's call)
    for rid, rec in list(head_reg.items.items()) + list(head_reg.families.items()):
        if rec.get("lifecycle") in INACTIVE or not rec.get("triggers"):
            continue
        own = (lambda p: p == rec.get("path")) if rid in head_reg.items else \
              (lambda p: matches(rec["patterns"], p) and not matches(rec.get("exclude"), p))
        if any(own(p) for p in changes):
            continue
        hits = sorted(p for p in changes if matches(rec["triggers"], p) and not own(p))
        if not hits:
            continue
        if rid in waivers:
            report.add("note", "WATCH-WAIVED", f"{rid}: watched change waived — {waivers[rid]}", rid)
        else:
            shown = ", ".join(hits[:4]) + (f" and {len(hits) - 4} more" if len(hits) > 4 else "")
            report.add("warning", "WATCH-STALE",
                       f"{rid} ({rec['name']}) may need an update: {shown} changed. Update it, or add "
                       f"'{rid}: no update needed — <reason>' to the PR body", rid)

    # ---- new unregistered documents
    roots = head_reg.raw.get("controlled_roots", [])
    for path, status in sorted(changes.items()):
        if status != "A" or not any(path.startswith(r) for r in roots) or head_reg.owner_of(path):
            continue
        if path in unregistered:
            report.add("note", "UNREGISTERED-DECLARED", f"{path} unregistered — {unregistered[path]}", path)
        else:
            report.add("warning", "UNREGISTERED",
                       f"{path} is new under a controlled root but matches no item or family. Register it, "
                       f"or add 'unregistered: `{path}` — <reason>' to the PR body", path)
    return report


def run_audit(repo: str, rev: str) -> Report:
    git = Git(repo)
    report = Report()
    sha = git.rev(rev)
    tree = set(git.files(sha))
    reg = parse_registry(git.read(sha, REGISTRY_PATH, tree), REGISTRY_PATH, report)
    if reg is None:
        report.add("error", "REGISTRY-ABSENT", f"{REGISTRY_PATH} not found at {rev}")
        return report
    validate_against_tree(reg, git, sha, tree, report)
    roots = reg.raw.get("controlled_roots", [])
    for path in sorted(tree):
        if any(path.startswith(r) for r in roots) and not reg.owner_of(path):
            report.add("warning", "UNREGISTERED", f"{path} matches no item or family", path)
    return report


# ---------------------------------------------------------------- output

def render(report: Report, title: str) -> str:
    errors, attention = report.of("error"), report.of("attention")
    warnings, notes = report.of("warning"), report.of("note")
    verdict = "FAIL" if errors else "PASS"
    out = [f"## {title}: {verdict}", "",
           f"{len(errors)} error(s) · {len(attention)} owner-attention item(s) · "
           f"{len(warnings)} warning(s)", ""]
    if attention:
        out += ["Owner-attention items are requests. Neither this check passing nor a clean review "
                "authorises them; the owner does, explicitly, and merges.", ""]
    for heading, group in (("Errors", errors), ("Owner attention requested", attention),
                           ("Warnings", warnings), ("Notes", notes)):
        if group:
            out.append(f"### {heading}")
            out += [f"- `{f.code}` {f.message}" for f in group]
            out.append("")
    if report.touched:
        out += ["### Configuration items touched", "", "| ID | Item | Class | Change |", "|---|---|---|---|"]
        out += [f"| {a} | {b} | {c} | {d} |" for a, b, c, d in report.touched]
        out.append("")
    return "\n".join(out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--repo", default=".", help="repository root (default: cwd)")
    ap.add_argument("--base", default="origin/main", help="base revision (merge-base is used)")
    ap.add_argument("--head", default="HEAD", help="head revision (committed changes only)")
    ap.add_argument("--pr-body-file", help="file holding the PR description")
    ap.add_argument("--audit", action="store_true", help="validate the registry at --head only")
    ap.add_argument("--summary-file", help="also append the report to this file (e.g. $GITHUB_STEP_SUMMARY)")
    args = ap.parse_args(argv)
    body = None
    if args.pr_body_file:
        with open(args.pr_body_file, encoding="utf-8") as fh:
            body = fh.read()
    elif "CI_CHECK_PR_BODY" in os.environ:
        body = os.environ["CI_CHECK_PR_BODY"]
    try:
        if args.audit:
            report, title = run_audit(args.repo, args.head), "Configuration-item audit"
        else:
            report, title = run_check(args.repo, args.base, args.head, body), "Configuration-item impact"
    except CheckError as exc:
        print(f"ci_check: {exc}", file=sys.stderr)
        return 2
    text = render(report, title)
    print(text)
    if args.summary_file:
        with open(args.summary_file, "a", encoding="utf-8") as fh:
            fh.write(text + "\n")
    return 1 if report.of("error") else 0


if __name__ == "__main__":
    sys.exit(main())
