-- Bank statement import: stop a re-imported CSV silently doubling the lines.
--
-- Problem: import_bank_statement_lines() inserts every line it is given, so
-- importing the same statement twice (or an overlapping one) duplicates the
-- lines and makes reconciliation report phantom unmatched items.
--
-- A unique constraint is the wrong fix: a real statement can contain two
-- identical lines (two equal charges, same day, same reference). So:
--
--   1. bank_statement_lines.import_batch_id tags every line with the import
--      call that created it (null for lines imported before this migration).
--   2. preview_bank_statement_import() tells the caller which incoming lines
--      are ALREADY on file. It matches on account, date, amount, currency,
--      reference and description, with multiplicity: if the file has two
--      identical lines and one is already on file, only the first counts as
--      already imported.
--   3. import_bank_statement_batch() imports a file as one batch and, when
--      asked, skips the lines the preview flags. It returns
--      {import_batch_id, imported, skipped}.
--
-- import_bank_statement_lines(text, jsonb) is left exactly as it was: seven
-- SQL tests and the insurance cash fixtures call it, and its return shape is
-- part of their contract. The web app moves to the batch function.
--
-- Rule 8: this only ADDS a nullable column. Nothing is dropped.

alter table public.bank_statement_lines
  add column if not exists import_batch_id uuid;

comment on column public.bank_statement_lines.import_batch_id is
  'Identifies the import call (import_bank_statement_batch) that created this line. Null for lines imported before 2026-11-19 or through import_bank_statement_lines.';

-- ---------------------------------------------------------------------------
-- preview_bank_statement_import
-- ---------------------------------------------------------------------------
create or replace function public.preview_bank_statement_import(
  p_bank_account text,
  p_lines jsonb
)
returns table (line_no integer, already_imported boolean)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_account   fin_bank_accounts%rowtype;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to import bank statement lines';
  end if;

  if p_bank_account is null or btrim(p_bank_account) = '' then
    raise exception 'bank_account is required';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'at least one statement line is required';
  end if;

  select * into v_account
    from fin_bank_accounts
   where tenant_id = v_tenant_id and name = btrim(p_bank_account);

  return query
  with incoming as (
    select t.ord::integer                                       as ln,
           (t.elem ->> 'statement_date')::date                  as d,
           (t.elem ->> 'amount')::numeric                       as amt,
           coalesce(nullif(t.elem ->> 'currency', ''), v_account.currency, 'UGX') as cur,
           lower(btrim(coalesce(t.elem ->> 'reference', '')))   as ref,
           lower(btrim(coalesce(t.elem ->> 'description', ''))) as descr
      from jsonb_array_elements(p_lines) with ordinality as t(elem, ord)
  ),
  ranked as (
    select i.*,
           row_number() over (partition by i.d, i.amt, i.cur, i.ref, i.descr order by i.ln) as rn
      from incoming i
  ),
  existing as (
    select l.statement_date                                  as d,
           l.amount                                          as amt,
           l.currency                                        as cur,
           lower(btrim(coalesce(l.reference, '')))           as ref,
           lower(btrim(coalesce(l.description, '')))         as descr,
           count(*)                                          as n
      from bank_statement_lines l
     where l.tenant_id = v_tenant_id
       and l.bank_account = btrim(p_bank_account)
       and l.statement_date between (select min(d) from incoming) and (select max(d) from incoming)
     group by 1, 2, 3, 4, 5
  )
  select r.ln, coalesce(r.rn <= e.n, false)
    from ranked r
    left join existing e
      on e.d = r.d and e.amt = r.amt and e.cur = r.cur and e.ref = r.ref and e.descr = r.descr
   order by r.ln;
end;
$$;

comment on function public.preview_bank_statement_import(text, jsonb) is
  'Read-only. For each incoming statement line (1-based line_no) says whether an equivalent line is already on file for the account, counting repeats: n identical lines on file cover the first n identical lines of the file.';

-- ---------------------------------------------------------------------------
-- import_bank_statement_batch
-- ---------------------------------------------------------------------------
create or replace function public.import_bank_statement_batch(
  p_bank_account text,
  p_lines jsonb,
  p_skip_duplicates boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant_id uuid := get_my_tenant_id();
  v_account   fin_bank_accounts%rowtype;
  v_batch     uuid := gen_random_uuid();
  v_line      jsonb;
  v_ord       integer := 0;
  v_dup       boolean[];
  v_imported  integer := 0;
  v_skipped   integer := 0;
begin
  if not is_finance_team_member('finance') then
    raise exception 'not authorized to import bank statement lines';
  end if;

  if p_bank_account is null or btrim(p_bank_account) = '' then
    raise exception 'bank_account is required';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'at least one statement line is required';
  end if;

  -- The registry is the source of truth for an account's currency. A name
  -- that is not registered keeps the legacy free-text behaviour.
  select * into v_account
    from fin_bank_accounts
   where tenant_id = v_tenant_id and name = btrim(p_bank_account);

  -- Validate the whole file before writing anything.
  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    if (v_line ->> 'statement_date') is null or (v_line ->> 'amount') is null then
      raise exception 'each line requires statement_date and amount';
    end if;

    if v_account.id is not null
       and coalesce(nullif(v_line ->> 'currency', ''), v_account.currency)
           is distinct from v_account.currency then
      raise exception 'BANK_STMT_CURRENCY: statement lines for % must be in %, got %',
        v_account.name, v_account.currency, nullif(v_line ->> 'currency', '');
    end if;
  end loop;

  if p_skip_duplicates then
    select array_agg(pv.already_imported order by pv.line_no)
      into v_dup
      from preview_bank_statement_import(p_bank_account, p_lines) pv;
  end if;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_ord := v_ord + 1;

    if p_skip_duplicates and coalesce(v_dup[v_ord], false) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    insert into bank_statement_lines (
      tenant_id, bank_account, statement_date, description, reference,
      amount, currency, imported_by, import_batch_id
    ) values (
      v_tenant_id,
      btrim(p_bank_account),
      (v_line ->> 'statement_date')::date,
      nullif(v_line ->> 'description', ''),
      nullif(v_line ->> 'reference', ''),
      (v_line ->> 'amount')::numeric,
      coalesce(nullif(v_line ->> 'currency', ''), v_account.currency, 'UGX'),
      auth.uid(),
      v_batch
    );
    v_imported := v_imported + 1;
  end loop;

  return jsonb_build_object(
    'import_batch_id', v_batch,
    'imported', v_imported,
    'skipped', v_skipped
  );
end;
$$;

comment on function public.import_bank_statement_batch(text, jsonb, boolean) is
  'Imports statement lines as one batch (import_batch_id). With p_skip_duplicates, lines that preview_bank_statement_import flags as already on file are skipped and counted. Returns {import_batch_id, imported, skipped}.';

-- ---------------------------------------------------------------------------
-- Grants: authenticated callers only, never PUBLIC or anon.
-- ---------------------------------------------------------------------------
revoke all on function public.preview_bank_statement_import(text, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.preview_bank_statement_import(text, jsonb)
  to authenticated, service_role;

revoke all on function public.import_bank_statement_batch(text, jsonb, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.import_bank_statement_batch(text, jsonb, boolean)
  to authenticated, service_role;
