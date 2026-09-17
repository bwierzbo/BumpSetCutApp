-- Direct messages: 1:1 conversations, a requests inbox, highlight/clip
-- attachments, private message-media bucket. All writes go through
-- SECURITY DEFINER RPCs (023); clients only SELECT (via RLS) and subscribe.
-- Applied to the live project on 2026-09-17 via MCP apply_migration.

CREATE TABLE public.conversations (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  -- least(a,b)||':'||greatest(a,b); guarantees one conversation per pair.
  pair_key text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_message_at timestamptz,
  -- NULL for attachment-only messages; the client renders its own copy.
  last_message_preview text,
  last_message_attachment_type text CHECK (last_message_attachment_type IN ('highlight','clip')),
  last_message_sender_id text REFERENCES public.profiles(id) ON DELETE SET NULL
);
CREATE INDEX conversations_last_message_idx ON public.conversations (last_message_at DESC);
CREATE INDEX conversations_last_sender_idx ON public.conversations (last_message_sender_id);

CREATE TABLE public.conversation_members (
  conversation_id text NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  user_id text NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'accepted' CHECK (status IN ('accepted','pending')),
  -- A brand-new member has read nothing. A now() default would equal the first
  -- message's created_at whenever both land in one transaction, making that
  -- message count as already-read.
  last_read_at timestamptz NOT NULL DEFAULT '-infinity'::timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX conversation_members_user_idx ON public.conversation_members (user_id, status);

CREATE TABLE public.messages (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  conversation_id text NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  sender_id text NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  -- Denormalised (1:1 only): realtime filter + push webhook read it directly.
  recipient_id text NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  body text CHECK (body IS NULL OR char_length(body) <= 2000),
  attachment_type text CHECK (attachment_type IN ('highlight','clip')),
  highlight_id text REFERENCES public.highlights(id) ON DELETE SET NULL,
  clip_path text,
  clip_duration double precision CHECK (clip_duration IS NULL OR clip_duration >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT messages_has_content CHECK (
    (body IS NOT NULL AND btrim(body) <> '') OR attachment_type IS NOT NULL),
  -- highlight_id may become NULL later via ON DELETE SET NULL, so only the
  -- clip shape is fully pinned.
  CONSTRAINT messages_attachment_shape CHECK (
    (attachment_type IS NULL AND highlight_id IS NULL AND clip_path IS NULL AND clip_duration IS NULL)
    OR (attachment_type = 'highlight' AND clip_path IS NULL AND clip_duration IS NULL)
    OR (attachment_type = 'clip' AND clip_path IS NOT NULL AND highlight_id IS NULL))
);
CREATE INDEX messages_conversation_created_idx ON public.messages (conversation_id, created_at DESC);
CREATE INDEX messages_recipient_created_idx ON public.messages (recipient_id, created_at DESC);
CREATE INDEX messages_sender_idx ON public.messages (sender_id);
CREATE INDEX messages_highlight_idx ON public.messages (highlight_id) WHERE highlight_id IS NOT NULL;
CREATE INDEX messages_clip_path_idx ON public.messages (clip_path) WHERE clip_path IS NOT NULL;

-- Helpers. Unlike 019's trigger helpers these ARE client-executable, because
-- an RLS policy / security_invoker view runs as the invoker. Both read
-- auth.uid() internally so neither can be used to probe other users.
CREATE OR REPLACE FUNCTION public.is_conversation_member(p_conversation_id text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM conversation_members
    WHERE conversation_id = p_conversation_id
      AND user_id = (SELECT auth.uid())::text);
$$;
REVOKE EXECUTE ON FUNCTION public.is_conversation_member(text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.is_conversation_member(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.dm_allowed(p_other_user_id text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT notification_allowed(p_other_user_id, (SELECT auth.uid())::text);
$$;
REVOKE EXECUTE ON FUNCTION public.dm_allowed(text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.dm_allowed(text) TO authenticated;

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversation_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "conversations_select_member" ON public.conversations
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.conversation_members cm
            WHERE cm.conversation_id = conversations.id
              AND cm.user_id = (SELECT auth.uid())::text));

-- Self-referential: the inline EXISTS used elsewhere would recurse here.
CREATE POLICY "conversation_members_select_member" ON public.conversation_members
  FOR SELECT TO authenticated USING (
    user_id = (SELECT auth.uid())::text
    OR public.is_conversation_member(conversation_id));

CREATE POLICY "messages_select_member" ON public.messages
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.conversation_members cm
            WHERE cm.conversation_id = messages.conversation_id
              AND cm.user_id = (SELECT auth.uid())::text));
-- No INSERT/UPDATE/DELETE policies on any of the three tables.

CREATE OR REPLACE FUNCTION public.cleanup_empty_conversation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM conversations c
  WHERE c.id = OLD.conversation_id
    AND NOT EXISTS (SELECT 1 FROM conversation_members WHERE conversation_id = c.id);
  RETURN OLD;
END $$;
REVOKE EXECUTE ON FUNCTION public.cleanup_empty_conversation() FROM anon, authenticated;
CREATE TRIGGER trg_cleanup_empty_conversation AFTER DELETE ON public.conversation_members
FOR EACH ROW EXECUTE FUNCTION public.cleanup_empty_conversation();
