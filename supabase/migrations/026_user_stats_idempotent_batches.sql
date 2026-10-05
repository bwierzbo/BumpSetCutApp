-- Idempotent lifetime-stats increments.
--
-- Applied to the live project 2026-10-05 (before the app build that sends
-- p_batch_id shipped). A build that sends it against a database without
-- this migration fails ("Could not find the function ... in the schema
-- cache") and its increments stay pending on the device until it's applied. Older builds keep working: p_batch_id defaults
-- to NULL, which skips deduplication exactly as before.
--
-- The client moves pending increments into a batch with a UUID before
-- sending and resends that same batch (same id, same amounts) until it gets
-- a response. Recording the id here makes a resend after a lost response a
-- no-op instead of a double credit.

CREATE TABLE public.user_stats_batches (
  user_id text NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  batch_id uuid NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, batch_id)
);

-- Written only by add_user_stats (SECURITY DEFINER); no client policies.
ALTER TABLE public.user_stats_batches ENABLE ROW LEVEL SECURITY;

-- Replace rather than overload: two add_user_stats signatures would make a
-- two-argument call from older builds ambiguous.
DROP FUNCTION public.add_user_stats(integer, double precision);

CREATE FUNCTION public.add_user_stats(
  p_rallies integer,
  p_time_cut_seconds double precision,
  p_batch_id uuid DEFAULT NULL
)
RETURNS public.user_stats
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid text := (SELECT auth.uid())::text;
  result public.user_stats;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF p_batch_id IS NOT NULL THEN
    INSERT INTO user_stats_batches (user_id, batch_id)
    VALUES (uid, p_batch_id)
    ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN
      -- Already applied (the client resent after a lost response).
      SELECT * INTO result FROM user_stats WHERE user_id = uid;
      RETURN result;
    END IF;
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

REVOKE EXECUTE ON FUNCTION public.add_user_stats(integer, double precision, uuid) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.add_user_stats(integer, double precision, uuid) TO authenticated;

-- Only add_user_stats (SECURITY DEFINER) touches the batch log.
REVOKE ALL ON public.user_stats_batches FROM anon, authenticated;
