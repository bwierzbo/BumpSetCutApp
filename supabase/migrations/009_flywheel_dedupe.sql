-- ============================================================
-- BumpSetCut Data Flywheel — per-video dedupe
-- One contribution row per (user, video). Whole-video frames are
-- uploaded once; subsequent flags on the same video just bump a
-- counter and append an event (rather than re-uploading frames).
-- Run via Supabase Dashboard > SQL Editor.
-- ============================================================

alter table flywheel_contributions
    add column if not exists flag_count int not null default 1,
    add column if not exists flag_events jsonb not null default '[]'::jsonb;

-- Collapse to a single row per (user, video).
create unique index if not exists uq_flywheel_user_video
    on flywheel_contributions(user_id, local_video_id);

-- Insert-or-increment. Frames + the descriptive columns are set only on the
-- first call; later calls for the same (user, video) just add to flag_count and
-- append events, leaving the uploaded frames untouched.
create or replace function record_flywheel_flag(
    p_local_video_id  uuid,
    p_rally_index     int,
    p_trigger         text,
    p_reason          text,
    p_frame_urls      text[],
    p_evidence        jsonb,
    p_rally_confidence double precision,
    p_rally_quality    double precision,
    p_app_version     text,
    p_os_version      text,
    p_device_model    text,
    p_consent_version text,
    p_events          jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into flywheel_contributions(
        user_id, local_video_id, rally_index, trigger_type, user_reason,
        frame_urls, evidence, rally_confidence, rally_quality,
        app_version, os_version, device_model, consent_version,
        flag_count, flag_events
    ) values (
        auth.uid()::text, p_local_video_id, p_rally_index, p_trigger, p_reason,
        p_frame_urls, p_evidence, p_rally_confidence, p_rally_quality,
        p_app_version, p_os_version, p_device_model, p_consent_version,
        greatest(jsonb_array_length(p_events), 1), p_events
    )
    on conflict (user_id, local_video_id) do update set
        flag_count  = flywheel_contributions.flag_count + greatest(jsonb_array_length(p_events), 1),
        flag_events = flywheel_contributions.flag_events || p_events;
end;
$$;

grant execute on function record_flywheel_flag(
    uuid, int, text, text, text[], jsonb, double precision, double precision,
    text, text, text, text, jsonb
) to authenticated;
