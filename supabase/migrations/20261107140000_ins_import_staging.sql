-- =====================================================================
-- Insurance brokerage: in-force portfolio import, step 1.
-- Staging, mapping profile and validation. NOTHING IS POSTED and no
-- live policy is created here (see docs/insurance-brokerage/IN_FORCE_IMPORT.md).
--
--   ins_import_batches   one load: label, cut-over date, status. Always
--                        accounting-policy version 1 (migrated policies
--                        are not restated).
--   ins_import_rows      raw legacy rows per sheet (policies, receipts,
--                        remittances, shares, control_totals) with the
--                        mapped/resolved values and per-row errors.
--   ins_import_profiles  saved header mapping per tenant.
--
-- Working rules honoured: RPC-only writes (no DML policies, table
-- revoked from public/anon), tenant RLS on reads, manager-only, every RPC
-- is SECURITY DEFINER with a pinned search_path and refuses cross-tenant
-- callers, anon cannot execute anything.
-- =====================================================================

create table if not exists public.ins_import_batches (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenants(id) on delete cascade,
  label                     text not null,
  cut_over_date             date not null,
  status                    text not null default 'staged',
  accounting_policy_version integer not null default 1,
  error_count               integer not null default 0,
  validated_at              timestamptz,
  created_by                uuid default auth.uid(),
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  constraint ins_import_batches_tenant_id_id_key unique (tenant_id, id),
  constraint ins_import_batches_label_check check (btrim(label) <> ''),
  constraint ins_import_batches_status_check
    check (status in ('staged', 'validated', 'committed', 'abandoned')),
  constraint ins_import_batches_version_check check (accounting_policy_version = 1)
);

create table if not exists public.ins_import_rows (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  batch_id    uuid not null,
  sheet       text not null,
  line        integer not null,
  raw         jsonb not null,
  status      text not null default 'pending',
  errors      jsonb not null default '[]'::jsonb,
  resolved    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  constraint ins_import_rows_batch_fk foreign key (tenant_id, batch_id)
    references public.ins_import_batches (tenant_id, id) on delete cascade,
  constraint ins_import_rows_sheet_check
    check (sheet in ('policies', 'receipts', 'remittances', 'shares', 'control_totals')),
  constraint ins_import_rows_status_check check (status in ('pending', 'valid', 'error')),
  constraint ins_import_rows_raw_check check (jsonb_typeof(raw) = 'object'),
  constraint ins_import_rows_batch_sheet_line_key unique (batch_id, sheet, line)
);

create index if not exists ins_import_rows_policy_no_idx
  on public.ins_import_rows (batch_id, sheet, (btrim(raw ->> 'legacy_policy_no')));

create table if not exists public.ins_import_profiles (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  name        text not null,
  mapping     jsonb not null,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint ins_import_profiles_tenant_name_key unique (tenant_id, name),
  constraint ins_import_profiles_name_check check (btrim(name) <> ''),
  constraint ins_import_profiles_mapping_check check (jsonb_typeof(mapping) = 'object')
);

alter table public.ins_import_batches  enable row level security;
alter table public.ins_import_rows     enable row level security;
alter table public.ins_import_profiles enable row level security;

create policy "ins_import_batches_select" on public.ins_import_batches
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_manage_insurance());
create policy "ins_import_rows_select" on public.ins_import_rows
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_manage_insurance());
create policy "ins_import_profiles_select" on public.ins_import_profiles
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_manage_insurance());

-- No insert/update/delete policies on purpose: RPCs only.
revoke all on public.ins_import_batches  from public, anon;
revoke all on public.ins_import_rows     from public, anon;
revoke all on public.ins_import_profiles from public, anon;

-- =====================================================================
-- Internal helpers (not callable by API roles)
-- =====================================================================

create or replace function public.platform_ins_import_num(p_text text)
returns numeric
language plpgsql
immutable
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if p_text is null or btrim(p_text) = '' then return null; end if;
  return replace(btrim(p_text), ',', '')::numeric;
exception when others then
  return null;
end $$;

