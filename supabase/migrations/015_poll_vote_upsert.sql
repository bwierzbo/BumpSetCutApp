-- 015_poll_vote_upsert.sql
-- The app now changes a poll vote with a single upsert on (poll_id, user_id)
-- instead of delete-then-insert, whose failure window erased the user's
-- persisted vote. The upsert's conflict path is an UPDATE, so poll_votes
-- needs an UPDATE policy and the vote-count trigger must handle UPDATE.

-- Vote as yourself (mirrors the 005 insert policy; auth.uid() initplan-wrapped per 013)
DROP POLICY IF EXISTS "poll_votes_update" ON poll_votes;
CREATE POLICY "poll_votes_update" ON poll_votes FOR UPDATE
    USING (user_id = (select auth.uid())::text)
    WITH CHECK (user_id = (select auth.uid())::text);

-- Move the count from the old option to the new one when a vote changes.
-- total_votes stays the same (still exactly one vote by this user).
CREATE OR REPLACE FUNCTION on_poll_vote_change() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE poll_options SET vote_count = vote_count + 1 WHERE id = NEW.option_id;
        UPDATE polls SET total_votes = total_votes + 1 WHERE id = NEW.poll_id;
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.option_id <> OLD.option_id THEN
            UPDATE poll_options SET vote_count = vote_count - 1 WHERE id = OLD.option_id;
            UPDATE poll_options SET vote_count = vote_count + 1 WHERE id = NEW.option_id;
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE poll_options SET vote_count = vote_count - 1 WHERE id = OLD.option_id;
        UPDATE polls SET total_votes = total_votes - 1 WHERE id = OLD.poll_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS poll_vote_change ON poll_votes;
CREATE TRIGGER poll_vote_change
    AFTER INSERT OR UPDATE OR DELETE ON poll_votes
    FOR EACH ROW EXECUTE FUNCTION on_poll_vote_change();
