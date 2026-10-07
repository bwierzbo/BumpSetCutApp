-- 028_labeling.sql
--
-- The Labeler app (a separate iPhone app for labeling training data, not
-- part of BumpSetCut) and RallyLab's Sync share these: the videos of a
-- RallyLab project (5-minute cuts, re-encoded small for the phone, in the
-- private "labeling" bucket) with the rallies RallyLab found in each, the
-- rally times marked on either side, and videos recorded on the phone and
-- uploaded for RallyLab to pull into its project.
--
-- Only labelers (rows added from the dashboard / service role) can read or
-- write any of it; nothing here is visible to app users.

CREATE TABLE IF NOT EXISTS public.labelers (
    user_id  uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    added_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.labelers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.labelers FROM anon;

DROP POLICY IF EXISTS "labelers_select_own" ON public.labelers;
CREATE POLICY "labelers_select_own" ON public.labelers
    FOR SELECT TO authenticated
    USING ((SELECT auth.uid()) = user_id);

CREATE OR REPLACE FUNCTION private.is_labeler()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (SELECT 1 FROM public.labelers WHERE user_id = (SELECT auth.uid()));
$$;
REVOKE ALL ON FUNCTION private.is_labeler() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_labeler() TO authenticated;

-- A video to label. RallyLab's videos have project + session_name; a video
-- uploaded from the phone has neither until RallyLab pulls it in.
CREATE TABLE IF NOT EXISTS public.label_videos (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project       text,
    session_name  text,
    title         text NOT NULL DEFAULT '',
    surface       text NOT NULL CHECK (surface IN ('Indoor', 'Grass', 'Beach')),
    camera        text NOT NULL DEFAULT 'endline_raised'
                  CHECK (camera IN ('endline_raised', 'endline_ground', 'corner', 'sideline')),
    lighting      text NOT NULL DEFAULT '',
    split         text NOT NULL DEFAULT 'train' CHECK (split IN ('train', 'val')),
    -- Path in the labeling bucket; null until the clip is uploaded.
    clip_path     text,
    duration      double precision NOT NULL DEFAULT 0,
    -- Rallies RallyLab's pipeline found, as [[start, end], …] in seconds.
    rallies_found jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- 'rallylab': from a project · 'uploaded': from the phone, waiting for
    -- RallyLab · 'imported': from the phone, now in a project.
    status        text NOT NULL DEFAULT 'rallylab' CHECK (status IN ('rallylab', 'uploaded', 'imported')),
    created_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project, session_name)
);
ALTER TABLE public.label_videos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.label_videos FROM anon;
CREATE INDEX IF NOT EXISTS label_videos_created_by_idx ON public.label_videos (created_by);

-- Every rally's start and end in one video; `complete` = all of them are marked.
CREATE TABLE IF NOT EXISTS public.label_rally_times (
    video_id   uuid PRIMARY KEY REFERENCES public.label_videos(id) ON DELETE CASCADE,
    -- [{"start": s, "end": s}, …] in seconds.
    rallies    jsonb NOT NULL DEFAULT '[]'::jsonb,
    complete   boolean NOT NULL DEFAULT false,
    updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.label_rally_times ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.label_rally_times FROM anon;
CREATE INDEX IF NOT EXISTS label_rally_times_updated_by_idx ON public.label_rally_times (updated_by);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['label_videos', 'label_rally_times'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS "%1$s_labelers" ON public.%1$I', t);
        EXECUTE format('CREATE POLICY "%1$s_labelers" ON public.%1$I FOR ALL TO authenticated
                        USING ((SELECT private.is_labeler())) WITH CHECK ((SELECT private.is_labeler()))', t);
    END LOOP;
END $$;

-- The clips: small H.264 MP4s (720p, ~2 Mbit/s, about 75 MB for 5 minutes).
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('labeling', 'labeling', false, 104857600, ARRAY['video/mp4'])
ON CONFLICT (id) DO UPDATE
    SET public = false, file_size_limit = 104857600, allowed_mime_types = ARRAY['video/mp4'];

-- Uploads use upsert (a re-encoded clip replaces the old one), which needs UPDATE too.
DROP POLICY IF EXISTS "labeling_select" ON storage.objects;
CREATE POLICY "labeling_select" ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'labeling' AND (SELECT private.is_labeler()));
DROP POLICY IF EXISTS "labeling_insert" ON storage.objects;
CREATE POLICY "labeling_insert" ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'labeling' AND (SELECT private.is_labeler()));
DROP POLICY IF EXISTS "labeling_update" ON storage.objects;
CREATE POLICY "labeling_update" ON storage.objects FOR UPDATE TO authenticated
    USING (bucket_id = 'labeling' AND (SELECT private.is_labeler()))
    WITH CHECK (bucket_id = 'labeling' AND (SELECT private.is_labeler()));
DROP POLICY IF EXISTS "labeling_delete" ON storage.objects;
CREATE POLICY "labeling_delete" ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'labeling' AND (SELECT private.is_labeler()));
