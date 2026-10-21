---
name: working-agreement
status: accepted (D-005, amended by D-014)
created: 2026-10-20T22:12:44Z
updated: 2026-10-21T01:10:00Z
---

# Working agreement

How work on BumpSetCut and RallyLab is defined, implemented, reviewed and merged. Established by owner decision [D-005](../decisions/DECISION_LOG.md#d-005) and amended by [D-014](../decisions/DECISION_LOG.md#d-014) (review tiers, Codex as reviewer). This document is authoritative; `CLAUDE.md`, `AGENTS.md` and `.claude/` rules point here rather than restating it.

## Roles

| Role | Who | Responsibilities |
|---|---|---|
| **Owner** | Benjamin Wierzbanowski | Defines tasks and acceptance criteria. Makes product and architecture decisions. Decides which review tier a change needs. Resolves or explicitly accepts blocking findings. Approves and merges. Verifies on the physical iPhone. Authorises anything that installs software or changes network/security settings. |
| **Implementer** | Claude Code | Implements on a feature branch. Runs builds and tests. Records evidence, assumptions and limitations in the PR. Addresses every review finding. Keeps the decision log, experiment registry and docs index current as part of each change. **Never pushes to `main` and never merges without explicit owner authorisation.** |
| **Independent reviewer** | Codex (the GitHub app `chatgpt-codex-connector`), with ChatGPT as a manual fallback or second opinion | Reviews PRs and posts findings. Has no merge authority. Its repository instructions are `AGENTS.md`. Hand-off details: [CHATGPT_REVIEW.md](CHATGPT_REVIEW.md). |

## Review tiers (D-014)

The owner decides when a formal PR is required. Default by kind of change:

| Tier | Applies to | Process |
|---|---|---|
| **PR with independent review** (default) | ML models, datasets, labels, manifests and splits; training pipelines and scripts; evaluation methodology, scorers, replay, tuner; architecture; the shared processing pipeline and `ProcessorConfig` defaults; significant production behaviour; `project.pbxproj` model membership; migrations; security or network settings; anything the owner asks to see reviewed | The full cycle below. Codex reviews automatically when the PR opens. **Blocking findings are resolved or explicitly accepted by the owner in the PR** before merge. Owner merges. |
| **Streamlined** (only when the owner explicitly authorises it for that change) | Minor UI adjustments, cosmetic changes, documentation corrections, low-risk bug fixes | Feature branch, build and tests as usual, push. Either the owner merges the branch (a PR without waiting for review), or, when the owner's authorisation says so for that specific change, the implementer pushes to `main` directly. The authorisation is quoted in the commit message. No Codex round required. |

The owner can require a PR for any change and can grant an exception for any change. Absent explicit authorisation, the PR tier applies.

## The cycle (PR tier)

1. **Define the task.** The owner (or the implementer, proposing) writes the task with measurable acceptance criteria. For ML work the criteria name the metric, the dataset/split version and the comparison baseline.
2. **Branch.** Cut a scoped feature branch from the latest approved `main`: `git checkout main && git pull && git checkout -b <type>/<slug>`. Types: `docs/`, `feat/`, `fix/`, `exp/` (experiment code or reports), `data/` (manifests, labels, provenance). One concern per branch; split large work into sequential PRs.
3. **Implement and test.** Build with `scripts/build.sh` (both targets when shared-pipeline files change). Run the unit suite. Add tests for new behaviour. Run headless RallyLab scoring when pipeline or data code changes.
4. **Record.** Fill `.github/PULL_REQUEST_TEMPLATE.md` with real output: affected files, test output, dataset/split/model versions, assumptions, limitations, risks, outstanding issues, docs updated. The template is **not** applied by `gh pr create --fill`; pass the filled file explicitly:
   ```bash
   gh pr create --base main --head <branch> --title "<title>" --body-file <filled-template.md>
   ```
5. **Open the PR.** Push intermediate commits to the branch freely; the PR is the unit of review. Codex reviews on open; after further commits, comment `@codex review` to re-run.
6. **Independent review.** Findings arrive as inline PR review comments (Codex) or as a posted comment (manual ChatGPT export). See [CHATGPT_REVIEW.md](CHATGPT_REVIEW.md).
7. **Address findings.** Every finding gets a fix commit or a written reason in the PR. Blocking findings (Codex P0/P1, or "Blocking defect" per `AGENTS.md`) are resolved, or the owner explicitly accepts them in a PR comment. Further review rounds as needed.
8. **Merge.** Only after the owner's explicit approval, and only by the owner (or by the implementer when the owner says "merge PR #n" for that PR).
9. **Documentation is part of the change.** Decision log, experiment registry, `CLAUDE.md`/rules and the docs index are updated in the same PR, not afterwards.

## Review gates

A PR is ready for review when every applicable row has evidence pasted or linked in the description:

| Change touches | Required evidence |
|---|---|
| Anything | `scripts/build.sh both` succeeded on the branch head; unit suite result with counts (or "not run" with the reason) |
| Scoring, replay, `SegmentBuilder`, `RallyDecider`, tuner | Scorer fixture tests and replay-vs-`VideoProcessor` parity test pass |
| Dataset, labels, manifests, splits | Leakage audit output; label provenance counts (reviewed vs legacy); hashes of the manifest/split used |
| Trainer or converter | Experiment registry entry with hypothesis, control, seeds, dataset hash; Core ML parity on real frames |
| Processing code shipped in the iOS app | Physical iPhone verification by the owner (noted in the PR); never simulator-only |
| Models or assets referenced by `project.pbxproj` | Committed in the same commit as the pbxproj change |

Numerical acceptance thresholds come from measured evaluation data, not from the task author's intuition ([D-007](../decisions/DECISION_LOG.md#d-007)).

## What the implementer may do without asking

- Anything inside the defined task on the feature branch, including refactors the task needs.
- Create, update and push the branch; open the PR; add tests; update docs; reply to review findings on the PR.
- Read-only inspection of the desktop over SSH (`bsc-desktop` on the LAN, `bens-desktop` over Tailscale), read-only dataset inspection, hashing.

## What needs the owner first

- Any decision that departs from the roadmap ([ROADMAP_REVISED_2026-10-20.md](../ml-roadmap/ROADMAP_REVISED_2026-10-20.md)) or from a logged decision.
- Merging. Pushing to `main`. Using the streamlined tier. Deleting branches other than the implementer's own.
- Installing software, changing network, firewall, account or security settings on either machine.
- Changing shared-pipeline defaults (`ProcessorConfig`) that alter what users get.
- Editing, moving or deleting footage, labels or dataset sessions outside the task; any write to the desktop footage store.
- Spending GPU time on a training run not already covered by an approved experiment.
- Accepting a blocking review finding without fixing it.

## Sources of truth

| Thing | Lives in | Not in |
|---|---|---|
| Decisions | [`docs/decisions/DECISION_LOG.md`](../decisions/DECISION_LOG.md) | chat history, memory notes |
| Experiments, datasets, models, results | [`docs/ml-roadmap/EXPERIMENT_REGISTRY.md`](../ml-roadmap/EXPERIMENT_REGISTRY.md) | scattered reports |
| Plan | [`docs/ml-roadmap/ROADMAP_REVISED_2026-10-20.md`](../ml-roadmap/ROADMAP_REVISED_2026-10-20.md) as amended by the decision log | |
| Agent rules | `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/`, `.claude/skills/` (Claude Code); `AGENTS.md` (Codex) | docs/ |
| Annotations | The RallyLab project on the Mac (`~/Movies/RallyLab/Projects/<name>`) | copies on the desktop |
| Source footage and training packages | The desktop `D:\RallyLabFootage` | the Mac, except transient copies |
| Task tracking | GitHub issues and PRs | a second tracker |

`.planning/` holds the earlier GSD milestone documents (rally viewer, social features) and stays as history; it is not the tracker for this work. The CCPM add-on (`/pm:*` epic and PRD commands, their scripts, worktree/branch/agent-coordination rules) was removed on 2026-10-20 as unused third-party tooling that contained direct-to-`main` merge paths; GitHub issues and PRs are the only tracker.

## Definition of done

The PR is merged by the owner, the branch is deleted, `main` builds both targets, and the docs index, decision log and registry describe the new state.
