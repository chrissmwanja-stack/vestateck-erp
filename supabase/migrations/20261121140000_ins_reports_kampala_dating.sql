-- =====================================================================
-- Insurance reports: which day a timestamp belongs to
-- =====================================================================
--
-- The report functions turned timestamps into dates with a bare "::date" and
-- compared against current_date. Both use the session time zone, which on
-- Supabase is UTC. Kampala is UTC+3 all year (no daylight saving), so anything
-- recorded between 00:00 and 03:00 local time was dated the previous day:
-- a policy bound at 01:00 on the 5th counted as written on the 4th, a receipt
-- voided at 02:00 was still "live" for the whole of that day's as-at figure,
-- and a claim event recorded just after midnight fell into yesterday. The
-- renewals report flipped a policy from upcoming at 03:00 instead of midnight.
--
-- Decision: the business day is Africa/Kampala, in one place.
--
--   public.ins_local_date(timestamptz)  the Kampala calendar date of a timestamp
--   public.ins_local_today()            today's date in Kampala
--
-- Every report that dated a timestamp, or compared against today, now calls
-- these. To move to a per-company time zone later, change the two helpers; the
-- reports do not need to be touched again.
--
-- Functions redefined here (same signatures, same grants; only the dating of
-- timestamps and the default "as at" date change): ins_report_outstanding_premium,
-- ins_report_premium_collected, ins_report_production,
-- ins_report_commission_receivable, ins_report_claims_register,
-- ins_report_claims_ageing, ins_report_renewals.
--
-- Not changed: figures that are already dates (posting dates, receipt dates,
-- expiry dates), and ins_report_commission_earned, which has no timestamp
-- conversion. Earlier reports (statements, unremitted premium, remittance)
-- were not part of this change.
-- =====================================================================

create or replace function public.ins_local_date(p_ts timestamptz)
returns date
language sql
immutable
parallel safe
set search_path to 'pg_catalog'
as $$
  select (p_ts at time zone 'Africa/Kampala')::date
$$;

create or replace function public.ins_local_today()
returns date
language sql
stable
parallel safe
set search_path to 'pg_catalog', 'public'
as $$
  select public.ins_local_date(now())
$$;

revoke all on function public.ins_local_date(timestamptz) from public, anon;
revoke all on function public.ins_local_today() from public, anon;
grant execute on function public.ins_local_date(timestamptz) to authenticated;
grant execute on function public.ins_local_today() to authenticated;


create or replace function public.ins_report_outstanding_premium(p_as_of date default public.ins_local_today())
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
                             or (s.status = 'void' and public.ins_local_date(s.voided_at) > p_as_of))), 0) as rec,
           coalesce((select sum(ca.amount)
                       from public.fin_credit_applications ca
                       join public.fin_credit_notes cn on cn.id = ca.credit_note_id
                      where ca.open_item_id = it.id
                        and cn.credit_date <= p_as_of
                        and (cn.status = 'posted'
                             or (cn.status = 'void' and public.ins_local_date(cn.voided_at) > p_as_of))), 0) as cred
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
       and (s.status = 'posted' or (s.status = 'void' and public.ins_local_date(s.voided_at) > p_to))
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
           p.gross_premium, public.ins_local_date(p.bound_at) as bound_date
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
    select e.policy_id, 'endorsement', public.ins_local_date(e.cancelled_at),
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

create or replace function public.ins_report_commission_receivable(p_as_of date default public.ins_local_today())
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
                             or (s.status = 'void' and public.ins_local_date(s.voided_at) > p_as_of))), 0) as rec,
           coalesce((select sum(ca.amount)
                       from public.fin_credit_applications ca
                       join public.fin_credit_notes cn on cn.id = ca.credit_note_id
                      where ca.open_item_id = it.id
                        and cn.credit_date <= p_as_of
                        and (cn.status = 'posted'
                             or (cn.status = 'void' and public.ins_local_date(cn.voided_at) > p_as_of))), 0) as cred
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

