-- Phase B, slice 1: premium received and not yet remitted to the insurer, with the
-- remittance deadline taken from the regulatory rules table.
--
-- Read-only. No posting changes.
--
-- Deadline rule: the remittance deadline is N working days after the receipt date,
-- where N is the approved value of 'remittance.deadline_working_days' on that date.
-- There is no default. If no value is approved, the deadline is null and the report
-- says 'deadline_not_set'. Public holidays are not modelled yet (Monday to Friday only).
--
-- Receipt date: the earliest posted receipt against the policy's premium. Cash is not
-- traced receipt by receipt, so this treats all cash still held as the oldest. The
-- deadline can therefore be earlier than the true one, which errs on the side of an
-- alert. Tracing receipts first-in, first-out is a later refinement.

create or replace function public.ins_remittance_due_date(p_tenant_id uuid, p_receipt_date date)
returns date
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_days numeric;
  v_due  date;
begin
  if p_receipt_date is null then
    return null;
  end if;
  begin
    v_days := platform_reg_number(p_tenant_id, 'remittance.deadline_working_days', p_receipt_date);
  exception when others then
    if sqlerrm like 'REG_PARAM_MISSING%' then
      return null;   -- no approved value: no deadline, and no default is assumed
    end if;
    raise;
  end;
  if v_days is null or v_days < 0 or v_days <> trunc(v_days) then
    raise exception 'REG_VALUE_INVALID: remittance deadline must be a whole number of working days';
  end if;
  if v_days = 0 then
    return p_receipt_date;
  end if;
  select (p_receipt_date + g.n) into v_due
    from generate_series(1, 120) as g(n)
   where extract(isodow from p_receipt_date + g.n) < 6
   order by g.n
   offset (v_days::int - 1)
   limit 1;
  return v_due;
end;
$$;

revoke all on function public.ins_remittance_due_date(uuid, date) from public, anon, authenticated;

create or replace function public.ins_unremitted_premium_report(p_as_of date default current_date)
returns table (
  policy_id        uuid,
  policy_no        text,
  insurer_id       uuid,
  unremitted_amount numeric,
  receipt_date     date,
  deadline_date    date,
  status           text
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant  uuid := get_my_tenant_id();
  p         record;
  v_avail   numeric;
  v_receipt date;
  v_due     date;
  v_status  text;
begin
  if not has_module_role('insurance', array['admin', 'manager', 'member']) then
    raise exception 'INS_FORBIDDEN: insurance access is required' using errcode = '42501';
  end if;

  for p in
    select ip.id, ip.policy_no, ip.insurer_id
      from public.ins_policies ip
     where ip.tenant_id = v_tenant
       and ip.status in ('active', 'renewed')
  loop
    v_avail := coalesce((public.ins_policy_cash_totals(p.id) ->> 'available_allocated_funds')::numeric, 0);
    continue when v_avail <= 0;

    select min(s.settlement_date) into v_receipt
      from public.fin_open_items i
      join public.fin_allocations a on a.open_item_id = i.id
      join public.fin_settlements s on s.id = a.settlement_id
       and s.status = 'posted' and s.direction = 'in'
     where i.tenant_id = v_tenant
       and i.source_type = 'ins_policy_premium'
       and i.source_id = p.id;

    v_due := public.ins_remittance_due_date(v_tenant, v_receipt);

    v_status := case
      when v_receipt is null then 'receipt_date_missing'
      when v_due is null then 'deadline_not_set'
      when v_due < p_as_of then 'overdue'
      when v_due = p_as_of then 'due_today'
      else 'within_deadline'
    end;

    policy_id := p.id;
    policy_no := p.policy_no;
    insurer_id := p.insurer_id;
    unremitted_amount := v_avail;
    receipt_date := v_receipt;
    deadline_date := v_due;
    status := v_status;
    return next;
  end loop;
end;
$$;

revoke all on function public.ins_unremitted_premium_report(date) from public, anon;
grant execute on function public.ins_unremitted_premium_report(date) to authenticated;
