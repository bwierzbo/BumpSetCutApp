-- 049_label_pilot.sql
--
-- The frozen 24-rally pilot draw (D-004; RallyLab `--pilot-freeze`), delivered to the phone read-only so the formal
-- Mac/iPhone comparison never depends on copying windows by hand. A draw is published once by a lead, as frozen:
-- its id, the SHA-256 of the frozen record file on the Mac, and the selection (which recording and legacy mark,
-- the frozen window, the stratum, the repeat flag). The server stores its own digest of the selection it received,
-- so the phone shows exactly which draw it holds. Rows are never updated or deleted through the API: a new draw is
-- a new row (append-only, as the Mac's records are). Labelers read; nobody writes directly.
--
-- Depends on 048 (label_withheld, label_withheld_lists): a selection may not name a withheld recording, and a
-- labeler reads a draw only while its project's withheld list is published.

CREATE TABLE IF NOT EXISTS public.label_pilot_records (
    id               text PRIMARY KEY,
    project          text NOT NULL,
    record_sha256    text NOT NULL CHECK (record_sha256 ~ '^[0-9a-f]{64}$'),
    selection        jsonb NOT NULL CHECK (jsonb_typeof(selection) = 'array'),
    selection_digest text NOT NULL,
    published_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    published_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.label_pilot_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.label_pilot_records FROM anon;

DROP POLICY IF EXISTS "label_pilot_records_labelers_read" ON public.label_pilot_records;
CREATE POLICY "label_pilot_records_labelers_read" ON public.label_pilot_records FOR SELECT TO authenticated
    USING (
        (SELECT private.is_labeler())
        AND EXISTS (SELECT 1 FROM public.label_withheld_lists l WHERE l.project = label_pilot_records.project)
    );

-- Publish a frozen draw (leads only). Refuses an id that exists (a draw is never changed), an empty or malformed
-- selection, and any selected recording that is on the project's withheld list or of a project without one.
CREATE OR REPLACE FUNCTION public.label_pilot_publish(p_id text, p_project text, p_record_sha256 text, p_selection jsonb)
    RETURNS public.label_pilot_records
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_row public.label_pilot_records;
    v_bad text;
BEGIN
    IF NOT (SELECT private.is_lead()) THEN
        RAISE EXCEPTION 'label_pilot_publish: leads only' USING ERRCODE = '42501';
    END IF;
    IF p_id IS NULL OR p_id = '' OR p_project IS NULL OR p_project = '' THEN
        RAISE EXCEPTION 'label_pilot_publish: an id and a project are required' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.label_pilot_records WHERE id = p_id) THEN
        RAISE EXCEPTION 'label_pilot_publish: % is published already; a frozen draw is never changed', p_id USING ERRCODE = '23505';
    END IF;
    IF p_selection IS NULL OR jsonb_typeof(p_selection) <> 'array' OR jsonb_array_length(p_selection) = 0 THEN
        RAISE EXCEPTION 'label_pilot_publish: the selection must be a non-empty array' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_selection) e
                WHERE NOT (coalesce(e->>'video', '') <> ''
                           AND jsonb_typeof(e->'legacyIndex') IS NOT DISTINCT FROM 'number'
                           AND CASE WHEN jsonb_typeof(e->'window') = 'array' THEN jsonb_array_length(e->'window') = 2 ELSE false END)) THEN
        RAISE EXCEPTION 'label_pilot_publish: every selected rally needs video, legacyIndex and a [start, end] window' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.label_withheld_lists WHERE project = p_project) THEN
        RAISE EXCEPTION 'withheld: project % has no published withheld list', p_project USING ERRCODE = '42501';
    END IF;
    SELECT e->>'video' INTO v_bad FROM jsonb_array_elements(p_selection) e
     WHERE EXISTS (SELECT 1 FROM public.label_withheld w WHERE w.project = p_project AND w.session_name = e->>'video') LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'withheld: the selection names %, a withheld recording', v_bad USING ERRCODE = '42501';
    END IF;
    INSERT INTO public.label_pilot_records (id, project, record_sha256, selection, selection_digest, published_by, published_at)
        VALUES (p_id, p_project, p_record_sha256, p_selection, encode(sha256(convert_to(p_selection::text, 'UTF8')), 'hex'), (SELECT auth.uid()), now())
        RETURNING * INTO v_row;
    RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.label_pilot_publish(text, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.label_pilot_publish(text, text, text, jsonb) TO authenticated;

DROP TRIGGER IF EXISTS label_pilot_records_live ON public.label_pilot_records;
CREATE TRIGGER label_pilot_records_live AFTER INSERT OR UPDATE OR DELETE ON public.label_pilot_records
    FOR EACH STATEMENT EXECUTE FUNCTION private.notify_labeling();
