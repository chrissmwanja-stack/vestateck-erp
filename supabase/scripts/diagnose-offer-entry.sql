-- Diagnostic for the e2e procurement failure: "offer-entry queue is empty
-- for procurement.offer@test.local" (procurement-happy-path.spec.ts,
-- "Procurement logs 2 competing offers" step).
--
-- Run this in the LOCAL Supabase Studio SQL editor (default:
-- http://localhost:54323) after `supabase start`, or via psql against the
-- local stack. Do NOT run against the linked/remote project.
--
-- The offer-entry worklist depends on two things that only seed.sql sets
-- (they are NOT in any migration):
--   1. workflow_stages.requires_offer_entry = true  on the "Procurement:
--      Offer Entry" stage (pinned id ...032) for the demo tenant
--      (00000000-0000-0000-0000-000000000001).
--   2. An approval_assignments row for procurement.offer@test.local on
--      that same stage.
--
-- If a local DB was last `supabase db reset` before those seed lines
-- landed (commit a32d255), the request advances to the Offer Entry stage
-- but this queue comes back empty and the spec times out looking for the
-- marker string.

-- 1) Stage flags for the demo tenant. Want requires_offer_entry = true on
--    ...032 (Offer Entry) and requires_offer_selection = true on ...033
--    (Budget Controller), plus a sane next_stage chain.
select id,
       name,
       sequence_order,
       requires_offer_entry,
       requires_offer_selection,
       is_finance_terminal_stage,
       next_stage_low_id,
       next_stage_high_id
from workflow_stages
where tenant_id = '00000000-0000-0000-0000-000000000001'
order by sequence_order;

-- 2) Who is assigned to which stage. Want exactly one row per test account:
--    cce@test.local            -> ...030 Cost Control Engineer
--    cost.control@test.local   -> ...031 Cost Control Manager
--    procurement.offer@test.local -> ...032 Procurement: Offer Entry  <-- key
--    procurement@test.local    -> ...033 Budget Controller
--    finance@test.local        -> ...034 Finance
select au.email,
       ws.id   as stage_id,
       ws.name as stage_name,
       aa.scope_type,
       aa.threshold_max
from approval_assignments aa
join app_users au on au.id = aa.user_id
join workflow_stages ws on ws.id = aa.workflow_stage_id
where au.email in ('cce@test.local',
                   'cost.control@test.local',
                   'procurement.offer@test.local',
                   'procurement@test.local',
                   'finance@test.local')
order by au.email;

-- 3) Where the stuck request actually sits. If the request is at the
--    ...032 stage but query 1 says requires_offer_entry = false, that is
--    the bug: the stage flag is missing. If the request is still at
--    ...030/...031, the approval steps in the spec aren't advancing it.
select r.id,
       r.item_description,
       r.current_stage_id,
       ws.name as current_stage,
       ws.requires_offer_entry,
       r.status,
       r.created_at
from requests r
join workflow_stages ws on ws.id = r.current_stage_id
where r.tenant_id = '00000000-0000-0000-0000-000000000001'
  and r.item_description like 'E2E smoke %'
order by r.created_at desc;

-- ---------------------------------------------------------------------------
-- Fix (if queries confirm the flag/assignment are missing). Either:
--   A) Preferred: `supabase db reset`  (re-runs migrations + current seed.sql)
--   B) Or apply just the missing bits:
-- ---------------------------------------------------------------------------
-- update workflow_stages set requires_offer_entry = true
-- where id = '00000000-0000-0000-0000-000000000032'; -- Procurement: Offer Entry
-- update workflow_stages set requires_offer_selection = true
-- where id = '00000000-0000-0000-0000-000000000033'; -- Budget Controller
