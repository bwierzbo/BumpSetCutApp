-- Write path + inbox read model for direct messages. Every RAISE EXCEPTION
-- leads with a stable DM_* token the client maps to a user-facing message.
-- Applied to the live project on 2026-09-17 via MCP apply_migration.

CREATE OR REPLACE FUNCTION public.get_or_create_conversation(p_other_user_id text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid text := (SELECT auth.uid())::text;
  key text; cid text; other_status text;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_other_user_id IS NULL OR p_other_user_id = uid THEN
    RAISE EXCEPTION 'DM_SELF: cannot message yourself';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_other_user_id) THEN
    RAISE EXCEPTION 'DM_UNKNOWN_USER: no such user';
  END IF;
  IF NOT notification_allowed(p_other_user_id, uid) THEN
    RAISE EXCEPTION 'DM_BLOCKED: cannot message this user';
  END IF;

  key := least(uid, p_other_user_id) || ':' || greatest(uid, p_other_user_id);
  -- Race-safe: concurrent callers both land on the same row.
  INSERT INTO conversations (pair_key) VALUES (key)
  ON CONFLICT (pair_key) DO UPDATE SET pair_key = EXCLUDED.pair_key
  RETURNING id INTO cid;

  -- Already following me? Straight to their inbox. Otherwise it's a request.
  other_status := CASE WHEN EXISTS (
      SELECT 1 FROM follows WHERE follower_id = p_other_user_id AND following_id = uid)
    THEN 'accepted' ELSE 'pending' END;

  INSERT INTO conversation_members (conversation_id, user_id, status)
  VALUES (cid, uid, 'accepted'), (cid, p_other_user_id, other_status)
  ON CONFLICT (conversation_id, user_id) DO NOTHING;
  RETURN cid;
END $$;

CREATE OR REPLACE FUNCTION public.send_message(
  p_conversation_id text,
  p_body text DEFAULT NULL,
  p_attachment_type text DEFAULT NULL,
  p_highlight_id text DEFAULT NULL,
  p_clip_path text DEFAULT NULL,
  p_clip_duration double precision DEFAULT NULL)
