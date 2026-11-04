-- Tests for 052_label_recording_type_claims, on a fresh database: stubs, 048, 049, 052 (supabase/tests/run_048_tests.sh).
-- Authorization, identity, idempotency, the lifecycle guard and the published type, as the API's roles. Every
-- check raises on failure; the run ends with 'ALL 052 CLAIMS TESTS PASSED'.
\set ON_ERROR_STOP on
SET client_min_messages = warning;

-- People: L a lead (RallyLab's account), M and M2 labelers (two phones), N signed in but not a labeler.
INSERT INTO auth.users VALUES ('00000000-0000-0000-0000-00000000000a'), ('00000000-0000-0000-0000-00000000000b'),
                              ('00000000-0000-0000-0000-00000000000c'), ('00000000-0000-0000-0000-00000000000d');
INSERT INTO public.labelers VALUES ('00000000-0000-0000-0000-00000000000a', true), ('00000000-0000-0000-0000-00000000000b', false),
                                   ('00000000-0000-0000-0000-00000000000d', false);
-- Recordings: a eligible (published fingerprint), c no published fingerprint, w withheld, t a project with no list.
INSERT INTO public.label_videos (id, project, session_name, source_fingerprint) VALUES
  ('10000000-0000-0000-0000-00000000000a', 'Scratch', 'a', 'file:a'),
  ('10000000-0000-0000-0000-00000000000c', 'Scratch', 'c', NULL),
  ('10000000-0000-0000-0000-0000000000f1', 'Scratch', 'w', 'file:w'),
  ('10000000-0000-0000-0000-0000000000c1', 'Test1', 't', 'file:t');
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
CREATE FUNCTION pg_temp.affected(q text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer; BEGIN EXECUTE q; GET DIAGNOSTICS n = ROW_COUNT; RETURN n; END $$;
CREATE FUNCTION pg_temp.check(ok boolean, what text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT coalesce(ok, false) THEN RAISE EXCEPTION 'FAIL: %', what; END IF; END $$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO authenticated, anon;

-- 1. Submitting: labelers only; a valid claim is revision 1, submitted, attributed and dated.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_submit('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', 'continuous', 'file:a')$q$, '42501', 'labelers only');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.check((SELECT (revision, status, submitted_by, project, session_name, source_fingerprint) = (1, 'submitted', '00000000-0000-0000-0000-00000000000b'::uuid, 'Scratch', 'a', 'file:a')
                      FROM public.recording_type_claim_submit('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', 'continuous', 'file:a')),
                     'first claim → revision 1, submitted, attributed');
-- Bad input.
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_submit('30000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-00000000000a', 'replay', 'file:a')$q$, '22023', 'not one of continuous, edited, unknown');
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_submit('30000000-0000-0000-0000-000000000009', '10000000-0000-0000-0000-0000000000ee', 'edited', 'file:a')$q$, '22023', 'no such recording');

-- 2. Idempotent by claim id: the same claim again is the row as it is; the id reused for another claim is refused.
SELECT pg_temp.check((SELECT (revision, status) = (1, 'submitted') FROM public.recording_type_claim_submit('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', 'continuous', 'file:a')), 'same claim again → the same row');
SELECT pg_temp.check((SELECT count(*) FROM public.label_recording_type_claims) = 1, 'no second row');
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_submit('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', 'edited', 'file:a')$q$, '22023', 'already used for another claim');

-- 3. Identity and protection: no published fingerprint, other footage, withheld, a project with no list.
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_submit('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000c', 'continuous', 'file:c')$q$, '22023', 'identity: c has no published original fingerprint');
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_submit('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', 'continuous', 'file:old')$q$, '22023', 'identity: the claim is about footage file:old, but a is file:a');
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_submit('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-0000000000f1', 'continuous', 'file:w')$q$, '42501', 'withheld: w is not open');
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_submit('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-0000000000c1', 'continuous', 'file:t')$q$, '42501', 'withheld: t is not open');
SELECT pg_temp.check((SELECT count(*) FROM public.label_recording_type_claims) = 1, 'nothing written by a refused submission');

