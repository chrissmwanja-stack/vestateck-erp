-- =====================================================================
-- Insurance brokerage: in-force portfolio import, step 2.
-- Commit the staged policies and the version-1 override
-- (see docs/insurance-brokerage/IN_FORCE_IMPORT.md, sections 3.1b and 4).
--
-- What this does:
--   * Creates the validated policies as 'active' rows, flagged with
--     import_batch_id and migrated_at, WITHOUT the bind journal, the open
--     items, the approval workflow or the certificate check. Opening
--     journals and open items are step 3; nothing is posted here.
--   * Creates insurer share rows for co-insured policies, allocating the
--     premium and the commission across insurers by largest remainder so
--     both sum exactly to the legacy figures.
--   * Lets migrated rows keep accounting-policy version 1 on a tenant that
--     is already on a later version (an explicit, audited override honoured
--     by the stamping trigger only while a validated or committed batch of
--     the same tenant is named in the transaction-local marker
--     acct.import_batch).
--
-- Not done here (by design, see IN_FORCE_IMPORT.md and the notes below):
--   * No bind snapshot (ins_policy_financial_snapshots needs a journal
--     entry; step 3 decides how migrated policies get one).
--   * No branch/agent resolution (the canonical template maps them but step 1
--     does not validate them).
--
-- Additive, except two CREATE OR REPLACE of existing functions
-- (platform_stamp_policy_version, ins_financial_configuration_guard), each
-- adding one narrowly scoped allowance and otherwise identical.
-- =====================================================================

-- =====================================================================
-- A. Batch and policy columns
-- =====================================================================
alter table public.ins_import_batches
  add column if not exists committed_at timestamptz,
  add column if not exists committed_by uuid;