RETURNS public.messages LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid text := (SELECT auth.uid())::text;
  key text; a text; b text; other text;
  body text := nullif(btrim(p_body), '');
  preview text; result public.messages;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT pair_key INTO key FROM conversations WHERE id = p_conversation_id;
  IF key IS NULL THEN RAISE EXCEPTION 'DM_NOT_FOUND: conversation not found'; END IF;
  IF NOT EXISTS (SELECT 1 FROM conversation_members
                 WHERE conversation_id = p_conversation_id AND user_id = uid) THEN
    RAISE EXCEPTION 'DM_NOT_MEMBER: not a member of this conversation';
  END IF;
  -- Recipient comes from the pair key so messaging someone who left re-invites them.
  a := split_part(key, ':', 1); b := split_part(key, ':', 2);
  other := CASE WHEN a = uid THEN b ELSE a END;
  IF NOT notification_allowed(other, uid) THEN
    RAISE EXCEPTION 'DM_BLOCKED: cannot message this user';
  END IF;

  IF body IS NULL AND p_attachment_type IS NULL THEN
    RAISE EXCEPTION 'DM_EMPTY: message needs text or an attachment';
  END IF;
  IF body IS NOT NULL AND char_length(body) > 2000 THEN
    RAISE EXCEPTION 'DM_TOO_LONG: message exceeds 2000 characters';
  END IF;

  IF p_attachment_type = 'highlight' THEN
    -- Sender may only attach a highlight they can see (mirrors 016 highlights_select).
    IF p_highlight_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM highlights h JOIN profiles p ON p.id = h.author_id
      WHERE h.id = p_highlight_id
        AND (p.privacy_level = 'public' OR p.id = uid
             OR (p.privacy_level = 'followers_only' AND EXISTS (
                   SELECT 1 FROM follows f WHERE f.follower_id = uid AND f.following_id = p.id))))
    THEN RAISE EXCEPTION 'DM_BAD_ATTACHMENT: highlight not found'; END IF;
    p_clip_path := NULL; p_clip_duration := NULL;
  ELSIF p_attachment_type = 'clip' THEN
    IF p_clip_path IS NULL OR split_part(p_clip_path, '/', 1) <> uid THEN
      RAISE EXCEPTION 'DM_BAD_ATTACHMENT: invalid clip path';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM storage.objects
                   WHERE bucket_id = 'message-media' AND name = p_clip_path) THEN
      RAISE EXCEPTION 'DM_BAD_ATTACHMENT: clip not uploaded';
    END IF;
    p_highlight_id := NULL;
  ELSIF p_attachment_type IS NOT NULL THEN
    RAISE EXCEPTION 'DM_BAD_ATTACHMENT: invalid attachment type';
  ELSE
    p_highlight_id := NULL; p_clip_path := NULL; p_clip_duration := NULL;
  END IF;

  -- Re-add the other side if they left; follow relationship decides pending/accepted.
  INSERT INTO conversation_members (conversation_id, user_id, status)
  VALUES (p_conversation_id, other,
          CASE WHEN EXISTS (SELECT 1 FROM follows WHERE follower_id = other AND following_id = uid)
               THEN 'accepted' ELSE 'pending' END)
  ON CONFLICT (conversation_id, user_id) DO NOTHING;

  INSERT INTO messages (conversation_id, sender_id, recipient_id, body,
                        attachment_type, highlight_id, clip_path, clip_duration)
  VALUES (p_conversation_id, uid, other, body,
          p_attachment_type, p_highlight_id, p_clip_path, p_clip_duration)
  RETURNING * INTO result;

  -- NULL preview for attachment-only messages; the client renders the copy.
  preview := CASE WHEN body IS NOT NULL THEN left(body, 120) ELSE NULL END;
  UPDATE conversations
     SET last_message_at = result.created_at,
         last_message_preview = preview,
         last_message_attachment_type = p_attachment_type,
         last_message_sender_id = uid
   WHERE id = p_conversation_id;

  -- Sender has read their own message; replying from Requests is consent.
  UPDATE conversation_members
     SET last_read_at = result.created_at, status = 'accepted'
   WHERE conversation_id = p_conversation_id AND user_id = uid;
  RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.accept_conversation(p_conversation_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid text := (SELECT auth.uid())::text;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  UPDATE conversation_members SET status = 'accepted'
   WHERE conversation_id = p_conversation_id AND user_id = uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'DM_NOT_MEMBER: not a member of this conversation'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.mark_conversation_read(p_conversation_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid text := (SELECT auth.uid())::text;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  UPDATE conversation_members SET last_read_at = greatest(last_read_at, now())
   WHERE conversation_id = p_conversation_id AND user_id = uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'DM_NOT_MEMBER: not a member of this conversation'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.leave_conversation(p_conversation_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid text := (SELECT auth.uid())::text;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  DELETE FROM conversation_members
   WHERE conversation_id = p_conversation_id AND user_id = uid;
  -- trg_cleanup_empty_conversation removes the conversation when both are gone.
END $$;

-- Internal: the push edge function runs as service_role and has no auth.uid().
-- Counts pending conversations too, so a request lights the badge.
CREATE OR REPLACE FUNCTION public.dm_unread_count_for(p_user_id text)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT count(*)::int
  FROM conversation_members me
  JOIN messages m ON m.conversation_id = me.conversation_id
  WHERE me.user_id = p_user_id
    AND m.sender_id <> p_user_id
    AND m.created_at > me.last_read_at
    AND notification_allowed(p_user_id, m.sender_id);
$$;
REVOKE EXECUTE ON FUNCTION public.dm_unread_count_for(text) FROM anon, authenticated, public;

CREATE OR REPLACE FUNCTION public.unread_message_count()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid text := (SELECT auth.uid())::text;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  RETURN dm_unread_count_for(uid);
END $$;

CREATE OR REPLACE FUNCTION public.pending_request_count()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid text := (SELECT auth.uid())::text;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  RETURN (
    SELECT count(*)::int
    FROM conversation_members me
    JOIN conversations c ON c.id = me.conversation_id
    JOIN conversation_members other ON other.conversation_id = c.id AND other.user_id <> uid
    WHERE me.user_id = uid AND me.status = 'pending'
      AND c.last_message_at IS NOT NULL
      AND notification_allowed(uid, other.user_id));
END $$;

REVOKE EXECUTE ON FUNCTION public.get_or_create_conversation(text) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.send_message(text, text, text, text, text, double precision) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.accept_conversation(text) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.mark_conversation_read(text) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.leave_conversation(text) FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.unread_message_count() FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.pending_request_count() FROM anon, public;
GRANT EXECUTE ON FUNCTION public.get_or_create_conversation(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_message(text, text, text, text, text, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_conversation(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_conversation_read(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.leave_conversation(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unread_message_count() TO authenticated;
GRANT EXECUTE ON FUNCTION public.pending_request_count() TO authenticated;

-- Inbox read model. Profile fields are flattened rather than embedded: the
-- view derives two columns from conversation_members.user_id (mine and
-- theirs), which would make a PostgREST embed ambiguous.
CREATE VIEW public.conversation_overview WITH (security_invoker = true) AS
SELECT
  c.id                           AS conversation_id,
  me.user_id                     AS user_id,
  me.status                      AS my_status,
  me.last_read_at                AS last_read_at,
  other.user_id                  AS other_user_id,
  other.status                   AS other_status,
  p.username                     AS other_username,
  p.avatar_url                   AS other_avatar_url,
  c.created_at                   AS created_at,
  c.last_message_at              AS last_message_at,
  c.last_message_preview         AS last_message_preview,
  c.last_message_attachment_type AS last_message_attachment_type,
  c.last_message_sender_id       AS last_message_sender_id,
  (SELECT count(*)::int FROM public.messages m
    WHERE m.conversation_id = c.id
      AND m.sender_id <> me.user_id
      AND m.created_at > me.last_read_at) AS unread_count
FROM public.conversations c
JOIN public.conversation_members me
  ON me.conversation_id = c.id AND me.user_id = (SELECT auth.uid())::text
JOIN public.conversation_members other
  ON other.conversation_id = c.id AND other.user_id <> me.user_id
JOIN public.profiles p ON p.id = other.user_id
WHERE c.last_message_at IS NOT NULL          -- empty shells never show in the inbox
  AND public.dm_allowed(other.user_id);      -- hides blocked either direction

REVOKE SELECT ON public.conversation_overview FROM anon;
GRANT SELECT ON public.conversation_overview TO authenticated;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('message-media', 'message-media', false, 104857600, ARRAY['video/mp4','video/quicktime'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "message_media_insert" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'message-media'
    AND (SELECT auth.uid())::text = (storage.foldername(name))[1]);

-- Uploader, or any member of a conversation whose message references the object.
CREATE POLICY "message_media_select" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'message-media' AND (
    (SELECT auth.uid())::text = (storage.foldername(name))[1]
    OR EXISTS (
      SELECT 1 FROM public.messages m
      JOIN public.conversation_members cm ON cm.conversation_id = m.conversation_id
      WHERE m.clip_path = storage.objects.name
        AND cm.user_id = (SELECT auth.uid())::text)));

CREATE POLICY "message_media_delete" ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'message-media'
    AND (SELECT auth.uid())::text = (storage.foldername(name))[1]);

-- Recipients subscribe to their own inserts (filter recipient_id).
ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
