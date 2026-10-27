-- Minimal stand-ins for what migration 048 depends on in the live Supabase project, for a throwaway local
-- PostgreSQL cluster (supabase/tests/run_048_tests.sh). Definitions of private.is_labeler, private.is_lead and
-- private.notify_labeling are copied from migrations 028, 039 and 045; auth.uid() reads the JWT subject the way
-- Supabase's does; default privileges mirror Supabase's (anon and authenticated get table privileges, RLS decides).
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
END $$;
CREATE SCHEMA auth;
CREATE SCHEMA private;
CREATE SCHEMA realtime;
GRANT USAGE ON SCHEMA public, auth, private TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated;

CREATE TABLE auth.users (id uuid PRIMARY KEY);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;
CREATE FUNCTION realtime.send(payload jsonb, event text, topic text, private boolean) RETURNS void LANGUAGE sql AS $$ SELECT $$;

CREATE TABLE public.labelers (user_id uuid PRIMARY KEY REFERENCES auth.users(id), lead boolean NOT NULL DEFAULT false);
ALTER TABLE public.labelers ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION private.is_labeler() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT EXISTS (SELECT 1 FROM public.labelers WHERE user_id = (SELECT auth.uid())) $$;
REVOKE ALL ON FUNCTION private.is_labeler() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_labeler() TO authenticated;

CREATE OR REPLACE FUNCTION private.is_lead() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$ SELECT EXISTS (SELECT 1 FROM public.labelers WHERE user_id = (SELECT auth.uid()) AND lead) $$;
REVOKE ALL ON FUNCTION private.is_lead() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_lead() TO authenticated;

CREATE OR REPLACE FUNCTION private.notify_labeling() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    BEGIN
        PERFORM realtime.send(jsonb_build_object('table', TG_TABLE_NAME, 'by', auth.uid()), 'changed', 'labeling', true);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'notify_labeling: %', SQLERRM;
    END;
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION private.notify_labeling() FROM PUBLIC, anon, authenticated;

-- The label_videos columns 048 reads (028 has more; none matter here).
CREATE TABLE public.label_videos (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project      text,
    session_name text,
    title        text NOT NULL DEFAULT ''
);
ALTER TABLE public.label_videos ENABLE ROW LEVEL SECURITY;
-- As live (028): labelers have every command on label_videos.
CREATE POLICY label_videos_labelers ON public.label_videos FOR ALL TO authenticated USING ((SELECT private.is_labeler())) WITH CHECK ((SELECT private.is_labeler()));
ALTER TABLE public.label_videos ADD COLUMN IF NOT EXISTS clip_path text;
ALTER TABLE public.label_videos ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'rallylab';
-- The live CHECK (label_videos_status_check), so a test cannot pass on a status the live table refuses.
DO $$ BEGIN
    ALTER TABLE public.label_videos ADD CONSTRAINT label_videos_status_check CHECK (status = ANY (ARRAY['rallylab'::text, 'uploaded'::text, 'imported'::text]));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- The legacy annotation tables and the storage bucket as live (028, 030, 039), for 049_protect_withheld_footage.
CREATE TABLE public.label_rally_times (video_id uuid PRIMARY KEY REFERENCES public.label_videos(id) ON DELETE CASCADE, rallies jsonb NOT NULL DEFAULT '[]');
ALTER TABLE public.label_rally_times ENABLE ROW LEVEL SECURITY;
CREATE POLICY label_rally_times_labelers ON public.label_rally_times FOR ALL TO authenticated USING ((SELECT private.is_labeler())) WITH CHECK ((SELECT private.is_labeler()));
CREATE TABLE public.label_tracks (id uuid PRIMARY KEY, video_id uuid NOT NULL REFERENCES public.label_videos(id) ON DELETE CASCADE, points jsonb NOT NULL DEFAULT '[]');
ALTER TABLE public.label_tracks ENABLE ROW LEVEL SECURITY;
CREATE POLICY label_tracks_labelers ON public.label_tracks FOR ALL TO authenticated USING ((SELECT private.is_labeler())) WITH CHECK ((SELECT private.is_labeler()));
CREATE TABLE public.label_frame_log (track uuid NOT NULL, i integer NOT NULL, labeler uuid NOT NULL, verdict boolean, PRIMARY KEY (track, i, labeler));
ALTER TABLE public.label_frame_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY label_frame_log_select ON public.label_frame_log FOR SELECT TO authenticated USING ((labeler = (SELECT auth.uid())) OR (SELECT private.is_lead()));
CREATE SCHEMA IF NOT EXISTS storage;
GRANT USAGE ON SCHEMA storage TO anon, authenticated;
CREATE TABLE storage.objects (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), bucket_id text NOT NULL, name text NOT NULL, owner uuid DEFAULT auth.uid(), UNIQUE (bucket_id, name));
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT ALL ON storage.objects TO anon, authenticated;
CREATE POLICY labeling_select ON storage.objects FOR SELECT TO authenticated USING ((bucket_id = 'labeling') AND (SELECT private.is_labeler()));
CREATE POLICY labeling_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK ((bucket_id = 'labeling') AND (SELECT private.is_labeler()));
CREATE POLICY labeling_update ON storage.objects FOR UPDATE TO authenticated USING ((bucket_id = 'labeling') AND (SELECT private.is_labeler())) WITH CHECK ((bucket_id = 'labeling') AND (SELECT private.is_labeler()));
CREATE POLICY labeling_delete ON storage.objects FOR DELETE TO authenticated USING ((bucket_id = 'labeling') AND (SELECT private.is_labeler()));
