-- Fix: ins_place_quote (20261106170000) inserted the draft policy without a
-- policy_no, which is NOT NULL (unique per tenant), so placing an accepted
-- quote always failed. Number it exactly as ins_create_policy does.
create or replace function public.ins_place_quote(p_quote_id uuid)
returns public.ins_policies
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_quote public.ins_quotes;
  v_policy public.ins_policies;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into v_quote from public.ins_quotes
  where tenant_id = v_tenant and id = p_quote_id;
  if v_quote.id is null then
    raise exception 'INS_QUOTE_NOT_FOUND';
  end if;
  if v_quote.status <> 'accepted' then
    raise exception 'INS_QUOTE_NOT_ACCEPTED';
  end if;

  set local ins.via_rpc = 'on';
  insert into public.ins_policies (
    tenant_id, policy_no, client_id, insurer_id, product_line_id, status,
    inception_date, expiry_date,
    sum_insured, currency, gross_premium, commission_rate_pct,
    notes, created_by
  ) values (
    v_tenant, next_doc_number(v_tenant, 'INS_POLICY', 'POL', 5),
    v_quote.client_id, v_quote.insurer_id, v_quote.product_line_id, 'draft',
    current_date, current_date + interval '1 year',
    v_quote.sum_insured, v_quote.currency, v_quote.gross_premium, v_quote.commission_rate_pct,
    v_quote.notes, auth.uid()
  )
  returning * into v_policy;

  update public.ins_quotes
  set status = 'placed', accepted_policy_id = v_policy.id, updated_at = now()
  where tenant_id = v_tenant and id = p_quote_id;
  reset ins.via_rpc;

  return v_policy;
end;
$$;
