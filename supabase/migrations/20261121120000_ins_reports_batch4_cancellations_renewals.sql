-- =====================================================================
-- Insurance reports, batch 4: cancellations, renewals and retention
-- =====================================================================
--
-- Same principle as batches 1 to 3: figures are read from posted or recorded
-- records, and nothing is typed into a total.
--
-- DEFINITIONS (INSURANCE_DECISIONS_REGISTER.md, DR-43 to DR-45)
--
--   Cancelled business = posted policy cancellations (status 'posted'), dated by
--                      posting date, with the amounts the cancellation posted
--                      per insurer (ins_cancellation_insurer_adjustments):
--                      return premium, commission clawed back, commission
--                      retained, and the total credit from the insurer.
--                      Proposed, prepared, rejected and withdrawn cancellations
--                      are not cancelled business and are not shown.
--                      The return premium here is the same figure batch 1
--                      subtracts as "cancellations" in production, so the two
--                      reports agree for the same period and the same
--                      imported-policy setting (DR-36).
--
--   Due for renewal    = bound policies whose status is active or renewed and
--                      whose expiry date falls in the period. A policy that was
--                      cancelled or reversed never reached expiry and is in the
--                      cancellation report instead. Imported in-force policies
--                      ARE included by default: they are the book that has to
--                      renew, even though opening a book is not writing it.
--
--   Renewal outcome    = renewed when a bound policy exists whose renewal_of_id
--                      is this policy (the first one bound); otherwise the
--                      outcome recorded in ins_renewal_outcomes (lost, declined
--                      or lapsed); otherwise upcoming when the expiry date has
--                      not passed, or unresolved when it has and nothing was
--                      recorded.
--
--   Retention          = renewed / (due less upcoming), as a count; and renewal
--                      premium / expiring premium of the same matured policies.
--                      A policy not yet expired cannot have been lost, so it is
--                      left out of both denominators. Premium retention can
--                      exceed 100 when renewal premiums are higher.
--
-- The renewal reports show the position TODAY. A renewal bound after the report
-- was first run changes the result for an earlier period; there is no as-at
-- date here, because renewal outcomes are not kept as history.
--
-- Insurer is the policy's lead insurer for renewals. For cancellations it is the
-- insurer on each adjustment, so a co-insured cancellation splits by insurer.
-- Every row carries its currency; nothing is summed across currencies.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Cancellations, summary over a period
-- ---------------------------------------------------------------------
create or replace function public.ins_report_cancellations(
  p_from date,
  p_to date,
  p_group_by text default 'month',
  p_include_imported boolean default false
)
returns table (
  group_key           text,
  group_label         text,
  currency            text,
  cancellation_count  integer,
  return_premium      numeric,
  commission_clawback numeric,
  retained_commission numeric,
  total_insurer_credit numeric
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
  if p_group_by is null
     or p_group_by not in ('month', 'client', 'product_line', 'branch', 'agent', 'insurer') then
    raise exception 'INS_REPORT_INPUT: group by must be month, client, product_line, branch, agent or insurer';
  end if;

  return query
  with canc as (
    select c.id as cid, c.posting_date, p.currency, p.client_id, p.product_line_id, p.branch_id, p.agent_id
      from public.ins_policy_cancellations c
      join public.ins_policies p on p.id = c.policy_id and p.tenant_id = v_tenant
     where c.tenant_id = v_tenant
       and c.status = 'posted'
       and c.posting_date between p_from and p_to
       and p.bound_at is not null
       and p.status in ('active', 'renewed', 'cancelled', 'reversed')
       and (p_include_imported or p.import_batch_id is null)
  ),
  rows_ as (
    select k.*, adj.insurer_id as adj_insurer_id,
           coalesce(adj.return_premium, 0)       as rp,
           coalesce(adj.commission_clawback, 0)  as cb,
           coalesce(adj.retained_commission, 0)  as rc,
           coalesce(adj.total_insurer_credit, 0) as tc
      from canc k
      left join public.ins_cancellation_insurer_adjustments adj
        on adj.cancellation_id = k.cid and adj.tenant_id = v_tenant
  ),
  keyed as (
    select r.*,
           case p_group_by
             when 'month'        then to_char(r.posting_date, 'YYYY-MM')
             when 'client'       then coalesce(r.client_id::text, 'none')
             when 'product_line' then coalesce(r.product_line_id::text, 'none')
             when 'branch'       then coalesce(r.branch_id::text, 'none')
             when 'agent'        then coalesce(r.agent_id::text, 'none')
             when 'insurer'      then coalesce(r.adj_insurer_id::text, 'none')
           end as k,
           case p_group_by
             when 'month'        then to_char(r.posting_date, 'YYYY-MM')
             when 'client'       then coalesce((select bd.name from public.ins_clients cl
                                                  join public.bd_clients bd on bd.id = cl.client_id
                                                 where cl.id = r.client_id), '(none)')
             when 'product_line' then coalesce((select pl.name from public.ins_product_lines pl
                                                 where pl.id = r.product_line_id), '(none)')
             when 'branch'       then coalesce(public.ins_branch_name(r.branch_id), '(none)')
             when 'agent'        then coalesce((select m.name from public.ins_intermediaries m
                                                 where m.id = r.agent_id), '(none)')
             when 'insurer'      then coalesce((select i.name from public.ins_insurers i
                                                 where i.id = r.adj_insurer_id), '(none)')
           end as lbl
      from rows_ r
  )
  select k.k, k.lbl, k.currency,
         count(distinct k.cid)::integer,
         coalesce(sum(k.rp), 0), coalesce(sum(k.cb), 0),
         coalesce(sum(k.rc), 0), coalesce(sum(k.tc), 0)
    from keyed k
   group by k.k, k.lbl, k.currency
   order by k.currency, k.k;
end;
$$;

revoke all on function public.ins_report_cancellations(date, date, text, boolean) from public, anon;
grant execute on function public.ins_report_cancellations(date, date, text, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Cancellation register: one row per posted cancellation
-- ---------------------------------------------------------------------
create or replace function public.ins_report_cancellation_register(
  p_from date,
  p_to date,
  p_include_imported boolean default false
)
returns table (
  cancellation_id      uuid,
  cancellation_no      text,
  policy_id            uuid,
  policy_no            text,
  client_name          text,
  insurer_name         text,
  product_line_name    text,
  currency             text,
  reason               text,
  effective_date       date,
  posting_date         date,
  return_premium       numeric,
  commission_clawback  numeric,
  retained_commission  numeric,
  total_insurer_credit numeric
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
  select c.id, c.cancellation_no, p.id, p.policy_no, bd.name, ins.name, pl.name, p.currency,
         c.reason, c.effective_date, c.posting_date,
         coalesce(a.rp, 0), coalesce(a.cb, 0), coalesce(a.rc, 0), coalesce(a.tc, 0)
    from public.ins_policy_cancellations c
    join public.ins_policies p on p.id = c.policy_id and p.tenant_id = v_tenant
    left join public.ins_clients cl on cl.id = p.client_id
    left join public.bd_clients bd on bd.id = cl.client_id
    left join public.ins_insurers ins on ins.id = p.insurer_id
    left join public.ins_product_lines pl on pl.id = p.product_line_id
    left join lateral (
      select sum(adj.return_premium) as rp, sum(adj.commission_clawback) as cb,
             sum(adj.retained_commission) as rc, sum(adj.total_insurer_credit) as tc
        from public.ins_cancellation_insurer_adjustments adj
       where adj.cancellation_id = c.id and adj.tenant_id = v_tenant
    ) a on true
   where c.tenant_id = v_tenant
     and c.status = 'posted'
     and c.posting_date between p_from and p_to
     and p.bound_at is not null
     and p.status in ('active', 'renewed', 'cancelled', 'reversed')
     and (p_include_imported or p.import_batch_id is null)
   order by p.currency, c.posting_date, c.cancellation_no;
end;
$$;

revoke all on function public.ins_report_cancellation_register(date, date, boolean) from public, anon;
grant execute on function public.ins_report_cancellation_register(date, date, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Renewals: one row per policy due in the period
-- ---------------------------------------------------------------------
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
         (p.expiry_date - current_date)::integer, p.gross_premium,
         case when rn.id is not null then 'renewed'
              when o.outcome is not null then o.outcome
              when p.expiry_date >= current_date then 'upcoming'
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

revoke all on function public.ins_report_renewals(date, date, boolean) from public, anon;
grant execute on function public.ins_report_renewals(date, date, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Renewal retention, grouped
-- ---------------------------------------------------------------------
-- Built on ins_report_renewals so the two can never disagree: the counts here
-- are the rows there, grouped.
create or replace function public.ins_report_renewal_retention(
  p_from date,
  p_to date,
  p_group_by text default 'month',
  p_include_imported boolean default true
)
returns table (
  group_key            text,
  group_label          text,
  currency             text,
  due_count            integer,
  renewed_count        integer,
  lost_count           integer,
  unresolved_count     integer,
  upcoming_count       integer,
  expiring_premium     numeric,
  renewed_premium      numeric,
  retention_count_pct  numeric,
  retention_premium_pct numeric
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
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'INS_REPORT_INPUT: a valid period is required';
  end if;
  if p_group_by is null
     or p_group_by not in ('month', 'client', 'product_line', 'branch', 'agent', 'insurer') then
    raise exception 'INS_REPORT_INPUT: group by must be month, client, product_line, branch, agent or insurer';
  end if;

  return query
  with r as (
    select x.*,
           case p_group_by
             when 'month'        then to_char(x.expiry_date, 'YYYY-MM')
             when 'client'       then coalesce(x.client_id::text, 'none')
             when 'product_line' then coalesce(x.product_line_id::text, 'none')
             when 'branch'       then coalesce(x.branch_id::text, 'none')
             when 'agent'        then coalesce(x.agent_id::text, 'none')
             when 'insurer'      then coalesce(x.insurer_id::text, 'none')
           end as k,
           case p_group_by
             when 'month'        then to_char(x.expiry_date, 'YYYY-MM')
             when 'client'       then coalesce(x.client_name, '(none)')
             when 'product_line' then coalesce(x.product_line_name, '(none)')
             when 'branch'       then coalesce(x.branch_name, '(none)')
             when 'agent'        then coalesce(x.agent_name, '(none)')
             when 'insurer'      then coalesce(x.insurer_name, '(none)')
           end as lbl
      from public.ins_report_renewals(p_from, p_to, p_include_imported) x
  ),
  g as (
    select r.k, r.lbl, r.currency,
           count(*)::integer as due,
           (count(*) filter (where r.outcome = 'renewed'))::integer as renewed,
           (count(*) filter (where r.outcome in ('lost', 'declined', 'lapsed')))::integer as lost,
           (count(*) filter (where r.outcome = 'unresolved'))::integer as unresolved,
           (count(*) filter (where r.outcome = 'upcoming'))::integer as upcoming,
           coalesce(sum(r.expiring_premium), 0) as exp_all,
           coalesce(sum(r.expiring_premium) filter (where r.outcome <> 'upcoming'), 0) as exp_matured,
           coalesce(sum(r.renewal_premium) filter (where r.outcome = 'renewed'), 0) as ren_prem
      from r
     group by r.k, r.lbl, r.currency
  )
  select g.k, g.lbl, g.currency, g.due, g.renewed, g.lost, g.unresolved, g.upcoming,
         g.exp_all, g.ren_prem,
         case when g.due - g.upcoming > 0
              then round(100.0 * g.renewed / (g.due - g.upcoming), 1) end,
         case when g.exp_matured > 0
              then round(100.0 * g.ren_prem / g.exp_matured, 1) end
    from g
   order by g.currency, g.k;
end;
$$;

revoke all on function public.ins_report_renewal_retention(date, date, text, boolean) from public, anon;
grant execute on function public.ins_report_renewal_retention(date, date, text, boolean) to authenticated;