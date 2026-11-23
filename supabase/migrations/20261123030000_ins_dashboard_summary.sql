-- =====================================================================
-- Insurance dashboard: one server summary function
-- =====================================================================
--
-- The dashboard used to total money in the browser from raw table rows:
-- "gross premium in force" and "commission in force" from the bound policies'
-- stored amounts, and "open claim reserves" from each claim's current reserve
-- field. Those figures left out cancelled business, ignored endorsements, and
-- could disagree with the reports.
--
-- ins_dashboard_summary returns the headline figures per currency by calling
-- the same report functions the reports screens call, so the dashboard cannot
-- disagree with them:
--
--   gross_written, endorsements, cancellations, reversals, net_written
--       ins_report_production (DR-35). gross_written is premium bound.
--       cancellations and reversals are negative. net_written is DR-35's net, so
--       gross_written + endorsements + cancellations + reversals = net_written.
--       Both the gross and the net figure are returned, so the screen can show
--       cancelled business beside gross premium without choosing between them.
--   commission_earned
--       ins_report_commission_earned (DR-39): the movement on the commission
--       income account, so it equals the ledger. Null when the company has no
--       commission income posting rule yet, so a setup gap does not hide the
--       rest of the dashboard.
--   premium_collected
--       ins_report_premium_collected (DR-37).
--   outstanding_premium, overdue_premium
--       ins_report_outstanding_premium as at the end date (DR-38).
--       overdue_premium is the part past its due date.
--   open_claim_count, claims_outstanding
--       ins_report_claims_register, open claims as at the end date (DR-41).
--
-- Written, commission and collected are movements in the period. Outstanding
-- premium and claims outstanding are positions as at the end date. The
-- include-imported switch applies to written and commission only: the reports
-- that give outstanding premium, collections and claims have no such switch,
-- because a receivable or a claim on an imported policy is real. policy_count is
-- the number of policies bound in the period.
--
-- Nothing is stored or maintained: no table, no counter, nothing a user can
-- type in. Every figure is recomputed from posted transactions and approved
-- records each time.
-- =====================================================================

create or replace function public.ins_dashboard_summary(
  p_from             date,
  p_to               date,
  p_include_imported boolean default false
)
returns table (
  currency            text,
  policy_count        integer,
  gross_written       numeric,
  endorsements        numeric,
  cancellations       numeric,
  reversals           numeric,
  net_written         numeric,
  commission_earned   numeric,
  premium_collected   numeric,
  outstanding_premium numeric,
  overdue_premium     numeric,
  open_claim_count    integer,
  claims_outstanding  numeric
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  v_comm_ok boolean;
  v_comm    jsonb := '[]'::jsonb;
begin
  if auth.uid() is null or not public.can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access is required' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'INS_REPORT_INPUT: a valid period is required';
  end if;

  -- The commission report refuses to run for a company with no commission income
  -- posting rule. One missing setup step must not take the whole dashboard down, so
  -- commission is then returned as null (not available), never as zero.
  v_comm_ok := public.get_posting_account(v_tenant, 'commission_income') is not null;
  if v_comm_ok then
    select coalesce(jsonb_agg(jsonb_build_object('ccy', x.currency, 'earned', x.earned)), '[]'::jsonb)
      into v_comm
      from (select r.currency, sum(r.net_earned) as earned
              from public.ins_report_commission_earned(p_from, p_to, 'month', p_include_imported) r
             group by r.currency) x;
  end if;

  return query
  with prod as (
    select r.currency as ccy,
           sum(r.new_business) as nb, sum(r.endorsements) as en, sum(r.cancellations) as ca,
           sum(r.reversals) as rv, sum(r.net_written) as nw
      from public.ins_report_production(p_from, p_to, 'month', p_include_imported) r
     group by r.currency
  ),
  bound as (
    select p.currency as ccy, count(*)::integer as n
      from public.ins_policies p
     where p.tenant_id = v_tenant
       and p.bound_at is not null
       and public.ins_local_date(p.bound_at) between p_from and p_to
       and (p_include_imported or p.import_batch_id is null)
     group by p.currency
  ),
  comm as (
    select e ->> 'ccy' as ccy, (e ->> 'earned')::numeric as earned
      from jsonb_array_elements(v_comm) e
  ),
  coll as (
    select r.currency as ccy, sum(r.collected) as collected
      from public.ins_report_premium_collected(p_from, p_to, 'month') r
     group by r.currency
  ),
  outp as (
    select r.currency as ccy, sum(r.outstanding) as o,
           sum(r.outstanding) filter (where r.days_overdue > 0) as od
      from public.ins_report_outstanding_premium(p_to) r
     group by r.currency
  ),
  clm as (
    select r.currency as ccy, count(*)::integer as n, sum(r.outstanding_amount) as s
      from public.ins_report_claims_register(p_to, 'open') r
     group by r.currency
  ),
  curr as (
    select ccy from prod union select ccy from bound union select ccy from comm
    union select ccy from coll union select ccy from outp union select ccy from clm
  )
  select c.ccy,
         coalesce(bound.n, 0),
         coalesce(prod.nb, 0), coalesce(prod.en, 0), coalesce(prod.ca, 0), coalesce(prod.rv, 0), coalesce(prod.nw, 0),
         case when v_comm_ok then coalesce(comm.earned, 0) end,
         coalesce(coll.collected, 0),
         coalesce(outp.o, 0), coalesce(outp.od, 0),
         coalesce(clm.n, 0), coalesce(clm.s, 0)
    from curr c
    left join prod  on prod.ccy  = c.ccy
    left join bound on bound.ccy = c.ccy
    left join comm  on comm.ccy  = c.ccy
    left join coll  on coll.ccy  = c.ccy
    left join outp  on outp.ccy  = c.ccy
    left join clm   on clm.ccy   = c.ccy
   order by c.ccy;
end;
$$;
revoke all on function public.ins_dashboard_summary(date, date, boolean) from public, anon;
grant execute on function public.ins_dashboard_summary(date, date, boolean) to authenticated;
