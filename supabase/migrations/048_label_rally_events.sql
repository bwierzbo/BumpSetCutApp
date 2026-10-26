-- 048_label_rally_events.sql
--
-- Stage 1 rally-boundary records (D-024) shared between the Mac and the phone:
-- one row per recording holding the whole versioned `rallyevents.json` record
-- (rally_event_truth_v1), a server-kept revision, and who saved it. Writes go
-- through `rally_events_save` only: it refuses a stale revision (optimistic
-- concurrency — the conflict comes back to the client, nothing is merged over),
-- refuses any recording on the project's withheld list (the L2 withheld
-- closure, published by the Mac), and refuses a project whose list has never
-- been published (unknown = withheld). The legacy label_rally_times rows are
-- untouched.

-- The withheld closure per project, as RallyLab computes it (ReservedVideos.lineageWithheldNames):
-- lineage holdout, legacy holdout, final test, candidates and every alias. Published whole by a lead.
CREATE TABLE IF NOT EXISTS public.label_withheld (
    project      text NOT NULL,
    session_name text NOT NULL,
    listed_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    listed_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project, session_name)
);
ALTER TABLE public.label_withheld ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.label_withheld FROM anon;

-- Which projects have a published list at all: a project without one is unknown, so no event is accepted for it.
CREATE TABLE IF NOT EXISTS public.label_withheld_lists (
    project    text PRIMARY KEY,
    names      integer NOT NULL DEFAULT 0,
    listed_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    listed_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.label_withheld_lists ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.label_withheld_lists FROM anon;

CREATE TABLE IF NOT EXISTS public.label_rally_events (
    video_id           uuid PRIMARY KEY REFERENCES public.label_videos(id) ON DELETE CASCADE,
    project            text NOT NULL,
    session_name       text NOT NULL,
    annotation_version text NOT NULL,
    -- The record as the apps write it (camelCase keys, EventReview.File); `revision` inside it equals the column.
    record             jsonb NOT NULL,
    revision           integer NOT NULL DEFAULT 1,
    updated_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project, session_name)
);
ALTER TABLE public.label_rally_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.label_rally_events FROM anon;
CREATE INDEX IF NOT EXISTS label_rally_events_updated_at_idx ON public.label_rally_events (updated_at);

