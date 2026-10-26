-- Tests for migration 050 (the published pilot draw), run after 048 and its tests' data are gone: a fresh cluster.
\set ON_ERROR_STOP on
SET client_min_messages = warning;
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000b'), ('00000000-0000-0000-0000-00000000000c');
INSERT INTO public.labelers VALUES ('00000000-0000-0000-0000-00000000000a', true), ('00000000-0000-0000-0000-00000000000b', false);
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
CREATE FUNCTION pg_temp.sel(v text) RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_array(jsonb_build_object('video', v, 'legacyIndex', 3, 'legacyStart', 10.0, 'legacyEnd', 13.0, 'window', jsonb_build_array(5.0, 18.0), 'stratum', 'short', 'repeatReview', true))
$$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon;
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.expect($q$SELECT public.label_pilot_publish('EXP-1', 'Scratch', repeat('a', 64), pg_temp.sel('a'))$q$, '42501', 'no published withheld list');
SELECT pg_temp.check(public.label_withheld_publish('Scratch', ARRAY['b']) = 1, 'list published');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.expect($q$SELECT public.label_pilot_publish('EXP-1', 'Scratch', repeat('a', 64), pg_temp.sel('a'))$q$, '42501', 'leads only');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.expect($q$SELECT public.label_pilot_publish('EXP-1', 'Scratch', repeat('a', 64), pg_temp.sel('b'))$q$, '42501', 'withheld: the selection names b');
SELECT pg_temp.expect($q$SELECT public.label_pilot_publish('EXP-1', 'Scratch', repeat('a', 64), '[]')$q$, '22023', 'non-empty array');
SELECT pg_temp.expect($q$SELECT public.label_pilot_publish('EXP-1', 'Scratch', repeat('a', 64), '[{"video":"a"}]')$q$, '22023', 'needs video, legacyIndex');
SELECT pg_temp.expect($q$SELECT public.label_pilot_publish('EXP-1', 'Scratch', 'not-a-hash', pg_temp.sel('a'))$q$, '23514', 'record_sha256');
SELECT pg_temp.check((SELECT selection_digest FROM public.label_pilot_publish('EXP-1', 'Scratch', repeat('a', 64), pg_temp.sel('a'))) = encode(sha256(convert_to(pg_temp.sel('a')::text, 'UTF8')), 'hex'), 'published, with the server''s digest of the selection');
SELECT pg_temp.expect($q$SELECT public.label_pilot_publish('EXP-1', 'Scratch', repeat('b', 64), pg_temp.sel('a'))$q$, '23505', 'never changed');
-- Labelers read; nobody writes directly.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.check((SELECT count(*) FROM public.label_pilot_records) = 1, 'a labeler reads the draw');
SELECT pg_temp.check(pg_temp.affected($q$UPDATE public.label_pilot_records SET selection = '[]'$q$) = 0, 'no direct update');
SELECT pg_temp.check(pg_temp.affected($q$DELETE FROM public.label_pilot_records$q$) = 0, 'no direct delete');
SELECT pg_temp.expect($q$INSERT INTO public.label_pilot_records (id, project, record_sha256, selection, selection_digest) VALUES ('X', 'Scratch', repeat('c', 64), '[]', 'x')$q$, '42501', 'row-level security');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
SELECT pg_temp.check((SELECT count(*) FROM public.label_pilot_records) = 0, 'a non-labeler reads nothing');
RESET ROLE;
SET ROLE anon;
SELECT pg_temp.expect($q$SELECT count(*) FROM public.label_pilot_records$q$, '42501', 'permission denied');
RESET ROLE;
SELECT pg_temp.check(NOT has_function_privilege('anon', 'public.label_pilot_publish(text, text, text, jsonb)', 'EXECUTE'), 'anon cannot publish');
SELECT 'ALL 050 PILOT TESTS PASSED' AS result;
