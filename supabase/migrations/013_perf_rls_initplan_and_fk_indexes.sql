-- ============================================================
-- Performance: RLS initplan + FK covering indexes
--
-- 1) RLS policies that call auth.uid() directly re-evaluate it for
--    every row. Wrapping in (select auth.uid()) makes Postgres treat
--    it as an initplan (evaluated once per query). Behaviour is
--    identical; only the per-row cost changes. (Supabase linter
--    0003_auth_rls_initplan.)
-- 2) Add covering indexes for foreign keys flagged by the linter
--    (0001_unindexed_foreign_keys).
-- ============================================================

-- comment_likes
alter policy "comment_likes_delete" on comment_likes using ((select auth.uid())::text = user_id);
alter policy "comment_likes_insert" on comment_likes with check ((select auth.uid())::text = user_id);

-- comments
alter policy "comments_delete" on comments using ((select auth.uid())::text = author_id);
alter policy "comments_insert" on comments with check ((select auth.uid())::text = author_id);

-- content_reports
alter policy "Users can create reports" on content_reports with check ((select auth.uid())::text = reporter_id);
alter policy "Users can view their own reports" on content_reports using ((select auth.uid())::text = reporter_id);

-- flywheel_contributions
alter policy "flywheel_delete" on flywheel_contributions using ((select auth.uid())::text = user_id);
alter policy "flywheel_insert" on flywheel_contributions with check ((select auth.uid())::text = user_id);
alter policy "flywheel_select" on flywheel_contributions using ((select auth.uid())::text = user_id);

-- follows
alter policy "follows_delete" on follows using ((select auth.uid())::text = follower_id);
alter policy "follows_insert" on follows with check ((select auth.uid())::text = follower_id);

-- highlights
alter policy "highlights_delete" on highlights using ((select auth.uid())::text = author_id);
alter policy "highlights_insert" on highlights with check ((select auth.uid())::text = author_id);

-- likes
alter policy "likes_delete" on likes using ((select auth.uid())::text = user_id);
alter policy "likes_insert" on likes with check ((select auth.uid())::text = user_id);

-- moderation_actions
alter policy "Users can view actions against them" on moderation_actions using ((select auth.uid())::text = target_user_id);

-- poll_options
alter policy "poll_options_insert" on poll_options with check (
    exists (
        select 1 from polls
        join highlights on highlights.id = polls.highlight_id
        where polls.id = poll_options.poll_id
          and highlights.author_id = (select auth.uid())::text
    )
);

-- poll_votes
alter policy "poll_votes_delete" on poll_votes using (user_id = (select auth.uid())::text);
alter policy "poll_votes_insert" on poll_votes with check (user_id = (select auth.uid())::text);

-- polls
alter policy "polls_insert" on polls with check (
    exists (
        select 1 from highlights
        where highlights.id = polls.highlight_id
          and highlights.author_id = (select auth.uid())::text
    )
);

-- profiles
alter policy "profiles_insert" on profiles with check ((select auth.uid())::text = id);
alter policy "profiles_update" on profiles using ((select auth.uid())::text = id) with check ((select auth.uid())::text = id);

-- user_blocks
alter policy "Users can create blocks" on user_blocks with check ((select auth.uid())::text = blocker_id);
alter policy "Users can delete their blocks" on user_blocks using ((select auth.uid())::text = blocker_id);
alter policy "Users can view their blocks" on user_blocks using ((select auth.uid())::text = blocker_id);

-- ------------------------------------------------------------
-- FK covering indexes
-- ------------------------------------------------------------
create index if not exists idx_comments_author on comments(author_id);
create index if not exists idx_poll_votes_option on poll_votes(option_id);
create index if not exists idx_moderation_actions_report on moderation_actions(report_id);
create index if not exists idx_content_reports_reviewed_by on content_reports(reviewed_by);
