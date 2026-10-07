-- 030_label_tracks.sql
--
-- Ball tracks and the training plan, shared between RallyLab on the Mac
-- and RallyLab on the iPhone (see 028_labeling.sql):
--
-- label_tracks — a rally tracked frame by frame: the ball (or "hidden") on
--   every frame, ~30 a second. Edited on either side; the newer wins. A
--   rally deleted on the phone is kept as `deleted` so the Mac removes it too.
-- label_project_state — a RallyLab project's training plan as the Mac
--   ran it (rounds trained, their packages and runs) and each run's
--   scores, for the iPhone's Plan tab. Written by the Mac only.
--
-- Labelers only, like the rest of the labeling data.

CREATE TABLE IF NOT EXISTS public.label_tracks (
    id         uuid PRIMARY KEY,
    video_id   uuid NOT NULL REFERENCES public.label_videos(id) ON DELETE CASCADE,
    start      double precision NOT NULL,
    "end"      double precision NOT NULL,
    -- [[time, state, origin, x, y, w, h, confidence], …]; state 0 unknown,
    -- 1 visible, 2 hidden; origin 0 auto, 1 user, 2 filled; the box (Vision-
    -- normalised, upright) only when visible.
    points     jsonb NOT NULL DEFAULT '[]'::jsonb,
    done       boolean NOT NULL DEFAULT false,
    deleted    boolean NOT NULL DEFAULT false,
    updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.label_tracks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.label_tracks FROM anon;
CREATE INDEX IF NOT EXISTS label_tracks_video_id_idx ON public.label_tracks (video_id);
CREATE INDEX IF NOT EXISTS label_tracks_updated_by_idx ON public.label_tracks (updated_by);

CREATE TABLE IF NOT EXISTS public.label_project_state (
    project    text PRIMARY KEY,
    -- training_plan.json: the rounds trained.
    plan       jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- {run name: {slice: F1}} for the runs brought back.
    scores     jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.label_project_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.label_project_state FROM anon;
CREATE INDEX IF NOT EXISTS label_project_state_updated_by_idx ON public.label_project_state (updated_by);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['label_tracks', 'label_project_state'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS "%1$s_labelers" ON public.%1$I', t);
        EXECUTE format('CREATE POLICY "%1$s_labelers" ON public.%1$I FOR ALL TO authenticated
                        USING ((SELECT private.is_labeler())) WITH CHECK ((SELECT private.is_labeler()))', t);
    END LOOP;
END $$;
