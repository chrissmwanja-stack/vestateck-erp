-- Phase 2, step D4a (decision D4 in PHASE0_COUPLING_AUDIT.md): a bank-account
-- registry, the first piece of the shared open-item subledger.
--
-- Why it comes first: today a bank account is just free text
-- (cash_bank_transactions.bank_account, bank_statement_lines.bank_account) and
-- posting knows only two GL roles, 'bank' and 'cash'. There is no way to say
-- "this account holds client money" or to map different bank accounts to
-- different GL accounts. Brokerage premium handling needs both, and the
-- settlement code (D4c) needs a registry row to post against.
--
-- What this adds (additive; no existing table or function is changed):
--   * fin_bank_accounts: name, kind (operating | client_money), currency,
--     gl_account_id, optional bank details.
--       - name is the SAME text already used by cash_bank_transactions and
--         bank_statement_lines, so reconciliation (which matches on exact
--         text) keeps working untouched.
--       - gl_account_id is nullable so legacy names can be registered before
--         anyone has mapped them; D4c refuses to post against a row without
--         one. A client_money account must have one from the start.
--   * A guard trigger that enforces what RLS and CHECKs cannot:
--       - the GL account is an active asset account of the SAME tenant;
--       - client money and operating money never share a GL account, and a
--         client_money account cannot use the account mapped to the 'bank' or
--         'cash' posting role (nor an operating one the 'client_money_bank'
--         role);
--       - name, kind and tenant never change, and a mapped GL account never
--         changes. Renaming would silently orphan reconciled history and
--         re-pointing the GL account would change what past postings meant.
--         Deactivate the row and create a new one instead.
--   * Rows are never deleted (no DELETE grant or policy); use is_active.
--   * platform_fin_backfill_bank_accounts(): registers every distinct name
--     already present in cash_bank_transactions / bank_statement_lines as an
--     operating account, with the currency used most often and the GL account
--     of the tenant's 'bank' posting rule when that is an active asset
--     account. Idempotent. Internal (not executable by clients); run once here.
--   * fin_unregistered_bank_accounts: names still in use but not registered,
--     so finance can finish the mapping before D4c starts enforcing it.
--
-- Currency: the registry stores any ISO-style code, but the ledger has no
-- base-amount / FX support yet (journal_entry_lines carries a currency label
-- only). Per the agreed D4 default, D4c will reject settlements on accounts
-- whose currency is not the ledger currency until that is designed.
--
-- Access mirrors gl_posting_rules: any finance-team member reads, the
-- 'finance' role writes, always within the caller's own tenant.

-- =====================================================================
-- A. Table
-- =====================================================================
create table if not exists public.fin_bank_accounts (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  name           text not null,
  kind           text not null default 'operating',
  currency       text not null default 'UGX',
  gl_account_id  uuid references public.gl_accounts(id),
  bank_name      text,
  account_number text,
  is_active      boolean not null default true,
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint fin_bank_accounts_name_check check (name <> '' and name = btrim(name)),
  constraint fin_bank_accounts_kind_check check (kind in ('operating', 'client_money')),
  constraint fin_bank_accounts_currency_check check (currency ~ '^[A-Z]{3}$'),
  constraint fin_bank_accounts_client_money_gl_check check (kind = 'operating' or gl_account_id is not null),
  constraint fin_bank_accounts_tenant_name_unique unique (tenant_id, name)
);

comment on table public.fin_bank_accounts is
  'Registry of a tenant''s bank accounts. name is the exact text used in cash_bank_transactions.bank_account and bank_statement_lines.bank_account. kind separates client money from operating money; each maps to its own GL account. Never deleted: set is_active = false. name, kind, tenant and a mapped gl_account_id are immutable (see fin_bank_accounts_guard).';
comment on column public.fin_bank_accounts.gl_account_id is
  'GL account postings against this bank account use. Nullable only so legacy names can be registered before mapping; required for client_money, and required by settlement posting (D4c).';

create index if not exists fin_bank_accounts_gl_account_idx
  on public.fin_bank_accounts (gl_account_id) where gl_account_id is not null;

