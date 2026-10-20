# BumpSetCut / RallyLab documentation index

Plain Markdown with relative links, so this folder opens as an Obsidian vault (point Obsidian at the repo root or at `docs/`) and reads on GitHub. Start here.

## Process

- [Working agreement](workflow/WORKING_AGREEMENT.md) — roles, the nine-step cycle, review gates, what needs the owner first, sources of truth.
- [Independent review](workflow/CHATGPT_REVIEW.md) — Codex on GitHub (primary): triggers, retrieving and answering findings; manual ChatGPT export (fallback) with a tested, context-preserving export.
- [Pull request template](../.github/PULL_REQUEST_TEMPLATE.md) — scope, acceptance criteria, evidence, risks, docs.
- [Hybrid Mac/Windows plan](workflow/HYBRID_MAC_WINDOWS_PLAN.md) — Tailscale connection verified 2026-10-20 (`bens-desktop`, 100.107.21.20); proposed read-only footage/GPU inventory; transfer workflow and remote desktop pending owner authorisation.

## Decisions

- [Decision log](decisions/DECISION_LOG.md) — authoritative; D-001 … D-013.
- [Owner decisions, 2026-10-20](decisions/2026-10-20-phase0-owner-decisions.md) — verbatim primary source for D-001 … D-010.
- [Decision template](templates/DECISION.md).

## ML roadmap and evaluation

- [Roadmap (revised 2026-10-20)](ml-roadmap/ROADMAP_REVISED_2026-10-20.md) — the plan Claude Code executes, **as amended by the decision log**. The copy carries a "superseded passages" banner and inline `[Superseded by D-001]` / `[Amended by D-007]` notes where the owner's later decisions override it (learned classifier is a production candidate, not research-only; tuner objective is constrained recall).
- [Phase 0 baseline](ml-roadmap/BASELINE.md) — repo state, claim-by-claim audit of the roadmap against the code, data/model inventory with hashes, frozen Oct 17 score table, the ten questions that became D-001 … D-010.
- [Experiment registry](ml-roadmap/EXPERIMENT_REGISTRY.md) — links issues ↔ experiments ↔ dataset/split versions ↔ model versions ↔ test results ↔ PRs. Historical rows recovered from memory notes.
- [Experiment template](templates/EXPERIMENT.md).
- `ml-roadmap/experiments/` — one record per experiment (created as experiments run).
- `ml-roadmap/manifests/` — footage and dataset manifests by hash (created when the transfer workflow lands).

## Agent instructions (not duplicated here)

- [`CLAUDE.md`](../CLAUDE.md) — build commands, architecture, product invariants, workflow pointer.
- [`.claude/CLAUDE.md`](../.claude/CLAUDE.md) — behaviour rules.
- [`AGENTS.md`](../AGENTS.md) — Codex repository instructions: operating boundaries and the eight high-value review rules; PR-review output format.
- `.claude/rules/` — branch, worktree, GitHub, datetime and other operating rules.
- `.claude/skills/` — build, run-rallylab, preexisting, device-logs.

## Earlier planning (history, not the tracker)

- `.planning/` — GSD milestone documents for the rally viewer (Jan–Feb 2026), social-features spec, beta-test plan, codebase maps. Kept for reference.
- `.claude/context/` — project context files from the same period.
- `reports/` — gitignored research notes (approach overview, commercial ball tracking, multi-frame detection path).

## Conventions

- Dates in frontmatter are UTC ISO 8601 from `date -u`.
- Decision IDs `D-NNN`; experiment IDs `EXP-YYYYMMDD-slug`; model versions by package name + SHA-256; dataset versions by manifest hash + split id.
- A number that was not measured is written `not measured`, never `0`.
