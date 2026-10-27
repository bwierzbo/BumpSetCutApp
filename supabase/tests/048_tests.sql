-- Authorization, identity and concurrency tests for migration 048, run as the roles the API uses.
-- Every check raises on failure; the run ends with 'ALL 048 TESTS PASSED'.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- People: L a lead labeler, M a labeler, N signed in but not a labeler.
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000b'), ('00000000-0000-0000-0000-00000000000c');
INSERT INTO public.labelers VALUES ('00000000-0000-0000-0000-00000000000a', true), ('00000000-0000-0000-0000-00000000000b', false);
-- Recordings: a (eligible), b (withheld), c (no published fingerprint), d (another project with no list), e (alias-to-be).
INSERT INTO public.label_videos (id, project, session_name) VALUES
  ('10000000-0000-0000-0000-00000000000a', 'Scratch', 'a'), ('10000000-0000-0000-0000-00000000000b', 'Scratch', 'b'),
  ('10000000-0000-0000-0000-00000000000c', 'Scratch', 'c'), ('10000000-0000-0000-0000-00000000000d', 'Other', 'd'),
  ('10000000-0000-0000-0000-00000000000e', 'Scratch', 'e');
UPDATE public.label_videos SET source_fingerprint = 'file:' || session_name, frame_times_digest = 'dg-' || session_name WHERE session_name <> 'c';

