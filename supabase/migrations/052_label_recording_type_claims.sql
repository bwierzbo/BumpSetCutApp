-- 052_label_recording_type_claims.sql
--
-- A labeler's claim about a recording's type — continuous, edited, or unknown — made on the phone at the end
-- of the marking pass (D-032 is the Mac's step; D-033 this contract). A claim is a request for confirmation,
-- never the confirmation: the authoritative record stays <project>/footage-properties/<video>.json on the Mac.
-- RallyLab (a lead's account) reads the submitted claims of its open project, validates each against the
-- project as it is — the recording and its session exist, the claim's fingerprint is the card's, the recording
-- is not withheld, the record on file is readable, no newer decision was made on the Mac — writes the accepted
-- ones through the one writer of the type (FootageProperties.Store.confirmRecordingType) and settles the claim
-- only after that write: accepted, or rejected with a reason in plain words. The phone shows the claim's state.
--
-- Lifecycle: submitted → accepted | rejected | superseded. A newer claim for the same recording supersedes the
-- ones still waiting ("replaced by a newer choice"), so one claim per recording is open at a time. A status only
-- moves forward, the identity columns never change, every change is dated and attributed (the guard below).
-- Writes go through two functions and nothing else — no row policy lets a client write the table directly:
--   recording_type_claim_submit  (labelers; idempotent by the client-minted claim id)
--   recording_type_claim_settle  (leads; idempotent for the same settlement — a lost reply is retried safely)
-- Reads: a labeler sees the claims of the recordings they may read (049's rule: a published withheld list, the
-- recording not on it); a lead sees all.
--
-- label_videos gains recording_type and recording_type_at: the type as the Mac's record has it, published by
-- the lead's RallyLab (a copy for the phone's display, never an authority — like source_fingerprint). An
-- accepted claim sets them to the claim's type and the Mac's confirmation time; a labeler may not set them
-- (the 048 guard, extended). An older phone build never sends either column, so its upserts leave them as they are.
--
-- RLS and privileges follow 028/039/048/049. Nothing here reads or changes an annotation, a split or a ledger.

CREATE TABLE IF NOT EXISTS public.label_recording_type_claims (
    -- Minted by the client: the idempotency key of a submission.
    id                 uuid PRIMARY KEY,
    video_id           uuid NOT NULL REFERENCES public.label_videos(id) ON DELETE CASCADE,
    project            text NOT NULL,
    session_name       text NOT NULL,
    -- The original's content fingerprint the claim is about (label_videos.source_fingerprint as published when
    -- the claim was made); the Mac re-checks it against the project card before accepting.
    source_fingerprint text NOT NULL,
    recording_type     text NOT NULL CHECK (recording_type IN ('continuous', 'edited', 'unknown')),
    -- 1, 2, 3… per recording, assigned by the server in submission order.
    revision           integer NOT NULL,
    status             text NOT NULL DEFAULT 'submitted' CHECK (status IN ('submitted', 'accepted', 'rejected', 'superseded')),
    -- Why it was rejected or superseded, in plain words safe to show (never a path).
    reason             text,
    submitted_by       uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    submitted_at       timestamptz NOT NULL DEFAULT now(),
    settled_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    settled_at         timestamptz,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (video_id, revision)
);
ALTER TABLE public.label_recording_type_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.label_recording_type_claims FROM anon;
CREATE INDEX IF NOT EXISTS label_recording_type_claims_updated_at_idx ON public.label_recording_type_claims (updated_at);
CREATE INDEX IF NOT EXISTS label_recording_type_claims_video_status_idx ON public.label_recording_type_claims (video_id, status);

-- The published type for the phone's display (never an authority).
ALTER TABLE public.label_videos ADD COLUMN IF NOT EXISTS recording_type text
    CHECK (recording_type IS NULL OR recording_type IN ('continuous', 'edited', 'unknown'));
ALTER TABLE public.label_videos ADD COLUMN IF NOT EXISTS recording_type_at timestamptz;
COMMENT ON COLUMN public.label_videos.recording_type IS
    'The recording''s type as the Mac''s footage-properties record has it, published by the lead''s RallyLab; a copy for the phone, never the authority.';

-- A claim's history is auditable: a status only moves forward from submitted, a settled claim never changes
-- again, and what the claim is about never changes. Applies to everyone, the functions below included.
CREATE OR REPLACE FUNCTION private.recording_type_claims_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF NEW.id <> OLD.id OR NEW.video_id <> OLD.video_id OR NEW.project <> OLD.project OR NEW.session_name <> OLD.session_name
       OR NEW.source_fingerprint <> OLD.source_fingerprint OR NEW.recording_type <> OLD.recording_type OR NEW.revision <> OLD.revision
       OR NEW.submitted_by IS DISTINCT FROM OLD.submitted_by OR NEW.submitted_at <> OLD.submitted_at THEN
        RAISE EXCEPTION 'label_recording_type_claims: what a claim is about never changes' USING ERRCODE = '42501';
    END IF;
    IF NEW.status <> OLD.status THEN
        IF OLD.status <> 'submitted' THEN
            RAISE EXCEPTION 'label_recording_type_claims: claim % is % and stays so', OLD.id, OLD.status USING ERRCODE = '42501';
        END IF;
        IF NEW.settled_at IS NULL THEN
            RAISE EXCEPTION 'label_recording_type_claims: a settlement is dated' USING ERRCODE = '42501';
        END IF;
    ELSIF OLD.status <> 'submitted' AND (NEW.reason IS DISTINCT FROM OLD.reason OR NEW.settled_by IS DISTINCT FROM OLD.settled_by
                                         OR NEW.settled_at IS DISTINCT FROM OLD.settled_at) THEN
        RAISE EXCEPTION 'label_recording_type_claims: a settled claim never changes' USING ERRCODE = '42501';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.recording_type_claims_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS label_recording_type_claims_guard ON public.label_recording_type_claims;
