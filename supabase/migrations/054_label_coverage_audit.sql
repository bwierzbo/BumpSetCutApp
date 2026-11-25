-- 054_label_coverage_audit.sql
--
-- The negative-coverage audit (D-038, G7) on the phone: one logical audit shared by RallyLab and the Labeler app.
-- The Mac's coverage_audit_v2 record (`<video>.coverageaudit.json`) stays the authority in meaning; the server holds
-- the same record, whole, so either device can carry on from the other. Nothing here derives an interval, judges a
-- verdict or decides what counts: both apps apply one set of rules (Labeler/Shared/CoverageAudit.swift) and the Mac
-- validates every synced record against them again before anything of it is used.
--
--   label_coverage_audit_draws       the frozen draw, byte for byte (`body`), and the SHA-256 of those bytes — the
--                                    identity every record is bound to. Published once by a lead; a different body
--                                    under a published draw id is refused (frozen).
--   label_coverage_audit_recordings  per drawn recording, what the Mac's admission found when it last published: the
--                                    recording's published copy (label_videos row), its original's content
--                                    fingerprint (= the draw's), the marks sidecar's SHA-256, and which of the draw's
--                                    intervals are still unmarked as drawn (`open_indices`). Lead-written only.
--   label_coverage_audits            the record per drawn recording, at a server revision (optimistic concurrency:
--                                    a stale revision is refused and comes back to the client as a conflict).
--   label_coverage_audit_uses        who opened which drawn recording for review, first time: the exposure ledger's
--                                    row for a review on the phone, written before a frame is shown; the Mac copies
--                                    it into its own ledger before it takes any verdict of that recording.
--
-- Writes go through the functions below only. First release (owner, 2026-11-17: "behind an appropriate owner/tester
-- control"): only a lead reads or writes any of it. Every read and every write is refused for a recording on its
-- project's withheld list, and for every recording of a project with no published list (unknown = withheld) — the
-- lead included, as for the Stage 1 records (048). Existing protections (048, 049) are unchanged.
--
-- A save refuses (each with the prefix the apps classify):
--   conflict:   the server's revision is not the one the record was loaded from;
--   withheld:   the recording is withheld, or its project has no published list;
--   identity:   the record names another draw, draw hash, recording, footage or marks than the published ones;
--   reviewer:   it adds, changes or removes a look that is not the caller's own (a look is its reviewer's), or a look
--               stamped in the future;
--   interval:   it adds or changes a look on an interval the Mac no longer publishes as unmarked as drawn, or a first
--               look whose ticks are not the draw's.
-- What a look must hold (clean only played whole, findings well-formed, the 24-hour wait, …) is the apps' rule and the
-- Mac's validation, not re-implemented here.

CREATE TABLE IF NOT EXISTS public.label_coverage_audit_draws (
    project      text NOT NULL,
    draw_id      text NOT NULL,
    draw_sha256  text NOT NULL,
    body         text NOT NULL,
    published_by uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    published_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project, draw_id)
);

