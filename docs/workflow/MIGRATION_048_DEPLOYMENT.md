---
title: Migration 048 — Stage 1 boundary-record sync — deployment, verification and rollback
status: prepared for the owner's approval; NOT applied
created: 2026-10-26T22:10:00Z
updated: 2026-10-26T22:10:00Z
pr: feat/stage1-events-sync (#100)
decision: D-024; owner direction of 2026-10-26 (docs/decisions/2026-10-26-stage1-testflight-direction.md)
---

# Migration 048 — deployment, verification and rollback

`supabase/migrations/048_label_rally_events.sql` adds the server side of the Mac ↔ iPhone Stage 1 sync. It is **not applied**. Applying it needs the owner's explicit approval (owner direction, 2026-10-26 §7).

## 1. What it adds

| Object | Kind | Purpose |
|---|---|---|
| `public.label_withheld (project, session_name, listed_by, listed_at)` | table, RLS on | The project's withheld closure as RallyLab computes it (lineage holdout, legacy holdout, final test, candidates, metadata aliases, and sessions refused by path or content). |
| `public.label_withheld_lists (project, names, listed_by, listed_at)` | table, RLS on | Which projects have a published list. A project without one is unknown, so nothing of it is accepted or readable. |
| `public.label_rally_events (video_id, project, session_name, annotation_version, record jsonb, revision, updated_by, updated_at)` | table, RLS on | One versioned Stage 1 record per recording (`rally_event_truth_v1`, camelCase keys as the apps write it). |
| `label_videos.frame_times_digest`, `label_videos.source_fingerprint` | nullable columns | The original's frame identity and content fingerprint, published by the Mac with each copy. |
| `label_videos_guard` (trigger + `private.label_videos_guard`) | BEFORE INSERT/UPDATE trigger on `label_videos` | 028's labeler policy lets any labeler write `label_videos`. The guard limits a non-lead to adding a phone upload's own row (no project, recording or identities; a `phone/` object no other row claims) and forbids changing a row's project, recording, copy path, fingerprint or digest. Only the lead's publication sets the identities every save and read is judged by. |
| `public.label_withheld_publish(p_project, p_names)` | SECURITY DEFINER function | Replaces a project's withheld list whole. **Leads only** (`private.is_lead()`). |
| `public.rally_events_save(p_video, p_expected, p_record)` | SECURITY DEFINER function | The only write path for records (rules in §2). |
| `label_rally_events_live`, `label_withheld_live` | statement triggers | The existing labeling broadcast (045): table name and user id only, no row data. |

**Privileges.** `anon` has no table privilege on the three tables and cannot execute either function. `authenticated` may execute both functions, and each checks the caller's role itself. No INSERT, UPDATE or DELETE policy exists on any of the three tables, so direct writes are refused for everyone, leads included.

**Read policies (RLS).**
- `label_withheld`, `label_withheld_lists`: labelers may read them. These are names only; the clients need them to refuse locally as well.
- `label_rally_events`: a labeler may read a row only while its project has a published list and the recording is not on it. This is evaluated at read time. A recording or alias added to the list later disappears from every read immediately, for leads as well. Rows are never deleted by this.

## 2. Server rules on save (`rally_events_save`)

| Condition | Result |
|---|---|
| Caller is not a labeler | `42501` `rally_events_save: labelers only` |
| Unknown recording, or no project/session | `22023` |
| Project has no published list | `42501` `withheld: … no published withheld list` |
| Recording is on the list | `42501` `withheld: … is a withheld recording` |
| `annotationVersion` is not `rally_event_truth_v1` | `22023` |
| Record names another recording | `22023` `the record names …` |
| The recording has no published original fingerprint | `22023` `identity: … no published original fingerprint` (fails closed) |
| The record has no `sourceFingerprint`, or names other footage | `22023` `identity: the record describes footage …` |
| The record's `frameTimesDigest` differs from the published one, when both exist | `22023` `identity: … frame digest …` |
| `p_expected` is not the current revision | `P0001` `conflict: …` (the client keeps both versions and asks the person) |
| Otherwise | inserts at revision 1, or updates to revision + 1, writing the revision inside the record too, under a row lock |

**Older records.** No server rows exist before this migration, so there is no data migration. On the Mac, an older `rallyevents.json` without a `sourceFingerprint` gets the footage's fingerprint the next time it is opened in the Review tab. That happens after the name check and is written with the next commit; an existing fingerprint is never replaced. Until then the sync reports such a record as "not sent" and leaves it untouched.

## 3. Tests run (no live project touched)

`supabase/tests/run_048_tests.sh` creates a throwaway local PostgreSQL 14 cluster. It loads stand-ins for Supabase's `auth.uid()`, roles, default privileges, `realtime.send`, `public.labelers` and the 028/039/045 helper functions, applies 048, and runs `supabase/tests/048_tests.sql` as the API roles. Result on the corrected migration:

```
ALL 048 TESTS PASSED
```

The same tests run against the previous revision of 048 fail at the first identity check, which shows they detect the gaps that were fixed.

What the tests cover:
- Only a lead can publish.
- First save gives revision 1, and the revision is also written inside the record.
- A stale revision is a conflict, and a stale "new" record is also a conflict.
- Every identity refusal: missing fingerprint, other footage, other frames, no published original, wrong record name.
- Withheld recordings and unlisted projects are refused.
- A non-labeler is refused and reads nothing.
- Direct INSERT, UPDATE and DELETE are refused or have no effect on all three tables.
- `anon` has no SELECT and no EXECUTE.
- Protected reads: a record saved while eligible becomes unreadable by id and by name once its recording (or an alias) is listed, for the lead as well. With no published list nothing is readable, and the rows are preserved.

## 4. Deployment checklist (owner)

Steps 1–3 happen after approval. None of them change any existing table except adding two nullable columns to `label_videos`.

1. **Lead role.** None needed. The owner's labeler account is already the only lead (`public.labelers.lead = true`, 1 lead of 4 labelers, checked 2026-10-26). The Mac must be signed in with that account to publish the withheld list. No other account needs the flag, and granting it to anyone else would let them replace the list.
2. **Apply.** Use `apply_migration` with the file's exact contents, named `048_label_rally_events`. Do not use `execute_sql` piecemeal.
3. **Advisors.** Run `get_advisors` for security and performance. Expected: no new security finding. The `SECURITY DEFINER` functions use `search_path = ''`. Re-check that `anon` has no EXECUTE on both functions:
   ```sql
   SELECT has_function_privilege('anon', 'public.rally_events_save(uuid, integer, jsonb)', 'EXECUTE'),
          has_function_privilege('anon', 'public.label_withheld_publish(text, text[])', 'EXECUTE');  -- both false
   ```
4. **Publish the list and the identities:** `RallyLab --project Scratch --publish-identities` (RallyLab built from merged `main`, signed in as the lead). It publishes the Scratch withheld list, which should contain the 21 names RallyLab computes today. It also fills `source_fingerprint` and `frame_times_digest` for every non-withheld recording that already has a row. It **uploads nothing**; a normal `--sync-phone` would also upload copies for recordings without one, which is a bulk upload that is not authorised. Then verify:
   ```sql
   SELECT names FROM public.label_withheld_lists WHERE project = 'Scratch';                       -- 21
   SELECT count(*) FILTER (WHERE source_fingerprint IS NULL) AS no_fp, count(*) FILTER (WHERE frame_times_digest IS NULL) AS no_digest
     FROM public.label_videos WHERE project = 'Scratch'
      AND session_name NOT IN (SELECT session_name FROM public.label_withheld WHERE project = 'Scratch');  -- 0, 0
   ```
5. **Direct-read check as a labeler.** Use a non-lead labeler session, or the phone through the app. A record cannot be read for any name in `label_withheld`. RLS evaluation is covered by the local tests; on live, confirm with the phone that a withheld recording shows "not reviewable" and that no record row for it is returned.
6. **End-to-end checks** (owner direction §8): Mac ↔ iPhone sync, offline save then sync, a concurrent-edit conflict, refusals for protected recordings on both platforms and through direct reads, the frame-identity gate on downloaded copies, and isolation of the legacy annotation and the L2 dataset (`rallylabels.json`, L2 package and split manifest unchanged by hash).

## 5. Rollback and recovery (annotations preserved)

The authoritative Stage 1 records are the Mac's `<video>.rallyevents.json` sidecars. The server holds the synchronised copy plus any edit made on the phone and not yet pulled.

- **Stop accepting writes without losing anything:**
  ```sql
  REVOKE EXECUTE ON FUNCTION public.rally_events_save(uuid, integer, jsonb) FROM authenticated;
  ```
  Reads stay governed by RLS. Re-grant to resume.
- **Before removing anything:** run one Mac sync, which pulls every server record that passes the identity check into its sidecar. Then export the table as the owner:
  ```sql
  SELECT jsonb_agg(to_jsonb(r)) FROM public.label_rally_events r;
  ```
  Keep the result with the project's manifests.
- **Full rollback** (only after the export):
  ```sql
  DROP TABLE public.label_rally_events;
  DROP FUNCTION public.rally_events_save(uuid, integer, jsonb);
  DROP FUNCTION public.label_withheld_publish(text, text[]);
  DROP TABLE public.label_withheld;
  DROP TABLE public.label_withheld_lists;
  ```
  The two `label_videos` columns are harmless to keep; dropping them loses only re-computable identities. Existing tables and the legacy `label_rally_times` are untouched in either direction.

## 6. Not covered by this migration (separate owner decisions)

The protected-footage inventory of 2026-10-26 found existing **copies of withheld recordings** in the private `labeling` bucket, together with their `label_videos` rows. They remain readable by every labeler through the existing `labeling_select` storage policy and the `label_videos_labelers` policy. Migration 048 protects rally-event content only. Restricting those reads, or removing the copies, is a permission or data change that needs the owner's approval. Proposed options are in the inventory report linked from PR #100.
