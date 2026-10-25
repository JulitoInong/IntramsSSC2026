-- Upgrade an existing SSC Intramurals attendance portal without deleting participant or attendance rows.
-- Review the existing schema and policies before running in Supabase SQL Editor.

alter table public.participants add column if not exists year_level smallint check (year_level between 1 and 6);

alter table public.attendance
  add column if not exists morning_time_in_at timestamptz,
  add column if not exists morning_time_out_at timestamptz,
  add column if not exists afternoon_time_in_at timestamptz,
  add column if not exists afternoon_time_out_at timestamptz;

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

alter table public.attendance_day_settings enable row level security;

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
));

-- Remove direct insert/update policies so attendance writes go through the checked RPC only.
drop policy if exists "Active officers can insert attendance" on public.attendance;
drop policy if exists "Active officers can update attendance" on public.attendance;

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

  insert into public.attendance (participant_id, attendance_date, checked_in_at, checked_in_by)
  values (p_participant_id, p_attendance_date, now(), auth.uid())
  on conflict (participant_id, attendance_date) do nothing;

  case p_action
    when 'morning_time_in' then
      update public.attendance set morning_time_in_at = now() where participant_id = p_participant_id and attendance_date = p_attendance_date and morning_time_in_at is null returning morning_time_in_at into v_recorded_at;
    when 'morning_time_out' then
      update public.attendance set morning_time_out_at = now() where participant_id = p_participant_id and attendance_date = p_attendance_date and morning_time_out_at is null returning morning_time_out_at into v_recorded_at;
    when 'afternoon_time_in' then
      update public.attendance set afternoon_time_in_at = now() where participant_id = p_participant_id and attendance_date = p_attendance_date and afternoon_time_in_at is null returning afternoon_time_in_at into v_recorded_at;
    when 'afternoon_time_out' then
      update public.attendance set afternoon_time_out_at = now() where participant_id = p_participant_id and attendance_date = p_attendance_date and afternoon_time_out_at is null returning afternoon_time_out_at into v_recorded_at;
  end case;
  if v_recorded_at is null then
    raise exception 'This attendance action has already been recorded for this student.' using errcode = '23505';
  end if;
  return v_recorded_at;
end;
$$;
revoke all on function public.record_attendance_action(uuid,date,text) from public;
grant execute on function public.record_attendance_action(uuid,date,text) to authenticated;

-- Historical rows are preserved as legacy check-ins. They are not automatically assigned to morning/afternoon.
-- Review this migration and test with a test account before using for official attendance.

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
