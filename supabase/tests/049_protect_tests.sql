-- Tests for 049_protect_withheld_footage, on a fresh database: stubs (live-equivalent prior policies), 048, 049.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000b'), ('00000000-0000-0000-0000-00000000000c');
INSERT INTO public.labelers VALUES ('00000000-0000-0000-0000-00000000000a', true), ('00000000-0000-0000-0000-00000000000b', false);
-- a eligible; w withheld; x an alias of w (listed too); p a phone-only upload; t a recording of a project with no list.
INSERT INTO public.label_videos (id, project, session_name, clip_path) VALUES
  ('10000000-0000-0000-0000-00000000000a', 'Scratch', 'a', 'rallylab/Scratch/a-v3.mp4'),
  ('10000000-0000-0000-0000-0000000000f1', 'Scratch', 'w', 'rallylab/Scratch/w-v2.mp4'),
  ('10000000-0000-0000-0000-0000000000f2', 'Scratch', 'x', 'rallylab/Scratch/x-v3.mp4'),
  ('10000000-0000-0000-0000-0000000000b1', NULL, NULL, 'phone/b1.mp4'),
  ('10000000-0000-0000-0000-0000000000c1', 'Test1', 't', 'rallylab/Test1/t-v2.mp4');
INSERT INTO storage.objects (bucket_id, name) VALUES ('labeling', 'rallylab/Scratch/a-v3.mp4'), ('labeling', 'rallylab/Scratch/w-v2.mp4'), ('labeling', 'rallylab/Scratch/x-v3.mp4'),
  ('labeling', 'phone/b1.mp4'), ('labeling', 'rallylab/Test1/t-v2.mp4'), ('labeling', 'rallylab/Scratch/orphan-v2.mp4');
