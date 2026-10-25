-- SSC Intramurals 2026 Daily Attendance Portal
-- Run in Supabase SQL Editor for a new installation. Review school privacy rules first.
create extension if not exists pgcrypto;

create table if not exists public.ssc_officers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.participants (
  id uuid primary key default gen_random_uuid(), -- internal system ID; not an official student number
  full_name text not null,
  student_number text unique,
  department text not null,
  year_level smallint check (year_level between 1 and 6),
  participant_type text not null check (participant_type in ('Student','SSC Officer')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references public.participants(id) on delete restrict,
  attendance_date date not null default (now() at time zone 'Asia/Manila')::date,
  -- Legacy audit fields retained for compatibility with existing portal records.
  checked_in_at timestamptz not null default now(),
  checked_in_by uuid not null references auth.users(id),
  morning_time_in_at timestamptz,
  morning_time_out_at timestamptz,
  afternoon_time_in_at timestamptz,
  afternoon_time_out_at timestamptz,
  created_at timestamptz not null default now(),
  constraint one_checkin_per_participant_per_day unique (participant_id, attendance_date)
);

create table if not exists public.attendance_day_settings (
  attendance_date date primary key,
  morning_time_in time not null default time '07:00',
  morning_time_out time not null default time '11:30',
  afternoon_time_in time not null default time '13:00',
  afternoon_time_out time not null default time '16:30',
  updated_by uuid not null references auth.users(id),
  updated_at timestamptz not null default now(),
  constraint valid_morning_schedule check (morning_time_in < morning_time_out),
  constraint valid_afternoon_schedule check (afternoon_time_in < afternoon_time_out),
  constraint valid_session_order check (morning_time_out <= afternoon_time_in)
);

create index if not exists participants_name_idx on public.participants using btree (full_name);
create index if not exists participants_department_idx on public.participants (department);
create index if not exists attendance_date_idx on public.attendance (attendance_date, checked_in_at desc);

alter table public.ssc_officers enable row level security;
alter table public.participants enable row level security;
alter table public.attendance enable row level security;
alter table public.attendance_day_settings enable row level security;

drop policy if exists "Officer can read own profile" on public.ssc_officers;
create policy "Officer can read own profile" on public.ssc_officers
for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "Active officers can read participants" on public.participants;
create policy "Active officers can read participants" on public.participants
for select to authenticated using (exists (
  select 1 from public.ssc_officers o where o.user_id = (select auth.uid()) and o.active = true
));

drop policy if exists "Active officers can read attendance" on public.attendance;
create policy "Active officers can read attendance" on public.attendance
for select to authenticated using (exists (
  select 1 from public.ssc_officers o where o.user_id = (select auth.uid()) and o.active = true
));
-- Attendance changes are made through the guarded RPC below, not direct browser writes.
drop policy if exists "Active officers can insert attendance" on public.attendance;
drop policy if exists "Active officers can update attendance" on public.attendance;

drop policy if exists "Active officers can read daily schedules" on public.attendance_day_settings;
create policy "Active officers can read daily schedules" on public.attendance_day_settings
for select to authenticated using (exists (
  select 1 from public.ssc_officers o where o.user_id = (select auth.uid()) and o.active = true
));
drop policy if exists "Active officers can insert daily schedules" on public.attendance_day_settings;
create policy "Active officers can insert daily schedules" on public.attendance_day_settings
for insert to authenticated with check (
  updated_by = (select auth.uid()) and exists (
    select 1 from public.ssc_officers o where o.user_id = (select auth.uid()) and o.active = true
  )
);
drop policy if exists "Active officers can update daily schedules" on public.attendance_day_settings;
create policy "Active officers can update daily schedules" on public.attendance_day_settings
for update to authenticated using (exists (
  select 1 from public.ssc_officers o where o.user_id = (select auth.uid()) and o.active = true
)) with check (
  updated_by = (select auth.uid()) and exists (
    select 1 from public.ssc_officers o where o.user_id = (select auth.uid()) and o.active = true
  )
);

create or replace function public.record_attendance_action(
  p_participant_id uuid,
  p_attendance_date date,
  p_action text
) returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recorded_at timestamptz := null;
begin
  if auth.uid() is null or not exists (
    select 1 from public.ssc_officers o where o.user_id = auth.uid() and o.active = true
  ) then
    raise exception 'Only an active SSC attendance officer can record attendance.' using errcode = '42501';
  end if;

  if p_attendance_date is distinct from (now() at time zone 'Asia/Manila')::date then
    raise exception 'Attendance actions are available only for the current Philippine date.' using errcode = '22023';
  end if;

  if p_action not in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out') then
    raise exception 'Invalid attendance action.' using errcode = '22023';
  end if;

  if not exists (select 1 from public.participants p where p.id = p_participant_id and p.active = true) then
    raise exception 'Student not found or inactive.' using errcode = '22023';
  end if;
  if p_action = 'morning_time_out' and not exists (select 1 from public.attendance a where a.participant_id = p_participant_id and a.attendance_date = p_attendance_date and a.morning_time_in_at is not null) then
    raise exception 'Record Morning Time In before Morning Time Out.' using errcode = '22023';
  end if;
  if p_action = 'afternoon_time_out' and not exists (select 1 from public.attendance a where a.participant_id = p_participant_id and a.attendance_date = p_attendance_date and a.afternoon_time_in_at is not null) then
    raise exception 'Record Afternoon Time In before Afternoon Time Out.' using errcode = '22023';
  end if;

  -- Preserve one row per student per date, even when four session actions are recorded.
  insert into public.attendance (participant_id, attendance_date, checked_in_at, checked_in_by)
  values (p_participant_id, p_attendance_date, now(), auth.uid())
  on conflict (participant_id, attendance_date) do nothing;

  case p_action
    when 'morning_time_in' then
      update public.attendance set morning_time_in_at = now()
      where participant_id = p_participant_id and attendance_date = p_attendance_date and morning_time_in_at is null
      returning morning_time_in_at into v_recorded_at;
    when 'morning_time_out' then
      update public.attendance set morning_time_out_at = now()
      where participant_id = p_participant_id and attendance_date = p_attendance_date and morning_time_out_at is null
      returning morning_time_out_at into v_recorded_at;
    when 'afternoon_time_in' then
      update public.attendance set afternoon_time_in_at = now()
      where participant_id = p_participant_id and attendance_date = p_attendance_date and afternoon_time_in_at is null
      returning afternoon_time_in_at into v_recorded_at;
    when 'afternoon_time_out' then
      update public.attendance set afternoon_time_out_at = now()
      where participant_id = p_participant_id and attendance_date = p_attendance_date and afternoon_time_out_at is null
      returning afternoon_time_out_at into v_recorded_at;
  end case;

  if v_recorded_at is null then
    raise exception 'This attendance action has already been recorded for this student.' using errcode = '23505';
  end if;
  return v_recorded_at;
end;
$$;
revoke all on function public.record_attendance_action(uuid,date,text) from public;
grant execute on function public.record_attendance_action(uuid,date,text) to authenticated;

-- Create authorized Auth users in Supabase, then add only approved user UUIDs to ssc_officers.
-- Never place a service_role key in browser code. Keep student data private and test RLS before launch.

-- Offline attendance queue support. Offline timestamps are device-captured and must be reviewed if the device clock is unreliable.
create table if not exists public.offline_attendance_sync_events (
  event_id uuid primary key,
  participant_id uuid not null references public.participants(id),
  attendance_date date not null,
  action text not null check (action in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out')),
  recorded_at timestamptz not null,
  officer_user_id uuid not null references auth.users(id),
  synced_at timestamptz not null default now()
);
alter table public.offline_attendance_sync_events enable row level security;
-- No direct client policies: only the SECURITY DEFINER RPC below may insert or inspect these records.

create or replace function public.sync_offline_attendance_action(
  p_event_id uuid,
  p_participant_id uuid,
  p_attendance_date date,
  p_action text,
  p_recorded_at timestamptz
) returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_recorded_at timestamptz := null;
  v_column text;
begin
  if auth.uid() is null or not exists (
    select 1 from public.ssc_officers o where o.user_id = auth.uid() and o.active = true
  ) then
    raise exception 'Only an active SSC attendance officer can sync offline attendance.' using errcode = '42501';
  end if;
  if p_event_id is null or p_recorded_at is null then
    raise exception 'Offline event ID and captured timestamp are required.' using errcode = '22023';
  end if;
  if p_action not in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out') then
    raise exception 'Invalid attendance action.' using errcode = '22023';
  end if;
  if (p_recorded_at at time zone 'Asia/Manila')::date is distinct from p_attendance_date then
    raise exception 'Captured timestamp does not match the attendance date in Philippine Time.' using errcode = '22023';
  end if;
  if p_recorded_at > now() + interval '5 minutes' or p_recorded_at < now() - interval '7 days' then
    raise exception 'Offline timestamp is outside the allowed sync window. Ask an administrator to review it.' using errcode = '22023';
  end if;
  if exists (select 1 from public.offline_attendance_sync_events e where e.event_id = p_event_id) then
    select e.recorded_at into v_recorded_at from public.offline_attendance_sync_events e where e.event_id = p_event_id;
    return v_recorded_at;
  end if;
  if not exists (select 1 from public.participants p where p.id = p_participant_id and p.active = true) then
    raise exception 'Student not found or inactive.' using errcode = '22023';
  end if;
  if p_action = 'morning_time_out' and not exists (select 1 from public.attendance a where a.participant_id = p_participant_id and a.attendance_date = p_attendance_date and a.morning_time_in_at is not null) then
    raise exception 'Record Morning Time In before Morning Time Out.' using errcode = '22023';
  end if;
  if p_action = 'afternoon_time_out' and not exists (select 1 from public.attendance a where a.participant_id = p_participant_id and a.attendance_date = p_attendance_date and a.afternoon_time_in_at is not null) then
    raise exception 'Record Afternoon Time In before Afternoon Time Out.' using errcode = '22023';
  end if;

  insert into public.attendance (participant_id, attendance_date, checked_in_at, checked_in_by)
  values (p_participant_id, p_attendance_date, p_recorded_at, auth.uid())
  on conflict (participant_id, attendance_date) do nothing;

  case p_action
    when 'morning_time_in' then update public.attendance set morning_time_in_at = p_recorded_at where participant_id = p_participant_id and attendance_date = p_attendance_date and morning_time_in_at is null returning morning_time_in_at into v_recorded_at;
    when 'morning_time_out' then update public.attendance set morning_time_out_at = p_recorded_at where participant_id = p_participant_id and attendance_date = p_attendance_date and morning_time_out_at is null returning morning_time_out_at into v_recorded_at;
    when 'afternoon_time_in' then update public.attendance set afternoon_time_in_at = p_recorded_at where participant_id = p_participant_id and attendance_date = p_attendance_date and afternoon_time_in_at is null returning afternoon_time_in_at into v_recorded_at;
    when 'afternoon_time_out' then update public.attendance set afternoon_time_out_at = p_recorded_at where participant_id = p_participant_id and attendance_date = p_attendance_date and afternoon_time_out_at is null returning afternoon_time_out_at into v_recorded_at;
  end case;
  if v_recorded_at is null then
    raise exception 'This attendance action has already been recorded for this student. Review the online and offline records.' using errcode = '23505';
  end if;
  insert into public.offline_attendance_sync_events(event_id, participant_id, attendance_date, action, recorded_at, officer_user_id)
  values (p_event_id, p_participant_id, p_attendance_date, p_action, v_recorded_at, auth.uid());
  return v_recorded_at;
end;
$$;
revoke all on function public.sync_offline_attendance_action(uuid,uuid,date,text,timestamptz) from public;
grant execute on function public.sync_offline_attendance_action(uuid,uuid,date,text,timestamptz) to authenticated;
