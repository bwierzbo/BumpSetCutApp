-- A label Ben marks wrong (sent to his Not sure) costs 1 RallyCoin again, not 50.
CREATE OR REPLACE FUNCTION private.rallycoins_earned(p_user uuid) RETURNS int
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT (count(i) + count(i) FILTER (WHERE verdict) - count(i) FILTER (WHERE NOT verdict))::int
      FROM public.label_frame_log WHERE labeler = p_user;
$$;
REVOKE ALL ON FUNCTION private.rallycoins_earned(uuid) FROM PUBLIC, anon, authenticated;
