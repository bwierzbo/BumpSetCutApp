-- 003_polls.sql
-- Community post polls: one optional poll per highlight, with options and votes.

-- Polls table (one per highlight)
CREATE TABLE IF NOT EXISTS polls (
    id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    highlight_id TEXT NOT NULL UNIQUE REFERENCES highlights(id) ON DELETE CASCADE,
    question TEXT NOT NULL,
    total_votes INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Poll options
CREATE TABLE IF NOT EXISTS poll_options (
    id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    poll_id TEXT NOT NULL REFERENCES polls(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    vote_count INT NOT NULL DEFAULT 0,
    sort_order INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Poll votes (one vote per user per poll)
CREATE TABLE IF NOT EXISTS poll_votes (
    id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    poll_id TEXT NOT NULL REFERENCES polls(id) ON DELETE CASCADE,
    option_id TEXT NOT NULL REFERENCES poll_options(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (poll_id, user_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_polls_highlight_id ON polls(highlight_id);
CREATE INDEX IF NOT EXISTS idx_poll_options_poll_id ON poll_options(poll_id);
CREATE INDEX IF NOT EXISTS idx_poll_votes_poll_id ON poll_votes(poll_id);
CREATE INDEX IF NOT EXISTS idx_poll_votes_user_id ON poll_votes(user_id);

-- RLS
ALTER TABLE polls ENABLE ROW LEVEL SECURITY;
ALTER TABLE poll_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE poll_votes ENABLE ROW LEVEL SECURITY;

-- Polls: anyone can read; only highlight author can insert
CREATE POLICY "polls_select" ON polls FOR SELECT USING (true);
CREATE POLICY "polls_insert" ON polls FOR INSERT WITH CHECK (
    EXISTS (
        SELECT 1 FROM highlights
        WHERE highlights.id = highlight_id
        AND highlights.author_id = auth.uid()::text
    )
);

-- Poll options: anyone can read; only highlight author (via poll) can insert
CREATE POLICY "poll_options_select" ON poll_options FOR SELECT USING (true);
CREATE POLICY "poll_options_insert" ON poll_options FOR INSERT WITH CHECK (
    EXISTS (
        SELECT 1 FROM polls
        JOIN highlights ON highlights.id = polls.highlight_id
        WHERE polls.id = poll_id
        AND highlights.author_id = auth.uid()::text
    )
);

-- Poll votes: anyone can read; insert only for yourself AND not the post author; delete own votes
CREATE POLICY "poll_votes_select" ON poll_votes FOR SELECT USING (true);
CREATE POLICY "poll_votes_insert" ON poll_votes FOR INSERT WITH CHECK (
    user_id = auth.uid()::text
    AND NOT EXISTS (
        SELECT 1 FROM polls
        JOIN highlights ON highlights.id = polls.highlight_id
        WHERE polls.id = poll_id
        AND highlights.author_id = auth.uid()::text
    )
);
CREATE POLICY "poll_votes_delete" ON poll_votes FOR DELETE USING (
    user_id = auth.uid()::text
);

-- Trigger: update vote counts on insert/delete
CREATE OR REPLACE FUNCTION on_poll_vote_change() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE poll_options SET vote_count = vote_count + 1 WHERE id = NEW.option_id;
        UPDATE polls SET total_votes = total_votes + 1 WHERE id = NEW.poll_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE poll_options SET vote_count = vote_count - 1 WHERE id = OLD.option_id;
        UPDATE polls SET total_votes = total_votes - 1 WHERE id = OLD.poll_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER poll_vote_change
    AFTER INSERT OR DELETE ON poll_votes
    FOR EACH ROW EXECUTE FUNCTION on_poll_vote_change();
