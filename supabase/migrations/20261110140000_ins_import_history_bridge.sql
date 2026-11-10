-- =====================================================================
-- In-force import: staged history becomes real history at commit.
--
-- The gap this closes. ins_import_record_history is the only writer of
-- ins_import_receipts / ins_import_remittances, and the import wizard never
-- calls it: it stages the receipts and remittances sheets into
-- ins_import_rows, then validates, commits and posts. Nothing promoted the
-- staged rows into the typed tables, so a batch imported through the UI had
-- no history at all, and 20261110120000 posted its opening position with
-- "nothing collected, nothing remitted": receivable equal to the full
-- billed premium and an empty clearing account. The function was right and
-- the data was never handed to it.
--
-- The fix is server-side, so the wizard keeps its order (stage, validate,
-- commit, post, reconcile) and needs no change:
--
--   * ins_import_history_add       one candidate history row, with the
--                                  caps and duplicate rule in one place.
--   * ins_import_promote_history   every valid staged row for a batch.
--   * ins_import_commit_policies   now promotes before it flips the batch
--                                  to 'committed', in the same transaction,
--                                  so "the policies exist" implies "their
--                                  history exists".
--   * ins_import_record_history    re-implemented on the same core, so the
--                                  JSON API and the staged-sheet path cannot
--                                  drift apart.
--
-- Both internal functions are owner-only: they are reachable through
-- commit_policies, never through PostgREST.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A. One history row
--
-- Returns 'recorded' or 'duplicate'. Raises (rather than returning an
-- error row) because every caller is inside a transaction that must not
-- half-commit: a batch whose history does not add up cannot be committed.
-- ---------------------------------------------------------------------
create or replace function public.ins_import_history_add(
  p_batch_id  uuid,
  p_policy_id uuid,
  p_kind      text,          -- 'receipt' | 'remittance'
  p_date      date,
  p_reference text,
  p_amount    numeric
)
returns text
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  b         public.ins_import_batches;
  v_policy  public.ins_policies;
  v_ref     text := nullif(btrim(coalesce(p_reference, '')), '');
  v_have    numeric;
  v_cap     numeric;
  v_exists  boolean;
begin
  if p_kind not in ('receipt', 'remittance') then
    raise exception 'INS_IMPORT_HISTORY_KIND: % is neither a receipt nor a remittance', p_kind;
  end if;

  select * into b from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;

  -- The opening position is posted: history is frozen with it.
  if exists (select 1 from public.journal_entries
              where tenant_id = v_tenant and source_type = 'ins_import_opening'
                and source_id = p_batch_id) then
    raise exception 'INS_IMPORT_OPENING_POSTED: the opening position is posted; history can no longer change';
  end if;

  if p_date is null then
    raise exception 'INS_IMPORT_HISTORY_DATE: every % needs a date', p_kind;
  end if;
  if p_date > b.cut_over_date then
    raise exception 'INS_IMPORT_HISTORY_AFTER_CUTOFF: % dated % is after the cut-over date %',
      p_kind, p_date, b.cut_over_date;
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_IMPORT_HISTORY_AMOUNT: every % needs an amount above zero', p_kind;
  end if;

  select * into v_policy from public.ins_policies
   where tenant_id = v_tenant and id = p_policy_id and import_batch_id = p_batch_id;
  if not found then
    raise exception 'INS_IMPORT_POLICY_NOT_IN_BATCH: policy % is not in this batch', p_policy_id;
  end if;

  if p_kind = 'receipt' then
    select exists (select 1 from public.ins_import_receipts x
                    where x.tenant_id = v_tenant and x.batch_id = p_batch_id
                      and x.policy_id = v_policy.id and x.receipt_date = p_date
                      and x.amount = p_amount and x.reference is not distinct from v_ref)
      into v_exists;
    if v_exists then return 'duplicate'; end if;

    select coalesce(sum(x.amount), 0) into v_have
      from public.ins_import_receipts x
     where x.tenant_id = v_tenant and x.batch_id = p_batch_id and x.policy_id = v_policy.id;
    v_cap := v_policy.gross_premium;
    if v_have + p_amount > v_cap then
      raise exception 'INS_IMPORT_RECEIPTS_EXCEED_PREMIUM: receipts for policy % would total % against a gross premium of %',
        v_policy.policy_no, v_have + p_amount, v_cap;
    end if;

    insert into public.ins_import_receipts
      (tenant_id, batch_id, policy_id, receipt_date, reference, amount)
    values (v_tenant, p_batch_id, v_policy.id, p_date, v_ref, p_amount);
  else
    select exists (select 1 from public.ins_import_remittances x
                    where x.tenant_id = v_tenant and x.batch_id = p_batch_id
                      and x.policy_id = v_policy.id and x.remit_date = p_date
                      and x.amount = p_amount and x.reference is not distinct from v_ref)
      into v_exists;
    if v_exists then return 'duplicate'; end if;

    select coalesce(sum(x.amount), 0) into v_have
      from public.ins_import_remittances x
     where x.tenant_id = v_tenant and x.batch_id = p_batch_id and x.policy_id = v_policy.id;
    v_cap := round(v_policy.gross_premium - coalesce(v_policy.commission_amount, 0), 2);
    if v_have + p_amount > v_cap then
      raise exception 'INS_IMPORT_REMITTANCES_EXCEED_PAYABLE: remittances for policy % would total % against a net premium of %',
        v_policy.policy_no, v_have + p_amount, v_cap;
    end if;

    insert into public.ins_import_remittances
      (tenant_id, batch_id, policy_id, remit_date, reference, amount)
    values (v_tenant, p_batch_id, v_policy.id, p_date, v_ref, p_amount);
  end if;

  return 'recorded';
