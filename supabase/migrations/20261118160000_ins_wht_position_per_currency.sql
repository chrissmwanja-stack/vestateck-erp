-- =====================================================================
-- The withholding position, per currency (item 8, bit 5)
--
-- `ins_wht_position()` summed every currency into one figure. A tenant working in
-- two currencies got 500 USD of tax plus 900,000 UGX of tax back as 900,500 of
-- something, and there is no exchange rate in this function: inventing one would
-- be an accounting decision taken by a display routine. The split is now the
-- answer and the flat fields are kept only as a summary for single-currency
-- tenants, which is what `by_currency` makes checkable rather than assumed.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT CLAIM. The clocked version of this
-- bit also "fixed" a negative `unreported` by flooring it at zero, on the theory
-- that a filed return could outlive the withholding behind it. Measuring the
-- schema says it cannot: a return's amount is the sum of the accrual lines it
-- claims, a paid share cannot be reversed, and `ins_agent_commission_wht_guard`
-- refuses a post-hoc change to a withheld figure. `reported` therefore never
-- exceeds `withheld`, and `over_reported` is structurally zero today.
--
-- It is kept anyway, because it costs one GREATEST and it is the difference
-- between a display that cannot print a negative backlog and one that can. But it
-- is documented as a guard against a state the schema does not currently permit,
-- not as a fix for a state it produces. If that ever changes -- a return that can
-- be part-paid, a share whose tax can be credited after filing -- the sign is
-- already handled.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The withholding position, per currency
-- ---------------------------------------------------------------------
-- The old flat fields are kept for every existing caller, because they are right
-- for a tenant that works in one currency -- which is most of them, and the reason
-- the defect went unnoticed. They are now the summary; `by_currency` is the answer.
create or replace function public.ins_wht_position()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant     uuid := public.get_my_tenant_id();
  v_withheld   numeric := 0;
  v_reported   numeric := 0;
  v_paid       numeric := 0;
  v_rows       jsonb;
  v_by_ccy     jsonb;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select coalesce(sum(x.wht_amount), 0) into v_withheld
    from public.ins_agent_commission_accruals x
   where x.tenant_id = v_tenant and x.wht_amount > 0 and x.status <> 'reversed';

  select coalesce(sum(r.amount), 0) into v_paid
    from public.ins_wht_remittances r
   where r.tenant_id = v_tenant and r.status = 'paid';

  select coalesce(sum(r.amount), 0) into v_reported
    from public.ins_wht_remittances r
   where r.tenant_id = v_tenant and r.status in ('prepared', 'approved', 'paid');

  select coalesce(jsonb_agg(jsonb_build_object(
           'remittance_no', r.remittance_no,
           'period_start', r.period_start,
           'period_end', r.period_end,
           'currency', r.currency,
           'amount', r.amount,
           'status', r.status,
           'paid_on', r.paid_on) order by r.period_start desc), '[]'::jsonb)
    into v_rows
    from public.ins_wht_remittances r
   where r.tenant_id = v_tenant and r.status <> 'void';

  -- Every currency either figure mentions, so a currency that has tax withheld
  -- but no return yet still appears with its backlog rather than vanishing.
  with ccys as (
    select x.currency from public.ins_agent_commission_accruals x
     where x.tenant_id = v_tenant and x.wht_amount > 0 and x.status <> 'reversed'
    union
    select r.currency from public.ins_wht_remittances r
     where r.tenant_id = v_tenant and r.status in ('prepared', 'approved', 'paid')
  ),
  agg as (
    select c.currency,
           (select coalesce(sum(x.wht_amount), 0) from public.ins_agent_commission_accruals x
             where x.tenant_id = v_tenant and x.currency = c.currency
               and x.wht_amount > 0 and x.status <> 'reversed') as withheld,
           (select coalesce(sum(r.amount), 0) from public.ins_wht_remittances r
             where r.tenant_id = v_tenant and r.currency = c.currency
               and r.status in ('prepared', 'approved', 'paid')) as reported,
           (select coalesce(sum(r.amount), 0) from public.ins_wht_remittances r
             where r.tenant_id = v_tenant and r.currency = c.currency
               and r.status = 'paid') as paid
      from ccys c
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'currency',         a.currency,
           'withheld_total',   round(a.withheld, 2),
           'reported_total',   round(a.reported, 2),
           'paid_total',       round(a.paid, 2),
           'unreported',       round(a.withheld - a.reported, 2),
           -- Floored, so the display layer can never print a negative backlog. The
           -- schema cannot currently produce one (see the header); this is a guard,
           -- not a repair.
           'unreported_open',  round(greatest(a.withheld - a.reported, 0), 2),
           'over_reported',    round(greatest(a.reported - a.withheld, 0), 2),
           'awaiting_payment', round(greatest(a.reported - a.paid, 0), 2)
         ) order by a.currency), '[]'::jsonb)
    into v_by_ccy
    from agg a;

  return jsonb_build_object(
    'withheld_total',   v_withheld,
    'reported_total',   v_reported,
    'paid_total',       v_paid,
    -- The number the accountant actually wants: tax taken from agents that is
    -- not yet on a return at all, never mind paid.
    'unreported',       round(v_withheld - v_reported, 2),
    'awaiting_payment', round(v_reported - v_paid, 2),
    'unreported_open',  round(greatest(v_withheld - v_reported, 0), 2),
    'over_reported',    round(greatest(v_reported - v_withheld, 0), 2),
    'by_currency',      v_by_ccy,
    'remittances',      v_rows);
end
$function$;

revoke all on function public.ins_wht_position() from public, anon;
grant execute on function public.ins_wht_position() to authenticated;

comment on function public.ins_wht_position() is
  'What has been withheld from agents and what has been done with it. `by_currency` splits it per currency, because the flat figures add unlike amounts together. `over_reported` is a guard against a return exceeding the withholding behind it; the schema does not currently permit that state.';
