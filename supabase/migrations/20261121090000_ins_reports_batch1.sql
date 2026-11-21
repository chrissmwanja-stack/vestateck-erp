-- =====================================================================
-- Insurance reports, batch 1: production, premium collected, outstanding premium
-- =====================================================================
--
-- WHY THESE ARE SERVER FUNCTIONS
--
-- The production book, the aged balances and the dashboard add up policy rows
-- in the browser. 20261117260000 already recorded what that costs: a figure
-- recomputed from policy columns drifts from the ledger (a 1,059,000 receivable
-- reported as 1,000,000). These functions read the ledger records instead, and
-- return nothing that was typed into a total.
--
-- DEFINITIONS (INSURANCE_DECISIONS_REGISTER.md, DR-35 to DR-38)
--
--   Net written premium  = premium bound
--                        + premium_delta of posted endorsements
--                        - the premium_delta of an endorsement later cancelled (E4)
--                        - return premium of posted cancellations
--                        - the remaining net premium of a reversed policy.
--                          Each movement is dated by the day it took effect
--                          (bind date, endorsement posting date, E4 cancelled
--                          date, cancellation posting date, reversal date).
--                        Premium only: broker fees, charges and VAT are not
--                        premium. Imported in-force policies are excluded unless
--                        asked for, because opening a book is not writing it.
--
--   Premium collected    = receipts allocated to client premium receivables
--                        (the bind receivable and endorsement receivables),
--                        dated by settlement date. These receivables carry the
--                        whole client invoice, so the figure includes charges
--                        and VAT billed with the premium.
--
--   Outstanding premium  = the same receivables, billed less received less
--                        credited, as at a date.
--
--   "As at" rule: an event dated after the as-at date is ignored, and a
--   settlement or credit note voided AFTER the as-at date still counts as it
--   did on that date. This is the rule 20261117120000 applies to the ledger.
--
-- Nothing here is summed across currencies. Every row carries its currency.
--
-- NOT IN THIS BATCH: grouping by insurer. Under co-insurance a policy has
-- several insurers; the right basis is the share, and that belongs with the
-- insurer performance report.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Outstanding premium, as at a date
-- ---------------------------------------------------------------------
create or replace function public.ins_report_outstanding_premium(p_as_of date default current_date)
returns table (
  open_item_id  uuid,
  policy_id     uuid,
  policy_no     text,
  client_id     uuid,
  client_name   text,
  currency      text,
  document_no   text,
  document_date date,
  due_date      date,
  billed        numeric,
  received      numeric,
  credited      numeric,
  outstanding   numeric,
  days_overdue  integer,
  age_bucket    text
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if auth.uid() is null or not public.can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access is required' using errcode = '42501';
  end if;
  if p_as_of is null then
    raise exception 'INS_REPORT_INPUT: an as-at date is required';
  end if;

  return query
  with items as (
    select i.id, i.document_no, i.document_date, i.due_date, i.currency, i.amount,
           case when i.source_type = 'ins_policy_premium' then i.source_id
                else e.policy_id end as pol_id
      from public.fin_open_items i
      left join public.ins_policy_endorsements e
        on i.source_type = 'ins_policy_endorsement'
       and e.id = i.source_id and e.tenant_id = i.tenant_id
     where i.tenant_id = v_tenant
       and i.control_role = 'ar_control'
       and i.source_type in ('ins_policy_premium', 'ins_policy_endorsement')
       and i.document_date <= p_as_of
  ),
  calc as (
    select it.*,
           coalesce((select sum(a.amount)
                       from public.fin_allocations a
                       join public.fin_settlements s on s.id = a.settlement_id
                      where a.open_item_id = it.id
                        and s.settlement_date <= p_as_of
                        and (s.status = 'posted'
                             or (s.status = 'void' and s.voided_at::date > p_as_of))), 0) as rec,
           coalesce((select sum(ca.amount)
                       from public.fin_credit_applications ca
                       join public.fin_credit_notes cn on cn.id = ca.credit_note_id
                      where ca.open_item_id = it.id
                        and cn.credit_date <= p_as_of
                        and (cn.status = 'posted'
                             or (cn.status = 'void' and cn.voided_at::date > p_as_of))), 0) as cred
      from items it
  )
  select c.id, p.id, p.policy_no, p.client_id, bd.name, c.currency, c.document_no,
         c.document_date, c.due_date,
         c.amount, c.rec, c.cred, (c.amount - c.rec - c.cred),
         greatest(p_as_of - coalesce(c.due_date, c.document_date), 0)::integer,
         case
           when coalesce(c.due_date, c.document_date) >= p_as_of then 'current'
           when p_as_of - coalesce(c.due_date, c.document_date) <= 30 then '1-30'
           when p_as_of - coalesce(c.due_date, c.document_date) <= 60 then '31-60'
           when p_as_of - coalesce(c.due_date, c.document_date) <= 90 then '61-90'
           else '90+'
         end
    from calc c
    join public.ins_policies p on p.id = c.pol_id and p.tenant_id = v_tenant
    join public.ins_clients cl on cl.id = p.client_id
    left join public.bd_clients bd on bd.id = cl.client_id
   where (c.amount - c.rec - c.cred) > 0.004
   order by c.currency, p.policy_no, c.document_date;
end;
$$;

revoke all on function public.ins_report_outstanding_premium(date) from public, anon;
grant execute on function public.ins_report_outstanding_premium(date) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Premium collected, over a period
-- ---------------------------------------------------------------------
create or replace function public.ins_report_premium_collected(
  p_from date,
  p_to date,
  p_group_by text default 'month'
)
returns table (
  group_key     text,
  group_label   text,
  currency      text,
  collected     numeric,
  receipt_count integer
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if auth.uid() is null or not public.can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access is required' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'INS_REPORT_INPUT: a valid period is required';
  end if;
  if p_group_by is null or p_group_by not in ('month', 'client', 'product_line', 'branch', 'agent') then
    raise exception 'INS_REPORT_INPUT: group by must be month, client, product_line, branch or agent';
  end if;

  return query
  with alloc as (
    select s.id as settlement_id, s.settlement_date, a.amount, i.currency,
           case when i.source_type = 'ins_policy_premium' then i.source_id
                else e.policy_id end as pol_id
      from public.fin_allocations a
      join public.fin_settlements s on s.id = a.settlement_id
      join public.fin_open_items i on i.id = a.open_item_id
      left join public.ins_policy_endorsements e
        on i.source_type = 'ins_policy_endorsement'
       and e.id = i.source_id and e.tenant_id = i.tenant_id
     where a.tenant_id = v_tenant
       and s.tenant_id = v_tenant
       and s.direction = 'in'
       and s.settlement_date between p_from and p_to
       and (s.status = 'posted' or (s.status = 'void' and s.voided_at::date > p_to))
       and i.control_role = 'ar_control'
       and i.source_type in ('ins_policy_premium', 'ins_policy_endorsement')
  ),
  keyed as (
    select al.settlement_id, al.amount, al.currency,
           case p_group_by
             when 'month'        then to_char(al.settlement_date, 'YYYY-MM')
             when 'client'       then coalesce(p.client_id::text, 'none')
             when 'product_line' then coalesce(p.product_line_id::text, 'none')
             when 'branch'       then coalesce(p.branch_id::text, 'none')
             when 'agent'        then coalesce(p.agent_id::text, 'none')
           end as k,
           case p_group_by
             when 'month'        then to_char(al.settlement_date, 'YYYY-MM')
             when 'client'       then coalesce(bd.name, '(none)')
             when 'product_line' then coalesce(pl.name, '(none)')
             when 'branch'       then coalesce(public.ins_branch_name(p.branch_id), '(none)')
             when 'agent'        then coalesce(m.name, '(none)')
           end as lbl
      from alloc al
      join public.ins_policies p on p.id = al.pol_id and p.tenant_id = v_tenant
      left join public.ins_clients cl on cl.id = p.client_id
      left join public.bd_clients bd on bd.id = cl.client_id
      left join public.ins_product_lines pl on pl.id = p.product_line_id
      left join public.ins_intermediaries m on m.id = p.agent_id
  )
  select k.k, k.lbl, k.currency, sum(k.amount), count(distinct k.settlement_id)::integer
    from keyed k
   group by k.k, k.lbl, k.currency
   order by k.currency, k.k;
end;
$$;

revoke all on function public.ins_report_premium_collected(date, date, text) from public, anon;
grant execute on function public.ins_report_premium_collected(date, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Production (net written premium), over a period
-- ---------------------------------------------------------------------
create or replace function public.ins_report_production(
  p_from date,
  p_to date,
  p_group_by text default 'product_line',
  p_include_imported boolean default false
)
returns table (
  group_key     text,
  group_label   text,
  currency      text,
  new_business  numeric,
  endorsements  numeric,
  cancellations numeric,
  reversals     numeric,
  net_written   numeric,
  policy_count  integer
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if auth.uid() is null or not public.can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access is required' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'INS_REPORT_INPUT: a valid period is required';
  end if;
  if p_group_by is null or p_group_by not in ('month', 'client', 'product_line', 'branch', 'agent') then
    raise exception 'INS_REPORT_INPUT: group by must be month, client, product_line, branch or agent';
  end if;

  return query
  with pol as (
    select p.id, p.client_id, p.product_line_id, p.branch_id, p.agent_id, p.currency,
           p.gross_premium, p.bound_at::date as bound_date
      from public.ins_policies p
     where p.tenant_id = v_tenant
       and p.bound_at is not null
       and p.status in ('active', 'renewed', 'cancelled', 'reversed')
       and (p_include_imported or p.import_batch_id is null)
  ),
  base as (
    select pol.id as policy_id, 'new'::text as kind, pol.bound_date as d, pol.gross_premium as amt
      from pol
    union all
    select e.policy_id, 'endorsement', e.posting_date,
           coalesce((e.calculation ->> 'premium_delta')::numeric, 0)
      from public.ins_policy_endorsements e
      join pol on pol.id = e.policy_id
     where e.tenant_id = v_tenant and e.status in ('posted', 'cancelled') and e.posting_date is not null
    union all
    select e.policy_id, 'endorsement', e.cancelled_at::date,
           -coalesce((e.calculation ->> 'premium_delta')::numeric, 0)
      from public.ins_policy_endorsements e
      join pol on pol.id = e.policy_id
     where e.tenant_id = v_tenant and e.status = 'cancelled' and e.cancelled_at is not null
    union all
    select c.policy_id, 'cancellation', c.posting_date,
           -coalesce((select sum(adj.return_premium)
                        from public.ins_cancellation_insurer_adjustments adj
                       where adj.cancellation_id = c.id), 0)
      from public.ins_policy_cancellations c
      join pol on pol.id = c.policy_id
     where c.tenant_id = v_tenant and c.status = 'posted' and c.posting_date is not null
  ),
  rev as (
    -- A reversal removes whatever the policy had written up to that day.
    select r.original_policy_id as policy_id, 'reversal'::text as kind, r.reversal_date as d,
           -coalesce((select sum(b.amt) from base b
                       where b.policy_id = r.original_policy_id and b.d <= r.reversal_date), 0) as amt
      from public.ins_policy_reversals r
      join pol on pol.id = r.original_policy_id
     where r.tenant_id = v_tenant and r.outcome = 'posted' and r.reversal_date is not null
  ),
  mv as (
    select * from base union all select * from rev
  ),
  win as (
    select m.* from mv m where m.d between p_from and p_to
  ),
  keyed as (
    select w.policy_id, w.kind, w.amt, pol.currency,
           case p_group_by
             when 'month'        then to_char(w.d, 'YYYY-MM')
             when 'client'       then coalesce(pol.client_id::text, 'none')
             when 'product_line' then coalesce(pol.product_line_id::text, 'none')
             when 'branch'       then coalesce(pol.branch_id::text, 'none')
             when 'agent'        then coalesce(pol.agent_id::text, 'none')
           end as k,
           case p_group_by
             when 'month'        then to_char(w.d, 'YYYY-MM')
             when 'client'       then coalesce(bd.name, '(none)')
             when 'product_line' then coalesce(pl.name, '(none)')
             when 'branch'       then coalesce(public.ins_branch_name(pol.branch_id), '(none)')
             when 'agent'        then coalesce(m.name, '(none)')
           end as lbl
      from win w
      join pol on pol.id = w.policy_id
      left join public.ins_clients cl on cl.id = pol.client_id
      left join public.bd_clients bd on bd.id = cl.client_id
      left join public.ins_product_lines pl on pl.id = pol.product_line_id
      left join public.ins_intermediaries m on m.id = pol.agent_id
  )
  select k.k, k.lbl, k.currency,
         coalesce(sum(k.amt) filter (where k.kind = 'new'), 0),
         coalesce(sum(k.amt) filter (where k.kind = 'endorsement'), 0),
         coalesce(sum(k.amt) filter (where k.kind = 'cancellation'), 0),
         coalesce(sum(k.amt) filter (where k.kind = 'reversal'), 0),
         coalesce(sum(k.amt), 0),
         (count(distinct k.policy_id) filter (where k.kind = 'new'))::integer
    from keyed k
   group by k.k, k.lbl, k.currency
   order by k.currency, k.k;
end;
$$;

revoke all on function public.ins_report_production(date, date, text, boolean) from public, anon;
grant execute on function public.ins_report_production(date, date, text, boolean) to authenticated;