CREATE TRIGGER label_recording_type_claims_guard BEFORE UPDATE ON public.label_recording_type_claims
    FOR EACH ROW EXECUTE FUNCTION private.recording_type_claims_guard();

-- Reads: labelers see the claims of recordings they may read (049); leads see all. No write policy.
DROP POLICY IF EXISTS "label_recording_type_claims_read" ON public.label_recording_type_claims;
CREATE POLICY "label_recording_type_claims_read" ON public.label_recording_type_claims FOR SELECT TO authenticated
    USING ((SELECT private.is_labeler()) AND private.label_video_readable(video_id));

-- The 048 guard, with the published type among what a labeler may neither set nor change.
CREATE OR REPLACE FUNCTION private.label_videos_guard() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF (SELECT auth.uid()) IS NULL OR (SELECT private.is_lead()) THEN RETURN NEW; END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.project IS NOT NULL OR NEW.session_name IS NOT NULL OR NEW.source_fingerprint IS NOT NULL OR NEW.frame_times_digest IS NOT NULL
           OR NEW.recording_type IS NOT NULL OR NEW.recording_type_at IS NOT NULL
           OR (NEW.clip_path IS NOT NULL AND NEW.clip_path NOT LIKE 'phone/%')
           OR (NEW.clip_path IS NOT NULL AND EXISTS (SELECT 1 FROM public.label_videos v WHERE v.clip_path = NEW.clip_path)) THEN
            RAISE EXCEPTION 'label_videos: a labeler may add only a phone upload''s own row' USING ERRCODE = '42501';
        END IF;
    ELSIF NEW.project IS DISTINCT FROM OLD.project OR NEW.session_name IS DISTINCT FROM OLD.session_name
          OR NEW.clip_path IS DISTINCT FROM OLD.clip_path OR NEW.source_fingerprint IS DISTINCT FROM OLD.source_fingerprint
          OR NEW.frame_times_digest IS DISTINCT FROM OLD.frame_times_digest
          OR NEW.recording_type IS DISTINCT FROM OLD.recording_type OR NEW.recording_type_at IS DISTINCT FROM OLD.recording_type_at THEN
        RAISE EXCEPTION 'label_videos: a labeler may not change a recording''s project, name, copy, identities or published type' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