-- =====================================================================
-- B. Guard trigger
-- =====================================================================
create or replace function public.fin_bank_accounts_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_acct gl_accounts%rowtype;
begin
  if tg_op = 'UPDATE' then
    if new.tenant_id is distinct from old.tenant_id then
      raise exception 'BANK_ACCOUNT_TENANT_IMMUTABLE: a bank account cannot move to another company';
    end if;
    if new.name is distinct from old.name then
      raise exception 'BANK_ACCOUNT_NAME_IMMUTABLE: the name links this account to its transactions and statements; deactivate it and register a new one instead';
    end if;
    if new.kind is distinct from old.kind then
      raise exception 'BANK_ACCOUNT_KIND_IMMUTABLE: an account cannot change between operating and client money; deactivate it and register a new one instead';
    end if;
    if old.gl_account_id is not null and new.gl_account_id is distinct from old.gl_account_id then
      raise exception 'BANK_ACCOUNT_GL_IMMUTABLE: a mapped GL account cannot be changed; deactivate this account and register a new one instead';
    end if;
  end if;

  if new.gl_account_id is not null
     and (tg_op = 'INSERT' or new.gl_account_id is distinct from old.gl_account_id) then
    select * into v_acct from gl_accounts where id = new.gl_account_id;
    if not found or v_acct.tenant_id <> new.tenant_id then
      raise exception 'BANK_ACCOUNT_GL_INVALID: the GL account must belong to the same company';
    end if;
    if v_acct.account_type <> 'asset' then
      raise exception 'BANK_ACCOUNT_GL_INVALID: a bank account must map to an asset GL account (% is %)',
        v_acct.account_code, v_acct.account_type;
    end if;
    if not v_acct.is_active then
      raise exception 'BANK_ACCOUNT_GL_INVALID: GL account % is inactive', v_acct.account_code;
    end if;

    -- Client money and operating money must never share a GL account.
    if exists (
      select 1 from fin_bank_accounts b
      where b.tenant_id = new.tenant_id
        and b.gl_account_id = new.gl_account_id
        and b.kind <> new.kind
        and b.id <> new.id
    ) then
      raise exception 'BANK_ACCOUNT_SEGREGATION: GL account % is already used by a % bank account; client money and operating money need separate GL accounts',
        v_acct.account_code,
        case new.kind when 'client_money' then 'operating' else 'client money' end;
    end if;

    -- ...nor may a client-money account sit on the operating posting roles,
    -- or an operating account on the client-money role.
    if new.kind = 'client_money' and exists (
      select 1 from gl_posting_rules r
      where r.tenant_id = new.tenant_id
        and r.gl_account_id = new.gl_account_id
        and r.account_role in ('bank', 'cash')
    ) then
      raise exception 'BANK_ACCOUNT_SEGREGATION: GL account % is the operating bank/cash posting account and cannot hold client money', v_acct.account_code;
    end if;
    if new.kind = 'operating' and exists (
      select 1 from gl_posting_rules r
      where r.tenant_id = new.tenant_id
        and r.gl_account_id = new.gl_account_id
        and r.account_role = 'client_money_bank'
    ) then
      raise exception 'BANK_ACCOUNT_SEGREGATION: GL account % is the client-money posting account and cannot be used by an operating bank account', v_acct.account_code;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.fin_bank_accounts_guard() from public, anon, authenticated;

drop trigger if exists trg_fin_bank_accounts_guard on public.fin_bank_accounts;
create trigger trg_fin_bank_accounts_guard
  before insert or update on public.fin_bank_accounts
  for each row execute function public.fin_bank_accounts_guard();

drop trigger if exists trg_touch_fin_bank_accounts_updated_at on public.fin_bank_accounts;
create trigger trg_touch_fin_bank_accounts_updated_at
  before update on public.fin_bank_accounts
  for each row execute function public.touch_updated_at();

-- =====================================================================
-- C. RLS and grants (same shape as gl_posting_rules, minus DELETE)
-- =====================================================================
alter table public.fin_bank_accounts enable row level security;

drop policy if exists fin_bank_accounts_select on public.fin_bank_accounts;
create policy fin_bank_accounts_select on public.fin_bank_accounts
  for select using (tenant_id = get_my_tenant_id() and is_finance_team_member(null::text));

