---
name: court-net-calibration-format
status: active
created: 2026-11-25T01:01:46Z
updated: 2026-11-25T01:01:46Z
---

# Court and net calibration format (`court_net_calibration_v1`)

Where the court and the physical net lie in a recording, as a person confirmed them. Decision: [D-042](../decisions/DECISION_LOG.md#d-042). Code: `BumpSetCut/Core/Calibration/` (`CourtLayout.swift`, `NetQuad.swift`, `CourtNetCalibration.swift`, `CourtNetCalibrationStore.swift`). Tests: `BumpSetCutTests/Domain/Calibration/`.

This document describes the file and its rules. One reader uses a calibration in processing: the app's `CalibrationNetSource` gives the pipeline the box round a **confirmed net**, for the existing under-net, off-court and above-net rules, when that net was confirmed for the file being processed and one stable camera view covers the whole video ([what changed and what is not verified](YOLO_DEPENDENCY_INVENTORY_2026-11-24.md)). Nothing reads the **court** to make a rally decision (D-042, point 4).

## Coordinates

Every point is in the **upright frame** (the stored frame turned by the track's orientation), as fractions of its width and height, **origin bottom-left, y up** — `coordinateSpace: "upright_vision_normalized"`. It is the space of the pipeline's ball boxes, of RallyLab's net labels and of the P2 court research. The file records the upright frame's pixel size and the orientation, so a reader can tell when its own decode differs.

## The two shapes

| Shape | Type | Points | Outside the frame | Not placed |
|---|---|---|---|---|
| Court (ground lines) | `CourtLayout` — `court_geometry_v1`, unchanged from PR #166 | `nearLeft`, `nearRight`, `netRight`, `netLeft`, `farLeft`, `farRight`, each `x`, `y`, `status` (`seen` / `estimated` / `unknown`) | allowed, −1.5 … 2.5 | `unknown`; the half that needs the point has no map |
| Physical net | `NetQuad` — the type of RallyLab's net labels, moved to a shared file | `topLeft`, `topRight`, `bottomRight`, `bottomLeft`, each `x`, `y` | refused | all four are needed |

`netLeft` / `netRight` of the court are where the net's **ground line** meets the sidelines; they are not the net's bottom corners. The court is never assumed rectangular on screen: each half (near end line to net line, net line to far end line) has its own perspective map, fitted from its four points. A court is usable when every placed point is in range, at least one half is a convex four-sided region, and the halves lie on opposite sides of the net line. A net is usable when its corners are in the frame, turn the same way all round (no crossing or fold) and enclose a usable area.

## The file

One file per recording, `<recordingId>_calibration.json`.

| Field | Meaning |
|---|---|
| `schemaVersion`, `coordinateSpace` | `court_net_calibration_v1`, `upright_vision_normalized` |
| `recordingId` | the recording's id where the file is kept (the app's video id) |
| `sourceFingerprint` | the video file's identity: `file:<sha256>` of its size and first and last 4 MB (`FileFingerprint`, the algorithm of RallyLab's `fileFingerprint`) |
| `frameWidth`, `frameHeight`, `orientation` | the upright frame in pixels; the orientation that makes the stored frames upright |
| `durationSec` | the recording's length |
| `setup` | the person's answers: `surface` (beach / grass / indoor), `format` (2v2 / 4v4 / 6v6), `answeredAt`; they give the court's size (16 × 8 m or 18 × 9 m) and are metadata, never proof of where the court is |
| `segments` | camera views, in order, tiling 0 … `durationSec` with no gap or overlap |

A segment: `id`, `validFromSec`, `validToSec`, `view` (`stable`, `not_stable_court_view`, `unknown`), `frameTimeSec`, `note`, `viewDecidedAt`, and two parts, `court` and `net`. Each part holds:

| Field | Meaning |
|---|---|
| `proposals` | what a method offered, as made: `method` (`net_guided_v1`, `court_lines_v1`, `combined_v1`, a model's name), `kind` (`detection` or `estimate`), `geometry`, `confidence`, `uncertainty`, `createdAt` |
| `draft`, `draftStartedFrom`, `draftBaseline` | the person's working geometry (saved as placed, usable or not), what it started from, and that starting geometry untouched |
| `confirmation` | the person's Confirm: `geometry`, `startedFrom` (a proposal's method, `manual`, `confirmation`, `segment N`), `baseline` (the geometry it started from; absent when placed from nothing), `adjustedPoints`, `confirmedAt`, `confirmedBy`, `tool` |
| `history` | earlier confirmations, replaced or withdrawn |

## Rules

1. **Only a person's Confirm confirms.** `confirm` is the one path: it takes the segment's draft, refuses an unusable geometry or a view that is not stable, and moves the confirmation it replaces to `history`. Court and net are confirmed separately.
2. **A proposal changes nothing.** Adding one appends to `proposals`; the draft and the confirmation are untouched. An editor opens on, in order: the draft, the confirmation, the latest detection, the latest estimate, nothing.
3. **A camera change splits the segment.** The second half starts with nothing confirmed. With reuse, the first half's court and net become the second's drafts (`startedFrom: "segment N"`) — a starting point, never a confirmation.
4. **A view that is not stable holds no confirmation.** Marking one moves its confirmations to `history`.
5. **Stale is never used.** A file whose schema, coordinates, recording, fingerprint, frame, orientation or length (beyond 0.05 s) differs from the video as it is now is `stale`: the store returns it marked so, for display only.
6. **The store fails closed.** A file that exists but can't be decoded, or is malformed, is an error — never an empty calibration — and is not written over. A save that would lose a confirmation on file (in force or in history) is refused. Saving a file for another video under the same id sets the old one aside as `<recordingId>_calibration.superseded-<time>.json` — only once the replacement is encoded, and it is put back if the replacement's write fails. A coordinate that is not a number is malformed anywhere, a draft included. Writes are atomic.

## Status

For a status line: `notCalibrated`, `draft`, `courtConfirmed`, `netConfirmed`, `bothConfirmed`, `unsuitable` (no stable view in the recording) and `needsReview` (stale or malformed, or the stable views stand differently — one confirmed, another waiting).

## Against the P2 research format (PR #166)

| | P2 `court_geometry_v1` file | This format |
|---|---|---|
| Court points | `CourtLayout` | the same type, the same JSON |
| Net | a copy of the net label inside the court confirmation | its own shape with its own proposals, draft, confirmation and history |
| Bound to | recording id, project fingerprint, decoded copy's fingerprint, frame, orientation | recording id, the file's fingerprint, frame, orientation, length |
| Segment state | one status (`unreviewed`, `confirmed`, `rejected`, `unknown_view`) | the view (`stable` / not / unknown), with court and net confirmed separately |
| Kept where | the experiment folder, research only | wherever the caller's store points |

The zone classifier (`court_polygon_v1`), the proposers and the review tooling stay in PR #166. When that branch is next rebased it should take `CourtLayout.swift` from here in place of its own copy.
