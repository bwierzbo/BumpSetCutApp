---
name: rally-classifier-coverage-audit-protocol-amendment-2
status: frozen 2026-11-20 on the owner's authorisation (D-041); in force from the builds and tools that carry it
created: 2026-11-21T02:05:36Z
updated: 2026-11-21T02:05:36Z
decision: D-041; amends the protocol frozen under D-038 and its amendment 1 (D-040); the owner's authorisation of 2026-11-20 ([verbatim](../decisions/2026-11-20-audit-single-look-authorization.md))
amends: RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md (SHA-256 bdb28442173588d25581ce904a78005e1c3b4d88f880864ca5ae5182c1293eab) and RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL_AMENDMENT_1.md (SHA-256 aaae6a7ed275c7c9ff6b03149f58626011626059efcd2a5998c2d83103d0a229), neither of which is edited
---

# Amendment 2 to the negative-coverage audit protocol: one look at each interval

The [protocol](RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md) was frozen on 2026-11-14 and [amendment 1](RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL_AMENDMENT_1.md) on 2026-11-18. Neither is edited. Every draw stays bound to the protocol file's SHA-256 and commit, and stage 2 still follows its pilot "on the same dataset, folds and protocol". This document removes one part of the procedure.

Owner instruction (2026-11-20): "i also dont want second looks or resolves lets remove that and just have the one confirm audit".

## When this was written, stated as it is

It was written during the pilot (draw `20261115-072552`), **after every one of its 150 intervals had its first verdict**, all by the owner: 147 clean, one `missed_serve`, one `missed_rally`, one `uncertain`. That is *m* = 2 against the draw's criterion of *n* = 127 with a largest passing *m* of 2: **the first-look result was known, and stood exactly at the passing limit, when the repeat was removed.** No blind-repeat verdict and no resolution had been given; the labeling server's records held none.

The implementer recommended keeping the repeat (36 intervals for the pilot). The owner chose to remove it. A reader of any result under this amendment should weigh it with both facts in view.

## A2.1 No blind repeat, no resolution: the first look is the interval's verdict

- §4.2 (the blind-repeat set), the third, fourth and fifth points of §6 (the blind repeat, how agreement is reported, disagreement) and the 24-hour wait **no longer apply**. No second look is owed for any interval — neither the draw's `repeatIndices` nor an interval the first review left `uncertain` — and none is taken. No resolution is taken.
- §8, "When the pilot can be evaluated", now reads: **only when every interval of all twelve recordings has an accepted first verdict, and no verdict that counts carries findings given before its interval had played whole.** Until then the outcome is `incomplete`. The same holds for a stage 2 recording's derived state.
- Everything §5 requires of a look still holds for the one look: the reviewer's explicit action, the whole interval played at no more than 3× (amendment 1), seeking and scrubbing earning no viewing credit, no ball path or pipeline output on screen.
- This applies to the pilot draw `20261115-072552` as it stands and to stage 2.

## A2.2 An interval left `uncertain` stays uncertain

§4.2 sent every `uncertain` interval to the repeat. It is now not looked at again under this protocol. It keeps what §7 and §9 already give it: its recording is `partial`, it is reported with its count and seconds, it is not a `missed_rally` or `missed_serve` and so is not in *m*, and it supplies **no** trusted negative.

## A2.3 What a result is called

The first two points of §6 stand and are now the whole of it: the auditor is the owner, who in most cases also made the marks, and the review is **one look by, mostly, the same person — blind to the pipeline, not an independent annotation, and not repeated.**

- A result under this amendment is reported as "single look, pipeline-blind, not repeated". It is never reported as repeated, as checked for consistency, or as independent verification, and **no agreement figure exists for it**.
- The audit report says so in its output and gives the number of second looks on record (zero for the pilot).
- Amendment 1 (A1.2) said of clean intervals viewed faster than 2× that the blind repeat's "agreement is the check on faster review". **That check no longer exists.** Those intervals are still reported apart, which is now the only view of them.

## A2.4 Draw files and records are unchanged

- **The draw.** `coverage_draw_v2` is not changed: a draw file, the pilot's and a stage 2 one alike, still records `repeatIndices`, `repeatOneIn` and `repeatMin`, and the frozen pilot draw is not rewritten. Those intervals are simply not reviewed a second time.
- **The record.** `coverage_audit_v2` is not changed. A record that holds a repeat verdict or a resolution is still valid and is read as the protocol says: a resolution is what counts where the two looks disagree, and an unresolved disagreement counts for nothing. The review surfaces give no new one and cannot withdraw one.

## What this amendment does not change

The population, the sample and the frozen pilot draw; the verdict kinds and their definitions; the 3× limit and the boundary-error trim and its correction (amendment 1); the pass / fail criterion and its numbers (§8: the bound on *m / n* and at most two missed findings in one recording); stage 2 being entered only after the pilot passes, as the draw tool establishes from the records; G6 and G7, and that only an explicitly reviewed `clean` interval supplies a trusted negative; what the protocol does not authorise (§12).

## Tooling

| What | Where |
|---|---|
| Evaluation on first looks alone; "single look" stated; second looks on record counted | `scripts/rally_classifier/coverage_audit_report.py` (`repeated` replaces `repeatPending` in the per-recording rows and totals) |
| No second look or resolution given | `CoverageAudit.applying` refuses both with `noSecondLook` (`Labeler/Shared/CoverageAudit.swift`, both apps); `CoverageAudit.owed(.repeatLook, …)` is empty |
| The review surfaces | the pass picker is removed from RallyLab's Audit tab and from the iPhone's (Blind repeat, Resolve) |
| Boundary corrections (A1.3) | wait for every first look, and for any disagreement an older record holds; no longer for repeats |
