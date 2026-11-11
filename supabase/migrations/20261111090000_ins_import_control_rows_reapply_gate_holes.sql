-- =====================================================================
-- In-force import: re-apply the two control-totals gate fixes.
--
-- 20261110180000 closed two holes in ins_import_control_rows:
--   1. a currency in the control sheet but not in the book was never
--      compared (no row, no DIFF, gate open);
--   2. policy_count was recorded but never compared.
--
-- 20261110190000 (client-money bank) was written on top of the 20261110170000
-- body and redefines the same function, so, because it sorts after
-- 20261110180000, it silently reverted both fixes. A fresh `supabase db reset`
-- therefore ended with the original gaps and a function that only looked
-- fixed in the middle of the migration history.
--
-- This file is the single definition that carries everything:
--   * the currency list is the union of the book and the control sheet,
--     zero imported for whichever side has nothing (hole 1);
--   * policy_count is compared (hole 2);
--   * client_money (receipts - remittances vs the counted bank balance)
--     is kept from 20261110190000, and for a control-only currency its
--     imported side is 0, like every other measure.
--
-- Six measures are compared per currency: policy_count, gross_premium,
-- commission, receipts_to_date, remittances_to_date, client_money.
-- receivables, payables and unearned_commission remain recorded but not
-- compared: they only mean something after the opening position is posted
-- (spec 4.6 step 5), so they belong in a post-commit report.
--
-- Name, signature and result shape are unchanged, so the diff, the
-- reconciliation, the override approval and the commit gate pick this up
-- untouched. Do not edit 20261110180000 / 20261110190000: they may already
-- be applied; later redefinitions of this function must start from this file.
-- =====================================================================

create or replace function public.ins_import_control_rows(p_batch_id uuid)
returns table (currency text, measure text, imported_amount numeric, control_amount numeric)
language plpgsql stable security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant    uuid;
  v_status    text;
  v_totals    jsonb;
  v_committed boolean;
begin
  select b.tenant_id, b.status, coalesce(b.control_totals, '[]'::jsonb)
    into v_tenant, v_status, v_totals
    from public.ins_import_batches b
   where b.id = p_batch_id;
  if v_status is null then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;

  -- One source at a time, chosen by the batch state: the staged sheet
  -- before commit, the typed history after it.
  v_committed := (v_status = 'committed');

  return query
  with src as (
    select p.currency as cur,
           1::numeric as cnt,
           p.gross_premium as gross,
           coalesce(p.commission_amount, 0) as comm,
           coalesce((select sum(r.amount) from public.ins_import_receipts r
                      where r.tenant_id = v_tenant and r.batch_id = p_batch_id
                        and r.policy_id = p.id), 0) as receipts,
           coalesce((select sum(m.amount) from public.ins_import_remittances m
                      where m.tenant_id = v_tenant and m.batch_id = p_batch_id
                        and m.policy_id = p.id), 0) as remits
      from public.ins_policies p
     where v_committed
       and p.tenant_id = v_tenant and p.import_batch_id = p_batch_id
    union all
    select upper(btrim(x.resolved ->> 'currency')),
           1::numeric,
           coalesce(public.platform_ins_import_num(x.resolved ->> 'gross_premium'), 0),
           coalesce(public.platform_ins_import_num(x.resolved ->> 'commission_amount'), 0),
           coalesce((select sum(public.platform_ins_import_num(y.raw ->> 'amount'))
                       from public.ins_import_rows y
                      where y.tenant_id = v_tenant and y.batch_id = p_batch_id
                        and y.sheet = 'receipts' and y.status = 'valid'
                        and btrim(y.raw ->> 'legacy_policy_no') = btrim(x.raw ->> 'legacy_policy_no')), 0),
           coalesce((select sum(public.platform_ins_import_num(y.raw ->> 'amount'))
                       from public.ins_import_rows y
                      where y.tenant_id = v_tenant and y.batch_id = p_batch_id
                        and y.sheet = 'remittances' and y.status = 'valid'
                        and btrim(y.raw ->> 'legacy_policy_no') = btrim(x.raw ->> 'legacy_policy_no')), 0)
      from public.ins_import_rows x
     where not v_committed
       and x.tenant_id = v_tenant and x.batch_id = p_batch_id
       and x.sheet = 'policies' and x.status = 'valid'
       and nullif(btrim(x.resolved ->> 'currency'), '') is not null
  ),
  imp as (
    select s.cur,
           sum(s.cnt)      as cnt,
           sum(s.gross)    as gross,
           sum(s.comm)     as comm,
           sum(s.receipts) as receipts,
           sum(s.remits)   as remits
      from src s
     group by s.cur
  ),
  ctl as (
    select distinct on (upper(btrim(e.obj ->> 'currency')))
           upper(btrim(e.obj ->> 'currency')) as cur,
           e.obj as totals
      from jsonb_array_elements(v_totals) as e(obj)
     where nullif(btrim(e.obj ->> 'currency'), '') is not null
     order by upper(btrim(e.obj ->> 'currency'))
  ),
  cur as (
    select i.cur from imp i
    union
    select c.cur from ctl c
  )
  select u.cur,
         m.measure,
         m.amt,
         case m.measure
           when 'policy_count'        then (c.totals ->> 'policy_count')::numeric
           when 'gross_premium'       then (c.totals ->> 'gross_premium')::numeric
           when 'commission'          then (c.totals ->> 'commission')::numeric
           when 'receipts_to_date'    then (c.totals ->> 'receipts')::numeric
           when 'remittances_to_date' then (c.totals ->> 'remittances')::numeric
           when 'client_money'        then (c.totals ->> 'client_money')::numeric
         end
    from cur u
    left join imp i on i.cur = u.cur
    left join ctl c on c.cur = u.cur
    cross join lateral (values
      ('policy_count',        coalesce(i.cnt, 0)),
      ('gross_premium',       coalesce(i.gross, 0)),
      ('commission',          coalesce(i.comm, 0)),
      ('receipts_to_date',    coalesce(i.receipts, 0)),
      ('remittances_to_date', coalesce(i.remits, 0)),
      ('client_money',        round(coalesce(i.receipts, 0) - coalesce(i.remits, 0), 2))) m(measure, amt)
   order by u.cur, m.measure;
end $$;
revoke all on function public.ins_import_control_rows(uuid) from public, anon, authenticated;
