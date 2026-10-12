-- Insurance commission transfer: bank account picker for insurance managers.
--
-- fin_bank_accounts is readable by finance team members only, so an insurance
-- manager who is not on the finance team cannot list the accounts a commission
-- transfer needs. This RPC returns just the fields the transfer dialog shows
-- (no account numbers) for active ledger-currency accounts, to insurance
-- admins and managers of the caller's own company.
--
-- Re-runnable: create or replace only.

create or replace function public.ins_commission_bank_accounts()
returns table (id uuid, name text, kind text, currency text, bank_name text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can list transfer bank accounts' using errcode = '42501';
  end if;
  return query
    select b.id, b.name, b.kind, b.currency, b.bank_name
      from fin_bank_accounts b
     where b.tenant_id = get_my_tenant_id()
       and b.is_active
       and b.gl_account_id is not null
       and b.currency = fin_ledger_currency(b.tenant_id)
     order by b.kind, b.name;
end;
$$;

revoke all on function public.ins_commission_bank_accounts() from public, anon;
grant execute on function public.ins_commission_bank_accounts() to authenticated;