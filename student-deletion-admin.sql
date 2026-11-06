-- Safe student removal controls for SSC Intramurals 2026.
-- These functions DEACTIVATE student rows (active=false); they do not hard-delete
-- participant rows or attendance history. Run in Supabase SQL Editor as project owner.

create or replace function public.deactivate_student(p_participant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  changed_id uuid;
  changed_name text;
begin
  if auth.uid() is null or not exists (
    select 1 from public.ssc_officers o
    where o.user_id = auth.uid() and o.active = true
  ) then
    raise exception 'Only an active SSC attendance officer can deactivate students.' using errcode = '42501';
  end if;

  update public.participants p
  set active = false
  where p.id = p_participant_id
    and p.participant_type = 'Student'
    and p.active = true
  returning p.id, p.full_name into changed_id, changed_name;

  if changed_id is null then
    raise exception 'Active student not found. Refresh the roster and try again.' using errcode = '22023';
  end if;

  return jsonb_build_object('id', changed_id, 'full_name', changed_name, 'active', false);
end;
$$;

create or replace function public.deactivate_all_students()
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  changed_count integer;
begin
  if auth.uid() is null or not exists (
    select 1 from public.ssc_officers o
    where o.user_id = auth.uid() and o.active = true
  ) then
    raise exception 'Only an active SSC attendance officer can deactivate students.' using errcode = '42501';
  end if;

  update public.participants
  set active = false
  where participant_type = 'Student' and active = true;

  get diagnostics changed_count = row_count;
  return changed_count;
end;
$$;

revoke all on function public.deactivate_student(uuid) from public, anon;
revoke all on function public.deactivate_all_students() from public, anon;
grant execute on function public.deactivate_student(uuid) to authenticated;
grant execute on function public.deactivate_all_students() to authenticated;
