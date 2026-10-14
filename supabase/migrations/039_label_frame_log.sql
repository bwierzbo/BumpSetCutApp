-- Who labeled each frame, so a lead can check other labelers' work in batches.
--
-- label_frame_log: one row per frame per labeler, the last time they labeled
-- it (a frame newly reviewed, or reviewed and changed). Kept by a trigger on
-- label_tracks, so every way a label is written (review_frames, whole-rally
-- saves from the phone or the Mac) is covered. verdict: a lead's check of
-- that label (true right, false wrong; null not checked yet). Labeling the
-- frame again clears it, so the new label is checked again.
--
-- labelers.name: how a labeler is shown. labelers.lead: may check others.

ALTER TABLE public.labelers
    ADD COLUMN name text,
    ADD COLUMN lead boolean NOT NULL DEFAULT false;

CREATE TABLE public.label_frame_log (
    track      uuid NOT NULL REFERENCES public.label_tracks(id) ON DELETE CASCADE,
    i          int  NOT NULL,
    labeler    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    at         timestamptz NOT NULL DEFAULT now(),
    verdict    boolean,
    checked_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    checked_at timestamptz,
    PRIMARY KEY (track, i, labeler)
);
CREATE INDEX label_frame_log_labeler ON public.label_frame_log (labeler) WHERE verdict IS NULL;
CREATE INDEX label_frame_log_checked_by ON public.label_frame_log (checked_by);

ALTER TABLE public.label_frame_log ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION private.is_lead() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT EXISTS (SELECT 1 FROM public.labelers WHERE user_id = (SELECT auth.uid()) AND lead) $$;

REVOKE ALL ON FUNCTION private.is_lead() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_lead() TO authenticated;

-- Leads see everything; a labeler sees their own rows.
CREATE POLICY label_frame_log_select ON public.label_frame_log FOR SELECT TO authenticated
    USING (labeler = (SELECT auth.uid()) OR (SELECT private.is_lead()));

CREATE OR REPLACE FUNCTION private.log_frame_labels() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    uid uuid := auth.uid();
BEGIN
    IF uid IS NULL OR NEW.deleted THEN RETURN NULL; END IF;
    INSERT INTO public.label_frame_log (track, i, labeler, at)
    SELECT NEW.id, r.i, uid, now()
      FROM (SELECT x::int AS i FROM jsonb_array_elements_text(COALESCE(NEW.reviewed, '[]'::jsonb)) x) r
     WHERE r.i >= 0 AND r.i < jsonb_array_length(NEW.points)
       AND (TG_OP = 'INSERT'
            OR NOT COALESCE(OLD.reviewed, '[]'::jsonb) @> to_jsonb(r.i)
            OR OLD.points -> r.i IS DISTINCT FROM NEW.points -> r.i)
    ON CONFLICT (track, i, labeler) DO UPDATE
        SET at = excluded.at, verdict = NULL, checked_by = NULL, checked_at = NULL;
    RETURN NULL;
END;
$$;

CREATE TRIGGER label_tracks_log_frames
    AFTER INSERT OR UPDATE OF points, reviewed ON public.label_tracks
    FOR EACH ROW EXECUTE FUNCTION private.log_frame_labels();

-- Each other labeler: frames labeled, checked right, checked wrong, waiting to be checked.
CREATE OR REPLACE FUNCTION public.labeler_summary()
    RETURNS TABLE (labeler uuid, name text, labeled int, approved int, wrong int, waiting int, last_at timestamptz)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT l.user_id, COALESCE(l.name, u.email::text),
           count(f.i)::int,
           count(f.i) FILTER (WHERE f.verdict)::int,
           count(f.i) FILTER (WHERE NOT f.verdict)::int,
           count(f.i) FILTER (WHERE f.verdict IS NULL)::int,
           max(f.at)
      FROM public.labelers l
      JOIN auth.users u ON u.id = l.user_id
      LEFT JOIN public.label_frame_log f ON f.labeler = l.user_id
     WHERE (SELECT private.is_lead()) AND l.user_id <> (SELECT auth.uid())
     GROUP BY l.user_id, l.name, u.email
     ORDER BY count(f.i) FILTER (WHERE f.verdict IS NULL) DESC, COALESCE(l.name, u.email::text);
$$;

-- A labeler's frames waiting to be checked, rally by rally in frame order.
CREATE OR REPLACE FUNCTION public.labeler_frames(p_labeler uuid)
    RETURNS TABLE (track uuid, i int)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT f.track, f.i FROM public.label_frame_log f
     WHERE (SELECT private.is_lead()) AND f.labeler = p_labeler AND f.verdict IS NULL
     ORDER BY f.track, f.i;
$$;

-- A lead's checks: [{track, i, labeler, ok}], ok true right, false wrong, null taken back.
CREATE OR REPLACE FUNCTION public.label_verdicts(p_verdicts jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF NOT (SELECT private.is_lead()) THEN
        RAISE EXCEPTION 'label_verdicts: only a lead checks labels' USING ERRCODE = '42501';
    END IF;
    UPDATE public.label_frame_log f
       SET verdict = (v->>'ok')::boolean,
           checked_by = CASE WHEN v->>'ok' IS NULL THEN NULL ELSE (SELECT auth.uid()) END,
           checked_at = CASE WHEN v->>'ok' IS NULL THEN NULL ELSE now() END
      FROM jsonb_array_elements(p_verdicts) v
     WHERE f.track = (v->>'track')::uuid AND f.i = (v->>'i')::int AND f.labeler = (v->>'labeler')::uuid;
END;
$$;

REVOKE ALL ON FUNCTION public.labeler_summary(), public.labeler_frames(uuid), public.label_verdicts(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.labeler_summary(), public.labeler_frames(uuid), public.label_verdicts(jsonb) TO authenticated;
REVOKE ALL ON FUNCTION private.log_frame_labels() FROM PUBLIC, anon, authenticated;

-- Names for the labelers so far; Ben checks the others.
UPDATE public.labelers l SET name = v.name, lead = v.lead
  FROM auth.users u, (VALUES ('bwierzbo@gmail.com', 'Ben', true), ('kbilyeu20@gmail.com', 'Kourtney', false),
                             ('qwoodruff2000@gmail.com', 'Quentin', false), ('sirlifeless@gmail.com', 'Grant', false)) v(email, name, lead)
 WHERE u.id = l.user_id AND lower(u.email) = v.email;
