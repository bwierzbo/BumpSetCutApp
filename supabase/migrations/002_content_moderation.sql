-- Content Moderation Schema
-- Handles user reports, blocks, and moderation actions

-- Report Types
CREATE TYPE report_type AS ENUM (
    'spam',
    'harassment',
    'inappropriate_content',
    'impersonation',
    'violence',
    'hate_speech',
    'self_harm',
    'other'
);

-- Report Status
CREATE TYPE report_status AS ENUM (
    'pending',
    'reviewed',
    'action_taken',
    'dismissed'
);

-- Content Reports Table
CREATE TABLE content_reports (
    id TEXT PRIMARY KEY DEFAULT uuid_generate_v4()::text,
    reporter_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,

    -- What is being reported
    reported_type TEXT NOT NULL, -- 'highlight', 'comment', 'user_profile'
    reported_id TEXT NOT NULL, -- ID of the content/user being reported
    reported_user_id TEXT REFERENCES profiles(id) ON DELETE CASCADE,

    -- Report details
    report_type report_type NOT NULL,
    description TEXT,

    -- Status tracking
    status report_status NOT NULL DEFAULT 'pending',
    reviewed_at TIMESTAMPTZ,
    reviewed_by TEXT REFERENCES profiles(id),
    moderator_notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- User Blocks Table
CREATE TABLE user_blocks (
    id TEXT PRIMARY KEY DEFAULT uuid_generate_v4()::text,
    blocker_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    blocked_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,

    reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Prevent duplicate blocks
    UNIQUE(blocker_id, blocked_id),

    -- Prevent self-blocking
    CHECK (blocker_id != blocked_id)
);

-- Moderation Actions Table (for tracking admin actions)
CREATE TABLE moderation_actions (
    id TEXT PRIMARY KEY DEFAULT uuid_generate_v4()::text,
    moderator_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    target_user_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,

    action_type TEXT NOT NULL, -- 'warning', 'content_removed', 'account_suspended', 'account_banned'
    reason TEXT NOT NULL,
    content_id TEXT, -- Optional reference to specific content
    report_id TEXT REFERENCES content_reports(id), -- Link to report if applicable

    expires_at TIMESTAMPTZ, -- For temporary suspensions
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX idx_content_reports_reporter ON content_reports(reporter_id);
CREATE INDEX idx_content_reports_reported_user ON content_reports(reported_user_id);
CREATE INDEX idx_content_reports_status ON content_reports(status);
CREATE INDEX idx_content_reports_created ON content_reports(created_at DESC);

CREATE INDEX idx_user_blocks_blocker ON user_blocks(blocker_id);
CREATE INDEX idx_user_blocks_blocked ON user_blocks(blocked_id);

CREATE INDEX idx_moderation_actions_moderator ON moderation_actions(moderator_id);
CREATE INDEX idx_moderation_actions_target ON moderation_actions(target_user_id);

-- RLS Policies

-- Content Reports: Users can create reports and view their own
ALTER TABLE content_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can create reports"
    ON content_reports FOR INSERT
    WITH CHECK (auth.uid()::text = reporter_id);

CREATE POLICY "Users can view their own reports"
    ON content_reports FOR SELECT
    USING (auth.uid()::text = reporter_id);

-- TODO: Add moderator policies when admin system is implemented

-- User Blocks: Users can manage their own blocks
ALTER TABLE user_blocks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can create blocks"
    ON user_blocks FOR INSERT
    WITH CHECK (auth.uid()::text = blocker_id);

CREATE POLICY "Users can view their blocks"
    ON user_blocks FOR SELECT
    USING (auth.uid()::text = blocker_id);

CREATE POLICY "Users can delete their blocks"
    ON user_blocks FOR DELETE
    USING (auth.uid()::text = blocker_id);

-- Moderation Actions: Read-only for regular users, write for moderators
ALTER TABLE moderation_actions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view actions against them"
    ON moderation_actions FOR SELECT
    USING (auth.uid()::text = target_user_id);

-- Updated_at trigger for content_reports
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_content_reports_updated_at
    BEFORE UPDATE ON content_reports
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Function to check if user is blocked
CREATE OR REPLACE FUNCTION is_user_blocked(blocker TEXT, blocked TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM user_blocks
        WHERE blocker_id = blocker AND blocked_id = blocked
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get blocked user IDs for a user
CREATE OR REPLACE FUNCTION get_blocked_user_ids(p_user_id TEXT)
RETURNS TABLE(blocked_id TEXT) AS $$
BEGIN
    RETURN QUERY
    SELECT user_blocks.blocked_id
    FROM user_blocks
    WHERE user_blocks.blocker_id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
