-- Revoke anon EXECUTE on SECURITY DEFINER functions that should never be
-- callable by an unauthenticated caller via PostgREST RPC.
--
-- Supabase's security advisor (2026-09-16) flagged 21 functions as
-- executable by the `anon` role. Postgres grants EXECUTE to PUBLIC by
-- default unless revoked, and Supabase's exposed schema turns that into
-- a live, unauthenticated /rest/v1/rpc/<fn> endpoint. RLS on the
-- underlying tables likely blocks most of these in practice (they read
-- get_my_tenant_id()/auth.uid(), which are null for anon), but that is
-- incidental protection, not intended access control -- and several of
-- these are financial writes (post_journal_entry,
-- import_bank_statement_lines, stamp_accounting_period_close,
-- unmatch_bank_reconciliation) that should not depend on incidental
-- protection.
--
-- This migration revokes EXECUTE from PUBLIC (which covers anon) on
-- each flagged function and re-grants it to authenticated only, so
-- logged-in app behavior is unchanged. No RLS or table changes.
--
-- Trigger-only functions in this list (notify_*, trg_post_*,
-- check_journal_entry_balanced, check_accounting_period_no_overlap,
-- pmo_check_task_dependency_validity) do not need direct EXECUTE grants
-- to any role to fire as triggers -- trigger invocation does not consult
-- grants on the trigger function itself. Revoking here removes their
-- accidental direct-RPC-callability without affecting trigger behavior.

revoke execute on function public.auto_match_bank_statement(text, date, date) from public;
grant  execute on function public.auto_match_bank_statement(text, date, date) to authenticated;

revoke execute on function public.calculate_statutory_deductions(numeric, date) from public;
grant  execute on function public.calculate_statutory_deductions(numeric, date) to authenticated;

revoke execute on function public.check_accounting_period_no_overlap() from public;
grant  execute on function public.check_accounting_period_no_overlap() to authenticated;

revoke execute on function public.check_journal_entry_balanced() from public;
grant  execute on function public.check_journal_entry_balanced() to authenticated;

revoke execute on function public.get_posting_account(uuid, text) from public;
grant  execute on function public.get_posting_account(uuid, text) to authenticated;

revoke execute on function public.get_security_settings() from public;
grant  execute on function public.get_security_settings() to authenticated;

revoke execute on function public.import_bank_statement_lines(text, jsonb) from public;
grant  execute on function public.import_bank_statement_lines(text, jsonb) to authenticated;

revoke execute on function public.match_bank_statement_line(uuid, uuid) from public;
grant  execute on function public.match_bank_statement_line(uuid, uuid) to authenticated;

revoke execute on function public.notify_contract_status_change() from public;
grant  execute on function public.notify_contract_status_change() to authenticated;

revoke execute on function public.notify_leave_status_change() from public;
grant  execute on function public.notify_leave_status_change() to authenticated;

revoke execute on function public.notify_proposal_status_change() from public;
grant  execute on function public.notify_proposal_status_change() to authenticated;

revoke execute on function public.pmo_check_task_dependency_validity() from public;
grant  execute on function public.pmo_check_task_dependency_validity() to authenticated;

revoke execute on function public.post_journal_entry(uuid, text, uuid, date, text, jsonb) from public;
grant  execute on function public.post_journal_entry(uuid, text, uuid, date, text, jsonb) to authenticated;

revoke execute on function public.seed_default_chart_of_accounts() from public;
grant  execute on function public.seed_default_chart_of_accounts() to authenticated;

revoke execute on function public.seed_statutory_rate_table(date) from public;
grant  execute on function public.seed_statutory_rate_table(date) to authenticated;

revoke execute on function public.stamp_accounting_period_close() from public;
grant  execute on function public.stamp_accounting_period_close() to authenticated;

revoke execute on function public.trg_post_cash_bank_transaction() from public;
grant  execute on function public.trg_post_cash_bank_transaction() to authenticated;

revoke execute on function public.trg_post_payroll_run_approval() from public;
grant  execute on function public.trg_post_payroll_run_approval() to authenticated;

revoke execute on function public.trg_post_receivable_invoice() from public;
grant  execute on function public.trg_post_receivable_invoice() to authenticated;

revoke execute on function public.trg_post_supplier_invoice() from public;
grant  execute on function public.trg_post_supplier_invoice() to authenticated;

revoke execute on function public.unmatch_bank_reconciliation(uuid) from public;
grant  execute on function public.unmatch_bank_reconciliation(uuid) to authenticated;
