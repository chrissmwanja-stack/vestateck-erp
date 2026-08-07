-- New schema-driven flag, same pattern as requires_offer_entry
alter table workflow_stages
  add column blocks_offer_submitter_approval boolean not null default false;

-- Make room in display ordering for the new stage
update workflow_stages set sequence_order = sequence_order + 1
  where id in (
    '00000000-0000-0000-0000-000000000033', -- Control Chief/Manager
    '00000000-0000-0000-0000-000000000034', -- Finance
    '00000000-0000-0000-0000-000000000035', -- Project Manager
    '00000000-0000-0000-0000-000000000036'  -- Deputy General Manager
  );

-- New stage: Cost Control Manager budget approval, right after offer entry
insert into workflow_stages
  (id, tenant_id, name, sequence_order, approver_role, threshold_amount,
   next_stage_low_id, next_stage_high_id, requires_offer_entry, blocks_offer_submitter_approval)
values
  ('00000000-0000-0000-0000-000000000037',
   '00000000-0000-0000-0000-000000000001',
   'Cost Control Manager: Budget Approval',
   4,
   'Cost Control Manager',
   null,
   '00000000-0000-0000-0000-000000000033', -- next: Control Chief/Manager
   null,
   false,
   true);

-- Re-point Offer Entry to route into the new stage instead of straight to Control Chief/Manager
update workflow_stages
  set next_stage_low_id = '00000000-0000-0000-0000-000000000037'
  where id = '00000000-0000-0000-0000-000000000032';

-- Give the existing Cost Control Manager the same authority on the new stage
insert into approval_assignments
  (tenant_id, user_id, workflow_stage_id, scope_type, scope_id, threshold_max)
values
  ('00000000-0000-0000-0000-000000000001',
   'b93bd287-c359-44cc-a7a6-2dd1578b06ee', -- cost.control@test.local
   '00000000-0000-0000-0000-000000000037',
   'global', null, null);
