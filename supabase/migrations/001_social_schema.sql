-- ============================================================
-- BumpSetCut Social Schema
-- Run via Supabase Dashboard > SQL Editor (not shipped in app)
-- ============================================================

-- MARK: Extensions
create extension if not exists "uuid-ossp";

-- ============================================================
-- TABLES
-- ============================================================

-- Profiles (auto-created on signup via trigger)
create table if not exists profiles (
    id          text primary key,  -- matches Supabase auth.users.id
    display_name text not null default 'Volleyball Player',
    username    text unique not null,
    avatar_url  text,
    bio         text,
    team_name   text,
    followers_count  int not null default 0,
    following_count  int not null default 0,
    highlights_count int not null default 0,
    privacy_level text not null default 'public'
        check (privacy_level in ('public', 'followers_only', 'private')),
    created_at  timestamptz not null default now()
);

-- Highlights (rally clips shared to feed)
create table if not exists highlights (
    id              text primary key default uuid_generate_v4()::text,
    author_id       text not null references profiles(id) on delete cascade,
    mux_playback_id text not null,
    thumbnail_url   text,
    caption         text,
    tags            text[] not null default '{}',
    rally_metadata  jsonb not null,
    likes_count     int not null default 0,
    comments_count  int not null default 0,
    local_video_id  uuid,
    local_rally_index int,
    created_at      timestamptz not null default now()
);

create index if not exists idx_highlights_author on highlights(author_id);
create index if not exists idx_highlights_created on highlights(created_at desc);

-- Likes
create table if not exists likes (
    id           text primary key default uuid_generate_v4()::text,
    highlight_id text not null references highlights(id) on delete cascade,
    user_id      text not null references profiles(id) on delete cascade,
    created_at   timestamptz not null default now(),
    unique(highlight_id, user_id)
);

create index if not exists idx_likes_highlight on likes(highlight_id);
create index if not exists idx_likes_user on likes(user_id);

-- Comments
create table if not exists comments (
    id           text primary key default uuid_generate_v4()::text,
    highlight_id text not null references highlights(id) on delete cascade,
    author_id    text not null references profiles(id) on delete cascade,
    text         text not null,
    likes_count  int not null default 0,
    created_at   timestamptz not null default now()
);

create index if not exists idx_comments_highlight on comments(highlight_id);

-- Follows
create table if not exists follows (
    id           text primary key default uuid_generate_v4()::text,
    follower_id  text not null references profiles(id) on delete cascade,
    following_id text not null references profiles(id) on delete cascade,
    created_at   timestamptz not null default now(),
    unique(follower_id, following_id),
    check(follower_id != following_id)
);

create index if not exists idx_follows_follower on follows(follower_id);
create index if not exists idx_follows_following on follows(following_id);

-- ============================================================
-- ROW-LEVEL SECURITY
-- ============================================================

alter table profiles enable row level security;
alter table highlights enable row level security;
alter table likes enable row level security;
alter table comments enable row level security;
alter table follows enable row level security;

-- Profiles: public read, owner write
create policy "profiles_select" on profiles for select using (true);
create policy "profiles_update" on profiles for update using (auth.uid()::text = id);

-- Highlights: public read, author write
create policy "highlights_select" on highlights for select using (true);
create policy "highlights_insert" on highlights for insert with check (auth.uid()::text = author_id);
create policy "highlights_delete" on highlights for delete using (auth.uid()::text = author_id);

-- Likes: public read, auth insert/delete own
create policy "likes_select" on likes for select using (true);
create policy "likes_insert" on likes for insert with check (auth.uid()::text = user_id);
create policy "likes_delete" on likes for delete using (auth.uid()::text = user_id);

-- Comments: public read, auth insert, author delete
create policy "comments_select" on comments for select using (true);
create policy "comments_insert" on comments for insert with check (auth.uid()::text = author_id);
create policy "comments_delete" on comments for delete using (auth.uid()::text = author_id);

