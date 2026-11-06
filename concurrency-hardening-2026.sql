-- ==============================================================================
-- SSC INTRAMURALS 2026: CONCURRENCY HARDENING & HIGH-LOAD PROTECTION
-- Run this script in the Supabase SQL Editor to bulletproof multi-kiosk concurrency.
-- ==============================================================================

-- Drop previous function signature before changing return type to jsonb
drop function if exists public.student_record_attendance_action(uuid, text);

create or replace function public.student_record_attendance_action(
  p_participant_id uuid,
  p_action text
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
  -- 1. Validate action parameter
  if p_action not in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out') then
    return jsonb_build_object('success', false, 'error', 'Invalid attendance action.');
  end if;

  v_slot_label := case p_action
    when 'morning_time_in' then 'Morning Time-in'
    when 'morning_time_out' then 'Morning Time-out'
    when 'afternoon_time_in' then 'Afternoon Time-in'
    when 'afternoon_time_out' then 'Afternoon Time-out'
  end;

  -- 2. Verify active student exists
  if not exists (select 1 from public.participants p where p.id = p_participant_id and p.active = true) then
    return jsonb_build_object('success', false, 'error', 'Student not found or inactive.');
  end if;

  -- 3. Verify action is enabled for today (read-lock day settings)
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

  -- 4. Check prerequisites (Time-in must precede Time-out)
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

  -- 5. ATOMIC ROW-LEVEL LOCKING & PREPARATION
  -- Ensure the master attendance row for this participant and date exists
  insert into public.attendance (participant_id, attendance_date, checked_in_at, checked_in_by)
  values (p_participant_id, v_date, v_recorded_at, null)
  on conflict (participant_id, attendance_date) do nothing;

  -- EXCLUSIVE ROW LOCK: Any concurrent device submitting for this exact student waits here!
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

  -- If another kiosk/device already recorded this slot: return gracefully!
  if v_existing_at is not null then
    return jsonb_build_object(
      'success', true,
      'already_recorded', true,
      'action', p_action,
      'recorded_at', v_existing_at,
      'message', v_slot_label || ' was already recorded today.'
    );
  end if;

  -- 6. Perform the atomic write
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
end; $$;

-- Maintain public execution privileges for kiosks
revoke all on function public.student_record_attendance_action(uuid,text) from public;
grant execute on function public.student_record_attendance_action(uuid,text) to anon, authenticated;