-- Submit a claim (labelers). Idempotent by claim id: the same claim again returns the row as it is, whatever has
-- become of it; the same id for another claim is refused. The recording must be one the labeler may label
-- (a published withheld list, not on it — 049's rule, unknown fails closed) with a published original
-- fingerprint, and the claim must be about that fingerprint. Earlier claims of the recording still waiting are
-- superseded. Returns the claim.
--   not a labeler        → 42501 'labelers only'
--   withheld / no list   → 42501 'withheld: …'
--   identity             → 22023 'identity: …'  (no published fingerprint, or the claim is about other footage)
--   bad input            → 22023
CREATE OR REPLACE FUNCTION public.recording_type_claim_submit(p_id uuid, p_video uuid, p_type text, p_fingerprint text)
    RETURNS SETOF public.label_recording_type_claims
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_project text;
    v_session text;
    v_fingerprint text;
    v_existing public.label_recording_type_claims;
    v_next integer;
BEGIN
    IF NOT (SELECT private.is_labeler()) THEN
        RAISE EXCEPTION 'recording_type_claim_submit: labelers only' USING ERRCODE = '42501';
    END IF;
    IF p_id IS NULL OR p_video IS NULL THEN
        RAISE EXCEPTION 'recording_type_claim_submit: a claim id and a recording are required' USING ERRCODE = '22023';
    END IF;
    IF p_type IS NULL OR p_type NOT IN ('continuous', 'edited', 'unknown') THEN
        RAISE EXCEPTION 'recording_type_claim_submit: recording type % is not one of continuous, edited, unknown', coalesce(p_type, '(none)') USING ERRCODE = '22023';
    END IF;
    -- One submission at a time per recording: the revision and the superseding are decided in order.
    PERFORM pg_advisory_xact_lock(hashtext('label_recording_type_claims'), hashtext(p_video::text));
    SELECT * INTO v_existing FROM public.label_recording_type_claims WHERE id = p_id;
    IF FOUND THEN
        IF v_existing.video_id <> p_video OR v_existing.recording_type <> p_type OR v_existing.source_fingerprint <> coalesce(p_fingerprint, '') THEN
            RAISE EXCEPTION 'recording_type_claim_submit: claim id % is already used for another claim', p_id USING ERRCODE = '22023';
        END IF;
        RETURN QUERY SELECT * FROM public.label_recording_type_claims WHERE id = p_id;
        RETURN;
    END IF;
    SELECT project, session_name, source_fingerprint INTO v_project, v_session, v_fingerprint
      FROM public.label_videos WHERE id = p_video;
    IF NOT FOUND OR v_project IS NULL OR v_session IS NULL THEN
        RAISE EXCEPTION 'recording_type_claim_submit: no such recording' USING ERRCODE = '22023';
    END IF;
    IF private.label_session_protected(v_project, v_session) THEN
        RAISE EXCEPTION 'withheld: % is not open to labeling (withheld, or its project has no published list)', v_session USING ERRCODE = '42501';
    END IF;
    IF v_fingerprint IS NULL OR v_fingerprint = '' THEN
        RAISE EXCEPTION 'identity: % has no published original fingerprint; nothing is accepted until RallyLab publishes it', v_session USING ERRCODE = '22023';
    END IF;
    IF coalesce(p_fingerprint, '') <> v_fingerprint THEN
        RAISE EXCEPTION 'identity: the claim is about footage %, but % is %', coalesce(p_fingerprint, '(none)'), v_session, v_fingerprint USING ERRCODE = '22023';
    END IF;
    UPDATE public.label_recording_type_claims
       SET status = 'superseded', reason = 'replaced by a newer choice', settled_by = (SELECT auth.uid()), settled_at = now()
     WHERE video_id = p_video AND status = 'submitted';
    SELECT coalesce(max(revision), 0) + 1 INTO v_next FROM public.label_recording_type_claims WHERE video_id = p_video;
    INSERT INTO public.label_recording_type_claims
        (id, video_id, project, session_name, source_fingerprint, recording_type, revision, status, submitted_by, submitted_at, updated_at)
        VALUES (p_id, p_video, v_project, v_session, v_fingerprint, p_type, v_next, 'submitted', (SELECT auth.uid()), now(), now());
    RETURN QUERY SELECT * FROM public.label_recording_type_claims WHERE id = p_id;
END;
$$;

-- Settle a claim (leads: RallyLab's account), after the authoritative record was written on the Mac (accepted,
-- with the confirmation's time) or when it will not be (rejected, with a reason in plain words). The same
-- settlement again returns the row as it is (a reply lost on the way back is retried safely); any other change
-- to a settled claim is a conflict. Accepting publishes the type on label_videos for the phone's display.
--   not a lead      → 42501 'leads only'
--   no such claim   → 22023
--   settled already → P0001 'conflict: …'
CREATE OR REPLACE FUNCTION public.recording_type_claim_settle(p_id uuid, p_status text, p_reason text DEFAULT NULL, p_confirmed_at timestamptz DEFAULT NULL)
    RETURNS SETOF public.label_recording_type_claims
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v public.label_recording_type_claims;
BEGIN
    IF NOT (SELECT private.is_lead()) THEN
        RAISE EXCEPTION 'recording_type_claim_settle: leads only' USING ERRCODE = '42501';
    END IF;
    IF p_status IS NULL OR p_status NOT IN ('accepted', 'rejected') THEN
        RAISE EXCEPTION 'recording_type_claim_settle: a claim is settled as accepted or rejected, not %', coalesce(p_status, '(none)') USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v FROM public.label_recording_type_claims WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'recording_type_claim_settle: no such claim' USING ERRCODE = '22023';
    END IF;
    IF v.status = p_status THEN
        RETURN QUERY SELECT * FROM public.label_recording_type_claims WHERE id = p_id;
        RETURN;
    END IF;
    IF v.status <> 'submitted' THEN
        RAISE EXCEPTION 'conflict: claim % is already %', p_id, v.status USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.label_recording_type_claims
       SET status = p_status, reason = p_reason, settled_by = (SELECT auth.uid()), settled_at = now()
     WHERE id = p_id;
    IF p_status = 'accepted' THEN
        UPDATE public.label_videos
           SET recording_type = v.recording_type, recording_type_at = coalesce(p_confirmed_at, now()), updated_at = now()
         WHERE id = v.video_id;
    END IF;
    RETURN QUERY SELECT * FROM public.label_recording_type_claims WHERE id = p_id;
END;
$$;

REVOKE ALL ON FUNCTION public.recording_type_claim_submit(uuid, uuid, text, text),
                       public.recording_type_claim_settle(uuid, text, text, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recording_type_claim_submit(uuid, uuid, text, text),
                          public.recording_type_claim_settle(uuid, text, text, timestamptz) TO authenticated;

-- Live notices as for the other labeling tables (045): the phone and the Mac pull at once.
DROP TRIGGER IF EXISTS label_recording_type_claims_live ON public.label_recording_type_claims;
CREATE TRIGGER label_recording_type_claims_live AFTER INSERT OR UPDATE OR DELETE ON public.label_recording_type_claims
    FOR EACH STATEMENT EXECUTE FUNCTION private.notify_labeling();
