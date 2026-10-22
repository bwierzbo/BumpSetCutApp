---
name: dataset-review-gui-plan
status: approved for implementation planning (owner decisions 2026-10-22, D-020): C1 first, then the health queue, then controlled corrections; no code until the L2 export completes
created: 2026-10-22T03:30:00Z
updated: 2026-10-22T03:30:00Z
---

# RallyLab Dataset Review & Repair: implementation plan

Owner milestone (2026-10-22): a native RallyLab interface to review and repair dataset problems by hand after the current export — a health queue, original-video frame stepping with non-destructive trim ranges, independent serve-contact / dead-ball annotation with uncertainty, versioned non-destructive label corrections, source-identity and split-leakage checks, and before/after previews with backups, provenance and validation evidence. **The Phase 1A event-review tool comes first.** Nothing here is built or run until the L2 export finishes; the live project is not modified.

## Principles (apply to every component)

1. **Nothing destructive, ever, from the GUI.** No trim, delete, relabel or move of footage or sessions happens as a side effect of review. Every change is a *proposal* written to a versioned sidecar; the original stays. Applying a proposal is a separate, explicit, logged action with a backup, and only for the categories the owner has approved.
2. **Owner judgment is flagged, not automated.** When a problem needs a decision, the queue item shows the affected recording, the proposed repair, the expected effect (counts, hashes, splits, exposure) and the evidence; the owner approves, amends or rejects it in the GUI, and that decision is recorded with who/when/why.
3. **Guards live in the shared function** (CLAUDE.md): refusals (withheld recordings, protected content), ledger rows and backups are inside the operation, so the GUI and the headless command cannot bypass them.
4. **Protected recordings are protected here too.** Every GUI and headless operation refuses the L2 withheld closure (`lineageWithheldNames`: lineage holdout, legacy holdout, final test, candidates, with aliases) by default. A historical **legacy-holdout** diagnostic exception needs a separate owner authorisation and an exposure-ledger entry carrying its reference, never a toggle. **Lineage-holdout** access stays separately gated (D-017: one preregistered evaluation per named candidate) and is not reachable through the exception.
5. **Evidence first.** Each applied repair produces: a backup path with hashes, a before/after summary, the new manifest/session digests, and an entry in the exposure/repair ledger; nothing is "done" without it.

## Components and order

### C1 — Event review tool (Phase 1A first; protocol in `EVENT_BOUNDARY_REVIEW_PROTOCOL.md`)

| Item | Plan |
|---|---|
| Where | a new **Review** tab in RallyLab (macOS only; no shared-pipeline files), plus headless `--review-events` for the pilot's frozen selection |
| Playback | the **original** video through the footage mount (never the scrub proxy); AVPlayer with frame stepping (±1 frame, ±5, ±1 s, hold-to-scrub), presentation timestamps shown to the millisecond and as frame index at the file's rate; audio on (whistles) |
| Annotation | serve contact and ball dead, each as `[earliest, latest]` set by two key presses (or one when unambiguous), visibility `clear|occluded`, kind `rally|missedServe|other`, flags (`ambiguous`, `edge`, free text); blind mode hides the legacy mark and the frozen prediction until both events are committed |
| Storage | `<video>.rallyevents.json` (schema in the protocol §5), written atomically, one record per rally with `annotationVersion`, `annotator`, `reviewedAt`, `tool` sha, `sourceFingerprint`, `frameRate`; the legacy `rallylabels.json` is never written by this tool |
| Selection | the pilot's frozen candidate list (24 rallies, windows, hashes) loaded from the pilot record; the tool shows progress and refuses to score anything |
| Refusal | by the L2 withheld closure, in the shared `EventReview.open(session)` function, with the ledger row `event_review` written on open |
| Repeat review | a separate pass that hides the first result and records `secondReview` with method label and timestamp; the 24-hour rule enforced from the first record's `reviewedAt` |
| Tests | `RallyLabTests`: schema round-trip, refusal of withheld names, atomic write and no-overwrite of legacy marks, 24-h gate, window loading |
| Out of scope | applying corrections to `rallylabels.json` (that is C4), scoring (SCORING_CONTRACT PRs) |

### C2 — Dataset-health queue

A read-only queue built from the manifest, the audit and the sessions, one row per finding, with severity and the recording:

| Finding | Source today | Proposed repair shown |
|---|---|---|
| Frame records with no file (dangling), orphan image files | `LineagePackage.protectedFrames` logic generalised to all sessions | drop dangling records (C4), keep orphans parked; expected effect: session digest change, counts |
| Incomplete rallies (tracked range shorter than marked rally, tracks without `done`, `isRally == nil` machine tracks) | sessions | open in C1/track tab; no auto change |
| Questionable clips (very short, no ball ever seen, duplicate time ranges, cut inside a rally) | sessions + marks | flag for owner; proposed `kind: other` or trim range (C3) |
| Duplicate sources (same `file:` fingerprint or confirmed sourceId under two names), unknown grouping (`LINEAGE-UNKNOWN-RELATIONS`, no session/venue) | audit findings | propose alias merge or provenance entry (C5); never auto-merge |
| Annotation issues (marks without kind, legacy_unverified, sidecar newer on phone than Mac, `ralliesMarked` without marks) | marks + sync state | flag; C4 corrections |
| Withheld recording with any of the above | same | shown read-only with a lock; repairs require the separate authorisation |

