-- Apply only after reviewing public.ssc_participant_import in Supabase Table Editor.
-- Expected current roster: 1,170 rows, 1,170 distinct non-null internal IDs, no blank names/departments.
-- This upsert does not delete participants omitted from the CSV and never matches by name.

insert into public.participants (id, student_number, full_name, department, year_level, participant_type, active)
select id, nullif(trim(student_number), ''), trim(full_name), trim(department), year_level,
       coalesce(nullif(trim(participant_type), ''), 'Student'),
       coalesce(active, true)
from public.ssc_participant_import
where id is not null
  and nullif(trim(full_name), '') is not null
  and nullif(trim(department), '') is not null
on conflict (id) do update set
  student_number = coalesce(excluded.student_number, public.participants.student_number),
  full_name = excluded.full_name,
  department = excluded.department,
  year_level = excluded.year_level,
  participant_type = excluded.participant_type,
  active = excluded.active;

-- Internal UUIDs are stable IDs, not official student numbers. Do not regenerate them after importing.
-- Existing records with different IDs are not automatically matched by name; reconcile prior imports manually.
-- Do not truncate public.participants or public.attendance.
