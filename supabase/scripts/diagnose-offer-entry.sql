-- Diagnostic for the e2e procurement failure at the "Procurement logs 2
-- competing offers" step (procurement-happy-path.spec.ts).
--
-- Run this in the LOCAL Supabase Studio SQL editor (default:
-- http://localhost:54323) after `supabase start`, or via psql against the
-- local stack. Do NOT run against the linked/remote project.
--
-- Three independent things must all be true for the offer-entry worklist
-- to show the request, and all three are seeded in supabase/seed.sql
-- (none of them are in a migration):
--   1. Procurement MODULE ACCESS: /offers/entry and /offers/approval-po
--      sit behind RequireModule module="procurement", which checks
--      has_module_role() -> staff_roles. Each procurement workflow
--      account needs a staff_roles row with module='procurement' (plus
--      the tenant_modules 'procurement' entitlement). Without it the
--      route renders "Not available to you" and the marker never
--      appears -- this was the actual cause of the first failures.
--   2. workflow_stages.requires_offer_entry = true on the "Procurement:
--      Offer Entry" stage (pinned id ...032) for the demo tenant
--      (00000000-0000-0000-0000-000000000001).
--   3. An approval_assignments row for procurement.offer@test.local on
--      that same stage (so get_my_approval_queue() lists it).
--
-- If a local DB was last `supabase db reset` before those seed lines
-- landed, the request advances to the Offer Entry stage but the page
-- either shows the module-access denial or an empty queue, and the spec
-- times out looking for the marker string.

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

-- 3) Module access for the two accounts that must reach the
--    procurement-gated routes (/offers/entry, /offers/approval-po).
--    RequireModule -> has_module_role() checks staff_roles(module) AND
--    tenant_modules(module) -- approval_assignments are NOT enough. Want
--    one staff_roles row each for procurement.offer@test.local and
--    procurement@test.local with module='procurement', plus the tenant
--    entitlement below.
select au.email, sr.module, sr.role
from staff_roles sr
join app_users au on au.id = sr.user_id
where au.email in ('procurement.offer@test.local', 'procurement@test.local')
order by au.email;

select tm.module
from tenant_modules tm
where tm.tenant_id = '00000000-0000-0000-0000-000000000001'
  and tm.module = 'procurement';

-- 4) Where the stuck request actually sits. If the request is at the
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
-- Fix (if queries confirm the flag/assignment/staff_roles are missing).
-- Either:
--   A) Preferred: `supabase db reset`  (re-runs migrations + current seed.sql)
--   B) Or apply just the missing bits:
-- ---------------------------------------------------------------------------
-- update workflow_stages set requires_offer_entry = true
-- where id = '00000000-0000-0000-0000-000000000032'; -- Procurement: Offer Entry
-- update workflow_stages set requires_offer_selection = true
-- where id = '00000000-0000-0000-0000-000000000033'; -- Budget Controller
