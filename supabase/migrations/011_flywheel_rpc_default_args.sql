-- ============================================================
-- BumpSetCut Data Flywheel — make record_flywheel_flag tolerant of omitted args
--
-- The Swift client encodes its RPC params with Encodable, which omits nil
-- optionals (e.g. p_reason for low_score/no_rallies contributions). With all 13
-- params declared NOT NULL / no-default (migration 009), PostgREST could not
-- resolve a call that omitted p_reason and failed with:
--   "Could not find the function public.record_flywheel_flag(... ) in the schema cache"
--
-- Give the trailing params (p_reason onward) defaults so any omitted optional
-- resolves. Function body is unchanged from 009.
--
-- Run via Supabase Dashboard > SQL Editor (not shipped in app).
-- ============================================================

create or replace function record_flywheel_flag(
    p_local_video_id  uuid,
    p_rally_index     int,
    p_trigger         text,
    p_reason          text default null,
    p_frame_urls      text[] default '{}',
    p_evidence        jsonb default '[]'::jsonb,
    p_rally_confidence double precision default null,
    p_rally_quality    double precision default null,
    p_app_version     text default null,
    p_os_version      text default null,
    p_device_model    text default null,
    p_consent_version text default null,
    p_events          jsonb default '[]'::jsonb
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

notify pgrst, 'reload schema';
