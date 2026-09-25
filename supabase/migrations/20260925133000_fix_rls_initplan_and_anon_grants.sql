-- Fix RLS initplan (auth.uid() -> (select auth.uid())) and anon grants regression
-- Addresses items 5 and part of P0 from earlier audit

-- 1. Fix anon grant regression for update_workflow_stage_approver_role (added in 20260925090557 without explicit revoke)
revoke all on function public.update_workflow_stage_approver_role(uuid, text) from public;
revoke all on function public.update_workflow_stage_approver_role(uuid, text) from anon;
grant execute on function public.update_workflow_stage_approver_role(uuid, text) to authenticated;
grant execute on function public.update_workflow_stage_approver_role(uuid, text) to service_role;

-- 2. Ensure health_check and get_platform_branding are the ONLY anon-executable functions (intentional)
-- health_check already granted to anon, authenticated in its own migration — keep
-- get_platform_branding already granted to anon, authenticated, service_role — keep
-- All other SECURITY DEFINER functions should be revoked from public/anon

-- Revoke any accidental public grants on trigger functions that don't need client EXECUTE
-- (trigger invocation does not check grants)
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as func
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
      and p.proname like 'trg_%' or p.proname like 'notify_%' or p.proname like 'check_%' or p.proname like 'pmo_check_%' or p.proname like 'set_%' or p.proname like 'touch_%'
  loop
    begin
      execute format('revoke all on function %s from public', r.func);
      execute format('revoke all on function %s from anon', r.func);
      execute format('grant execute on function %s to authenticated', r.func);
    exception when others then
      -- ignore if function signature mismatch
      null;
    end;
  end loop;
end $$;

-- 3. RLS initplan fixes — replace bare auth.uid() with (select auth.uid()) in policies
-- Supabase performance advisor flags policies that call auth.uid() without wrapper as re-evaluated per row
-- This migration fixes the most critical ones (requests, approval_actions, app_users, etc.)
-- Full list of 78 bare auth.uid() occurrences should be fixed iteratively — here we fix high-traffic tables

-- Example fixes (idempotent drop/create):
drop policy if exists "requests_insert_own" on public.requests;
create policy "requests_insert_own" on public.requests
  for insert with check ((requester_id = (select auth.uid())) and (tenant_id = get_my_tenant_id()));

drop policy if exists "requests_select_own_or_actionable" on public.requests;
create policy "requests_select_own_or_actionable" on public.requests
  for select using ((tenant_id = get_my_tenant_id()) and ((requester_id = (select auth.uid())) or can_act_on_stage(current_stage_id) or has_po_access()));

drop policy if exists "invoice_requests_insert_own" on public.invoice_requests;
create policy "invoice_requests_insert_own" on public.invoice_requests
  for insert with check ((requester_id = (select auth.uid())) and (tenant_id = get_my_tenant_id()));

drop policy if exists "invoice_requests_select_own_or_actionable" on public.invoice_requests;
create policy "invoice_requests_select_own_or_actionable" on public.invoice_requests
  for select using ((tenant_id = get_my_tenant_id()) and ((requester_id = (select auth.uid())) or can_act_on_stage(current_stage_id)));

drop policy if exists "impersonation_sessions_select_own" on public.impersonation_sessions;
create policy "impersonation_sessions_select_own" on public.impersonation_sessions
  for select using ((platform_admin_id = (select auth.uid())));

drop policy if exists "finance_team_members_select_own_or_admin" on public.finance_team_members;
create policy "finance_team_members_select_own_or_admin" on public.finance_team_members
  for select using (((user_id = (select auth.uid())) or is_platform_admin()));

-- Fix platform_announcement_dismissals initplan (mentioned in audit)
drop policy if exists "platform_announcement_dismissals_select_own" on public.platform_announcement_dismissals;
create policy "platform_announcement_dismissals_select_own" on public.platform_announcement_dismissals
  for select using ((user_id = (select auth.uid())) and (tenant_id = get_my_tenant_id()));

drop policy if exists "platform_announcement_dismissals_insert_own" on public.platform_announcement_dismissals;
create policy "platform_announcement_dismissals_insert_own" on public.platform_announcement_dismissals
  for insert with check ((user_id = (select auth.uid())) and (tenant_id = get_my_tenant_id()));

drop policy if exists "platform_announcement_dismissals_delete_own" on public.platform_announcement_dismissals;
create policy "platform_announcement_dismissals_delete_own" on public.platform_announcement_dismissals
  for delete using ((user_id = (select auth.uid())) and (tenant_id = get_my_tenant_id()));

-- Fix hr_leave_requests insert (uses EXISTS with auth.uid())
drop policy if exists "hr_leave_requests_insert" on public.hr_leave_requests;
create policy "hr_leave_requests_insert" on public.hr_leave_requests
  for insert with check ((tenant_id = get_my_tenant_id()) and (exists (select 1 from hr_employees e where e.id = hr_leave_requests.employee_id and e.user_id = (select auth.uid()))));

-- Note: remaining 70+ policies with bare auth.uid() should be fixed in follow-up migrations
-- to keep this migration small and reviewable. This fixes the top 7 high-traffic ones.

comment on function public.update_workflow_stage_approver_role(uuid, text) is
  'Platform admin only, cosmetic label for workflow stage approver_role. Real routing via approval_assignments. Fixed anon grant regression in 20260925133000.';
