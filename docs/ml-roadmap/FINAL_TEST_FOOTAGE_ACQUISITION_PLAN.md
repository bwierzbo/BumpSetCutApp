---
name: final-test-footage-acquisition-plan
status: proposed — a plan for the owner; nothing has been recorded, imported or reserved
created: 2026-11-15T06:45:31Z
updated: 2026-11-15T06:45:31Z
---

# A new, independent final-test set: what to record, how it is reserved before anything touches it, and how it is used once

Owner, 2026-11-14 ([verbatim](../decisions/2026-11-14-classifier-readiness-authorization.md)): "Prepare a new independent final-test footage acquisition plan. Reserve recordings before development-model exposure."

## 1. Why new footage

No recording the project holds today can be an independent test.

| Set | Count | Why it is not an independent final test |
|---|---|---|
| `final_test`, `final_test_candidate` | 0, 0 | the seven former candidates were pre-tracked and became lineage holdouts (D-015, D-017) |
| Lineage holdout | 16 (+ 3 train copies withheld with them, D-036/D-037) | "must never be described as an untouched final test" (D-017); three were trained on by L2 and four L1 runs under other names (D-036); two legacy holdouts and several of these have ball-path or scoring rows on the ledger |
| Legacy holdout | 5 | scored repeatedly for decider selection before the ledger existed (D-015) |
| The classifier dataset `rc-v1-20261112` | 49 | development data: 44 are in detector training packages, 24 carry `rally_scoring` rows; the shipped detector's own training set is not on record (preregistration §11.5, A13) |

D-002 reserves `final_test` "for recordings with no prior exposure"; D-016 says "the independent final test waits for new footage collected after the ledger existed". That footage does not exist yet.

## 2. What to record

