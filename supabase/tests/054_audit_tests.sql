-- Tests for 054_label_coverage_audit, on a fresh database: stubs, 048, 049, 054 (supabase/tests/run_048_tests.sh).
-- Leads only, the frozen draw, the published recording state, the use ledger, and every refusal of a save — as the
-- API's roles. Synthetic records only. Every check raises on failure; the run ends with 'ALL 054 AUDIT TESTS PASSED'.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- People: L and K leads (the owner's Mac and phone are both L; K another lead), M a labeler.
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000b'), ('00000000-0000-0000-0000-00000000000e');
INSERT INTO public.labelers VALUES ('00000000-0000-0000-0000-00000000000a', true), ('00000000-0000-0000-0000-00000000000b', false),
                                   ('00000000-0000-0000-0000-00000000000e', true);
INSERT INTO public.label_videos (id, project, session_name, source_fingerprint) VALUES
  ('10000000-0000-0000-0000-00000000000a', 'Scratch', 'a', 'file:a'),
  ('10000000-0000-0000-0000-0000000000f1', 'Scratch', 'w', 'file:w');
INSERT INTO public.label_withheld_lists (project, names) VALUES ('Scratch', 1);
INSERT INTO public.label_withheld (project, session_name) VALUES ('Scratch', 'w');

