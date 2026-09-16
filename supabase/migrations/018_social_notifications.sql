-- Social notifications: rows fan out to the recipient via triggers on
-- likes / follows / comments / comment_likes. Clients only read + mark read.
-- Applied to the live project on 2026-09-15 via MCP apply_migration.
CREATE TABLE public.notifications (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  recipient_id text NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  actor_id text NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  type text NOT NULL CHECK (type IN ('like','follow','comment','comment_like')),
  highlight_id text REFERENCES public.highlights(id) ON DELETE CASCADE,
  comment_id text REFERENCES public.comments(id) ON DELETE CASCADE,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX notifications_recipient_created_idx ON public.notifications (recipient_id, created_at DESC);
CREATE INDEX notifications_recipient_unread_idx ON public.notifications (recipient_id) WHERE read_at IS NULL;
CREATE INDEX notifications_actor_idx ON public.notifications (actor_id);
CREATE INDEX notifications_highlight_idx ON public.notifications (highlight_id);
CREATE INDEX notifications_comment_idx ON public.notifications (comment_id);

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "notifications_select_own" ON public.notifications
  FOR SELECT TO authenticated USING ((SELECT auth.uid())::text = recipient_id);
CREATE POLICY "notifications_update_own" ON public.notifications
  FOR UPDATE TO authenticated
  USING ((SELECT auth.uid())::text = recipient_id)
  WITH CHECK ((SELECT auth.uid())::text = recipient_id);
CREATE POLICY "notifications_delete_own" ON public.notifications
  FOR DELETE TO authenticated USING ((SELECT auth.uid())::text = recipient_id);
-- No INSERT policy: only the SECURITY DEFINER trigger functions write.

-- Never notify across a block in either direction, and never for self-actions.
CREATE OR REPLACE FUNCTION public.notification_allowed(p_recipient text, p_actor text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p_recipient IS NOT NULL
     AND p_recipient <> p_actor
     AND NOT EXISTS (
       SELECT 1 FROM user_blocks
       WHERE (blocker_id = p_recipient AND blocked_id = p_actor)
          OR (blocker_id = p_actor AND blocked_id = p_recipient)
     );
$$;

CREATE OR REPLACE FUNCTION public.notify_on_like() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE owner text;
BEGIN
  SELECT author_id INTO owner FROM highlights WHERE id = NEW.highlight_id;
  IF notification_allowed(owner, NEW.user_id) THEN
    INSERT INTO notifications (recipient_id, actor_id, type, highlight_id)
    VALUES (owner, NEW.user_id, 'like', NEW.highlight_id);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_notify_on_like AFTER INSERT ON public.likes
FOR EACH ROW EXECUTE FUNCTION public.notify_on_like();

CREATE OR REPLACE FUNCTION public.denotify_on_unlike() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM notifications
  WHERE type = 'like' AND actor_id = OLD.user_id AND highlight_id = OLD.highlight_id;
  RETURN OLD;
END $$;
CREATE TRIGGER trg_denotify_on_unlike AFTER DELETE ON public.likes
FOR EACH ROW EXECUTE FUNCTION public.denotify_on_unlike();

CREATE OR REPLACE FUNCTION public.notify_on_follow() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF notification_allowed(NEW.following_id, NEW.follower_id) THEN
    INSERT INTO notifications (recipient_id, actor_id, type)
    VALUES (NEW.following_id, NEW.follower_id, 'follow');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_notify_on_follow AFTER INSERT ON public.follows
FOR EACH ROW EXECUTE FUNCTION public.notify_on_follow();

CREATE OR REPLACE FUNCTION public.denotify_on_unfollow() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM notifications
  WHERE type = 'follow' AND actor_id = OLD.follower_id AND recipient_id = OLD.following_id;
  RETURN OLD;
END $$;
CREATE TRIGGER trg_denotify_on_unfollow AFTER DELETE ON public.follows
FOR EACH ROW EXECUTE FUNCTION public.denotify_on_unfollow();

CREATE OR REPLACE FUNCTION public.notify_on_comment() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE owner text;
BEGIN
  SELECT author_id INTO owner FROM highlights WHERE id = NEW.highlight_id;
  IF notification_allowed(owner, NEW.author_id) THEN
    INSERT INTO notifications (recipient_id, actor_id, type, highlight_id, comment_id)
    VALUES (owner, NEW.author_id, 'comment', NEW.highlight_id, NEW.id);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_notify_on_comment AFTER INSERT ON public.comments
FOR EACH ROW EXECUTE FUNCTION public.notify_on_comment();
-- Comment deletion cleans up via the comment_id FK cascade.

CREATE OR REPLACE FUNCTION public.notify_on_comment_like() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE owner text; hl text;
BEGIN
  SELECT author_id, highlight_id INTO owner, hl FROM comments WHERE id = NEW.comment_id;
  IF notification_allowed(owner, NEW.user_id) THEN
    INSERT INTO notifications (recipient_id, actor_id, type, highlight_id, comment_id)
    VALUES (owner, NEW.user_id, 'comment_like', hl, NEW.comment_id);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_notify_on_comment_like AFTER INSERT ON public.comment_likes
FOR EACH ROW EXECUTE FUNCTION public.notify_on_comment_like();

CREATE OR REPLACE FUNCTION public.denotify_on_comment_unlike() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM notifications
  WHERE type = 'comment_like' AND actor_id = OLD.user_id AND comment_id = OLD.comment_id;
  RETURN OLD;
END $$;
CREATE TRIGGER trg_denotify_on_comment_unlike AFTER DELETE ON public.comment_likes
FOR EACH ROW EXECUTE FUNCTION public.denotify_on_comment_unlike();

-- Live delivery to the signed-in recipient (postgres_changes respects RLS).
ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
