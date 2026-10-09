-- 033_review_claims.sql
--
-- Several people reviewing at once (annotation review, RallyLab on the
-- iPhone and the Mac):
--   · claims — whoever reviews a rally claims it; others pass it over while
--     the claim is fresh (15 minutes since their last decision);
--   · review_frames — a decision saves only its frames (server-side, under
--     the row lock), so two people never overwrite each other's work;
--   · unsure — frames someone marked "not sure", by index, kept for later.

ALTER TABLE public.label_tracks ADD COLUMN IF NOT EXISTS unsure jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.label_tracks ADD COLUMN IF NOT EXISTS claimed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE public.label_tracks ADD COLUMN IF NOT EXISTS claimed_at timestamptz;
CREATE INDEX IF NOT EXISTS label_tracks_claimed_by_idx ON public.label_tracks (claimed_by);

-- Claim a rally for review: true if it's now yours.
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
           AND (claimed_by IS NULL OR claimed_by = (SELECT auth.uid()) OR claimed_at < now() - interval '15 minutes')
        RETURNING 1)
    SELECT EXISTS (SELECT 1 FROM claimed);
$$;

-- Save review decisions on a rally's frames: p_edits is
-- [{"i": index, "point": packed row, "reviewed": bool, "unsure": bool}, …].
-- Refused when someone else holds a fresh claim on it.
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
       AND (claimed_by IS NULL OR claimed_by = (SELECT auth.uid()) OR claimed_at < now() - interval '15 minutes')
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

REVOKE ALL ON FUNCTION public.review_claim(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.review_frames(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_claim(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_frames(uuid, jsonb) TO authenticated;
