-- SSC Intramurals 2026 student-facing kiosk portal.
-- Run once in Supabase SQL Editor as project owner. This does not delete existing records.
-- Important: this is a public name-search kiosk. Anyone with access can search names and submit an action for a selected student.

alter table public.attendance_day_settings
  add column if not exists enable_morning_time_in boolean not null default false,
  add column if not exists enable_morning_time_out boolean not null default false,
  add column if not exists enable_afternoon_time_in boolean not null default false,
  add column if not exists enable_afternoon_time_out boolean not null default false;

-- Public kiosk records are tagged by a NULL checked_in_by; officer-recorded rows keep their officer UUID.
alter table public.attendance alter column checked_in_by drop not null;

create or replace function public.get_public_attendance_controls()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_date date := (now() at time zone 'Asia/Manila')::date; v_settings public.attendance_day_settings%rowtype;
begin
  select * into v_settings from public.attendance_day_settings where attendance_date = v_date;
  if not found then
    return jsonb_build_object('attendance_date',v_date,'enable_morning_time_in',false,'enable_morning_time_out',false,'enable_afternoon_time_in',false,'enable_afternoon_time_out',false);
  end if;
  return jsonb_build_object('attendance_date',v_date,
    'enable_morning_time_in',v_settings.enable_morning_time_in,
    'enable_morning_time_out',v_settings.enable_morning_time_out,
    'enable_afternoon_time_in',v_settings.enable_afternoon_time_in,
    'enable_afternoon_time_out',v_settings.enable_afternoon_time_out,
    'morning_time_in',v_settings.morning_time_in,
    'morning_time_out',v_settings.morning_time_out,
    'afternoon_time_in',v_settings.afternoon_time_in,
    'afternoon_time_out',v_settings.afternoon_time_out);
end; $$;

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
    select p.id,p.full_name,p.department,p.year_level
    from public.participants p
    where p.active = true and p.full_name ilike '%' || v_query || '%'
    order by p.full_name
    limit 12;
end; $$;

create or replace function public.get_student_attendance_state(p_participant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_date date := (now() at time zone 'Asia/Manila')::date; v_settings public.attendance_day_settings%rowtype; v_attendance public.attendance%rowtype;
begin
  if not exists(select 1 from public.participants p where p.id=p_participant_id and p.active=true) then
    raise exception 'Student not found or inactive.' using errcode='22023';
  end if;
  select * into v_settings from public.attendance_day_settings where attendance_date=v_date;
  select * into v_attendance from public.attendance where participant_id=p_participant_id and attendance_date=v_date;
  return jsonb_build_object(
    'controls',jsonb_build_object(
      'enable_morning_time_in',coalesce(v_settings.enable_morning_time_in,false),
      'enable_morning_time_out',coalesce(v_settings.enable_morning_time_out,false),
      'enable_afternoon_time_in',coalesce(v_settings.enable_afternoon_time_in,false),
      'enable_afternoon_time_out',coalesce(v_settings.enable_afternoon_time_out,false)),
    'attendance',jsonb_build_object(
      'morning_time_in_at',v_attendance.morning_time_in_at,
      'morning_time_out_at',v_attendance.morning_time_out_at,
      'afternoon_time_in_at',v_attendance.afternoon_time_in_at,
      'afternoon_time_out_at',v_attendance.afternoon_time_out_at));
end; $$;

create or replace function public.student_record_attendance_action(p_participant_id uuid,p_action text)
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
  if not exists(select 1 from public.participants p where p.id=p_participant_id and p.active=true) then
    raise exception 'Student not found or inactive.' using errcode='22023';
  end if;
  select * into v_settings from public.attendance_day_settings where attendance_date=v_date for share;
  v_enabled := case p_action
    when 'morning_time_in' then v_settings.enable_morning_time_in
    when 'morning_time_out' then v_settings.enable_morning_time_out
    when 'afternoon_time_in' then v_settings.enable_afternoon_time_in
    when 'afternoon_time_out' then v_settings.enable_afternoon_time_out end;
  if coalesce(v_enabled,false) is not true then
    raise exception 'This attendance action is currently closed by the SSC admin.' using errcode='42501';
  end if;
  if p_action='morning_time_out' and not exists(select 1 from public.attendance a where a.participant_id=p_participant_id and a.attendance_date=v_date and a.morning_time_in_at is not null) then
    raise exception 'Record Morning Time-in first.' using errcode='22023';
  end if;
  if p_action='afternoon_time_out' and not exists(select 1 from public.attendance a where a.participant_id=p_participant_id and a.attendance_date=v_date and a.afternoon_time_in_at is not null) then
    raise exception 'Record Afternoon Time-in first.' using errcode='22023';
  end if;

  -- Ensure the daily row exists. Kiosk submissions have no authenticated officer identity.
  insert into public.attendance(participant_id,attendance_date,checked_in_at,checked_in_by)
  values(p_participant_id,v_date,v_recorded_at,null)
  on conflict(participant_id,attendance_date) do nothing;

  -- Atomic conditional update means concurrent clicks/devices cannot both record the same slot.
  case p_action
    when 'morning_time_in' then update public.attendance set morning_time_in_at=v_recorded_at where participant_id=p_participant_id and attendance_date=v_date and morning_time_in_at is null returning morning_time_in_at into v_recorded_at;
    when 'morning_time_out' then update public.attendance set morning_time_out_at=v_recorded_at where participant_id=p_participant_id and attendance_date=v_date and morning_time_out_at is null returning morning_time_out_at into v_recorded_at;
    when 'afternoon_time_in' then update public.attendance set afternoon_time_in_at=v_recorded_at where participant_id=p_participant_id and attendance_date=v_date and afternoon_time_in_at is null returning afternoon_time_in_at into v_recorded_at;
    when 'afternoon_time_out' then update public.attendance set afternoon_time_out_at=v_recorded_at where participant_id=p_participant_id and attendance_date=v_date and afternoon_time_out_at is null returning afternoon_time_out_at into v_recorded_at;
  end case;
  if v_recorded_at is null then raise exception 'This attendance action has already been recorded for this student.' using errcode='23505'; end if;
  return v_recorded_at;
end; $$;

revoke all on function public.get_public_attendance_controls() from public;
revoke all on function public.search_active_students(text) from public;
revoke all on function public.get_student_attendance_state(uuid) from public;
revoke all on function public.student_record_attendance_action(uuid,text) from public;
grant execute on function public.get_public_attendance_controls() to anon, authenticated;
grant execute on function public.search_active_students(text) to anon, authenticated;
grant execute on function public.get_student_attendance_state(uuid) to anon, authenticated;
grant execute on function public.student_record_attendance_action(uuid,text) to anon, authenticated;
