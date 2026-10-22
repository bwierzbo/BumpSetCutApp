---
name: d007-threshold-decision
status: accepted
created: 2026-10-22T06:13:53Z
updated: 2026-10-22T06:13:53Z
source: owner, delivered to Claude Code on 2026-10-22
---

> Verbatim record of the owner's decision on the D-007 numerical threshold, given in answer to the open question in the scoring implementation plan. Normalised as the dated amendment under [D-007](DECISION_LOG.md#d-007). This file is the primary source; do not edit it.

Owner decision — D-007 numerical threshold

**Do not set a numerical dead-time-retention ceiling yet.**

Implement D-007 as approved:

- Primary objective: minimize dead-time retention subject to complete-rally recall meeting an approved target.
- Keep the recall target configurable but unset until the Phase 1A event-boundary review and corrected scoring provide reliable evidence.
- Do not introduce an arbitrary default ceiling or recall threshold.
- Do not treat the provisional 0.98 complete-rally criterion as the recall target. It defines whether an individual rally was preserved, not the required percentage of rallies preserved.
- Report complete-rally recall, dead-time retention, false clips, and the trade-off between candidate configurations.
- On partially annotated recordings, leave dead-time metrics unavailable rather than treating unmarked footage as verified dead time.
- Until the target is approved, permit diagnostic comparisons but do not automatically declare a configuration the winner under D-007.
- Preserve the historical `covered − 0.25 × dead time` score as a named diagnostic, not the optimization objective.

**Next steps:**

1. Finish the documentation/readiness PR and independent Codex review.
2. Let the current L2 export complete without interruption.
3. Once the export is finished, begin scoring PR A: interval library, reference scoring implementation, and parity against all 23 fixtures.
4. Keep PR B's numerical selection gates pending the event-review calibration evidence.
5. Return the verified L2 package and completed preregistration for separate final training approval.

No training or protected-holdout evaluation is authorized by this decision.
