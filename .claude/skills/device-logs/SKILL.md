---
name: device-logs
description: Triage pasted iOS device console output. Use whenever the user pastes device/Xcode console logs (often large and mostly OS noise) to report a bug or verify a feature — filter to app-relevant lines first, then diagnose.
---

# Device console log triage

The user tests on a physical iPhone and pastes raw console output. Most of it is benign OS noise. Triage before diagnosing:

## 1. Discard known noise (do not analyze or mention these)

- `RBSService` / `RBSAssert` / process-assertion chatter
- `Unable to obtain a task name port right for pid ...`
- `CoreTransferable` plumbing (unless the bug IS drag/drop or share-sheet)
- Keyboard/input noise: `RTIInputSystemClient`, "accumulator", `UIKBFeedbackGenerator`
- `CKImageMediaObject`, `LaunchServices`, `HALC_`/audio-HAL chatter, `nw_connection` teardown spam
- SwiftUI layout-loop warnings unless the report is about UI jank

## 2. Extract signal

- App-tagged lines: `🪁` (flywheel), `[BumpSetCut]`, emoji-tagged debug prints
- Supabase/PostgREST errors: HTTP status codes, `row-level security`, `Could not find the function`, `PGRST` codes, storage 4xx — for these, check the live schema/policies via the Supabase MCP before proposing app-side fixes (past incidents: missing UPDATE policy with `upsert:true`; RPC call signature not matching the migration)
- Crashes, `error:`, `Fatal`, thread-priority-inversion warnings tied to app frameworks (e.g. AVAudioSession)

## 3. Diagnose

State plainly which pasted lines are noise (one sentence, collectively) and which line is the actual signal, then work the signal. If a needed detail is missing, ask for a specific filter, e.g.:

```
log stream --predicate 'processImagePath CONTAINS "BumpSetCut"' --level info
```

If verification needs more logging, add temporary tagged debug prints — and strip them before committing (user preference).