Headless twin `--dataset-health` writes the same queue as JSON/CSV for the record.

### C3 — Frame stepping and non-destructive trim ranges

Reuses C1's player. A **trim proposal** is `{recording, start, end, reason, author, createdAt}` in `<video>.trimproposals.json`; it changes nothing until applied. Applying (explicit owner action, logged, validated) writes a **separately identified derived recording** next to the original with its own name and fingerprint and provenance `derived_from: <parent fingerprint>, trim: [start, end]`; the original remains untouched (it is its own backup, with its hash list). The parent–source relationship carries **every split and holdout restriction**: the derived recording is an alias of its parent in the manifest and audit (same identities, session and venue), so it takes the parent's split, is withheld whenever the parent is, and can never land on the other side of a split from it (decided 2026-10-22).

### C4 — Versioned, non-destructive label corrections

- A correction is a record in a per-recording **correction log** (`<video>.corrections.json`): `{id, target (mark index | frame id | track id), field, from, to, reason, author, createdAt, status: proposed|applied|rejected}`.
- The GUI shows the legacy value, the proposed value and the effect (which scorers/packages read this field).
- **Apply** rewrites the target file through the shared store function with: a backup copy of the file under `manifests/backups/<date>/<recording>/` with SHA-256, the correction marked `applied` with the backup path and the new file hash, and a ledger row `label_correction`. The manifest's `sessions` digest changes and is recorded in the registry on the next `--manifest` run.
- Dangling-record removal (`DATASET_HYGIENE.md` H-1) is the first correction type; `kind` fixes and event-driven boundary corrections from C1 come next.

### C5 — Source identity and split-leakage checks

Surfaces the existing manifest/audit machinery live: identity closure for a selected recording (fp/src/ses/ven chains, alias group), which side of which split each alias sits on, hard/soft audit findings, and a **what-if**: "if I set this provenance / merge these aliases / move this recording to tune, the audit says …" computed on a copy of the inputs, never written. Writing provenance stays the existing `--set-provenance` path (owner-confirmed, visual review per D-016), now reachable from the GUI with the same confirmation.

### C6 — Before/after previews, backups, provenance, validation evidence

Shared by C3/C4: side-by-side preview (legacy vs proposed mark on the timeline; original vs trimmed range; counts and digests before/after), the backup list with hashes, the ledger rows the action will write, and a **validation panel** that re-runs the relevant checks after apply (manifest build, audit, protected-content inventory, scoring parity on the affected recording) and shows pass/fail with the evidence paths.

## PR boundaries and order

| PR | Scope | Needs RallyLab build/tests | After |
|---|---|---|---|
| G0 | protocol/plan docs (this page, #80) | no | now |
| G1 | C1 event review tool + `rallyevents.json` + refusal + tests | yes | export done |
| G1b | protected-holdout refusal for routine scoring commands (`lineageWithheldNames` + auditable exception flag) | yes | export done; small, independent of G1 |
| G2 | C2 health queue (read-only) + `--dataset-health` | yes | G1 |
| G3 | C4 correction log + apply with backups; first type = dangling records (H-1) | yes | G2; owner approves the first apply explicitly |
| G4 | C5 identity/leakage view + what-if | yes | G2 |
| G5 | C3 trim proposals + apply-as-new-cut | yes | G3 |
| G6 | C6 validation panel (depends on SCORING_CONTRACT PR A for parity) | yes | G3, scoring PR A |

Each PR: RallyLab-only files (no shared-pipeline changes except where noted), Codex review, owner merge; any first "apply" of a destructive-looking category (trim cut, correction apply) is additionally demonstrated on a copy of the project before the owner authorises it on the live one.

## Decisions requested from the owner

1. ~~Approve the order (C1 first, then the read-only queue, then corrections) and the rule that every apply is an explicit owner action with backup and ledger.~~ Decided 2026-10-22: approved — C1 first, then the health queue, then controlled corrections; every application of a proposed repair is explicit, logged, backed up or source-preserving, and validated.
2. ~~Confirm the trim design: a trimmed range becomes a **new derived video** aliased to its source, the original untouched.~~ Decided 2026-10-22: approved as a separately identified derived recording linked to the original, restrictions carried through the parent–source relationship.
3. ~~Confirm that the GUI's withheld-recording lock is absolute by default, with the auditable exception only.~~ Decided 2026-10-22: yes — refusal by default for every GUI and headless operation; legacy-holdout diagnostic exceptions need separate owner authorisation plus a ledger entry; lineage-holdout access is separately gated. The 54 dangling frame records are **not** cleaned up yet.
