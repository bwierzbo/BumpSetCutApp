---
title: Migration 049 — restrict protected footage — deployment, verification and residual risk
status: APPLIED to the live project 2026-10-27T06:39:52Z and verified (§6)
created: 2026-10-27T00:10:00Z
updated: 2026-10-27T06:42:55Z
pr: fix/protect-withheld-footage
decision: owner decision of 2026-10-26 (docs/decisions/2026-10-26-stage1-integration-approvals.md §5); corrections requested 2026-10-27 (docs/decisions/2026-10-27-next-owner-decisions.md §2); merge and deployment authorised 2026-10-27 (docs/decisions/2026-10-27-final-security-testflight-decisions.md §2–3); D-002, D-017, D-018
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
| Storage: rename, move | any name in the bucket | the destination name must be readable too, so an object cannot be renamed or moved onto a protected or unreferenced name |
| Storage: ball-path sidecar (`<clip>.ballpath.json`) | every object | follows its clip |
| `label_videos`: creating rows and changing identities | anything | an ordinary labeler may create only a phone upload's own row (no project, recording or identities; a `phone/` object nobody else claims) and may never change a row's project, recording, copy path or identities (048's trigger `label_videos_guard`, live since 2026-10-27); no labeler-made row can point at a RallyLab copy or the unreferenced object |
| Storage: upload | allowed | unchanged; the uploader can read back its own new `phone/` object until the clip's row is saved (below) |

Signed URLs: the storage API checks the caller's SELECT access on the object before it signs. Supabase's documentation shows that signed URLs serve private buckets and that object access is governed by `storage.objects` policies, but it gives no per-operation table. After deployment this is checked live (§4 step 4).

- **A phone upload before its row exists.** The phone uploads a new clip first and saves its `label_videos` row afterwards. The storage API authorises an upload by writing the object and reading it back (`INSERT … ON CONFLICT DO UPDATE … RETURNING`, Supabase storage `src/storage/database/pg.ts`), which needs read access to the fresh object. An ordinary labeler may therefore also read an object that is under `phone/`, records the labeler as its `owner_id` (the storage API sets it to the caller's id), and that no row references yet. Once a row claims the path, the referencing rule alone decides, so a phone upload a lead later files under a protected recording is restricted like any other copy. Another labeler's unclaimed upload, an upload claiming someone else's id and any path outside `phone/` stay unreadable.
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
- **Writes:** cannot update, delete or recreate a protected row, track, copy or the unreferenced object. Cannot forge a reference: a new row pointing at a protected copy or the unreferenced object, a second claim on a phone upload, a row with a project, or rewriting a row's copy path, project or identities are all refused. Can still edit an eligible row's status, add its own phone upload's row and upload from the phone. A protected clip's sidecar is refused and an eligible clip's is readable.
- **Phone uploads:** a fresh upload passes the storage API's upsert check, and so does a retry that replaces it. The phone then saves the clip's row and the clip stays readable through it. An upload claiming another labeler's id, an unreferenced path outside `phone/`, and another labeler's unclaimed upload are all refused. Run against the previous head of this migration, the fresh-upload check fails, which is the defect the review found.
- **Renames and moves:** an object cannot be renamed onto a protected copy's name or sidecar, onto an unreferenced name, or into another bucket. Replacing a readable object under its own name, as the phone's upsert upload does, still works. Postgres already checks the new row against the read policy when the update's `WHERE` reads a column, which the storage API's move does. The update policy's own check closes the case of an update that reads no column. Two tests cover that case, and both fail on the earlier version of this migration.
- **Later withholding:** a recording withheld later is hidden at once, together with its copy.

For other callers:
- A lead reads every row and object, and may still rename an object.
- A non-labeler reads nothing.
- `anon` cannot call the helpers.

Finally, every object and row is preserved.

The stand-in `label_videos` carries the live `label_videos_status_check` constraint (`rallylab`, `uploaded`, `imported`, read from `pg_constraint` on 2026-10-27), so no test can pass on a status the live table refuses. The status changes in the 048 and 049 tests use `imported`.

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
   - A phone upload by an ordinary labeler still succeeds. This needs a non-lead labeler's token and a small test file under `phone/`, removed afterwards, and therefore the owner's go at that point; until then the local upsert test above is the evidence.
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

## 6. Deployment record (2026-10-27)

Authorised by the owner on 2026-10-27 ([verbatim](../decisions/2026-10-27-final-security-testflight-decisions.md), §2–3). PR #104 was merged at its reviewed head `7abcbe4` (no unresolved review threads, checks green) as `91cca0b`.

**Before deployment**
- 048 present in the live migration list (`20261027032411`). The Scratch withheld list is published with 21 names and 21 rows.
- The migration file on `main` is byte-identical to the reviewed head (sha256 `ea52cfdb…7f`).
- The policies it replaces were read from `pg_policies` and match §5's rollback exactly.
- Preservation snapshot, taken as the owner (no RLS):

| Item | Count | Digest |
|---|---|---|
| `labeling` objects (name, eTag, size) | 124 | `90d85846…` |
| `label_videos` (id, copy path, identities) | 123 | `9ebc87b7…` |
| `label_tracks` (id, points) | 282 | `19a64fea…` |
| `label_rally_times` | 33 | — |
| `label_frame_log` | 25,811 | — |
| `label_rally_events` | 0 | — |

**Deployment:** `apply_migration` named `049_protect_withheld_footage` with the file's exact contents, recorded as version `20261027063952` (2026-10-27T06:39:52Z, 00:39 MDT).

**After deployment**
- The four helper functions' bodies have the same MD5 as the reviewed file. One `label_object_readable(text, text)` exists. `anon` cannot execute any of them. The new policies are present.
- Advisors (security and performance): no new finding from 049. The findings are the same as after 048: the long-standing signed-in SECURITY DEFINER warnings, the two RLS-without-policy notes, leaked-password protection off, three INFO foreign-key-index notes on 048's audit columns, and unused-index notes.
- Access, simulated in SQL for each labeler (reads only):

| Caller | Recordings | Objects | Unreferenced object | Rally times | Tracks |
|---|---|---|---|---|---|
| Expected for an ordinary labeler | 101 eligible (22 protected) | 101 eligible (23 restricted) | hidden | 30 (3 protected) | 266 (16 protected) |
| Each of the three ordinary labelers | 101, none withheld | 101 | 0 | 30 | 266 |
| Lead | 123 | 124 | 1 | 33 | 282 |

- Through the real APIs, as a temporary non-lead labeler (the disposable test account, added to `labelers` for the test and removed afterwards), 17 of 17 checks passed:
  - **Protected material:** a protected copy, its ball-path sidecar and the unreferenced object were each refused, both for signing and for a direct read (HTTP 400).
  - **Listing and rows:** the bucket listing and the REST `label_videos` read showed 101 entries and no protected or unreferenced one.
  - **Eligible material:** an eligible copy was signed (200) and read (one byte, 206).
  - **Controlled upload:** a 1-second synthetic test pattern (6,053 bytes) was uploaded to the phone's path with upsert, before its row (200), and the retry succeeded (200). The phone row was saved (201) and the upload signed through it (200). Moving it onto a protected name was refused (400). Then only that row and that object were deleted (200, 200), and both were confirmed gone.
- **Preservation:** after the tests, every count and digest in the snapshot above is unchanged, and `labelers` is back to its four rows.

**Residual risk**
- Signed URLs issued before 06:39:52Z stay valid until they expire. The apps request at most 6 hours, so the last one expires by 12:39:52Z on 2026-10-27 (06:39 MDT). They cannot be revoked without rotating the storage signing key (§3).
- Copies already on labelers' phones are pruned when each app next reloads. A device that never reopens the app keeps its copy.
- Anything copied off a device or a signed URL before deployment is beyond control. The inventory (`docs/ml-roadmap/PROTECTED_FOOTAGE_INVENTORY_2026-10-26.md`) records which recordings and dates were exposed.
- The lead's real RallyLab sync was not exercised by these checks. The lead's access was verified in SQL; the next sync from the owner's Mac exercises it for real.

