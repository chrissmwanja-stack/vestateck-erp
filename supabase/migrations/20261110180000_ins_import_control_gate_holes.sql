-- =====================================================================
-- In-force import: close two holes in the control-totals gate.
--
-- 20261110170000 made recorded control totals binding, but the one
-- calculation both the reconciliation and the commit gate read
-- (ins_import_control_rows) had two gaps:
--
--   1. A currency that is in the control totals but not in the book was
--      never compared. The rows were built from the currencies found in
--      the staged policies, so a control sheet saying "EUR: 5,000,000"
--      with no EUR policy imported produced no EUR row, no entry in
--      ins_import_control_diff, and a gate that let the commit through.
--      That is exactly the "we lost a whole currency" failure control
--      totals exist to catch.
--
--      Fix: the currency list is the union of the book's currencies and
--      the control sheet's currencies, with zero imported for whichever
--      side has nothing. A measure the sheet did not record for that
--      currency still has a NULL control amount, so it is "not recorded",
--      never a difference.
--
--   2. policy_count was recorded by the sync and never compared. It is
--      the cheapest check for dropped or duplicated rows, so it is now
--      the fifth compared measure (imported = valid staged policy rows
--      before commit, the batch's own ins_policies rows after it).
--
-- What is deliberately NOT changed:
--
--   receivables, payables and unearned_commission are still recorded by
--   the sync but not compared, and they do not gate the commit. They are
--   only meaningful once the opening position has been posted (spec 4.6,
--   step 5), which happens after commit; comparing them against the
--   staged book would either always differ or compare a number the book
--   does not yet contain. They are for the post-commit report. The
--   20261110170000 header said that once totals are supplied "they are
--   binding"; that is true of the five measures compared here and of no
--   others, and this file is the place that says so.
--
-- Nothing else moves: the function keeps its name, signature and result
-- shape, so ins_import_control_diff, ins_import_reconciliation, the
-- override approval (bound to the exact difference set) and the commit
-- gate trigger pick up both fixes without being touched. The measure
-- names are unchanged; 'policy_count' is simply a new value.
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

  -- One source at a time, chosen by the batch state (see 20261110170000):
  -- the staged sheet before commit, the typed history after it.
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
  -- The control sheet, one object per currency (the sync keeps it so; the
  -- distinct on makes that hold even if the column was written by hand).
  ctl as (
    select distinct on (upper(btrim(e.obj ->> 'currency')))
           upper(btrim(e.obj ->> 'currency')) as cur,
           e.obj as totals
      from jsonb_array_elements(v_totals) as e(obj)
     where nullif(btrim(e.obj ->> 'currency'), '') is not null
     order by upper(btrim(e.obj ->> 'currency'))
  ),
  -- Hole 1: every currency either side knows about.
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
         end
    from cur u
    left join imp i on i.cur = u.cur
    left join ctl c on c.cur = u.cur
    cross join lateral (values
      ('policy_count',        coalesce(i.cnt, 0)),       -- hole 2
      ('gross_premium',       coalesce(i.gross, 0)),
      ('commission',          coalesce(i.comm, 0)),
      ('receipts_to_date',    coalesce(i.receipts, 0)),
      ('remittances_to_date', coalesce(i.remits, 0))) m(measure, amt)
   order by u.cur, m.measure;
end $$;
revoke all on function public.ins_import_control_rows(uuid) from public, anon, authenticated;