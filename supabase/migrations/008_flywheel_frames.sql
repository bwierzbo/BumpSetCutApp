-- ============================================================
-- BumpSetCut Data Flywheel — switch from clip upload to frames
-- Contributions now upload a small set of full-resolution still
-- frames (the annotation input) instead of a video clip.
-- Run via Supabase Dashboard > SQL Editor.
-- ============================================================

alter table flywheel_contributions
    add column if not exists frame_urls text[] not null default '{}';

-- Clips are no longer uploaded; keep the column for back-compat but allow null.
alter table flywheel_contributions
    alter column clip_url drop not null;
