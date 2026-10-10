-- 035_label_tracks_machine.sql
--
-- Self-training (RallyLab PreTracker): the multi-frame model tracks rallies
-- in train videos on its own. `machine` marks those rallies: their sure
-- frames train as the model's own labels, the rest go to annotation review.
-- Null (older builds, people's rallies) means a person's. Older app builds
-- don't send it, and an upsert without it leaves it as it was.

ALTER TABLE public.label_tracks ADD COLUMN IF NOT EXISTS machine boolean;