| Requirement | Minimum | Why |
|---|---|---|
| Recordings | 9 full recordings (not clips), **3 per surface** (beach, grass, indoor) | a per-surface number needs more than one recording behind it; the experiment reports by surface (§7 of the preregistration) |
| Rallies | ≥ 15 per recording, ≥ 150 in total | if 5 % of rallies are observed missed, the exact one-sided 90 % upper bound on the rate is 8.5 % with 150 rallies (9.1 % with the 100 proposed earlier); about 50 per surface keeps the per-surface numbers descriptive only |
| Length | 8–20 minutes each, continuous, one take | dead time between rallies is what the dead-time and false-clip metrics are measured on |
| Camera | at the endline (the pipeline's assumption): at least 3 elevated (tripod / stands, 2 m+), at least 3 at ground level; at least 2 portrait | the placements the app is used in; one handheld recording may be added and is reported apart (A4) |
| Independence | every recording at a **venue and on a day no project recording shares**; at least two venues per surface where possible; no player group that appears in more than a third of the training recordings | a new card of an old outing is a sibling, not a test (D-036 showed how that goes unnoticed) |
| Source | the owner's iPhone, original files (no export through an editing app, no trimming before import) | continuous by construction; the frame-time identity of an iPhone original is known |
| Not acceptable | online footage; anything a tester's phone has processed and uploaded; a second cut of an outing already in the project | unknown venue relations and edits; the tester-footage flywheel imports uploaded rallies as **train** cards (`--pull-tester-footage`) |

The count is a floor for a first independent claim, not a target for a release decision; the record that uses the set states what it can and cannot support.

## 3. Reserving it before anything touches it

The order matters more than the tools.

1. **Record. Do not open the recording in the BumpSetCut app.** Processing it on a tester account uploads its rallies, and the Mac's footage pull would import them as training cards. Keep the originals in Photos (a dedicated album, e.g. "BSC final test").
2. **Name and list first.** Before any file reaches the project: choose the card names and write them to `pipeline_tuning/validation.json` under `finalTest`, and record each recording's `sourceId` (the Photos original file name), `sessionId` (outing) and `venueId`. From that moment the names are in the reserved set and the withheld closure, by name and — once the card exists — by every identity it shares (`ReservedVideos`).
3. **Import as a reserved card.** A withheld card with no session is registered with a metadata-only session: no detector, no pipeline, no machine labels, no ledger row of model use (PR #177, `SamplerModel.admission`). Every routine model run refuses the whole withheld closure (D-037 §3): scoring, tuning, comparison, pre-tracking, the Sampler, the Net-labels tab, the packagers, ball-path building, the labeling queues' track jobs (PR #181).
4. **Check.** `RallyLab --project Scratch --manifest --audit-dataset`: each new recording is `final_test`, its content was read, it shares no identity with any other card, and its exposure list is empty. The manifest's `finalTestExposed` guard fails the manifest if a `final_test` row ever shows exposure. Run the content-lineage audit (`scripts/content_lineage/audit.py`) over the ordinary recordings afterwards as usual; the protected ones are never decoded by it.

**Dependency F1 (to build and review before step 2):** no headless RallyLab command writes a `finalTest` reservation (none of the `--` commands in `RallyLab/Headless*.swift` does). A small command (`RallyLab --project <p> --reserve-final-test <name>… --source-id … --session-id … --venue-id …`) that writes the reservation and the provenance atomically, refuses a name that already has a session, a ledger row or a shared identity, and records who reserved it and when, would make step 2 a single checked action. Until it exists the footage stays in Photos and is not imported.

## 4. Marking it without lifting the reservation

- **Rally marks:** by hand, by the lead, on the Mac or the phone — manual annotation of a withheld recording is allowed (D-037 §3; PR #181: "by hand only", no snapping to a ball path, no found rallies shown).
- **Frame-exact contact and dead times (Stage 1):** `EventReview.open` refuses a withheld recording today (`RallyLab/EventReview.swift`), and the phone's `rally_events_save` raises `withheld` for every account (migration 048). **Dependency F2:** a separately authorised, person-only annotation path for `final_test` recordings — an owner-signed per-recording authorisation that the Stage 1 opener and the coverage audit honour and every model-facing consumer ignores, with `event_review` / `coverage_audit` ledger rows that the manifest treats as labeling, not exposure. It is a reviewed change with its own decision; the reservation is never lifted temporarily to mark.
- **Negative coverage:** the coverage audit ([protocol](RALLY_CLASSIFIER_COVERAGE_AUDIT_PROTOCOL.md)) refuses protected recordings. Under F2 the same review (every unmarked interval watched by a person, blind to the pipeline) certifies the final-test recordings' dead time; without it their dead-time and false-clip metrics are undefined.
- Who marks: the owner. The marker has not seen any candidate's output on these recordings, because none has been produced.

## 5. Using it — once

A separate preregistered record names the single candidate carried forward and the baseline, the metrics and the decision rule, before the run. The `rally_scoring` ledger rows are written before the pass; baseline and candidate are scored on the same evidence in one pass; the record closes. No second look for selection, no tuning on it, no re-run after a change — a changed candidate needs a new independent set or an explicit statement that the set is now exposed. Until then the set exists only as cards and marks.

## 6. Order of work and owner decisions

| # | Step | Who | Depends on |
|---|---|---|---|
| 1 | Decide to record, where and when (three surfaces; winter makes beach and grass the constraint) | owner | — |
| 2 | Build and review F1 (reserve-at-import command) | implementer, PR | owner's go |
| 3 | Record; keep in the Photos album; process nothing | owner | 1 |
| 4 | Reserve, then import, then manifest + audit | owner with the implementer | 2, 3 |
| 5 | Mark rallies by hand | owner | 4 |
| 6 | Build and review F2 (person-only Stage 1 and coverage review of `final_test`) | implementer, PR + decision | owner's go |
| 7 | Stage 1 and coverage review | owner | 5, 6 |
| 8 | Preregister and run the one evaluation | owner approves | 7, and a candidate that passed development evaluation |

Open decisions: whether and when to record (1); whether F1 and F2 are built now or when the footage exists; whether a second person marks a sample for agreement.

## 7. What this plan does not do

It records, imports, reserves and marks nothing. It does not change the withheld closure, lift any reservation, or claim that any existing holdout is pristine. The classifier's development evaluation on `rc-v1-20261112` and its successors does not wait for this set and is not replaced by it: development evidence stays development evidence (A13).
