-- 037_review_claim_unsynced.sql
--
-- A rally that isn't here yet (pre-tracked on the Mac and not synced) can't
-- be held by anyone else: claiming it succeeds. Before, the claim's UPDATE
-- matched nothing and said no, so the Mac's review passed over every such
-- rally as "being reviewed by someone else".

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
    SELECT EXISTS (SELECT 1 FROM claimed)
        OR NOT EXISTS (SELECT 1 FROM public.label_tracks WHERE id = p_track);
$$;

REVOKE ALL ON FUNCTION public.review_claim(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_claim(uuid) TO authenticated;
