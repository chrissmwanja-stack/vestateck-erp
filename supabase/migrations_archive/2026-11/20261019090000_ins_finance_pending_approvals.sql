-- A worklist of insurance cash and cancellation items that are waiting on Finance.
--
-- Premium receipts, insurer remittances and cancellation cash all need a second Finance
-- person to approve what the first prepared. Until now the checker had to open policies one
-- at a time to find them: the Finance policy lookup says nothing about pending work, and a
-- Finance user without an Insurance role cannot read ins_policies to search for it.
--
-- ins_finance_pending_approvals() lists, for the caller's tenant and oldest first:
--   premium_cash       a pending premium receipt or insurer remittance
--   cancellation_cash  a pending cash request on a cancellation (refund, recovery, void ...)
--   cancellation       a cancellation case that is proposed or prepared and not yet decided
-- with the policy, client, insurer, currency, amount where there is one, who submitted it,
-- and is_mine: true when the caller is barred from approving it because they made it
-- (for a cancellation case, because they proposed or prepared it).
--
-- Read only. It reuses the existing Finance gate (ins_policy_cash_require_finance), so the
-- caller must be a Finance team member acting as themselves, exactly as for the policy lookup.
-- It decides nothing: approving or rejecting still goes through the existing RPCs, which
-- recheck identity, balances and maker-checker separation. At most 200 rows are returned,
-- oldest first; the oldest are the ones that have waited longest.
--
-- Re-runnable: create or replace only.

create or replace function public.ins_finance_pending_approvals()
returns table(
  item_type text,
  item_id uuid,
  policy_id uuid,
  policy_no text,
  client_name text,
  insurer_name text,
  currency text,
  kind text,
  amount numeric,
  submitted_at timestamptz,
  submitted_by_name text,
  is_mine boolean
)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform ins_policy_cash_require_finance();
  return query
  with pending as (
    select 'premium_cash'::text as p_type, r.id as p_id, r.policy_id as p_policy, r.kind as p_kind, r.amount as p_amount,
           r.created_at as p_at, r.maker_id as p_by, (r.maker_id = auth.uid()) as p_mine
      from ins_policy_cash_requests r
     where r.tenant_id = get_my_tenant_id() and r.status = 'pending'
    union all
    select 'cancellation_cash'::text, c.id, pc.policy_id, c.kind, c.amount,
           c.created_at, c.maker_id, (c.maker_id = auth.uid())
      from ins_cancellation_cash_requests c
      join ins_policy_cancellations pc on pc.id = c.cancellation_id and pc.tenant_id = c.tenant_id
     where c.tenant_id = get_my_tenant_id() and c.status = 'pending'
    union all
    select 'cancellation'::text, x.id, x.policy_id, x.status, null::numeric,
           x.proposed_at, x.proposed_by, (x.proposed_by = auth.uid() or coalesce(x.prepared_by = auth.uid(), false))
      from ins_policy_cancellations x
     where x.tenant_id = get_my_tenant_id() and x.status in ('proposed', 'prepared')
  )
  select pe.p_type, pe.p_id, pe.p_policy, po.policy_no, bc.name, ii.name, po.currency,
         pe.p_kind, pe.p_amount, pe.p_at, coalesce(au.name, 'Unknown'), pe.p_mine
    from pending pe
    join ins_policies po on po.id = pe.p_policy and po.tenant_id = get_my_tenant_id()
    join ins_clients ic on ic.id = po.client_id and ic.tenant_id = po.tenant_id
    join bd_clients bc on bc.id = ic.client_id and bc.tenant_id = ic.tenant_id
    join ins_insurers ii on ii.id = po.insurer_id and ii.tenant_id = po.tenant_id
    left join app_users au on au.id = pe.p_by and au.tenant_id = get_my_tenant_id()
   order by pe.p_at, pe.p_id
   limit 200;
end $$;

revoke all on function public.ins_finance_pending_approvals() from public, anon;
grant execute on function public.ins_finance_pending_approvals() to authenticated;
