-- 051_label_rally_times_cuts.sql
--
-- Cut ranges (D-030): stretches of a recording that are not footage — the clip started in the
-- middle of a rally, an editor put an instant replay in — marked in the live rally pass on the
-- Mac or the phone and synced with the rally times. Kept as a column of their own, not inside
-- `rallies`: every reader of `rallies` (038's SQL, the scorers, the phone) takes each element
-- for a rally, and a phone build from before this column rewrites `rallies` whole but never
-- sends `cuts`, so the merge upsert keeps the server's value.
--
-- RLS: the row policies of 028/049 apply unchanged (a column needs none of its own).

ALTER TABLE public.label_rally_times ADD COLUMN IF NOT EXISTS cuts jsonb;
COMMENT ON COLUMN public.label_rally_times.cuts IS
    'Cut ranges, [{"start": s, "end": e}] in seconds, as marked: stretches that are not footage (the clip starts mid-rally, an editor''s replay). NULL = only builds from before cuts have written the row.';
