---
name: working-agreement
status: proposed
created: 2026-10-20T22:12:44Z
updated: 2026-10-20T22:12:44Z
---

# Working agreement

How work on BumpSetCut and RallyLab is defined, implemented, reviewed and merged. Established by owner decision [D-005](../decisions/DECISION_LOG.md#d-005) on 2026-10-20. This document is authoritative; `CLAUDE.md` and `.claude/` rules point here.

## Roles

| Role | Who | Responsibilities |
|---|---|---|
| **Owner** | Benjamin Wierzbanowski | Defines tasks and acceptance criteria. Makes product and architecture decisions. Hands PRs to independent review. Approves and merges. Verifies on the physical iPhone. Authorises anything that installs software or changes network/security settings. |
| **Implementer** | Claude Code (this repo's agent sessions) | Implements on a feature branch. Runs builds and tests. Records evidence, assumptions and limitations in the PR. Addresses every review finding. Keeps the decision log, experiment registry and docs index current as part of each change. Never pushes to `main`, never merges. |
| **Independent reviewer** | ChatGPT, via the owner | Reviews the PR (description, diff, evidence, linked docs) and returns findings. Has no write access. See [CHATGPT_REVIEW.md](CHATGPT_REVIEW.md). |

## The cycle

1. **Define the task.** The owner (or the implementer, proposing) writes the task with measurable acceptance criteria. For ML work the criteria name the metric, the dataset/split version and the comparison baseline.
2. **Branch.** Cut a scoped feature branch from the latest approved `main`: `git checkout main && git pull && git checkout -b <type>/<slug>`. Types: `docs/`, `feat/`, `fix/`, `exp/` (experiment code or reports), `data/` (manifests, labels, provenance). One concern per branch; split large work into sequential PRs.
3. **Implement and test.** Build with `scripts/build.sh` (both targets when shared-pipeline files change). Run the unit suite. Add tests for new behaviour. Run headless RallyLab scoring when pipeline or data code changes.
4. **Record.** In the PR description (template is automatic): affected files, test output, dataset/split/model versions, assumptions, limitations, risks, outstanding issues, docs updated.
5. **Open the PR.** `gh pr create --base main`. Push intermediate commits to the branch freely; the PR is the unit of review.
6. **Independent review.** The owner hands the PR to ChatGPT following [CHATGPT_REVIEW.md](CHATGPT_REVIEW.md) and posts the findings on the PR (or pastes them to the implementer).
7. **Address findings.** Every finding gets a fix or a written reason, in the PR. Further review rounds as needed.
8. **Merge.** Only after the owner's explicit approval, and only by the owner (or by the implementer when the owner says "merge PR #n" for that PR).
9. **Documentation is part of the change.** Decision log, experiment registry, `CLAUDE.md`/rules and the docs index are updated in the same PR, not afterwards.

## Review gates

A PR is ready for review when every applicable row has evidence pasted or linked in the description:

| Change touches | Required evidence |
|---|---|
| Anything | `scripts/build.sh both` succeeded on the branch head; unit suite result with counts |
| Scoring, replay, `SegmentBuilder`, `RallyDecider`, tuner | Scorer fixture tests and replay-vs-`VideoProcessor` parity test pass |
| Dataset, labels, manifests, splits | Leakage audit output; label provenance counts (reviewed vs legacy); hashes of the manifest/split used |
| Trainer or converter | Experiment registry entry with hypothesis, control, seeds, dataset hash; Core ML parity on real frames |
| Processing code shipped in the iOS app | Physical iPhone verification by the owner (noted in the PR); never simulator-only |
| Models or assets referenced by `project.pbxproj` | Committed in the same commit as the pbxproj change |

Numerical acceptance thresholds come from measured evaluation data, not from the task author's intuition ([D-007](../decisions/DECISION_LOG.md#d-007)).

## What the implementer may do without asking

- Anything inside the defined task on the feature branch, including refactors the task needs.
- Create, update and push the branch; open the PR; add tests; update docs.
- Read-only inspection of the desktop over SSH (`bsc-desktop`), read-only dataset inspection, hashing.

## What needs the owner first

- Any decision that departs from the roadmap ([ROADMAP_REVISED_2026-10-20.md](../ml-roadmap/ROADMAP_REVISED_2026-10-20.md)) or from a logged decision.
- Merging. Pushing to `main`. Deleting branches other than the implementer's own.
- Installing software, changing network, firewall, account or security settings on either machine.
- Changing shared-pipeline defaults (`ProcessorConfig`) that alter what users get.
- Editing, moving or deleting footage, labels or dataset sessions outside the task; any write to the desktop footage store.
- Spending GPU time on a training run not already covered by an approved experiment.

## Sources of truth

| Thing | Lives in | Not in |
|---|---|---|
| Decisions | [`docs/decisions/DECISION_LOG.md`](../decisions/DECISION_LOG.md) | chat history, memory notes |
| Experiments, datasets, models, results | [`docs/ml-roadmap/EXPERIMENT_REGISTRY.md`](../ml-roadmap/EXPERIMENT_REGISTRY.md) | scattered reports |
| Plan | [`docs/ml-roadmap/ROADMAP_REVISED_2026-10-20.md`](../ml-roadmap/ROADMAP_REVISED_2026-10-20.md) + decision log | |
| Agent rules | `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/`, `.claude/skills/` | docs/ |
| Annotations | The RallyLab project on the Mac (`~/Movies/RallyLab/Projects/<name>`) | copies on the desktop |
| Source footage and training packages | The desktop `D:\RallyLabFootage` | the Mac, except transient copies |
| Task tracking | GitHub issues and PRs | a second tracker |

`.planning/` holds the earlier GSD milestone documents (rally viewer, social features) and stays as history; it is not the tracker for this work. `.claude/commands/pm` (CCPM) remains available for epics that want it; this workflow does not require it.

## Definition of done

The PR is merged by the owner, the branch is deleted, `main` builds both targets, and the docs index, decision log and registry describe the new state.
