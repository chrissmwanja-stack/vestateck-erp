-- Trigger functions must not be callable via the API.
revoke execute on function public.fin_transaction_actors_guard()           from public, anon, authenticated;
revoke execute on function public.trg_fin_audit_journal_actor()            from public, anon, authenticated;
revoke execute on function public.trg_settle_supplier_invoice_open_item()  from public, anon, authenticated;