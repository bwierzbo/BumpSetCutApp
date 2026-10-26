-- 049_protect_withheld_footage.sql
--
-- Restricts access to protected footage for ordinary labelers (owner decision, 2026-10-26: restrict, do not
-- delete). Depends on 048: the project's withheld list (label_withheld / label_withheld_lists, published by the
-- lead's RallyLab) names every protected recording and alias.
--
-- A recording is PROTECTED when it belongs to a project (RallyLab's recordings; a phone-only upload has no project)
-- and that project has no published withheld list (unknown = protected) or lists the recording. Judged at access
-- time, so a recording withheld later is protected at once.
--
-- For ordinary labelers (leads are unaffected — they publish the list and keep RallyLab's sync working):
--   * label_videos           — protected rows cannot be read, created, changed or deleted;
--   * label_rally_times, label_tracks — rows of a protected (or unreadable) recording likewise;
--   * label_frame_log        — a labeler's own rows on a protected recording's tracks cannot be read;
--   * storage, bucket 'labeling' — an object can be read (and so signed: creating a signed URL requires SELECT on
--     the object), changed or deleted only when a label_videos row references it and no protected row does; a
--     clip's ball-path sidecar (`<clip>.ballpath.json`) follows its clip. A copy of a protected recording, and any
--     object no row references (its identity unknown), is therefore refused, through the apps and the API alike.
--   * references cannot be forged: an ordinary labeler may create only a phone upload's row (no project, no
--     recording, no identities, a `phone/` object no other row claims) and may never change a row's project,
--     recording, copy path or identities — so no labeler-made row can point at a RallyLab copy or the
--     unreferenced object. Uploads are unchanged.
-- Nothing is deleted or moved: every object, row, hash and historical annotation stays as it is.

CREATE OR REPLACE FUNCTION private.label_session_protected(p_project text, p_session text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT p_project IS NOT NULL AND (
        NOT EXISTS (SELECT 1 FROM public.label_withheld_lists l WHERE l.project = p_project)
        OR EXISTS (SELECT 1 FROM public.label_withheld w WHERE w.project = p_project AND w.session_name = p_session))
$$;

-- Whether the caller may see this recording's rows: a lead always; a labeler when the recording exists and is not protected.
CREATE OR REPLACE FUNCTION private.label_video_readable(p_video uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT (SELECT private.is_lead())
        OR EXISTS (SELECT 1 FROM public.label_videos v WHERE v.id = p_video AND NOT private.label_session_protected(v.project, v.session_name))
$$;

CREATE OR REPLACE FUNCTION private.label_track_readable(p_track uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT (SELECT private.is_lead())
        OR EXISTS (SELECT 1 FROM public.label_tracks t WHERE t.id = p_track AND private.label_video_readable(t.video_id))
$$;

-- A storage object of the labeling bucket the caller may read: a lead always; a labeler when a row references the
-- object (or, for a ball-path sidecar, its clip) and no protected row does.
CREATE OR REPLACE FUNCTION private.label_object_readable(p_name text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    WITH clip AS (SELECT regexp_replace(p_name, '\.ballpath\.json$', '') AS path)
    SELECT (SELECT private.is_lead())
        OR (EXISTS (SELECT 1 FROM public.label_videos v, clip WHERE v.clip_path = clip.path)
            AND NOT EXISTS (SELECT 1 FROM public.label_videos v, clip WHERE v.clip_path = clip.path AND private.label_session_protected(v.project, v.session_name)))
$$;

-- No forged references: what an ordinary labeler may write to label_videos (leads are not limited).
CREATE OR REPLACE FUNCTION private.label_videos_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    -- Server-side work (migrations, the service role) has no signed-in user; API callers always do.
    IF (SELECT auth.uid()) IS NULL OR (SELECT private.is_lead()) THEN RETURN NEW; END IF;
    IF TG_OP = 'INSERT' THEN
        -- Only a phone upload's own row: no project or recording, no identities, a phone/ object nobody else claims.
        IF NEW.project IS NOT NULL OR NEW.session_name IS NOT NULL OR NEW.source_fingerprint IS NOT NULL OR NEW.frame_times_digest IS NOT NULL
           OR (NEW.clip_path IS NOT NULL AND NEW.clip_path NOT LIKE 'phone/%')
           OR (NEW.clip_path IS NOT NULL AND EXISTS (SELECT 1 FROM public.label_videos v WHERE v.clip_path = NEW.clip_path)) THEN
            RAISE EXCEPTION 'label_videos: a labeler may add only a phone upload''s own row' USING ERRCODE = '42501';
        END IF;
    ELSIF NEW.project IS DISTINCT FROM OLD.project OR NEW.session_name IS DISTINCT FROM OLD.session_name
          OR NEW.clip_path IS DISTINCT FROM OLD.clip_path OR NEW.source_fingerprint IS DISTINCT FROM OLD.source_fingerprint
          OR NEW.frame_times_digest IS DISTINCT FROM OLD.frame_times_digest THEN
        RAISE EXCEPTION 'label_videos: a labeler may not change a recording''s project, name, copy or identities' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.label_videos_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS label_videos_guard ON public.label_videos;
CREATE TRIGGER label_videos_guard BEFORE INSERT OR UPDATE ON public.label_videos FOR EACH ROW EXECUTE FUNCTION private.label_videos_guard();

REVOKE ALL ON FUNCTION private.label_session_protected(text, text), private.label_video_readable(uuid),
                       private.label_track_readable(uuid), private.label_object_readable(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.label_session_protected(text, text), private.label_video_readable(uuid),
                          private.label_track_readable(uuid), private.label_object_readable(text) TO authenticated;

-- label_videos: one policy per command, protected rows refused to ordinary labelers.
DROP POLICY IF EXISTS "label_videos_labelers" ON public.label_videos;
DROP POLICY IF EXISTS "label_videos_read" ON public.label_videos;
DROP POLICY IF EXISTS "label_videos_insert" ON public.label_videos;
DROP POLICY IF EXISTS "label_videos_update" ON public.label_videos;
DROP POLICY IF EXISTS "label_videos_delete" ON public.label_videos;
CREATE POLICY "label_videos_read" ON public.label_videos FOR SELECT TO authenticated
    USING ((SELECT private.is_labeler()) AND ((SELECT private.is_lead()) OR NOT private.label_session_protected(project, session_name)));
CREATE POLICY "label_videos_insert" ON public.label_videos FOR INSERT TO authenticated
    WITH CHECK ((SELECT private.is_labeler()) AND ((SELECT private.is_lead()) OR NOT private.label_session_protected(project, session_name)));
CREATE POLICY "label_videos_update" ON public.label_videos FOR UPDATE TO authenticated
    USING ((SELECT private.is_labeler()) AND ((SELECT private.is_lead()) OR NOT private.label_session_protected(project, session_name)))
    WITH CHECK ((SELECT private.is_labeler()) AND ((SELECT private.is_lead()) OR NOT private.label_session_protected(project, session_name)));
CREATE POLICY "label_videos_delete" ON public.label_videos FOR DELETE TO authenticated
    USING ((SELECT private.is_labeler()) AND ((SELECT private.is_lead()) OR NOT private.label_session_protected(project, session_name)));

-- Legacy annotations of a recording: only where the recording is readable.
DROP POLICY IF EXISTS "label_rally_times_labelers" ON public.label_rally_times;
CREATE POLICY "label_rally_times_labelers" ON public.label_rally_times FOR ALL TO authenticated
    USING ((SELECT private.is_labeler()) AND private.label_video_readable(video_id))
    WITH CHECK ((SELECT private.is_labeler()) AND private.label_video_readable(video_id));
DROP POLICY IF EXISTS "label_tracks_labelers" ON public.label_tracks;
CREATE POLICY "label_tracks_labelers" ON public.label_tracks FOR ALL TO authenticated
    USING ((SELECT private.is_labeler()) AND private.label_video_readable(video_id))
    WITH CHECK ((SELECT private.is_labeler()) AND private.label_video_readable(video_id));
DROP POLICY IF EXISTS "label_frame_log_select" ON public.label_frame_log;
CREATE POLICY "label_frame_log_select" ON public.label_frame_log FOR SELECT TO authenticated
    USING ((SELECT private.is_lead()) OR (labeler = (SELECT auth.uid()) AND private.label_track_readable(track)));

-- Storage: reading (and so signing), replacing and deleting a labeling object needs a readable row referencing it.
DROP POLICY IF EXISTS "labeling_select" ON storage.objects;
CREATE POLICY "labeling_select" ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'labeling' AND (SELECT private.is_labeler()) AND private.label_object_readable(name));
DROP POLICY IF EXISTS "labeling_update" ON storage.objects;
CREATE POLICY "labeling_update" ON storage.objects FOR UPDATE TO authenticated
    USING (bucket_id = 'labeling' AND (SELECT private.is_labeler()) AND private.label_object_readable(name))
    WITH CHECK (bucket_id = 'labeling' AND (SELECT private.is_labeler()));
DROP POLICY IF EXISTS "labeling_delete" ON storage.objects;
CREATE POLICY "labeling_delete" ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'labeling' AND (SELECT private.is_labeler()) AND private.label_object_readable(name));
