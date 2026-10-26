-- Safe attendance clearing controls for SSC Intramurals 2026.
-- These functions clear attendance records while registering cancellation markers
-- so stale offline queued syncs from other devices cannot resurrect deleted entries.
-- Run in Supabase SQL Editor as project owner / postgres.

-- 1. Clear attendance for a specific date
create or replace function public.clear_attendance_for_date(p_attendance_date date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cleared_count integer;
begin
  -- Validate active SSC attendance officer session
  if auth.uid() is null or not exists (
    select 1 from public.ssc_officers o
    where o.user_id = auth.uid() and o.active = true
  ) then
    raise exception 'Only an active SSC attendance officer can clear attendance.' using errcode = '42501';
  end if;

  if p_attendance_date is null then
    raise exception 'Attendance date must be specified.' using errcode = '22023';
  end if;

  -- Protect against stale offline syncs reviving deleted actions:
  -- Insert cancellation entries into attendance_action_cancellations for all active slots on this date
  insert into public.attendance_action_cancellations (participant_id, attendance_date, action, cancelled_by, cancelled_at)
  select a.participant_id, a.attendance_date, 'morning_time_in', auth.uid(), now()
  from public.attendance a
  where a.attendance_date = p_attendance_date and a.morning_time_in_at is not null
  on conflict (participant_id, attendance_date, action) do update
    set cancelled_by = excluded.cancelled_by, cancelled_at = excluded.cancelled_at;

  insert into public.attendance_action_cancellations (participant_id, attendance_date, action, cancelled_by, cancelled_at)
  select a.participant_id, a.attendance_date, 'morning_time_out', auth.uid(), now()
  from public.attendance a
  where a.attendance_date = p_attendance_date and a.morning_time_out_at is not null
  on conflict (participant_id, attendance_date, action) do update
    set cancelled_by = excluded.cancelled_by, cancelled_at = excluded.cancelled_at;

  insert into public.attendance_action_cancellations (participant_id, attendance_date, action, cancelled_by, cancelled_at)
  select a.participant_id, a.attendance_date, 'afternoon_time_in', auth.uid(), now()
  from public.attendance a
  where a.attendance_date = p_attendance_date and a.afternoon_time_in_at is not null
  on conflict (participant_id, attendance_date, action) do update
    set cancelled_by = excluded.cancelled_by, cancelled_at = excluded.cancelled_at;

  insert into public.attendance_action_cancellations (participant_id, attendance_date, action, cancelled_by, cancelled_at)
  select a.participant_id, a.attendance_date, 'afternoon_time_out', auth.uid(), now()
  from public.attendance a
  where a.attendance_date = p_attendance_date and a.afternoon_time_out_at is not null
  on conflict (participant_id, attendance_date, action) do update
    set cancelled_by = excluded.cancelled_by, cancelled_at = excluded.cancelled_at;

  -- Delete rows from attendance table for this specific date
  delete from public.attendance
  where attendance_date = p_attendance_date;

  get diagnostics v_cleared_count = row_count;
  return v_cleared_count;
end;
$$;

-- 2. Clear attendance across ALL dates (Full Event Reset)
create or replace function public.clear_all_attendance()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cleared_count integer;
begin
  -- Validate active SSC attendance officer session
  if auth.uid() is null or not exists (
    select 1 from public.ssc_officers o
    where o.user_id = auth.uid() and o.active = true
  ) then
    raise exception 'Only an active SSC attendance officer can clear attendance.' using errcode = '42501';
  end if;

  -- Register cancellation markers for all recorded slots across all dates
  insert into public.attendance_action_cancellations (participant_id, attendance_date, action, cancelled_by, cancelled_at)
  select a.participant_id, a.attendance_date, 'morning_time_in', auth.uid(), now()
  from public.attendance a
  where a.morning_time_in_at is not null
  on conflict (participant_id, attendance_date, action) do update
    set cancelled_by = excluded.cancelled_by, cancelled_at = excluded.cancelled_at;

  insert into public.attendance_action_cancellations (participant_id, attendance_date, action, cancelled_by, cancelled_at)
  select a.participant_id, a.attendance_date, 'morning_time_out', auth.uid(), now()
  from public.attendance a
  where a.morning_time_out_at is not null
  on conflict (participant_id, attendance_date, action) do update
    set cancelled_by = excluded.cancelled_by, cancelled_at = excluded.cancelled_at;

  insert into public.attendance_action_cancellations (participant_id, attendance_date, action, cancelled_by, cancelled_at)
  select a.participant_id, a.attendance_date, 'afternoon_time_in', auth.uid(), now()
  from public.attendance a
  where a.afternoon_time_in_at is not null
  on conflict (participant_id, attendance_date, action) do update
    set cancelled_by = excluded.cancelled_by, cancelled_at = excluded.cancelled_at;

  insert into public.attendance_action_cancellations (participant_id, attendance_date, action, cancelled_by, cancelled_at)
  select a.participant_id, a.attendance_date, 'afternoon_time_out', auth.uid(), now()
  from public.attendance a
  where a.afternoon_time_out_at is not null
  on conflict (participant_id, attendance_date, action) do update
    set cancelled_by = excluded.cancelled_by, cancelled_at = excluded.cancelled_at;

  -- Delete all attendance records
  delete from public.attendance;

  get diagnostics v_cleared_count = row_count;
  return v_cleared_count;
end;
$$;

-- Secure access controls
revoke all on function public.clear_attendance_for_date(date) from public, anon;
revoke all on function public.clear_all_attendance() from public, anon;
grant execute on function public.clear_attendance_for_date(date) to authenticated;
grant execute on function public.clear_all_attendance() to authenticated;
