---
name: iphone-coverage-audit-direction
status: accepted (owner direction); its decision is D-039 (accepted 2026-11-17)
created: 2026-11-17T19:42:39Z
updated: 2026-11-17T19:42:39Z
source: owner, delivered to Claude Code on 2026-11-17
---

> Verbatim record of the owner's direction, reproduced as received. In summary:
> - The existing negative-coverage audit is brought to the iPhone's labeling app, sharing one audit state with RallyLab, under the same frozen protocol and coverage_audit_v2 records.
> - Synchronisation is the smallest safe extension of the labeling server; any schema, migration or permission change is prepared and stops at the owner's approval gate.
> - First release: the frozen pilot (draw 20261115-072552), behind an owner/tester control; physical-iPhone acceptance with a throwaway record before one legitimate interval.
> - Not authorised: merging, applying a migration, a TestFlight distribution, training, changing the frozen pilot, weakening G6/G7, or any synthetic human review.

BumpSetCut — Owner Direction: Bring Human Coverage Auditing to iPhone

Date: 2026-11-17
Repository: bwierzbo/BumpSetCutApp
Starting branch: Current main, verify before beginning
Priority: High — unblock human auditing away from the Mac

Objective

Implement the existing RallyLab negative-coverage audit workflow in the BumpSetCut iPhone labeling experience.

I want to audit recordings directly on my iPhone during breaks at work, without remotely controlling my Mac.

The iPhone and RallyLab must share the same audit state so I can begin on one device and continue on the other.

This is an extension of the existing human-labeling workflow, not a separate experiment or independent labeling system.

1. Inspect Existing Implementations

Read the repository instructions and relevant decisions, especially D-038.

Inspect:

* RallyLab’s CoverageAudit.swift
* CoverageAuditRecording.swift
* CoverageAuditModel.swift
* CoverageAuditView.swift
* The frozen coverage-audit protocol
* Existing iOS rally-marking screens
* LabelingClient and the existing labeling server
* Local video storage and downloads
* Labeling sync, permissions and conflict handling
* PR #181’s withheld protections
* PR #188’s optional Audit-tab usability improvements

Determine which audit rules and data structures can be shared safely between Mac and iOS.

Avoid duplicating business logic unnecessarily.

2. Mobile User Experience

Add an Audit Mode to the existing iPhone labeling interface.

The owner should be able to:

1. Open Audit Mode.
2. See the current pilot’s overall progress.
3. Select the next unreviewed interval.
4. Watch the interval, including one second of context on either side.
5. Play at 0.5×, 1×, or 2×.
6. Mark Clean, Missed Rally, Missed Serve, Boundary Error, Non-Rally Activity, Edited Footage, or Uncertain.
7. Enter an approximate timestamp and notes when needed.
8. Save the verdict.
9. Automatically advance to the next interval.
10. Leave the app and resume later without losing progress.

Optimize the interface for portrait one-handed use.

Use clear, large controls and minimize unnecessary navigation.

The interface should display the number of reviewed and remaining intervals, recordings completed, and findings.

Support both short and long intervals.

Do not display ball-path, detector, or predicted rally overlays during the audit.

3. Preserve the Existing Audit Rules

The iPhone must honor the same frozen protocol and audit records as RallyLab.

Requirements:

* Only an actual human verdict counts.
* Clean cannot be selected until the full interval has played at 2× or slower.
* Seeking does not earn viewing credit.
* Pausing or backgrounding the app does not earn viewing credit.
* Findings preserve approximate timestamps and notes.
* A missed rally does not automatically rewrite existing rally marks.
* Reviewer identity is recorded.
* A same-reviewer blind repeat requires at least 24 hours between reviews.
* First-pass verdicts are hidden during blind repeats.
* Disagreements remain unresolved until explicitly reviewed.
* Every verdict is tied to its frozen draw, recording, interval and source identity.
* Changes to the source or marks cannot silently reuse an invalid audit.