CREATE FUNCTION pg_temp.expect(q text, code text, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN EXECUTE q;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> code OR position(msg IN SQLERRM) = 0 THEN RAISE EXCEPTION 'FAIL: % → % % (wanted % containing "%")', q, SQLSTATE, SQLERRM, code, msg; END IF;
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: % succeeded (wanted %)', q, code;
END $$;
CREATE FUNCTION pg_temp.check(ok boolean, what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT coalesce(ok, false) THEN RAISE EXCEPTION 'FAIL: %', what; END IF; END $$;
CREATE FUNCTION pg_temp.as_(who text) RETURNS void LANGUAGE sql AS $$
    SELECT set_config('request.jwt.claim.sub', CASE who WHEN 'L' THEN '00000000-0000-0000-0000-00000000000a' WHEN 'M' THEN '00000000-0000-0000-0000-00000000000b'
                                                        ELSE '00000000-0000-0000-0000-00000000000e' END, false) $$;
-- A record of recording `rec` with these first looks (JSON array), over marks `marks`.
CREATE FUNCTION pg_temp.rec(looks jsonb, marks text DEFAULT 'm1', sha text DEFAULT NULL, src text DEFAULT 'file:a', rec text DEFAULT 'a') RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object('annotationVersion', 'coverage_audit_v2', 'recordingId', rec, 'sourceFingerprint', src, 'drawId', 'd1',
        'drawSha256', coalesce(sha, (SELECT draw_sha256 FROM public.label_coverage_audit_draws WHERE draw_id = 'd1')), 'datasetName', 'rc-test',
        'marksSha256', marks, 'timescale', 600, 'blindToPipeline', true, 'tool', 'test', 'intervals', looks, 'resolutions', '[]'::jsonb) $$;
CREATE FUNCTION pg_temp.look(idx int, s int, e int, who text, at text DEFAULT '2026-11-17T10:00:00Z') RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object('index', idx, 'startTick', s, 'endTick', e, 'verdict', 'clean', 'playedAllAtMaxRate', 2, 'findings', '[]'::jsonb,
        'reviewedAt', at, 'reviewer', CASE who WHEN 'L' THEN '00000000-0000-0000-0000-00000000000a' ELSE '00000000-0000-0000-0000-00000000000e' END) $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon;

\set body '{"schemaVersion":"coverage_audit_draw_v2","drawId":"d1","dataset":{"name":"rc-test","timescale":600},"recordings":[{"recordingId":"a","groupId":"g","contentFingerprint":"file:a","marksSha256":"m0","durationTicks":6000,"intervals":[{"index":0,"startTick":0,"endTick":600},{"index":1,"startTick":1200,"endTick":3000},{"index":2,"startTick":4000,"endTick":6000}],"repeatIndices":[1]},{"recordingId":"w","groupId":"h","contentFingerprint":"file:w","marksSha256":"m0","durationTicks":600,"intervals":[{"index":0,"startTick":0,"endTick":600}],"repeatIndices":[]}]}'
SET ROLE authenticated;

-- 1. A labeler who is not a lead: nothing (first release: leads only).
SELECT pg_temp.as_('M');
SELECT pg_temp.expect(format('SELECT public.coverage_audit_publish_draw(%L, %L)', 'Scratch', :'body'), '42501', 'leads only');

-- 2. The draw: published by a lead, its bytes' SHA-256 returned and kept; the same bytes again are fine; other bytes are frozen out.
SELECT pg_temp.as_('L');
SELECT pg_temp.check(public.coverage_audit_publish_draw('Scratch', :'body') = encode(sha256(convert_to(:'body', 'UTF8')), 'hex'), 'the draw''s hash is its bytes''');
SELECT pg_temp.check(public.coverage_audit_publish_draw('Scratch', :'body') = encode(sha256(convert_to(:'body', 'UTF8')), 'hex'), 'republishing the same bytes');
SELECT pg_temp.expect(format('SELECT public.coverage_audit_publish_draw(%L, %L)', 'Scratch', :'body' || ' '), '22023', 'frozen');
SELECT pg_temp.expect(format('SELECT public.coverage_audit_publish_draw(%L, %L)', 'Scratch', '{"schemaVersion":"other","drawId":"d2"}'), '22023', 'schemaVersion');
SELECT pg_temp.check((SELECT count(*) FROM public.label_coverage_audit_draws) = 1, 'a lead reads the draw');

-- 3. The recordings' state: a withheld recording, other footage, no copy, an interval the draw lacks — refused; the right row taken.
SELECT pg_temp.expect($q$SELECT public.coverage_audit_publish_recordings('Scratch', 'd1', '[{"recordingId":"w","videoId":"10000000-0000-0000-0000-0000000000f1","sourceFingerprint":"file:w","marksSha256":"m1","openIndices":[0]}]')$q$, '42501', 'withheld');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_publish_recordings('Scratch', 'd1', '[{"recordingId":"a","videoId":"10000000-0000-0000-0000-00000000000a","sourceFingerprint":"file:x","marksSha256":"m1","openIndices":[0]}]')$q$, '22023', 'identity');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_publish_recordings('Scratch', 'd1', '[{"recordingId":"a","videoId":"10000000-0000-0000-0000-0000000000f1","sourceFingerprint":"file:a","marksSha256":"m1","openIndices":[0]}]')$q$, '22023', 'no published copy');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_publish_recordings('Scratch', 'd1', '[{"recordingId":"a","videoId":"10000000-0000-0000-0000-00000000000a","sourceFingerprint":"file:a","marksSha256":"m1","openIndices":[3]}]')$q$, '22023', 'interval');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_publish_recordings('Scratch', 'd1', '[{"recordingId":"zz","videoId":"10000000-0000-0000-0000-00000000000a","sourceFingerprint":"file:a","marksSha256":"m1","openIndices":[0]}]')$q$, '22023', 'not a recording');
SELECT pg_temp.check(public.coverage_audit_publish_recordings('Scratch', 'd1', '[{"recordingId":"a","videoId":"10000000-0000-0000-0000-00000000000a","sourceFingerprint":"file:a","marksSha256":"m1","openIndices":[0,1]}]') = 1, 'state published');
SELECT pg_temp.as_('M');
SELECT pg_temp.check((SELECT count(*) FROM public.label_coverage_audit_recordings) = 0 AND (SELECT count(*) FROM public.label_coverage_audit_draws) = 0, 'a labeler reads nothing');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_open('Scratch', 'd1', 'a')$q$, '42501', 'leads only');

-- 4. Opening: the use is on the ledger before review, once per reviewer.
SELECT pg_temp.as_('L');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_open('Scratch', 'd1', 'w')$q$, '42501', 'withheld');
SELECT public.coverage_audit_open('Scratch', 'd1', 'a');
SELECT public.coverage_audit_open('Scratch', 'd1', 'a');
SELECT pg_temp.check((SELECT count(*) FROM public.label_coverage_audit_uses) = 1, 'one use row per reviewer');

-- 5. Saves: the first at revision 0, then each at the revision it was loaded from.
SELECT pg_temp.check((SELECT revision FROM public.coverage_audit_save('Scratch', 'd1', 'a', 0, pg_temp.rec(jsonb_build_array(pg_temp.look(0, 0, 600, 'L'))))) = 1, 'first save → revision 1');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 0, pg_temp.rec(jsonb_build_array(pg_temp.look(0, 0, 600, 'L')))) $q$, 'P0001', 'conflict');
-- The same record again at its revision (a retry after a lost reply would carry the new revision): accepted, nothing of anyone else's touched.
SELECT pg_temp.check((SELECT revision FROM public.coverage_audit_save('Scratch', 'd1', 'a', 1, pg_temp.rec(jsonb_build_array(pg_temp.look(0, 0, 600, 'L'))))) = 2, 'same content → revision 2');

