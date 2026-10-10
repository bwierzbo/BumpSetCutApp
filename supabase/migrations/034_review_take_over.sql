-- 034_review_take_over.sql
--
-- Annotation review claims (033) lapse after 3 minutes without a decision
-- (was 15): someone reviewing decides every few seconds, so only an idle
-- reviewer's rallies come free. And anyone can take a rally over at once
-- (review_take_over) — the reviewer who had it then has their decisions on
-- it refused, so the one who took it over isn't overwritten.
-- review_held_by_others lists the rallies someone else holds right now.

CREATE OR REPLACE FUNCTION public.review_claim(p_track uuid)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
    WITH claimed AS (
        UPDATE public.label_tracks
           SET claimed_by = (SELECT auth.uid()), claimed_at = now()
         WHERE id = p_track
           AND (claimed_by IS NULL OR claimed_by = (SELECT auth.uid()) OR claimed_at < now() - interval '3 minutes')
        RETURNING 1)
    SELECT EXISTS (SELECT 1 FROM claimed);
$$;

CREATE OR REPLACE FUNCTION public.review_frames(p_track uuid, p_edits jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    e jsonb;
    i int;
    pts jsonb;
    rev jsonb;
    uns jsonb;
BEGIN
    SELECT points, reviewed, unsure INTO pts, rev, uns
      FROM public.label_tracks
     WHERE id = p_track
       AND (claimed_by IS NULL OR claimed_by = (SELECT auth.uid()) OR claimed_at < now() - interval '3 minutes')
       FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'review_frames: rally % is being reviewed by someone else', p_track USING ERRCODE = 'P0001';
    END IF;
    FOR e IN SELECT * FROM jsonb_array_elements(p_edits) LOOP
        i := (e->>'i')::int;
        CONTINUE WHEN i < 0 OR i >= jsonb_array_length(pts);
        pts := jsonb_set(pts, ARRAY[i::text], e->'point');
        rev := COALESCE((SELECT jsonb_agg(x) FROM jsonb_array_elements(rev) x WHERE x::int <> i), '[]'::jsonb);
        uns := COALESCE((SELECT jsonb_agg(x) FROM jsonb_array_elements(uns) x WHERE x::int <> i), '[]'::jsonb);
        IF (e->>'reviewed')::boolean THEN rev := rev || to_jsonb(i); END IF;
        IF (e->>'unsure')::boolean THEN uns := uns || to_jsonb(i); END IF;
    END LOOP;
    UPDATE public.label_tracks
       SET points = pts, reviewed = rev, unsure = uns,
           claimed_by = (SELECT auth.uid()), claimed_at = now(), updated_at = now()
     WHERE id = p_track;
END;
$$;

-- Take a rally over from whoever has it.
CREATE OR REPLACE FUNCTION public.review_take_over(p_track uuid)
RETURNS void
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
    UPDATE public.label_tracks SET claimed_by = (SELECT auth.uid()), claimed_at = now() WHERE id = p_track;
$$;

-- Rallies someone else is reviewing right now.
DROP FUNCTION IF EXISTS public.review_held_by_others();
CREATE FUNCTION public.review_held_by_others()
RETURNS TABLE (track uuid)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
    SELECT id FROM public.label_tracks
     WHERE claimed_by IS NOT NULL AND claimed_by <> (SELECT auth.uid())
       AND claimed_at > now() - interval '3 minutes' AND NOT deleted;
$$;

REVOKE ALL ON FUNCTION public.review_take_over(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.review_held_by_others() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_take_over(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_held_by_others() TO authenticated;
