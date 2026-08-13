-- Backfill migration: track 4 RLS policies that exist in production but were
-- never created by any tracked migration. They were first referenced via
-- ALTER POLICY / DROP POLICY (no IF EXISTS) in
-- 20260808055750_wrap_auth_uid_calls_in_select_for_rls_perf.sql and
-- 20260808060400_merge_overlapping_select_policies_pattern2.sql, which only
-- succeeded because the policies already existed directly in production
-- (created out-of-band, e.g. via SQL editor, before migration tracking
-- caught up). Replaying migrations 0001 -> present against a fresh database
-- or a Supabase branch fails at those two files without this backfill.
--
-- Each CREATE is guarded so this migration is a safe no-op against the
-- current production database (where the policies already exist) while
-- fixing the history for fresh rebuilds / branches / disaster recovery.
-- Definitions below are copied verbatim from production's pg_policies as of
-- 2026-08-13, i.e. the current, already-optimized (auth.uid() wrapped in
-- SELECT) versions -- no behavior change.

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'approval_assignments'
      and policyname = 'approval_assignments_select_own'
  ) then
    create policy approval_assignments_select_own on public.approval_assignments
      for select
      using (user_id = (select auth.uid()));
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'approval_delegations'
      and policyname = 'approval_delegations_select_involved'
  ) then
    create policy approval_delegations_select_involved on public.approval_delegations
      for select
      using (
        (delegator_user_id = (select auth.uid()))
        or (delegate_user_id = (select auth.uid()))
      );
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'request_offers'
      and policyname = 'request_offers_select_via_request'
  ) then
    create policy request_offers_select_via_request on public.request_offers
      for select
      using (
        exists (
          select 1
          from requests r
          where r.id = request_offers.request_id
            and r.tenant_id = get_my_tenant_id()
            and (
              (r.requester_id = (select auth.uid()))
              or can_act_on_stage(r.current_stage_id)
            )
        )
      );
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'requests'
      and policyname = 'requests_select_own_or_actionable'
  ) then
    create policy requests_select_own_or_actionable on public.requests
      for select
      using (
        (tenant_id = get_my_tenant_id())
        and (
          (requester_id = (select auth.uid()))
          or can_act_on_stage(current_stage_id)
          or has_po_access()
        )
      );
  end if;
end $$;