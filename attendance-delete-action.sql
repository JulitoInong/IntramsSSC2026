-- SSC Intramurals 2026: safe per-slot attendance deletion with stale-offline-sync protection.
-- Run once in Supabase SQL Editor as project owner/postgres.

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

  -- A deliberate new online record clears the cancellation marker for this exact slot.
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
  -- Record the cancellation first. The trigger blocks any stale queued sync from restoring this slot.
  insert into public.attendance_action_cancellations(participant_id,attendance_date,action,cancelled_by,cancelled_at)
  values (p_participant_id,p_attendance_date,p_action,auth.uid(),now())
  on conflict (participant_id,attendance_date,action) do update set cancelled_by=excluded.cancelled_by,cancelled_at=excluded.cancelled_at;
  execute format('update public.attendance set %I = null where participant_id = $1 and attendance_date = $2 and %I is not null',v_column,v_column)
    using p_participant_id,p_attendance_date;
  get diagnostics v_rows = row_count;
  if v_rows=0 then
    -- Keep the cancellation marker even if the row was already removed; it prevents a stale queued event from recreating it.
    return false;
  end if;
  delete from public.attendance where participant_id=p_participant_id and attendance_date=p_attendance_date
    and morning_time_in_at is null and morning_time_out_at is null and afternoon_time_in_at is null and afternoon_time_out_at is null;
  return true;
end; $$;
revoke all on function public.delete_attendance_action(uuid,date,text) from public;
grant execute on function public.delete_attendance_action(uuid,date,text) to authenticated;