-- ISO dates only (YYYY-MM-DD, a trailing time part is ignored). Anything
-- else is a mapping problem for the user, never a guess.
create or replace function public.platform_ins_import_date(p_text text)
returns date
language plpgsql
immutable
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if p_text is null or btrim(p_text) !~ '^\d{4}-\d{2}-\d{2}' then return null; end if;
  return left(btrim(p_text), 10)::date;
exception when others then
  return null;
end $$;

create or replace function public.platform_ins_import_err(p_code text, p_message text)
returns jsonb
language sql
immutable
set search_path = pg_catalog, public, pg_temp
as $$
  select jsonb_build_object('code', p_code, 'message', p_message);
$$;

revoke all on function public.platform_ins_import_num(text)  from public, anon, authenticated;
revoke all on function public.platform_ins_import_date(text) from public, anon, authenticated;
revoke all on function public.platform_ins_import_err(text, text) from public, anon, authenticated;

-- =====================================================================
-- RPCs
-- =====================================================================

create or replace function public.ins_import_create_batch(p_label text, p_cut_over_date date)
returns public.ins_import_batches
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.ins_import_batches;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_label is null or btrim(p_label) = '' then
    raise exception 'INS_IMPORT_LABEL_REQUIRED';
  end if;
  if p_cut_over_date is null or p_cut_over_date > current_date then
    raise exception 'INS_IMPORT_CUTOVER_INVALID: the cut-over date is required and cannot be in the future';
  end if;

  insert into public.ins_import_batches (tenant_id, label, cut_over_date, created_by)
  values (v_tenant, btrim(p_label), p_cut_over_date, auth.uid())
  returning * into v_row;
  return v_row;
end $$;

