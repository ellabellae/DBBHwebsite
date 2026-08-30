-- ═══════════════════════════════════════════════════════════════
-- dBBH portal backend — run this once in Supabase → SQL Editor
-- ═══════════════════════════════════════════════════════════════

-- ── Tables ─────────────────────────────────────────────────────

create table if not exists public.members (
  netid           text primary key,
  email           text unique,
  first           text,
  last            text,
  year            text,
  major           text,
  interests       text,
  looking         text,
  linkedin        text,
  notes           text,
  status          text default 'New Member',  -- New Member / Active Member / Fellow / Director / VP
  role            text,                       -- exec role, if any
  roles           text,                       -- extra roles, comma-separated
  fellow_eligible boolean default false,
  in_roster       boolean default true,
  joined          text,
  created_at      timestamptz default now()
);

create table if not exists public.events (
  id         bigint generated always as identity primary key,
  name       text not null,
  date_iso   text not null,          -- YYYY-MM-DD
  time       text default 'TBA',
  venue      text default 'TBA',
  tag        text default 'Event',   -- GBM / Corporate / Alumni / Conference / Incubator
  details    text default '',
  rsvp_link  text default '',
  published  boolean default true,
  created_at timestamptz default now()
);

create table if not exists public.attendance (
  id         bigint generated always as identity primary key,
  netid      text not null,
  event_name text not null,
  event_date text,
  created_at timestamptz default now()
);

create table if not exists public.rsvps (
  id         bigint generated always as identity primary key,
  netid      text not null,
  event_name text not null,
  created_at timestamptz default now()
);

-- raw log of every signup / profile-update submission (audit trail)
create table if not exists public.signups (
  id         bigint generated always as identity primary key,
  payload    jsonb not null,
  created_at timestamptz default now()
);

-- ── Row-level security ─────────────────────────────────────────
-- Everything locked down; the site talks to members/attendance/
-- rsvps/signups ONLY through the security-definer functions below,
-- so the anon key can never dump the roster.

alter table public.members    enable row level security;
alter table public.events     enable row level security;
alter table public.attendance enable row level security;
alter table public.rsvps      enable row level security;
alter table public.signups    enable row level security;

drop policy if exists "public can read published events" on public.events;
create policy "public can read published events"
  on public.events for select
  to anon, authenticated
  using (published = true);

-- ── RPC: member_lookup ─────────────────────────────────────────
-- Returns the same JSON shape the old Apps Script ?netid= endpoint
-- returned, for one netid only.

create or replace function public.member_lookup(p_netid text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m  public.members%rowtype;
  ev jsonb;
  rv jsonb;
begin
  select * into m from public.members where lower(netid) = lower(trim(p_netid));
  if not found then
    return jsonb_build_object('found', false, 'inRoster', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('name', a.event_name, 'date', a.event_date)
                            order by a.event_date), '[]'::jsonb)
    into ev from public.attendance a where lower(a.netid) = lower(m.netid);

  select coalesce(jsonb_agg(jsonb_build_object('name', r.event_name)), '[]'::jsonb)
    into rv from public.rsvps r where lower(r.netid) = lower(m.netid);

  return jsonb_build_object(
    'found', true,
    'inRoster', coalesce(m.in_roster, true),
    'rosterFirst', m.first,
    'name', trim(coalesce(m.first,'') || ' ' || coalesce(m.last,'')),
    'status', m.status,
    'role', m.role,
    'roles', m.roles,
    'fellowEligible', coalesce(m.fellow_eligible, false),
    'eventCount', (select count(*) from public.attendance a where lower(a.netid) = lower(m.netid)),
    'events', ev,
    'rsvps', rv,
    'profile', jsonb_build_object(
      'first', m.first, 'last', m.last, 'year', m.year, 'major', m.major,
      'interests', m.interests, 'looking', m.looking, 'linkedin', m.linkedin)
  );
end
$$;

-- ── RPC: member_submit ─────────────────────────────────────────
-- Handles both the signup form and profile updates (update='1'),
-- mirroring the old Apps Script POST endpoint.

create or replace function public.member_submit(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(trim(coalesce(p_data->>'email','')));
  v_netid text := split_part(v_email, '@', 1);
begin
  if v_email = '' or v_email !~ '^[^@\s]+@duke\.edu$' then
    return jsonb_build_object('ok', false, 'error', 'valid duke.edu email required');
  end if;

  insert into public.signups(payload) values (p_data);

  if coalesce(p_data->>'update','') = '1' then
    update public.members set
      year      = coalesce(nullif(p_data->>'year',''),      year),
      major     = coalesce(nullif(p_data->>'major',''),     major),
      interests = coalesce(nullif(p_data->>'interests',''), interests),
      looking   = coalesce(nullif(p_data->>'looking',''),   looking),
      linkedin  = coalesce(nullif(p_data->>'linkedin',''),  linkedin)
    where lower(email) = v_email or lower(netid) = v_netid;
    return jsonb_build_object('ok', true);
  end if;

  if exists (select 1 from public.members
             where lower(email) = v_email or lower(netid) = v_netid) then
    return jsonb_build_object('ok', true, 'duplicate', true);
  end if;

  insert into public.members
    (netid, email, first, last, year, major, interests, looking,
     linkedin, notes, status, in_roster, joined)
  values
    (v_netid, v_email, p_data->>'first', p_data->>'last', p_data->>'year',
     p_data->>'major', p_data->>'interests', p_data->>'looking',
     p_data->>'linkedin', p_data->>'notes', 'New Member', true,
     coalesce(nullif(p_data->>'joined',''), to_char(now(), 'YYYY-MM-DD')));

  return jsonb_build_object('ok', true);
end
$$;

grant execute on function public.member_lookup(text)  to anon, authenticated;
grant execute on function public.member_submit(jsonb) to anon, authenticated;
