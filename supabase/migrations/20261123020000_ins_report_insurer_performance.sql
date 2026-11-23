-- =====================================================================
-- Insurance reports: insurer performance
-- =====================================================================
--
-- One row per insurer and currency for the policies bound in a period:
--   premium placed and commission are each insurer's own recorded share
--   (ins_policy_insurer_shares.premium_amount and commission_amount), so a
--   co-insured policy counts once for each insurer that carries part of it;
--   claims are those on the same policies, as at the end date, attributed to
--   insurers pro rata by share (DR-51);
--   the loss ratio is claims incurred (paid plus outstanding) over premium
--   placed.
--
-- Claim amounts come from ins_report_claims_register as at the end date, so
-- the status, reserve and payment history are the ones that report shows. Each
-- claim's paid and outstanding amounts are split across the policy's shares by
-- largest remainder, so the insurers' parts always add up to the claim.
--
-- Basis, stated so nobody reads it as something else: this is a cohort view.
-- Premium is placed premium on policies bound in the period, gross of any later
-- cancellation (cancelled policies are counted separately), and the claims
-- are every claim ever notified on those policies up to the end date, not only
-- claims notified in the period.
--
-- Not covered: remittance timeliness, cancellation credits by insurer and
-- renewal retention by insurer. Renewal retention by insurer is already
-- available by grouping the renewal retention report.
-- =====================================================================

create or replace function public.ins_report_insurer_performance(
  p_from             date,
  p_to               date,
  p_include_imported boolean default false
)
returns table (
  insurer_id             uuid,
  insurer_name           text,
  currency               text,
  policy_count           integer,
  cancelled_policy_count integer,
  premium_placed         numeric,
  commission             numeric,
  commission_pct         numeric,
  claim_count            integer,
  open_claim_count       integer,
  claims_paid            numeric,
  claims_outstanding     numeric,
  claims_incurred        numeric,
  loss_ratio_pct         numeric
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
  with pols as (
    select p.id as policy_id, p.currency, p.status
      from public.ins_policies p
     where p.tenant_id = v_tenant
       and p.bound_at is not null
       and public.ins_local_date(p.bound_at) between p_from and p_to
       and (p_include_imported or p.import_batch_id is null)
  ),
  sh as (
    select s.policy_id, s.insurer_id, s.share_pct, s.premium_amount, s.commission_amount,
           pols.currency, pols.status
      from public.ins_policy_insurer_shares s
      join pols on pols.policy_id = s.policy_id
     where s.tenant_id = v_tenant
  ),
  reg as (
    select r.claim_id, r.paid_as_at, r.outstanding_amount, r.is_open
      from public.ins_report_claims_register(p_to, 'all') r
  ),
  cl as (
    select c.id as claim_id, c.policy_id, reg.paid_as_at, reg.outstanding_amount, reg.is_open
      from public.ins_claims c
      join reg on reg.claim_id = c.id
      join pols on pols.policy_id = c.policy_id
     where c.tenant_id = v_tenant
  ),
  parts as (
    select cl.claim_id, sh.insurer_id, sh.currency, cl.is_open,
           cl.paid_as_at * sh.share_pct / 100 as paid_x,
           cl.outstanding_amount * sh.share_pct / 100 as out_x
      from cl
      join sh on sh.policy_id = cl.policy_id
  ),
  alloc as (
    select p.claim_id, p.insurer_id, p.currency, p.is_open,
           trunc(p.paid_x, 2) as paid_b, trunc(p.out_x, 2) as out_b,
           row_number() over (partition by p.claim_id order by p.paid_x - trunc(p.paid_x, 2) desc, p.insurer_id) as rk_p,
           row_number() over (partition by p.claim_id order by p.out_x - trunc(p.out_x, 2) desc, p.insurer_id) as rk_o,
           round((round(sum(p.paid_x) over (partition by p.claim_id), 2)
                  - sum(trunc(p.paid_x, 2)) over (partition by p.claim_id)) * 100)::integer as cents_p,
           round((round(sum(p.out_x) over (partition by p.claim_id), 2)
                  - sum(trunc(p.out_x, 2)) over (partition by p.claim_id)) * 100)::integer as cents_o
      from parts p
  ),
  claims_by as (
    select a.insurer_id, a.currency,
           count(distinct a.claim_id)::integer as n_claims,
           (count(distinct a.claim_id) filter (where a.is_open))::integer as n_open,
           sum(a.paid_b + case when a.rk_p <= a.cents_p then 0.01 else 0 end) as paid,
           sum(a.out_b + case when a.rk_o <= a.cents_o then 0.01 else 0 end) as outstanding
      from alloc a
     group by a.insurer_id, a.currency
  ),
  placed_by as (
    select s.insurer_id, s.currency,
           count(distinct s.policy_id)::integer as n_pol,
           (count(distinct s.policy_id) filter (where s.status = 'cancelled'))::integer as n_cancelled,
           sum(s.premium_amount) as premium,
           sum(s.commission_amount) as comm
      from sh s
     group by s.insurer_id, s.currency
  )
  select pb.insurer_id, i.name, pb.currency, pb.n_pol, pb.n_cancelled,
         coalesce(pb.premium, 0), coalesce(pb.comm, 0),
         case when coalesce(pb.premium, 0) > 0 then round(100 * pb.comm / pb.premium, 1) end,
         coalesce(cb.n_claims, 0), coalesce(cb.n_open, 0),
         coalesce(cb.paid, 0), coalesce(cb.outstanding, 0),
         coalesce(cb.paid, 0) + coalesce(cb.outstanding, 0),
         case when coalesce(pb.premium, 0) > 0
              then round(100 * (coalesce(cb.paid, 0) + coalesce(cb.outstanding, 0)) / pb.premium, 1) end
    from placed_by pb
    left join claims_by cb on cb.insurer_id = pb.insurer_id and cb.currency = pb.currency
    left join public.ins_insurers i on i.id = pb.insurer_id
   order by pb.currency, i.name;
end;
$$;
revoke all on function public.ins_report_insurer_performance(date, date, boolean) from public, anon;
grant execute on function public.ins_report_insurer_performance(date, date, boolean) to authenticated;
