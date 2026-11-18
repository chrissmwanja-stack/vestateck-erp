
-- =====================================================================
-- Agent commission statement: per currency, and by payment not by accrual
-- (item 8, bit 6a)
--
-- `ins_agent_commission_statement()` had three defects and the third one is a
-- correctness problem rather than a display problem.
--
-- 1. It summed every currency into one figure. An agent paid in shillings on one
--    policy and dollars on another was handed a statement saying they had earned
--    300,000 plus 200, which is a number that corresponds to no account anywhere.
--
-- 2. The line filter and the total filter disagreed. `lines` included reversed
--    shares; the totals excluded them. A statement whose detail does not add up to
--    its own headline is worse than no statement: it is a document an agent can
--    use to prove the brokerage cannot count, and they would be right.
--
-- 3. The date window filtered on `created_at` -- when the accrual ROW was written
--    -- while the money it reports is paid on `paid_on`. Two consequences, both
--    real. A share accrued in November and paid in December appeared on November's
--    statement, because that is when the row was created. And a re-accrual after a
--    reversal carried a NEW created_at, so correcting a mistake moved the history
--    of a policy into the month of the correction. The same wrong basis was fixed
--    in the remittance period in item 8 bit 1; it survived here.
--
-- The fix keeps the response shape that existing callers read (`gross_commission`,
-- `wht_withheld`, `net_commission`, `paid`, `outstanding`, `lines`) and adds
-- `by_currency`, which is where the real answers are. With one currency in use the
-- flat figures and the single currency line are identical, so a single-currency
-- tenant sees no change at all -- which is exactly why the defect survived this
-- long, and why the test has to build the two-currency case on purpose.
-- =====================================================================

create or replace function public.ins_agent_commission_statement(
  p_intermediary_id uuid,
  p_from            date default null,
  p_to              date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  a        public.ins_intermediaries;
  v_rows   jsonb;
  v_gross  numeric := 0;
  v_wht    numeric := 0;
  v_net    numeric := 0;
  v_paid   numeric := 0;
  v_by_ccy jsonb;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  select * into a from public.ins_intermediaries
   where id = p_intermediary_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_INTERMEDIARY_NOT_FOUND'; end if;

  -- The window is the PAYMENT date. `coalesce(paid_on, created_at::date)` so an
  -- unpaid share still has a date to fall on: an agent asking "what is owed to me
  -- as at today" must see the shares that have not been paid yet, and they have no
  -- payment date. Reversed shares appear on neither side.
  select coalesce(jsonb_agg(jsonb_build_object(
           'accrual_id', x.id,
           'policy_no', p.policy_no,
           'currency', x.currency,
           'accrued_on', x.created_at::date,
           'paid_on', x.paid_on,
           'statement_date', coalesce(x.paid_on, x.created_at::date),
           'basis', x.basis,
           'gross_amount', x.gross_amount,
           'wht_rate_pct', x.wht_rate_pct,
           'wht_amount', x.wht_amount,
           'wht_is_final', x.wht_is_final,
           'net_amount', x.net_amount,
           'status', x.status) order by coalesce(x.paid_on, x.created_at::date), x.created_at, x.id), '[]'::jsonb)
    into v_rows
    from public.ins_agent_commission_accruals x
    join public.ins_policies p on p.id = x.policy_id
   where x.tenant_id = v_tenant and x.intermediary_id = p_intermediary_id
     and x.status <> 'reversed'
     and (p_from is null or coalesce(x.paid_on, x.created_at::date) >= p_from)
     and (p_to   is null or coalesce(x.paid_on, x.created_at::date) <= p_to);

  -- The same filter the lines use, deliberately: two WHERE clauses that are meant
  -- to agree should be written as one expression, because the version that drifts
  -- is the version nobody reads twice.
  select coalesce(sum(x.gross_amount), 0),
         coalesce(sum(x.wht_amount), 0),
         coalesce(sum(coalesce(x.net_amount, x.gross_amount - x.wht_amount)), 0),
         coalesce(sum(case when x.status = 'paid'
                           then coalesce(x.net_amount, x.gross_amount - x.wht_amount)
                           else 0 end), 0)
    into v_gross, v_wht, v_net, v_paid
    from public.ins_agent_commission_accruals x
   where x.tenant_id = v_tenant and x.intermediary_id = p_intermediary_id
     and x.status <> 'reversed'
     and (p_from is null or coalesce(x.paid_on, x.created_at::date) >= p_from)
     and (p_to   is null or coalesce(x.paid_on, x.created_at::date) <= p_to);

  select coalesce(jsonb_agg(jsonb_build_object(
           'currency',         c.currency,
           'gross_commission', round(c.gross, 2),
           'wht_withheld',     round(c.wht, 2),
           'net_commission',   round(c.net, 2),
           'paid',             round(c.paid, 2),
           'outstanding',      round(c.net - c.paid, 2),
           'lines',            c.n) order by c.currency), '[]'::jsonb)
    into v_by_ccy
    from (
      select x.currency,
             count(*) as n,
             sum(x.gross_amount) as gross,
             sum(x.wht_amount) as wht,
             sum(coalesce(x.net_amount, x.gross_amount - x.wht_amount)) as net,
             sum(case when x.status = 'paid'
                      then coalesce(x.net_amount, x.gross_amount - x.wht_amount)
                      else 0 end) as paid
        from public.ins_agent_commission_accruals x
       where x.tenant_id = v_tenant and x.intermediary_id = p_intermediary_id
         and x.status <> 'reversed'
         and (p_from is null or coalesce(x.paid_on, x.created_at::date) >= p_from)
         and (p_to   is null or coalesce(x.paid_on, x.created_at::date) <= p_to)
       group by x.currency
    ) c;

  return jsonb_build_object(
    'intermediary_id', a.id,
    'name', a.name,
    'category', a.category,
    'from', p_from,
    'to', p_to,
    'gross_commission', v_gross,
    'wht_withheld',     v_wht,
    'net_commission',   v_net,
    'paid',             v_paid,
    'outstanding',      round(v_net - v_paid, 2),
    'by_currency',      v_by_ccy,
    'lines',            v_rows);
end
$function$;

revoke all on function public.ins_agent_commission_statement(uuid, date, date) from public, anon;
grant execute on function public.ins_agent_commission_statement(uuid, date, date) to authenticated;

comment on function public.ins_agent_commission_statement(uuid, date, date) is
  'What one agent earned, what was withheld and what has been paid, for a date window measured on the PAYMENT date. `by_currency` holds the real figures; the flat ones add unlike currencies together and are kept only for callers that work in one.';
