-- ============================================================
-- Security: SECURITY DEFINER function hardening
--
-- 1) Pin search_path on the two definer functions still missing it
--    (linter 0011_function_search_path_mutable). A mutable search_path
--    on a SECURITY DEFINER function is a privilege-escalation vector.
-- 2) Revoke EXECUTE from anon/authenticated/PUBLIC on the trigger
--    functions — they fire under the table owner via triggers and must
--    not be callable directly via the REST RPC endpoint
--    (linter 0017_security_definer_function). Triggers continue to fire
--    regardless of EXECUTE grants.
-- 3) record_flywheel_flag IS a real RPC the app calls, but only when
--    authenticated — drop anon's ability to call it.
--
-- get_blocked_user_ids / is_user_blocked are intentionally left callable:
-- they're harmless read helpers and may be consumed by the web app.
-- ============================================================

-- 1) search_path
alter function public.on_poll_vote_change() set search_path = public;
alter function public.update_comment_likes_count() set search_path = public;

-- 2) Trigger functions: not meant to be invoked directly.
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.on_poll_vote_change() from public, anon, authenticated;
revoke execute on function public.update_comment_likes_count() from public, anon, authenticated;
revoke execute on function public.update_comments_count() from public, anon, authenticated;
revoke execute on function public.update_follow_counts() from public, anon, authenticated;
revoke execute on function public.update_highlights_count() from public, anon, authenticated;
revoke execute on function public.update_likes_count() from public, anon, authenticated;

-- 3) Flywheel RPC: authenticated-only. (anon had an explicit grant from an
--    earlier migration, so revoke from anon directly, not just PUBLIC.)
revoke execute on function public.record_flywheel_flag(
    uuid, integer, text, text, text[], jsonb, double precision, double precision,
    text, text, text, text, jsonb
) from public, anon;
grant execute on function public.record_flywheel_flag(
    uuid, integer, text, text, text[], jsonb, double precision, double precision,
    text, text, text, text, jsonb
) to authenticated;
