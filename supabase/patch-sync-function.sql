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
