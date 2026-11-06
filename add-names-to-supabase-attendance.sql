-- ==============================================================================
-- SSC INTRAMURALS 2026: ADD STUDENT NAME, NUMBER & DEPT TO ATTENDANCE TABLE
-- ==============================================================================
-- Run this in Supabase SQL Editor as project owner.
-- This adds full_name, student_number, and department columns directly to the
-- 'attendance' table so you can see student names in Supabase Table Editor!
-- It also backfills existing rows and sets an automatic trigger for all future entries.
-- ==============================================================================

-- 1. Add student information columns directly to attendance table
alter table public.attendance
  add column if not exists full_name text,
  add column if not exists student_number text,
  add column if not exists department text;

-- 2. Populate all existing attendance records immediately from participants table
update public.attendance a
set full_name = p.full_name,
    student_number = p.student_number,
    department = p.department
from public.participants p
where a.participant_id = p.id
  and (a.full_name is null or a.full_name is distinct from p.full_name);

-- 3. Automatic trigger: Whenever attendance is recorded (by student kiosk, officer portal, or offline sync),
-- look up and fill full_name, student_number, and department automatically!
create or replace function public.populate_attendance_student_info()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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

-- 4. Convenient Attendance View in Supabase (ordered by date and time)
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
