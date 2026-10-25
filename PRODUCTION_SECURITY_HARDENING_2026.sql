-- ==============================================================================
-- SSC INTRAMURALS 2026: INVISIBLE SHIELD KIOSK SECURITY ENFORCEMENT
-- Target Tables: public.participants, public.attendance, public.attendance_day_settings
-- Safe, idempotent, preserves all existing student records, and does not reference attendance_view.
-- ==============================================================================

-- 1. Ensure schema prerequisites are in place
alter table public.attendance alter column checked_in_by drop not null;

alter table public.attendance_day_settings
  add column if not exists enable_morning_time_in boolean not null default false,
  add column if not exists enable_morning_time_out boolean not null default false,
  add column if not exists enable_afternoon_time_in boolean not null default false,
  add column if not exists enable_afternoon_time_out boolean not null default false;

-- Ensure cancellation tracking table exists (prevents 42P01 error on delete)
create table if not exists public.attendance_action_cancellations (
  participant_id uuid not null references public.participants(id) on delete restrict,
  attendance_date date not null,
  action text not null check (action in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out')),
  cancelled_by uuid references auth.users(id),
  cancelled_at timestamptz not null default now(),
  primary key (participant_id, attendance_date, action)
);
alter table public.attendance_action_cancellations enable row level security;


-- 2. HARDENED STUDENT SEARCH (Requires stealth p_station_key)
drop function if exists public.search_active_students(text);
drop function if exists public.search_active_students(text, text);

create or replace function public.search_active_students(
  p_query text,
  p_station_key text default null
)
returns table(id uuid, full_name text, department text, year_level smallint)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_query text := trim(coalesce(p_query, ''));
begin
  -- Stealth Station Key Verification (or Authenticated Officer Session)
  if p_station_key is distinct from 'SSC-KIOSK-2026-STATION-AUTH-SECURE-KEY' and (
    auth.uid() is null or not exists (
      select 1 from public.ssc_officers o where o.user_id = auth.uid() and o.active = true
    )
  ) then
    raise exception '42501 Unauthorized: Invalid kiosk credentials' using errcode = '42501';
  end if;

  -- Minimum 3 characters to block wide single-letter table dumps
  if char_length(v_query) < 3 then
    return;
  end if;

  return query
    select p.id, p.full_name, p.department, p.year_level
    from public.participants p
    where p.active = true
      and p.full_name ilike '%' || v_query || '%'
    order by p.full_name
    limit 12;
end;
$$;

revoke all on function public.search_active_students(text, text) from public;
grant execute on function public.search_active_students(text, text) to anon, authenticated;


-- 3. HARDENED STUDENT ATTENDANCE STATE QUERY (Requires stealth p_station_key)
drop function if exists public.get_student_attendance_state(uuid);
drop function if exists public.get_student_attendance_state(uuid, text);

create or replace function public.get_student_attendance_state(
  p_participant_id uuid,
  p_station_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_date date := (now() at time zone 'Asia/Manila')::date;
  v_settings public.attendance_day_settings%rowtype;
  v_attendance public.attendance%rowtype;
begin
  -- Stealth Station Key Verification (or Authenticated Officer Session)
  if p_station_key is distinct from 'SSC-KIOSK-2026-STATION-AUTH-SECURE-KEY' and (
    auth.uid() is null or not exists (
      select 1 from public.ssc_officers o where o.user_id = auth.uid() and o.active = true
    )
  ) then
    raise exception '42501 Unauthorized: Invalid kiosk credentials' using errcode = '42501';
  end if;

  if not exists (select 1 from public.participants p where p.id = p_participant_id and p.active = true) then
    return jsonb_build_object('success', false, 'error', 'Student not found or inactive.');
  end if;

  select * into v_settings from public.attendance_day_settings where attendance_date = v_date;
  select * into v_attendance from public.attendance where participant_id = p_participant_id and attendance_date = v_date;

  return jsonb_build_object(
    'success', true,
    'controls', jsonb_build_object(
      'enable_morning_time_in', coalesce(v_settings.enable_morning_time_in, false),
      'enable_morning_time_out', coalesce(v_settings.enable_morning_time_out, false),
      'enable_afternoon_time_in', coalesce(v_settings.enable_afternoon_time_in, false),
      'enable_afternoon_time_out', coalesce(v_settings.enable_afternoon_time_out, false)
    ),
    'attendance', jsonb_build_object(
      'morning_time_in_at', v_attendance.morning_time_in_at,
      'morning_time_out_at', v_attendance.morning_time_out_at,
      'afternoon_time_in_at', v_attendance.afternoon_time_in_at,
      'afternoon_time_out_at', v_attendance.afternoon_time_out_at
    )
  );
end;
$$;

revoke all on function public.get_student_attendance_state(uuid, text) from public;
grant execute on function public.get_student_attendance_state(uuid, text) to anon, authenticated;


-- 4. HIGH-CONCURRENCY TRANSACTIONAL KIOSK ATTENDANCE RECORDING (Requires stealth p_station_key)
drop function if exists public.student_record_attendance_action(uuid, text);
drop function if exists public.student_record_attendance_action(uuid, text, text);
drop function if exists public.student_record_attendance_action(uuid, text, text, uuid);

create or replace function public.student_record_attendance_action(
  p_participant_id uuid,
  p_action text,
  p_station_key text default null,
  p_event_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_date date := (now() at time zone 'Asia/Manila')::date;
  v_recorded_at timestamptz := clock_timestamp();
  v_existing_at timestamptz;
  v_enabled boolean := false;
  v_settings public.attendance_day_settings%rowtype;
  v_slot_label text;
begin
  -- Stealth Station Key Verification (or Authenticated Officer Session)
  if p_station_key is distinct from 'SSC-KIOSK-2026-STATION-AUTH-SECURE-KEY' and (
    auth.uid() is null or not exists (
      select 1 from public.ssc_officers o where o.user_id = auth.uid() and o.active = true
    )
  ) then
    raise exception '42501 Unauthorized: Invalid kiosk credentials' using errcode = '42501';
  end if;

  -- Validate action parameter
  if p_action not in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out') then
    return jsonb_build_object('success', false, 'error', 'Invalid attendance action.');
  end if;

  v_slot_label := case p_action
    when 'morning_time_in' then 'Morning Time-in'
    when 'morning_time_out' then 'Morning Time-out'
    when 'afternoon_time_in' then 'Afternoon Time-in'
    when 'afternoon_time_out' then 'Afternoon Time-out'
  end;

  -- Verify active student exists in participants table
  if not exists (select 1 from public.participants p where p.id = p_participant_id and p.active = true) then
    return jsonb_build_object('success', false, 'error', 'Student not found or inactive.');
  end if;

  -- Verify action is enabled for today (read-lock day settings)
  select * into v_settings from public.attendance_day_settings where attendance_date = v_date for share;
  v_enabled := case p_action
    when 'morning_time_in' then v_settings.enable_morning_time_in
    when 'morning_time_out' then v_settings.enable_morning_time_out
    when 'afternoon_time_in' then v_settings.enable_afternoon_time_in
    when 'afternoon_time_out' then v_settings.enable_afternoon_time_out
  end;

  if coalesce(v_enabled, false) is not true then
    return jsonb_build_object('success', false, 'error', 'This attendance action is currently closed by the SSC admin.');
  end if;

  -- Check prerequisites (Time-in must precede Time-out)
  if p_action = 'morning_time_out' and not exists (
    select 1 from public.attendance a
    where a.participant_id = p_participant_id and a.attendance_date = v_date and a.morning_time_in_at is not null
  ) then
    return jsonb_build_object('success', false, 'error', 'Please record Morning Time-in first.');
  end if;

  if p_action = 'afternoon_time_out' and not exists (
    select 1 from public.attendance a
    where a.participant_id = p_participant_id and a.attendance_date = v_date and a.afternoon_time_in_at is not null
  ) then
    return jsonb_build_object('success', false, 'error', 'Please record Afternoon Time-in first.');
  end if;

  -- Deliberate new online check-in clears any prior officer cancellation marker
  delete from public.attendance_action_cancellations
  where participant_id = p_participant_id
    and attendance_date = v_date
    and action = p_action;

  -- ATOMIC ROW-LEVEL LOCKING & PREPARATION
  insert into public.attendance (participant_id, attendance_date, checked_in_at, checked_in_by)
  values (p_participant_id, v_date, v_recorded_at, null)
  on conflict (participant_id, attendance_date) do nothing;

  -- EXCLUSIVE ROW LOCK: Any concurrent kiosk submitting for this student queues here!
  perform 1 from public.attendance
  where participant_id = p_participant_id and attendance_date = v_date
  for update;

  -- Inspect the current state while holding the exclusive lock
  select case p_action
    when 'morning_time_in' then morning_time_in_at
    when 'morning_time_out' then morning_time_out_at
    when 'afternoon_time_in' then afternoon_time_in_at
    when 'afternoon_time_out' then afternoon_time_out_at
  end into v_existing_at
  from public.attendance
  where participant_id = p_participant_id and attendance_date = v_date;

  -- IDEMPOTENT CONCURRENCY RETURN:
  -- If another kiosk recorded this slot in the millisecond before us: return cleanly without error!
  if v_existing_at is not null then
    return jsonb_build_object(
      'success', true,
      'already_recorded', true,
      'action', p_action,
      'recorded_at', v_existing_at,
      'message', v_slot_label || ' was already recorded today.'
    );
  end if;

  -- Perform the atomic write
  case p_action
    when 'morning_time_in' then
      update public.attendance set morning_time_in_at = v_recorded_at
      where participant_id = p_participant_id and attendance_date = v_date;
    when 'morning_time_out' then
      update public.attendance set morning_time_out_at = v_recorded_at
      where participant_id = p_participant_id and attendance_date = v_date;
    when 'afternoon_time_in' then
      update public.attendance set afternoon_time_in_at = v_recorded_at
      where participant_id = p_participant_id and attendance_date = v_date;
    when 'afternoon_time_out' then
      update public.attendance set afternoon_time_out_at = v_recorded_at
      where participant_id = p_participant_id and attendance_date = v_date;
  end case;

  return jsonb_build_object(
    'success', true,
    'already_recorded', false,
    'action', p_action,
    'recorded_at', v_recorded_at,
    'message', v_slot_label || ' recorded successfully.'
  );
end;
$$;

revoke all on function public.student_record_attendance_action(uuid, text, text, uuid) from public;
grant execute on function public.student_record_attendance_action(uuid, text, text, uuid) to anon, authenticated;
