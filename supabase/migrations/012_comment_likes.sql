-- ============================================================
-- Comment likes
-- Adds a per-user like table for comments and keeps
-- comments.likes_count in sync via trigger. Mirrors the
-- existing `likes` table (for highlights) in 001_social_schema.sql.
-- ============================================================

create table if not exists comment_likes (
    id         text primary key default uuid_generate_v4()::text,
    comment_id text not null references comments(id) on delete cascade,
    user_id    text not null references profiles(id) on delete cascade,
    created_at timestamptz not null default now(),
    unique(comment_id, user_id)
);

create index if not exists idx_comment_likes_comment on comment_likes(comment_id);
create index if not exists idx_comment_likes_user on comment_likes(user_id);

-- Row level security: anyone can read like rows; users may only
-- insert/delete their own (mirrors the `likes` policies).
alter table comment_likes enable row level security;

drop policy if exists "comment_likes_select" on comment_likes;
create policy "comment_likes_select" on comment_likes for select using (true);

drop policy if exists "comment_likes_insert" on comment_likes;
create policy "comment_likes_insert" on comment_likes for insert with check (auth.uid()::text = user_id);

drop policy if exists "comment_likes_delete" on comment_likes;
create policy "comment_likes_delete" on comment_likes for delete using (auth.uid()::text = user_id);

-- Keep comments.likes_count accurate.
create or replace function update_comment_likes_count()
returns trigger as $$
begin
    if TG_OP = 'INSERT' then
        update comments set likes_count = likes_count + 1 where id = NEW.comment_id;
    elsif TG_OP = 'DELETE' then
        update comments set likes_count = greatest(likes_count - 1, 0) where id = OLD.comment_id;
    end if;
    return coalesce(NEW, OLD);
end;
$$ language plpgsql security definer;

drop trigger if exists on_comment_like_change on comment_likes;
create trigger on_comment_like_change
    after insert or delete on comment_likes
    for each row execute procedure update_comment_likes_count();
