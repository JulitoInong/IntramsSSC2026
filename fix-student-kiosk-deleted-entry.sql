-- SSC Intramurals 2026: Fix kiosk attendance after an officer deletes a slot.
-- Run this once in Supabase SQL Editor. It does not delete or alter attendance records.
-- A deliberate new kiosk submission clears the cancellation marker for that exact slot,
-- matching the behavior of the admin record_attendance_action() function.

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

  -- A new online kiosk action is an intentional re-recording.
  -- Clear the officer's cancellation marker for this exact slot before the row write.
  -- If the write fails, the transaction rolls this deletion back.
  delete from public.attendance_action_cancellations
  where participant_id = p_participant_id
    and attendance_date = v_date
    and action = p_action;

  -- Ensure the daily row exists. Kiosk submissions do not have an officer identity.
  insert into public.attendance(participant_id, attendance_date, checked_in_at, checked_in_by)
  values(p_participant_id, v_date, v_recorded_at, null)
  on conflict(participant_id, attendance_date) do nothing;

  -- Atomic conditional update prevents duplicate submissions from concurrent devices.
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
