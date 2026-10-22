# BumpSetCut / RallyLab documentation index

Plain Markdown with relative links, so this folder opens as an Obsidian vault (point Obsidian at the repo root or at `docs/`) and reads on GitHub. Start here.

## Process

- [Working agreement](workflow/WORKING_AGREEMENT.md) — roles, the nine-step cycle, review gates, what needs the owner first, sources of truth.
- [Independent review](workflow/CHATGPT_REVIEW.md) — Codex on GitHub (primary): triggers, retrieving and answering findings; manual ChatGPT export (fallback) with a tested, context-preserving export.
- [Footage share](workflow/FOOTAGE_SHARE.md) — read-only SMB share of the desktop's footage over Tailscale, staging share for L2 packages, file-by-file links on the Mac; exact Windows and macOS steps, applied 2026-10-22, with the working mount commands and what differed.
- [Pull request template](../.github/PULL_REQUEST_TEMPLATE.md) — scope, acceptance criteria, evidence, risks, docs.
- [Hybrid Mac/Windows plan](workflow/HYBRID_MAC_WINDOWS_PLAN.md) — Tailscale connection verified 2026-10-20 (`bens-desktop`, 100.107.21.20); proposed read-only footage/GPU inventory; transfer workflow and remote desktop pending owner authorisation.

## Decisions

- [Decision log](decisions/DECISION_LOG.md) — authoritative; D-001 … D-019.
- [Owner decisions, 2026-10-20](decisions/2026-10-20-phase0-owner-decisions.md) — verbatim primary source for D-001 … D-010.
- [Owner decisions, 2026-10-21 (L2)](decisions/2026-10-21-l2-owner-decisions.md) — verbatim primary source for D-018 (dataset isolation, preregistration).
- [Owner decisions, 2026-10-21 (PR #73, L2 recipe)](decisions/2026-10-21-l2-approval-decisions.md) — verbatim primary source for D-019 (merge, recipe approved with amendments, one seed, legacy holdout confirmed).
- [Decision template](templates/DECISION.md).

## ML roadmap and evaluation

- [Roadmap (revised 2026-10-20)](ml-roadmap/ROADMAP_REVISED_2026-10-20.md) — the plan Claude Code executes, **as amended by the decision log**. The copy carries a "superseded passages" banner and inline `[Superseded by D-001]` / `[Amended by D-007]` notes where the owner's later decisions override it (learned classifier is a production candidate, not research-only; tuner objective is constrained recall).
- [Phase 0 baseline](ml-roadmap/BASELINE.md) — repo state, claim-by-claim audit of the roadmap against the code, data/model inventory with hashes, frozen Oct 17 score table, the ten questions that became D-001 … D-010.
- [Model lineages](ml-roadmap/MODEL_LINEAGES.md) — L1 (every model to date, historical) and L2 (planned from-scratch lineage after the D-017 cut-over): cut-over hashes, withheld recordings, preregistration requirements.
- [Experiment registry](ml-roadmap/EXPERIMENT_REGISTRY.md) — links issues ↔ experiments ↔ dataset/split versions ↔ model versions ↔ test results ↔ PRs. Historical rows recovered from memory notes.
- [Provenance audit, 2026-10-21](ml-roadmap/PROVENANCE_AUDIT_2026-10-21.md) — Task B.1 result on Scratch: split manifest, exposure history, the one hard leak, final-test candidates, and the five decisions for the owner.
- [Provenance questions, 2026-10-21](ml-roadmap/PROVENANCE_QUESTIONS_2026-10-21.md) — what only the owner can answer after D-015: Q0 (pre-tracking) is settled by D-016; venue/session for the seven candidates and the legacy-holdout uploader overlap are answered on the review page.
- [Visual provenance review, 2026-10-21](ml-roadmap/PROVENANCE_REVIEW_2026-10-21.md) — how to generate and use the local frame-review page (`scripts/provenance_review.py`), the thumbnail → recording mapping, the answer file format, the answers applied on 2026-10-21 and the reservation consequence awaiting D-017.
- `ml-roadmap/manifests/<project>/` — committed `manifest.json` / `audit.json` (+ `.md`) per project, regenerated with `RallyLab --project <name> --audit-dataset`; also the YouTube source-ID reports and validation.json before/after copies.
- [Experiment template](templates/EXPERIMENT.md).
- [Dataset hygiene](ml-roadmap/DATASET_HYGIENE.md) — known session/dataset inconsistencies (H-1: 54 dangling frame records in a legacy-holdout session) and the proposed, not yet approved, cleanup procedure with backup and verification.
- [Lineage preregistration template](templates/PREREGISTRATION_L2.md) — the ten sections every L2 training run fills and the owner approves before training (D-018).
- [EXP-20261021-l2-scratch-prereg](ml-roadmap/experiments/EXP-20261021-l2-scratch-prereg.md) — proposed first L2 run (not approved): recipe, data counts, holdout rules.
- `ml-roadmap/manifests/<project>/l2/` — lineage package plans and records (`RallyLab --package-l2`): what is eligible, what is withheld, preflight results and file hashes.
- `ml-roadmap/experiments/` — one record per experiment, written before it runs.
- `ml-roadmap/manifests/` — footage and dataset manifests by hash (created when the transfer workflow lands).

## Agent instructions (not duplicated here)

- [`CLAUDE.md`](../CLAUDE.md) — build commands, architecture, product invariants, workflow pointer.
- [`.claude/CLAUDE.md`](../.claude/CLAUDE.md) — behaviour rules.
- [`AGENTS.md`](../AGENTS.md) — Codex repository instructions: operating boundaries and the eight high-value review rules; PR-review output format.
- `.claude/rules/` — GitHub operations, datetime, test execution, ast-grep. (The CCPM add-on's epic/worktree/PRD commands and rules were removed 2026-10-20.)
- `.claude/skills/` — build, run-rallylab, preexisting, device-logs.

## Earlier planning (history, not the tracker)

- `.planning/` — GSD milestone documents for the rally viewer (Jan–Feb 2026), social-features spec, beta-test plan, codebase maps. Kept for reference.
- `.claude/context/` — project context files from the same period.
- `reports/` — gitignored research notes (approach overview, commercial ball tracking, multi-frame detection path).

## Conventions

- Dates in frontmatter are UTC ISO 8601 from `date -u`.
- Decision IDs `D-NNN`; experiment IDs `EXP-YYYYMMDD-slug`; model versions by package name + SHA-256; dataset versions by manifest hash + split id.
- A number that was not measured is written `not measured`, never `0`.