end $$;

revoke all on function public.ins_import_history_add(uuid, uuid, text, date, text, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- B. Promote the staged receipts and remittances sheets
--
-- Validation has already refused bad rows (POLICY_NOT_IN_BATCH, BAD_DATE,
-- AFTER_CUTOVER, BAD_AMOUNT, RECEIPTS_EXCEED_PREMIUM, REMITTANCES_EXCEED_NET)
-- and commit refuses a batch with any row not 'valid', so this is the
-- well-formed path; the core re-checks anyway because it is also the path
-- the JSON API uses.
-- ---------------------------------------------------------------------
create or replace function public.ins_import_promote_history(p_batch_id uuid)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  b         public.ins_import_batches;
  r         record;
  v_policy  uuid;
  v_outcome text;
  v_date    date;
  v_rec     integer := 0;
  v_rec_dup integer := 0;
  v_rem     integer := 0;
  v_rem_dup integer := 0;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into b from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;
  if b.status not in ('validated', 'committed') then
    raise exception 'INS_IMPORT_NOT_VALIDATED: a % batch has no history to promote', b.status;
  end if;

  set local ins.via_rpc = 'on';

  for r in
    select x.id, x.sheet, x.raw
      from public.ins_import_rows x
     where x.batch_id = p_batch_id
       and x.tenant_id = v_tenant
       and x.sheet in ('receipts', 'remittances')
       and x.status = 'valid'
     order by x.sheet, x.line
  loop
    v_date := public.platform_ins_import_date(
      r.raw ->> case when r.sheet = 'receipts' then 'receipt_date' else 'remit_date' end);

    select p.id into v_policy
      from public.ins_policies p
     where p.tenant_id = v_tenant
       and p.import_batch_id = p_batch_id
       and p.policy_no = btrim(r.raw ->> 'legacy_policy_no');
    if v_policy is null then
      raise exception 'INS_IMPORT_POLICY_NOT_IN_BATCH: staged % row % names policy % which is not in this batch',
        r.sheet, r.id, coalesce(r.raw ->> 'legacy_policy_no', '(blank)');
    end if;

    v_outcome := public.ins_import_history_add(
      p_batch_id, v_policy,
      case when r.sheet = 'receipts' then 'receipt' else 'remittance' end,
      v_date,
      r.raw ->> 'reference',
      public.platform_ins_import_num(r.raw ->> 'amount'));

    if r.sheet = 'receipts' then
      if v_outcome = 'recorded' then v_rec := v_rec + 1; else v_rec_dup := v_rec_dup + 1; end if;
    else
      if v_outcome = 'recorded' then v_rem := v_rem + 1; else v_rem_dup := v_rem_dup + 1; end if;
    end if;
  end loop;

  reset ins.via_rpc;

  return jsonb_build_object(
    'receipts_recorded', v_rec,
    'receipts_already_present', v_rec_dup,
    'remittances_recorded', v_rem,
    'remittances_already_present', v_rem_dup);
end $$;

revoke all on function public.ins_import_promote_history(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- C. record_history, re-implemented on the same core
--
-- Same signature, same payload, same error codes as 20261110120000; the
-- difference is that the rules now live in ins_import_history_add.
-- ---------------------------------------------------------------------
create or replace function public.ins_import_record_history(
  p_batch_id uuid, p_receipts jsonb, p_remittances jsonb
)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant   uuid := public.get_my_tenant_id();
  b          public.ins_import_batches;
  r          jsonb;
  v_outcome  text;
  v_rec      integer := 0;
  v_rec_skip integer := 0;
  v_rem      integer := 0;
  v_rem_skip integer := 0;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  select * into b from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;
  if b.status <> 'committed' then
    raise exception 'INS_IMPORT_NOT_COMMITTED: commit the policies before recording their payment history';
  end if;

  set local ins.via_rpc = 'on';

  for r in select * from jsonb_array_elements(coalesce(p_receipts, '[]'::jsonb)) loop
    v_outcome := public.ins_import_history_add(
      p_batch_id, (r ->> 'policy_id')::uuid, 'receipt',
      (r ->> 'receipt_date')::date, r ->> 'reference', (r ->> 'amount')::numeric);
    if v_outcome = 'recorded' then v_rec := v_rec + 1; else v_rec_skip := v_rec_skip + 1; end if;
  end loop;

  for r in select * from jsonb_array_elements(coalesce(p_remittances, '[]'::jsonb)) loop
    v_outcome := public.ins_import_history_add(
      p_batch_id, (r ->> 'policy_id')::uuid, 'remittance',
      (r ->> 'remit_date')::date, r ->> 'reference', (r ->> 'amount')::numeric);
    if v_outcome = 'recorded' then v_rem := v_rem + 1; else v_rem_skip := v_rem_skip + 1; end if;
  end loop;

  reset ins.via_rpc;

  return jsonb_build_object(
    'batch_id', p_batch_id,
    'receipts_recorded', v_rec,
    'receipts_already_present', v_rec_skip,
    'remittances_recorded', v_rem,
    'remittances_already_present', v_rem_skip);
end $$;

revoke all on function public.ins_import_record_history(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.ins_import_record_history(uuid, jsonb, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- D. Commit promotes the staged history
--
-- Everything else is 20261107160000 unchanged; the additions are the
-- v_history block and the three counts in the payload.
-- ---------------------------------------------------------------------
create or replace function public.ins_import_commit_policies(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant   uuid := public.get_my_tenant_id();
  v_batch    public.ins_import_batches;
  r          record;
  v_res      jsonb;
  v_no       text;
  v_policy   uuid;
  v_shares   jsonb;
  v_n_shares integer;
  v_policies integer := 0;
  v_share_rows integer := 0;
  v_history  jsonb;
  v_totals   jsonb;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into v_batch from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;
  if v_batch.status = 'committed' then
    raise exception 'INS_IMPORT_ALREADY_COMMITTED: this batch was committed on %', v_batch.committed_at;
  end if;
  if v_batch.status <> 'validated' then
    raise exception 'INS_IMPORT_NOT_VALIDATED: a % batch cannot be committed; validate it with no errors first', v_batch.status;
  end if;
  if exists (select 1 from public.ins_import_rows where batch_id = p_batch_id and status <> 'valid')
     or not exists (select 1 from public.ins_import_rows where batch_id = p_batch_id and sheet = 'policies') then
    raise exception 'INS_IMPORT_NOT_VALIDATED: every staged row must be valid and the batch needs at least one policy';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  perform set_config('ins.import_commit', p_batch_id::text, true);
  perform set_config('acct.import_batch', p_batch_id::text, true);

  for r in select * from public.ins_import_rows
            where batch_id = p_batch_id and sheet = 'policies' order by line loop
    v_res := r.resolved;
    v_no  := v_res ->> 'policy_no';

    insert into public.ins_policies (
      tenant_id, policy_no, client_id, insurer_id, product_line_id, status,
      inception_date, expiry_date, sum_insured, currency, gross_premium,
      commission_rate_pct, commission_amount, net_premium_to_insurer,
      bound_at, bound_by, risk_description, notes, import_batch_id, migrated_at)
    values (
      v_tenant, v_no, (v_res ->> 'client_id')::uuid, (v_res ->> 'insurer_id')::uuid,
      (v_res ->> 'product_line_id')::uuid, 'active',
      (v_res ->> 'inception_date')::date, (v_res ->> 'expiry_date')::date,
      (v_res ->> 'sum_insured')::numeric, v_res ->> 'currency', (v_res ->> 'gross_premium')::numeric,
      (v_res ->> 'commission_rate_pct')::numeric, (v_res ->> 'commission_amount')::numeric,
      (v_res ->> 'net_premium')::numeric,
      (v_res ->> 'inception_date')::date, auth.uid(),
      nullif(btrim(r.raw ->> 'risk_description'), ''), nullif(btrim(r.raw ->> 'notes'), ''),
      p_batch_id, now())
    returning id into v_policy;
    v_policies := v_policies + 1;

    -- co-insurance: share rows only when the batch lists shares for this policy
    select jsonb_agg(x.resolved order by x.line), count(*)
      into v_shares, v_n_shares
      from public.ins_import_rows x
     where x.batch_id = p_batch_id and x.sheet = 'shares'
       and btrim(x.raw ->> 'legacy_policy_no') = v_no;

    if v_n_shares > 0 then
      if (select count(distinct e ->> 'insurer_id') from jsonb_array_elements(v_shares) e) <> v_n_shares then
        raise exception 'INS_IMPORT_SHARE_DUPLICATE_INSURER: policy % lists the same insurer more than once', v_no;
      end if;
      if not exists (select 1 from jsonb_array_elements(v_shares) e where (e ->> 'insurer_id')::uuid = (v_res ->> 'insurer_id')::uuid) then
        raise exception 'INS_IMPORT_SHARE_LEAD_MISSING: policy % has an insurer that is not one of its shares; the policy insurer is the lead', v_no;
      end if;

      insert into public.ins_policy_insurer_shares (
        tenant_id, policy_id, insurer_id, is_lead, share_pct, commission_rate_pct,
        premium_amount, pass_through_amount, commission_amount, payable_amount, reviewed)
      select v_tenant, v_policy, s.insurer_id,
             s.insurer_id = (v_res ->> 'insurer_id')::uuid,
             s.pct, (v_res ->> 'commission_rate_pct')::numeric,
             prem.amount, 0, comm.amount, prem.amount - comm.amount, true
        from (select (e ->> 'insurer_id')::uuid as insurer_id, (e ->> 'share_pct')::numeric as pct
                from jsonb_array_elements(v_shares) e) s
        join public.platform_ins_import_allocate((v_res ->> 'gross_premium')::numeric, v_shares) prem on prem.insurer_id = s.insurer_id
        join public.platform_ins_import_allocate((v_res ->> 'commission_amount')::numeric, v_shares) comm on comm.insurer_id = s.insurer_id;
      get diagnostics v_n_shares = row_count;
      v_share_rows := v_share_rows + v_n_shares;

      if exists (select 1 from public.ins_policy_insurer_shares
                  where policy_id = v_policy and (premium_amount <= 0 or payable_amount <= 0)) then
        raise exception 'INS_IMPORT_SHARE_TOO_SMALL: every insurer share of policy % needs a positive premium and payable', v_no;
      end if;
    end if;
  end loop;

  -- The policies exist, so the staged payment history can be attached to
  -- them. Same transaction: a batch is committed with its history or not at
  -- all, and the opening position can no longer be posted without it.
  v_history := public.ins_import_promote_history(p_batch_id);

  update public.ins_import_batches
     set status = 'committed', committed_at = now(), committed_by = auth.uid(), updated_at = now()
   where id = p_batch_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'currency', t.currency, 'policies', t.policies, 'gross_premium', t.gross,
           'commission', t.comm, 'net_premium', t.net) order by t.currency), '[]'::jsonb)
    into v_totals
    from (select currency, count(*) as policies, sum(gross_premium) as gross,
                 sum(commission_amount) as comm, sum(net_premium_to_insurer) as net
            from public.ins_policies where import_batch_id = p_batch_id group by currency) t;

  perform set_config('ins.import_commit', '', true);
  perform set_config('acct.import_batch', '', true);
  perform set_config('ins.via_rpc', 'off', true);

  return jsonb_build_object(
    'batch_id', p_batch_id, 'policies_created', v_policies, 'share_rows_created', v_share_rows,
    'accounting_policy_version', 1, 'totals_by_currency', v_totals,
    'history_receipts_recorded', (v_history ->> 'receipts_recorded')::int,
    'history_remittances_recorded', (v_history ->> 'remittances_recorded')::int,
    'history_rows_already_present',
      (v_history ->> 'receipts_already_present')::int + (v_history ->> 'remittances_already_present')::int,
    'posted', false,
    'note', 'Policies and their payment history. Nothing is posted; the opening position is a separate step.');
end $$;

revoke all on function public.ins_import_commit_policies(uuid) from public, anon;
grant execute on function public.ins_import_commit_policies(uuid) to authenticated;