-- 4. A newer claim for the same recording (another phone) supersedes the one still waiting.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000d', false);
SELECT pg_temp.check((SELECT (revision, status) = (2, 'submitted') FROM public.recording_type_claim_submit('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-00000000000a', 'edited', 'file:a')), 'second claim → revision 2');
SELECT pg_temp.check((SELECT (status, reason, settled_by IS NOT NULL, settled_at IS NOT NULL) = ('superseded', 'replaced by a newer choice', true, true)
                      FROM public.label_recording_type_claims WHERE id = '30000000-0000-0000-0000-000000000001'), 'the first is superseded, dated, with the reason');
-- The superseded claim resubmitted by its id: still the row as it is (superseded), never reopened.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.check((SELECT status FROM public.recording_type_claim_submit('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', 'continuous', 'file:a')) = 'superseded', 'a superseded claim stays superseded on retry');

-- 5. Reading: a labeler sees the claims of recordings they may read; not a withheld recording's; a lead sees all.
RESET ROLE;
INSERT INTO public.label_recording_type_claims (id, video_id, project, session_name, source_fingerprint, recording_type, revision, submitted_by)
    VALUES ('30000000-0000-0000-0000-0000000000f1', '10000000-0000-0000-0000-0000000000f1', 'Scratch', 'w', 'file:w', 'edited', 1, '00000000-0000-0000-0000-00000000000b');
SET ROLE authenticated;
SELECT pg_temp.check((SELECT count(*) FROM public.label_recording_type_claims) = 2, 'labeler M sees the two claims on a, not the one on w');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
SELECT pg_temp.check((SELECT count(*) FROM public.label_recording_type_claims) = 0, 'not a labeler: nothing');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.check((SELECT count(*) FROM public.label_recording_type_claims) = 3, 'the lead sees all');

-- 6. No client writes the table directly: no insert, update or delete policy — for labelers and leads alike.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.expect($q$INSERT INTO public.label_recording_type_claims (id, video_id, project, session_name, source_fingerprint, recording_type, revision)
                         VALUES ('30000000-0000-0000-0000-000000000077', '10000000-0000-0000-0000-00000000000a', 'Scratch', 'a', 'file:a', 'edited', 9)$q$, '42501', 'row-level security');
SELECT pg_temp.check(pg_temp.affected($q$UPDATE public.label_recording_type_claims SET status = 'accepted', settled_at = now() WHERE id = '30000000-0000-0000-0000-000000000003'$q$) = 0, 'a labeler cannot accept their own claim');
SELECT pg_temp.check(pg_temp.affected($q$DELETE FROM public.label_recording_type_claims WHERE id = '30000000-0000-0000-0000-000000000003'$q$) = 0, 'nor delete it');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.check(pg_temp.affected($q$UPDATE public.label_recording_type_claims SET status = 'accepted', settled_at = now() WHERE id = '30000000-0000-0000-0000-000000000003'$q$) = 0, 'a lead settles through the function, not the table');
SELECT pg_temp.check((SELECT status FROM public.label_recording_type_claims WHERE id = '30000000-0000-0000-0000-000000000003') = 'submitted', 'still submitted');

-- 7. Settling: leads only; after the Mac's write — accepted with the confirmation time publishes the type.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_settle('30000000-0000-0000-0000-000000000003', 'accepted')$q$, '42501', 'leads only');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_settle('30000000-0000-0000-0000-000000000003', 'superseded')$q$, '22023', 'accepted or rejected');
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_settle('30000000-0000-0000-0000-0000000000ee', 'accepted')$q$, '22023', 'no such claim');
SELECT pg_temp.check((SELECT (status, settled_by) = ('accepted', '00000000-0000-0000-0000-00000000000a'::uuid)
                      FROM public.recording_type_claim_settle('30000000-0000-0000-0000-000000000003', 'accepted', NULL, '2026-11-04T01:02:03Z')), 'accepted by the lead');
