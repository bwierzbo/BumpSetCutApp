-- 016_security_audit_hardening.sql
-- Fixes from the deep security audit (2026-07). Idempotent: safe to re-run.
--
-- Covers:
--   1. Enforce profiles.privacy_level for highlight visibility (was UI-only theater).
--   2. Stop anon from enumerating the block graph via SECURITY DEFINER RPCs.
--   3. Reconcile drift: pin search_path on all SECURITY DEFINER functions,
--      re-declare profiles_insert (live but never committed).
--   4. Folder-scope the videos bucket INSERT policy (parity with training-data/avatars).
--   5. Make content reporting functional: default reporter_id to auth.uid().
--
-- NOTE: test_sections/test_subsections/test_items intentionally NOT locked here —
-- the public test dashboard writes with the anon key and no session, so restricting
-- them would break inline editing. Tracked separately.

-- ---------------------------------------------------------------------------
-- 1. Privacy enforcement on highlights
-- ---------------------------------------------------------------------------
-- A highlight is visible when its author is public, the viewer is the author,
-- or the author is followers_only AND the viewer follows them. 'private' authors
-- expose highlights only to themselves. Anonymous viewers (auth.uid() IS NULL)
-- see only public authors' highlights.
-- Profiles themselves stay discoverable (username/avatar) so search & follow work;
-- the privacy gate is on content (highlights), which is the actual promise.

drop policy if exists highlights_select on public.highlights;
create policy highlights_select on public.highlights
  for select
  using (
    exists (
      select 1 from public.profiles p
      where p.id = highlights.author_id
        and (
          p.privacy_level = 'public'
          or p.id = (select auth.uid())::text
          or (
            p.privacy_level = 'followers_only'
            and exists (
              select 1 from public.follows f
              where f.follower_id = (select auth.uid())::text
                and f.following_id = p.id
            )
          )
        )
    )
  );

-- ---------------------------------------------------------------------------
-- 2. Block-graph RPCs: revoke anon, scope to the caller
-- ---------------------------------------------------------------------------
-- get_blocked_user_ids now ignores its argument and returns ONLY the caller's
-- blocks (a caller has no business reading anyone else's block list). Signature
-- is preserved for client/webapp compatibility.
create or replace function public.get_blocked_user_ids(p_user_id text)
  returns table(blocked_id text)
  language plpgsql
  security definer
  set search_path to 'public'
as $function$
begin
  return query
  select ub.blocked_id
  from user_blocks ub
  where ub.blocker_id = (select auth.uid())::text;
end;
$function$;

-- is_user_blocked stays pair-based (needed for directional checks) but is no
-- longer callable anonymously.
create or replace function public.is_user_blocked(blocker text, blocked text)
  returns boolean
  language plpgsql
  security definer
  set search_path to 'public'
as $function$
begin
  return exists (
    select 1 from user_blocks
    where blocker_id = blocker and blocked_id = blocked
  );
end;
$function$;

-- Revoke from PUBLIC (not just anon) — EXECUTE was granted to PUBLIC, which
-- encompasses anon, so revoking anon alone is a no-op.
revoke execute on function public.get_blocked_user_ids(text) from public;
revoke execute on function public.is_user_blocked(text, text) from public;
grant execute on function public.get_blocked_user_ids(text) to authenticated;
grant execute on function public.is_user_blocked(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Drift reconciliation
-- ---------------------------------------------------------------------------
-- 3a. Pin search_path on every SECURITY DEFINER function (already set live;
--     captured here so a clean rebuild from migrations matches production).
alter function public.handle_new_user() set search_path = public, auth;
alter function public.update_likes_count() set search_path = public;
alter function public.update_comments_count() set search_path = public;
alter function public.update_follow_counts() set search_path = public;
alter function public.update_highlights_count() set search_path = public;
alter function public.update_updated_at_column() set search_path = public;

-- 3b. profiles_insert exists live but was never in a committed migration; a rebuild
--     from source would leave signups unable to create their profile row.
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles
  for insert
  with check ((select auth.uid())::text = id);

-- ---------------------------------------------------------------------------
-- 4. videos bucket: folder-scope INSERT (prevents writing under another user's prefix)
-- ---------------------------------------------------------------------------
drop policy if exists videos_insert on storage.objects;
create policy videos_insert on storage.objects
  for insert
  with check (
    bucket_id = 'videos'
    and auth.role() = 'authenticated'
    and (select auth.uid())::text = (storage.foldername(name))[1]
  );

-- ---------------------------------------------------------------------------
-- 5. content_reports: default reporter_id so inserts succeed under RLS
-- ---------------------------------------------------------------------------
alter table public.content_reports
  alter column reporter_id set default (auth.uid())::text;
