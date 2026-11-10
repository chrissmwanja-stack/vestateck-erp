-- =====================================================================
-- In-force import: control totals are recorded, compared and binding.
--
-- Three defects, one subject.
--
--   1. ins_import_batches.control_totals was never written. 20261108030000
--      added the column and 20261107140000 validated the staged sheet, but
--      nothing copied the sheet into the column, so the reviewer's totals
--      existed only as raw rows.
--   2. ins_import_reconciliation therefore compared every measure against
--      COALESCE(NULL, 0) and reported false on every line - a report that
--      cries wolf on a perfect batch. It also summed receipts and
--      remittances across the whole batch for every currency (the
--      subqueries in `imp` were not correlated), so a two-currency batch
--      showed each currency the other's cash.
--   3. A difference between the staged book and the control totals did not
--      stop anything. IN_FORCE_IMPORT.md 4.6 asks for commit to be refused
--      unless the totals match, or the difference is explained and approved
--      by someone other than the uploader.
--
-- What this migration does:
--
--   * a trigger keeps ins_import_batches.control_totals in step with the
--     staged sheet, so there is no separate "sync" step for the wizard to
--     forget. Only rows validation marked 'valid' count, and the canonical
--     form is one object per currency with the numeric fields that were
--     actually supplied (a missing field stays missing, not zero).
--   * ins_import_control_rows is the single calculation: per currency,
--     per measure, imported versus control, control NULL when the sheet
--     did not record that measure. Reconciliation and the commit gate both
--     read it, so they cannot disagree.
--   * reconciliation distinguishes "not recorded" (control NULL, match
--     NULL) from "recorded and different" (match false).
--   * a BEFORE UPDATE trigger on ins_import_batches refuses the transition
--     to 'committed' when a recorded total disagrees, unless
--     ins_import_override_control_totals was called by someone other than
--     the uploader AND the approved difference is exactly the difference
--     that exists now (so an approval cannot be reused after the numbers
--     move).
--   * totals stay optional. A batch with no control totals sheet commits
--     as before and reconciliation says "not recorded"; once totals are
--     supplied they are binding. Recorded here because "optional" must not
--     drift into "ignored".
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. Batch columns: sync stamp and the approval record
-- ---------------------------------------------------------------------
alter table public.ins_import_batches
  add column if not exists control_totals_synced_at timestamptz,
  add column if not exists control_override_reason   text,
  add column if not exists control_override_by       uuid,
  add column if not exists control_override_at       timestamptz,
  add column if not exists control_override_diff     jsonb;

