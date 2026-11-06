-- ==============================================================================
-- SSC INTRAMURALS 2026: INDEPENDENT ATTENDANCE ACTION MIGRATION
-- Purpose: Remove intra-session prerequisite dependencies (Time-in before Time-out)
-- Schema Changes: NONE (Zero table, column, constraint, or relationship changes)
-- Existing Records: 100% Preserved
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. ALIGN STUDENT KIOSK RPC: student_record_attendance_action
-- ------------------------------------------------------------------------------
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
  -- 1. Stealth Station Key Verification (or Authenticated Officer Session)
  if p_station_key is distinct from 'SSC-KIOSK-2026-STATION-AUTH-SECURE-KEY' and (
    auth.uid() is null or not exists (
      select 1 from public.ssc_officers o where o.user_id = auth.uid() and o.active = true
    )
  ) then
    raise exception '42501 Unauthorized: Invalid kiosk credentials' using errcode = '42501';
  end if;

  -- 2. Validate action parameter
  if p_action not in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out') then
    return jsonb_build_object('success', false, 'error', 'Invalid attendance action.');
  end if;

  v_slot_label := case p_action
    when 'morning_time_in' then 'Morning Time-in'
    when 'morning_time_out' then 'Morning Time-out'
    when 'afternoon_time_in' then 'Afternoon Time-in'
    when 'afternoon_time_out' then 'Afternoon Time-out'
  end;

  -- 3. Verify active student exists in participants table
  if not exists (select 1 from public.participants p where p.id = p_participant_id and p.active = true) then
    return jsonb_build_object('success', false, 'error', 'Student not found or inactive.');
  end if;

  -- 4. Verify action is enabled for today (read-lock day settings)
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

  -- [REMOVED] Intra-session prerequisite checks that previously rejected Time-out without Time-in.

  -- 5. Deliberate new online check-in clears any prior officer cancellation marker
  delete from public.attendance_action_cancellations
  where participant_id = p_participant_id
    and attendance_date = v_date
    and action = p_action;

  -- 6. ATOMIC ROW-LEVEL LOCKING & PREPARATION
  insert into public.attendance (participant_id, attendance_date, checked_in_at, checked_in_by)
  values (p_participant_id, v_date, v_recorded_at, null)
  on conflict (participant_id, attendance_date) do nothing;

  -- 7. EXCLUSIVE ROW LOCK: Any concurrent kiosk submitting for this student queues here
  perform 1 from public.attendance
  where participant_id = p_participant_id and attendance_date = v_date
  for update;

  -- 8. Inspect the current state while holding the exclusive lock
  select case p_action
    when 'morning_time_in' then morning_time_in_at
    when 'morning_time_out' then morning_time_out_at
    when 'afternoon_time_in' then afternoon_time_in_at
    when 'afternoon_time_out' then afternoon_time_out_at
  end into v_existing_at
  from public.attendance
  where participant_id = p_participant_id and attendance_date = v_date;

  -- 9. IDEMPOTENT CONCURRENCY RETURN: Duplicate prevention
  if v_existing_at is not null then
    return jsonb_build_object(
      'success', true,
      'already_recorded', true,
      'action', p_action,
      'recorded_at', v_existing_at,
      'message', v_slot_label || ' was already recorded today.'
    );
  end if;

  -- 10. Perform the atomic write
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


