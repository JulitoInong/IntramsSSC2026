-- ==============================================================================
-- SSC INTRAMURALS 2026: OFFICIAL SSC OFFICERS ROSTER UPGRADE
-- SAFE MATCH BY SYSTEM ID: Preserves 100% of original masterlist full_name & department!
-- Run this script in the Supabase SQL Editor once confirmed.
-- ==============================================================================

-- 1. Ensure the optional 'position' column exists in public.participants
alter table public.participants add column if not exists position text;

-- 2. Update official SSC Officers by their verified system UUID
-- Note: full_name and department are intentionally NOT modified or replaced.
update public.participants
set
  participant_type = 'SSC Officer',
  position = o.position,
  active = true
from (
  values
    ('fa2acdcd-84a0-482c-abe1-8125369776cb'::uuid, 'President'),
    ('169af25b-68e0-4924-8e75-a69217aadbe3'::uuid, 'Vice President'),
    ('64993bf3-2789-489a-aabf-5281aa2e5498'::uuid, 'Secretary'),
    ('c5311ae9-1f00-4c00-9ab3-1913af5255a4'::uuid, 'Treasurer'),
    ('7796d51c-8d53-4544-a0bd-1b26a845c16e'::uuid, 'Auditor'),
    ('31279e75-3472-4479-945c-0fdb78ad6bd4'::uuid, 'P.I.O.'),
    ('74a3e7bc-3c78-4ff9-be97-3a95daf6dc95'::uuid, 'Business Manager'),
    ('22751edf-f94a-4efa-a59f-f8483911336b'::uuid, 'Business Manager'),
    ('b3a3d899-d655-438a-840b-ece37c7567c8'::uuid, 'Senator - BSIS'),
    ('59dd63a9-f9c0-4359-95af-be7c98289c19'::uuid, 'Senator - BSAB'),
    ('770df64b-f2fa-4d90-a8dc-a4caa921048d'::uuid, 'Senator - BSSW'),
    ('02429e8c-360b-44c3-9dad-a63d931ac3f0'::uuid, 'Senator - BSMA'),
    ('61eea43a-4efe-4528-8aec-734ec6d03843'::uuid, 'Senator - BSTM')
) as o(id, position)
where public.participants.id = o.id;

-- 3. Verification query: Display the updated officers with their untouched original full names
select
  p.position,
  p.full_name as original_roster_name,
  p.department,
  p.year_level,
  p.participant_type,
  p.id
from public.participants p
where p.id in (
  'fa2acdcd-84a0-482c-abe1-8125369776cb',
  '169af25b-68e0-4924-8e75-a69217aadbe3',
  '64993bf3-2789-489a-aabf-5281aa2e5498',
  'c5311ae9-1f00-4c00-9ab3-1913af5255a4',
  '7796d51c-8d53-4544-a0bd-1b26a845c16e',
  '31279e75-3472-4479-945c-0fdb78ad6bd4',
  '74a3e7bc-3c78-4ff9-be97-3a95daf6dc95',
  '22751edf-f94a-4efa-a59f-f8483911336b',
  'b3a3d899-d655-438a-840b-ece37c7567c8',
  '59dd63a9-f9c0-4359-95af-be7c98289c19',
  '770df64b-f2fa-4d90-a8dc-a4caa921048d',
  '02429e8c-360b-44c3-9dad-a63d931ac3f0',
  '61eea43a-4efe-4528-8aec-734ec6d03843'
)
order by
  case p.position
    when 'President' then 1
    when 'Vice President' then 2
    when 'Secretary' then 3
    when 'Treasurer' then 4
    when 'Auditor' then 5
    when 'P.I.O.' then 6
    when 'Business Manager' then 7
    else 8
  end,
  p.full_name;
