---
name: rally-classifier-coverage-audit-protocol-amendment-1
status: frozen 2026-11-18 on the owner's authorisation (D-040); in force from the builds that carry it
created: 2026-11-18T16:29:43Z
updated: 2026-11-18T16:29:43Z
decision: D-040; amends the protocol frozen under D-038; the owner's authorisation of 2026-11-18 ([verbatim](../decisions/2026-11-18-audit-trim-and-3x-authorization.md))
amends: RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md (SHA-256 bdb28442173588d25581ce904a78005e1c3b4d88f880864ca5ae5182c1293eab), which is not edited
---

# Amendment 1 to the negative-coverage audit protocol: viewing at up to 3×, and boundary-error corrections

The [protocol](RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md) was frozen on 2026-11-14 and is not edited. Every draw stays bound to that file's SHA-256 and commit, and stage 2 still follows its pilot "on the same dataset, folds and protocol" (the draw tool compares that file). This document changes one rule of it and settles how one kind of finding is corrected. It was written during the pilot (draw `20261115-072552`), after 13 first looks had been given, all at 2×.

Owner authorisation (2026-11-18): asked "Should 3× count toward Clean?" and "Apply trims to the rally marks on the Mac?", the owner answered "Yes on all of those". The implementer had recommended leaving the limit at 2×.

## A1.1 The viewing rate for `clean` is at most 3×

In §5, `clean` "is recorded only by the reviewer's explicit action after the whole interval has been played at no more than 2×". **From this amendment the limit is 3×.** The same number applies wherever the protocol and its tooling state the limit: the record's `playedAllAtMaxRate` is valid in (0, 3]; playback faster than 3× earns no viewing credit; scrubbing and seeking still earn none; §11's row for `clean` reads "≤ 3×".

Nothing else about `clean` changes: it is still the reviewer's explicit verdict, only over an interval played whole, with the surface tracking which ticks were played.

- **Looks already given stand.** A look played at 2× or slower satisfies both limits.
- **Why 2× was chosen, and what 3× risks.** The limit exists so that a short event — a served ball that goes nowhere, a brief rally — is not skimmed past. At 3× a 2 s event is on screen for under 0.7 s. The owner accepts this for speed of review.
- **Reported apart (A1.2)**, so the effect can be seen and, if needed, those intervals looked at again.

## A1.2 Clean intervals with a look faster than 2× are reported apart

Besides what §8 reports, the audit report gives the count and the seconds of clean intervals for which any look that counts (the first, the repeat, the resolution) was played whole at more than 2×. The blind repeat (§6) is unchanged and applies to them like any other interval; its agreement is the check on faster review. The pass / fail criterion (§8) is unchanged and does not depend on this number.

## A1.3 Boundary errors: entered as a trim, corrected in the marking pass

- **Entry.** A `boundary_error` may be entered as a trim at the playhead: the stretch of the interval the neighbouring mark should have covered, with its edge (`leading`: from the interval's start to the playhead; `trailing`: from the playhead to its end). This is the finding §5 defines, with its approximate seconds given to 0.1 s. The 1.0 s threshold of §5 is unchanged: a mark off by 1.0 s or less is not a boundary error, and the interval may be clean.
- **Correction.** §5 sends a boundary error "to the marking pass". The marking pass on the Mac may take the recorded finding as a proposal — the neighbouring mark's end moved to the end of a `leading` trim, or its start moved to the start of a `trailing` one — which the owner confirms or declines one by one. §12 stands: the audit itself writes, moves and deletes no mark; the correction is a marking-pass edit, made by a person, that uses the audit's finding as its input.
- **Not during a review.** A correction is refused while the stage whose draw holds the finding is incomplete (§8: an interval not reviewed, a repeat pending, a disagreement unresolved, a look unfinished). It is applied after that stage has been evaluated.
- **Afterwards**, as §8 already says: the report lists the marks that changed between the draw and the review, the intervals the corrections change are audited again under a new inventory and a new draw with its reason, and an interval whose bounds changed supplies no negative meanwhile.

## What this amendment does not change

The population, the sample and the frozen pilot draw; the verdict kinds and their definitions; the record's format (`coverage_audit_v2`); the blind repeat, its set and the 24-hour wait; the pass / fail criterion and its numbers; G6 and G7; what the protocol does not authorise (§12).

## Tooling

| What | Where |
|---|---|
| The limit | `CoverageAudit.maxCreditRate` (`Labeler/Shared/CoverageAudit.swift`, both apps); `AUDIT_MAX_RATE` (`scripts/rally_classifier/validate_dataset.py`); `MAX_COVERAGE_RATE` (`scripts/rally_classifier/coverage_audit_report.py`) |
| Reported apart | `cleanFastIntervals`, `cleanFastSeconds` in the report's per-recording rows and totals |
| The trim | `AuditModel.trim` (iPhone, PR #191); `b` / `⇧b` on the Mac (unchanged) |
| The correction step | not built yet; a later PR |
