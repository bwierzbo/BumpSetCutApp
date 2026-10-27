-- Minimal stand-ins for what migration 048 depends on in the live Supabase project, for a throwaway local
-- PostgreSQL cluster (supabase/tests/run_048_tests.sh). Definitions of private.is_labeler, private.is_lead and
-- private.notify_labeling are copied from migrations 028, 039 and 045; auth.uid() reads the JWT subject the way
-- Supabase's does; default privileges mirror Supabase's (anon and authenticated get table privileges, RLS decides).
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
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
