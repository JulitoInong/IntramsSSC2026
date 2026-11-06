-- SSC Intramurals 2026: safe bulk import using persistent internal system UUIDs.
-- Run AFTER reviewing schema.sql / upgrade-daily-attendance.sql. Dashboard-only staging table.
-- `id` is generated once in the supplied import CSV and is NOT an official student number.

create table if not exists public.ssc_participant_import (
  id uuid primary key,
  student_number text,
  full_name text not null,
  department text not null,
  year_level smallint check (year_level between 1 and 6),
  participant_type text not null default 'Student'
    check (participant_type in ('Student','SSC Officer')),
  active boolean not null default true,
  imported_at timestamptz not null default now()
);

-- Upgrade a staging table created by the older template, if it already exists.
alter table public.ssc_participant_import add column if not exists id uuid;
alter table public.ssc_participant_import add column if not exists year_level smallint check (year_level between 1 and 6);
update public.ssc_participant_import set id = gen_random_uuid() where id is null;
-- Drop the old student_number primary key first; PostgreSQL otherwise will not allow student_number to become nullable.
do $$
declare pk_name text;
begin
  select c.conname into pk_name
  from pg_constraint c
  where c.conrelid = 'public.ssc_participant_import'::regclass
    and c.contype = 'p'
    and (select array_agg(a.attname order by a.attname)
         from unnest(c.conkey) as key(attnum)
         join pg_attribute a on a.attrelid = c.conrelid and a.attnum = key.attnum) = array['student_number']::name[];
  if pk_name is not null then
    execute format('alter table public.ssc_participant_import drop constraint %I', pk_name);
  end if;
end $$;
alter table public.ssc_participant_import alter column id set not null;
alter table public.ssc_participant_import alter column student_number drop not null;
create unique index if not exists ssc_participant_import_id_uidx on public.ssc_participant_import(id);

alter table public.ssc_participant_import enable row level security;
revoke all on public.ssc_participant_import from anon, authenticated;

-- If staging already contains old test/import rows, review them and clear ONLY the staging table before loading the new CSV.
-- Never truncate public.participants or public.attendance.
-- Import the supplied CSV through Supabase Table Editor into public.ssc_participant_import.
-- Review first:
-- select count(*) as rows_to_import,
--        count(distinct id) as unique_system_ids,
--        count(*) filter (where id is null) as missing_system_ids,
--        count(*) filter (where nullif(trim(full_name), '') is null) as blank_names,
--        count(*) filter (where nullif(trim(department), '') is null) as blank_departments
-- from public.ssc_participant_import;
--
-- Review sample rows:
-- select id, student_number, full_name, department, year_level, participant_type, active
-- from public.ssc_participant_import order by department, full_name limit 50;
--
-- Check duplicate names (duplicates may be valid separate students; never merge automatically):
-- select lower(trim(full_name)) as normalized_name, count(*)
-- from public.ssc_participant_import group by lower(trim(full_name)) having count(*) > 1;
--
-- Only run the upsert after confirming 1,170 expected rows, 1,170 distinct non-null IDs,
-- no blank names/departments, and correct department labels.

-- IMPORTANT: This setup/review script intentionally does NOT apply the roster.
-- After importing the CSV and checking the row count/IDs/names/departments, run apply-student-import.sql separately.
-- Do not truncate public.participants or public.attendance.
