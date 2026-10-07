-- 029_labeler_builds.sql
--
-- Builds of the Labeler iPhone app (development-signed for registered
-- devices) and their install manifests, installed over the air from a
-- signed link (itms-services) — no TestFlight needed for an internal tool.
-- Private; only labelers can upload or make links.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('labeler-builds', 'labeler-builds', false, 104857600,
        ARRAY['application/octet-stream', 'application/xml', 'text/xml', 'text/html'])
ON CONFLICT (id) DO UPDATE
    SET public = false, file_size_limit = 104857600,
        allowed_mime_types = ARRAY['application/octet-stream', 'application/xml', 'text/xml', 'text/html'];

DROP POLICY IF EXISTS "labeler_builds_select" ON storage.objects;
CREATE POLICY "labeler_builds_select" ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'labeler-builds' AND (SELECT private.is_labeler()));
DROP POLICY IF EXISTS "labeler_builds_insert" ON storage.objects;
CREATE POLICY "labeler_builds_insert" ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'labeler-builds' AND (SELECT private.is_labeler()));
DROP POLICY IF EXISTS "labeler_builds_update" ON storage.objects;
CREATE POLICY "labeler_builds_update" ON storage.objects FOR UPDATE TO authenticated
    USING (bucket_id = 'labeler-builds' AND (SELECT private.is_labeler()))
    WITH CHECK (bucket_id = 'labeler-builds' AND (SELECT private.is_labeler()));
DROP POLICY IF EXISTS "labeler_builds_delete" ON storage.objects;
CREATE POLICY "labeler_builds_delete" ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'labeler-builds' AND (SELECT private.is_labeler()));
