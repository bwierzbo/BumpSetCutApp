-- Final check: a lead signs off a finished rally after seeing its whole
-- path (no jumping between balls or courts). Relabeling any frame after
-- that (label_frame_log, 039) makes the sign-off stale, so it's checked again.

CREATE TABLE public.label_rally_finals (
    track      uuid PRIMARY KEY REFERENCES public.label_tracks(id) ON DELETE CASCADE,
    checked_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    checked_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX label_rally_finals_checked_by ON public.label_rally_finals (checked_by);
CREATE INDEX label_frame_log_track_at ON public.label_frame_log (track, at);
ALTER TABLE public.label_rally_finals ENABLE ROW LEVEL SECURITY;

-- Rallies signed off and still good (nothing relabeled since). Leads only.
CREATE OR REPLACE FUNCTION public.rally_finals() RETURNS TABLE (track uuid)
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF NOT (SELECT private.is_lead()) THEN
        RAISE EXCEPTION 'rally_finals: leads only' USING ERRCODE = '42501';
    END IF;
    RETURN QUERY
    SELECT r.track FROM public.label_rally_finals r
     WHERE NOT EXISTS (SELECT 1 FROM public.label_frame_log f WHERE f.track = r.track AND f.at > r.checked_at);
END;
$$;

-- Sign a rally off (true), or take it back (false).
CREATE OR REPLACE FUNCTION public.rally_final(p_track uuid, p_ok boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF NOT (SELECT private.is_lead()) THEN
        RAISE EXCEPTION 'rally_final: leads only' USING ERRCODE = '42501';
    END IF;
    IF p_ok THEN
        INSERT INTO public.label_rally_finals (track, checked_by) VALUES (p_track, (SELECT auth.uid()))
        ON CONFLICT (track) DO UPDATE SET checked_by = excluded.checked_by, checked_at = now();
    ELSE
        DELETE FROM public.label_rally_finals WHERE track = p_track;
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.rally_finals(), public.rally_final(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rally_finals(), public.rally_final(uuid, boolean) TO authenticated;