The Mac’s coverage_audit_v2 records remain authoritative in meaning.

Do not create an incompatible mobile-only audit schema.

4. Synchronization

The phone and RallyLab should operate on one logical audit.

Investigate the smallest safe extension to the existing labeling synchronization system.

Synchronize:

* Frozen pilot identity and interval queue.
* Reviewer identity.
* First-pass verdicts.
* Findings and notes.
* Playback-coverage evidence.
* Blind-repeat status.
* Resolutions.
* Completion and synchronization status.

Implement idempotent writes, appropriate version checks, and conflict detection.

Never silently overwrite another reviewer’s work or a newer valid audit record.

The Mac must validate synced results against the same rules used for local audits before treating them as trusted training evidence.

Consider intermittent connectivity. If safe offline review is feasible, preserve pending verdicts locally and reconcile them when connected.

If authentication, source identity, or audit provenance cannot be established, fail closed rather than manufacturing a valid review.

Do not weaken server RLS or withheld-footage protections.

If a new server schema, migration, or permission change is required, prepare the reviewed change and stop at the owner approval gate before applying it.

5. Mobile Video Availability

The audit must work on footage accessible to the iPhone.

Investigate which of the 12 pilot recordings are already available on the phone or its supported video service.

Do not assume the Mac’s local footage paths work on iOS.

If another encoding or mobile proxy is used, verify that it represents the correct source recording with the same timeline and a defensible timestamp mapping.

Do not equate two video files merely because their names match.

Provide a clear unavailable-video state and an approved means of obtaining missing footage.

Where supported, allow the owner to prepare or download audit footage for later review.

Do not silently substitute unrelated, shortened, or edited copies.

6. First Release Scope

Prioritize getting the existing frozen pilot usable on the owner’s iPhone.

Pilot:

* Draw: 20261115-072552
* 12 recordings.
* 150 unmarked intervals.
* 35 blind-repeat intervals.
* No human reviews recorded as of the latest report.

Keep this feature behind an appropriate owner/tester control initially.

Don’t build a general multi-user audit-management platform before the first pilot works.

Stage 2 should use the same underlying implementation once the pilot passes.

7. Testing

Add tests for:

* Audit-record schema compatibility between Mac and iPhone.
* Interval and timestamp equivalence.
* Playback-coverage enforcement.
* Reviewer identity.
* Offline interruptions and retry behavior.
* Duplicate submissions.
* Conflicting updates.
* Stale marks and changed footage.
* Withheld recording refusal.
* Blind-repeat timing and verdict visibility.
* Proper ledger reconciliation.
* Resume after app termination.

Use synthetic fixtures for automated tests.

No scripted or automated verdict may count toward the real frozen pilot.

Perform physical-iPhone acceptance testing with a throwaway audit record before testing one legitimate pilot interval.

Verify that a real verdict saved on the iPhone appears correctly in RallyLab, with its identity, coverage evidence and audit status intact.

8. Delivery and Approval Gates

Implement this work in a dedicated feature branch and PR.

Run applicable iOS, RallyLab, Labeler, synchronization and Python tests.

Obtain independent Codex review and resolve substantive findings.

Do not merge automatically.

Prepare a TestFlight build only after the required code and backend changes are approved.

Do not distribute the build without separate owner authorization.

Do not train a classifier, modify the frozen pilot, weaken G6/G7, or generate synthetic human reviews.

9. Required Owner Report

Report:

1. Which existing iOS labeling components were reused.
2. Which audit data structures are shared with RallyLab.
3. How verdicts synchronize.
4. How conflicts and offline reviews are handled.
5. How many pilot recordings are available on the phone.
6. Which backend changes, if any, are necessary.
7. Test and Codex review results.
8. Exact steps remaining before I can begin auditing on my iPhone.
9. The earliest safe TestFlight delivery path.

Prioritize delivering a functional, trustworthy mobile pilot over expanding the audit system with unrelated features.

Stop at the owner merge, backend-change and TestFlight approval gates.
