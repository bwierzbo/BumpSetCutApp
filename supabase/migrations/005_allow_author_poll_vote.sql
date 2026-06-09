-- Allow a post's author to vote in their own poll.
-- Previously the insert policy excluded the highlight author; drop that restriction
-- so the only requirement is that you vote as yourself (the UNIQUE(poll_id,user_id)
-- constraint still prevents double-voting).
DROP POLICY IF EXISTS "poll_votes_insert" ON poll_votes;
CREATE POLICY "poll_votes_insert" ON poll_votes FOR INSERT WITH CHECK (
    user_id = auth.uid()::text
);
