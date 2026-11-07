-- =====================================================================
-- Insurance brokerage, slice R1: per-insurer remittance position
--
-- Aggregates the unremitted-premium report (20261016170000) per insurer
-- and currency, so Finance can see "insurer X is owed Y in CUR, due by
-- Z, overdue" and then record remittances through the existing
-- ins_policy_cash_requests machinery (kind='remittance').
-- Read-only RPC; same access tier as the report.
-- =====================================================================

create or replace function public.ins_insurer_remittance_position(p_as_of date default current_date)
returns table (
  insurer_id        uuid,
  insurer_name      text,
  currency          text,
  unremitted_amount numeric,
  earliest_receipt  date,
  earliest_deadline date,
  status            text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  r record;
begin
  if not public.has_module_role('insurance', array['admin', 'manager', 'member']) then
    raise exception 'INS_FORBIDDEN: insurance access is required' using errcode = '42501';
  end if;

  for r in
    select ip.insurer_id,
           coalesce(ins.name, '?') as insurer_name,
           ip.currency,
           sum(r2.unremitted_amount) as unremitted_amount,
           min(r2.receipt_date) as earliest_receipt,
           min(r2.deadline_date) as earliest_deadline
      from public.ins_policies ip
      join public.ins_insurers ins on ins.tenant_id = ip.tenant_id and ins.id = ip.insurer_id
      cross join lateral public.ins_unremitted_premium_report(p_as_of) r2
     where ip.tenant_id = v_tenant
       and r2.policy_id = ip.id
     group by ip.insurer_id, ins.name, ip.currency
  loop
    insurer_id := r.insurer_id;
    insurer_name := r.insurer_name;
    currency := r.currency;
    unremitted_amount := r.unremitted_amount;
    earliest_receipt := r.earliest_receipt;
    earliest_deadline := r.earliest_deadline;
    status := case
      when r.earliest_receipt is null then 'receipt_date_missing'
      when r.earliest_deadline is null then 'deadline_not_set'
      when r.earliest_deadline < p_as_of then 'overdue'
      when r.earliest_deadline = p_as_of then 'due_today'
      else 'within_deadline'
    end;
    return next;
  end loop;
end;
$$;

revoke all on function public.ins_insurer_remittance_position(date) from public, anon;
grant execute on function public.ins_insurer_remittance_position(date) to authenticated;
