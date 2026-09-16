-- Notification trigger machinery is server-side only: nothing should call it
-- through the REST RPC surface. (Trigger functions error if invoked directly,
-- but notification_allowed() would leak whether two users block each other.)
-- Applied to the live project on 2026-09-15 via MCP apply_migration.
REVOKE EXECUTE ON FUNCTION public.notification_allowed(text, text) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_on_like() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.denotify_on_unlike() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_on_follow() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.denotify_on_unfollow() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_on_comment() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_on_comment_like() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.denotify_on_comment_unlike() FROM anon, authenticated;
