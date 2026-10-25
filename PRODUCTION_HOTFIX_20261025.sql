-- ==============================================================================
-- SSC INTRAMURALS 2026: PRODUCTION CONSOLIDATED HOTFIX (RUN IN SUPABASE SQL EDITOR)
-- ==============================================================================
-- Run this script once in your Supabase project SQL Editor to apply all security,
-- integrity, and kiosk fixes on your live database.
-- It is safe, idempotent, and will NOT delete any student or attendance records.
-- ==============================================================================

-- 1. Ensure attendance_action_cancellations table exists (prevents stale offline resyncs)
create table if not exists public.attendance_action_cancellations (
  participant_id uuid not null references public.participants(id) on delete restrict,
  attendance_date date not null,
  action text not null check (action in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out')),
  cancelled_by uuid not null references auth.users(id),
  cancelled_at timestamptz not null default now(),
  primary key (participant_id, attendance_date, action)
);
alter table public.attendance_action_cancellations enable row level security;
revoke all on public.attendance_action_cancellations from anon, authenticated;

-- 2. Trigger to block stale offline sync events from reviving cancelled attendance
create or replace function public.prevent_cancelled_offline_attendance()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if NEW.morning_time_in_at is not null and OLD.morning_time_in_at is null and exists (
    select 1 from public.attendance_action_cancellations c where c.participant_id=NEW.participant_id and c.attendance_date=NEW.attendance_date and c.action='morning_time_in'
  ) then raise exception 'This attendance entry was deleted by an officer. Remove the stale offline entry before syncing.' using errcode='22023'; end if;
  if NEW.morning_time_out_at is not null and OLD.morning_time_out_at is null and exists (
    select 1 from public.attendance_action_cancellations c where c.participant_id=NEW.participant_id and c.attendance_date=NEW.attendance_date and c.action='morning_time_out'
  ) then raise exception 'This attendance entry was deleted by an officer. Remove the stale offline entry before syncing.' using errcode='22023'; end if;
  if NEW.afternoon_time_in_at is not null and OLD.afternoon_time_in_at is null and exists (
    select 1 from public.attendance_action_cancellations c where c.participant_id=NEW.participant_id and c.attendance_date=NEW.attendance_date and c.action='afternoon_time_in'
  ) then raise exception 'This attendance entry was deleted by an officer. Remove the stale offline entry before syncing.' using errcode='22023'; end if;
  if NEW.afternoon_time_out_at is not null and OLD.afternoon_time_out_at is null and exists (
    select 1 from public.attendance_action_cancellations c where c.participant_id=NEW.participant_id and c.attendance_date=NEW.attendance_date and c.action='afternoon_time_out'
  ) then raise exception 'This attendance entry was deleted by an officer. Remove the stale offline entry before syncing.' using errcode='22023'; end if;
  return NEW;
end; $$;

drop trigger if exists prevent_cancelled_offline_attendance on public.attendance;
create trigger prevent_cancelled_offline_attendance before update on public.attendance
for each row execute function public.prevent_cancelled_offline_attendance();

-- 3. Search active students (Hardened: minimum 3 characters required to prevent wide enumeration)
create or replace function public.search_active_students(p_query text)
returns table(id uuid, full_name text, department text, year_level smallint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_query text := trim(coalesce(p_query,''));
begin
  if char_length(v_query) < 3 then return; end if;
  return query
    select p.id, p.full_name, p.department, p.year_level
    from public.participants p
    where p.active = true and p.full_name ilike '%' || v_query || '%'
    order by p.full_name
    limit 12;
end; $$;

revoke all on function public.search_active_students(text) from public;
grant execute on function public.search_active_students(text) to anon, authenticated;

-- 4. Kiosk attendance recording (Hardened: checks admin session toggles, clears cancellation markers, atomic lock)
create or replace function public.student_record_attendance_action(
  p_participant_id uuid,
  p_action text
)
returns timestamptz
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_date date := (now() at time zone 'Asia/Manila')::date;
  v_recorded_at timestamptz := clock_timestamp();
  v_enabled boolean := false;
  v_settings public.attendance_day_settings%rowtype;
begin
  if p_action not in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out') then
    raise exception 'Invalid attendance action.' using errcode='22023';
  end if;

  if not exists (
    select 1 from public.participants p
    where p.id = p_participant_id and p.active = true
  ) then
    raise exception 'Student not found or inactive.' using errcode='22023';
  end if;

  select * into v_settings
  from public.attendance_day_settings
  where attendance_date = v_date
  for share;

  v_enabled := case p_action
    when 'morning_time_in' then v_settings.enable_morning_time_in
    when 'morning_time_out' then v_settings.enable_morning_time_out
    when 'afternoon_time_in' then v_settings.enable_afternoon_time_in
    when 'afternoon_time_out' then v_settings.enable_afternoon_time_out
  end;

  if coalesce(v_enabled, false) is not true then
    raise exception 'This attendance action is currently closed by the SSC admin.' using errcode='42501';
  end if;

  if p_action = 'morning_time_out' and not exists (
    select 1 from public.attendance a
    where a.participant_id = p_participant_id
      and a.attendance_date = v_date
      and a.morning_time_in_at is not null
  ) then
    raise exception 'Record Morning Time-in first.' using errcode='22023';
  end if;

  if p_action = 'afternoon_time_out' and not exists (
    select 1 from public.attendance a
    where a.participant_id = p_participant_id
      and a.attendance_date = v_date
      and a.afternoon_time_in_at is not null
  ) then
    raise exception 'Record Afternoon Time-in first.' using errcode='22023';
  end if;

  -- A deliberate new online kiosk action clears any cancellation marker for that slot
  delete from public.attendance_action_cancellations
  where participant_id = p_participant_id
    and attendance_date = v_date
    and action = p_action;

  -- Ensure daily attendance row exists
  insert into public.attendance(participant_id, attendance_date, checked_in_at, checked_in_by)
  values(p_participant_id, v_date, v_recorded_at, null)
  on conflict(participant_id, attendance_date) do nothing;

  -- Atomic conditional update prevents concurrent or duplicate recordings
  case p_action
    when 'morning_time_in' then
      update public.attendance
      set morning_time_in_at = v_recorded_at
      where participant_id = p_participant_id and attendance_date = v_date and morning_time_in_at is null
      returning morning_time_in_at into v_recorded_at;
    when 'morning_time_out' then
      update public.attendance
      set morning_time_out_at = v_recorded_at
      where participant_id = p_participant_id and attendance_date = v_date and morning_time_out_at is null
      returning morning_time_out_at into v_recorded_at;
    when 'afternoon_time_in' then
      update public.attendance
      set afternoon_time_in_at = v_recorded_at
      where participant_id = p_participant_id and attendance_date = v_date and afternoon_time_in_at is null
      returning afternoon_time_in_at into v_recorded_at;
    when 'afternoon_time_out' then
      update public.attendance
      set afternoon_time_out_at = v_recorded_at
      where participant_id = p_participant_id and attendance_date = v_date and afternoon_time_out_at is null
      returning afternoon_time_out_at into v_recorded_at;
  end case;

  if v_recorded_at is null then
    raise exception 'This attendance action has already been recorded for this student.' using errcode='23505';
  end if;

  return v_recorded_at;
end;
$$;

revoke all on function public.student_record_attendance_action(uuid, text) from public;
grant execute on function public.student_record_attendance_action(uuid, text) to anon, authenticated;

-- 5. Officer attendance deletion RPC
create or replace function public.delete_attendance_action(
  p_participant_id uuid,
  p_attendance_date date,
  p_action text
) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_column text; v_rows integer;
begin
  if auth.uid() is null or not exists (select 1 from public.ssc_officers o where o.user_id=auth.uid() and o.active=true) then
    raise exception 'Only an active SSC attendance officer can delete attendance.' using errcode='42501';
  end if;
  if p_action is null or p_action not in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out') then
    raise exception 'Invalid attendance action.' using errcode='22023';
  end if;
  if not exists (select 1 from public.participants p where p.id=p_participant_id) then
    raise exception 'Student not found.' using errcode='22023';
  end if;
  v_column := case p_action
    when 'morning_time_in' then 'morning_time_in_at'
    when 'morning_time_out' then 'morning_time_out_at'
    when 'afternoon_time_in' then 'afternoon_time_in_at'
    when 'afternoon_time_out' then 'afternoon_time_out_at'
  end;
  insert into public.attendance_action_cancellations(participant_id,attendance_date,action,cancelled_by,cancelled_at)
  values (p_participant_id,p_attendance_date,p_action,auth.uid(),now())
  on conflict (participant_id,attendance_date,action) do update set cancelled_by=excluded.cancelled_by,cancelled_at=excluded.cancelled_at;
  execute format('update public.attendance set %I = null where participant_id = $1 and attendance_date = $2 and %I is not null',v_column,v_column)
    using p_participant_id,p_attendance_date;
  get diagnostics v_rows = row_count;
  if v_rows=0 then
    return false;
  end if;
  delete from public.attendance where participant_id=p_participant_id and attendance_date=p_attendance_date
    and morning_time_in_at is null and morning_time_out_at is null and afternoon_time_in_at is null and afternoon_time_out_at is null;
  return true;
end; $$;

revoke all on function public.delete_attendance_action(uuid,date,text) from public;
grant execute on function public.delete_attendance_action(uuid,date,text) to authenticated;

-- 6. Add student information columns directly to attendance table for easy viewing in Supabase
alter table public.attendance
  add column if not exists full_name text,
  add column if not exists student_number text,
  add column if not exists department text;

-- Backfill existing rows
update public.attendance a
set full_name = p.full_name,
    student_number = p.student_number,
    department = p.department
from public.participants p
where a.participant_id = p.id
  and (a.full_name is null or a.full_name is distinct from p.full_name);

-- Automatic trigger to populate names on any future insert/update
create or replace function public.populate_attendance_student_info()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select p.full_name, p.student_number, p.department
  into NEW.full_name, NEW.student_number, NEW.department
  from public.participants p
  where p.id = NEW.participant_id;
  return NEW;
end;
$$;

drop trigger if exists populate_attendance_student_info on public.attendance;
create trigger populate_attendance_student_info
before insert or update of participant_id on public.attendance
for each row execute function public.populate_attendance_student_info();

create or replace view public.attendance_view as
select
  a.id,
  a.attendance_date,
  coalesce(a.full_name, p.full_name) as full_name,
  coalesce(a.student_number, p.student_number) as student_number,
  coalesce(a.department, p.department) as department,
  p.year_level,
  p.participant_type,
  a.morning_time_in_at,
  a.morning_time_out_at,
  a.afternoon_time_in_at,
  a.afternoon_time_out_at,
  a.checked_in_at,
  a.checked_in_by,
  a.participant_id
from public.attendance a
left join public.participants p on a.participant_id = p.id
order by a.attendance_date desc, a.created_at desc;

grant select on public.attendance_view to authenticated, anon;
