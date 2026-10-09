-- 031_label_tracks_reviewed.sql
--
-- Annotation review (RallyLab on the Mac and the iPhone): every labeled
-- frame of a tracked rally is checked once — its box tightened or
-- confirmed on a crop, a "no ball" or hidden frame checked on the whole
-- frame — before it's used for training. `reviewed` lists the reviewed
-- frames by their index in `points`. Older app builds don't send it, and an
-- upsert without it leaves it as it was.

ALTER TABLE public.label_tracks ADD COLUMN IF NOT EXISTS reviewed jsonb NOT NULL DEFAULT '[]'::jsonb;