CREATE FUNCTION pg_temp.rec(v text, fp text, dg text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_strip_nulls(jsonb_build_object('annotationVersion', 'rally_event_truth_v1', 'video', v, 'sourceFingerprint', fp,
                                                'frameTimesDigest', dg, 'frameRate', 30, 'durationSec', 10, 'tool', 'test', 'rallies', '[]'::jsonb))
$$;
-- expect(sql, code, text): the statement must fail with that SQLSTATE and its message must contain the text.
CREATE FUNCTION pg_temp.expect(q text, code text, msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE q;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE <> code OR position(msg IN SQLERRM) = 0 THEN
            RAISE EXCEPTION 'FAIL: % → % % (wanted % containing "%")', q, SQLSTATE, SQLERRM, code, msg;
        END IF;
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL: % succeeded (wanted %)', q, code;
END $$;
CREATE FUNCTION pg_temp.affected(q text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer; BEGIN EXECUTE q; GET DIAGNOSTICS n = ROW_COUNT; RETURN n; END $$;
CREATE FUNCTION pg_temp.check(ok boolean, what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT coalesce(ok, false) THEN RAISE EXCEPTION 'FAIL: %', what; END IF; END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon;

-- 1. Publishing the withheld list: leads only.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.expect($q$SELECT public.label_withheld_publish('Scratch', ARRAY['b'])$q$, '42501', 'leads only');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.check(public.label_withheld_publish('Scratch', ARRAY['b']) = 1, 'lead publishes one name');
-- Publishing the same list again writes nothing (no broadcast loop between two RallyLab instances).
RESET ROLE;
UPDATE public.label_withheld_lists SET listed_at = '2000-01-01' WHERE project = 'Scratch';
SET ROLE authenticated;
SELECT pg_temp.check(public.label_withheld_publish('Scratch', ARRAY['b', 'b', '']) = 1, 'same list → same count');
SELECT pg_temp.check((SELECT listed_at FROM public.label_withheld_lists WHERE project = 'Scratch') = '2000-01-01', 'same list → nothing rewritten');

-- 2. Saving: a labeler, at the expected revision, for the published original only.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.check((SELECT revision FROM public.rally_events_save('10000000-0000-0000-0000-00000000000a', 0, pg_temp.rec('a', 'file:a'))) = 1, 'first save → revision 1');
SELECT pg_temp.check((SELECT (record->>'revision')::int FROM public.label_rally_events WHERE session_name = 'a') = 1, 'revision written inside the record too');
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000a', 0, pg_temp.rec('a', 'file:a'))$q$, 'P0001', 'conflict: the record changed on the server (revision 1, expected 0)');
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000a', 5, pg_temp.rec('a', 'file:a'))$q$, 'P0001', 'conflict');
SELECT pg_temp.check((SELECT revision FROM public.rally_events_save('10000000-0000-0000-0000-00000000000a', 1, pg_temp.rec('a', 'file:a', 'dg-a'))) = 2, 'save at the current revision with the matching digest → 2');
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000e', 3, pg_temp.rec('e', 'file:e'))$q$, 'P0001', 'no record on the server yet');
-- Identity: missing, other footage, other frames, no published original.
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000a', 2, pg_temp.rec('a', NULL))$q$, '22023', 'identity: the record describes footage (none)');
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000a', 2, pg_temp.rec('a', 'file:replaced'))$q$, '22023', 'identity: the record describes footage file:replaced');
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000a', 2, pg_temp.rec('a', 'file:a', 'dg-other'))$q$, '22023', 'frame digest');
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000c', 0, pg_temp.rec('c', 'file:c'))$q$, '22023', 'no published original fingerprint');
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000a', 2, pg_temp.rec('b', 'file:a'))$q$, '22023', 'the record names b, not a');
-- Withheld, and a project with no published list.
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000b', 0, pg_temp.rec('b', 'file:b'))$q$, '42501', 'withheld: b is a withheld recording');
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000d', 0, pg_temp.rec('d', 'file:d'))$q$, '42501', 'has no published withheld list');
SELECT pg_temp.check((SELECT revision FROM public.label_rally_events WHERE session_name = 'a') = 2, 'every refused save left revision 2');
-- Not a labeler.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000a', 2, pg_temp.rec('a', 'file:a'))$q$, '42501', 'labelers only');
SELECT pg_temp.check((SELECT count(*) FROM public.label_rally_events) = 0, 'a non-labeler reads nothing');

-- 2b. The identities every save is judged by cannot be rewritten by an ordinary labeler (the live 028 policy allows writes).
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.expect($q$UPDATE public.label_videos SET source_fingerprint = 'file:other' WHERE session_name = 'a'$q$, '42501', 'may not change');
SELECT pg_temp.expect($q$UPDATE public.label_videos SET frame_times_digest = 'dg-other' WHERE session_name = 'a'$q$, '42501', 'may not change');
SELECT pg_temp.expect($q$UPDATE public.label_videos SET session_name = 'renamed' WHERE session_name = 'b'$q$, '42501', 'may not change');
SELECT pg_temp.expect($q$UPDATE public.label_videos SET project = 'Other' WHERE session_name = 'b'$q$, '42501', 'may not change');
SELECT pg_temp.expect($q$INSERT INTO public.label_videos (project, session_name, source_fingerprint) VALUES ('Scratch', 'forged', 'file:x')$q$, '42501', 'only a phone upload');
SELECT pg_temp.check((SELECT source_fingerprint FROM public.label_videos WHERE session_name = 'a') = 'file:a', 'identities intact');
-- The phone's own upload row and a status change still work; the lead still publishes identities.
SELECT pg_temp.check(pg_temp.affected($q$INSERT INTO public.label_videos (clip_path, status) VALUES ('phone/p1.mp4', 'uploaded')$q$) = 1, 'a phone upload row');
SELECT pg_temp.check(pg_temp.affected($q$UPDATE public.label_videos SET status = 'labeled' WHERE session_name = 'a'$q$) = 1, 'a status change');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.check(pg_temp.affected($q$UPDATE public.label_videos SET frame_times_digest = 'dg-a' WHERE session_name = 'a'$q$) = 1, 'the lead publishes identities');

-- 3. Direct writes are impossible for everyone; anon has no table access at all.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.expect($q$INSERT INTO public.label_rally_events (video_id, project, session_name, annotation_version, record) VALUES ('10000000-0000-0000-0000-00000000000e', 'Scratch', 'e', 'rally_event_truth_v1', '{}')$q$, '42501', 'row-level security');
SELECT pg_temp.check(pg_temp.affected($q$UPDATE public.label_rally_events SET revision = 99$q$) = 0, 'a direct update changes nothing');
SELECT pg_temp.check(pg_temp.affected($q$DELETE FROM public.label_rally_events$q$) = 0, 'a direct delete removes nothing');
SELECT pg_temp.expect($q$INSERT INTO public.label_withheld (project, session_name) VALUES ('Scratch', 'zz')$q$, '42501', 'row-level security');
SELECT pg_temp.check(pg_temp.affected($q$DELETE FROM public.label_withheld$q$) = 0, 'no direct delete from the withheld list');
SELECT pg_temp.check(pg_temp.affected($q$DELETE FROM public.label_withheld_lists$q$) = 0, 'no direct delete of a published list');
RESET ROLE;
SET ROLE anon;
SELECT pg_temp.expect($q$SELECT count(*) FROM public.label_rally_events$q$, '42501', 'permission denied');
SELECT pg_temp.expect($q$SELECT public.rally_events_save('10000000-0000-0000-0000-00000000000a', 2, '{}')$q$, '42501', 'permission denied');
RESET ROLE;

-- 4. Protected reads: a record saved while eligible disappears from every read once its recording (or an alias)
--    is withheld, for leads too, and when the project's list is gone.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.check((SELECT revision FROM public.rally_events_save('10000000-0000-0000-0000-00000000000e', 0, pg_temp.rec('e', 'file:e'))) = 1, 'e saved while eligible');
SELECT pg_temp.check((SELECT count(*) FROM public.label_rally_events) = 2, 'labeler reads a and e');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.check(public.label_withheld_publish('Scratch', ARRAY['b', 'e']) = 2, 'e becomes withheld (e.g. a newly found alias)');
SELECT pg_temp.check((SELECT count(*) FROM public.label_rally_events WHERE session_name = 'e') = 0, 'the lead cannot read e');
SELECT pg_temp.check((SELECT count(*) FROM public.label_rally_events WHERE video_id = '10000000-0000-0000-0000-00000000000e') = 0, 'not by id either');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.check((SELECT array_agg(session_name) FROM public.label_rally_events) = ARRAY['a'], 'the labeler reads only a');
SELECT pg_temp.expect($q$SELECT * FROM public.rally_events_save('10000000-0000-0000-0000-00000000000e', 1, pg_temp.rec('e', 'file:e'))$q$, '42501', 'withheld: e');
RESET ROLE;
DELETE FROM public.label_withheld_lists WHERE project = 'Scratch';
SET ROLE authenticated;
SELECT pg_temp.check((SELECT count(*) FROM public.label_rally_events) = 0, 'no published list: nothing is readable');
RESET ROLE;
SELECT pg_temp.check((SELECT count(*) FROM public.label_rally_events) = 2, 'the rows themselves are preserved (nothing deleted)');

-- 5. Privileges on the functions: anon cannot execute; private helpers are not callable by anon.
SELECT pg_temp.check(NOT has_function_privilege('anon', 'public.rally_events_save(uuid, integer, jsonb)', 'EXECUTE'), 'anon cannot execute rally_events_save');
SELECT pg_temp.check(NOT has_function_privilege('anon', 'public.label_withheld_publish(text, text[])', 'EXECUTE'), 'anon cannot execute label_withheld_publish');
SELECT pg_temp.check(NOT has_table_privilege('anon', 'public.label_rally_events', 'SELECT'), 'anon has no SELECT on label_rally_events');

SELECT 'ALL 048 TESTS PASSED' AS result;
