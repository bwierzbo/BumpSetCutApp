# BumpSetCut / RallyLab documentation index

Plain Markdown with relative links, so this folder opens as an Obsidian vault (point Obsidian at the repo root or at `docs/`) and reads on GitHub. Start here.

## Process

- [Working agreement](workflow/WORKING_AGREEMENT.md) — roles, the nine-step cycle, review gates, what needs the owner first, sources of truth.
- [Independent review](workflow/CHATGPT_REVIEW.md) — Codex on GitHub (primary): triggers, retrieving and answering findings; manual ChatGPT export (fallback) with a tested, context-preserving export.
- [Footage share](workflow/FOOTAGE_SHARE.md) — read-only SMB share of the desktop's footage over Tailscale, staging share for L2 packages, file-by-file links on the Mac; exact Windows and macOS steps, applied 2026-10-22, with the working mount commands and what differed.
- [Migration 048 deployment](workflow/MIGRATION_048_DEPLOYMENT.md) — the Stage 1 sync's server side (not applied): tables, functions, privileges, RLS and triggers; local authorization and concurrency tests; the owner's deployment and verification checklist; rollback that preserves annotations.
- [Migration 049: restrict protected footage](workflow/MIGRATION_049_PROTECT_FOOTAGE.md) — owner decision to restrict, not delete (not applied): ordinary labelers lose read, sign, change and delete on protected recordings' rows, annotations and copies and on the unreferenced object; local tests; residual risk from issued signed URLs and copies on devices; deployment checklist and rollback.
- [Configuration management](workflow/CONFIGURATION_MANAGEMENT.md) — which documents and records are controlled ([registry](config-items.toml)), the living / append-only / frozen change classes, the `ci-impact` check (`scripts/ci_check.py`), and how approval works.
- [Pull request template](../.github/PULL_REQUEST_TEMPLATE.md) — scope, acceptance criteria, evidence, risks, docs, configuration items.
- [Hybrid Mac/Windows plan](workflow/HYBRID_MAC_WINDOWS_PLAN.md) — Tailscale connection verified 2026-10-20 (`bens-desktop`, 100.107.21.20); proposed read-only footage/GPU inventory; transfer workflow and remote desktop pending owner authorisation.

## Decisions