-- ------------------------------------------------------------------------------
-- 2. ALIGN OFFICER MANUAL ATTENDANCE RPC: record_attendance_action
-- ------------------------------------------------------------------------------
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
  -- 1. Active officer verification
  if auth.uid() is null or not exists (
    select 1 from public.ssc_officers o where o.user_id = auth.uid() and o.active = true
  ) then
    raise exception 'Only an active SSC attendance officer can record attendance.' using errcode = '42501';
  end if;

  -- 2. Date validation (current Philippine date)
  if p_attendance_date is distinct from (now() at time zone 'Asia/Manila')::date then
    raise exception 'Attendance actions are available only for the current Philippine date.' using errcode = '22023';
  end if;

  -- 3. Action parameter validation
  if p_action is null or p_action not in ('morning_time_in','morning_time_out','afternoon_time_in','afternoon_time_out') then
    raise exception 'Invalid attendance action.' using errcode = '22023';
  end if;

  -- 4. Active participant check
  if not exists (select 1 from public.participants p where p.id = p_participant_id and p.active = true) then
    raise exception 'Student not found or inactive.' using errcode = '22023';
  end if;

  -- [REMOVED] Intra-session prerequisite checks that previously raised errcode 22023.

  -- 5. Preserve one row per student per date
  insert into public.attendance (participant_id, attendance_date, checked_in_at, checked_in_by)
  values (p_participant_id, p_attendance_date, now(), auth.uid())
  on conflict (participant_id, attendance_date) do nothing;

  -- 6. A deliberate new online record clears the cancellation marker for this exact slot
  delete from public.attendance_action_cancellations
  where participant_id = p_participant_id and attendance_date = p_attendance_date and action = p_action;

  -- 7. Perform slot-specific update with duplicate check
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

  -- 8. Duplicate rejection if slot was already filled
  if v_recorded_at is null then
    raise exception 'This attendance action has already been recorded for this student.' using errcode = '23505';
  end if;
  return v_recorded_at;
end;
$$;

revoke all on function public.record_attendance_action(uuid,date,text) from public;
grant execute on function public.record_attendance_action(uuid,date,text) to authenticated;


-- ------------------------------------------------------------------------------
-- 3. ALIGN OFFLINE SYNC RPC: sync_offline_attendance_action
-- ------------------------------------------------------------------------------
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
  -- 1. Active officer verification
  if auth.uid() is null or not exists (
    select 1 from public.ssc_officers o where o.user_id = auth.uid() and o.active = true
  ) then
    raise exception 'Only an active SSC attendance officer can sync offline attendance.' using errcode = '42501';
  end if;

  -- 2. Validate parameters & sync window
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

  -- 3. Idempotency check: if already processed, return stored timestamp
  if exists (select 1 from public.offline_attendance_sync_events e where e.event_id = p_event_id) then
    select e.recorded_at into v_recorded_at from public.offline_attendance_sync_events e where e.event_id = p_event_id;
    return v_recorded_at;
  end if;

  -- 4. Active participant check
  if not exists (select 1 from public.participants p where p.id = p_participant_id and p.active = true) then
    raise exception 'Student not found or inactive.' using errcode = '22023';
  end if;

  -- [REMOVED] Intra-session prerequisite checks that previously rejected offline sync.

  -- 5. Prepare master row
  insert into public.attendance (participant_id, attendance_date, checked_in_at, checked_in_by)
  values (p_participant_id, p_attendance_date, p_recorded_at, auth.uid())
  on conflict (participant_id, attendance_date) do nothing;

  -- 6. Slot update with duplicate detection
  case p_action
    when 'morning_time_in' then update public.attendance set morning_time_in_at = p_recorded_at where participant_id = p_participant_id and attendance_date = p_attendance_date and morning_time_in_at is null returning morning_time_in_at into v_recorded_at;
    when 'morning_time_out' then update public.attendance set morning_time_out_at = p_recorded_at where participant_id = p_participant_id and attendance_date = p_attendance_date and morning_time_out_at is null returning morning_time_out_at into v_recorded_at;
    when 'afternoon_time_in' then update public.attendance set afternoon_time_in_at = p_recorded_at where participant_id = p_participant_id and attendance_date = p_attendance_date and afternoon_time_in_at is null returning afternoon_time_in_at into v_recorded_at;
    when 'afternoon_time_out' then update public.attendance set afternoon_time_out_at = p_recorded_at where participant_id = p_participant_id and attendance_date = p_attendance_date and afternoon_time_out_at is null returning afternoon_time_out_at into v_recorded_at;
  end case;

  if v_recorded_at is null then
    raise exception 'This attendance action has already been recorded for this student. Review the online and offline records.' using errcode = '23505';
  end if;

  -- 7. Audit log the sync event
  insert into public.offline_attendance_sync_events(event_id, participant_id, attendance_date, action, recorded_at, officer_user_id)
  values (p_event_id, p_participant_id, p_attendance_date, p_action, v_recorded_at, auth.uid());
  return v_recorded_at;
end;
$$;

revoke all on function public.sync_offline_attendance_action(uuid,uuid,date,text,timestamptz) from public;
grant execute on function public.sync_offline_attendance_action(uuid,uuid,date,text,timestamptz) to authenticated;
