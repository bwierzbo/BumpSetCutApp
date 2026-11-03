---
name: rallylab2-overhaul-direction
status: accepted (owner direction); its decision is D-031, proposed
created: 2026-11-03T02:42:42Z
updated: 2026-11-03T02:42:42Z
source: owner, delivered to Claude Code on 2026-11-02 (evening, MDT)
---

> Verbatim record of the owner's direction, reproduced as received. In summary:
> - RallyLab becomes a reliable, unified dataset-management and annotation platform: every eligible recording enters through one auditable pipeline (identity and duplicates, lineage and split, five-minute selection, pinned pipeline premarking, rally / L2 / net / future contact tasks, review progress, versioned validated exports); consenting testers' footage enters it automatically, subject to duplicate detection, privacy and eligibility.
> - A substantial rearchitecture is permitted where justified; existing datasets, annotations, experiments and project functionality are preserved — not a destructive rewrite.
> - Stability first: investigate the actual causes with evidence (the owner later clarified, 2026-11-02 evening: not crashes but stalls — "it just sat loading for over a minute"); no invented crash fix.
> - Phases: 0 audit; 1 persistent intake and task foundation (this PR, stop before merge); 2 automated ingestion and premarking; 3 existing and tester dataset integration; 4 reliable versioned exports; 5 UI consolidation and legacy retirement. Each later phase needs new authorisation. No training, Supabase deployment, public-app change or TestFlight upload under this direction.
>
> Logged as [D-031](DECISION_LOG.md#d-031) (proposed). Audit: [RALLYLAB2_PHASE0_AUDIT_2026-11-02.md](../ml-roadmap/RALLYLAB2_PHASE0_AUDIT_2026-11-02.md).

# BumpSetCut — RallyLab 2.0: Complete Architecture Overhaul and Automated Training Data Pipeline

**Owner authorization:** November 2, 2026  
**Repository:** `bwierzbo/BumpSetCutApp`  
**Primary application:** RallyLab (macOS)  
**Related applications:** BumpSetCut (iOS), Labeler (iPhone)  
**Assignment:** Lead the architecture overhaul and begin implementation.

## 1. Mission

We are transforming RallyLab from a collection of video labeling and research tools into a **reliable, unified dataset management and annotation platform**.

Every new piece of eligible volleyball footage should enter through a standard, auditable pipeline that:

1. Identifies the source and detects duplicates.
2. Determines the correct dataset lineage and split.
3. Selects an appropriate five-minute segment when full-length footage is available.
4. Processes it with our current volleyball detection and rally-cutting pipeline.
5. Generates proposed rally boundaries for human correction.
6. Creates tasks for L2 ball trajectory labeling.
7. Creates tasks for net labeling.
8. Eventually creates tasks for contact/action labeling.
9. Tracks human review progress.
10. Exports versioned, validated datasets for independent ML experiments.

We also want qualifying footage contributed by consenting beta testers to enter this pipeline automatically, subject to duplicate detection, privacy requirements, and source eligibility.

**The long-term objective is continuous data acquisition and improvement across all BumpSetCut ML models.**

The owner is explicitly permitting a substantial rearchitecture of RallyLab where justified.

However, existing datasets, completed annotations, historical experiments, and project functionality must be preserved.

This is not permission for a destructive rewrite.

---

# 2. Read the Current Project Before Modifying It

Start by reviewing:

- `AGENTS.md`
- `CLAUDE.md`
- `.claude/` instructions
- `docs/workflow/WORKING_AGREEMENT.md`
- `docs/workflow/CONFIGURATION_MANAGEMENT.md`
- `docs/workflow/CHATGPT_REVIEW.md`
- `docs/decisions/DECISION_LOG.md`
- `docs/ml-roadmap/ROADMAP_REVISED_2026-10-20.md`
- `docs/ml-roadmap/NET_MODEL_PLAN.md`
- `docs/ml-roadmap/STAGE1_RALLY_BOUNDARIES_PLAN.md`
- `docs/ml-roadmap/EVENT_BOUNDARY_REVIEW_PROTOCOL.md`
- `docs/ml-roadmap/EXPERIMENT_REGISTRY.md`

Study the existing implementation rather than assuming every feature needs replacing.

Important existing components include:

| Component | Location |
|---|---|
| Project management and footage intake | `RallyLab/ProjectsModel.swift` |
| Existing project UI | `RallyLab/ProjectsTabView.swift` |
| Frame sampling and prelabeling | `RallyLab/SamplerModel.swift` |
| Dataset audit | `RallyLab/DatasetAudit.swift` |
| Source identification | `RallyLab/YouTubeSourceIDs.swift` |
| Dataset manifests | `RallyLab/DatasetSplitManifest.swift` |
| Protected footage rules | `RallyLab/ReservedVideos.swift` |
| L2 dataset packaging | `RallyLab/LineagePackage.swift` |
| Rally boundary labeling | `RallyLab/RallyMarkModel.swift` |
| Stage 1 review | `RallyLab/EventReview.swift` |
| Net annotation | `RallyLab/NetLabelsModel.swift` |
| Net proposals | `RallyLab/NetAIProposals.swift` |
| Tester footage imports | `RallyLab/TesterFootage.swift` |
| Tester upload capture | `BumpSetCut/Services/FlywheelCaptureService.swift` |
| Tester upload records | `BumpSetCut/Models/FlywheelContribution.swift` |
| Tester storage/backend | `supabase/migrations/036_flywheel_clips.sql` |
| Phone synchronization | `RallyLab/LabelingSync.swift` |
| App composition | `RallyLab/RallyLabApp.swift` |

Inspect all current PRs and active branches before modifying anything.

Other Claude instances are working on L2 integration, net detector training, rally marking, and dataset acquisition.

**Do not touch another agent's worktree, branch, running process, or uncommitted changes.**

Use an isolated worktree and feature branch.

---

# 3. Highest Priority: Fix RallyLab Stability

RallyLab has been experiencing crashes and reliability problems during normal use.

The owner wants this addressed as part of the overhaul, not ignored while adding features.

Before rebuilding the UI or introducing major new workflows, investigate the actual causes.

Examine:

- Available macOS crash reports and diagnostic logs.
- High memory consumption when projects are open.
- AVFoundation frame decoding and video player lifecycles.
- Core ML model initialization and retention.
- Large in-memory frame and annotation collections.
- Unbounded task creation or concurrent processing.
- SwiftUI observation and state invalidation.
- Automatic phone synchronization.
- Project autosaving.
- Background frame extraction and prefetching.
- Network share interruptions and slow SMB reads.
- Filesystem operations that block the main actor.
- Race conditions between synchronization, labeling, and project writes.

In particular, inspect the large observable models and current `RallyLabApp` initialization lifecycle.

The current application constructs multiple interdependent models and starts automatic synchronization. Determine whether expensive tasks, observers, or asynchronous work can continue after projects close or switch.

**Do not assume the crash cause. Obtain evidence.**

Use Instruments, crash traces, memory graphs, or reproducible workload tests where possible.

If no real crash evidence is available, establish instrumentation and clearly label hypotheses as unverified.

## Required stability goals

The redesigned application should:

- Keep the UI responsive during long-running operations.
- Avoid loading complete video frame collections unnecessarily.
- Bound concurrent decoding and inference work.
- Release inactive players, image buffers, and model resources.
- Recover after network interruptions.
- Resume interrupted tasks safely.
- Persist annotation edits before acknowledging completion.
- Avoid corrupting project state after crashes.
- Support cancellation without losing completed work.
- Start successfully even when the footage share is unavailable.

Use measurable benchmarks instead of declaring the application stable because it builds.

---

# 4. Proposed Architecture: RallyLab 2.0

Build the application around a **persistent source registry and task orchestration system**.

The UI should present the current state of a dataset and its labeling work rather than requiring users to manually move footage between unrelated tabs.

The logical architecture should be:

```text
FOOTAGE SOURCES
  ├── Local video files
  ├── Authorized external links
  ├── Existing RallyLab projects
  ├── Opted-in tester contributions
  └── Eligible user-submitted rallies
             │
             ▼
SOURCE REGISTRY
  ├── Metadata and provenance
  ├── Exact duplicate detection
  ├── Near-duplicate detection
  ├── Source-event grouping
  ├── Consent and licensing
  └── Protected-holdout screening
             │
             ▼
DATASET ADMISSION
  ├── Approved development footage
  ├── Existing reserved material
  ├── Potential new evaluation groups
  ├── Quarantine / needs review
  └── Duplicate / rejected
             │
             ▼
AUTOMATED PREPROCESSING
  ├── Select clip or original window
  ├── Run pinned rally pipeline
  ├── Preserve detector evidence
  ├── Generate premark proposals
  └── Create annotation tasks
             │
             ▼
LABELING TASK QUEUE
  ├── Rally boundaries
  ├── L2 ball trajectories
  ├── Net geometry
  ├── Future contact labeling
  └── Quality-control review
             │
             ▼
HUMAN-VERIFIED ANNOTATIONS
             │
             ▼
DATASET VALIDATION AND VERSIONED EXPORT
  ├── Rally classifier dataset
  ├── L2 detector dataset
  ├── Net detector dataset
  └── Future contact classifier dataset
```

This is a conceptual architecture, not a mandated file or database layout.

Evaluate how to implement it with the current Swift/macOS architecture. Prefer reusing proven stores and tools.

Do not introduce a new database or major third-party dependency merely because the system is being redesigned.

If a local indexed store would improve reliability, evaluate SQLite or another appropriate option against the existing JSON-based persistence and explain the migration and rollback implications.

There must be one clearly documented source of truth for each data type. Cached indexes must be rebuildable and must not become competing authoritative annotation copies.

---

# 5. Source Registry and Deduplication

Every incoming item needs a stable identity and provenance record.

Record, where known:

- Source recording identifier.
- Original source URL or local origin.
- External video ID.
- File SHA-256.
- Parent recording and clip time range.
- Session or match identity.
- Venue identity.
- Camera setup.
- Court surface.
- Recording date, if known.
- Contributor identity or pseudonymous reference.
- Consent or usage authorization.
- Dataset group and split.
- Existing annotations and model exposures.

Distinguish confirmed identifiers from inferred or unknown identifiers.

## Duplicate policy

**Exact duplicate:** Already ingested footage with identical content. Reuse existing source records rather than duplicating labeling work.

**Near duplicate:** A crop, encoding variant, resized copy, or overlapping portion of an existing recording. Identify shared source and avoid redundant labeling.

**Same source, different content:** May be useful. Preserve the footage when appropriate but keep it in the same lineage group.

**Unknown identity:** Quarantine until the system can make a defensible admission decision.

Do not assume that a different file hash means an independent recording.

The same match filmed by different cameras may contain valuable training data, but must remain grouped appropriately for validation.

## Protected holdouts

Preserve every protected reservation and its alias closure.

Do not inspect protected video content, extract frames, generate thumbnails, run models, or use protected recordings for training.

Use existing authorized metadata to detect possible overlap.

When overlap is uncertain, fail closed and require review.

Every downstream exporter must enforce the same exclusion rules.

---

# 6. Automated Five-Minute Footage Selection

For eligible full-length recordings, automatically choose one five-minute window for initial labeling.

The selection should favor:

- Actual gameplay.
- Sufficient rallies for meaningful labeling.
- Camera stability compatible with our temporal pipeline.
- Underrepresented court surfaces or camera setups.
- Novelty relative to existing footage.
- Useful examples for our current detectors.

The pipeline should not simply take the first five minutes every time.

If the source is shorter than five minutes, preserve its actual duration rather than fabricating footage.

Record the selected start and end timestamps against the original recording.

Avoid creating overlapping windows from the same source unless there is a specific documented reason.

The source identity and lineage group must remain attached to every derived clip.

For edited footage, camera cuts and missing dead time must be identified or flagged. A fully labeled edited highlight cannot automatically serve as evidence of ordinary between-rally dead time.

---

# 7. Automatic Rally Premarking

After a video is admitted, run the current approved volleyball processing pipeline to generate proposed rally intervals.

Use a pinned model, configuration, and code version for reproducibility.

Store:

- Proposed rally start/end times.
- Model identity.
- Processor configuration.
- Confidence and available diagnostics.
- Raw rally boundaries.
- Export padding separately.
- Processing date and tool version.
- Any processing failures.

Human labelers must be able to accept, reject, split, merge, and correct proposals.

**Machine-generated predictions are proposals, not ground truth.**

The pipeline should make it easy for me to watch the entire five-minute recording and mark:

- S — serve contact.
- D — ball dead.
- M — missed serve.
- N — not a rally.

Continue supporting the existing **"Marked Every Rally"** completion workflow.

That completion indicates the owner declares the entire clip reviewed.

The system must distinguish declared completion from independently verified timeline coverage.

A completed five-minute clip can provide development-training negatives from unmarked intervals, with the approved ignore and uncertainty rules.

An incomplete clip must never have all unmarked time automatically labeled negative.

Do not rewrite historical annotations or change the completion status silently.

---

# 8. L2 Ball Tracking Labeling Tasks

Each eligible five-minute recording should produce a default target of **2–3 complete rallies for dense ball trajectory labeling**.

Make this target configurable.

The selector should prioritize diversity and useful model failures instead of random volume alone.

Consider:

- Rally length.
- Small or distant balls.
- Occlusion.
- Ball crossings near players.
- Missed detections.
- False detections.
- Track fragmentation.
- Different lighting and court types.
- Different camera elevations.
- Cases where L2 struggles.

Include a mechanism for manually overriding the selected rallies.

Preserve existing annotation semantics for:

- Visible balls.
- Occluded balls.
- Out-of-frame balls.
- Unknown states.
- Confirmed absence.

Do not infer a ball's absence merely because a rally is over.

Reuse the existing L2 annotation workflow and reviewed tracks.

Only human-confirmed eligible annotations may enter future detector training packages.

---

# 9. Net Annotation Tasks

For each independent camera setup, default to **one representative net frame**.

Select a frame where the net is clearly visible and suitable for geometry labeling.

Optionally select one or two additional frames when they provide a meaningful new condition:

- Players partially obscuring the net.
- Difficult lighting.
- Strong contrast changes.
- Motion blur.
- Partial visibility.
- Camera movement.
- Another genuinely distinct appearance.

Do not automatically generate ten nearly identical net-labeling tasks from a stationary camera.

Multiple frames from one fixed camera setup are useful as augmentation or robustness examples, but do not constitute independent geometry or validation groups.

Preserve the existing four-corner net annotation workflow and distinguish bounding-box labels from actual corner ground truth.

Proposals may come from an approved model or AI-assisted annotation process.

Only confirmed labels should become ground truth.

Do not change the current net training experiments or models as part of this task.

---

# 10. Future Contact Labeling

Design the architecture now so a future labeling stage can record individual volleyball actions without reprocessing or relabeling everything.

Each reviewed rally should have a stable persistent identity.

Future labels may include:

- Serve.
- Pass/receive.
- Set.
- Attack.
- Block.
- Free ball.
- Contact timestamp.
- Court side.
- Additional player metadata in a later phase.

Contact annotation must have its own review and completion status.

Do not require contact labeling to complete Stage 1 rally-boundary review or L2 ball tracking.

**Do not implement the full contact classifier in this overhaul.** Build the extensibility and task relationships.

---

# 11. Automatic Tester Footage Intake

The application already contains a data flywheel:

- `FlywheelCaptureService`
- `FlywheelContribution`
- Supabase `training-data` storage
- `tester_footage()`
- `RallyLab/TesterFootage.swift`

Audit these existing systems and integrate them with the new source registry.

Our goal is for new eligible tester footage to appear automatically in the intake queue without repeated manual imports.

Requirements:

1. Verify contribution permission and current consent.
2. Retrieve submission metadata before downloading media wherever possible.
3. Deduplicate against all previously admitted sources.
4. Preserve original contribution and source identities.
5. Distinguish full-length recordings from isolated rally clips.
6. Preserve uploaded detector evidence and corrections.
7. Route admitted clips to appropriate labeling tasks.
8. Prevent repeated imports on retry or restart.
9. Support withdrawal and deletion requests according to the applicable retention policy.
10. Do not expose private contributed footage through public project views.

Important existing behavior to audit:

- `TesterFootage.pull` already imports tester contributions.
- Posted highlights are currently grouped using contributor and day; this is not sufficient as a unique source identity.
- The existing flywheel deduplicates contributions primarily per user/local video; that is not equivalent to cross-user content deduplication.
- The current tester-default contribution setting does not, by itself, prove every historical tester granted the required permissions.

**Do not treat public posting alone as consent to private model training.**

Verify actual permissions and product/legal requirements before enabling any new automatic acquisition path.

If changes to consent, account access, backend security, or deployed Supabase tables are necessary, prepare a separate reviewed proposal and migration. Do not deploy it without explicit authorization.

A rally-only contribution must not be treated as a fully reviewed five-minute source.

---

# 12. Dataset and Annotation Management

The new RallyLab should offer one coherent view of progress across all labeling stages.

Each source and derived clip should expose:

- Intake status.
- Identity confidence.
- Source group.
- Dataset split.
- Video processing status.
- Rally-label completion.
- L2 annotation completion.
- Net annotation completion.
- Contact-labeling status, when introduced.
- Quality review status.
- Dataset export eligibility.

Use persistent task identifiers and an explicit task lifecycle.

Suggested states:

`pending → ready → in_progress → needs_review → complete`

Also support:

`blocked`, `failed`, `quarantined`, and `cancelled`.

Operations must be idempotent.

A crash or restart should not create duplicate tasks, discard a completed annotation, or cause the same footage to be downloaded repeatedly.

Failed tasks should be retryable with recorded failure reasons.

Avoid tying annotation identity to unstable array indexes or UI ordering.

---

# 13. Data Integrity and Migration Strategy

This is non-negotiable.

We already have substantial research data and annotation history.

At the last verified audit:

- 167 Scratch clips existed.
- 145 were eligible for development.
- 30 eligible clips were declared fully marked.
- 466 ordinary rallies were labeled across those clips.
- 40 missed serves were labeled.
- 25 independent recording groups were represented.
- 115 eligible clips remained unmarked.

These are historical checkpoint values, not guaranteed current counts. Reconcile them against the actual project metadata.

Before any storage migration:

1. Inventory every existing data type and authoritative location.
2. Document its schema and ownership.
3. Capture relevant hashes and backup requirements.
4. Identify compatibility requirements with the current iPhone Labeler.
5. Build read-only compatibility tests using representative fixtures.
6. Design an explicit migration and rollback procedure.
7. Demonstrate that all existing marks and completion states survive.
8. Present any destructive or live-data migration for owner approval.

The new architecture should work with legacy data without requiring immediate conversion.

Do not modify the live Scratch project merely to validate the new architecture.

Use isolated copies or synthetic fixtures for migration tests.

Keep experiment records, dataset manifests, exposure ledgers, and frozen historical artifacts unchanged.

---

# 14. UI/UX Direction

You may substantially redesign RallyLab's UI.

The objective is to minimize the number of places a labeler must navigate.

I want a clear, responsive application organized around work rather than disconnected technical tools.

Proposed major views:

**Dashboard**
- Overall dataset health and progress.
- Incoming footage.
- Pending review tasks.
- Current processing jobs.
- Blocked items and errors.

**Sources**
- All known original recordings and contributions.
- Provenance and duplicate relationships.
- Source groups and split status.

**Labeling Queue**
- Rally marking.
- Ball tracking.
- Net labeling.
- Future contact labeling.
- Resume unfinished work.

**Dataset Explorer**
- Search and filter videos, rallies, annotations, and source groups.
- Review individual records and quality issues.

**Experiments and Exports**
- View available approved datasets.
- Generate validated training packages.
- Inspect experiment provenance and results.

**Diagnostics**
- Application health.
- Background jobs.
- Memory usage where available.
- Import errors.
- Sync status.
- Recent failure information.

These are product goals, not instructions to implement every screen in the first PR.

Keep the existing functional annotation interfaces until replacements are validated.

Avoid large UI rewrites that offer no stability or workflow benefit.

---

# 15. Performance and Reliability Requirements

The system must be usable on a Mac while footage is stored on the Windows training machine and reached over Tailscale/SMB.

Design for:

- Slow remote media access.
- Transient disconnects.
- Video formats with different frame rates.
- HEVC/H.264.
- Vertical and horizontal footage.
- Long original videos.
- Multiple simultaneous queued jobs.
- Large collections of already annotated footage.

Prefer bounded, cancelable background operations.

Avoid eagerly decoding whole videos.

Cache thumbnails and frames carefully with defined eviction limits.

Never block the main actor on remote file reads or lengthy inference.

Record task progress persistently.

An interrupted download, preprocessing operation, or annotation export should resume or fail safely without corrupting previous results.

---

# 16. Execution Plan — Do Not Build Everything in One PR

You are authorized to begin the overhaul.

Break the implementation into independently reviewable phases.

## Phase 0 — Crash and Architecture Audit

**Start immediately.**

Produce:

- Current RallyLab architecture map.
- Data ownership and storage inventory.
- Crash/reliability investigation with evidence.
- Existing component reuse plan.
- Proposed target architecture.
- Dependency and migration plan.
- Measurable acceptance criteria.

Investigate crash causes and implement narrowly scoped, evidence-supported reliability fixes when safe.

Do not invent a crash fix if a failure cannot be reproduced or supported by diagnostics.

## Phase 1 — Persistent Intake and Task Foundation

**Begin implementation after documenting the Phase 0 findings in the worktree.**

This is the first substantial feature PR.

Build the minimum reusable foundation:

- Source identity registry.
- Source-to-clip relationships.
- Dataset admission states.
- Persistent labeling-job records.
- Task state transitions.
- Idempotent enqueue/resume behavior.
- Integration adapters for existing RallyLab sources and labels.
- A small working task-queue UI.

The initial implementation should be able to inventory existing projects and show work that is already complete versus pending.

Do not require migration of existing project files.

Use synthetic and non-protected development fixtures for tests.

**Open a reviewable PR for Phase 1 and stop before merging.**

## Phase 2 — Automated Ingestion and Premarking

Implement in a subsequent PR:

- Source screening.
- Five-minute selection.
- Pinned pipeline processing.
- Proposed rally labels.
- L2 task selection.
- Net task selection.
- Review queue integration.

Require new authorization before executing bulk changes against the live dataset.

## Phase 3 — Existing and Tester Dataset Integration

Implement:

- Existing Scratch project compatibility.
- Automatic intake of eligible opted-in tester contributions.
- Cross-source deduplication.
- Source grouping and leakage checks.
- Appropriate consent and deletion workflows.
- Controlled synchronization with existing Labeler features.

Backend migrations, security changes, and deployments require separate explicit approval.

## Phase 4 — Reliable Versioned Training Exports

Implement model-specific exporters for:

- Rally classifier.
- Ball detector.
- Net detector.
- Future contact annotations.

All exports must enforce:

- Human-label eligibility.
- Declared or verified review coverage.
- Source lineage and split isolation.
- Protected-holdout exclusions.
- Exposure ledger recording.
- Reproducible manifests.
- Dataset versioning.
- Validation and preflight checks.

No experimental training is authorized by this assignment.

## Phase 5 — UI Consolidation and Legacy Retirement

Only after new workflows pass parity and recovery tests:

- Consolidate redundant views.
- Remove obsolete UI paths.
- Retire redundant implementations.
- Complete the RallyLab 2.0 user experience.

Preserve old data formats or provide validated compatibility paths.

Do not delete legacy code simply because the new architecture exists.

---

# 17. Testing and Acceptance Criteria

At minimum, create or extend tests for:

**Data integrity**
- Opening legacy projects.
- Preserving annotations and completion flags.
- Non-destructive indexing.
- Interrupted writes.
- Corrupted or missing records.
- Incompatible schema versions.

**Source admission**
- Exact duplicates.
- Near duplicates.
- Same match/different camera.
- Unknown provenance.
- Protected source relationships.
- Split conflicts.
- Quarantine behavior.

**Task system**
- Duplicate enqueue.
- Interrupted jobs.
- Failed jobs.
- Retry after restart.
- Cancellation.
- Concurrent task updates.
- Persistent task identity.

**Labeling**
- Existing rally marks remain intact.
- Machine proposals do not become human truth automatically.
- Ball visibility remains separate from rally activity.
- Incomplete footage cannot create verified non-rally negatives.
- Sync preserves existing approved annotations.

**Performance**
- Project open and close.
- Repeated video switching.
- Memory use during extended labeling.
- Slow or disconnected SMB share.
- Large dataset inventory.
- Background processing without UI stalls.

Use `scripts/build.sh` and the repository's documented test procedures.

Run macOS tests for RallyLab changes and both targets when shared code changes.

A successful build does not establish application stability.

Record actual test results and measurements.

---

# 18. GitHub Workflow and Independent Review

Follow the working agreement.

- Use an isolated feature branch and worktree.
- Do not push to `main`.
- Keep PRs scoped.
- Update controlled documentation appropriately.
- Run `scripts/ci_check.py`.
- Run applicable unit and integration tests.
- Open a PR with actual evidence and limitations.
- Request independent Codex review.
- Resolve or document findings.
- Never merge without owner approval.

Do not change active experiment branches, frozen experiment records, training splits, or protected footage.

Do not start ML training, deploy Supabase migrations, change public app behavior, or upload TestFlight builds under this authorization.

---

# 19. What I Expect From You Now

Do not respond with only a broad conceptual plan.

**Start working on the overhaul.**

Your immediate sequence should be:

1. Inspect the current repository, working agreement, active worktrees, and open PRs.
2. Establish a reproducible architecture and crash/stability baseline.
3. Identify the most important reliability risks.
4. Propose a concrete implementation architecture that reuses existing components.
5. Create your own branch and isolated worktree.
6. Implement the first safe, foundational part of RallyLab 2.0.
7. Add appropriate tests.
8. Run builds and validation checks.
9. Open a reviewable PR for the first implementation slice.
10. Report the result and stop at the owner review gate.

If existing tooling, crash evidence, or access is unavailable, describe the precise blocker, finish the independent work that is possible, and do not fabricate completion.

At the end, report:

- Architecture findings.
- Confirmed versus suspected crash causes.
- What you changed.
- What existing code you reused.
- Tests run and actual results.
- Dataset and compatibility risks.
- PR URL and commit SHA.
- Remaining work by phase.
- The decisions requiring owner approval.

## Final Direction

**RallyLab 2.0 should become the long-term foundation of BumpSetCut's machine-learning development.**

Every eligible new recording should increase the usefulness of our training corpus.

Every labeling action should contribute to a clearly defined training objective.

Every source must retain its identity, permissions, and lineage.

Every experiment must remain reproducible.

Every annotation must survive a crash.

Build a maintainable system that supports years of incremental model development, not a temporary collection of scripts and UI patches.

Begin with stability and the source/task foundation, deliver the first reviewed PR, and do not merge or deploy without my approval.