-- Follows: public read, auth insert/delete own
create policy "follows_select" on follows for select using (true);
create policy "follows_insert" on follows for insert with check (auth.uid()::text = follower_id);
create policy "follows_delete" on follows for delete using (auth.uid()::text = follower_id);

-- ============================================================
-- TRIGGERS: Auto-create profile on signup
-- ============================================================

create or replace function handle_new_user()
returns trigger as $$
begin
    insert into profiles (id, display_name, username)
    values (
        new.id::text,
        coalesce(new.raw_user_meta_data->>'full_name', 'Volleyball Player'),
        'user_' || left(new.id::text, 8)
    )
    on conflict (id) do nothing;
    return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute procedure handle_new_user();

-- ============================================================
-- TRIGGERS: Counter updates
-- ============================================================

-- Likes count on highlights
create or replace function update_likes_count()
returns trigger as $$
begin
    if TG_OP = 'INSERT' then
        update highlights set likes_count = likes_count + 1 where id = NEW.highlight_id;
    elsif TG_OP = 'DELETE' then
        update highlights set likes_count = greatest(likes_count - 1, 0) where id = OLD.highlight_id;
    end if;
    return coalesce(NEW, OLD);
end;
$$ language plpgsql security definer;

drop trigger if exists on_like_change on likes;
create trigger on_like_change
    after insert or delete on likes
    for each row execute procedure update_likes_count();

-- Comments count on highlights
create or replace function update_comments_count()
returns trigger as $$
begin
    if TG_OP = 'INSERT' then
        update highlights set comments_count = comments_count + 1 where id = NEW.highlight_id;
    elsif TG_OP = 'DELETE' then
        update highlights set comments_count = greatest(comments_count - 1, 0) where id = OLD.highlight_id;
    end if;
    return coalesce(NEW, OLD);
end;
$$ language plpgsql security definer;

drop trigger if exists on_comment_change on comments;
create trigger on_comment_change
    after insert or delete on comments
    for each row execute procedure update_comments_count();

-- Followers/following count on profiles
create or replace function update_follow_counts()
returns trigger as $$
begin
    if TG_OP = 'INSERT' then
        update profiles set followers_count = followers_count + 1 where id = NEW.following_id;
        update profiles set following_count = following_count + 1 where id = NEW.follower_id;
    elsif TG_OP = 'DELETE' then
        update profiles set followers_count = greatest(followers_count - 1, 0) where id = OLD.following_id;
        update profiles set following_count = greatest(following_count - 1, 0) where id = OLD.follower_id;
    end if;
    return coalesce(NEW, OLD);
end;
$$ language plpgsql security definer;

drop trigger if exists on_follow_change on follows;
create trigger on_follow_change
    after insert or delete on follows
    for each row execute procedure update_follow_counts();

-- Highlights count on profiles
create or replace function update_highlights_count()
returns trigger as $$
begin
    if TG_OP = 'INSERT' then
        update profiles set highlights_count = highlights_count + 1 where id = NEW.author_id;
    elsif TG_OP = 'DELETE' then
        update profiles set highlights_count = greatest(highlights_count - 1, 0) where id = OLD.author_id;
    end if;
    return coalesce(NEW, OLD);
end;
$$ language plpgsql security definer;

drop trigger if exists on_highlight_change on highlights;
create trigger on_highlight_change
    after insert or delete on highlights
    for each row execute procedure update_highlights_count();

-- ============================================================
-- STORAGE: Videos bucket
-- ============================================================

insert into storage.buckets (id, name, public)
values ('videos', 'videos', true)
on conflict (id) do nothing;

create policy "videos_select" on storage.objects for select
    using (bucket_id = 'videos');

create policy "videos_insert" on storage.objects for insert
    with check (bucket_id = 'videos' and auth.role() = 'authenticated');

create policy "videos_delete" on storage.objects for delete
    using (bucket_id = 'videos' and auth.uid()::text = (storage.foldername(name))[1]);
