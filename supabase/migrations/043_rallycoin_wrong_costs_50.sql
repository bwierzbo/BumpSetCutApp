-- A label Ben marks wrong (sent to his Not sure) costs 50 RallyCoin, not 3.
CREATE OR REPLACE FUNCTION private.rallycoins_earned(p_user uuid) RETURNS int
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT (count(i) + count(i) FILTER (WHERE verdict) - 50 * count(i) FILTER (WHERE NOT verdict))::int
      FROM public.label_frame_log WHERE labeler = p_user;
$$;
REVOKE ALL ON FUNCTION private.rallycoins_earned(uuid) FROM PUBLIC, anon, authenticated;
