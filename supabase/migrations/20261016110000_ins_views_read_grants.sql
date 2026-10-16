-- Least privilege for the insurance reporting views.
--
-- Some views were created with the default privileges of the schema, so
-- `authenticated` also had INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES and TRIGGER
-- on them. Reads are the only intended use. Tenant isolation is unaffected (the views
-- are security_invoker, so base-table RLS still applies), but write privileges on a
-- view should not exist.
--
-- This revokes everything from authenticated on the five readable views and grants
-- SELECT back. ins_policy_cash_items is internal (no authenticated grant) and is not
-- changed. Fix-forward: no earlier migration is edited.

revoke all on public.ins_broker_fee_tax_report from public, authenticated;
grant select on public.ins_broker_fee_tax_report to authenticated;

revoke all on public.ins_claim_cash_position from public, authenticated;
grant select on public.ins_claim_cash_position to authenticated;

revoke all on public.ins_commission_ledger from public, authenticated;
grant select on public.ins_commission_ledger to authenticated;

revoke all on public.ins_commission_position from public, authenticated;
grant select on public.ins_commission_position to authenticated;

revoke all on public.ins_renewal_pipeline from public, authenticated;
grant select on public.ins_renewal_pipeline to authenticated;