-- Appends parsed rows (an array of JSON objects keyed by the canonical
-- column names) to one sheet of a batch. p_replace clears that sheet first.
-- Any change sends the batch back to 'staged': it must be validated again.
create or replace function public.ins_import_stage_rows(
  p_batch_id uuid,
  p_sheet    text,
  p_rows     jsonb,
  p_replace  boolean default false
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_batch  public.ins_import_batches;
  v_base   integer;
  v_n      integer;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_sheet is null or p_sheet not in ('policies', 'receipts', 'remittances', 'shares', 'control_totals') then
    raise exception 'INS_IMPORT_SHEET_INVALID';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'INS_IMPORT_ROWS_INVALID: rows must be a JSON array';
  end if;
  if jsonb_array_length(p_rows) > 2000 then
    raise exception 'INS_IMPORT_ROWS_TOO_MANY: at most 2000 rows per call';
  end if;
  if exists (select 1 from jsonb_array_elements(p_rows) e where jsonb_typeof(e) <> 'object') then
    raise exception 'INS_IMPORT_ROWS_INVALID: every row must be a JSON object';
  end if;

  select * into v_batch from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;
  if v_batch.status not in ('staged', 'validated') then
    raise exception 'INS_IMPORT_BATCH_LOCKED: a % batch cannot be changed', v_batch.status;
  end if;

  if p_replace then
    delete from public.ins_import_rows where batch_id = p_batch_id and sheet = p_sheet;
  end if;

  select coalesce(max(line), 0) into v_base
    from public.ins_import_rows where batch_id = p_batch_id and sheet = p_sheet;

  insert into public.ins_import_rows (tenant_id, batch_id, sheet, line, raw)
  select v_tenant, p_batch_id, p_sheet, v_base + t.ord::integer, t.val
    from jsonb_array_elements(p_rows) with ordinality as t(val, ord);
  get diagnostics v_n = row_count;

  update public.ins_import_batches
     set status = 'staged', validated_at = null, updated_at = now()
   where id = p_batch_id;
  return v_n;
end $$;

-- Saves (or replaces) a header mapping: {"canonical_column": "Legacy Header", ...}
create or replace function public.ins_import_save_profile(p_name text, p_mapping jsonb)
returns public.ins_import_profiles
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.ins_import_profiles;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_name is null or btrim(p_name) = '' then raise exception 'INS_IMPORT_PROFILE_NAME_REQUIRED'; end if;
  if p_mapping is null or jsonb_typeof(p_mapping) <> 'object' then
    raise exception 'INS_IMPORT_PROFILE_INVALID: mapping must be a JSON object';
  end if;

  insert into public.ins_import_profiles (tenant_id, name, mapping, created_by)
  values (v_tenant, btrim(p_name), p_mapping, auth.uid())
  on conflict (tenant_id, name)
  do update set mapping = excluded.mapping, updated_at = now()
  returning * into v_row;
  return v_row;
end $$;

-- Validates every staged row, writes status / errors / resolved ids back
-- to the rows and returns a dry-run report. Re-runnable; never posts.
create or replace function public.ins_import_validate_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_tenant   uuid := public.get_my_tenant_id();
  v_batch    public.ins_import_batches;
  v_ledger   text;
  r          record;
  v_err      jsonb;
  v_no       text;
  v_name     text;
  v_tax      text;
  v_cur      text;
  v_incep    date;
  v_exp      date;
  v_gross    numeric;
  v_comm     numeric;
  v_rate     numeric;
  v_sum      numeric;
  v_client   uuid;
  v_insurer  uuid;
  v_line     uuid;
  v_n        integer;
  v_amount   numeric;
  v_date     date;
  v_res      jsonb;
  v_errors   integer;
  v_sheets   jsonb;
  v_totals   jsonb;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into v_batch from public.ins_import_batches
   where id = p_batch_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_IMPORT_BATCH_NOT_FOUND'; end if;
  if v_batch.status not in ('staged', 'validated') then
    raise exception 'INS_IMPORT_BATCH_LOCKED: a % batch cannot be validated', v_batch.status;
  end if;

  v_ledger := public.fin_ledger_currency(v_tenant);

  update public.ins_import_rows
     set status = 'pending', errors = '[]'::jsonb, resolved = '{}'::jsonb
   where batch_id = p_batch_id;

  -- ---------------------------------------------------------------
  -- policies
  -- ---------------------------------------------------------------
  for r in select * from public.ins_import_rows
            where batch_id = p_batch_id and sheet = 'policies' order by line loop
    v_err := '[]'::jsonb;
    v_no := nullif(btrim(r.raw ->> 'legacy_policy_no'), '');
    v_name := nullif(btrim(r.raw ->> 'client_name'), '');
    v_tax := nullif(btrim(r.raw ->> 'client_tax_id'), '');
    v_cur := upper(nullif(btrim(r.raw ->> 'currency'), ''));
    v_incep := public.platform_ins_import_date(r.raw ->> 'inception_date');
    v_exp := public.platform_ins_import_date(r.raw ->> 'expiry_date');
    v_gross := public.platform_ins_import_num(r.raw ->> 'gross_premium');
    v_comm := public.platform_ins_import_num(r.raw ->> 'commission_amount');
    v_rate := public.platform_ins_import_num(r.raw ->> 'commission_rate_pct');
    v_sum := coalesce(public.platform_ins_import_num(r.raw ->> 'sum_insured'), 0);
    v_client := null; v_insurer := null; v_line := null;

    if v_no is null then v_err := v_err || public.platform_ins_import_err('MISSING_FIELD', 'legacy_policy_no is required'); end if;
    if v_name is null and v_tax is null then
      v_err := v_err || public.platform_ins_import_err('MISSING_FIELD', 'client_name or client_tax_id is required');
    end if;

    if v_no is not null then
      select count(*) into v_n from public.ins_import_rows x
       where x.batch_id = p_batch_id and x.sheet = 'policies' and btrim(x.raw ->> 'legacy_policy_no') = v_no;
      if v_n > 1 then v_err := v_err || public.platform_ins_import_err('DUPLICATE_IN_FILE', 'policy number appears ' || v_n || ' times in this batch'); end if;
      if exists (select 1 from public.ins_policies p where p.tenant_id = v_tenant and p.policy_no = v_no) then
        v_err := v_err || public.platform_ins_import_err('POLICY_EXISTS', 'a policy with this number already exists');
      end if;
    end if;

    -- client: tax id first (when it finds exactly one), then exact name
    if v_tax is not null then
      select count(*), min(c.id::text)::uuid into v_n, v_client
        from public.ins_clients c where c.tenant_id = v_tenant and c.tax_id = v_tax;
      if v_n <> 1 then v_client := null; end if;
    end if;
    if v_client is null and v_name is not null then
      select count(*), min(c.id::text)::uuid into v_n, v_client
        from public.ins_clients c
        join public.bd_clients b on b.id = c.client_id and b.tenant_id = c.tenant_id
       where c.tenant_id = v_tenant and lower(btrim(b.name)) = lower(v_name);
      if v_n = 0 then
        v_err := v_err || public.platform_ins_import_err('CLIENT_NOT_FOUND', 'no client matches ' || coalesce(v_name, v_tax));
        v_client := null;
      elsif v_n > 1 then
        v_err := v_err || public.platform_ins_import_err('CLIENT_AMBIGUOUS', 'more than one client is named ' || v_name);
        v_client := null;
      end if;
    elsif v_client is null then
      v_err := v_err || public.platform_ins_import_err('CLIENT_NOT_FOUND', 'no client matches tax id ' || v_tax);
    end if;

    select i.id into v_insurer from public.ins_insurers i
     where i.tenant_id = v_tenant
       and (i.code = upper(nullif(btrim(r.raw ->> 'insurer'), '')) or lower(i.name) = lower(nullif(btrim(r.raw ->> 'insurer'), '')))
     order by i.code limit 1;
    if v_insurer is null then v_err := v_err || public.platform_ins_import_err('INSURER_NOT_FOUND', 'unknown insurer ' || coalesce(r.raw ->> 'insurer', '(blank)')); end if;

    select l.id into v_line from public.ins_product_lines l
     where l.tenant_id = v_tenant
       and (l.code = upper(nullif(btrim(r.raw ->> 'product_line'), '')) or lower(l.name) = lower(nullif(btrim(r.raw ->> 'product_line'), '')))
     order by l.code limit 1;
    if v_line is null then v_err := v_err || public.platform_ins_import_err('PRODUCT_LINE_NOT_FOUND', 'unknown product line ' || coalesce(r.raw ->> 'product_line', '(blank)')); end if;

    if v_incep is null then v_err := v_err || public.platform_ins_import_err('BAD_DATE', 'inception_date must be YYYY-MM-DD'); end if;
    if v_exp is null then v_err := v_err || public.platform_ins_import_err('BAD_DATE', 'expiry_date must be YYYY-MM-DD'); end if;
    if v_incep is not null and v_exp is not null and v_exp <= v_incep then
      v_err := v_err || public.platform_ins_import_err('DATE_ORDER', 'expiry_date must be after inception_date');
    end if;

    if v_cur is null or v_cur !~ '^[A-Z]{3}$' then
      v_err := v_err || public.platform_ins_import_err('BAD_CURRENCY', 'currency must be a 3-letter code');
    elsif v_cur <> v_ledger and not exists (
      select 1 from public.fx_rates f
       where f.tenant_id = v_tenant and f.currency = v_cur and f.status = 'approved' and f.rate_date <= v_batch.cut_over_date) then
      v_err := v_err || public.platform_ins_import_err('FX_RATE_MISSING', 'no approved ' || v_cur || ' rate on or before the cut-over date');
    end if;

    if v_gross is null or v_gross <= 0 then v_err := v_err || public.platform_ins_import_err('BAD_AMOUNT', 'gross_premium must be a positive number'); end if;
    if v_sum < 0 then v_err := v_err || public.platform_ins_import_err('BAD_AMOUNT', 'sum_insured cannot be negative'); end if;

    if v_gross is not null and v_gross > 0 then
      if v_comm is null and v_rate is null then
        v_err := v_err || public.platform_ins_import_err('COMMISSION_MISSING', 'commission_amount or commission_rate_pct is required');
      elsif v_comm is null then
        if v_rate < 0 or v_rate >= 100 then
          v_err := v_err || public.platform_ins_import_err('COMMISSION_RANGE', 'commission_rate_pct must be at least 0 and below 100');
        else
          v_comm := round(v_gross * v_rate / 100, 2);
        end if;
      else
        if v_comm < 0 or v_comm >= v_gross then
          v_err := v_err || public.platform_ins_import_err('COMMISSION_RANGE', 'commission_amount must be at least 0 and below the gross premium');
        else
          if v_rate is not null and abs(round(v_gross * v_rate / 100, 2) - v_comm) > 0.01 then
            v_err := v_err || public.platform_ins_import_err('COMMISSION_MISMATCH', 'commission_amount and commission_rate_pct disagree');
          end if;
          v_rate := round(v_comm / v_gross * 100, 2);
        end if;
      end if;
    end if;

    v_res := '{}'::jsonb;
    if jsonb_array_length(v_err) = 0 then
      v_res := jsonb_build_object(
        'policy_no', v_no, 'client_id', v_client, 'insurer_id', v_insurer, 'product_line_id', v_line,
        'currency', v_cur, 'inception_date', v_incep, 'expiry_date', v_exp, 'sum_insured', v_sum,
        'gross_premium', v_gross, 'commission_amount', v_comm, 'commission_rate_pct', v_rate,
        'net_premium', v_gross - v_comm);
    end if;
    update public.ins_import_rows
       set errors = v_err, resolved = v_res,
           status = case when jsonb_array_length(v_err) = 0 then 'valid' else 'error' end
     where id = r.id;
  end loop;

  -- ---------------------------------------------------------------
  -- receipts and remittances (history only)
  -- ---------------------------------------------------------------
  for r in select * from public.ins_import_rows
            where batch_id = p_batch_id and sheet in ('receipts', 'remittances') order by sheet, line loop
    v_err := '[]'::jsonb;
    v_no := nullif(btrim(r.raw ->> 'legacy_policy_no'), '');
    v_date := public.platform_ins_import_date(r.raw ->> case when r.sheet = 'receipts' then 'receipt_date' else 'remit_date' end);
    v_amount := public.platform_ins_import_num(r.raw ->> 'amount');

    if v_no is null or not exists (
      select 1 from public.ins_import_rows p
       where p.batch_id = p_batch_id and p.sheet = 'policies' and btrim(p.raw ->> 'legacy_policy_no') = v_no) then
      v_err := v_err || public.platform_ins_import_err('POLICY_NOT_IN_BATCH', 'no policy in this batch has number ' || coalesce(v_no, '(blank)'));
    end if;
    if v_date is null then
      v_err := v_err || public.platform_ins_import_err('BAD_DATE', 'date must be YYYY-MM-DD');
    elsif v_date > v_batch.cut_over_date then
      v_err := v_err || public.platform_ins_import_err('AFTER_CUTOVER', 'history after the cut-over date belongs in the live system');
    end if;
    if v_amount is null or v_amount <= 0 then
      v_err := v_err || public.platform_ins_import_err('BAD_AMOUNT', 'amount must be a positive number');
    end if;
    update public.ins_import_rows
       set errors = v_err, status = case when jsonb_array_length(v_err) = 0 then 'valid' else 'error' end
     where id = r.id;
  end loop;

  -- ---------------------------------------------------------------
  -- co-insurance shares
  -- ---------------------------------------------------------------
  for r in select * from public.ins_import_rows
            where batch_id = p_batch_id and sheet = 'shares' order by line loop
    v_err := '[]'::jsonb;
    v_no := nullif(btrim(r.raw ->> 'legacy_policy_no'), '');
    v_amount := public.platform_ins_import_num(r.raw ->> 'share_pct');
    v_insurer := null;
    if v_no is null or not exists (
      select 1 from public.ins_import_rows p
       where p.batch_id = p_batch_id and p.sheet = 'policies' and btrim(p.raw ->> 'legacy_policy_no') = v_no) then
      v_err := v_err || public.platform_ins_import_err('POLICY_NOT_IN_BATCH', 'no policy in this batch has number ' || coalesce(v_no, '(blank)'));
    end if;
    select i.id into v_insurer from public.ins_insurers i
     where i.tenant_id = v_tenant
       and (i.code = upper(nullif(btrim(r.raw ->> 'insurer'), '')) or lower(i.name) = lower(nullif(btrim(r.raw ->> 'insurer'), '')))
     order by i.code limit 1;
    if v_insurer is null then v_err := v_err || public.platform_ins_import_err('INSURER_NOT_FOUND', 'unknown insurer ' || coalesce(r.raw ->> 'insurer', '(blank)')); end if;
    if v_amount is null or v_amount <= 0 or v_amount > 100 then
      v_err := v_err || public.platform_ins_import_err('BAD_AMOUNT', 'share_pct must be above 0 and at most 100');
    end if;
    update public.ins_import_rows
       set errors = v_err,
           resolved = case when jsonb_array_length(v_err) = 0 then jsonb_build_object('insurer_id', v_insurer, 'share_pct', v_amount) else '{}'::jsonb end,
           status = case when jsonb_array_length(v_err) = 0 then 'valid' else 'error' end
     where id = r.id;
  end loop;

  -- ---------------------------------------------------------------
  -- control totals (format only; compared at reconciliation)
  -- ---------------------------------------------------------------
  for r in select * from public.ins_import_rows
            where batch_id = p_batch_id and sheet = 'control_totals' order by line loop
    v_err := '[]'::jsonb;
    v_cur := upper(nullif(btrim(r.raw ->> 'currency'), ''));
    if v_cur is null or v_cur !~ '^[A-Z]{3}$' then
      v_err := v_err || public.platform_ins_import_err('BAD_CURRENCY', 'currency must be a 3-letter code');
    elsif (select count(*) from public.ins_import_rows x
            where x.batch_id = p_batch_id and x.sheet = 'control_totals' and upper(btrim(x.raw ->> 'currency')) = v_cur) > 1 then
      v_err := v_err || public.platform_ins_import_err('DUPLICATE_IN_FILE', 'one control-totals row per currency');
    end if;
    if exists (
      select 1 from jsonb_each_text(r.raw) kv
       where kv.key <> 'currency' and nullif(btrim(kv.value), '') is not null
         and public.platform_ins_import_num(kv.value) is null) then
      v_err := v_err || public.platform_ins_import_err('BAD_AMOUNT', 'every control total other than currency must be a number');
    end if;
    update public.ins_import_rows
       set errors = v_err, status = case when jsonb_array_length(v_err) = 0 then 'valid' else 'error' end
     where id = r.id;
  end loop;

  -- ---------------------------------------------------------------
  -- policy-level aggregate checks
  -- ---------------------------------------------------------------
  update public.ins_import_rows p
     set errors = p.errors || public.platform_ins_import_err('RECEIPTS_EXCEED_PREMIUM', 'receipts to date exceed the gross premium'),
         status = 'error'
    from (
      select btrim(x.raw ->> 'legacy_policy_no') as policy_no,
             sum(coalesce(public.platform_ins_import_num(x.raw ->> 'amount'), 0)) as total
        from public.ins_import_rows x
       where x.batch_id = p_batch_id and x.sheet = 'receipts' and x.status = 'valid'
       group by 1) s
   where p.batch_id = p_batch_id and p.sheet = 'policies' and p.resolved ? 'policy_no'
     and btrim(p.raw ->> 'legacy_policy_no') = s.policy_no
     and s.total > (p.resolved ->> 'gross_premium')::numeric;

  update public.ins_import_rows p
     set errors = p.errors || public.platform_ins_import_err('REMITTANCES_EXCEED_NET', 'remittances to date exceed the net premium'),
         status = 'error'
    from (
      select btrim(x.raw ->> 'legacy_policy_no') as policy_no,
             sum(coalesce(public.platform_ins_import_num(x.raw ->> 'amount'), 0)) as total
        from public.ins_import_rows x
       where x.batch_id = p_batch_id and x.sheet = 'remittances' and x.status = 'valid'
       group by 1) s
   where p.batch_id = p_batch_id and p.sheet = 'policies' and p.resolved ? 'policy_no'
     and btrim(p.raw ->> 'legacy_policy_no') = s.policy_no
     and s.total > (p.resolved ->> 'net_premium')::numeric;

  update public.ins_import_rows p
     set errors = p.errors || public.platform_ins_import_err('SHARES_NOT_100', 'co-insurance shares must add up to 100'),
         status = 'error'
    from (
      select btrim(x.raw ->> 'legacy_policy_no') as policy_no,
             sum((x.resolved ->> 'share_pct')::numeric) as total
        from public.ins_import_rows x
       where x.batch_id = p_batch_id and x.sheet = 'shares' and x.status = 'valid'
       group by 1) s
   where p.batch_id = p_batch_id and p.sheet = 'policies' and p.resolved ? 'policy_no'
     and btrim(p.raw ->> 'legacy_policy_no') = s.policy_no
     and abs(s.total - 100) > 0.01;

  -- ---------------------------------------------------------------
  -- report
  -- ---------------------------------------------------------------
  select count(*) into v_errors from public.ins_import_rows where batch_id = p_batch_id and status = 'error';

  select coalesce(jsonb_object_agg(sheet, jsonb_build_object('total', total, 'valid', valid, 'error', bad)), '{}'::jsonb)
    into v_sheets
    from (select sheet, count(*) as total,
                 count(*) filter (where status = 'valid') as valid,
                 count(*) filter (where status = 'error') as bad
            from public.ins_import_rows where batch_id = p_batch_id group by sheet) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'currency', t.currency, 'policies', t.policies, 'gross_premium', t.gross,
           'commission', t.comm, 'net_premium', t.net, 'receipts', t.receipts, 'remittances', t.remits)
           order by t.currency), '[]'::jsonb)
    into v_totals
    from (
      select p.resolved ->> 'currency' as currency,
             count(*) as policies,
             sum((p.resolved ->> 'gross_premium')::numeric) as gross,
             sum((p.resolved ->> 'commission_amount')::numeric) as comm,
             sum((p.resolved ->> 'net_premium')::numeric) as net,
             coalesce(sum((select sum(public.platform_ins_import_num(x.raw ->> 'amount'))
                             from public.ins_import_rows x
                            where x.batch_id = p_batch_id and x.sheet = 'receipts' and x.status = 'valid'
                              and btrim(x.raw ->> 'legacy_policy_no') = p.resolved ->> 'policy_no')), 0) as receipts,
             coalesce(sum((select sum(public.platform_ins_import_num(x.raw ->> 'amount'))
                             from public.ins_import_rows x
                            where x.batch_id = p_batch_id and x.sheet = 'remittances' and x.status = 'valid'
                              and btrim(x.raw ->> 'legacy_policy_no') = p.resolved ->> 'policy_no')), 0) as remits
        from public.ins_import_rows p
       where p.batch_id = p_batch_id and p.sheet = 'policies' and p.status = 'valid'
       group by 1) t;

  update public.ins_import_batches
     set error_count = v_errors,
         status = case when v_errors = 0 and exists (
                    select 1 from public.ins_import_rows where batch_id = p_batch_id and sheet = 'policies')
                  then 'validated' else 'staged' end,
         validated_at = now(), updated_at = now()
   where id = p_batch_id;

  return jsonb_build_object(
    'batch_id', p_batch_id, 'cut_over_date', v_batch.cut_over_date,
    'accounting_policy_version', 1,
    'error_count', v_errors, 'sheets', v_sheets, 'totals_by_currency', v_totals);
end $$;

-- Grants: managers only through the RPCs; anon and PUBLIC get nothing.
revoke all on function public.ins_import_create_batch(text, date)                     from public, anon;
revoke all on function public.ins_import_stage_rows(uuid, text, jsonb, boolean)        from public, anon;
revoke all on function public.ins_import_save_profile(text, jsonb)                     from public, anon;
revoke all on function public.ins_import_validate_batch(uuid)                          from public, anon;
grant execute on function public.ins_import_create_batch(text, date)                   to authenticated;
grant execute on function public.ins_import_stage_rows(uuid, text, jsonb, boolean)     to authenticated;
grant execute on function public.ins_import_save_profile(text, jsonb)                  to authenticated;
grant execute on function public.ins_import_validate_batch(uuid)                       to authenticated;