SELECT pg_temp.check((SELECT (recording_type, recording_type_at) = ('edited', '2026-11-04T01:02:03Z'::timestamptz) FROM public.label_videos WHERE session_name = 'a'), 'the type is published for the phone, at the confirmation time');
-- The same settlement again (a reply lost on the way back): the row as it is, nothing changed.
SELECT pg_temp.check((SELECT status FROM public.recording_type_claim_settle('30000000-0000-0000-0000-000000000003', 'accepted')) = 'accepted', 'accepting again → as it is');
SELECT pg_temp.check((SELECT recording_type_at FROM public.label_videos WHERE session_name = 'a') = '2026-11-04T01:02:03Z'::timestamptz, 'the published time untouched by the retry');
-- Any other change to a settled claim is a conflict; a superseded claim cannot be settled either.
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_settle('30000000-0000-0000-0000-000000000003', 'rejected', 'changed my mind')$q$, 'P0001', 'conflict: claim 30000000-0000-0000-0000-000000000003 is already accepted');
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_settle('30000000-0000-0000-0000-000000000001', 'rejected', 'x')$q$, 'P0001', 'is already superseded');
-- Rejecting carries the reason and does not publish a type.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.check((SELECT revision FROM public.recording_type_claim_submit('30000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-00000000000a', 'unknown', 'file:a')) = 3, 'a third claim → revision 3');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.check((SELECT (status, reason) = ('rejected', 'the recording''s file changed since this was sent — confirm again')
                      FROM public.recording_type_claim_settle('30000000-0000-0000-0000-000000000004', 'rejected', 'the recording''s file changed since this was sent — confirm again')), 'rejected with the reason');
SELECT pg_temp.check((SELECT recording_type FROM public.label_videos WHERE session_name = 'a') = 'edited', 'a rejection publishes nothing');

-- 8. The lifecycle guard holds for everyone, the table's owner included: no backward move, no change to what a
-- claim is about, no change to a settled claim.
RESET ROLE;
SELECT pg_temp.expect($q$UPDATE public.label_recording_type_claims SET status = 'submitted' WHERE id = '30000000-0000-0000-0000-000000000003'$q$, '42501', 'is accepted and stays so');
SELECT pg_temp.expect($q$UPDATE public.label_recording_type_claims SET recording_type = 'continuous' WHERE id = '30000000-0000-0000-0000-000000000003'$q$, '42501', 'never changes');
SELECT pg_temp.expect($q$UPDATE public.label_recording_type_claims SET reason = 'later' WHERE id = '30000000-0000-0000-0000-000000000003'$q$, '42501', 'a settled claim never changes');
SELECT pg_temp.expect($q$UPDATE public.label_recording_type_claims SET status = 'rejected' WHERE id = '30000000-0000-0000-0000-0000000000f1'$q$, '42501', 'a settlement is dated');

-- 9. The published type on label_videos: a labeler may neither set nor change it; a lead may.
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.expect($q$UPDATE public.label_videos SET recording_type = 'continuous' WHERE session_name = 'a'$q$, '42501', 'published type');
SELECT pg_temp.expect($q$INSERT INTO public.label_videos (id, clip_path, recording_type) VALUES ('10000000-0000-0000-0000-0000000000b9', 'phone/b9.mp4', 'continuous')$q$, '42501', 'only a phone upload');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT pg_temp.check(pg_temp.affected($q$UPDATE public.label_videos SET recording_type = 'continuous', recording_type_at = now() WHERE session_name = 'a'$q$) = 1, 'the lead publishes the type');
SELECT pg_temp.expect($q$UPDATE public.label_videos SET recording_type = 'montage' WHERE session_name = 'a'$q$, '23514', 'check');

