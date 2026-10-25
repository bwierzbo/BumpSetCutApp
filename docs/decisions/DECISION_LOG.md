---
name: decision-log
status: authoritative
created: 2026-10-20T22:12:44Z
updated: 2026-10-24T23:50:37Z
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
| [D-015](#d-015) | 2026-10-21 | accepted | Task B.1 decisions: holdout sibling moved; seven provisional final-test candidates protected; tune/dev_val cards kept; CLI provenance now, UI in B.2; YouTube IDs confirmed as sourceId |
| [D-016](#d-016) | 2026-10-21 | accepted (amended by D-017) | Pre-tracking counts as exposure (strict); machine tracks kept; none of the seven candidates is promoted; provenance confirmed by visual review, never inferred |
| [D-017](#d-017) | 2026-10-21 | accepted | Model-lineage holdout: the seven candidates and their nine related recordings (16) are withheld from all future training as `lineageHoldout`; historical exposure kept; never the final test; new lineages preregister before evaluating on it |
| [D-018](#d-018) | 2026-10-21 | accepted | L2 dataset isolation: a manifest-generated lineage package with preflight audit and file hashes (`--package-l2`), the project `data.yaml` unsupported for L2; mandatory preregistration from a fixed template, independent initialisation, no holdout use in selection |
| [D-019](#d-019) | 2026-10-21 | accepted | PR #73 merged; L2 recipe approved (768, colour, 60 epochs, seed 20261021) with amendments: H1 becomes a paired comparison with the L1 checkpoint on the same val windows, label provenance stated, one seed only; legacy holdout confirmed out of L2; training and holdout evaluation still need separate authorisation |
| [D-020](#d-020) | 2026-10-22 | proposed | Configuration management: controlled documents and records are registered configuration items (living / append-only / frozen), checked on every PR by a read-only `ci-impact` workflow; approval stays the owner's explicit authorisation and merge |
| [D-021](#d-021) | 2026-10-22 | accepted | Scoring contract v1 accepted: excluded time masked with separate diagnostics, false clips per exported segment with delivered dead/excluded time split, no dead-time claims on partially marked footage, 0.98 completeness provisional, merged rallies tracked; Dataset Review & Repair GUI approved (C1 first; explicit logged backed-up applies; trim = derived recording inheriting its parent's restrictions; protected recordings refused by default, legacy-holdout exceptions authorised + ledgered, lineage holdout separately gated); 54 dangling records not cleaned up |
| [D-022](#d-022) | 2026-10-22 | accepted (amended by D-025) | L2 export recovery: direct LAN SMB restricted to the Mac's address, the partial package preserved, and a resumable export that reuses a frame only once validated (whole JPEG, planned moment, written size, same video), fails promptly on a lost mount, retries I/O a bounded number of times, never skips a frame, and finishes only after completion is verified; gates unchanged |
| [D-023](#d-023) | 2026-10-23 | accepted | L2 labels are people's only; unreviewed pre-tracked rallies excluded |
| [D-024](#d-024) | 2026-10-23 | accepted | Progressive RallyLab rally review: full-video boundaries first, optional contacts second, player IDs later |
| [D-025](#d-025) | 2026-10-24 | proposed | Amends D-022: a planned frame the decoder reproducibly cannot produce — an HEVC leading picture, and only that — is recorded in the journal and the summary and left out with every window that needed it, instead of stopping the export; every other failure stays fatal; plan and run identity unchanged; the three affected recordings stay in the package |

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

**Consequences.** Dataset manifest gains a `split` of `train | dev_val | tune | legacy_holdout | final_test` with an `exposure` history (`legacy_holdout` is the canonical name for the four previously reused holdout recordings, per `AGENTS.md` rule 3; `final_test` is reserved for recordings with no prior exposure). Any report states the split version. Test-set scoring excludes `final_test` until promotion.

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

**Consequences.** [WORKING_AGREEMENT.md](../workflow/WORKING_AGREEMENT.md), [CHATGPT_REVIEW.md](../workflow/CHATGPT_REVIEW.md), `.github/PULL_REQUEST_TEMPLATE.md`, this log, the [experiment registry](../ml-roadmap/EXPERIMENT_REGISTRY.md), the [docs index](../README.md). `CLAUDE.md`, `.claude/CLAUDE.md` ("push after every commit chunk" now means the feature branch) and `.claude/rules/github-operations.md` updated. `.planning/` kept as history; the unused CCPM add-on (`/pm:*` commands, scripts, epic rules) removed because it carried direct-to-`main` merge paths; GitHub issues/PRs are the tracker.

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

**Amendment (owner, 2026-10-22).** No numerical dead-time-retention ceiling or recall target is set yet. The objective stays *minimise dead-time retention subject to complete-rally recall ≥ an approved target*; the target is configurable but unset until the Phase 1A event-boundary review and the corrected scoring provide reliable evidence; no default ceiling or threshold is introduced; the provisional 0.98 complete-rally criterion is not the recall target (it defines whether one rally was preserved, not the required share of rallies). Reports show complete-rally recall, dead-time retention, false clips and the trade-off between candidates; dead-time metrics stay unavailable on partially annotated recordings; diagnostic comparisons are permitted but no configuration is declared the winner under D-007 until the target is approved; `covered − 0.25 × dead time` stays a named diagnostic, never the objective. Source: [verbatim note](2026-10-22-d007-threshold-decision.md).

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

**Consequences.** [WORKING_AGREEMENT.md](../workflow/WORKING_AGREEMENT.md) "Review tiers"; [CHATGPT_REVIEW.md](../workflow/CHATGPT_REVIEW.md) now leads with Codex; `CLAUDE.md`, `.claude/CLAUDE.md`, `AGENTS.md` updated to point there. The CCPM epic tooling, whose merge command pushed `main`, was removed rather than patched (unused third-party add-on).

**Source.** Owner instruction to Claude Code, 2026-10-20 ("Task 2 — Update the development workflow"), recorded in PR #65.

### D-015

**Task B.1 decisions applied** — 2026-10-21 — accepted — owner (with ChatGPT review). Source: [owner note, verbatim](2026-10-21-task-b1-owner-decisions.md).

**Decision.**
1. `bch_onl_sun_land_onl_03_v2` joins its sibling in `legacy_holdout` (option A). Both were exposed to evaluation; neither is unseen.
2. The seven unexposed dev_val recordings (`bch_extra_self_05`, `bch_extra_self_18`, `grs_extra_self_06`, `grs_extra_self_07`, `grs_extra_self_14`, `grs_extra_self_21`, `ind_extra_self_09`) are **provisional final-test candidates**: protected immediately against any new training, tuning, evaluation or scoring exposure, and promoted to `final_test` only after the owner confirms venue and session, duplicates and overlap with training/tuning are checked, historical exposure evidence is reviewed (an empty ledger does not prove absence of use before logging), and independence is justified. Provisional candidates are kept distinct from verified final-test recordings. They are an initial evaluation resource, not a basis for broad generalisation claims; a stronger independent final-test collection (more venues, sessions, cameras, all three surfaces) stays planned.
3. Tune/dev_val card overlaps are not reorganised now; the soft findings stay documented and visible; reassess when the D-007 tuning methodology is implemented.
4. Provenance is assigned with the existing CLI now; a lightweight provenance editor (sourceId, sessionId, venueId, explicit confirmation status, unknown values; never inferring) joins the RallyLab clip card in Task B.2 without blocking integrity work.
5. YouTube video IDs may be confirmed as `sourceId` when independently verifiable, by a deterministic, reversible, previewed procedure; venueId/sessionId are never inferred from YouTube IDs, uploaders or cards; ambiguous entries stay unconfirmed.

**Consequences.** `validation.json` gains `finalTestCandidates`; split `final_test_candidate` (reserved like `final_test`, reported apart); `--confirm-youtube-source-ids [--apply]`; pre-logging uses are discovered from session machine tracks and the tuner evidence cache. Applied to Scratch on 2026-10-21: holdout 4→5, dev_val 12→4, candidates 0→7, 73 YouTube `sourceId`s confirmed, hard 0→0, soft 8→8. All seven candidates are `CANDIDATE-BLOCKED` (pre-tracking exposure; venue/session unconfirmed) pending the owner's answers in [PROVENANCE_QUESTIONS_2026-10-21.md](../ml-roadmap/PROVENANCE_QUESTIONS_2026-10-21.md). Task B.2 does not start until those are addressed and this work is reviewed.

### D-016

**Pre-tracking counts as exposure; candidates stay protected; provenance by visual review only** — 2026-10-21 — accepted, amended by [D-017](#d-017) — owner (answer to Q0 of [PROVENANCE_QUESTIONS_2026-10-21.md](../ml-roadmap/PROVENANCE_QUESTIONS_2026-10-21.md)).

**Decision.** Option (a), strict. A pre-tracking run that wrote machine tracks into a session is model exposure like any other, even when nothing was trained, tuned or selected on those tracks and no human reviewed them. Consequently: (1) the seven provisional candidates of D-015 §2 keep their `pre_tracking` exposure and remain `CANDIDATE-BLOCKED`; none is promoted to `final_test`; (2) the machine tracks are **not** deleted from the seven sessions (deleting them would not undo the exposure and would discard evidence of it); (3) the seven remain protected candidates — reserved against any further training, tuning, evaluation or scoring use — and the independent final test waits for new footage collected after the ledger existed; (4) venue, session and camera for the candidates, their neighbouring training imports and the Dianne Gan recordings are established by the owner looking at frames in a local review page ([PROVENANCE_REVIEW_2026-10-21.md](../ml-roadmap/PROVENANCE_REVIEW_2026-10-21.md)); nothing is pre-filled or inferred from file numbers, uploaders, YouTube metadata or visual similarity, and every answer may be "unknown". Q4 (tune/dev_val uploader venues) stays deferred to the D-007 tuning work.

**Context.** The ledger did not exist on 2026-10-18 when `--pretrack --val` ran over the dev_val sessions; the audit now discovers that use from the session files. Clearing it would set a precedent that unlogged uses can be argued away.

**Consequences.** No code or data change: the audit already reports the seven as blocked by `pre_tracking`. Their status is "protected candidate, not promotable"; the roadmap's final-test collection plan (new venues, sessions, cameras, all three surfaces) is the only path to a verified `final_test`. Owner answers from the review page are applied by `--set-provenance` in a reviewed PR with the before/after report; only answers marked *confirmed* are written.

**Source.** Owner instruction to Claude Code, 2026-10-21 ("Task B.1 — Visual Provenance Review": "Treat Q0 as strict … do not delete machine tracks, do not promote any candidate to final_test").

### D-017

**Model-lineage holdout of 16 recordings; D-016 amended with a three-way distinction** — 2026-10-21 — accepted — owner (with ChatGPT review). Source: owner note "D-017 Owner Decision and Next Steps", 2026-10-21.

**Context.** Confirming venues and sessions (PR #70) made the reservation closure grow from the seven candidates to 16 recordings (nine training recordings alias them by confirmed session or venue), train 142 → 133. The seven can never be the independent final test (D-016). The owner proposed retraining from scratch without those recordings and evaluating on them.

**Decision.**
1. **Option (a) of the proposal, with qualifications.** The seven provisional candidates and their nine related training recordings are excluded from all future detector training packages and preserved as a protected, versioned **model-lineage holdout** (`validation.json` `lineageHoldout`, manifest split `lineage_holdout`), distinct from `finalTest`. Reserved exactly like the final test in every package, scoring, tuning, selection, pre-tracking and GUI path; their machine tracks never enter training, tuning, selection or development-time scoring.
2. **D-016 amendment.** The strict historical interpretation stands: pre-tracking and any earlier use stay recorded permanently; nothing is deleted or rewritten. Three things are distinguished: (i) historical exposure of a recording during earlier development; (ii) training exclusion for a specifically identified new model lineage; (iii) eligibility for an independent, never-used final test. A newly initialised model trained without the 16 may be described as having no direct training exposure to them, once its full training and model-selection dependencies are verified from the ledger; the 16 must never be described as an untouched final test.
3. **Holdout composition.** All 16. The nine's reviewed ball annotations are preserved for later detector evaluation (as of the cut-over none of the 16 has reviewed frames; the machine tracks are not ground truth). The seven serve pipeline evaluation only once trustworthy rally-boundary annotations exist; missing or unverified annotations are never ground truth.
4. **Evaluation restrictions.** Scores of any model exposed before the cut (every model to date, L1) on this set are marked exposed, diagnostic-only. New lineages preregister the training recipe, selection criterion, metrics and holdout procedure before looking at holdout results; no tuning against the holdout, no repeated evaluations for selection; results reported by surface and recording group with sample-size limits. A separate new-footage final test remains planned for broader claims.
5. **Before finalising**, all remaining training and development recordings were audited for confirmed or suspected overlap; unknown relations are reported explicitly (`LINEAGE-UNKNOWN-RELATIONS`: 144 recordings without confirmed venue or session).

**Consequences.** `validation.json` key `lineageHoldout`; `DatasetSplit.lineageHoldout` ("lineage_holdout", reserved); `ReservedVideos.expanded` ranks final test > lineage holdout > candidates; audit findings `LINEAGE-HOLDOUT`, `LINEAGE-HOLDOUT-SUMMARY`, `LINEAGE-UNKNOWN-RELATIONS`; lineage record [MODEL_LINEAGES.md](../ml-roadmap/MODEL_LINEAGES.md) (L1 historical, L2 planned with cut-over hashes). Applied to Scratch 2026-10-21: train 133 · dev_val 4 · tune 9 · legacy_holdout 5 · lineage_holdout 16 · candidates 0 · final_test 0; 0 hard, 8 soft. Older `validation.json` files without the key still decode (tested). No model training started. The stack #68 → #72 was merged on the owner's authorisation on 2026-10-21.

### D-018

**L2 dataset isolation and mandatory preregistration** — 2026-10-21 — accepted — owner (with ChatGPT review). Source: [owner note, verbatim](2026-10-21-l2-owner-decisions.md).

**Context.** After D-017 two questions stayed open: the project's `data.yaml` dataset (`images/train`, `images/val`, `excluded/`) is addressed by folder, so a trainer pointed at it bypasses every name-based reservation, and the lineage holdout holds frames there (parked under `excluded/images/val`); and L2 training needed a written protocol before anyone looks at holdout numbers.

**Decision.**
1. **Physical isolation through a manifest-generated L2 dataset.** Name-based exclusion and a "do not use" policy are not enough on their own. The L2 training set is a separate package generated from the authoritative versioned split manifest, with its own dataset description, from which every protected recording (the 16 of D-017, the final test, provisional candidates and the legacy holdout) and anything sharing a confirmed identity with one is physically absent — no window, no frame, no folder. The original dataset, labels and historical artefacts are preserved untouched. A **preflight audit** of the written package verifies source identities, split membership, exclusion closure and the hash of every file, and **fails closed**: any protected recording or related frame removes the package. The project's `data.yaml` is explicitly marked unsupported for L2 training. The generated dataset manifest and hashes are stored with the experiment record. Training is not executed yet.
2. **Mandatory preregistration before any L2 training**, from a reusable template covering objective and hypotheses; dataset versions, counts, provenance and hashes; architecture and initialisation; hyperparameters, seeds, augmentation and stopping; development validation and checkpoint selection; detector and end-to-end metrics; per-surface reporting and uncertainty; protected-holdout access and evaluation rules; reproducibility (hardware, code revision, dependencies); success, failure and limitations. No protected-holdout result may be used for model selection or hyperparameter tuning. A model described as trained from scratch uses independently initialised weights, never a checkpoint derived from the exposed detector. Training begins only after the owner explicitly approves the completed preregistration and the dataset preflight passes.

**Consequences.** `RallyLab --project <name> --package-l2 [--dry-run] [--long-side N]` (`LineagePackage`): the plan (`manifests/l2/<stamp>-plan.{json,md}`) is derived from the manifest and the audit (hard leak → refused; any recording that `validation.json` withholds — reserved names and `holdout`, expanded through every project video's identities, sessionless ones included — but the manifest would package → refused; any identity or alias group shared between an eligible and a withheld recording → refused); the package `<project>-L2-multiframe-<stamp>` is written by the existing multi-frame exporter, preflighted before zipping (eleven checks incl. the fingerprint of the video file behind every packaged clip against every identity a withheld recording's video can carry — over the full withheld closure, sessionless project videos included — and against the other side of the package, content hashes of every frame the dataset holds for a withheld recording, and a ban on model-written labels), and carries `l2-manifest.json` (plan + preflight + SHA-256 of every file + canonical digest), copied to `manifests/l2/`. `legacy_holdout` is withheld from L2 packages (it was val data in every L1 package). The project `data.yaml` header states it is not a lineage dataset. Template: [PREREGISTRATION_L2.md](../templates/PREREGISTRATION_L2.md); first record, proposed and unapproved: [EXP-20261021-l2-scratch-prereg](../ml-roadmap/experiments/EXP-20261021-l2-scratch-prereg.md). Applied to Scratch (dry run, 2026-10-21): 133 train · 13 val eligible, 21 withheld, audit 0 hard. No package exported (footage not on the Mac), no training.

### D-019

**PR #73 merged; L2 recipe approved with amendments; one seed; legacy holdout stays out** — 2026-10-21 — accepted — owner. Source: [owner note, verbatim](2026-10-21-l2-approval-decisions.md).

**Context.** Codex's eighth round on PR #73 (D-018 implementation and the proposed preregistration) was clean; the seventh run had stalled on Codex's side and was restarted with an empty commit. The owner reviewed the proposed record [EXP-20261021-l2-scratch-prereg](../ml-roadmap/experiments/EXP-20261021-l2-scratch-prereg.md).

**Decision.**
1. **Merge PR #73** (done 2026-10-21T23:37:56Z, squash `14c86b8`). Not an authorisation to train.
2. **Technical recipe approved:** from-scratch VballNetV4c, 768×432, colour, nine frames, 60 epochs, batch 8, seed 20261021, no pseudo-labels. **Amendments required before final authorisation:** (a) H1 no longer uses the historical L1 interval from a different validation set as a success/failure criterion; a paired, methodologically compatible comparison on the same eligible development-validation data replaces it, and historical results stay descriptive. (b) The record states that the ball tracks were initially proposed by L1 and personally reviewed and corrected by the owner to cover entire rallies: human-verified complete-rally ball labels; possible model-assisted rally-selection bias is a separate limitation. (c) **Only the first seed is authorised**; a second run needs separate approval.
3. **Legacy-holdout exclusion confirmed:** all 16 lineage-holdout and five legacy-holdout recordings, including identity-linked aliases, stay out of L2 training and development-validation packages.
4. **Sequence:** complete the amendments, export the isolated package, run the full preflight, fill in package hashes and reproducibility, return the completed record for final approval. Training and any protected-holdout evaluation each need a separate explicit authorisation.

**Consequences.** The paired comparison is executable: `train_heatmap_model.py <package> --size … --color --score-only <best.pt> --name <run>` scores a checkpoint on a package's val windows with the epoch scorer and stops (metrics.json carries the checkpoint's SHA-256; `desktop.sh train … --score-only` forwards it and `wait`/`fetch`/`run` treat the job like a training run, fetch adding no model); every run's metrics.json now carries the 4 px tallies per val video and a **digest of the val windows as scored** (every record and every frame's bytes); `scripts/desktop_training/paired_compare.py A.json B.json` refuses two files whose digests differ, then resamples the same val videos for both models (1,000 draws, seed 0) and reports ΔF1 with its paired 90 % interval, overall and per surface. H1 of the record is restated on that basis against the shipped L1 checkpoint `scratch_768_1014`, scored on the L2 package's val windows; the L1 checkpoint's selection exposure to those recordings is recorded as a bias in L1's favour. Label provenance stated from the sessions: 525 ready tracks in 131 eligible recordings (132 contribute windows), of which 501 are L1-proposed (`machine`) and 24 hand-drawn; only person-checked points become labels (55,329 train / 9,558 val checked points; the val tracks are fully checked; 61,006 unchecked L1-proposed train points are never labels — the preflight's `no-machine-labels` check refuses a package carrying any, and the Oct 16 package with the same tracks had 231 L1-origin rallies and 0 machine frames). The package export is blocked by disk: the exporter needs every eligible recording's video (132, 75.5 GB) and every withheld recording's video (21, 25.5 GB, for the content fingerprints) on the Mac at once, plus about 21 GB for the package folder and zip, against 28 GB free; the footage is on the desktop (`D:\RallyLabFootage\Scratch\footage`, 106.7 GB, 1.3 TB free there). How to provide it is the owner's call (network mount of the desktop folder, an external drive, or freeing roughly 100 GB on the Mac).

**Amendment (owner, via independent review, 2026-10-22).** (a) **H1 is exploratory for this first experiment**: "paired 90 % interval not entirely below zero" is not a non-inferiority test; ΔF1 and its interval are reported, an interval that includes zero is *not* evidence of equivalence, and a non-inferiority margin may only be used if justified and preregistered before any L2 result is seen. The L1 checkpoint's selection exposure and the small sample stay explicit. (b) Resampling must not treat related video variants as independent: `paired_compare.py --manifest` also resamples **recording groups** (one clip card, alias group, confirmed session or venue, or uploader → one unit); among the 13 val recordings there are 5 such groups. (c) Dangling protected frame records are documented, not fatal; unreadable existing content stays fatal (as merged in PR #76). (d) `ProjectsModel.fileFingerprint` (size + first/last 4 MB, optional reads) is a weaker guarantee than the rest of the preflight: a **strict full-file source verification** is proposed as a separate reviewed change — [L2_SOURCE_VERIFICATION_PROPOSAL.md](../ml-roadmap/L2_SOURCE_VERIFICATION_PROPOSAL.md), which also reconciles the protected-content inventory (closure 21 = recomputed; 452 files = 425 record files + 27 orphans; 54 dangling). (e) The running export is not changed or restarted; the training gate is unchanged.

### D-020

**Configuration management of engineering documents and records** — 2026-10-22 — proposed — implementer, from the owner's approved proposal and decisions of 2026-10-22; acceptance is the owner's.

**Decision.** Controlled documents, records and product artefacts are configuration items registered in `docs/config-items.toml` (TOML, schema 1, standard-library parsing): individual items for important records, families for recurring artefacts. Each has a stable id, type, lifecycle, change class (`living`, `append-only`, `frozen`), approval policy, source dependencies and update triggers; revision metadata is derived from git, never stored. Frozen records are never edited and are corrected by superseding records; decision-log entries are append-only with controlled status transitions. `scripts/ci_check.py` enforces this from the base revision's rules, run by a read-only `pull_request` workflow. Errors: invalid registry, frozen-record changes, unauthorised historical entry edits. Warnings to start: watched paths without an update, unregistered documents; promotion after about five representative PRs. The PR's approval-request list is a request; approval is the owner's explicit authorisation and merge, never inferred from a passing check or review.

**Context.** Decisions, lineages, manifests and audits accumulated quickly (D-001 … D-019) with history protected only by review attention; read-only dashboards need a machine-readable inventory.

**Consequences.** New: the registry, the checker and its tests, `.github/workflows/ci-impact.yml`, [CONFIGURATION_MANAGEMENT.md](../workflow/CONFIGURATION_MANAGEMENT.md), [ROADMAP_AMENDMENTS.md](../ml-roadmap/ROADMAP_AMENDMENTS.md) (the 2026-10-20 roadmap is frozen with its existing notes). Updated: PR template, working agreement (step 9, review gate, sources of truth), `AGENTS.md` rule 9, `CLAUDE.md`, docs index. No app, pipeline, dataset or training change.

**Source.** Owner decisions on the configuration-management proposal, 2026-10-22 (delivered to Claude Code; decisions 1–8 and amendments A–F).

### D-021

**Scoring contract v1 accepted; Dataset Review & Repair GUI approved for implementation planning** — 2026-10-22 — accepted — owner (via independent review). Source: [owner note, verbatim](2026-10-22-scoring-and-gui-decisions.md).

**Context.** PR #79 ([SCORING_CONTRACT.md](../ml-roadmap/SCORING_CONTRACT.md)) and PR #82 ([DATASET_REVIEW_GUI_PLAN.md](../ml-roadmap/DATASET_REVIEW_GUI_PLAN.md)) were merged under the owner's "merge the ones that are technically ready"; the reviewer then settled the open contract questions and the GUI principles.

**Decision.**
1. **Masking accepted.** Boundary errors use scorable prediction boundaries. Separate diagnostics — predictions entering excluded time, excluded seconds overlapped, partially masked predictions — never affect primary detection scores. Disconnected scorable pieces are preserved for matching, with regression tests.
2. **False clips** are counted per original exported segment, not per masked piece; a segment with no rally and 1.8 s of scorable dead time is one false clip. Scorable dead time and excluded time delivered are reported separately. Verified dead time is never inferred from unknown or partially annotated footage.
3. **Complete rally** = retained fraction ≥ 0.98 **and** serve contact and ball dead inside the actual exported interval, with the half-open containment convention and the video-end exception; merged rallies tracked separately even when fully retained. 0.98 is provisional, to be revisited with Phase 1A evidence.
4. **GUI.** C1 (event review) first, then the health queue, then controlled corrections. Every applied repair is explicit, logged, backed up or source-preserving, and validated. Trimming yields a separately identified derived recording linked to the original, which stays untouched; split and holdout restrictions carry through the parent–source relationship. All GUI and headless operations refuse protected recordings by default; legacy-holdout diagnostic exceptions need separate owner authorisation and an exposure-ledger entry; lineage-holdout access remains separately gated. The 54 dangling frame records are not cleaned up yet.
5. The running L2 export is not interrupted; after a successful preflight: desktop verification, completed preregistration with hashes and reproducibility, final training approval. No training or protected-holdout evaluation is authorised.

**Consequences.** Reference scorer and fixtures updated (`excludedTimeDiagnostics`; `falseClips` per segment; `scorableDeadSecondsDelivered` / `excludedSecondsDelivered`; `fullyMarked` gating with null dead-time metrics otherwise; `mergedRallies` / `inMergedExport`; fixtures 21 and 22; 22 pinned fixtures). Post-export implementation continues as separate scoped PRs with Codex review: G1 event-review tool, G1b protected-holdout refusal for routine scoring with the auditable exception, scoring PRs A–C, strict source verification.

### D-022

**L2 export recovery: LAN SMB path, partial package preserved, resumable export with validated reuse** — 2026-10-22 — accepted — owner. Source: [owner note, verbatim](2026-10-22-l2-export-recovery-decision.md).

**Context.** The first L2 export (`Scratch-L2-multiframe-20261021-1917`, D-019 sequence step 4, written to the desktop's staging share over Tailscale) failed at 10:50 UTC on 2026-10-22 after about 16 hours: the desktop's Wi‑Fi retired the IPv6 privacy address Tailscale's direct path used, both SMB sessions dropped, the server scavenged the open video handle, and the exporter failed on the next read. 87,572 frames in 75 of 132 clip folders were on the desktop; no windows.jsonl, summary, record or exposure-ledger row; nothing on the Mac changed. The implementer reported and stopped, as the export instructions required, with three options.

**Decision.**
1. **Network:** direct LAN SMB to the desktop (`10.0.0.123`), inbound TCP 445 restricted to the Mac's LAN address, DHCP reservations preferred; the footage share stays read-only and the staging share separately writable; IPv6 privacy addresses are not disabled; SMB is not exposed to the internet; no credential in a script, Git or a log. Both mounts and sustained read/write access are verified before any resume.
2. **Resumable export**, in a focused RallyLab PR with tests and Codex review: a retained frame is reused only when validated against the expected source, timestamp, format and completeness; existence alone proves nothing; corrupt or incomplete files are handled safely; a lost mount is detected and fails promptly; transient I/O errors are retried a bounded number of times; no source video or expected frame is ever skipped silently; windows, summary and record are written only once completion is verified; the full preflight, source-identity, split-isolation and protected-content checks run afterwards; desktop verification must pass before the package is presented for training approval.
3. **The partial folder is kept**; no deletion or wholesale replacement is authorised.
4. PR #83 merged after its title was corrected to D-021; PR #84 merged after it, rebased, with its D-007 amendment and the CI-BSC-001, CI-BSC-010, CI-BSC-053 and CF-BSC-006 changes explicitly approved.
5. **Gate:** no replacement export until the LAN path is verified and the resumability change has passed review and received merge authorisation; the exact resume command and validation results are returned before rerunning. No L2 training or protected-holdout evaluation is authorised.

**Consequences.** Desktop: a firewall rule `RallyLab SMB from the Mac over LAN` (TCP 445, Private profile, from 10.0.0.113 to 10.0.0.123 on the Wi‑Fi interface) and the Windows built-in `File and Printer Sharing (Restrictive) (SMB-In)` rule, which had opened TCP 445 to any address on the Private profile, disabled; the Tailscale rule unchanged. Mac: a second Keychain item for `10.0.0.123`; both shares mounted over the LAN; sustained test 3 × 2 GB read and 2 GB written and read back consistent at about 25 MB/s ([FOOTAGE_SHARE.md](../workflow/FOOTAGE_SHARE.md)). RallyLab: `MultiFramePackage.export(resume:)` and `--package-l2 --resume DIR [--dry-run]` against a journal written beside every package (`ExportJournal`: versioned run identity, one line per durable frame with its hash, states; `ExportIO`: volume anchors, bounded retry, whole-file writes, frame inspection); a frame is reused only when the journal's hash matches its bytes or its bytes are identical to its regeneration from the video (the interrupted run has no journal, so every one of its frames is proven that way); the exporter fails naming any frame it cannot produce instead of dropping the window; the exposure ledger is written after the preflight, not before; a resumed folder whose preflight fails keeps its frames. The Scratch project and the partial folder are untouched until the owner authorises the resume.

**Amendment (D-025, 2026-10-24).** Item 2's "no source video or expected frame is ever skipped silently" is kept; "the exporter fails naming any frame it cannot produce" gains one recorded exception, defined in [D-025](#d-025): a planned frame that is an HEVC leading picture the frame-accurate decoder reproducibly cannot produce is journaled with its error and left out together with every window that needed it, counted in the summary and the record; every other frame the exporter cannot produce still stops it. Source: [owner direction, verbatim](2026-10-24-l2-run4-undecodable-frames-direction.md).

### D-023

**L2 labels are people's only: a pre-tracked rally nobody has checked is left out of the lineage package** — 2026-10-23 — accepted — owner. Source: [owner direction, verbatim](2026-10-23-l2-labels-people-only-direction.md) ("The 43 unreviewed *_extra_self_* recordings were not intended for the human-verified L2 training dataset"; item 3: "Prepare a corrective PR implementing an L2-specific eligibility rule that excludes unreviewed machine-generated trajectories").

**Context.** The read-only audit of the Scratch records found that `--package-l2` planned 150,924 frame files of which 69,629 (46 %) came from 43 recordings imported and pre-tracked on 2026-10-17 and never reviewed: 284 machine rallies with `isRally == nil`, 61,006 unchecked model points, no human label at all. The general exporter packages a pre-tracked rally as soon as it exists (`TrackedRally.isReady`) and labels its "sure" frames as the model's own (`MachineLabels.trusted`, flagged `pseudo`); the lineage preflight's `no-machine-labels` check would have refused the package only after the nine-hour write. The human-reviewed material (67,981 checked points: 55,329 train, 9,558 val, 3,094 withheld) was intact and correctly represented; the defect was scope.

**Decision.**
1. A lineage package takes labels only from rallies a person finished, or pre-tracked rallies a person confirmed as rallies, and only when at least one frame of the rally was checked (`LineagePackage.isHumanLabeled`); every other rally is left out whole, and the recordings and their annotations stay untouched in the dataset.
2. The lineage exporter never labels a frame from the model: `MultiFramePackage` runs with `machineLabels: false` for `--package-l2`, so `machineFrames` is 0 by construction; the preflight check stays as the backstop. The setting is part of the export's run identity, so a journal written under one rule cannot be resumed under the other.
3. The train/val/holdout boundaries (D-017/D-018/D-019) and the prohibition on pseudo-label training are unchanged. The 43 recordings keep their pre-tracked rallies for future rally-classification work; none is marked "not a rally".
4. The Stage D resumed export of 2026-10-23 was interrupted by the owner's direction before it wrote a frame (SIGTERM during the read-only validation phase; journal and folder unchanged); the preserved folder and its journal are kept pending a separate decision on the 43 clip folders the corrected plan no longer expects.

**Consequences.** Corrective PR with tests (exporter, journal identity, lineage rule); the preregistration's §2a records the audit and the corrected plan's expected counts; final fields stay pending. Stage D export, L2 training and protected-holdout evaluation remain unauthorised until the owner decides on the recovery plan.

### D-024

**Progressive RallyLab review: boundary-first MVP, optional contacts, deferred player identities** — 2026-10-23 — accepted — owner (voice direction summarised for review).

**Decision.** RallyLab will organise annotation in three independent, progressive stages. **Stage 1** is the immediate MVP priority: review each **eligible development recording end-to-end** and mark every rally's precise serve-contact and first dead-ball moment, its kind (rally or missed serve), and uncertain/occluded or truncated boundaries; quickly flag non-rally ball activity (thrown balls, ball retrieval, warm-ups or bouncing) without requiring frame-exact boundaries for each throw. A recording is only `fully reviewed` when its entire timeline has been checked for rallies, not when selected rallies are marked. Intervals not yet reviewed remain unknown; they are not automatically negative training examples or verified dead time. **Stage 2** optionally takes Stage 1's persistent rally IDs and boundaries, presenting each rally for incremental per-contact review (exact contact frame, action and technique; unknown is allowed) without redoing Stage 1. Stage 2 can be entered over time and tracks completion per rally separately from Stage 1. **Stage 3** adds player tracking/identity attribution and statistics only under a future explicit decision; it is not authorised for present implementation.

**Rollout.** Keep the approved 24-rally, 48-boundary-event calibration pilot (D-004) first, then expand Stage 1 to all eligible development recordings. The GUI should make Stage 1 and optional Stage 2 separate, clearly labelled workflows; deliver a useful Stage 1 MVP first, and develop minimal Stage 2 contact entry as an independent incremental feature, not a precondition for the MVP. Preserve earlier annotations, frozen L2 material and protected split/holdout restrictions (D-010, D-017–D-019, D-021). Do not alter original footage or reinterpret human-checked ball tracks. The staged interface and new sidecars require scoped PRs, tests and review. Training L2, holdout access, and model deployment are separate approval gates.

**Context.** The owner chose a short path to high-quality start/stop supervision for automatic rally highlights while preserving a way to collect contacts gradually for a future event classifier and defer the larger player-statistics project.

**Source.** [Owner direction summary, 2026-10-23](2026-10-23-progressive-rally-review-owner-direction.md); the summary is not represented as a verbatim transcript.

### D-025

**Undecodable HEVC leading pictures are recorded and left out with their windows, not fatal; everything else stays fatal (amends D-022)** — 2026-10-24 — proposed — owner (Option 1 of the run-4 report). Source: [owner direction, verbatim](2026-10-24-l2-run4-undecodable-frames-direction.md) ("I select Option 1: explicitly record confirmed undecodable HEVC frames and exclude affected temporal windows"; "Do not turn general decoder failures into accepted omissions"). Numbered D-024 in PR #93's first revision; renumbered D-025 on the owner's review follow-up of 2026-10-24 ([verbatim](2026-10-24-l2-pr93-review-followup-direction.md)), D-024 being the progressive RallyLab review decision of PR #90.

**Context.** The fourth resumed L2 export (main `6f73cec`, 2026-10-24 02:49Z–11:02Z) re-proved the 19,668 retained frames, completed 44 of 89 clips and stopped, as D-022 requires, on `bch_ele_sun_land_self_01/1685000.jpg` (`Cannot Decode`, AVFoundation −11821, after the bounded retries). The cause is structural, not damage or the network: the clip is iPhone HEVC with open groups of pictures, and the three (sometimes four) frames displayed just before each key frame are *leading pictures* coded after it and predicted from the group before it; the frame-accurate image generator cannot produce them on their own, deterministically, from a shared or a fresh decoder, from the mounted or a local copy; the sequential reader and ffmpeg each drop some of them too. Pictures the generator does produce match ffmpeg's at ≈45 dB PSNR. Neither the Oct 16 package nor run 4 ever held such a frame: the old exporter dropped their windows without a word (its known silent omissions). Three of the 45 remaining clips are affected (`bch_ele_sun_land_self_01`, `grs_gnd_sun_land_self_01_v2`, `ind_gnd_bright_port_self_03`; about 6 % of their planned frames, about a third of their windows). A 10 KB synthetic x265 open-GOP clip reproduces the failure exactly. Reconciled counts: the authoritative plan is **81,273** frames (the 81,295 of 2026-10-23 less the 22 trimmed-end moments PR #91/#92 removed); **34,515** are in the folder and journaled (19,668 retained + 12,721 written for the 44 complete clips + 2,126 of the stopped clip); **46,758** remain; the earlier "54,183 present" had counted the retained frames twice.

**Decision.**
1. A planned frame the exporter's decoder cannot produce after its bounded retries is judged, not assumed: the volumes are verified; a decoder created for that one question is asked (an answer is the frame); the frame is left out only when the clip is HEVC, both decoders answered the decode failure (−11821) and nothing else, the run of consecutive undecodable video frames it sits in is at most four long, and the frame before and the frame after that run decode. Another codec, another error, a longer run (a damaged clip loses the rest of its group of pictures), a run reaching the clip's start or end, or a lost volume stop the export naming the frame, as before.
2. Every frame left out is a journal line (`undecodable`: clip, key, moment, the decoder's error, attempts, run length, reason, time) and appears per clip in `summary.json` (`undecodable`: frames, windows left out by kind, labeled frames now in no window, error, reason) and in the record's clip table; the README says so. Every window that needs such a frame is left out whole: no neighbouring frame is duplicated, nothing is interpolated, no label is changed. A clip every window of which is left out contributes no window; its decodable frames stay in its folder, on record (`windowsPlanned` = `windowsLeftOut`), and the preflight accepts that folder on the record alone, for an eligible, non-withheld clip, still checked against the withheld identities. The preflight gains a 13th check, `undecodable-frames-recorded`: every recorded frame is absent from the folder and from every window, for the one accepted reason, and the counts agree; a summary that cannot say fails.
3. The plan and the run identity are unchanged: the frame is still planned (`plannedKeys`), so the live journal of run 4 is resumed as it is; a resumed run asks the decoder again for every frame an earlier run left out and judges it afresh. The journal format keeps version 1 (no existing line changed; a journal holding the new line type is refused by an older build as not a journal, never half-read). Exporter version stays 2: a frame that decodes is written exactly as before.
4. The three affected recordings stay in the package; no clip is dropped, no retained frame is re-proven for this reason.
5. Preparation only: this entry is `proposed` until the owner authorises the merge; the resume of the export, L2 training, protected-holdout evaluation and model promotion remain unauthorised.

**Consequences.** `MultiFramePackage.Undecodable` (rule and verdicts), `judgeUndecodable`, `ClipFrames.codec/freshGenerator/adjacent`, `ExportJournal.Line.undecodable`, `Summary.undecodable*`, `LineagePackage` check and `ClipRow` fields, `--package-l2` log lines; three committed fixtures under `RallyLabTests/Fixtures/` (open-GOP HEVC with three and with five leading pictures; H.264 with a damaged inter frame) and tests that the exception holds, that a resume judges again, and that a longer run or another codec stays fatal. The preregistration's §2a records run 4, the cause, the reconciled counts and the rule; the final counts of frames and windows left out, per clip and split, come from the completed run's `summary.json` and record. Expected loss: well under 1 % of the package's windows, all in the three clips.