-- 6. Identity: another draw hash, other footage, stale marks, not blind.
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 2, pg_temp.rec('[]', 'm1', 'beef'))$q$, '22023', 'identity');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 2, pg_temp.rec('[]', 'm1', NULL, 'file:x'))$q$, '22023', 'describes footage');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 2, pg_temp.rec('[]', 'm0'))$q$, '22023', 'marks');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 2, pg_temp.rec('[]') || '{"blindToPipeline":false}')$q$, '22023', 'blind');

-- 7. Looks: another person's, given in another's name, stamped ahead, on a closed interval, on the wrong ticks.
SELECT pg_temp.as_('K');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 2, pg_temp.rec('[]'))$q$, '42501', 'only they change or withdraw it');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 2, pg_temp.rec(jsonb_build_array(pg_temp.look(0, 0, 600, 'L'), pg_temp.look(1, 1200, 3000, 'L'))))$q$, '42501', 'reviewer');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 2, pg_temp.rec(jsonb_build_array(pg_temp.look(0, 0, 600, 'L'), pg_temp.look(1, 1200, 3000, 'K', '2099-01-01T00:00:00Z'))))$q$, '22023', 'future');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 2, pg_temp.rec(jsonb_build_array(pg_temp.look(0, 0, 600, 'L'), pg_temp.look(2, 4000, 6000, 'K'))))$q$, '22023', 'no longer unmarked');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 2, pg_temp.rec(jsonb_build_array(pg_temp.look(0, 0, 600, 'L'), pg_temp.look(1, 1200, 2999, 'K'))))$q$, '22023', 'draw''s ticks');
-- K's own look next to L's, untouched: accepted. (L's look re-encoded with its findings left out reads the same.)
SELECT pg_temp.check((SELECT revision FROM public.coverage_audit_save('Scratch', 'd1', 'a', 2,
    pg_temp.rec(jsonb_build_array(pg_temp.look(0, 0, 600, 'L') - 'findings', pg_temp.look(1, 1200, 3000, 'K'))))) = 3, 'a second lead adds their own look');
SELECT pg_temp.check((SELECT count(*) FROM public.label_coverage_audit_uses) = 2, 'the save put K''s use on the ledger');
SELECT pg_temp.as_('L');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 3, pg_temp.rec(jsonb_build_array(pg_temp.look(0, 0, 600, 'L'))))$q$, '42501', 'only they change or withdraw it');

-- 8. Withheld after the fact: the recording disappears from every read and every save at once — the lead's included.
RESET ROLE;
INSERT INTO public.label_withheld (project, session_name) VALUES ('Scratch', 'a');
SET ROLE authenticated;
SELECT pg_temp.as_('L');
SELECT pg_temp.check((SELECT count(*) FROM public.label_coverage_audits) = 0 AND (SELECT count(*) FROM public.label_coverage_audit_recordings) = 0, 'withheld: nothing read');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 3, pg_temp.rec(jsonb_build_array(pg_temp.look(0, 0, 600, 'L'), pg_temp.look(1, 1200, 3000, 'K'))))$q$, '42501', 'withheld');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_open('Scratch', 'd1', 'a')$q$, '42501', 'withheld');

-- 9. Nothing is written directly, and anon has nothing.
SELECT pg_temp.expect($q$INSERT INTO public.label_coverage_audits (project, draw_id, recording_id, record) VALUES ('Scratch', 'd1', 'a', '{}')$q$, '42501', 'permission denied');
SELECT pg_temp.expect($q$UPDATE public.label_coverage_audit_draws SET body = '{}'$q$, '42501', 'permission denied');
RESET ROLE;
SET ROLE anon;
SELECT pg_temp.expect($q$SELECT * FROM public.label_coverage_audits$q$, '42501', 'permission denied');
SELECT pg_temp.expect($q$SELECT public.coverage_audit_save('Scratch', 'd1', 'a', 3, '{}')$q$, '42501', 'permission denied');
RESET ROLE;

SELECT 'ALL 054 AUDIT TESTS PASSED';
