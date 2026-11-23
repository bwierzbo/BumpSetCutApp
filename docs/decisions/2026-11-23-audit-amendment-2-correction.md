---
name: audit-amendment-2-correction
status: record (correction of a statement of fact; no decision is changed)
created: 2026-11-23T21:26:08Z
updated: 2026-11-23T21:26:08Z
source: Claude Code (implementer), from the pilot's audit records as RallyLab holds them after the sync of 2026-11-21
corrects: one statement of fact in RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL_AMENDMENT_2.md (frozen, SHA-256 09d938e09859b1e6c68902d52ade56db271f51cf5dc0868c36205e194ebe86a5), which is not edited
---

# Correction: six second looks had been given before the blind repeat was removed

[Amendment 2](../ml-roadmap/RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL_AMENDMENT_2.md) to the coverage audit protocol (D-041) is frozen and is not edited. It states a fact that is wrong. This note is the correction; where the two disagree on this fact, this note is right.

## What the amendment says

- "No blind-repeat verdict and no resolution had been given; the labeling server's records held none." (under "When this was written, stated as it is")
- "The audit report says so in its output and gives the number of second looks on record (zero for the pilot)." (A2.3)

## What the records show

Six blind-repeat verdicts had been given, all by the owner on the iPhone, in the pilot draw `20261115-072552`. No resolution had been given: that part of the statement is right.

| Recording | Interval | First look (UTC) | First verdict | Second look (UTC) | Second verdict |
|---|---|---|---|---|---|
| `bch_ele_ovc_land_self_02_v2` | 2 | 2026-11-18T15:34:40Z | clean | 2026-11-21T01:54:12Z | clean |
| `bch_ele_ovc_land_self_02_v2` | 5 | 2026-11-18T15:35:12Z | clean | 2026-11-21T01:54:19Z | clean |
| `bch_ele_ovc_land_self_02_v2` | 9 | 2026-11-18T16:16:53Z | clean | 2026-11-21T01:54:26Z | clean |
| `bch_extra_self_04` | 1 | 2026-11-19T17:21:58Z | clean | 2026-11-21T01:54:34Z | clean |
| `bch_extra_self_04` | 8 | 2026-11-19T17:24:23Z | clean | 2026-11-21T01:54:40Z | clean |
| `bch_extra_self_04` | 10 | 2026-11-19T17:29:24Z | clean | 2026-11-21T01:54:49Z | clean |

Each second look is recorded as played whole at 3×, with the method `same_reviewer_after_24h`, and each came more than 24 hours after its first look. They were given with the build that still had the Blind repeat pass, as the protocol then required.

## How the wrong statement came to be written

The implementer checked the labeling server for second looks shortly before the owner's instruction of 2026-11-20 and found none. The six were given within the next minute, at 01:54:12–01:54:49 UTC on 2026-11-21, and the amendment was written (02:05 UTC) from the earlier check without looking again. The error is the implementer's.

## What this changes, and what it does not

- **The pilot's result is unchanged.** Amendment 2 evaluates on first looks. The report (`coverage_audit_report.py`, run 2026-11-23 on the records the Mac adopted) gives a pass: *m* = 2 of *n* = 127, one-sided 90 % upper bound 4.14 %, most in one recording 1. It prints "second looks on record: 6" and "identical on 6 of 6".
- **The six are valid and stay on record**, as A2.4 already provides for a record that holds a repeat verdict. Nothing is withdrawn or rewritten.
- **"6 of 6" is not an agreement figure for the result.** It covers 6 of the 36 intervals the repeat would have covered, in 2 of the 12 recordings, all of them `clean` both times; neither of the two missed findings and not the `uncertain` interval is among them. A2.3 stands: the result is reported as "single look, pipeline-blind, not repeated".
- **The order of events the amendment records is otherwise right**: the first-look result was known, and stood at the passing limit, when the repeat was removed, and the implementer recommended keeping it. To that is added: the repeat had been started, and its first six looks agreed, when it was removed.
- No protocol rule, draw, record, criterion or tool is changed by this note.
