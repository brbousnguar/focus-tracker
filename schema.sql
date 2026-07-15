-- Focus Tracker — Supabase schema.
-- Run once in Supabase: Dashboard -> SQL Editor -> paste -> Run.

create table if not exists public.sessions (
    id            bigint generated always as identity primary key,
    started_at    timestamptz not null unique,   -- unique = dedup key for retries
    ended_at      timestamptz not null,
    category      text not null,
    session_names text[] not null default '{}', -- reusable selections tied to category
    description   text default '',              -- optional note for this occurrence
    duration_min  int not null,
    device        text default '',               -- 'mac' / 'windows'
    created_at    timestamptz default now()
);

-- Safe when upgrading an existing installation created before session names.
alter table public.sessions
    add column if not exists session_names text[] not null default '{}';

-- Row Level Security: on, with policies scoped to the public (anon) key the apps use.
-- Personal single-user setup; the anon key lives only in your local config.json.
alter table public.sessions enable row level security;

drop policy if exists "anon can insert" on public.sessions;
create policy "anon can insert" on public.sessions
    for insert to anon with check (true);

drop policy if exists "anon can read" on public.sessions;
create policy "anon can read" on public.sessions
    for select to anon using (true);

-- Required by clients that retry with `resolution=merge-duplicates` when a
-- session with the same started_at already exists.
drop policy if exists "anon can update" on public.sessions;
create policy "anon can update" on public.sessions
    for update to anon using (true) with check (true);

drop policy if exists "anon can delete" on public.sessions;
create policy "anon can delete" on public.sessions
    for delete to anon using (true);

-- Handy analysis view (optional): totals per category.
create or replace view public.sessions_by_category as
select category,
       count(*)              as sessions,
       sum(duration_min)     as minutes,
       round(sum(duration_min)/60.0, 1) as hours
from public.sessions
group by category
order by minutes desc;
