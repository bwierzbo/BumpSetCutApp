-- 006_harden_profiles_update.sql
-- profiles_update had a USING clause but no WITH CHECK, so a user updating their
-- own row was not constrained on the resulting row (e.g. could attempt to change
-- id to another value). Add a matching WITH CHECK for defense-in-depth.
-- Applied to the live project on 2026-06-09.

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update
  using ((auth.uid())::text = id)
  with check ((auth.uid())::text = id);