create or replace function public.ins_report_claims_register(
  p_as_of date default public.ins_local_today(),
  p_scope text default 'open'
)
returns table (
  claim_id            uuid,
  claim_no            text,
  insurer_claim_ref   text,
  policy_id           uuid,
  policy_no           text,
  client_id           uuid,
  client_name         text,
  insurer_id          uuid,
  insurer_name        text,
  product_line_id     uuid,
  product_line_name   text,
  currency            text,
  loss_date           date,
  notified_date       date,
  status_as_at        text,
  is_open             boolean,
  reserve_as_at       numeric,
  approved_amount     numeric,
  paid_as_at          numeric,
  outstanding_amount  numeric,
  age_days            integer,
  days_since_activity integer,
  age_bucket          text
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
  if p_scope is null or p_scope not in ('open', 'all') then
    raise exception 'INS_REPORT_INPUT: scope must be open or all';
  end if;

  return query
  with st as (
    select c.id as cid,
           (select e.to_status
              from public.ins_claim_events e
             where e.claim_id = c.id and e.tenant_id = v_tenant
               and public.ins_local_date(e.created_at) <= p_as_of
             order by e.created_at desc,
                      exists (select 1 from public.ins_claim_events n
                               where n.claim_id = e.claim_id and n.tenant_id = v_tenant
                                 and n.created_at = e.created_at
                                 and n.from_status = e.to_status and n.id <> e.id),
                      e.id desc
             limit 1) as status_at,
           (select public.ins_local_date(e.created_at)
              from public.ins_claim_events e
             where e.claim_id = c.id and e.tenant_id = v_tenant
               and public.ins_local_date(e.created_at) <= p_as_of
             order by e.created_at desc,
                      exists (select 1 from public.ins_claim_events n
                               where n.claim_id = e.claim_id and n.tenant_id = v_tenant
                                 and n.created_at = e.created_at
                                 and n.from_status = e.to_status and n.id <> e.id),
                      e.id desc
             limit 1) as last_activity
      from public.ins_claims c
     where c.tenant_id = v_tenant
       and c.notified_date <= p_as_of
  ),
  calc as (
    select c.*,
           coalesce(st.status_at, 'notified') as status_at,
           coalesce(st.last_activity, c.notified_date) as last_activity,
           coalesce(
             (select h.new_amount
                from public.ins_claim_reserve_history h
               where h.claim_id = c.id and h.tenant_id = v_tenant
                 and public.ins_local_date(h.revised_at) <= p_as_of
               order by h.revised_at desc,
                        exists (select 1 from public.ins_claim_reserve_history n
                                 where n.claim_id = h.claim_id and n.tenant_id = v_tenant
                                   and n.revised_at = h.revised_at
                                   and n.previous_amount = h.new_amount and n.id <> h.id),
                        h.id desc
               limit 1),
             (select h.new_amount
                from public.ins_claim_reserve_history h
               where h.claim_id = c.id and h.tenant_id = v_tenant and h.kind = 'initial'
               limit 1),
             c.reserve_amount) as reserve_at,
           coalesce((select sum(p.amount)
                       from public.ins_claim_payments p
                      where p.claim_id = c.id and p.tenant_id = v_tenant
                        and p.kind in ('insurer_direct', 'client_payout')
                        and p.payment_date <= p_as_of
                        and (p.status = 'posted'
                             or (p.status = 'void' and public.ins_local_date(p.voided_at) > p_as_of))), 0) as paid_at
      from public.ins_claims c
      join st on st.cid = c.id
  ),
  fin as (
    select k.*,
           (k.status_at in ('notified', 'assessing', 'approved')) as open_flag,
           case
             when k.status_at = 'approved'
               then greatest(coalesce(k.approved_amount, 0) - k.paid_at, 0)
             when k.status_at in ('notified', 'assessing') then k.reserve_at
             else 0
           end as outstanding_at
      from calc k
  )
  select f.id, f.claim_no, f.insurer_claim_ref,
         p.id, p.policy_no, p.client_id, bd.name,
         p.insurer_id, ins.name, p.product_line_id, pl.name,
         p.currency,
         f.loss_date, f.notified_date, f.status_at, f.open_flag,
         f.reserve_at,
         case when f.status_at in ('approved', 'settled') then f.approved_amount else null end,
         f.paid_at, f.outstanding_at,
         (p_as_of - f.notified_date)::integer,
         (p_as_of - f.last_activity)::integer,
         case
           when not f.open_flag then 'closed'
           when p_as_of - f.notified_date <= 30  then '0-30'
           when p_as_of - f.notified_date <= 60  then '31-60'
           when p_as_of - f.notified_date <= 90  then '61-90'
           when p_as_of - f.notified_date <= 180 then '91-180'
           else '180+'
         end
    from fin f
    join public.ins_policies p on p.id = f.policy_id and p.tenant_id = v_tenant
    left join public.ins_clients cl on cl.id = p.client_id
    left join public.bd_clients bd on bd.id = cl.client_id
    left join public.ins_insurers ins on ins.id = p.insurer_id
    left join public.ins_product_lines pl on pl.id = p.product_line_id
   where (p_scope = 'all' or f.open_flag)
   order by p.currency, f.notified_date, f.claim_no;
end;
$$;

create or replace function public.ins_report_claims_ageing(
  p_as_of date default public.ins_local_today(),
  p_group_by text default 'none'
)
returns table (
  group_key          text,
  group_label        text,
  currency           text,
  age_bucket         text,
  claim_count        integer,
  reserve_total      numeric,
  outstanding_total  numeric,
  oldest_age_days    integer
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if auth.uid() is null or not public.can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access is required' using errcode = '42501';
  end if;
  if p_as_of is null then
    raise exception 'INS_REPORT_INPUT: an as-at date is required';
  end if;
  if p_group_by is null or p_group_by not in ('none', 'insurer', 'product_line') then
    raise exception 'INS_REPORT_INPUT: group by must be none, insurer or product_line';
  end if;

  return query
  select case p_group_by
           when 'insurer'      then coalesce(r.insurer_id::text, 'none')
           when 'product_line' then coalesce(r.product_line_id::text, 'none')
           else 'all'
         end,
         case p_group_by
           when 'insurer'      then coalesce(r.insurer_name, '(none)')
           when 'product_line' then coalesce(r.product_line_name, '(none)')
           else 'All open claims'
         end,
         r.currency,
         r.age_bucket,
         count(*)::integer,
         coalesce(sum(r.reserve_as_at), 0),
         coalesce(sum(r.outstanding_amount), 0),
         max(r.age_days)::integer
    from public.ins_report_claims_register(p_as_of, 'open') r
   group by 1, 2, r.currency, r.age_bucket
   order by r.currency, 2,
            case r.age_bucket
              when '0-30' then 1 when '31-60' then 2 when '61-90' then 3
              when '91-180' then 4 else 5
            end;
end;
$$;

create or replace function public.ins_report_renewals(
  p_from date,
  p_to date,
  p_include_imported boolean default true
)
returns table (
  policy_id           uuid,
  policy_no           text,
  client_id           uuid,
  client_name         text,
  insurer_id          uuid,
  insurer_name        text,
  product_line_id     uuid,
  product_line_name   text,
  branch_id           uuid,
  branch_name         text,
  agent_id            uuid,
  agent_name          text,
  currency            text,
  expiry_date         date,
  days_to_expiry      integer,
  expiring_premium    numeric,
  outcome             text,
  outcome_reason      text,
  renewal_policy_id   uuid,
  renewal_policy_no   text,
  renewal_premium     numeric
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

  return query
  select p.id, p.policy_no, p.client_id, bd.name, p.insurer_id, ins.name,
         p.product_line_id, pl.name, p.branch_id, public.ins_branch_name(p.branch_id),
         p.agent_id, m.name, p.currency, p.expiry_date,
         (p.expiry_date - public.ins_local_today())::integer, p.gross_premium,
         case when rn.id is not null then 'renewed'
              when o.outcome is not null then o.outcome
              when p.expiry_date >= public.ins_local_today() then 'upcoming'
              else 'unresolved' end,
         case when rn.id is null then o.reason else null end,
         rn.id, rn.policy_no, rn.gross_premium
    from public.ins_policies p
    left join public.ins_clients cl on cl.id = p.client_id
    left join public.bd_clients bd on bd.id = cl.client_id
    left join public.ins_insurers ins on ins.id = p.insurer_id
    left join public.ins_product_lines pl on pl.id = p.product_line_id
    left join public.ins_intermediaries m on m.id = p.agent_id
    left join lateral (
      select d.id, d.policy_no, d.gross_premium
        from public.ins_policies d
       where d.renewal_of_id = p.id and d.tenant_id = v_tenant and d.bound_at is not null
       order by d.bound_at, d.id
       limit 1
    ) rn on true
    left join public.ins_renewal_outcomes o on o.policy_id = p.id and o.tenant_id = v_tenant
   where p.tenant_id = v_tenant
     and p.bound_at is not null
     and p.status in ('active', 'renewed')
     and p.expiry_date between p_from and p_to
     and (p_include_imported or p.import_batch_id is null)
   order by p.currency, p.expiry_date, p.policy_no;
end;
$$;
