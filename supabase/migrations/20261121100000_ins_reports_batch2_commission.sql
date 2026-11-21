-- =====================================================================
-- Insurance reports, batch 2: commission earned, commission receivable
-- =====================================================================
--
-- Same principle as batch 1 (20261121090000): the figure comes from posted
-- ledger records, and nothing is typed into a total.
--
-- DEFINITIONS (INSURANCE_DECISIONS_REGISTER.md, DR-39 and DR-40)
--
--   Commission earned = the movement on the commission income account
--                     (posting role commission_income) over a period,
--                     credits less debits, dated by journal entry date.
--
--                     Reading the account, not the commission entries, is
--                     deliberate. Income reaches that account by several
--                     routes (at placement or gross settlement on the bind
--                     journal; on insurer settlement or on premium
--                     collection through a recognition journal; retained
--                     commission after a cancellation; endorsements; and the
--                     reversals of each). Summing entries would have to
--                     re-implement every route and would drift the first time
--                     a route changed. The account is the answer, and the
--                     breakdown below says which route produced it.
--
--                     A voided entry keeps its lines and its reversal is a
--                     separate posted entry, so both are counted and a void
--                     nets to zero (20261117120000). With p_include_imported
--                     true the total equals the ledger movement for the period;
--                     by default imported policies and opening-balance
--                     journals are left out, so the default total is the ledger
--                     movement less those.
--
--   Commission deferred is NOT earned: until recognition, commission sits in
--   unearned commission (2020), not income, and this report does not show it.
--
--   Imported in-force policies are excluded by default (opening a book is not
--   earning it), as DR-36 does for production. Opening-balance journals are
--   excluded with them. A parameter includes them.
--
--   Commission receivable = commission the insurer owes the broker, as at a
--                     date: open items with control role commission_receivable,
--                     billed less received less credited. These exist only
--                     where the insurer settles on the gross basis (DR-13);
--                     under the net basis the broker withholds commission and
--                     nothing is owed. "As at" follows DR-38.
--
-- Every row carries its currency; nothing is summed across currencies.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Commission earned, over a period
-- ---------------------------------------------------------------------
create or replace function public.ins_report_commission_earned(
  p_from date,
  p_to date,
  p_group_by text default 'month',
  p_include_imported boolean default false
)
returns table (
  group_key     text,
  group_label   text,
  currency      text,
  placement     numeric,
  recognised    numeric,
  reversed      numeric,
  cancellations numeric,
  endorsements  numeric,
  other         numeric,
  net_earned    numeric,
  policy_count  integer
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_gl     uuid;
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

  v_gl := public.get_posting_account(v_tenant, 'commission_income');
  if v_gl is null then
    raise exception 'INS_POSTING_RULE_MISSING: the commission_income posting rule is not configured for this company';
  end if;

  return query
  with lines as (
    select jel.journal_entry_id as je_id, je.source_type, je.source_id,
           je.entry_date as d, jel.currency as cur, (jel.credit - jel.debit) as amt
      from public.journal_entry_lines jel
      join public.journal_entries je on je.id = jel.journal_entry_id
     where jel.tenant_id = v_tenant
       and je.tenant_id = v_tenant
       and jel.gl_account_id = v_gl
       and je.entry_date between p_from and p_to
       and je.status in ('posted', 'void')
  ),
  attr as (
    -- Which policy a journal belongs to. The source id is the policy for a
    -- bind, but the event, cancellation or endorsement for the other routes,
    -- so each route is resolved through its own link. Anything that resolves
    -- to no policy is kept, under "none", so the total still ties.
    select l.*,
           coalesce(
             case when l.source_type = 'ins_policy_bind' then l.source_id end,
             (select ce.policy_id
                from public.ins_commission_events ev
                join public.ins_commission_entries ce on ce.id = ev.entry_id
               where ev.journal_entry_id = l.je_id
               limit 1),
             (select c.policy_id
                from public.ins_cancellation_journals cj
                join public.ins_policy_cancellations c on c.id = cj.cancellation_id
               where cj.journal_entry_id = l.je_id
               limit 1),
             (select c.policy_id
                from public.ins_policy_cancellations c
               where l.source_type = 'ins_policy_cancellation' and c.id = l.source_id),
             (select e.policy_id
                from public.ins_policy_endorsements e
               where l.source_type = 'ins_policy_endorsement' and e.id = l.source_id)
           ) as pol_id
      from lines l
  ),
  keyed as (
    select a.pol_id, a.source_type, a.amt, a.cur,
           case p_group_by
             when 'month'        then to_char(a.d, 'YYYY-MM')
             when 'client'       then coalesce(p.client_id::text, 'none')
             when 'product_line' then coalesce(p.product_line_id::text, 'none')
             when 'branch'       then coalesce(p.branch_id::text, 'none')
             when 'agent'        then coalesce(p.agent_id::text, 'none')
           end as k,
           case p_group_by
             when 'month'        then to_char(a.d, 'YYYY-MM')
             when 'client'       then coalesce(bd.name, '(none)')
             when 'product_line' then coalesce(pl.name, '(none)')
             when 'branch'       then coalesce(public.ins_branch_name(p.branch_id), '(none)')
             when 'agent'        then coalesce(m.name, '(none)')
           end as lbl
      from attr a
      left join public.ins_policies p on p.id = a.pol_id and p.tenant_id = v_tenant
      left join public.ins_clients cl on cl.id = p.client_id
      left join public.bd_clients bd on bd.id = cl.client_id
      left join public.ins_product_lines pl on pl.id = p.product_line_id
      left join public.ins_intermediaries m on m.id = p.agent_id
     where p_include_imported
        or (a.source_type <> 'opening_balance' and p.import_batch_id is null)
  )
  select k.k, k.lbl, k.cur,
         coalesce(sum(k.amt) filter (where k.source_type = 'ins_policy_bind'), 0),
         coalesce(sum(k.amt) filter (where k.source_type = 'ins_commission_recognition'), 0),
         coalesce(sum(k.amt) filter (where k.source_type = 'ins_commission_recognition_reversal'), 0),
         coalesce(sum(k.amt) filter (where k.source_type in ('ins_policy_cancellation', 'ins_cancellation_cash')), 0),
         coalesce(sum(k.amt) filter (where k.source_type = 'ins_policy_endorsement'), 0),
         coalesce(sum(k.amt) filter (where k.source_type not in (
           'ins_policy_bind', 'ins_commission_recognition', 'ins_commission_recognition_reversal',
           'ins_policy_cancellation', 'ins_cancellation_cash', 'ins_policy_endorsement')), 0),
         coalesce(sum(k.amt), 0),
         (count(distinct k.pol_id))::integer
    from keyed k
   group by k.k, k.lbl, k.cur
   order by k.cur, k.k;
end;
$$;

revoke all on function public.ins_report_commission_earned(date, date, text, boolean) from public, anon;
grant execute on function public.ins_report_commission_earned(date, date, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Commission receivable from insurers, as at a date
-- ---------------------------------------------------------------------
create or replace function public.ins_report_commission_receivable(p_as_of date default current_date)
returns table (
  open_item_id  uuid,
  policy_id     uuid,
  policy_no     text,
  insurer_id    uuid,
  insurer_name  text,
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
    select i.id, i.source_id as pol_id, i.document_no, i.document_date, i.due_date, i.currency, i.amount
      from public.fin_open_items i
     where i.tenant_id = v_tenant
       and i.control_role = 'commission_receivable'
       and i.source_type = 'ins_commission_receivable'
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
  select c.id, p.id, p.policy_no, p.insurer_id, ins.name, c.currency, c.document_no,
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
    left join public.ins_insurers ins on ins.id = p.insurer_id
   where (c.amount - c.rec - c.cred) > 0.004
   order by c.currency, ins.name, p.policy_no, c.document_date;
end;
$$;

revoke all on function public.ins_report_commission_receivable(date) from public, anon;
grant execute on function public.ins_report_commission_receivable(date) to authenticated;
