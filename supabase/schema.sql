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

-- ── RPC: sync_from_sheet ───────────────────────────────────────
-- Called by the Google Apps Script that lives inside the DBBH
-- spreadsheet (supabase/sync.gs). The sheet stays the source of
-- truth; this ingests its tabs. NOT callable with the public anon
-- key — only the service_role key the sync script holds.
--
-- Merge rules:
--   roster rows  -> status/role always follow the sheet; never
--                   flips in_roster (that comes from signing up)
--   signup rows  -> mark in_roster=true; profile fields only fill
--                   blanks so website profile edits aren't clobbered
--   events/attendance/rsvps -> full replace from the sheet

create or replace function public.sync_from_sheet(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb;
  v_first text;
  v_last  text;
begin
  for r in select * from jsonb_array_elements(coalesce(p_data->'roster','[]'::jsonb)) loop
    v_first := split_part(trim(coalesce(r->>'name','')), ' ', 1);
    v_last  := nullif(trim(substr(trim(coalesce(r->>'name','')), length(v_first) + 1)), '');
    insert into public.members (netid, first, last, year, status, role, in_roster)
    values (lower(trim(r->>'netid')), v_first, v_last, nullif(r->>'year',''),
            nullif(r->>'status',''), nullif(r->>'role',''), false)
    on conflict (netid) do update set
      status = coalesce(nullif(excluded.status,''), members.status),
      role   = excluded.role,
      first  = coalesce(members.first, excluded.first),
      last   = coalesce(members.last,  excluded.last),
      year   = coalesce(members.year,  excluded.year);
  end loop;

  for r in select * from jsonb_array_elements(coalesce(p_data->'signups','[]'::jsonb)) loop
    insert into public.members
      (netid, email, first, last, year, major, interests, looking,
       linkedin, notes, status, in_roster, joined)
    values
      (lower(trim(r->>'netid')), lower(nullif(r->>'email','')),
       nullif(r->>'first',''), nullif(r->>'last',''), nullif(r->>'year',''),
       nullif(r->>'major',''), nullif(r->>'interests',''), nullif(r->>'looking',''),
       nullif(r->>'linkedin',''), nullif(r->>'notes',''),
       'New Member', true, nullif(r->>'joined',''))
    on conflict (netid) do update set
      email     = coalesce(excluded.email, members.email),
      first     = coalesce(excluded.first, members.first),
      last      = coalesce(excluded.last,  members.last),
      year      = coalesce(members.year,      excluded.year),
      major     = coalesce(members.major,     excluded.major),
      interests = coalesce(members.interests, excluded.interests),
      looking   = coalesce(members.looking,   excluded.looking),
      linkedin  = coalesce(members.linkedin,  excluded.linkedin),
      notes     = coalesce(members.notes,     excluded.notes),
      joined    = coalesce(members.joined,    excluded.joined),
      in_roster = true;
  end loop;

  if p_data ? 'events' then
    delete from public.events where true;
    for r in select * from jsonb_array_elements(p_data->'events') loop
      insert into public.events (name, date_iso, time, venue, tag, details, rsvp_link, published)
      values (r->>'name', r->>'date_iso',
              coalesce(nullif(r->>'time',''),'TBA'),
              coalesce(nullif(r->>'venue',''),'TBA'),
              coalesce(nullif(r->>'tag',''),'Event'),
              coalesce(r->>'details',''), coalesce(r->>'rsvp_link',''), true);
    end loop;
  end if;

  if p_data ? 'attendance' then
    delete from public.attendance where true;
    for r in select * from jsonb_array_elements(p_data->'attendance') loop
      insert into public.attendance (netid, event_name, event_date)
      values (lower(trim(r->>'netid')), r->>'event_name', nullif(r->>'event_date',''));
    end loop;
  end if;

  if p_data ? 'rsvps' then
    delete from public.rsvps where true;
    for r in select * from jsonb_array_elements(p_data->'rsvps') loop
      insert into public.rsvps (netid, event_name)
      values (lower(trim(r->>'netid')), r->>'event_name');
    end loop;
  end if;

  return jsonb_build_object('ok', true,
    'members', (select count(*) from public.members),
    'events',  (select count(*) from public.events),
    'attendance', (select count(*) from public.attendance),
    'rsvps', (select count(*) from public.rsvps));
end
$$;

revoke execute on function public.sync_from_sheet(jsonb) from public, anon, authenticated;
grant  execute on function public.sync_from_sheet(jsonb) to service_role;
