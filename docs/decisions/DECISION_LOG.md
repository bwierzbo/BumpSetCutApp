---
name: decision-log
status: authoritative
created: 2026-10-20T22:12:44Z
updated: 2026-10-20T22:12:44Z
---

# Decision log

The authoritative record of product, architecture, data and process decisions for BumpSetCut and RallyLab. A decision is in force until a later entry supersedes it. Chat transcripts and agent memory notes are not decisions; if they disagree with this log, this log wins.

**Conventions.** IDs are `D-NNN`, assigned in order of logging. Status is `accepted`, `superseded by D-NNN`, or `proposed`. Each entry records the date, who decided, the decision, the context that drove it, the consequences for code and data, and the source. New entries are added in the same PR as the change they authorise ([working agreement](../workflow/WORKING_AGREEMENT.md)). Use the [decision template](../templates/DECISION.md).

## Index

| ID | Date | Status | Title |
|---|---|---|---|
| [D-001](#d-001) | 2026-10-20 | accepted | Learned temporal rally classifier is an approved production candidate |
| [D-002](#d-002) | 2026-10-20 | accepted | Freeze the four holdout recordings; build an independent final test |
| [D-003](#d-003) | 2026-10-20 | accepted | Hybrid Mac/Windows workflow over Tailscale |
| [D-004](#d-004) | 2026-10-20 | accepted | Frame-stepping rally-boundary review for 20–30 rallies |
| [D-005](#d-005) | 2026-10-20 | accepted | Branch + PR + independent review workflow; no direct push or merge to main |
| [D-006](#d-006) | 2026-10-20 | accepted | Repeat validation under corrected methodology; retraining authorised |
| [D-007](#d-007) | 2026-10-20 | accepted | Tuner objective: constrained complete-rally recall; 0.25 score kept as diagnostic |
| [D-008](#d-008) | 2026-10-20 | accepted | Remove `enableRallyScoreGate` from tuning; reconcile replay with production |
| [D-009](#d-009) | 2026-10-20 | accepted | Explicit `sourceId` / `sessionId` / `venueId` provenance |
| [D-010](#d-010) | 2026-10-20 | accepted | Ball visibility and rally activity are separate labels; negative supervision needs an audit first |
| [D-011](#d-011) | 2026-10-11 | superseded by D-007 | Tuner objective: covered share − 0.25 × dead time |
| [D-012](#d-012) | 2026-10-09 | accepted | No Ultralytics licence; no YOLO-derived weights ship in the public app |
| [D-013](#d-013) | 2026-10-06 | accepted (amended by D-001) | From-scratch multi-frame ball model + learned decision layer, all on-device |
| [D-014](#d-014) | 2026-10-20 | accepted (amends D-005) | Review tiers: PR review by default for ML/data/architecture; streamlined path only with explicit owner authorisation; Codex is the reviewer |

---

### D-001

**Learned temporal rally classifier is an approved production candidate** — 2026-10-20 — accepted — decided by the owner (with ChatGPT review).

**Decision.** The former rule "NO ML rally classification, NO weighted scoring as the primary mechanism" is withdrawn. A learned temporal rally classifier over detector/tracker features is an approved architectural direction and is developed and evaluated as a production candidate. The deterministic pipeline (`RallyDecider` FSM, `BallisticsGate`) stays as benchmark and fallback. No approval gate on experimentation. Production adoption requires independent validation evidence on recordings the model and its tuning never saw.

**Context.** The rule dated from an earlier product iteration. [D-013](#d-013) had already chosen a learned decision layer; the revised roadmap (written against the old `CLAUDE.md`) re-imposed a research-only gate. Phase 0 surfaced the conflict.

**Consequences.** `CLAUDE.md` product invariants rewritten. The roadmap's Phase 8 is no longer "P2 / approval gate"; it is planned work after the measurement phases (2, 7). End-to-end video→rally models and player tracking/pose remain out of scope. Displayed detection confidence stays the raw model confidence.

**Source.** [Owner decisions §1](2026-10-20-phase0-owner-decisions.md).

### D-002

**Freeze the four holdout recordings; build an independent final test** — 2026-10-20 — accepted — owner.

**Decision.** The four `holdout` videos in `Scratch/pipeline_tuning/validation.json` are frozen and their historical exposure is labelled (they are in the detector's val split and were scored by every heat-model test-set run). Where possible, a genuinely independent final-test collection is created from recordings, sessions and venues absent from training and tuning. Previously used validation recordings stay development-validation data. Historical scores are preserved and never described as "unseen".

**Context.** Phase 0 found all 13 tuning videos inside the detector val split (BASELINE.md, decision 2).

**Consequences.** Dataset manifest gains a `split` of `train | dev_val | tune | holdout_frozen | final_test` with an `exposure` history. Any report states the split version. Test-set scoring excludes `final_test` until promotion.

**Source.** [Owner decisions §2](2026-10-20-phase0-owner-decisions.md).

### D-003

**Hybrid Mac/Windows workflow over Tailscale** — 2026-10-20 — accepted — owner.

**Decision.** The Windows desktop is the canonical store for source footage and the primary GPU trainer. The Mac runs RallyLab, Core ML verification, annotation review and Apple-platform testing. Connectivity is Tailscale with standard OpenSSH over the tailnet for automation (Tailscale SSH's server does not run on Windows) and a remote-desktop application for interactive access. No public port forwarding; access restricted to authorised devices and accounts. Footage and artefact transfer is versioned and checksummed. There is exactly one editable annotation store (the Mac RallyLab project).

**Context.** Scratch footage (25 GB) moved to the desktop on 2026-10-16; evaluation steps that read video stalled.

**Consequences.** Implementation plan in [HYBRID_MAC_WINDOWS_PLAN.md](../workflow/HYBRID_MAC_WINDOWS_PLAN.md). Nothing is installed and no network/security setting changes without explicit owner authorisation per step.

**Source.** [Owner decisions §3](2026-10-20-phase0-owner-decisions.md).

### D-004

**Frame-stepping rally-boundary review for 20–30 rallies** — 2026-10-20 — accepted — owner.

**Decision.** Build a frame-stepping review in RallyLab for 20–30 representative rallies with exact serve-contact and dead-ball times, earliest/latest uncertainty intervals and provenance. Legacy records are preserved, not overwritten. Report how annotation differences change scoring, especially complete-rally recall and boundary errors.

**Consequences.** `RallyMarkRecord` gains optional provenance and uncertainty fields (decodeIfPresent). Legacy marks are tagged `legacy_unverified`. A sensitivity report compares frozen predictions against old and corrected marks.

**Source.** [Owner decisions §4](2026-10-20-phase0-owner-decisions.md).

### D-005

**Branch + PR + independent review workflow; no direct push or merge to main** — 2026-10-20 — accepted — owner.

**Decision.** Nine-step cycle: define task with measurable acceptance criteria → scoped feature branch from approved `main` → implement and test → record files, results, assumptions, limitations, outstanding issues → open a PR with evidence → owner hands PR to ChatGPT for review → incorporate findings → merge only after explicit owner approval → docs and decision records updated as part of the change. No direct pushes to `main`. No automatic merges. Intermediate commits to the feature branch are fine. The first PR is documentation and workflow only.

**Consequences.** [WORKING_AGREEMENT.md](../workflow/WORKING_AGREEMENT.md), [CHATGPT_REVIEW.md](../workflow/CHATGPT_REVIEW.md), `.github/PULL_REQUEST_TEMPLATE.md`, this log, the [experiment registry](../ml-roadmap/EXPERIMENT_REGISTRY.md), the [docs index](../README.md). `CLAUDE.md`, `.claude/CLAUDE.md` ("push after every commit chunk" now means the feature branch), `.claude/rules/branch-operations.md` and `worktree-operations.md` (merge sections) updated. `.planning/` and `.claude/commands/pm` kept as-is; GitHub issues/PRs are the tracker.

**Source.** [Owner decisions §5](2026-10-20-phase0-owner-decisions.md).

### D-006

**Repeat validation under corrected methodology; retraining authorised** — 2026-10-20 — accepted — owner.

**Decision.** Historical results are not assumed sufficient. Order: (1) correct grouping and leakage, (2) trusted rally-boundary truth, (3) raw-vs-padded scoring, (4) replay-vs-production parity, (5) new baseline with the shipping model (`ball_heat` = scratch_768_1014), (6) re-evaluate viable existing checkpoints under the corrected procedure. Then selective multi-seed experiments. Retraining is authorised when justified by updated annotations, a revised training distribution or a defined hypothesis; compute is not a reason to skip it. Architecture selection weighs complete-rally preservation, false starts, dead-time removal and device performance, not detector F1 alone.

**Consequences.** Every evaluation records dataset/split version. The Oct 17 score table in BASELINE.md is the historical reference, not the new baseline.

**Source.** [Owner decisions §6](2026-10-20-phase0-owner-decisions.md).

### D-007

**Tuner objective: constrained complete-rally recall; 0.25 score kept as diagnostic** — 2026-10-20 — accepted — owner. Supersedes [D-011](#d-011).

**Decision.** `PipelineTuner` optimises: minimise dead-time retention subject to complete-rally recall ≥ target. The existing `covered/rallyTime − 0.25 × deadTime/rallyTime` score is kept and reported under its own name as a historical diagnostic. Numerical gates (the recall target, complete-rally threshold) are set from reliable evaluation data once the corrected methodology exists; none are invented.

**Source.** [Owner decisions §7](2026-10-20-phase0-owner-decisions.md).

### D-008

**Remove `enableRallyScoreGate` from tuning; reconcile replay with production** — 2026-10-20 — accepted — owner.

**Decision.** Production `VideoProcessor` does not apply the rally-score gate, so it leaves the tuner's search space and the replayer stops applying it. `EvidenceReplayer` must match `VideoProcessor` exactly; an automated parity test enforces it. Historical configurations that set the flag must still decode.

**Source.** [Owner decisions §8](2026-10-20-phase0-owner-decisions.md).

### D-009

**Explicit `sourceId` / `sessionId` / `venueId` provenance** — 2026-10-20 — accepted — owner.

**Decision.** Optional, explicit `sourceId` (original recording), `sessionId` (recording session) and `venueId` relationships are added to the dataset/project metadata. Clip-card IDs are not treated as verified venue identities. Existing source URLs, recording info, annotations and splits are preserved. A provenance-quality audit flags uncertain grouping for the owner's review.

**Source.** [Owner decisions §9](2026-10-20-phase0-owner-decisions.md).

### D-010

**Ball visibility and rally activity are separate labels; negative supervision needs an audit first** — 2026-10-20 — accepted — owner.

**Decision.** Two independent label axes: ball visibility `VISIBLE | OCCLUDED | OUT_OF_FRAME | UNKNOWN` and rally activity `ACTIVE_RALLY | NON_RALLY | TRANSITION | UNCERTAIN`. They never share a target and are never inferred from each other. Existing "no ball" labels (mostly out-of-frame during active rallies) are **not** reinterpreted as inactive rally or converted into dead-time negatives. Before any trainer change, an audit answers the eight questions in the owner's note (target construction, temporal arrangement, hidden/no-ball treatment, when an empty heatmap is valid, reentry behaviour, controlled comparison, independent-session validation). New negative-supervision behaviour stays off by default until evidence supports it. Non-rally ball activity (tosses, retrieval, warm-up, bouncing) is a labelled category used to evaluate and train the rally classifier, not as detector negatives. The event taxonomy keeps missed serve, rally and non-rally handling distinct.

**Context.** Phase 0 found dead windows have no labels on any frame and unlabeled frames carry zero loss weight; a hidden ball is encoded like "no ball" unless the hide is ≤ 0.6 s.

**Source.** [Owner decisions §10](2026-10-20-phase0-owner-decisions.md).

### D-011

**Tuner objective: covered share − 0.25 × dead time** — 2026-10-11 — superseded by [D-007](#d-007) — owner.

**Decision.** `PipelineTuner.Score.value = covered/rallyTime − 0.25 × deadTime/rallyTime` on padded clips ("missing a rally is worse"; 1 s of rally lost ≈ 4 s of dead time kept). Preroll/postroll not searched.

**Source.** Session memory `pipeline-tuner` (commit c660c9a).

### D-012

**No Ultralytics licence; no YOLO-derived weights ship in the public app** — 2026-10-09 — accepted — owner.

**Decision.** The Ultralytics Enterprise licence (quoted $12k/yr) is declined. Ultralytics/YOLO may be used internally (RallyLab pre-labeling, candidates while labeling) but nothing Ultralytics-derived ships in the public BumpSetCut build. Before launch the processing path is heat-only and `ball_v2_small`, `bestv2`, `bestv3`, `ball_rallylab_960/1280` and `net` leave the iOS bundle. RallyLab (Mac) and the internal Labeler TestFlight may keep them.

**Status 2026-10-20.** Processing already defaults to multi-frame only; the YOLO packages are still in the iOS bundle for the debug picker (BASELINE.md model inventory).

**Source.** Session memory `ultralytics-licensing`.

### D-013

**From-scratch multi-frame ball model + learned decision layer, all on-device** — 2026-10-06 — accepted, amended by [D-001](#d-001) — owner.

**Decision.** (1) A multi-frame heatmap model trained from scratch on tracked-rally frames balanced across indoor/grass/beach becomes the only ball finder in processing; YOLO leaves the processing path. (2) A small learned sequence model over per-frame tracker/gate signals replaces the hand-tuned FSM thresholds; rules stay as a safety net. (3) Rejected: end-to-end video→rally model. (4) Everything runs on the iPhone; measure on device.

**Status 2026-10-20.** (1) shipped (`ball_heat` = scratch_768_1014, 2026-10-14). (2) reaffirmed and broadened by D-001.

**Source.** Session memory `detection-architecture-direction`.

### D-014

**Review tiers; Codex is the independent reviewer** — 2026-10-20 — accepted, amends [D-005](#d-005) — owner, after the first Codex review of PR #65.

**Decision.** The owner decides when a formal PR is required. Changes affecting ML models, datasets, training pipelines, evaluation methodology, architecture, or significant production behaviour require PR review by default. Minor UI adjustments, cosmetic changes, documentation corrections and low-risk bug fixes may use a streamlined workflow when the owner explicitly authorises it for that change. The owner can require a PR for any change or grant an exception for any change. Claude never pushes directly to `main` or merges without explicit owner authorisation. Codex (GitHub app) remains the independent reviewer for PRs; the manual ChatGPT export is the fallback. Blocking findings must be resolved or explicitly accepted by the owner.

**Context.** D-005 required a PR for every change. The first review cycle showed that is heavier than needed for cosmetic and documentation fixes, while ML and production changes need the full gate.

**Consequences.** [WORKING_AGREEMENT.md](../workflow/WORKING_AGREEMENT.md) "Review tiers"; [CHATGPT_REVIEW.md](../workflow/CHATGPT_REVIEW.md) now leads with Codex; `CLAUDE.md`, `.claude/CLAUDE.md`, `AGENTS.md` updated to point there. `/pm:epic-merge` no longer merges or pushes `main`.

**Source.** Owner instruction to Claude Code, 2026-10-20 ("Task 2 — Update the development workflow"), recorded in PR #65.