CREATE TABLE IF NOT EXISTS public.label_coverage_audit_recordings (
    project            text NOT NULL,
    draw_id            text NOT NULL,
    recording_id       text NOT NULL,
    video_id           uuid NOT NULL REFERENCES public.label_videos(id) ON DELETE CASCADE,
    source_fingerprint text NOT NULL,
    marks_sha256       text NOT NULL,
    open_indices       integer[] NOT NULL DEFAULT '{}',
    published_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    published_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project, draw_id, recording_id),
    FOREIGN KEY (project, draw_id) REFERENCES public.label_coverage_audit_draws(project, draw_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS label_coverage_audit_recordings_video_idx ON public.label_coverage_audit_recordings (video_id);

CREATE TABLE IF NOT EXISTS public.label_coverage_audits (
    project      text NOT NULL,
    draw_id      text NOT NULL,
    recording_id text NOT NULL,
    -- The coverage_audit_v2 record as the apps write it (camelCase keys, CoverageAudit.File).
    record       jsonb NOT NULL,
    revision     integer NOT NULL DEFAULT 1,
    updated_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project, draw_id, recording_id),
    FOREIGN KEY (project, draw_id, recording_id)
        REFERENCES public.label_coverage_audit_recordings(project, draw_id, recording_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS label_coverage_audits_updated_at_idx ON public.label_coverage_audits (updated_at);

CREATE TABLE IF NOT EXISTS public.label_coverage_audit_uses (
    project      text NOT NULL,
    draw_id      text NOT NULL,
    recording_id text NOT NULL,
    reviewer     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    first_used_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project, draw_id, recording_id, reviewer),
    FOREIGN KEY (project, draw_id, recording_id)
        REFERENCES public.label_coverage_audit_recordings(project, draw_id, recording_id) ON DELETE CASCADE
);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['label_coverage_audit_draws', 'label_coverage_audit_recordings', 'label_coverage_audits', 'label_coverage_audit_uses'] LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.%I FROM authenticated', t);
    END LOOP;
END $$;

-- Reads: a lead, and only while the recording is not protected (049's rule, judged at read time).
DROP POLICY IF EXISTS "label_coverage_audit_draws_lead_read" ON public.label_coverage_audit_draws;
CREATE POLICY "label_coverage_audit_draws_lead_read" ON public.label_coverage_audit_draws FOR SELECT TO authenticated
    USING ((SELECT private.is_lead()));
DROP POLICY IF EXISTS "label_coverage_audit_recordings_lead_read" ON public.label_coverage_audit_recordings;
CREATE POLICY "label_coverage_audit_recordings_lead_read" ON public.label_coverage_audit_recordings FOR SELECT TO authenticated
    USING ((SELECT private.is_lead()) AND NOT private.label_session_protected(project, recording_id));
DROP POLICY IF EXISTS "label_coverage_audits_lead_read" ON public.label_coverage_audits;
CREATE POLICY "label_coverage_audits_lead_read" ON public.label_coverage_audits FOR SELECT TO authenticated
    USING ((SELECT private.is_lead()) AND NOT private.label_session_protected(project, recording_id));
DROP POLICY IF EXISTS "label_coverage_audit_uses_lead_read" ON public.label_coverage_audit_uses;
CREATE POLICY "label_coverage_audit_uses_lead_read" ON public.label_coverage_audit_uses FOR SELECT TO authenticated
    USING ((SELECT private.is_lead()) AND NOT private.label_session_protected(project, recording_id));

-- The refusals every function below shares: a lead, a published draw, a recording of it that is not protected.
CREATE OR REPLACE FUNCTION private.coverage_audit_require(p_project text, p_draw text, p_recording text) RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF NOT (SELECT private.is_lead()) THEN
        RAISE EXCEPTION 'coverage audit: leads only in this release' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.label_coverage_audit_draws WHERE project = p_project AND draw_id = p_draw) THEN
        RAISE EXCEPTION 'identity: draw % of % is not published', p_draw, p_project USING ERRCODE = '22023';
    END IF;
    IF p_recording IS NOT NULL AND private.label_session_protected(p_project, p_recording) THEN
        RAISE EXCEPTION 'withheld: % is withheld, or % has no published withheld list', p_recording, p_project USING ERRCODE = '42501';
    END IF;
END;
$$;

-- The draw's entry for one recording (its JSON object), or NULL.
CREATE OR REPLACE FUNCTION private.coverage_audit_drawn(p_project text, p_draw text, p_recording text) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT r FROM public.label_coverage_audit_draws d, jsonb_array_elements(d.body::jsonb -> 'recordings') r
     WHERE d.project = p_project AND d.draw_id = p_draw AND r ->> 'recordingId' = p_recording
$$;

-- Publish a frozen draw (leads): its file's bytes, exactly. The same bytes again change nothing; other bytes under a
-- published draw id are refused — a draw is frozen, a change is a new draw. Returns the SHA-256 of the bytes.
CREATE OR REPLACE FUNCTION public.coverage_audit_publish_draw(p_project text, p_body text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_sha text;
    v_id text;
    v_have text;
BEGIN
    IF NOT (SELECT private.is_lead()) THEN
        RAISE EXCEPTION 'coverage audit: leads only in this release' USING ERRCODE = '42501';
    END IF;
    IF p_project IS NULL OR p_project = '' OR p_body IS NULL THEN
        RAISE EXCEPTION 'coverage_audit_publish_draw: a project and a body are required' USING ERRCODE = '22023';
    END IF;
    IF coalesce(p_body::jsonb ->> 'schemaVersion', '') <> 'coverage_audit_draw_v2' THEN
        RAISE EXCEPTION 'coverage_audit_publish_draw: schemaVersion % is not accepted', coalesce(p_body::jsonb ->> 'schemaVersion', '(none)') USING ERRCODE = '22023';
    END IF;
    v_id := coalesce(p_body::jsonb ->> 'drawId', '');
    IF v_id = '' THEN
        RAISE EXCEPTION 'coverage_audit_publish_draw: the draw has no drawId' USING ERRCODE = '22023';
    END IF;
    v_sha := encode(sha256(convert_to(p_body, 'UTF8')), 'hex');
    SELECT draw_sha256 INTO v_have FROM public.label_coverage_audit_draws WHERE project = p_project AND draw_id = v_id;
    IF FOUND THEN
        IF v_have <> v_sha THEN
            RAISE EXCEPTION 'frozen: draw % is published with SHA-256 %, not %', v_id, v_have, v_sha USING ERRCODE = '22023';
        END IF;
        RETURN v_sha;
    END IF;
    INSERT INTO public.label_coverage_audit_draws (project, draw_id, draw_sha256, body) VALUES (p_project, v_id, v_sha, p_body);
    RETURN v_sha;
END;
$$;

-- Publish what the Mac's admission found for drawn recordings (leads): `p_rows` is a JSON array of
-- {recordingId, videoId, sourceFingerprint, marksSha256, openIndices}. Each row must name a drawn recording that is
-- not protected, its published copy (that recording's label_videos row, whose original fingerprint it carries) and the
-- draw's content fingerprint for it; open indices must be the draw's. Rows not named are left as they are.
CREATE OR REPLACE FUNCTION public.coverage_audit_publish_recordings(p_project text, p_draw text, p_rows jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_row jsonb;
    v_rec text;
    v_drawn jsonb;
    v_video uuid;
    v_open integer[];
    n integer := 0;
BEGIN
    PERFORM private.coverage_audit_require(p_project, p_draw, NULL);
    FOR v_row IN SELECT * FROM jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) LOOP
        v_rec := coalesce(v_row ->> 'recordingId', '');
        PERFORM private.coverage_audit_require(p_project, p_draw, v_rec);
        v_drawn := private.coverage_audit_drawn(p_project, p_draw, v_rec);
        IF v_drawn IS NULL THEN
            RAISE EXCEPTION 'identity: % is not a recording of draw %', v_rec, p_draw USING ERRCODE = '22023';
        END IF;
        IF coalesce(v_row ->> 'sourceFingerprint', '') = '' OR v_row ->> 'sourceFingerprint' <> v_drawn ->> 'contentFingerprint' THEN
            RAISE EXCEPTION 'identity: % is footage %, not the draw''s %', v_rec, coalesce(v_row ->> 'sourceFingerprint', '(none)'), v_drawn ->> 'contentFingerprint' USING ERRCODE = '22023';
        END IF;
        v_video := (v_row ->> 'videoId')::uuid;
        IF NOT EXISTS (SELECT 1 FROM public.label_videos v WHERE v.id = v_video AND v.project = p_project AND v.session_name = v_rec
                                                           AND v.source_fingerprint = v_row ->> 'sourceFingerprint') THEN
            RAISE EXCEPTION 'identity: % has no published copy of footage %', v_rec, v_row ->> 'sourceFingerprint' USING ERRCODE = '22023';
        END IF;
        IF coalesce(v_row ->> 'marksSha256', '') = '' THEN
            RAISE EXCEPTION 'identity: % has no marks hash', v_rec USING ERRCODE = '22023';
        END IF;
        SELECT coalesce(array_agg(x::integer ORDER BY x::integer), '{}') INTO v_open FROM jsonb_array_elements_text(coalesce(v_row -> 'openIndices', '[]')) x;
        IF EXISTS (SELECT 1 FROM unnest(v_open) i WHERE i < 0 OR i >= jsonb_array_length(v_drawn -> 'intervals')) THEN
            RAISE EXCEPTION 'interval: % lists an open interval the draw does not have', v_rec USING ERRCODE = '22023';
        END IF;
        INSERT INTO public.label_coverage_audit_recordings (project, draw_id, recording_id, video_id, source_fingerprint, marks_sha256, open_indices, published_by, published_at)
            VALUES (p_project, p_draw, v_rec, v_video, v_row ->> 'sourceFingerprint', v_row ->> 'marksSha256', v_open, (SELECT auth.uid()), now())
            ON CONFLICT (project, draw_id, recording_id) DO UPDATE
               SET video_id = excluded.video_id, source_fingerprint = excluded.source_fingerprint, marks_sha256 = excluded.marks_sha256,
                   open_indices = excluded.open_indices, published_by = excluded.published_by, published_at = excluded.published_at
             WHERE (label_coverage_audit_recordings.video_id, label_coverage_audit_recordings.source_fingerprint,
                    label_coverage_audit_recordings.marks_sha256, label_coverage_audit_recordings.open_indices)
                   IS DISTINCT FROM (excluded.video_id, excluded.source_fingerprint, excluded.marks_sha256, excluded.open_indices);
        n := n + 1;
    END LOOP;
    RETURN n;
END;
$$;

-- A drawn recording opened for review on a device: the use, on the server's ledger, before a frame is shown. A repeat
-- changes nothing (the first use is the one kept).
CREATE OR REPLACE FUNCTION public.coverage_audit_open(p_project text, p_draw text, p_recording text) RETURNS timestamptz
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_at timestamptz;
BEGIN
    PERFORM private.coverage_audit_require(p_project, p_draw, p_recording);
    IF NOT EXISTS (SELECT 1 FROM public.label_coverage_audit_recordings WHERE project = p_project AND draw_id = p_draw AND recording_id = p_recording) THEN
        RAISE EXCEPTION 'identity: % of draw % is not published for review', p_recording, p_draw USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.label_coverage_audit_uses (project, draw_id, recording_id, reviewer) VALUES (p_project, p_draw, p_recording, (SELECT auth.uid()))
        ON CONFLICT DO NOTHING;
    SELECT first_used_at INTO v_at FROM public.label_coverage_audit_uses
     WHERE project = p_project AND draw_id = p_draw AND recording_id = p_recording AND reviewer = (SELECT auth.uid());
    RETURN v_at;
END;
$$;

-- One pass's looks by interval index: {"<index>": look}. A look's empty findings and absent fields read the same.
CREATE OR REPLACE FUNCTION private.coverage_audit_looks(p_looks jsonb) RETURNS TABLE (idx integer, look jsonb)
    LANGUAGE sql IMMUTABLE SET search_path = ''
AS $$
    SELECT (l ->> 'index')::integer, jsonb_strip_nulls(l) || jsonb_build_object('findings', coalesce(l -> 'findings', '[]'::jsonb))
      FROM jsonb_array_elements(coalesce(p_looks, '[]'::jsonb)) l
$$;

-- Save a drawn recording's record at an expected revision (0 = none on the server yet). Returns the row as saved.
CREATE OR REPLACE FUNCTION public.coverage_audit_save(p_project text, p_draw text, p_recording text, p_expected integer, p_record jsonb)
    RETURNS SETOF public.label_coverage_audits
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_me text := (SELECT auth.uid())::text;
    v_state public.label_coverage_audit_recordings;
    v_sha text;
    v_drawn jsonb;
    v_old jsonb;
    v_current integer;
    v_pass record;
    v_change record;
BEGIN
    PERFORM private.coverage_audit_require(p_project, p_draw, p_recording);
    -- The published recording's row is locked first: every save of one recording runs one at a time, the first save
    -- (no record yet, so nothing else to lock) included — a second save made on revision 0 meets the first's record.
    SELECT * INTO v_state FROM public.label_coverage_audit_recordings WHERE project = p_project AND draw_id = p_draw AND recording_id = p_recording FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'identity: % of draw % is not published for review', p_recording, p_draw USING ERRCODE = '22023';
    END IF;
    SELECT draw_sha256 INTO v_sha FROM public.label_coverage_audit_draws WHERE project = p_project AND draw_id = p_draw;
    v_drawn := private.coverage_audit_drawn(p_project, p_draw, p_recording);
    IF coalesce(p_record ->> 'annotationVersion', '') <> 'coverage_audit_v2' THEN
        RAISE EXCEPTION 'identity: annotationVersion % is not accepted', coalesce(p_record ->> 'annotationVersion', '(none)') USING ERRCODE = '22023';
    END IF;
    IF coalesce(p_record ->> 'recordingId', '') <> p_recording OR coalesce(p_record ->> 'drawId', '') <> p_draw
       OR coalesce(p_record ->> 'drawSha256', '') <> v_sha THEN
        RAISE EXCEPTION 'identity: the record is of %/% (draw hash %), not %/% (%)', p_record ->> 'drawId', p_record ->> 'recordingId',
            p_record ->> 'drawSha256', p_draw, p_recording, v_sha USING ERRCODE = '22023';
    END IF;
    IF coalesce(p_record ->> 'sourceFingerprint', '') <> v_state.source_fingerprint THEN
        RAISE EXCEPTION 'identity: the record describes footage %, but % is %', coalesce(p_record ->> 'sourceFingerprint', '(none)'), p_recording, v_state.source_fingerprint USING ERRCODE = '22023';
    END IF;
    IF coalesce(p_record ->> 'marksSha256', '') <> v_state.marks_sha256 THEN
        RAISE EXCEPTION 'identity: the record was made over marks %, but % has marks % now', coalesce(p_record ->> 'marksSha256', '(none)'), p_recording, v_state.marks_sha256 USING ERRCODE = '22023';
    END IF;
    IF (p_record ->> 'blindToPipeline') IS DISTINCT FROM 'true' OR (p_record ->> 'timescale') IS DISTINCT FROM '600' THEN
        RAISE EXCEPTION 'identity: the record is not blind to the pipeline at timescale 600' USING ERRCODE = '22023';
    END IF;

    SELECT revision, record INTO v_current, v_old FROM public.label_coverage_audits
     WHERE project = p_project AND draw_id = p_draw AND recording_id = p_recording FOR UPDATE;
    IF NOT FOUND THEN v_current := 0; v_old := '{}'::jsonb; END IF;
    IF v_current <> p_expected THEN
        RAISE EXCEPTION 'conflict: the record changed on the server (revision %, expected %)', v_current, p_expected USING ERRCODE = 'P0001';
    END IF;

    -- Every look that differs from the server's: the caller's own on both sides, on an open interval, not stamped ahead.
    FOR v_pass IN SELECT * FROM (VALUES ('intervals', v_old -> 'intervals', p_record -> 'intervals', 'reviewedAt'),
                                        ('repeat', v_old -> 'repeat' -> 'intervals', p_record -> 'repeat' -> 'intervals', 'reviewedAt'),
                                        ('resolutions', v_old -> 'resolutions', p_record -> 'resolutions', 'resolvedAt')) AS p(name, old_looks, new_looks, stamp) LOOP
        FOR v_change IN
            SELECT coalesce(o.idx, n.idx) AS idx, o.look AS old_look, n.look AS new_look
              FROM private.coverage_audit_looks(v_pass.old_looks) o
              FULL JOIN private.coverage_audit_looks(v_pass.new_looks) n ON o.idx = n.idx
             WHERE o.look IS DISTINCT FROM n.look
        LOOP
            IF v_change.old_look IS NOT NULL AND v_change.old_look ->> 'reviewer' <> v_me THEN
                RAISE EXCEPTION 'reviewer: interval % (%) is %''s look; only they change or withdraw it', v_change.idx, v_pass.name, v_change.old_look ->> 'reviewer' USING ERRCODE = '42501';
            END IF;
            IF v_change.new_look IS NOT NULL THEN
                IF v_change.new_look ->> 'reviewer' IS DISTINCT FROM v_me THEN
                    RAISE EXCEPTION 'reviewer: interval % (%) is given as %''s look by %', v_change.idx, v_pass.name, v_change.new_look ->> 'reviewer', v_me USING ERRCODE = '42501';
                END IF;
                IF (v_change.new_look ->> v_pass.stamp)::timestamptz > now() + interval '5 minutes' THEN
                    RAISE EXCEPTION 'reviewer: interval % (%) is stamped %, in the future', v_change.idx, v_pass.name, v_change.new_look ->> v_pass.stamp USING ERRCODE = '22023';
                END IF;
                IF NOT (v_change.idx = ANY (v_state.open_indices)) THEN
                    RAISE EXCEPTION 'interval: interval % of % is no longer unmarked as drawn', v_change.idx, p_recording USING ERRCODE = '22023';
                END IF;
                IF v_pass.name = 'intervals' AND (
                    (v_change.new_look ->> 'startTick')::integer IS DISTINCT FROM (v_drawn -> 'intervals' -> v_change.idx ->> 'startTick')::integer
                    OR (v_change.new_look ->> 'endTick')::integer IS DISTINCT FROM (v_drawn -> 'intervals' -> v_change.idx ->> 'endTick')::integer) THEN
                    RAISE EXCEPTION 'interval: interval % of % is not the draw''s ticks', v_change.idx, p_recording USING ERRCODE = '22023';
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    INSERT INTO public.label_coverage_audit_uses (project, draw_id, recording_id, reviewer) VALUES (p_project, p_draw, p_recording, (SELECT auth.uid()))
        ON CONFLICT DO NOTHING;
    IF v_current = 0 THEN
        -- No ON CONFLICT: a record that appeared meanwhile is an error, never overwritten.
        INSERT INTO public.label_coverage_audits (project, draw_id, recording_id, record, revision, updated_by, updated_at)
            VALUES (p_project, p_draw, p_recording, p_record, 1, (SELECT auth.uid()), now());
    ELSE
        UPDATE public.label_coverage_audits SET record = p_record, revision = v_current + 1, updated_by = (SELECT auth.uid()), updated_at = now()
         WHERE project = p_project AND draw_id = p_draw AND recording_id = p_recording AND revision = v_current;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'conflict: the record changed on the server (expected revision %)', v_current USING ERRCODE = 'P0001';
        END IF;
    END IF;
    RETURN QUERY SELECT * FROM public.label_coverage_audits WHERE project = p_project AND draw_id = p_draw AND recording_id = p_recording;
END;
$$;

REVOKE ALL ON FUNCTION private.coverage_audit_require(text, text, text), private.coverage_audit_drawn(text, text, text),
                       private.coverage_audit_looks(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.coverage_audit_publish_draw(text, text), public.coverage_audit_publish_recordings(text, text, jsonb),
                       public.coverage_audit_open(text, text, text), public.coverage_audit_save(text, text, text, integer, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.coverage_audit_publish_draw(text, text), public.coverage_audit_publish_recordings(text, text, jsonb),
                          public.coverage_audit_open(text, text, text), public.coverage_audit_save(text, text, text, integer, jsonb) TO authenticated;

-- Live notices as for the other labeling tables (045): a tiny broadcast, no row data.
DROP TRIGGER IF EXISTS label_coverage_audits_live ON public.label_coverage_audits;
CREATE TRIGGER label_coverage_audits_live AFTER INSERT OR UPDATE OR DELETE ON public.label_coverage_audits
    FOR EACH STATEMENT EXECUTE FUNCTION private.notify_labeling();
DROP TRIGGER IF EXISTS label_coverage_audit_recordings_live ON public.label_coverage_audit_recordings;
CREATE TRIGGER label_coverage_audit_recordings_live AFTER INSERT OR UPDATE OR DELETE ON public.label_coverage_audit_recordings
    FOR EACH STATEMENT EXECUTE FUNCTION private.notify_labeling();
