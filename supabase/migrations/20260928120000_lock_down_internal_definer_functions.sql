-- Lock down internal SECURITY DEFINER helpers that were callable by any
-- signed-in user via /rest/v1/rpc/<name>.
--
-- Found by the 28 Sep 2026 architecture review and re-verified against the
-- live database (pg_proc + has_function_privilege) before writing this:
--
--   post_journal_entry(uuid,text,uuid,date,text,jsonb)   CRITICAL
--     Takes an arbitrary p_tenant_id and never checks it against the
--     caller, so any authenticated user could write a balanced journal
--     into ANY tenant's ledger.
--   resolve_or_create_vendor_account(uuid,text)          HIGH
--     Same shape: arbitrary tenant id, creates vendor accounts.
--   try_complete_po(uuid)                                MEDIUM-HIGH
--     Marks a delivered + fully-paid PO complete and notifies the requester.
--   apply_tenant_read_only_guard()                       MEDIUM-HIGH
--     Drops and recreates the read-only trigger on every tenant table.
--
-- Safe to revoke: every in-database caller is itself a SECURITY DEFINER
-- function owned by postgres (trg_post_*, transition_maintenance_request,
-- link_vendor_account_on_offer, confirm_po_delivered,
-- check_po_completion_on_*). A definer function runs with its owner's
-- privileges, so it can still call these. The frontend never calls any of
-- the four (ProcurementTrack.tsx only mentions try_complete_po in a
-- comment). apply_tenant_read_only_guard is only ever run from migrations.
--
-- PUBLIC and anon are revoked as well as authenticated so a future
-- "grant ... to public" or default-privilege change cannot re-open them.
-- service_role keeps EXECUTE for trusted server-side paths.

revoke all on function public.post_journal_entry(uuid, text, uuid, date, text, jsonb) from public, anon, authenticated;
grant execute on function public.post_journal_entry(uuid, text, uuid, date, text, jsonb) to service_role;

revoke all on function public.resolve_or_create_vendor_account(uuid, text) from public, anon, authenticated;
grant execute on function public.resolve_or_create_vendor_account(uuid, text) to service_role;

revoke all on function public.try_complete_po(uuid) from public, anon, authenticated;
grant execute on function public.try_complete_po(uuid) to service_role;

revoke all on function public.apply_tenant_read_only_guard() from public, anon, authenticated;
grant execute on function public.apply_tenant_read_only_guard() to service_role;

comment on function public.post_journal_entry(uuid, text, uuid, date, text, jsonb) is
  'INTERNAL: called only by SECURITY DEFINER posting triggers/RPCs. Not client-callable (no authenticated EXECUTE) because it trusts p_tenant_id. Locked down 20260928120000.';
comment on function public.resolve_or_create_vendor_account(uuid, text) is
  'INTERNAL helper for link_vendor_account_on_offer. Not client-callable. Locked down 20260928120000.';
comment on function public.try_complete_po(uuid) is
  'INTERNAL helper for PO completion triggers. Finance manual path is complete_purchase_order_manually(). Not client-callable. Locked down 20260928120000.';
comment on function public.apply_tenant_read_only_guard() is
  'MAINTENANCE: re-applies tenant_read_only_guard triggers. Run from migrations only. Not client-callable. Locked down 20260928120000.';
