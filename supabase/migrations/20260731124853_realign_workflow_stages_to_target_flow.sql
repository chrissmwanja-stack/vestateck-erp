-- Schema-driven flag marking the Finance/terminal stage. approve-stage uses this to
-- decide WHEN to mint the PO: on the approval that ROUTES INTO this stage (from
-- Budget Controller's low path or General Manager's approval), not on the approval
-- taken AT this stage. Mirrors the existing requires_offer_entry /
-- blocks_offer_submitter_approval pattern rather than hardcoding a stage UUID in code.
alter table workflow_stages add column if not exists is_finance_terminal_stage boolean not null default false;

update workflow_stages set is_finance_terminal_stage = true
where id = '00000000-0000-0000-0000-000000000034'; -- Finance

-- Rename to match the agreed terminology.
update workflow_stages set name = 'Budget Controller'
where id = '00000000-0000-0000-0000-000000000033'; -- was "Control Chief/Manager"

update workflow_stages set name = 'General Manager'
where id = '00000000-0000-0000-0000-000000000036'; -- was "Deputy General Manager"

-- Retire the orphan "Cost Control Manager: Budget Approval" stage (037) from the live
-- routing chain. It was inserted between Offer Entry and the threshold check but isn't
-- part of the agreed 7-stage flow. Row is kept (not deleted) because it's referenced by
-- existing approval_actions/approval_assignments history â just no longer reachable.
update workflow_stages set next_stage_low_id = null, blocks_offer_submitter_approval = false
where id = '00000000-0000-0000-0000-000000000037';

-- Offer Entry now routes straight to Budget Controller, skipping 037.
update workflow_stages set next_stage_low_id = '00000000-0000-0000-0000-000000000033'
where id = '00000000-0000-0000-0000-000000000032'; -- Procurement: Offer Entry

-- Move the segregation-of-duty flag onto Budget Controller â this is the stage that
-- actually does the threshold check, approved by "Procurement & Logistics Chief", which
-- sits in the same chain as the "Procurement/Logistics Expert" who submits the offer.
update workflow_stages set blocks_offer_submitter_approval = true
where id = '00000000-0000-0000-0000-000000000033';
