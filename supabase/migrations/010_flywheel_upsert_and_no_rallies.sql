-- ============================================================
-- BumpSetCut Data Flywheel — fix upsert RLS + add no_rallies trigger
--
-- Two fixes:
--  1. Frame uploads use upsert (x-upsert: true), so the storage server runs
--     INSERT ... ON CONFLICT DO UPDATE. Under RLS that needs an UPDATE policy on
--     storage.objects in addition to INSERT — migration 007 only created
--     INSERT/SELECT/DELETE, so every frame upload failed with
--     "new row violates row-level security policy". Add the UPDATE policy (and
--     re-assert the others idempotently in case 007's storage block didn't apply).
--  2. The new "no_rallies" trigger (whole-video upload when the detector finds no
--     rallies) isn't in the trigger_type CHECK constraint, so the RPC insert would
--     fail once storage works. Widen the constraint.
--
-- Run via Supabase Dashboard > SQL Editor (not shipped in app).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Storage policies for the private training-data bucket
-- ------------------------------------------------------------

drop policy if exists "training_data_insert" on storage.objects;
drop policy if exists "training_data_select" on storage.objects;
drop policy if exists "training_data_update" on storage.objects;
drop policy if exists "training_data_delete" on storage.objects;

-- Authenticated users may upload into their own {user_id}/... folder.
create policy "training_data_insert" on storage.objects for insert
    with check (
        bucket_id = 'training-data'
        and auth.role() = 'authenticated'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

-- Read only your own objects (bucket is private; ML service role reads out-of-band).
create policy "training_data_select" on storage.objects for select
    using (bucket_id = 'training-data' and auth.uid()::text = (storage.foldername(name))[1]);

-- Required for upsert uploads (INSERT ... ON CONFLICT DO UPDATE).
create policy "training_data_update" on storage.objects for update
    using (bucket_id = 'training-data' and auth.uid()::text = (storage.foldername(name))[1])
    with check (bucket_id = 'training-data' and auth.uid()::text = (storage.foldername(name))[1]);

-- Delete only your own objects.
create policy "training_data_delete" on storage.objects for delete
    using (bucket_id = 'training-data' and auth.uid()::text = (storage.foldername(name))[1]);

-- ------------------------------------------------------------
-- 2. Allow the new no_rallies trigger on contributions
-- ------------------------------------------------------------

alter table flywheel_contributions
    drop constraint if exists flywheel_contributions_trigger_type_check;

alter table flywheel_contributions
    add constraint flywheel_contributions_trigger_type_check
    check (trigger_type in ('low_score', 'user_removed', 'user_trimmed', 'reported', 'no_rallies'));
