-- =====================================================================
-- Insurance reports, batch 3: claims register, claims ageing
-- =====================================================================
--
-- Same principle as batches 1 and 2: the figure is read from recorded
-- claim records, and nothing is typed into a total.
--
-- DEFINITIONS (INSURANCE_DECISIONS_REGISTER.md, DR-41 and DR-42)
--
--   Claim status as at a date = the to_status of the latest ins_claim_events
--                     row on or before that date (events are written by
--                     every status change, starting with 'notified'). Events
--                     are dated by the day they were recorded. A claim whose
--                     notified date is on or before the date but whose first
--                     event was recorded later (a back-dated entry) counts as
--                     notified from its notified date.
--
--   Open claim        = status as at the date is notified, assessing or
--                     approved. An approved claim stays open until it is
--                     fully paid, because the insurer or the brokerage still
--                     owes the client money. settled, repudiated and closed
--                     are not open.
--
--   Reserve as at     = new_amount of the latest ins_claim_reserve_history
--                     row on or before the date; failing that the initial
--                     reserve (a back-dated claim); failing that the current
--                     reserve_amount (claims recorded before history existed).
--
--   Paid as at        = claim payments of kind insurer_direct or client_payout
--                     (the same kinds ins_claim_apply_payment_totals adds up),
--                     dated by payment_date. A payment voided AFTER the as-at
--                     date still counts as it did on that date (DR-38).
--
--   Outstanding amount = approved claims: approved amount less paid as at
--                     (never below zero). Notified or assessing claims: the
--                     reserve as at. Settled, repudiated and closed claims
--                     owe nothing.
--
--   Age               = days from the notified date to the as-at date. Days
--                     since activity = days from the latest status event.
--
-- KNOWN LIMIT: the approved amount is not kept as history, so the register
-- uses the current approved amount for a claim that was approved as at the
-- date. If an approval was revised after the date, an old as-at figure for
-- that claim reflects the revised amount. Status, reserve and payments ARE
-- reproducible for any past date.
--
-- Insurer shown is the policy's lead insurer. Under co-insurance a claim
-- belongs to several insurers; grouping by share belongs with the insurer
-- performance report, as noted in batch 1.
--
-- Every row carries its currency (the policy's); nothing is summed across
-- currencies.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Claims register, as at a date
-- ---------------------------------------------------------------------
create or replace function public.ins_report_claims_register(
  p_as_of date default current_date,
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
               and e.created_at::date <= p_as_of
             order by e.created_at desc, e.id desc
             limit 1) as status_at,
           (select e.created_at::date
              from public.ins_claim_events e
             where e.claim_id = c.id and e.tenant_id = v_tenant
               and e.created_at::date <= p_as_of
             order by e.created_at desc, e.id desc
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
                 and h.revised_at::date <= p_as_of
               order by h.revised_at desc, h.id desc
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
                             or (p.status = 'void' and p.voided_at::date > p_as_of))), 0) as paid_at
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

revoke all on function public.ins_report_claims_register(date, text) from public, anon;
grant execute on function public.ins_report_claims_register(date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Claims ageing, as at a date
-- ---------------------------------------------------------------------
-- Built on the register so the two can never disagree: the ageing total is
-- the register total, grouped.
create or replace function public.ins_report_claims_ageing(
  p_as_of date default current_date,
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

revoke all on function public.ins_report_claims_ageing(date, text) from public, anon;
grant execute on function public.ins_report_claims_ageing(date, text) to authenticated;
