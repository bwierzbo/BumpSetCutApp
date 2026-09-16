-- Lifetime processing stats tied to the account, so they follow the user
-- across devices and reinstalls. Cumulative and monotonic (never reduced by
-- deleting videos). Clients read their own row and add to it only through
-- add_user_stats(); there are deliberately no INSERT/UPDATE policies.
-- Applied to the live project on 2026-09-16 via MCP apply_migration.
CREATE TABLE public.user_stats (
  user_id text PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  rallies_found integer NOT NULL DEFAULT 0 CHECK (rallies_found >= 0),
  time_cut_seconds double precision NOT NULL DEFAULT 0 CHECK (time_cut_seconds >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.user_stats ENABLE ROW LEVEL SECURITY;

CREATE POLICY "user_stats_select_own" ON public.user_stats
  FOR SELECT TO authenticated USING ((SELECT auth.uid())::text = user_id);

-- Atomic increment for the signed-in user; creates the row on first use and
-- returns the new totals so the client can refresh in one round trip.
CREATE OR REPLACE FUNCTION public.add_user_stats(p_rallies integer, p_time_cut_seconds double precision)
RETURNS public.user_stats
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid text := (SELECT auth.uid())::text;
  result public.user_stats;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  INSERT INTO user_stats (user_id, rallies_found, time_cut_seconds)
  VALUES (uid, GREATEST(0, p_rallies), GREATEST(0, p_time_cut_seconds))
  ON CONFLICT (user_id) DO UPDATE SET
    rallies_found = user_stats.rallies_found + GREATEST(0, EXCLUDED.rallies_found),
    time_cut_seconds = user_stats.time_cut_seconds + GREATEST(0, EXCLUDED.time_cut_seconds),
    updated_at = now()
  RETURNING * INTO result;
  RETURN result;
END $$;

REVOKE EXECUTE ON FUNCTION public.add_user_stats(integer, double precision) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.add_user_stats(integer, double precision) TO authenticated;
