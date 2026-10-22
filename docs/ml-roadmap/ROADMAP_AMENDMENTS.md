---
name: roadmap-amendments
status: living (CI-BSC-021)
created: 2026-10-22T02:29:29Z
updated: 2026-10-22T02:29:29Z
---

# Roadmap amendments

The current plan is the [revised roadmap of 2026-10-20](ROADMAP_REVISED_2026-10-20.md) (CI-BSC-020) **as amended by the decision log**. The roadmap file is frozen: it keeps the owner's wording and the bracketed notes it was committed with in PR #65, and is never edited again. Amendments are recorded here instead. This page is an index; the [decision log](../decisions/DECISION_LOG.md) stays authoritative, and where the two disagree the log wins.

How to add an amendment: when a decision changes what the roadmap says to do, add a row to *Amendments after the roadmap was frozen* in the same PR as the decision, naming the roadmap section it affects. `scripts/ci_check.py` warns when the decision log changes without this page (waive with `CI-BSC-021: no update needed — <reason>` when a decision does not touch the plan).

## Inline notes in the frozen roadmap

Present since the roadmap was committed (`2c5bdca`); listed so they can be found without reading the whole document.

| Decision | Roadmap passage | Note in the roadmap |
|---|---|---|
| D-001 | Decision in one page — "Do not do a wholesale rewrite" | `[Superseded by D-001]` — learned temporal classifier is an approved production candidate |
| D-001 | Conflicts Claude must not silently resolve — "Research proposal vs product invariant" | `[Superseded by D-001]` — no approval gate on experimentation |
| D-007 | Conflicts Claude must not silently resolve — "User's 4x cost phrasing vs actual code" | `[Amended by D-007]` — constrained complete-rally recall is primary; 0.25 score is a diagnostic |
| D-001 | Non-negotiable engineering constraints, item 4 | `[Superseded by D-001]` — classifier developed as a production candidate |
| D-001 | Phase 8 — Optional shadow TCN vs deterministic FSM | `[Superseded by D-001]` — no longer P2 or approval-gated |
| D-001 | Experiment matrix, row E09 | `[Amended by D-001]` — ships via the PR tier with independent validation |
| D-001 | Claude Code execution brief (two passages) | `[Superseded by D-001]` |

The roadmap's repository note also records that D-002, D-009 and D-010 are consistent with it and refine it.

## Amendments after the roadmap was frozen

Decisions logged after the roadmap whose entries change the plan. The section column is filled only where the entry names the roadmap passage. Decisions that only settle how a phase is carried out (D-003 … D-006, D-008, D-014, D-015) are not repeated here.

| Decision | Date | Roadmap section affected | Change |
|---|---|---|---|
| D-016 | 2026-10-21 | Two independent validation products (final-test collection) | The seven provisional candidates are not promotable; the roadmap's new-footage final-test collection is the only path to a verified `final_test`. |
| D-017 | 2026-10-21 | not named in the entry (owner to confirm) | Adds a model-lineage holdout (16 recordings) withheld from all future training, distinct from the final test; new lineages preregister before evaluating on it. |
| D-018 | 2026-10-21 | not named in the entry (owner to confirm) | L2 training only from a manifest-generated package with a fail-closed preflight; preregistration from a fixed template is mandatory before any L2 training. |
| D-019 | 2026-10-21 | not named in the entry (owner to confirm) | First L2 recipe approved with amendments (paired H1, label provenance, one seed); training and holdout evaluation each need separate authorisation. |
