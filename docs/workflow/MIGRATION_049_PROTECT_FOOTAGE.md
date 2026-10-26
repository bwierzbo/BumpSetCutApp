---
title: Migration 049 — restrict protected footage — deployment, verification and residual risk
status: prepared for the owner's deployment approval; NOT applied
created: 2026-10-27T00:10:00Z
updated: 2026-10-27T00:10:00Z
pr: fix/protect-withheld-footage
decision: owner decision of 2026-10-26 (docs/decisions/2026-10-26-stage1-integration-approvals.md §5); D-002, D-017, D-018
---

# Migration 049: restrict protected footage

`supabase/migrations/049_protect_withheld_footage.sql` carries out the owner's decision on the protected-footage findings (`docs/ml-roadmap/PROTECTED_FOOTAGE_INVENTORY_2026-10-26.md`): **restrict access, delete nothing.** It is not applied. Deploying it needs the owner's separate approval. It depends on 048, because the withheld list it reads is 048's. The pilot migration in PR #102 moves to 050.

## 1. What changes

**Protected recording.** A recording that belongs to a project (RallyLab's recordings) is protected when either:
- its project has no published withheld list (an unknown list counts as protected), or
- the list names it. The list includes aliases by name, path and content.

The check runs at access time, so a recording withheld later is protected at once. Phone-only uploads have no project and are never protected by this rule.

**Ordinary labelers** (every labeler who is not a lead):

| Path | Before | After |
|---|---|---|
| `label_videos` (rows, `clip_path`) | every row, any command | protected rows cannot be read, created, changed or deleted |
| `label_rally_times`, `label_tracks` | every row | only rows of a readable recording, for every command |
| `label_frame_log` | own rows | own rows on a readable recording's tracks |
| Storage, bucket `labeling`: read, list, download | every object | only objects referenced by a readable `label_videos` row |
| Storage: create a signed URL | every object | same as read |
| Storage: replace, delete | every object | same as read |
| Storage: upload | allowed | unchanged |

Signed URLs: the storage API checks the caller's SELECT access on the object before it signs. Supabase's documentation shows that signed URLs serve private buckets and that object access is governed by `storage.objects` policies, but it gives no per-operation table. After deployment this is checked live (§4 step 4).

- **The unreferenced object** `rallylab/Scratch/ind_gnd_dim_land_self_02_v2-v2.mp4` is referenced by no row, so no ordinary labeler can read, sign, change or delete it until its identity is established.
- **Leads are unaffected.** The lead publishes the list and runs RallyLab's sync. The owner is the only lead.
- **Lead-only paths are unaffected.** The SECURITY DEFINER functions over these tables are either lead-only (`labeler_frames`, `labeler_summary`, `rally_finals`, `label_verdicts`) or return counts only (`rallycoin_board`). `label_rally_finals` has RLS with no policies, so the API cannot read it.
- **Nothing is deleted or moved.** Every object, row, hash, historical annotation and exposure record stays exactly as it is.

## 2. Tests (local cluster; the live project is untouched)

`supabase/tests/run_048_tests.sh` gives each migration a fresh database with stand-ins whose prior policies equal the live ones (read from `pg_policies` on 2026-10-26). It then applies 048 and this migration and runs `supabase/tests/049_protect_tests.sql`:

```
ALL 048 TESTS PASSED
ALL 049 PROTECT TESTS PASSED
```

Run without the fix, the same tests fail at the first check: an ordinary labeler can read the withheld recordings. They therefore detect the live exposure.

**What the tests cover**, for an ordinary labeler:
- **Reads:** sees only the eligible recording and the phone upload. The withheld recording, its alias and the unlisted project's recording are hidden. The copies of protected recordings and the unreferenced object cannot be listed or read by name, so they cannot be signed. Rally times, tracks and the labeler's own frame log on protected recordings are hidden.
- **Writes:** cannot update, delete or recreate a protected row, track, copy or the unreferenced object. Can still edit an eligible row and still upload from the phone.
- **Later withholding:** a recording withheld later is hidden at once, together with its copy.

For other callers:
- A lead reads every row and object.
- A non-labeler reads nothing.
- `anon` cannot call the helpers.

Finally, every object and row is preserved.

## 3. Residual exposure (documented, not fixable by access control)

1. **Signed URLs issued before deployment** stay valid until they expire. The apps request 6 hours (playback) or 1 hour (download). Supabase cannot revoke a signed URL that has been issued without rotating the project's storage signing key, which would invalidate every link. Exposure therefore ends at most 6 hours after deployment. Storage logs keep only 24 hours, so issuance before 2026-10-26 cannot be checked.
2. **Copies already downloaded to labelers' phones** remain on those devices until the app reloads. On reload, `LabelerModel.reload` calls `LocalStore.pruneClips(keeping:)` with the rows the labeler can still read, which deletes local copies of every protected recording. A device that never reopens the app keeps its copy, and nothing on the server can reach it.
3. **Anything copied off a device or out of a signed URL** before deployment is outside the system's control. The inventory records which recordings and dates are affected.
4. **Projects without a published list** become invisible to ordinary labelers until the lead publishes one (today: the archived Test1). This is intended, because an unknown list fails closed.

## 4. Deployment checklist (after the owner's approval)

1. Confirm that 048 is applied and that the Scratch list is published: `SELECT names FROM public.label_withheld_lists WHERE project = 'Scratch'` returns 21.
2. Apply with `apply_migration` using the file's exact contents, named `049_protect_withheld_footage`.
3. Run `get_advisors` for security and performance. Confirm `anon` cannot execute the four helpers and that the new policies exist:
   ```sql
   SELECT tablename, policyname, cmd FROM pg_policies
    WHERE (schemaname = 'public' AND tablename IN ('label_videos','label_rally_times','label_tracks','label_frame_log'))
       OR (schemaname = 'storage' AND policyname LIKE 'labeling_%') ORDER BY 1, 2;
   ```
4. Check as an ordinary labeler, then as the lead.
   - Simulate a non-lead labeler session in SQL (`SET LOCAL ROLE authenticated` plus the JWT subject of a non-lead labeler, inside a transaction that is rolled back) and confirm the reads in §2 against the live rows: no protected row, track, copy, or the unreferenced object.
   - Signing needs a non-lead labeler's token. A tester account can ask to sign the URL of a protected copy and must be refused.
   - The lead's RallyLab sync still lists and uploads normally.
5. The first phone reload after deployment prunes local protected copies.

## 5. Rollback (restores the previous access; deletes nothing)

```sql
DROP POLICY "label_videos_read" ON public.label_videos;
DROP POLICY "label_videos_insert" ON public.label_videos;
DROP POLICY "label_videos_update" ON public.label_videos;
DROP POLICY "label_videos_delete" ON public.label_videos;
CREATE POLICY "label_videos_labelers" ON public.label_videos FOR ALL TO authenticated
    USING ((SELECT private.is_labeler())) WITH CHECK ((SELECT private.is_labeler()));
DROP POLICY "label_rally_times_labelers" ON public.label_rally_times;
CREATE POLICY "label_rally_times_labelers" ON public.label_rally_times FOR ALL TO authenticated
    USING ((SELECT private.is_labeler())) WITH CHECK ((SELECT private.is_labeler()));
DROP POLICY "label_tracks_labelers" ON public.label_tracks;
CREATE POLICY "label_tracks_labelers" ON public.label_tracks FOR ALL TO authenticated
    USING ((SELECT private.is_labeler())) WITH CHECK ((SELECT private.is_labeler()));
DROP POLICY "label_frame_log_select" ON public.label_frame_log;
CREATE POLICY "label_frame_log_select" ON public.label_frame_log FOR SELECT TO authenticated
    USING ((labeler = (SELECT auth.uid())) OR (SELECT private.is_lead()));
DROP POLICY "labeling_select" ON storage.objects;
CREATE POLICY "labeling_select" ON storage.objects FOR SELECT TO authenticated USING ((bucket_id = 'labeling') AND (SELECT private.is_labeler()));
DROP POLICY "labeling_update" ON storage.objects;
CREATE POLICY "labeling_update" ON storage.objects FOR UPDATE TO authenticated
    USING ((bucket_id = 'labeling') AND (SELECT private.is_labeler())) WITH CHECK ((bucket_id = 'labeling') AND (SELECT private.is_labeler()));
DROP POLICY "labeling_delete" ON storage.objects;
CREATE POLICY "labeling_delete" ON storage.objects FOR DELETE TO authenticated USING ((bucket_id = 'labeling') AND (SELECT private.is_labeler()));
-- The helper functions can stay (unused) or be dropped.
```