alter table public.ins_policies
  add column if not exists import_batch_id uuid,
  add column if not exists migrated_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ins_policies_import_batch_fk') then
    alter table public.ins_policies
      add constraint ins_policies_import_batch_fk foreign key (tenant_id, import_batch_id)
      references public.ins_import_batches (tenant_id, id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ins_policies_import_flag_check') then
    alter table public.ins_policies
      add constraint ins_policies_import_flag_check
      check ((import_batch_id is null) = (migrated_at is null));
  end if;
end $$;

create index if not exists ins_policies_import_batch_idx
  on public.ins_policies (import_batch_id) where import_batch_id is not null;

comment on column public.ins_policies.import_batch_id is
  'Set only by ins_import_commit_policies: the in-force import batch that created this policy. Migrated policies were never bound through ins_bind_policy and have no bind journal.';

-- The import columns are set at creation by the commit RPC and never change.
create or replace function public.ins_policies_import_lock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if new.import_batch_id is not null
       and coalesce(current_setting('ins.import_commit', true), '') <> new.import_batch_id::text then
      raise exception 'INS_IMPORT_RPC_ONLY: migrated policies are created by ins_import_commit_policies()' using errcode = '42501';
    end if;
  elsif new.import_batch_id is distinct from old.import_batch_id
        or new.migrated_at is distinct from old.migrated_at then
    raise exception 'INS_IMPORT_IMMUTABLE: the import flag of a policy cannot change' using errcode = '42501';
  end if;
  return new;
end $$;

revoke all on function public.ins_policies_import_lock() from public, anon, authenticated, service_role;
drop trigger if exists ins_policies_import_lock_trg on public.ins_policies;
create trigger ins_policies_import_lock_trg before insert or update on public.ins_policies
  for each row execute function public.ins_policies_import_lock();

-- =====================================================================
-- B. Share and charge guard: allow the commit to write a migrated
--    policy's share rows. Identical to 20261107100000 plus one clause.
-- =====================================================================
create or replace function public.ins_financial_configuration_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare pid uuid;
begin
 if tg_table_name='ins_policy_financial_snapshots' then
   if tg_op<>'INSERT' then raise exception 'INS_FINANCIAL_IMMUTABLE: bind snapshot cannot be changed or deleted'; end if;
   return new;
 end if;
 pid:=case when tg_op='DELETE' then old.policy_id else new.policy_id end;
 perform id from ins_policies where id=pid for update;
 if exists(
   select 1 from ins_policies
   where id=pid and status<>'draft'
     -- the bind step of THIS policy may fill in computed amounts while approved
     and not (status='approved' and tg_op='UPDATE'
              and coalesce(current_setting('ins.binding_policy', true), '') = pid::text)
     -- the import commit may write the share rows of a policy it is creating
     and not (tg_op in ('INSERT','UPDATE')
              and coalesce(current_setting('ins.import_commit', true), '') <> ''
              and import_batch_id::text = current_setting('ins.import_commit', true))
 ) then
   raise exception 'INS_FINANCIAL_IMMUTABLE: insurer shares and charge lines are locked after bind';
 end if;
 if tg_op='UPDATE' and (new.policy_id is distinct from old.policy_id or new.tenant_id is distinct from old.tenant_id) then
   raise exception 'INS_FINANCIAL_IMMUTABLE: configuration cannot move between policies';
 end if;
 if tg_op='DELETE' then return old; else return new; end if;
end $$;

revoke all on function public.ins_financial_configuration_guard() from public,anon,authenticated;

-- =====================================================================
-- C. Version-1 override in the stamping trigger
--    Identical to 20261016130000 except: while acct.import_batch names a
--    validated or committed import batch of THE SAME tenant, the stamp is 1.
--    A fake or foreign batch id changes nothing.
-- =====================================================================
create or replace function public.platform_stamp_policy_version()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_raw    text := to_jsonb(new) ->> tg_argv[0];
  v_date   date := coalesce(left(v_raw, 10)::date, current_date);
  v_batch  uuid;
begin
  begin
    v_batch := nullif(current_setting('acct.import_batch', true), '')::uuid;
  exception when others then
    v_batch := null;
  end;

  if v_batch is not null and exists (
       select 1 from ins_import_batches b
        where b.id = v_batch and b.tenant_id = new.tenant_id and b.status in ('validated', 'committed')) then
    new.accounting_policy_version := 1;
  else
    new.accounting_policy_version := platform_accounting_policy_version(new.tenant_id, v_date);
  end if;
  return new;
end;
$$;

revoke all on function public.platform_stamp_policy_version() from public, anon, authenticated;

-- =====================================================================
-- D. Internal helper: largest-remainder allocation across shares
--    (the same rule the bind uses: exact cents, insurer-id tie-break).
-- =====================================================================
create or replace function public.platform_ins_import_allocate(p_total numeric, p_shares jsonb)
returns table (insurer_id uuid, amount numeric)
language sql
immutable
set search_path = pg_catalog, public, pg_temp
as $$
  with s as (
    select (e ->> 'insurer_id')::uuid as insurer_id, (e ->> 'share_pct')::numeric as pct
      from jsonb_array_elements(p_shares) e
  ), a as (
    select insurer_id,
           trunc(p_total * pct / 100, 2) as base,
           p_total * pct / 100 - trunc(p_total * pct / 100, 2) as fraction
      from s
  ), r as (
    select *, row_number() over (order by fraction desc, insurer_id) as rk,
           round((p_total - sum(base) over ()) * 100) as cents
      from a
  )
  select insurer_id, base + case when rk <= cents then 0.01 else 0 end from r;
$$;

revoke all on function public.platform_ins_import_allocate(numeric, jsonb) from public, anon, authenticated;

-- =====================================================================
-- E. Commit the staged policies
-- =====================================================================
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
    'posted', false,
    'note', 'Policies only. Nothing is posted; opening journals and open items are a separate step.');
end $$;

revoke all on function public.ins_import_commit_policies(uuid) from public, anon;
grant execute on function public.ins_import_commit_policies(uuid) to authenticated;