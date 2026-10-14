-- "To check" counts only frames still labeled: a frame someone has since
-- sent to Not sure, Find the ball or back for review has no label to check,
-- so it was counted on the Labelers card but never shown when opened.

CREATE OR REPLACE FUNCTION public.labeler_summary()
    RETURNS TABLE (labeler uuid, name text, labeled int, approved int, wrong int, waiting int, last_at timestamptz)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT l.user_id, COALESCE(l.name, u.email::text),
           count(f.i)::int,
           count(f.i) FILTER (WHERE f.verdict)::int,
           count(f.i) FILTER (WHERE NOT f.verdict)::int,
           count(f.i) FILTER (WHERE f.verdict IS NULL AND NOT t.deleted
                                AND COALESCE(t.reviewed, '[]'::jsonb) @> to_jsonb(f.i))::int,
           max(f.at)
      FROM public.labelers l
      JOIN auth.users u ON u.id = l.user_id
      LEFT JOIN public.label_frame_log f ON f.labeler = l.user_id
      LEFT JOIN public.label_tracks t ON t.id = f.track
     WHERE (SELECT private.is_lead()) AND l.user_id <> (SELECT auth.uid())
     GROUP BY l.user_id, l.name, u.email
     ORDER BY 6 DESC, 2;
$$;

CREATE OR REPLACE FUNCTION public.labeler_frames(p_labeler uuid)
    RETURNS TABLE (track uuid, i int)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT f.track, f.i FROM public.label_frame_log f
      JOIN public.label_tracks t ON t.id = f.track
     WHERE (SELECT private.is_lead()) AND f.labeler = p_labeler AND f.verdict IS NULL
       AND NOT t.deleted AND COALESCE(t.reviewed, '[]'::jsonb) @> to_jsonb(f.i)
     ORDER BY f.track, f.i;
$$;
