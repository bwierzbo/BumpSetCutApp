-- ============================================================
-- BumpSetCut Data Flywheel Schema
-- Opt-in training contributions: clips of rallies the detector
-- struggled with (or the user corrected), plus per-frame evidence.
-- Run via Supabase Dashboard > SQL Editor (not shipped in app)
-- ============================================================

-- ============================================================
-- TABLE: flywheel_contributions
-- ============================================================

create table if not exists flywheel_contributions (
    id                text primary key default uuid_generate_v4()::text,
    user_id           text not null references profiles(id) on delete cascade,
    local_video_id    uuid,
    rally_index       int not null,
    clip_url          text not null,          -- object path in the private training-data bucket
    trigger_type      text not null
        check (trigger_type in ('low_score', 'user_removed', 'user_trimmed', 'reported')),
    user_reason       text,
    evidence          jsonb not null default '[]'::jsonb,
    rally_confidence  double precision,
    rally_quality     double precision,
    app_version       text,
    os_version        text,
    device_model      text,
    consent_version   text,
    created_at        timestamptz not null default now()
);

create index if not exists idx_flywheel_user on flywheel_contributions(user_id);
create index if not exists idx_flywheel_created on flywheel_contributions(created_at desc);

-- ============================================================
-- RLS: users only touch their own contributions.
-- Offline relabeling tooling reads everything via the service role,
-- which bypasses RLS — so there is intentionally no public select.
-- ============================================================

alter table flywheel_contributions enable row level security;

create policy "flywheel_select" on flywheel_contributions
    for select using (auth.uid()::text = user_id);

create policy "flywheel_insert" on flywheel_contributions
    for insert with check (auth.uid()::text = user_id);

create policy "flywheel_delete" on flywheel_contributions
    for delete using (auth.uid()::text = user_id);

-- ============================================================
-- STORAGE: private training-data bucket
-- ============================================================

insert into storage.buckets (id, name, public)
values ('training-data', 'training-data', false)
on conflict (id) do nothing;

-- Authenticated users may upload into their own {user_id}/... folder.
create policy "training_data_insert" on storage.objects for insert
    with check (
        bucket_id = 'training-data'
        and auth.role() = 'authenticated'
        and auth.uid()::text = (storage.foldername(name))[1]
    );

-- Users may read/delete only their own objects. No public select — the bucket
-- is private; the ML service role reads it out-of-band.
create policy "training_data_select" on storage.objects for select
    using (bucket_id = 'training-data' and auth.uid()::text = (storage.foldername(name))[1]);

create policy "training_data_delete" on storage.objects for delete
    using (bucket_id = 'training-data' and auth.uid()::text = (storage.foldername(name))[1]);
