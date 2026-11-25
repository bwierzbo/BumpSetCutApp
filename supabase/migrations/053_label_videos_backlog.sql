-- 053: the labeling backlog (owner, 2026-11-06: "skip videos and put them into the backlog if they won't be good
-- ones to mark the rallies"). A recording a labeler sets aside: it leaves the marking queue on the phone and the
-- work queue on the Mac until someone puts it back. Not withheld, not excluded — the marks it has still count, its
-- pass is simply never complete while it is set aside. Both devices read and write it here, so they agree.
--
-- A labeler may set or clear these three columns on a row they may read (the 049 update policy); the 052 guard
-- lists what a labeler may not change and these are not on it. `backlog_at` is the time it was set aside, by
-- `backlog_by` (auth.uid of the device's account); a reason is one of the phone's and the Mac's fixed words
-- (BacklogReason in the apps) or free text.

ALTER TABLE public.label_videos
    ADD COLUMN IF NOT EXISTS backlog_reason text,
    ADD COLUMN IF NOT EXISTS backlog_at timestamptz,
    ADD COLUMN IF NOT EXISTS backlog_by uuid;

COMMENT ON COLUMN public.label_videos.backlog_reason IS 'Set aside from labeling for this reason (null: not in the backlog). Not withheld, not excluded.';
COMMENT ON COLUMN public.label_videos.backlog_at IS 'When the recording was set aside; null with backlog_reason.';
COMMENT ON COLUMN public.label_videos.backlog_by IS 'Who set it aside (auth.uid).';

ALTER TABLE public.label_videos DROP CONSTRAINT IF EXISTS label_videos_backlog_consistent;
ALTER TABLE public.label_videos ADD CONSTRAINT label_videos_backlog_consistent
    CHECK ((backlog_reason IS NULL) = (backlog_at IS NULL));
