-- 027_security_advisor_hardening.sql
--
-- Clears the Supabase security advisor's actionable findings (2026-10-05).
-- Applied to the live project; this file is the committed record.

-- 1. Trigger functions are not API endpoints. Triggers fire regardless of
--    EXECUTE grants, so callers lose nothing; /rest/v1/rpc/… stops exposing
--    them.
REVOKE EXECUTE ON FUNCTION
    public.cleanup_empty_conversation(),
    public.denotify_on_comment_unlike(),
    public.denotify_on_unfollow(),
    public.denotify_on_unlike(),
    public.notify_on_comment(),
    public.notify_on_comment_like(),
    public.notify_on_follow(),
    public.notify_on_like(),
    public.push_on_message(),
    public.update_updated_at_column()
FROM public, anon, authenticated;

-- 2. Only called from other SECURITY DEFINER functions (which run as the
--    owner), never by clients.
REVOKE EXECUTE ON FUNCTION public.notification_allowed(text, text) FROM public, anon, authenticated;

-- 3. Unused by the app, webapp, edge functions, policies and views — and both
--    let any signed-in user ask about anyone else's blocks.
DROP FUNCTION IF EXISTS public.get_blocked_user_ids(text);
DROP FUNCTION IF EXISTS public.is_user_blocked(text, text);

-- 4. Helpers RLS needs as the signed-in user (a policy on
--    conversation_members, the security-invoker conversation_overview view)
--    move out of the API-exposed schema. Policies and views reference
--    functions by OID, so they keep working.
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM public, anon;
GRANT USAGE ON SCHEMA private TO authenticated;
ALTER FUNCTION public.is_conversation_member(text) SET SCHEMA private;
ALTER FUNCTION public.dm_allowed(text) SET SCHEMA private;
REVOKE EXECUTE ON FUNCTION private.is_conversation_member(text), private.dm_allowed(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION private.is_conversation_member(text), private.dm_allowed(text) TO authenticated;

-- 5. Nothing uses GraphQL (the app, webapp and edge functions all use REST/
--    RPC); without it, no table is discoverable through the GraphQL schema.
DROP EXTENSION IF EXISTS pg_graphql;

-- 6. The test dashboard's FOR ALL policies already allow reads; the separate
--    read policies only doubled the per-row policy work.
DROP POLICY IF EXISTS "Allow all reads on test_items" ON public.test_items;
DROP POLICY IF EXISTS "Allow all reads on test_sections" ON public.test_sections;
DROP POLICY IF EXISTS "Allow all reads on test_subsections" ON public.test_subsections;

-- 7. The lifetime-stats batch log is written only by add_user_stats
--    (SECURITY DEFINER); say so explicitly rather than leave RLS with no policy.
CREATE POLICY "user_stats_batches_no_client_access" ON public.user_stats_batches
    AS RESTRICTIVE FOR ALL TO authenticated USING (false) WITH CHECK (false);

-- Left as is (intentional): the client RPCs signed-in users call —
-- accept_conversation, add_user_stats, get_or_create_conversation,
-- leave_conversation, mark_conversation_read, pending_request_count,
-- record_flywheel_flag, register_device_token, send_message,
-- unread_message_count — are SECURITY DEFINER by design (each checks
-- auth.uid() itself); they are the API.
--
-- Also left: 18 "unused index" notices — mostly foreign-key indexes the
-- account-deletion cascades rely on, plus feed/inbox indexes; they read as
-- unused only because traffic is still low. Dashboard-only settings (not SQL):
-- leaked-password protection, Auth connection strategy.
