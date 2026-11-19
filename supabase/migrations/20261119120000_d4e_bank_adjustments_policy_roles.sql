-- D4e follow-up: align the live RLS policies with MIGRATION_POLICY.md rule 10.
--
-- d4e_bank_adjustments (recorded live as version 20261119064626) was applied
-- outside the repo flow with policies that name no role, so they apply to
-- PUBLIC. `anon` holds no table privileges since 20261112090000, so this is a
-- hardening/parity fix, not a behaviour change. The repo migration file for
-- 20261119064626 already carries `to authenticated`; this file makes the live
-- database match it exactly. Idempotent: safe to replay.

drop policy if exists bank_adjustments_select on public.bank_adjustments;
create policy bank_adjustments_select on public.bank_adjustments
  for select to authenticated
  using (public.is_finance_team_member(null) and tenant_id = public.get_my_tenant_id());

drop policy if exists bank_adjustment_events_select on public.bank_adjustment_events;
create policy bank_adjustment_events_select on public.bank_adjustment_events
  for select to authenticated
  using (public.is_finance_team_member(null) and tenant_id = public.get_my_tenant_id());

drop policy if exists bank_adjustment_usual_accounts_select on public.bank_adjustment_usual_accounts;
create policy bank_adjustment_usual_accounts_select on public.bank_adjustment_usual_accounts
  for select to authenticated
  using (public.is_finance_team_member(null) and tenant_id = public.get_my_tenant_id());

drop policy if exists bank_adjustment_usual_accounts_insert on public.bank_adjustment_usual_accounts;
create policy bank_adjustment_usual_accounts_insert on public.bank_adjustment_usual_accounts
  for insert to authenticated
  with check (public.is_finance_team_member('finance') and tenant_id = public.get_my_tenant_id());

drop policy if exists bank_adjustment_usual_accounts_delete on public.bank_adjustment_usual_accounts;
create policy bank_adjustment_usual_accounts_delete on public.bank_adjustment_usual_accounts
  for delete to authenticated
  using (public.is_finance_team_member('finance') and tenant_id = public.get_my_tenant_id());