- [Decision log](decisions/DECISION_LOG.md) — authoritative; D-001 … D-021 (D-020 proposed).
- [Decision log](decisions/DECISION_LOG.md) — authoritative; D-001 … D-020.
- [Owner decisions, 2026-10-20](decisions/2026-10-20-phase0-owner-decisions.md) — verbatim primary source for D-001 … D-010.
- [Owner decisions, 2026-10-21 (L2)](decisions/2026-10-21-l2-owner-decisions.md) — verbatim primary source for D-018 (dataset isolation, preregistration).
- [Owner decisions, 2026-10-21 (PR #73, L2 recipe)](decisions/2026-10-21-l2-approval-decisions.md) — verbatim primary source for D-019 (merge, recipe approved with amendments, one seed, legacy holdout confirmed).
- [Owner decision, 2026-10-22 (D-007 threshold)](decisions/2026-10-22-d007-threshold-decision.md) — verbatim: no numerical dead-time ceiling or recall target yet; target configurable but unset; no winner declared under D-007 until approved.
- [Owner decisions, 2026-10-22 (scoring contract, GUI)](decisions/2026-10-22-scoring-and-gui-decisions.md) — verbatim primary source for D-021 (masking diagnostics, false clips per segment, 0.98 provisional, GUI principles, protected-recording refusal).
- [Progressive rally review owner direction, 2026-10-23](decisions/2026-10-23-progressive-rally-review-owner-direction.md) — D-024: full-video boundary review for the MVP, optional contact-stage review, player identification deferred.
- [Owner direction, 2026-10-24 (L2 run 4, undecodable HEVC frames)](decisions/2026-10-24-l2-run4-undecodable-frames-direction.md) — verbatim primary source for D-025: record reproducibly undecodable HEVC leading pictures and leave out the windows that need them; counts reconciled; PR preparation only, no merge, restart or training.
- [Owner review follow-up, 2026-10-24 (PR #93)](decisions/2026-10-24-l2-pr93-review-followup-direction.md) — verbatim: the HEVC exception is D-025 (D-024 stays the progressive RallyLab review decision, PR #90); rebase PR #93 after PR #90 merges, re-review, then return it for merge authorisation; export restart, training and holdout evaluation stay gated.
- [Owner overnight authorisation, 2026-10-24 (L2 export recovery)](decisions/2026-10-24-l2-overnight-recovery-authorization.md) — verbatim: merge PR #93 once clean (D-025 accepted), restore the shares under the approved configuration, resume the Stage D export in place, verify the package, prepare the completed preregistration and a read-only Stage 1 plan; training, holdout evaluation, promotion and network changes stay unauthorised.
- [Owner final approval and training authorisation, 2026-10-25 (L2)](decisions/2026-10-25-l2-final-approval-and-training-authorization.md) — verbatim: final approval of EXP-20261021-l2-scratch-prereg as merged in PR #95 incl. the §10 preservation policy; first L2 training run authorised on the approved recipe; second seed, holdout evaluation, promotion and deployment stay unauthorised.
- [Owner direction, 2026-10-26 (Stage 1 on Mac and iPhone)](decisions/2026-10-26-stage1-mac-iphone-direction.md) — verbatim: PR #98 merge approved; the same Stage 1 review on the Labeler iPhone app with Supabase sync, one shared schema and rules, iPhone commits gated on proven frame identity, owner-only TestFlight after the PRs merge, the pilot prepared in parallel; four PRs, each owner-approved; L2 training untouched.
- [Owner direction, 2026-10-26 (complete Mac + iPhone, prepare TestFlight)](decisions/2026-10-26-stage1-testflight-direction.md) — verbatim: PR #99 merge approved; #100 finished with source identity, protected reads and server-side footage identity; read-only footage inventory; copy frame identity verified before TestFlight; #101 finalised; #102 without the freeze; migration 048 returned for approval; owner-only TestFlight after #99–#101 merge and 048 is applied and verified.
- [Owner approvals, 2026-10-26 evening (iPhone Stage 1 integration)](decisions/2026-10-26-stage1-integration-approvals.md) — verbatim: #103 merge; #100 merge after a clean final review; migration 048 to be applied with security checks and the lead's publication; #101 after verification, with the end-to-end checks before an owner-only TestFlight; protected footage restricted, not deleted (fix prepared for separate deployment approval); #102 held; L2 untouched.
- [Owner decisions, 2026-10-27 (TestFlight, 049 corrections, #102 rebase)](decisions/2026-10-27-next-owner-decisions.md) — verbatim: an owner-only internal TestFlight upload; migration 049's destination-name and status-constraint corrections before a deployment decision; #102 rebased, not merged or frozen; L2 unchanged.
- [Owner direction, 2026-10-23 (L2 labels people's only)](decisions/2026-10-23-l2-labels-people-only-direction.md) — verbatim primary source for D-023 (interrupt Stage D, keep the 43 recordings, lineage eligibility rule, recovery plan for review).
- [Owner decisions, 2026-10-22 (L2 export recovery)](decisions/2026-10-22-l2-export-recovery-decision.md) — verbatim primary source for D-022: LAN SMB restricted to the Mac, partial package preserved, resumable export with validated frame reuse, gates unchanged.
- [Decision template](templates/DECISION.md).

## ML roadmap and evaluation

- [Roadmap (revised 2026-10-20)](ml-roadmap/ROADMAP_REVISED_2026-10-20.md) — frozen; the plan Claude Code executes, **as amended by the decision log**; later amendments are indexed in [Roadmap amendments](ml-roadmap/ROADMAP_AMENDMENTS.md), not written into the roadmap. The copy carries a "superseded passages" banner and inline `[Superseded by D-001]` / `[Amended by D-007]` notes where the owner's later decisions override it (learned classifier is a production candidate, not research-only; tuner objective is constrained recall).
- [Phase 0 baseline](ml-roadmap/BASELINE.md) — repo state, claim-by-claim audit of the roadmap against the code, data/model inventory with hashes, frozen Oct 17 score table, the ten questions that became D-001 … D-010.
- [Model lineages](ml-roadmap/MODEL_LINEAGES.md) — L1 (every model to date, historical) and L2 (planned from-scratch lineage after the D-017 cut-over): cut-over hashes, withheld recordings, preregistration requirements.
- [Experiment registry](ml-roadmap/EXPERIMENT_REGISTRY.md) — links issues ↔ experiments ↔ dataset/split versions ↔ model versions ↔ test results ↔ PRs. Historical rows recovered from memory notes.
- [Provenance audit, 2026-10-21](ml-roadmap/PROVENANCE_AUDIT_2026-10-21.md) — Task B.1 result on Scratch: split manifest, exposure history, the one hard leak, final-test candidates, and the five decisions for the owner. Frozen as written (CI-BSC-034): its "awaiting owner decisions" status is historical; the five questions were resolved by [D-015](decisions/DECISION_LOG.md#d-015) and the audit text is not edited.
- [Provenance questions, 2026-10-21](ml-roadmap/PROVENANCE_QUESTIONS_2026-10-21.md) — what only the owner can answer after D-015: Q0 (pre-tracking) is settled by D-016; venue/session for the seven candidates and the legacy-holdout uploader overlap are answered on the review page.
- [Visual provenance review, 2026-10-21](ml-roadmap/PROVENANCE_REVIEW_2026-10-21.md) — how to generate and use the local frame-review page (`scripts/provenance_review.py`), the thumbnail → recording mapping, the answer file format, the answers applied on 2026-10-21 and the reservation consequence awaiting D-017.
- `ml-roadmap/manifests/<project>/` — committed `manifest.json` / `audit.json` (+ `.md`) per project, regenerated with `RallyLab --project <name> --audit-dataset`; also the YouTube source-ID reports and validation.json before/after copies.
- [Experiment template](templates/EXPERIMENT.md).
- [Scoring implementation plan](ml-roadmap/SCORING_IMPLEMENTATION_PLAN.md) — PRs A (tick intervals, rational thresholds, the two scorers, 23 fixture tests + production-finalization tests), B (callers, `evaluation_v2.json`, D-007 objective), C (replay parity, D-008, raw boundaries in metadata, iPhone gate); exact files, interfaces, test strategy.
- [L2 training readiness, 2026-10-22](ml-roadmap/L2_TRAINING_READINESS_2026-10-22.md) — read-only check of the desktop (GPU, torch/CUDA, disks, scripts, L1 checkpoint hash), the approved commands as they will run, and the conditions before the preregistered run (GPU idle, export preflight, desktop verify).
- [Scoring contract v1](ml-roadmap/SCORING_CONTRACT.md) — Phase 2: raw-boundary scorer vs padded-export scorecard (exact definitions, tick time base, excluded spans), 13 inconsistencies found in today's scorers with file:line, 12 pinned fixtures + the Python reference implementation (`scripts/scoring/reference_scorecard.py`), implementation PR plan.
- [Dataset review & repair GUI plan](ml-roadmap/DATASET_REVIEW_GUI_PLAN.md) — owner milestone 2026-10-22: health queue, original-video frame stepping and trim proposals, independent event annotation, versioned non-destructive corrections, identity/leakage checks, before/after evidence; Phase 1A event-review tool first; PR order G0–G6.
- [Stage 1 Rally Boundaries review: implementation plan](ml-roadmap/STAGE1_RALLY_BOUNDARIES_PLAN.md) — read-only plan under D-024 for owner review: `rallyevents.json` schema with coverage and persistent rally ids, refusal through the withheld closure with a ledger row, the Rally Boundaries tab, read-only inventory commands, tests and PR order; nothing built.
- [iPhone copy frame identity, 2026-10-26](ml-roadmap/IPHONE_COPY_FRAME_IDENTITY_2026-10-26.md) — v3 copies keep every frame at its presentation time (7 recordings: H.264/HEVC, CFR/VFR, rotated, trimmed, open-GOP; PSNR ≥ 32 dB on every frame); the frame-time reading is corrected to the presentation timeline; 63 eligible copies are still v2.
- [Protected-footage inventory, 2026-10-26](ml-roadmap/PROTECTED_FOOTAGE_INVENTORY_2026-10-26.md) — read-only: 8 withheld recordings (3 lineage holdout, 5 legacy holdout) have copies in the labeling bucket readable by every labeler; 2 were uploaded after the D-017 cut-over; download exposure cannot be ruled out; one unreferenced object of unknown source; options for the owner.
- [Event boundary review protocol](ml-roadmap/EVENT_BOUNDARY_REVIEW_PROTOCOL.md) — Phase 1A / Task B.2: the 24-event serve-contact / dead-ball calibration pilot on development recordings (rubric, uncertainty intervals, blind second review, `rallyevents.json` provenance sidecar, outputs, tooling PRs, blockers).
- [L2 source verification proposal](ml-roadmap/L2_SOURCE_VERIFICATION_PROPOSAL.md) — proposed strict full-file SHA-256 of every packaged and withheld source video in the preflight (fail closed, identities and ledgers untouched); reconciliation of the protected-content inventory (closure 21, 452 files, 54 dangling).
- [Dataset hygiene](ml-roadmap/DATASET_HYGIENE.md) — known session/dataset inconsistencies (H-1: 54 dangling frame records in a legacy-holdout session) and the proposed, not yet approved, cleanup procedure with backup and verification.
- [Lineage preregistration template](templates/PREREGISTRATION_L2.md) — the ten sections every L2 training run fills and the owner approves before training (D-018).
- [EXP-20261021-l2-scratch-prereg](ml-roadmap/experiments/EXP-20261021-l2-scratch-prereg.md) — proposed first L2 run (not approved): recipe, data counts, holdout rules.
- `ml-roadmap/manifests/<project>/l2/` — lineage package plans and records (`RallyLab --package-l2`): what is eligible, what is withheld, preflight results and file hashes.
- `ml-roadmap/experiments/` — one record per experiment, written before it runs.
- `ml-roadmap/manifests/` — footage and dataset manifests by hash (created when the transfer workflow lands).

## Agent instructions (not duplicated here)

- [`CLAUDE.md`](../CLAUDE.md) — build commands, architecture, product invariants, workflow pointer.
- [`.claude/CLAUDE.md`](../.claude/CLAUDE.md) — behaviour rules.
- [`AGENTS.md`](../AGENTS.md) — Codex repository instructions: operating boundaries and the nine high-value review rules; PR-review output format.
- `.claude/rules/` — GitHub operations, datetime, test execution, ast-grep. (The CCPM add-on's epic/worktree/PRD commands and rules were removed 2026-10-20.)
- `.claude/skills/` — build, run-rallylab, preexisting, device-logs.

## Earlier planning (history, not the tracker)

- `.planning/` — GSD milestone documents for the rally viewer (Jan–Feb 2026), social-features spec, beta-test plan, codebase maps. Kept for reference.
- `.claude/context/` — project context files from the same period.
- `reports/` — gitignored research notes (approach overview, commercial ball tracking, multi-frame detection path).

## Conventions

- Dates in frontmatter are UTC ISO 8601 from `date -u`.
- Decision IDs `D-NNN`; configuration items `CI-BSC-NNN`, families `CF-BSC-NNN`; experiment IDs `EXP-YYYYMMDD-slug`; model versions by package name + SHA-256; dataset versions by manifest hash + split id.
- A number that was not measured is written `not measured`, never `0`.
