-- RallyCoin: a joke token for labelers, from label_frame_log (039).
-- 1 per frame labeled, +1 when a lead checks it right, −3 when wrong.
-- No cash value. Every labeler sees the board (names only, no emails).

CREATE OR REPLACE FUNCTION public.rallycoin_board()
    RETURNS TABLE (name text, coins int, frames int, me boolean)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(l.name, 'Mystery labeler'),
           (count(f.i) + count(f.i) FILTER (WHERE f.verdict) - 3 * count(f.i) FILTER (WHERE NOT f.verdict))::int,
           count(f.i)::int,
           l.user_id = (SELECT auth.uid())
      FROM public.labelers l
      LEFT JOIN public.label_frame_log f ON f.labeler = l.user_id
     WHERE (SELECT private.is_labeler())
     GROUP BY l.user_id, l.name
     ORDER BY 2 DESC, 1;
$$;

REVOKE ALL ON FUNCTION public.rallycoin_board() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rallycoin_board() TO authenticated;
