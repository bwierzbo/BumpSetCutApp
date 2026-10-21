---
name: provenance-questions-2026-10-21
status: Q0 → D-016; Q1–Q3 answered and applied 2026-10-21 (see PROVENANCE_REVIEW); Q4 deferred
created: 2026-10-21T05:20:00Z
updated: 2026-10-21T17:20:09Z
decisions: D-015, D-016
---

# Provenance questions for the owner (Task B.1, after D-015)

Everything D-015 asked for that does not need your answer is done (see [PROVENANCE_AUDIT_2026-10-21.md](PROVENANCE_AUDIT_2026-10-21.md) § "Decisions applied"). What remains needs facts only you have.

**Status 2026-10-21.** Q0 is decided: [D-016](../decisions/DECISION_LOG.md#d-016), option (a) strict. Q1–Q3 were answered on the review page and applied on 2026-10-21 (20 videos; table and consequences in PROVENANCE_REVIEW_2026-10-21.md § "Answers applied") described in [PROVENANCE_REVIEW_2026-10-21.md](PROVENANCE_REVIEW_2026-10-21.md) (`scripts/provenance_review.py`); the exported answer file is applied with `--set-provenance` in a reviewed PR and nothing is inferred. Q4 stays deferred.

## Q0 — A ruling first: does pre-tracking count as exposure?

All seven candidates carry **machine tracks written by a pre-tracking run** (`--pretrack --val`, 2026-10-18, model not recorded), 6–8 tracks each, with **zero reviewed frames**. The ledger did not exist then; the audit now discovers this from the session files (`pre_tracking`, "session tracks (machine)"). Under the current rule, any exposure blocks promotion to `final_test`, so today none of the seven is promotable.

What actually happened: a detector ran over the footage and wrote candidate tracks into the session file. Nothing was trained on them (val sessions never contribute machine labels to packages), nothing was selected on them, and no human reviewed them.

Options:
- **(a) Strict.** Pre-tracking is exposure; the seven stay protected candidates and the final test waits for new footage. Simplest, most defensible.
- **(b) Clear and promote.** Rule that unreviewed, never-exported machine tracks are not model-selection or training exposure; delete the machine tracks from the seven sessions (nothing human-made is lost; a note stays in the manifest that pre-tracking happened); promotion then depends only on Q1–Q2. Recommended, with the caveat recorded permanently.
- **(c) Keep as an "evaluation resource"** with the exposure noted, never called `final_test`.

Your choice becomes a decision-log entry (D-016). Until then the seven stay protected either way.

**Answered:** (a) strict — [D-016](../decisions/DECISION_LOG.md#d-016). The machine tracks stay in the sessions; no candidate is promoted; the final test waits for new footage.

## Q1 — Venue and session for each candidate

The seven are your own phone recordings (local files, `IMG_*.MOV`). Photos numbers run in capture order, so a training import with an adjacent number was almost certainly filmed in the same outing. That is a **hint for you to check**, not something the audit records.

| Candidate | Photos file | Surface | Nearest training imports by Photos number (hint only) | Your answer: venueId · sessionId (date) · camera |
|---|---|---|---|---|
| `bch_extra_self_05` | IMG_4969.MOV | Beach | `bch_extra_self_31` (IMG_4970, Δ1), `bch_extra_self_30` (IMG_4967, Δ2), `bch_extra_self_29` (IMG_4966, Δ3) | |
| `bch_extra_self_18` | IMG_0612.MOV | Beach | `bch_extra_self_10` (IMG_0643, Δ31), `bch_extra_self_02` (IMG_0668, Δ56) | |
| `grs_extra_self_06` | IMG_0823.MOV | Grass | `grs_extra_self_12` (IMG_0822, Δ1) | |
| `grs_extra_self_07` | IMG_2378.MOV | Grass | `grs_extra_self_02` (IMG_2379, Δ1) | |
| `grs_extra_self_14` | IMG_4372.MOV | Grass | `grs_extra_self_15` (IMG_4374, Δ2), `grs_extra_self_16` (IMG_4394, Δ22) | |
| `grs_extra_self_21` | IMG_4778.MOV | Grass | `grs_extra_self_20` (IMG_4776, Δ2) | |
| `ind_extra_self_09` | IMG_0043.MOV | Indoor | `ind_extra_self_06` (IMG_0041, Δ2) | |

Read plainly: six of the seven look like they were shot in the same outing as a **training** video. If you confirm that, they are not independent of training and cannot be a final test, whatever Q0 decides. `bch_extra_self_18` is the only one with no near neighbour.

For each candidate please give:
1. **venueId** — any stable name you will reuse (e.g. `beach-huntington-pier`, `park-rosebowl-grass`, `gym-ymca-main`).
2. **sessionId** — the outing: date plus a tag if you filmed twice that day (e.g. `2026-07-14-pm`).
3. **camera** — which phone/mount, if not the usual one.
4. Whether the neighbouring training imports listed were the **same venue and session**. If yes, say whether you would rather (i) drop the candidate, or (ii) move those training videos out of train (they would need their own exposure review).

## Q2 — Venues for the training imports (so the audit can see overlap)

The 54 training `*_extra_self_*` videos have no uploader and one video per card, so the card/uploader checks cannot see overlap between them and the candidates. Until they carry a `venueId`, **your confirmation in Q1 is the only guard**. You do not need to label all 54 now; the ones adjacent to candidates (listed above) are enough to settle Q1. If you can give a venue for each outing in one line ("IMG_4966–4970: beach-X, 2026-08-03"), that covers it.

## Q3 — The legacy holdout and Dianne Gan

`bch_onl_sun_land_onl_03` and `_v2` (now both `legacy_holdout`) share the uploader *Dianne Gan* with two **training** videos: `grs_onl_sun_land_onl_04` (grass) and `grs_sid_shade_land_self_02_v2` (grass). Different surfaces, so probably different venues, but a channel can film at several. Please confirm a `venueId` for those four (two values would do: one beach, one grass) so the audit can clear or escalate the overlap.

## Q4 — Optional now, needed before D-007 tuning

Cards whose uploader spans tune and dev_val: Grace Qian (`grs_hnd_shade_port_self_02`, `grs_onl_dusk_land_onl_03`, `grs_onl_shade_land_onl_02`, `grs_onl_sun_land_onl_01`, `_v2`) and Blake Seegers (`bch_onl_ovc_land_onl_02` ×4). A `venueId` per card (or per video if they differ) lets the audit judge the tune/dev_val overlap when D-007 is implemented (decision 3 said reassess then).

## What happens with your answers

- Q0 → D-016 in the decision log: strict; nothing removed, nothing promoted.
- Q1–Q3 → `--set-provenance` per video (reviewed PR with the before/after report), audit re-run, and only candidates that come out `CANDIDATE-READY` are moved to `finalTest`.
- Independent of all of the above: the stronger final-test collection (new venues, sessions, cameras, all three surfaces) stays planned as new footage.
