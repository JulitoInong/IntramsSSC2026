-- ==============================================================================
-- ROLLBACK SCRIPT: RESTORE ORIGINAL TIME-IN PREREQUISITE GUARDS
-- ==============================================================================

-- 1. RESTORE student_record_attendance_action ORIGINAL DEFINITION
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
  if p_station_key is distinct from 'SSC-KIOSK-2026-STATION-AUTH-SECURE-KEY' and (
    auth.uid() is null or not exists (
      select 1 from public.ssc_officers o where o.user_id = auth.uid() and o.active = true
    )
  ) then
    raise exception '42501 Unauthorized: Invalid kiosk credentials' using errcode = '42501';
  end if;

  if p_action not in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out') then
    return jsonb_build_object('success', false, 'error', 'Invalid attendance action.');
  end if;

  v_slot_label := case p_action
    when 'morning_time_in' then 'Morning Time-in'
    when 'morning_time_out' then 'Morning Time-out'
    when 'afternoon_time_in' then 'Afternoon Time-in'
    when 'afternoon_time_out' then 'Afternoon Time-out'
  end;

  if not exists (select 1 from public.participants p where p.id = p_participant_id and p.active = true) then
    return jsonb_build_object('success', false, 'error', 'Student not found or inactive.');
  end if;

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

  -- [RESTORED PREREQUISITE GUARDS]
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

  delete from public.attendance_action_cancellations
  where participant_id = p_participant_id
    and attendance_date = v_date
    and action = p_action;

  insert into public.attendance (participant_id, attendance_date, checked_in_at, checked_in_by)
  values (p_participant_id, v_date, v_recorded_at, null)
  on conflict (participant_id, attendance_date) do nothing;

  perform 1 from public.attendance
  where participant_id = p_participant_id and attendance_date = v_date
  for update;

  select case p_action
    when 'morning_time_in' then morning_time_in_at
    when 'morning_time_out' then morning_time_out_at
    when 'afternoon_time_in' then afternoon_time_in_at
    when 'afternoon_time_out' then afternoon_time_out_at
  end into v_existing_at
  from public.attendance
  where participant_id = p_participant_id and attendance_date = v_date;

  if v_existing_at is not null then
    return jsonb_build_object(
      'success', true,
      'already_recorded', true,
      'action', p_action,
      'recorded_at', v_existing_at,
      'message', v_slot_label || ' was already recorded today.'
    );
  end if;

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

-- 2. RESTORE record_attendance_action ORIGINAL DEFINITION
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

  if p_action is null or p_action not in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out') then
    raise exception 'Invalid attendance action.' using errcode = '22023';
  end if;

  if not exists (select 1 from public.participants p where p.id = p_participant_id and p.active = true) then
    raise exception 'Student not found or inactive.' using errcode = '22023';
  end if;

  -- [RESTORED PREREQUISITE GUARDS]
  if p_action = 'morning_time_out' and not exists (select 1 from public.attendance a where a.participant_id = p_participant_id and a.attendance_date = p_attendance_date and a.morning_time_in_at is not null) then
    raise exception 'Record Morning Time In before Morning Time Out.' using errcode = '22023';
  end if;
  if p_action = 'afternoon_time_out' and not exists (select 1 from public.attendance a where a.participant_id = p_participant_id and a.attendance_date = p_attendance_date and a.afternoon_time_in_at is not null) then
    raise exception 'Record Afternoon Time In before Afternoon Time Out.' using errcode = '22023';
  end if;

  insert into public.attendance (participant_id, attendance_date, checked_in_at, checked_in_by)
  values (p_participant_id, p_attendance_date, now(), auth.uid())
  on conflict (participant_id, attendance_date) do nothing;

  delete from public.attendance_action_cancellations
  where participant_id = p_participant_id and attendance_date = p_attendance_date and action = p_action;

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

-- 3. RESTORE sync_offline_attendance_action ORIGINAL DEFINITION
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

  -- [RESTORED PREREQUISITE GUARDS]
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
