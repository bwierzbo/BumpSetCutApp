-- 036_flywheel_clips.sql
--
-- The data flywheel sends video now: every rally of a processed video as a
-- clip of the original footage (the multi-frame ball model learns from
-- moving pictures, not stills). Testers share by default; RallyLab pulls the
-- clips into the training project.
--
-- 1. clip_urls / clip_windows on flywheel_contributions, and the
--    'processed' trigger (one contribution per processed video).
-- 2. record_flywheel_flag takes the clips (frame_urls stays for builds that
--    still send stills).
-- 3. Labelers read the contributions and the training-data bucket, through
--    tester_footage(), which leaves out labelers' own footage (it is in the
--    project already).

ALTER TABLE public.flywheel_contributions
    ADD COLUMN IF NOT EXISTS clip_urls text[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS clip_windows jsonb NOT NULL DEFAULT '[]';

ALTER TABLE public.flywheel_contributions
    DROP CONSTRAINT IF EXISTS flywheel_contributions_trigger_type_check;
ALTER TABLE public.flywheel_contributions
    ADD CONSTRAINT flywheel_contributions_trigger_type_check
    CHECK (trigger_type IN ('low_score', 'user_removed', 'user_trimmed', 'reported', 'no_rallies', 'processed'));

DROP FUNCTION IF EXISTS public.record_flywheel_flag(uuid, integer, text, text, text[], jsonb, double precision,
    double precision, text, text, text, text, jsonb);

CREATE OR REPLACE FUNCTION public.record_flywheel_flag(
    p_local_video_id uuid,
    p_rally_index integer,
    p_trigger text,
    p_reason text DEFAULT NULL,
    p_frame_urls text[] DEFAULT '{}',
    p_evidence jsonb DEFAULT '[]',
    p_rally_confidence double precision DEFAULT NULL,
    p_rally_quality double precision DEFAULT NULL,
    p_app_version text DEFAULT NULL,
    p_os_version text DEFAULT NULL,
    p_device_model text DEFAULT NULL,
    p_consent_version text DEFAULT NULL,
    p_events jsonb DEFAULT '[]',
    p_clip_urls text[] DEFAULT '{}',
    p_clip_windows jsonb DEFAULT '[]'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
begin
    insert into flywheel_contributions(
        user_id, local_video_id, rally_index, trigger_type, user_reason,
        frame_urls, clip_urls, clip_windows, evidence, rally_confidence, rally_quality,
        app_version, os_version, device_model, consent_version,
        flag_count, flag_events
    ) values (
        auth.uid()::text, p_local_video_id, p_rally_index, p_trigger, p_reason,
        p_frame_urls, p_clip_urls, p_clip_windows, p_evidence, p_rally_confidence, p_rally_quality,
        p_app_version, p_os_version, p_device_model, p_consent_version,
        greatest(jsonb_array_length(p_events), 1), p_events
    )
    on conflict (user_id, local_video_id) do update set
        flag_count  = flywheel_contributions.flag_count + greatest(jsonb_array_length(p_events), 1),
        flag_events = flywheel_contributions.flag_events || p_events;
end;
$$;

REVOKE ALL ON FUNCTION public.record_flywheel_flag(uuid, integer, text, text, text[], jsonb, double precision,
    double precision, text, text, text, text, jsonb, text[], jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_flywheel_flag(uuid, integer, text, text, text[], jsonb, double precision,
    double precision, text, text, text, text, jsonb, text[], jsonb) TO authenticated;

-- Contributions with clips from anyone who isn't a labeler, with who sent
-- them. Labelers only.
CREATE OR REPLACE FUNCTION public.tester_footage()
RETURNS TABLE (
    id text,
    user_id text,
    username text,
    local_video_id uuid,
    clip_urls text[],
    clip_windows jsonb,
    consent_version text,
    device_model text,
    created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $$
begin
    if not private.is_labeler() then
        raise exception 'labelers only' using errcode = '42501';
    end if;
    return query
        select c.id, c.user_id, p.username, c.local_video_id, c.clip_urls, c.clip_windows,
               c.consent_version, c.device_model, c.created_at
        from public.flywheel_contributions c
        left join public.profiles p on p.id = c.user_id
        where cardinality(c.clip_urls) > 0
          and not exists (select 1 from public.labelers l where l.user_id::text = c.user_id)
        order by c.created_at;
end;
$$;

REVOKE ALL ON FUNCTION public.tester_footage() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tester_footage() TO authenticated;

-- Labelers download the clips (signed URLs need read access).
DROP POLICY IF EXISTS "training_data_labelers_select" ON storage.objects;
CREATE POLICY "training_data_labelers_select" ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'training-data' AND (SELECT private.is_labeler()));
