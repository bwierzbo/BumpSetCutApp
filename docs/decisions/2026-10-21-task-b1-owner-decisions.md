---
name: task-b1-owner-decisions
status: accepted
created: 2026-10-21T05:10:00Z
updated: 2026-10-21T05:10:00Z
source: owner, reviewed with ChatGPT, delivered to Claude Code on 2026-10-21
---

> Verbatim record of the owner's answers to the five Task B.1 decisions in [PROVENANCE_AUDIT_2026-10-21.md](../ml-roadmap/PROVENANCE_AUDIT_2026-10-21.md). The normalised entry is [D-015](DECISION_LOG.md#d-015). This file is the primary source; do not edit it.

# BumpSetCut — Task B.1 Owner Decisions

I've reviewed the five Task B.1 decisions with ChatGPT. Apply the following decisions in accordance with the existing workflow and authoritative decision log.

## Decision 1 — Legacy holdout sibling

**Accept Option A.**

Move `bch_onl_sun_land_onl_03_v2` into `legacy_holdout`, alongside its sibling.

Both have already been exposed to evaluation, so neither may be described as unseen.

Expected result: 5 legacy_holdout recordings and 11 dev_val recordings, before other split changes.

## Decision 2 — Final-test candidates

**Conditionally accept reserving the seven identified recordings.**

The seven candidates are:

- `bch_extra_self_05`
- `bch_extra_self_18`
- `grs_extra_self_06`
- `grs_extra_self_07`
- `grs_extra_self_14`
- `grs_extra_self_21`
- `ind_extra_self_09`

Immediately protect these recordings against new training, tuning, evaluation, and scoring exposure while provenance verification is pending.

Before promoting them to `final_test`:

1. Ask me to confirm their recording venues and sessions.
2. Check for duplicates, related clips, and overlap with existing training/tuning recordings.
3. Review available historical exposure evidence, recognizing that an empty ledger does not prove absence of use before logging was implemented.
4. Promote only recordings whose independence can be justified.
5. Clearly distinguish provisional candidates from verified final-test recordings.

These seven recordings are an initial evaluation resource, not a sufficient basis for broad generalization claims.

Continue planning a stronger independent final-test collection covering additional venues, recording sessions, cameras, and all three volleyball environments.

## Decision 3 — Tune/dev_val card overlap

**Accept the recommendation: do not reorganize these cards now.**

Retain the existing tune/dev_val assignment and document the eight soft findings.

Reassess grouping when the corrected D-007 tuning methodology is implemented.

Do not dismiss or hide the soft findings in the audit.

## Decision 4 — Provenance assignment

**Use the existing CLI for immediate verified assignments.**

Add a lightweight provenance editor to the RallyLab clip-card interface during Task B.2.

The interface should support sourceId, sessionId, venueId, explicit confirmation status, and unknown values.

It must never silently infer or confirm these identifiers.

Do not let UI work block the immediate dataset integrity tasks.

Ask me for the recording-specific venue and session details that you need.

## Decision 5 — YouTube source IDs

**Approve confirmed YouTube video identifiers as sourceId when independently verifiable.**

First audit how these identifiers were extracted and ensure they actually represent original YouTube uploads.

Use a deterministic, reversible procedure with a preview and report of proposed changes.

Do not automatically infer venueId or sessionId from YouTube IDs, uploader names, or clip cards.

Ambiguous entries must remain unconfirmed.

## Execution constraints

- Preserve all existing labels, footage, and historical evaluation results.
- Keep the exposure ledger append-only and fail-closed.
- Maintain backward compatibility.
- Re-run the dataset audit and report changes to all split counts, hard findings, soft findings, and provenance completeness.
- Follow the established feature-branch and PR review workflow.
- Do not merge without my authorization.
- Do not start Task B.2 until the remaining required owner confirmations are addressed and this work is reviewed.

Please identify the exact recording provenance questions I must answer and present them together rather than making assumptions.
