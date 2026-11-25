---
name: mark-kind-impact-audit-2026-11-04
status: read-only audit; repair procedure proposed, not applied (owner decision pending)
created: 2026-11-05T01:20:21Z
updated: 2026-11-05T01:20:21Z
---

# Mark-kind impact audit (2026-11-04)

Read-only audit for the D-028 amendment of 2026-11-04 ([DECISION_LOG.md](../decisions/DECISION_LOG.md#d-028)): what the marks' kinds were worth to the code before the amendment, what that did to stored track decisions and to the scores on record, and how the affected data could be repaired. Nothing here was changed: the queries are reads of the live server (Supabase project `nodxhfrdefmaksisuylb`, 2026-11-04 ~18:00 MT), the records are quoted as they stand.

## 1. What the code did before the amendment

| Reader | Before | Effect |
|---|---|---|
| `LiveTagger.close(as:at:)` → `LiveTagStore.confirmPretracked(start:end:)` (Mac `ProjectLiveTagStore`, phone `PhoneLiveTagStore`) | confirmed (`isRally = true`) and trimmed every pre-tracked rally mostly inside the closed mark, whatever its kind | a missed serve or "not a rally" closed over a pre-tracked rally would have confirmed it as a rally |
| "That's every rally" (Mac `LiveTagView.finish`, phone `MarkRalliesView.finish`) | a pre-tracked rally mostly inside **any** mark counted as covered; a found rally overlapping any mark by 0.3 s counted as marked | a machine prediction under a missed serve was left unrefuted, and a found rally there was never dropped |
| `TrainingDataExporter`, `RallyCutScore`, `PipelineTuner`, the Pipeline tab (`RallyLabModel`) | decoded the sidecar as `[LabeledRally]` (start/end only) | every missed serve and "not a rally" mark was a truth rally in the export and in every score; the scoring contract (D-021) lists this as known defect 4 |
| `DeciderRetune` | read the kinds but kept every mark in the truth, counting missed serves on their own | same, with the count shown |
| `--export-training-data` | exported any video with a decodable sidecar | an unfinished pass exported with its unmarked time as not-rally time |

## 2. Marks on the server (2026-11-04)

| Kind | Marks | Recordings | On complete passes |
|---|---|---|---|
| rally | 649 | 41 | — |
| missedServe | 51 | 20 | 49 (19 recordings) |
| other ("Not a rally") | 2 | 2 | 2 (2 recordings) |

## 3. Track decisions

Machine (pre-tracked) rallies on the server, not deleted: 232 confirmed (`is_rally = true`), 12 turned down, 137 not looked at — all Scratch.

**3.1 Confirmed by a non-rally close (the `confirmPretracked` defect).** A track would carry the defect if it lay mostly (more than half) inside a `missedServe` or `other` mark. **None does.** Four confirmed tracks touch a missed-serve mark at all; three of them lie mostly inside a neighbouring rally mark (confirmed by it, correctly); the fourth (`grs_ele_dusk_port_self_03_v2`, track `845a2677…`, 240.1–245.7 s, 9 % inside the missed serve at 245.2–247.7) lies inside no mark and was confirmed before the marks were made (track updated 2026-10-16, marks 2026-10-18) — see 3.3.

**3.2 Left unrefuted by the finish sweep.** On every recording whose pass is complete, **no machine track is still unchecked** (`is_rally` null): the sweep ran on all of them. No unchecked track lies mostly inside a non-rally mark.

**3.3 Confirmed tracks that no rally mark covers (pre-existing, not the defect).** Six confirmed machine tracks on complete passes lie mostly outside every rally mark. All six were confirmed (2026-10-14 to 10-16) before the live pass marked the recording (2026-10-18 or later), most by a review verdict or an earlier, longer mark; the pass never re-judged a track already confirmed, and the amendment does not change that (the sweep still refutes only unchecked tracks).

| Recording | Track | Span (s) | Most inside a rally mark | Marks nearby |
|---|---|---|---|---|
| bch_ele_ovc_land_self_02 | 79406a7d… | 266.5–271.5 | none | rally 245.4–261.8 |
| bch_ele_sun_land_self_01 | 12363fc7… | 161.5–174.6 | 4.8 s | rally 160.8–166.3 |
| grs_ele_dusk_port_self_03_v2 | 845a2677… | 240.1–245.7 | none | missedServe 233.3–235.3, rally 236.9–238.4, missedServe 245.2–247.7 |
| grs_ele_sun_land_self_01 | 87c25f44… | 171.9–181.2 | 4.5 s | rally 171.9–176.4 |
| ind_gnd_bright_land_self_01_v4 | 82dbd265… | 153.9–162.1 | 3.8 s | rally 151.8–157.7, missedServe 161.9–164.7 |
| ind_onl_bright_land_onl_01_v2 | 747bff0f… | 113.0–121.2 | 3.3 s | rally 113.6–116.9 |

**3.4 Found rallies and the Mac's `notRallies`.** Rejected found rallies live on each device (the Mac session's `notRallies`, the phone's local store), not on the server; the Mac's Scratch sessions were not read (the owner's project is off limits to this session). A found rally under a missed serve that the old sweep kept open is the one class this audit cannot count from the server.

## 4. Scores and experiments on record

| Record | Marks read | Effect | Standing |
|---|---|---|---|
| [EXP-20261031-l2-decider-retune](experiments/EXP-20261031-l2-decider-retune.md) (L1 vs L2 committed vs L2 chosen; D-029's basis) | 449 truth rallies, **36 of them missed-serve marks** (the record says so: 8 / 7 / 7 of them "missed") | every class count, dead time per rally, the objective and the per-recording table include the missed serves as rallies | **superseded** for the exact numbers; the direction of the comparison (preserved, merged, false clips) is not re-derived here. Recomputation = re-running the search on the cached passes with `RallyTruth`; needs owner authorisation (nothing re-run under the amendment) |
| L1 / L2 diagnostic of 2026-10-31 (`~/Movies/RallyLab/Reports/l1l2-diag-20261031`, README table: found / missed / false / merged per recording) | `RallyCutScore` over the same 26 recordings | the same 36 missed serves counted as rallies to find | **superseded**; same recomputation |
| EXP-20261101-l2-decider-retune-r2 (PR #127, unmerged) | as above | as above | superseded when merged; the record should say so |
| D-029 (the L2 tradeoff accepted temporarily) | rests on the two above | the tradeoff was judged on scores that counted missed serves | the decision stands as the owner's; its evidence is flagged, not withdrawn |
| EXP-20261011-tune-pipeline-r1 (2026-10-11/12) | marks from before live tagging: no kinds | unaffected | stands |
| EXP-20260705-rally-classifier-lr (IMG_2806, July) | no kinds | unaffected | stands |
| `scripts/rally_classifier_weights.json` (from the July run) | no kinds | unaffected | stands |
| Every `*.trainingdata.json` export written before this PR (schema 1) | start/end pairs | missed serves inside `labels` | **refused by the trainer** from this PR on; re-export after merge |
| Scoring contract fixtures (`BumpSetCutTests/Fixtures/Scoring`, `scripts/scoring/reference_scorecard.py`) | kinds read as the contract says | unaffected (the contract's reference implementation already masks missed serves) | stands |

## 5. Proposed repair procedure (not applied)

1. **Track decisions.** No track needs repair for the defect (3.1, 3.2). The six confirmations of 3.3 are a separate, pre-existing question: list them in RallyLab's review queue for the owner to confirm or turn down by eye; never rewrite them from the marks.
2. **Found rallies under missed serves (3.4).** After merge, opening a complete recording in the pass and pressing "That's every rally" again drops them (the sweep now judges by rallies only); no stored mark changes. Alternatively a headless `--resweep` that applies only the found-rally rule could be written — a new command, owner's call.
3. **Scores.** Re-run `--retune-decider` on the cached passes of EXP-20261031 (plan unchanged) and the L1/L2 diagnostic (`--score-rallies`) with the amended readers; file the result as a new experiment record that supersedes the numbers of the two above; the records themselves are not edited. Requires the owner's authorisation (D-002 exposure rows will be written again) and the Scratch footage online.
4. **Exports.** Re-run `--export-training-data` on the complete recordings; the trainer refuses schema-1 files until then.

## 6. Queries

```sql
-- marks by kind
select coalesce(r->>'kind','rally') kind, count(*), count(distinct t.video_id)
from label_rally_times t, jsonb_array_elements(t.rallies) r group by 1;
-- machine tracks mostly inside a non-rally mark (3.1): none
with marks as (select t.video_id, (r->>'start')::float8 s, (r->>'end')::float8 e, coalesce(r->>'kind','rally') kind
               from label_rally_times t, jsonb_array_elements(t.rallies) r)
select k.id from label_tracks k join marks m on m.video_id = k.video_id
where k.machine and not k.deleted and m.kind in ('missedServe','other')
  and least(k."end", m.e) - greatest(k.start, m.s) > 0.5 * (k."end" - k.start);
-- coverage of confirmed tracks on complete passes (3.2, 3.3): most-inside-a-rally-mark vs half the track
```
