-- 038_label_tracks_is_rally.sql
--
-- Pre-tracked rallies (machine) are checked as rallies before their frames
-- are reviewed: is_rally is a person's answer — true a rally, false not one
-- (left out of review and training, and not picked again), null not looked
-- at yet. People's own rallies don't use it. Older app builds don't send it,
-- and an upsert without it leaves it as it was.

ALTER TABLE public.label_tracks ADD COLUMN IF NOT EXISTS is_rally boolean;

-- One rally's answer (null takes it back), stamped now so every device's
-- next pull takes it; the rest of the rally is left as it is.
CREATE OR REPLACE FUNCTION public.review_rally(p_track uuid, p_is_rally boolean DEFAULT NULL)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
    UPDATE public.label_tracks
       SET is_rally = p_is_rally, updated_at = now()
     WHERE id = p_track;
$$;

REVOKE ALL ON FUNCTION public.review_rally(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_rally(uuid, boolean) TO authenticated;

-- Pre-tracked rallies cut from rally times a person marked are rallies.
UPDATE public.label_tracks t
   SET is_rally = true, updated_at = now()
 WHERE t.machine AND NOT t.deleted AND t.is_rally IS NULL
   AND EXISTS (
       SELECT 1
         FROM public.label_rally_times r, jsonb_array_elements(r.rallies) m
        WHERE r.video_id = t.video_id
          AND least(t."end", (m->>'end')::double precision) - greatest(t.start, (m->>'start')::double precision)
              > 0.5 * ((m->>'end')::double precision - (m->>'start')::double precision));