-- 10. A retry of a submission after the recording was withheld (or its project's list withdrawn) is refused like a
-- new one: the idempotent return never shows a claim of a recording the labeler may no longer read.
RESET ROLE;
INSERT INTO public.label_withheld (project, session_name) VALUES ('Scratch', 'a');
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
SELECT pg_temp.expect($q$SELECT public.recording_type_claim_submit('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-00000000000a', 'edited', 'file:a')$q$, '42501', 'withheld: a is not open');
SELECT pg_temp.check((SELECT count(*) FROM public.label_recording_type_claims WHERE video_id = '10000000-0000-0000-0000-00000000000a') = 0, 'and the claims are not readable either');
RESET ROLE;
DELETE FROM public.label_withheld WHERE project = 'Scratch' AND session_name = 'a';
SET ROLE authenticated;
SELECT pg_temp.check((SELECT status FROM public.recording_type_claim_submit('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-00000000000a', 'edited', 'file:a')) = 'accepted', 'open again: the retry shows the claim as it is');

-- 11. An account deleted (supabase/functions/delete-account): its attribution is cleared by the foreign keys, the
-- claims and their history stay as they are; nothing else may change through that path.
RESET ROLE;
SELECT pg_temp.check((SELECT submitted_by FROM public.label_recording_type_claims WHERE id = '30000000-0000-0000-0000-000000000003') = '00000000-0000-0000-0000-00000000000d', 'claim 3 is M2''s');
DELETE FROM public.labelers WHERE user_id = '00000000-0000-0000-0000-00000000000d';   -- the profile goes first, as delete-account does
DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-00000000000d';
SELECT pg_temp.check((SELECT (status, submitted_by IS NULL, recording_type, revision) = ('accepted', true, 'edited', 2) FROM public.label_recording_type_claims WHERE id = '30000000-0000-0000-0000-000000000003'), 'the submitter gone: the accepted claim stays, unattributed');
SELECT pg_temp.check((SELECT settled_by FROM public.label_recording_type_claims WHERE id = '30000000-0000-0000-0000-000000000004') = '00000000-0000-0000-0000-00000000000a', 'claim 4 was settled by L');
DELETE FROM public.labelers WHERE user_id = '00000000-0000-0000-0000-00000000000a';
DELETE FROM auth.users WHERE id = '00000000-0000-0000-0000-00000000000a';
SELECT pg_temp.check((SELECT (status, settled_by IS NULL, reason IS NOT NULL) = ('rejected', true, true) FROM public.label_recording_type_claims WHERE id = '30000000-0000-0000-0000-000000000004'), 'the settler gone: the rejected claim stays, its reason too');
SELECT pg_temp.expect($q$UPDATE public.label_recording_type_claims SET submitted_by = NULL, status = 'submitted' WHERE id = '30000000-0000-0000-0000-000000000003'$q$, '42501', 'stays so');
SELECT pg_temp.expect($q$UPDATE public.label_recording_type_claims SET settled_by = NULL, reason = 'edited away' WHERE id = '30000000-0000-0000-0000-000000000004'$q$, '42501', 'never changes');

-- 12. A recording removed takes its claims with it (no orphan claim); nothing else is touched.
RESET ROLE;
SELECT pg_temp.check((SELECT count(*) FROM public.label_recording_type_claims WHERE video_id = '10000000-0000-0000-0000-0000000000f1') = 1, 'w has its claim');
DELETE FROM public.label_videos WHERE id = '10000000-0000-0000-0000-0000000000f1';
SELECT pg_temp.check((SELECT count(*) FROM public.label_recording_type_claims WHERE video_id = '10000000-0000-0000-0000-0000000000f1') = 0, 'gone with the recording');
SELECT pg_temp.check((SELECT count(*) FROM public.label_recording_type_claims) = 3, 'the others stay');

SELECT 'ALL 052 CLAIMS TESTS PASSED';