-- ---------------------------------------------------------------------
-- B. Reading one number out of a raw sheet row, forgiving the header
--    spelling (the workbook is the customer's, not ours).
-- ---------------------------------------------------------------------
create or replace function public.ins_import_pick_num(p_raw jsonb, p_keys text[])
returns numeric
language sql immutable set search_path = pg_catalog, public, pg_temp
as $$
  select min(public.platform_ins_import_num(p_raw ->> k)) from unnest(p_keys) k;
$$;
revoke all on function public.ins_import_pick_num(jsonb, text[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- C. Copy the staged sheet into the batch
-- ---------------------------------------------------------------------
-- Internal worker. It takes the tenant from the batch, not from the
-- session: a trigger fires on whatever connection touched the row, including
-- the table owner repairing data, and bookkeeping must not depend on who is
-- asking. Authorisation lives in the RPCs that expose it.
create or replace function public.ins_import_sync_control_totals(p_batch_id uuid)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant uuid;
  v_totals jsonb;
begin
  select b.tenant_id into v_tenant from public.ins_import_batches b where b.id = p_batch_id;
  if v_tenant is null then
    raise exception 'INS_IMPORT_BATCH_NOT_FOUND';
  end if;

  select coalesce(jsonb_agg(v.vals || jsonb_build_object('currency', v.currency)
                            order by v.currency), '[]'::jsonb)
    into v_totals
    from (
      select distinct on (upper(btrim(x.raw ->> 'currency')))
             upper(btrim(x.raw ->> 'currency')) as currency,
             jsonb_strip_nulls(jsonb_build_object(
               'policy_count',        public.ins_import_pick_num(x.raw, array['policy_count','policies','policy count']),
               'gross_premium',       public.ins_import_pick_num(x.raw, array['gross_premium','gross premium','gross']),
               'commission',          public.ins_import_pick_num(x.raw, array['commission','commission_amount','commission amount']),
               'receipts',            public.ins_import_pick_num(x.raw, array['receipts','receipts_to_date','receipts to date','receipts_todate']),
               'remittances',         public.ins_import_pick_num(x.raw, array['remittances','remittances_to_date','remittances to date','remittances_todate']),
               'receivables',         public.ins_import_pick_num(x.raw, array['receivables','receivable','outstanding_receivable']),
               'payables',            public.ins_import_pick_num(x.raw, array['payables','insurer_payables','insurer payables','payable']),
               'unearned_commission', public.ins_import_pick_num(x.raw, array['unearned_commission','unearned commission','deferred_commission'])
             )) as vals
        from public.ins_import_rows x
       where x.batch_id = p_batch_id
         and x.tenant_id = v_tenant
         and x.sheet = 'control_totals'
         and x.status = 'valid'
         and nullif(btrim(x.raw ->> 'currency'), '') is not null
       order by upper(btrim(x.raw ->> 'currency')), x.line
    ) v;

  update public.ins_import_batches
     set control_totals = v_totals,
         control_totals_synced_at = now(),
         updated_at = now()
   where id = p_batch_id and tenant_id = v_tenant
     and control_totals is distinct from v_totals;

  return v_totals;
end $$;
revoke all on function public.ins_import_sync_control_totals(uuid) from public, anon, authenticated;

-- Kept in step by the staged rows themselves, so no caller can forget it.
create or replace function public.ins_import_rows_control_totals()
returns trigger
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
begin
  perform public.ins_import_sync_control_totals(coalesce(new.batch_id, old.batch_id));
  return coalesce(new, old);
end $$;

-- Two triggers, because a DELETE trigger's WHEN clause cannot look at NEW.
drop trigger if exists ins_import_rows_control_totals_ins_upd on public.ins_import_rows;
create trigger ins_import_rows_control_totals_ins_upd
  after insert or update on public.ins_import_rows
  for each row
  when (new.sheet = 'control_totals')
  execute function public.ins_import_rows_control_totals();

drop trigger if exists ins_import_rows_control_totals_del on public.ins_import_rows;
create trigger ins_import_rows_control_totals_del
  after delete on public.ins_import_rows
  for each row
  when (old.sheet = 'control_totals')
  execute function public.ins_import_rows_control_totals();

revoke all on function public.ins_import_rows_control_totals() from public, anon, authenticated;

-- Explicit refresh, for a repaired sheet or a batch staged before this
-- migration existed.
create or replace function public.ins_import_refresh_control_totals(p_batch_id uuid)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
begin
  if public.get_my_tenant_id() is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ins_import_batches
                  where id = p_batch_id and tenant_id = public.get_my_tenant_id()) then
    raise exception 'INS_IMPORT_BATCH_NOT_FOUND';
  end if;
  return public.ins_import_sync_control_totals(p_batch_id);
end $$;
revoke all on function public.ins_import_refresh_control_totals(uuid) from public, anon;
grant execute on function public.ins_import_refresh_control_totals(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- D. The one calculation: imported versus control, per currency and measure
-- ---------------------------------------------------------------------
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

  -- Before commit there are no policies to read, and the reviewer is
  -- reconciling the file they uploaded; after commit the typed history is
  -- the ledger's own record of the same rows. One source at a time, chosen
  -- by the batch state, so the two can never be mixed into a total neither
  -- of them supports.
  v_committed := (v_status = 'committed');

  return query
  with src as (
    select p.currency as currency,
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
    select s.currency, sum(s.gross) as gross, sum(s.comm) as comm,
           sum(s.receipts) as receipts, sum(s.remits) as remits
      from src s
     group by s.currency
  )
  select i.currency,
         m.measure,
         m.amt,
         (select case m.measure
                   when 'gross_premium'       then (c ->> 'gross_premium')::numeric
                   when 'commission'          then (c ->> 'commission')::numeric
                   when 'receipts_to_date'    then (c ->> 'receipts')::numeric
                   when 'remittances_to_date' then (c ->> 'remittances')::numeric
                 end
            from jsonb_array_elements(v_totals) c
           where upper(c ->> 'currency') = upper(i.currency)
           limit 1)
    from imp i
    cross join lateral (values
      ('gross_premium', i.gross),
      ('commission', i.comm),
      ('receipts_to_date', i.receipts),
      ('remittances_to_date', i.remits)) m(measure, amt)
   order by i.currency, m.measure;
end $$;
revoke all on function public.ins_import_control_rows(uuid) from public, anon, authenticated;

-- The differences that must stop a commit: recorded and unequal.
create or replace function public.ins_import_control_diff(p_batch_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'currency', c.currency, 'measure', c.measure,
           'imported', c.imported_amount, 'control', c.control_amount)
           order by c.currency, c.measure), '[]'::jsonb)
    into v
    from public.ins_import_control_rows(p_batch_id) c
   where c.control_amount is not null
     and c.imported_amount is distinct from c.control_amount;
  return v;
end $$;
revoke all on function public.ins_import_control_diff(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- E. Reconciliation, rebuilt on D
-- ---------------------------------------------------------------------
create or replace function public.ins_import_reconciliation(p_batch_id uuid)
returns table (currency text, measure text, imported_amount numeric, control_amount numeric, match boolean)
language plpgsql stable security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if not exists (select 1 from public.ins_import_batches where id = p_batch_id and tenant_id = v_tenant) then
    raise exception 'INS_IMPORT_BATCH_NOT_FOUND';
  end if;

  return query
  select c.currency, c.measure, c.imported_amount, c.control_amount,
         case when c.control_amount is null then null
              else c.imported_amount = c.control_amount end
    from public.ins_import_control_rows(p_batch_id) c
   order by c.currency, c.measure;
end $$;
revoke all on function public.ins_import_reconciliation(uuid) from public, anon;
grant execute on function public.ins_import_reconciliation(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- F. Approving a difference: not the uploader, and only these numbers
-- ---------------------------------------------------------------------
create or replace function public.ins_import_override_control_totals(p_batch_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  b        public.ins_import_batches;
  v_diff   jsonb;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'INS_IMPORT_CONTROL_REASON: say why the totals differ (at least 10 characters)';
  end if;

  select * into b from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;
  if b.status not in ('validated') then
    raise exception 'INS_IMPORT_CONTROL_STATE: a % batch cannot have its totals approved; validate it first', b.status;
  end if;
  if b.created_by is not null and b.created_by = auth.uid() then
    raise exception 'INS_IMPORT_CONTROL_OVERRIDE_SELF: the person who uploaded the batch cannot approve its differences';
  end if;

  v_diff := public.ins_import_control_diff(p_batch_id);
  if v_diff = '[]'::jsonb then
    raise exception 'INS_IMPORT_CONTROL_NO_DIFFERENCE: the recorded control totals already agree with the staged book';
  end if;

  update public.ins_import_batches
     set control_override_reason = btrim(p_reason),
         control_override_by     = auth.uid(),
         control_override_at     = now(),
         control_override_diff   = v_diff,
         updated_at              = now()
   where id = p_batch_id;

  return jsonb_build_object('batch_id', p_batch_id, 'approved_differences', v_diff);
end $$;
revoke all on function public.ins_import_override_control_totals(uuid, text) from public, anon;
grant execute on function public.ins_import_override_control_totals(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- G. The gate: no commit while a recorded total disagrees
--
-- A trigger rather than a step in commit_policies, so every path that
-- commits a batch (RPC, repair script, a future scheduler) is covered by
-- the same rule.
-- ---------------------------------------------------------------------
create or replace function public.ins_import_batches_control_gate()
returns trigger
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_diff jsonb;
begin
  if new.status = 'committed' and coalesce(old.status, '') <> 'committed' then
    v_diff := public.ins_import_control_diff(new.id);
    if v_diff <> '[]'::jsonb
       and coalesce(new.control_override_diff, '[]'::jsonb) is distinct from v_diff then
      raise exception 'INS_IMPORT_CONTROL_MISMATCH: the recorded control totals disagree with the staged book (%). Correct the totals, or have someone other than the uploader approve them with ins_import_override_control_totals.', v_diff::text;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists ins_import_batches_control_gate on public.ins_import_batches;
create trigger ins_import_batches_control_gate
  before update on public.ins_import_batches
  for each row
  execute function public.ins_import_batches_control_gate();

revoke all on function public.ins_import_batches_control_gate() from public, anon, authenticated;