-- Labelers read all three tables; no direct write policy exists — writes go through the functions below.
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['label_withheld', 'label_withheld_lists', 'label_rally_events'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS "%1$s_labelers_read" ON public.%1$I', t);
        EXECUTE format('CREATE POLICY "%1$s_labelers_read" ON public.%1$I FOR SELECT TO authenticated
                        USING ((SELECT private.is_labeler()))', t);
    END LOOP;
END $$;

-- The frame identity of the copy's original (FrameIdentity.digest), published by the Mac with the copy; the
-- phone compares its downloaded copy's own frames with it before any event commit.
ALTER TABLE public.label_videos ADD COLUMN IF NOT EXISTS frame_times_digest text;

-- Publish a project's withheld list whole (leads only). Replaces the previous list in one transaction.
CREATE OR REPLACE FUNCTION public.label_withheld_publish(p_project text, p_names text[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE n integer;
BEGIN
    IF NOT (SELECT private.is_lead()) THEN
        RAISE EXCEPTION 'label_withheld_publish: leads only' USING ERRCODE = '42501';
    END IF;
    IF p_project IS NULL OR p_project = '' THEN
        RAISE EXCEPTION 'label_withheld_publish: a project name is required' USING ERRCODE = '22023';
    END IF;
    DELETE FROM public.label_withheld WHERE project = p_project;
    INSERT INTO public.label_withheld (project, session_name, listed_by, listed_at)
        SELECT p_project, x, (SELECT auth.uid()), now() FROM unnest(coalesce(p_names, ARRAY[]::text[])) AS x WHERE x <> '';
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO public.label_withheld_lists (project, names, listed_by, listed_at) VALUES (p_project, n, (SELECT auth.uid()), now())
        ON CONFLICT (project) DO UPDATE SET names = excluded.names, listed_by = excluded.listed_by, listed_at = excluded.listed_at;
    RETURN n;
END;
$$;

-- Save a recording's record at an expected revision. Returns the row as saved (new revision inside and out).
--   stale revision  → P0001 'conflict: …'   (the client keeps both versions and asks the person)
--   withheld        → 42501 'withheld: …'   (also when the project has no published list)
--   wrong record    → 22023                (version, or a record naming another recording)
CREATE OR REPLACE FUNCTION public.rally_events_save(p_video uuid, p_expected integer, p_record jsonb)
    RETURNS SETOF public.label_rally_events
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_project text;
    v_session text;
    v_current integer;
    v_next integer;
BEGIN
    IF NOT (SELECT private.is_labeler()) THEN
        RAISE EXCEPTION 'rally_events_save: labelers only' USING ERRCODE = '42501';
    END IF;
    SELECT project, session_name INTO v_project, v_session FROM public.label_videos WHERE id = p_video;
    IF NOT FOUND OR v_project IS NULL OR v_session IS NULL THEN
        RAISE EXCEPTION 'rally_events_save: no such recording' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.label_withheld_lists WHERE project = v_project) THEN
        RAISE EXCEPTION 'withheld: project % has no published withheld list; nothing is accepted until RallyLab publishes it', v_project USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM public.label_withheld WHERE project = v_project AND session_name = v_session) THEN
        RAISE EXCEPTION 'withheld: % is a withheld recording', v_session USING ERRCODE = '42501';
    END IF;
    IF coalesce(p_record->>'annotationVersion', '') <> 'rally_event_truth_v1' THEN
        RAISE EXCEPTION 'rally_events_save: annotationVersion % is not accepted', coalesce(p_record->>'annotationVersion', '(none)') USING ERRCODE = '22023';
    END IF;
    IF coalesce(p_record->>'video', '') <> v_session THEN
        RAISE EXCEPTION 'rally_events_save: the record names %, not %', coalesce(p_record->>'video', '(none)'), v_session USING ERRCODE = '22023';
    END IF;
    SELECT revision INTO v_current FROM public.label_rally_events WHERE video_id = p_video FOR UPDATE;
    IF NOT FOUND THEN
        IF p_expected <> 0 THEN
            RAISE EXCEPTION 'conflict: no record on the server yet, expected revision % (server 0)', p_expected USING ERRCODE = 'P0001';
        END IF;
        v_next := 1;
        INSERT INTO public.label_rally_events (video_id, project, session_name, annotation_version, record, revision, updated_by, updated_at)
            VALUES (p_video, v_project, v_session, 'rally_event_truth_v1', jsonb_set(p_record, '{revision}', to_jsonb(v_next), true), v_next, (SELECT auth.uid()), now());
    ELSE
        IF v_current <> p_expected THEN
            RAISE EXCEPTION 'conflict: the record changed on the server (revision %, expected %)', v_current, p_expected USING ERRCODE = 'P0001';
        END IF;
        v_next := v_current + 1;
        UPDATE public.label_rally_events
           SET record = jsonb_set(p_record, '{revision}', to_jsonb(v_next), true), revision = v_next,
               annotation_version = 'rally_event_truth_v1', updated_by = (SELECT auth.uid()), updated_at = now()
         WHERE video_id = p_video;
    END IF;
    RETURN QUERY SELECT * FROM public.label_rally_events WHERE video_id = p_video;
END;
$$;

REVOKE ALL ON FUNCTION public.label_withheld_publish(text, text[]), public.rally_events_save(uuid, integer, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.label_withheld_publish(text, text[]), public.rally_events_save(uuid, integer, jsonb) TO authenticated;

-- Live notices as for the other labeling tables (045): a tiny broadcast, no row data.
DROP TRIGGER IF EXISTS label_rally_events_live ON public.label_rally_events;
CREATE TRIGGER label_rally_events_live AFTER INSERT OR UPDATE OR DELETE ON public.label_rally_events
    FOR EACH STATEMENT EXECUTE FUNCTION private.notify_labeling();
DROP TRIGGER IF EXISTS label_withheld_live ON public.label_withheld;
CREATE TRIGGER label_withheld_live AFTER INSERT OR UPDATE OR DELETE ON public.label_withheld
    FOR EACH STATEMENT EXECUTE FUNCTION private.notify_labeling();
