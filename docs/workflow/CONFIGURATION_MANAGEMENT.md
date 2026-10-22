---
name: configuration-management
status: proposed (D-020)
created: 2026-10-22T02:29:29Z
updated: 2026-10-22T02:29:29Z
decision: D-020
---

# Configuration management

Roadmaps, decisions, lineages, experiment records, dataset records, legal text, product configuration and similar artefacts are **configuration items**: version-controlled, identified, and changed only through the PR workflow of the [working agreement](WORKING_AGREEMENT.md). This repository is authoritative for them. Read-only views elsewhere (dashboards, mirrors) are never edited and never committed back as competing copies.

- **Registry:** [`docs/config-items.toml`](../config-items.toml) (schema 1, parsed with Python's standard library).
- **Check:** [`scripts/ci_check.py`](../../scripts/ci_check.py), run locally and by the read-only [`ci-impact`](../../.github/workflows/ci-impact.yml) workflow on every PR.
- **Tests:** `python3 -m unittest discover -s scripts/tests`.

## Items and families

An **item** (`CI-BSC-NNN`) is one important file registered individually: the decision log, each verbatim owner-decision note, the roadmap, the baseline, the model lineages, the legal documents. A **family** (`CF-BSC-NNN`) governs every file matching its patterns, so a new experiment record, dataset report or owner note is controlled the moment it is added, without a new registry row. An individually registered file is governed by its item, not by a family. A file may match at most one family.

Each record carries its type, lifecycle, change class, approval policy, source dependencies (`sources`), update triggers (`triggers`) and, for generated artefacts, the command that regenerates them (`generated_by`). **Revision metadata is never typed in**: the latest commit, its PR, the git blob id and the SHA-256 of a file are derived from git history by whoever reads the registry.

IDs are stable. An id is never renumbered or reused; a record that stops applying moves to `lifecycle = "retired"` instead of being deleted.

The type vocabulary already covers the later milestones (architecture diagrams, timelines, dependency maps, model-performance charts, feature matrices, App Store screenshot sets, marketing copy, subscription configuration, legal disclosures, privacy manifest, release assets and notes). Planned artefacts are registered with `lifecycle = "planned"` and no path; they are inactive until they get one.

## Change classes

| Class | What may change | How a change is checked |
|---|---|---|
| `living` | anything, in a PR | Changes to `approval = "owner"` items are listed for the owner. |
| `append-only` | new entries; an existing entry only by a **controlled status transition**: its status on the title line (e.g. `accepted` → `superseded by D-NNN`) or an appended dated `**Status YYYY-MM-DD.**` paragraph | Any other edit, removal or reordering of an existing entry is an **error**. A status transition not listed under *Owner approval requested* is an **error**. |
| `frozen` | nothing, ever | Any modification, deletion or rename is an **error**. Correction = a new record with `superseded_by` set on the old one. |

Frozen items pin `frozen_sha256`: the SHA-256 of the file's bytes, which is not the git blob id (a blob id is SHA-1 over a `blob <size>\0` header plus the bytes). Experiment records are living until their frontmatter `status` is `done` or `abandoned`, then frozen (`freeze_when`).

**Protections come from the base, not the PR.** The PR's changes are measured from the merge-base; the records they may not touch are those protected by the registry at the merge-base *or* at the current tip of `main`, so a stale branch cannot edit a record frozen after it branched. A PR cannot make a frozen record editable by re-pinning its hash, renaming it, changing its class or path, removing it from the registry, narrowing a frozen family's patterns, or registering a frozen family member as a living item: each of those is itself an error, and **frozen wins** wherever an item and a family overlap. The workflow also runs the base branch's copy of the checker, so a PR cannot weaken the check that judges it.

Current classification (owner decision 8, 2026-10-22): historical baselines, verbatim owner-decision notes and accepted audits are frozen; the current plan, model lineages, experiment registry and process documents are living; the decision log is append-only with controlled status transitions. The 2026-10-20 roadmap keeps its original wording frozen; amendments go to [ROADMAP_AMENDMENTS.md](../ml-roadmap/ROADMAP_AMENDMENTS.md). A newly generated audit is a new versioned file, not an edit of an old one.

## What the check reports

| Level | Meaning | Examples |
|---|---|---|
| **error** (fails the check) | the registry is invalid, or a historical record was changed | unknown key or type, duplicate id, missing file, frozen hash mismatch, a `D-NNN` not in the log, overlapping families; frozen record edited; historical entry edited; undeclared status transition |
| **owner attention** | a change only the owner can authorise | an `approval = "owner"` item changed; a status transition; a new decision entry recorded as anything but `proposed`; a supersession |
| **warning** | possible missing documentation | a trigger path changed without its item; a new file under `docs/`, `legal/` or `marketing/` that no item or family covers; a generated artefact edited without its regeneration command in the PR |

The check never edits files, never comments, labels or approves, and needs no secrets. Warnings start as warnings; promoting the watched-path and unregistered-document warnings to errors is the owner's call after about five representative PRs, based on false positives seen.

## What a PR does

1. Fill the **Configuration items** section of the [PR template](../../.github/PULL_REQUEST_TEMPLATE.md): every item or family member touched, and the list *Owner approval requested*.
2. For a trigger that fired but needs no update, add a waiver line with a reason: `CI-BSC-030: no update needed — refactor only, no change to what is packaged`.
3. For a new document that should stay unregistered: ``unregistered: `docs/x.md` — reason``.
4. Run `python3 scripts/ci_check.py --base origin/main --pr-body-file <filled body>` and paste the result; the `ci-impact` job re-runs it on GitHub with the real PR body.

## Approval

The *Owner approval requested* list is a **request, not an authorisation**. Approval is the owner's explicit authorisation in the PR or in the owner's own instructions, followed by the owner's merge. A passing `ci-impact` check, a clean Codex review or a dashboard never counts as approval, and nothing may infer it from them. An **error** can only be set aside by the owner, in writing, in the PR; the implementer never does it.

## Adding or changing records

- **New important document:** add an `[[item]]` with the next free id; frozen records pin `shasum -a 256 <file>`.
- **New kind of recurring artefact:** add a `[[family]]` with patterns, class and policy.
- **Superseding a frozen record:** add the new record, then set `lifecycle = "superseded"` and `superseded_by` on the old one; leave its file and pin as they are.
- **Audit of the whole registry** (e.g. on `main`): `python3 scripts/ci_check.py --audit`.

This repository is public: the registry and its notes hold no machine paths, credentials, private strategy or unpublished assets.