drop policy if exists fin_bank_accounts_insert on public.fin_bank_accounts;
create policy fin_bank_accounts_insert on public.fin_bank_accounts
  for insert with check (tenant_id = get_my_tenant_id() and is_finance_team_member('finance'::text));

drop policy if exists fin_bank_accounts_update on public.fin_bank_accounts;
create policy fin_bank_accounts_update on public.fin_bank_accounts
  for update using (tenant_id = get_my_tenant_id() and is_finance_team_member('finance'::text))
  with check (tenant_id = get_my_tenant_id() and is_finance_team_member('finance'::text));

revoke all on public.fin_bank_accounts from anon, authenticated;
grant select, insert, update on public.fin_bank_accounts to authenticated;

-- =====================================================================
-- D. Backfill (internal, idempotent)
-- =====================================================================
create or replace function public.platform_fin_backfill_bank_accounts(p_tenant_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer;
begin
  with seen as (
    select t.tenant_id,
           btrim(t.bank_account) as name,
           case when upper(btrim(t.currency)) ~ '^[A-Z]{3}$' then upper(btrim(t.currency)) else 'UGX' end as currency
    from cash_bank_transactions t
    where t.bank_account is not null and btrim(t.bank_account) <> ''
      and (p_tenant_id is null or t.tenant_id = p_tenant_id)
    union all
    select l.tenant_id,
           btrim(l.bank_account),
           case when upper(btrim(l.currency)) ~ '^[A-Z]{3}$' then upper(btrim(l.currency)) else 'UGX' end
    from bank_statement_lines l
    where l.bank_account is not null and btrim(l.bank_account) <> ''
      and (p_tenant_id is null or l.tenant_id = p_tenant_id)
  ), agg as (
    select tenant_id, name, mode() within group (order by currency) as currency
    from seen
    group by tenant_id, name
  ), ins as (
    insert into fin_bank_accounts (tenant_id, name, kind, currency, gl_account_id, created_by)
    select a.tenant_id, a.name, 'operating', a.currency, g.id, null
    from agg a
    left join gl_posting_rules r
      on r.tenant_id = a.tenant_id and r.account_role = 'bank'
    left join gl_accounts g
      on g.id = r.gl_account_id and g.account_type = 'asset' and g.is_active
    on conflict (tenant_id, name) do nothing
    returning 1
  )
  select count(*) into v_count from ins;

  return v_count;
end;
$$;

revoke all on function public.platform_fin_backfill_bank_accounts(uuid) from public, anon, authenticated;

select public.platform_fin_backfill_bank_accounts();

-- =====================================================================
-- E. Names in use but not registered
-- =====================================================================
create or replace view public.fin_unregistered_bank_accounts
with (security_invoker = true) as
select u.tenant_id,
       u.name,
       count(*)::integer as row_count,
       array_agg(distinct u.source order by u.source) as sources,
       max(u.seen_on) as last_seen_on
from (
  select t.tenant_id, btrim(t.bank_account) as name, 'cash_bank_transactions'::text as source, t.transaction_date as seen_on
  from cash_bank_transactions t
  where t.bank_account is not null and btrim(t.bank_account) <> ''
  union all
  select l.tenant_id, btrim(l.bank_account), 'bank_statement_lines', l.statement_date
  from bank_statement_lines l
  where l.bank_account is not null and btrim(l.bank_account) <> ''
) u
where not exists (
  select 1 from fin_bank_accounts b
  where b.tenant_id = u.tenant_id and b.name = u.name
)
group by u.tenant_id, u.name;

comment on view public.fin_unregistered_bank_accounts is
  'Bank-account names present in cash_bank_transactions or bank_statement_lines with no fin_bank_accounts row. Runs with the caller''s RLS. Finance should register each before D4c starts requiring a registered account.';

revoke all on public.fin_unregistered_bank_accounts from anon, authenticated;
grant select on public.fin_unregistered_bank_accounts to authenticated;

-- =====================================================================
-- F. Tenant read-only guard (new tenant_id table)
-- =====================================================================
select public.apply_tenant_read_only_guard();