INSERT INTO public.label_rally_times (video_id) VALUES ('10000000-0000-0000-0000-00000000000a'), ('10000000-0000-0000-0000-0000000000f1');
INSERT INTO public.label_tracks (id, video_id) VALUES ('20000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a'), ('20000000-0000-0000-0000-0000000000f1', '10000000-0000-0000-0000-0000000000f1');
INSERT INTO public.label_frame_log (track, i, labeler) VALUES ('20000000-0000-0000-0000-00000000000a', 1, '00000000-0000-0000-0000-00000000000b'), ('20000000-0000-0000-0000-0000000000f1', 1, '00000000-0000-0000-0000-00000000000b');
INSERT INTO public.label_withheld_lists (project, names) VALUES ('Scratch', 2);
INSERT INTO public.label_withheld (project, session_name) VALUES ('Scratch', 'w'), ('Scratch', 'x');
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
CREATE FUNCTION pg_temp.affected(q text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer; BEGIN EXECUTE q; GET DIAGNOSTICS n = ROW_COUNT; RETURN n; END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon;
SET ROLE authenticated;

-- An ordinary labeler.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.check((SELECT array_agg(coalesce(session_name, 'phone') ORDER BY coalesce(session_name, 'phone')) FROM public.label_videos) = ARRAY['a', 'phone'], 'videos: a and the phone upload only (w, its alias x, and the unlisted project hidden)');
SELECT pg_temp.check((SELECT array_agg(name ORDER BY name) FROM storage.objects WHERE bucket_id = 'labeling') = ARRAY['phone/b1.mp4', 'rallylab/Scratch/a-v3.mp4'], 'objects: no protected copy, no unreferenced object');
SELECT pg_temp.check((SELECT count(*) FROM storage.objects WHERE name = 'rallylab/Scratch/w-v2.mp4') = 0, 'the withheld copy cannot be read by name (so it cannot be signed)');
SELECT pg_temp.check((SELECT count(*) FROM storage.objects WHERE name = 'rallylab/Scratch/orphan-v2.mp4') = 0, 'the unreferenced object is restricted');
SELECT pg_temp.check((SELECT array_agg(video_id) FROM public.label_rally_times) = ARRAY['10000000-0000-0000-0000-00000000000a'::uuid], 'rally times of protected recordings hidden');
SELECT pg_temp.check((SELECT array_agg(id) FROM public.label_tracks) = ARRAY['20000000-0000-0000-0000-00000000000a'::uuid], 'tracks of protected recordings hidden');
SELECT pg_temp.check((SELECT array_agg(track) FROM public.label_frame_log) = ARRAY['20000000-0000-0000-0000-00000000000a'::uuid], 'own frame log on protected tracks hidden');
-- Writes: nothing protected can be changed, deleted or recreated; eligible rows still work.
SELECT pg_temp.check(pg_temp.affected($q$UPDATE public.label_videos SET title = 'x' WHERE session_name = 'w'$q$) = 0, 'no update of a protected row');
SELECT pg_temp.check(pg_temp.affected($q$DELETE FROM public.label_videos WHERE session_name = 'w'$q$) = 0, 'no delete of a protected row');
SELECT pg_temp.expect($q$INSERT INTO public.label_videos (project, session_name) VALUES ('Scratch', 'w')$q$, '42501', 'row-level security');
SELECT pg_temp.check(pg_temp.affected($q$UPDATE public.label_videos SET title = 'ok' WHERE session_name = 'a'$q$) = 1, 'an eligible row is still editable');
SELECT pg_temp.check(pg_temp.affected($q$DELETE FROM storage.objects WHERE name = 'rallylab/Scratch/w-v2.mp4'$q$) = 0, 'no delete of a protected object');
SELECT pg_temp.check(pg_temp.affected($q$UPDATE storage.objects SET owner = NULL WHERE name = 'rallylab/Scratch/orphan-v2.mp4'$q$) = 0, 'no change to the unreferenced object');
SELECT pg_temp.check(pg_temp.affected($q$UPDATE public.label_tracks SET points = '[1]' WHERE id = '20000000-0000-0000-0000-0000000000f1'$q$) = 0, 'no change to a protected track');
SELECT pg_temp.expect($q$INSERT INTO public.label_tracks (id, video_id) VALUES ('20000000-0000-0000-0000-0000000000f9', '10000000-0000-0000-0000-0000000000f1')$q$, '42501', 'row-level security');
-- Uploads from the phone are unchanged.
SELECT pg_temp.check(pg_temp.affected($q$INSERT INTO storage.objects (bucket_id, name) VALUES ('labeling', 'phone/new.mp4')$q$) = 1, 'a phone upload still lands');
-- Withheld later: hidden at once.
RESET ROLE;
INSERT INTO public.label_withheld (project, session_name) VALUES ('Scratch', 'a');
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.check((SELECT count(*) FROM public.label_videos WHERE session_name = 'a') = 0, 'a recording withheld later is hidden immediately');
SELECT pg_temp.check((SELECT count(*) FROM storage.objects WHERE name = 'rallylab/Scratch/a-v3.mp4') = 0, 'and its copy');
-- A lead sees everything (RallyLab's sync and the list publication keep working); nothing was deleted.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.check((SELECT count(*) FROM public.label_videos) = 5, 'the lead reads every row');
SELECT pg_temp.check((SELECT count(*) FROM storage.objects WHERE bucket_id = 'labeling') = 7, 'the lead reads every object');
-- Not a labeler: nothing.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
SELECT pg_temp.check((SELECT count(*) FROM public.label_videos) + (SELECT count(*) FROM storage.objects) = 0, 'a non-labeler reads nothing');
RESET ROLE;
SET ROLE anon;
SELECT pg_temp.check(NOT has_function_privilege('anon', 'private.label_object_readable(text)', 'EXECUTE'), 'anon cannot call the helpers');
RESET ROLE;
SELECT pg_temp.check((SELECT count(*) FROM storage.objects) = 7 AND (SELECT count(*) FROM public.label_videos) = 5 AND (SELECT count(*) FROM public.label_tracks) = 2, 'every object and row preserved');
SELECT 'ALL 049 PROTECT TESTS PASSED' AS result;
