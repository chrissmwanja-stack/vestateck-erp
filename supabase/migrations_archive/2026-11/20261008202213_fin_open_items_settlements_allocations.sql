-- Phase 2, steps D4b-1 + D4c (decision D4 in PHASE0_COUPLING_AUDIT.md): the
-- shared open-item subledger and settlement posting.
--
-- Adds fin_open_items, fin_settlements, fin_allocations, the
-- fin_open_item_balances view, and the functions fin_create_open_item (internal),
-- fin_record_settlement and fin_void_settlement (finance role). Posting fails
-- loudly on any missing mapping; client money is segregated by bank account kind
-- and re-checked at posting time; ledger currency only; fully allocated at
-- posting; posted rows immutable, voids are reversing entries.
-- Journal source types are widened from the LIVE constraint (8 values).
-- Credit notes (D4b-2) and reconciliation of settlements (D4d) come later.
--
-- Re-runnable: this file may already have been applied to production outside
-- the CLI ledger. In that case fin_settlements_bank_fk depends on
-- fin_bank_accounts_tenant_id_id_key, so that constraint must NOT be dropped
-- and re-added; it is created only when missing.

alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries add constraint journal_entries_source_type_check
  check (source_type = any (array[
    'supplier_invoice', 'receivable_invoice', 'cash_bank_transaction', 'opening_balance', 'manual',
    'payroll_run', 'machine_fuel_log', 'machine_maintenance_request',
    'fin_settlement', 'fin_settlement_void'
  ]));

create or replace function public.fin_ledger_currency(p_tenant_id uuid)
returns text
language sql
immutable
as $$ select 'UGX'::text $$;

revoke all on function public.fin_ledger_currency(uuid) from public, anon;
grant execute on function public.fin_ledger_currency(uuid) to authenticated;

-- Target of fin_settlements_bank_fk. Guarded instead of drop/add: dropping it
-- fails (2BP01) once the foreign key exists.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.fin_bank_accounts'::regclass
      and conname = 'fin_bank_accounts_tenant_id_id_key'
  ) then
    alter table public.fin_bank_accounts
      add constraint fin_bank_accounts_tenant_id_id_key unique (tenant_id, id);
  end if;
end
$$;

create table if not exists public.fin_open_items (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  party_account_id uuid not null references public.accounts(id),
  side             text not null,
  control_role     text not null,
  source_type      text not null,
  source_id        uuid,
  document_no      text not null,
  document_date    date not null,
  due_date         date,
  currency         text not null default 'UGX',
  amount           numeric not null,
  description      text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  constraint fin_open_items_tenant_id_id_key unique (tenant_id, id),
  constraint fin_open_items_side_check check (side in ('receivable', 'payable')),
  constraint fin_open_items_role_check check (control_role in ('ar_control', 'commission_receivable', 'ap_control', 'insurer_payable')),
  constraint fin_open_items_side_role_check check (
    (side = 'receivable' and control_role in ('ar_control', 'commission_receivable'))
    or (side = 'payable' and control_role in ('ap_control', 'insurer_payable'))
  ),
  constraint fin_open_items_amount_check check (amount > 0),
  constraint fin_open_items_currency_check check (currency ~ '^[A-Z]{3}$'),
  constraint fin_open_items_document_no_check check (document_no <> '' and document_no = btrim(document_no)),
  constraint fin_open_items_source_type_check check (source_type <> '' and source_type = btrim(source_type))
);

create unique index if not exists fin_open_items_source_unique
  on public.fin_open_items (tenant_id, source_type, source_id) where source_id is not null;
create index if not exists fin_open_items_party_idx on public.fin_open_items (tenant_id, party_account_id);
create index if not exists fin_open_items_party_account_fk_idx on public.fin_open_items (party_account_id);

create table if not exists public.fin_settlements (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenants(id) on delete cascade,
  settlement_no         text not null,
  direction             text not null,
  bank_account_id       uuid not null,
  party_account_id      uuid not null references public.accounts(id),
  amount                numeric not null,
  currency              text not null,
  settlement_date       date not null,
  reference             text,
  notes                 text,
  status                text not null default 'posted',
  journal_entry_id      uuid references public.journal_entries(id),
  void_journal_entry_id uuid references public.journal_entries(id),
  voided_at             timestamptz,
  voided_by             uuid,
  void_reason           text,
  created_by            uuid default auth.uid(),
  created_at            timestamptz not null default now(),
  constraint fin_settlements_tenant_id_id_key unique (tenant_id, id),
  constraint fin_settlements_tenant_no_key unique (tenant_id, settlement_no),
  constraint fin_settlements_bank_fk foreign key (tenant_id, bank_account_id)
    references public.fin_bank_accounts (tenant_id, id),
  constraint fin_settlements_direction_check check (direction in ('in', 'out')),
  constraint fin_settlements_amount_check check (amount > 0),
  constraint fin_settlements_currency_check check (currency ~ '^[A-Z]{3}$'),
  constraint fin_settlements_status_check check (status in ('posted', 'void')),
  constraint fin_settlements_void_fields_check check (
    (status = 'posted' and voided_at is null and void_reason is null and void_journal_entry_id is null)
    or (status = 'void' and voided_at is not null and void_reason is not null and void_journal_entry_id is not null)
  )
);

create index if not exists fin_settlements_party_idx on public.fin_settlements (tenant_id, party_account_id);
create index if not exists fin_settlements_party_account_fk_idx on public.fin_settlements (party_account_id);
create index if not exists fin_settlements_bank_idx on public.fin_settlements (tenant_id, bank_account_id);
create index if not exists fin_settlements_journal_idx on public.fin_settlements (journal_entry_id) where journal_entry_id is not null;
create index if not exists fin_settlements_void_journal_idx on public.fin_settlements (void_journal_entry_id) where void_journal_entry_id is not null;

create table if not exists public.fin_allocations (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  settlement_id uuid not null,
  open_item_id  uuid not null,
  amount        numeric not null,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  constraint fin_allocations_settlement_item_key unique (settlement_id, open_item_id),
  constraint fin_allocations_settlement_fk foreign key (tenant_id, settlement_id)
    references public.fin_settlements (tenant_id, id),
  constraint fin_allocations_item_fk foreign key (tenant_id, open_item_id)
    references public.fin_open_items (tenant_id, id),
  constraint fin_allocations_amount_check check (amount > 0)
);

create index if not exists fin_allocations_item_idx on public.fin_allocations (open_item_id);
create index if not exists fin_allocations_tenant_settlement_idx on public.fin_allocations (tenant_id, settlement_id);
create index if not exists fin_allocations_tenant_item_idx on public.fin_allocations (tenant_id, open_item_id);

comment on table public.fin_open_items is
  'Subledger of amounts owed to or by the company. control_role selects the GL control account. Created through fin_create_open_item() by the module that raises the document. Immutable.';
comment on table public.fin_settlements is
  'Money in or out through a registered bank account against one party, fully allocated to open items when recorded. Posted via fin_record_settlement(); voided by reversal via fin_void_settlement(). Never deleted.';
comment on table public.fin_allocations is
  'Portion of a settlement applied to an open item. Insert-only; a void settlement stops counting.';

create or replace function public.fin_open_items_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception 'OPEN_ITEM_IMMUTABLE: an open item cannot be changed; settle it, or use a credit note';
  end if;
  if not exists (select 1 from accounts a where a.id = new.party_account_id and a.tenant_id = new.tenant_id) then
    raise exception 'OPEN_ITEM_PARTY_INVALID: the party must be an account of the same company';
  end if;
  if new.currency is distinct from fin_ledger_currency(new.tenant_id) then
    raise exception 'OPEN_ITEM_CURRENCY: only % items are supported until multi-currency is designed (got %)',
      fin_ledger_currency(new.tenant_id), new.currency;
  end if;
  return new;
end;
$$;

create or replace function public.fin_settlements_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_keys constant text[] := array['journal_entry_id', 'status', 'void_journal_entry_id', 'voided_at', 'voided_by', 'void_reason'];
begin
  if tg_op = 'INSERT' then
    if new.status <> 'posted' or new.journal_entry_id is not null or new.void_journal_entry_id is not null then
      raise exception 'SETTLEMENT_STATE: a settlement is created posted, with its journal attached afterwards';
    end if;
    if not exists (select 1 from accounts a where a.id = new.party_account_id and a.tenant_id = new.tenant_id) then
      raise exception 'SETTLEMENT_PARTY_INVALID: the party must be an account of the same company';
    end if;
    if new.currency is distinct from fin_ledger_currency(new.tenant_id) then
      raise exception 'SETTLEMENT_CURRENCY: only % settlements are supported until multi-currency is designed (got %)',
        fin_ledger_currency(new.tenant_id), new.currency;
    end if;
    return new;
  end if;

  if (to_jsonb(new) - v_keys) is distinct from (to_jsonb(old) - v_keys) then
    raise exception 'SETTLEMENT_IMMUTABLE: a recorded settlement cannot be edited; void it and record a new one';
  end if;
  if old.journal_entry_id is not null and new.journal_entry_id is distinct from old.journal_entry_id then
    raise exception 'SETTLEMENT_IMMUTABLE: the posted journal cannot be changed';
  end if;
  if old.status = 'void' then
    raise exception 'SETTLEMENT_VOID: a void settlement cannot change';
  end if;
  if new.status = 'void' and (new.void_journal_entry_id is null or new.void_reason is null or new.voided_at is null) then
    raise exception 'SETTLEMENT_VOID: a void needs its reversing journal, reason and time';
  end if;
  return new;
end;
$$;

create or replace function public.fin_allocations_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_s fin_settlements%rowtype;
  v_i fin_open_items%rowtype;
  v_item_alloc numeric;
  v_settle_alloc numeric;
begin
  if tg_op = 'UPDATE' then
    raise exception 'ALLOCATION_IMMUTABLE: allocations cannot be changed; void the settlement instead';
  end if;

  select * into v_s from fin_settlements where id = new.settlement_id and tenant_id = new.tenant_id;
  if not found then
    raise exception 'ALLOCATION_SETTLEMENT: settlement not found in this company';
  end if;
  if v_s.status <> 'posted' then
    raise exception 'ALLOCATION_SETTLEMENT: cannot allocate against a void settlement';
  end if;

  select * into v_i from fin_open_items where id = new.open_item_id and tenant_id = new.tenant_id for update;
  if not found then
    raise exception 'ALLOCATION_ITEM: open item not found in this company';
  end if;

  if v_i.party_account_id <> v_s.party_account_id then
    raise exception 'ALLOCATION_PARTY: item % belongs to a different party than the settlement', v_i.document_no;
  end if;
  if (v_s.direction = 'in') <> (v_i.side = 'receivable') then
    raise exception 'ALLOCATION_DIRECTION: money % cannot settle a % item (%)',
      case v_s.direction when 'in' then 'in' else 'out' end, v_i.side, v_i.document_no;
  end if;
  if v_i.currency <> v_s.currency then
    raise exception 'ALLOCATION_CURRENCY: item % is in %, settlement is in %', v_i.document_no, v_i.currency, v_s.currency;
  end if;

  select coalesce(sum(a.amount), 0) into v_item_alloc
    from fin_allocations a join fin_settlements s on s.id = a.settlement_id
   where a.open_item_id = v_i.id and s.status = 'posted';
  if v_item_alloc + new.amount > v_i.amount then
    raise exception 'ALLOCATION_EXCEEDS_ITEM: % has % outstanding, % cannot be applied',
      v_i.document_no, v_i.amount - v_item_alloc, new.amount;
  end if;

  select coalesce(sum(amount), 0) into v_settle_alloc from fin_allocations where settlement_id = v_s.id;
  if v_settle_alloc + new.amount > v_s.amount then
    raise exception 'ALLOCATION_EXCEEDS_SETTLEMENT: allocations would exceed the settlement amount of %', v_s.amount;
  end if;

  return new;
end;
$$;

revoke all on function public.fin_open_items_guard() from public, anon, authenticated;
revoke all on function public.fin_settlements_guard() from public, anon, authenticated;
revoke all on function public.fin_allocations_guard() from public, anon, authenticated;

drop trigger if exists trg_fin_open_items_guard on public.fin_open_items;
create trigger trg_fin_open_items_guard before insert or update on public.fin_open_items
  for each row execute function public.fin_open_items_guard();
drop trigger if exists trg_fin_settlements_guard on public.fin_settlements;
create trigger trg_fin_settlements_guard before insert or update on public.fin_settlements
  for each row execute function public.fin_settlements_guard();
drop trigger if exists trg_fin_allocations_guard on public.fin_allocations;
create trigger trg_fin_allocations_guard before insert or update on public.fin_allocations
  for each row execute function public.fin_allocations_guard();

alter table public.fin_open_items enable row level security;
alter table public.fin_settlements enable row level security;
alter table public.fin_allocations enable row level security;

drop policy if exists fin_open_items_select on public.fin_open_items;
create policy fin_open_items_select on public.fin_open_items
  for select using (tenant_id = get_my_tenant_id() and is_finance_team_member(null::text));
drop policy if exists fin_settlements_select on public.fin_settlements;
create policy fin_settlements_select on public.fin_settlements
  for select using (tenant_id = get_my_tenant_id() and is_finance_team_member(null::text));
drop policy if exists fin_allocations_select on public.fin_allocations;
create policy fin_allocations_select on public.fin_allocations
  for select using (tenant_id = get_my_tenant_id() and is_finance_team_member(null::text));

revoke all on public.fin_open_items from anon, authenticated;
revoke all on public.fin_settlements from anon, authenticated;
revoke all on public.fin_allocations from anon, authenticated;
grant select on public.fin_open_items, public.fin_settlements, public.fin_allocations to authenticated;

create or replace view public.fin_open_item_balances
with (security_invoker = true) as
select i.id, i.tenant_id, i.party_account_id, i.side, i.control_role, i.source_type, i.source_id,
       i.document_no, i.document_date, i.due_date, i.currency, i.amount, i.description,
       coalesce(a.allocated, 0) as allocated_amount,
       i.amount - coalesce(a.allocated, 0) as outstanding_amount,
       case when coalesce(a.allocated, 0) = 0 then 'open'
            when coalesce(a.allocated, 0) < i.amount then 'partly_settled'
            else 'settled' end as settlement_status
from public.fin_open_items i
left join lateral (
  select sum(al.amount) as allocated
  from public.fin_allocations al
  join public.fin_settlements s on s.id = al.settlement_id
  where al.open_item_id = i.id and s.status = 'posted'
) a on true;

comment on view public.fin_open_item_balances is
  'Open items with allocated and outstanding amounts. Allocations of void settlements do not count. Runs with the caller''s RLS.';

revoke all on public.fin_open_item_balances from anon, authenticated;
grant select on public.fin_open_item_balances to authenticated;

create or replace function public.fin_create_open_item(
  p_tenant_id        uuid,
  p_party_account_id uuid,
  p_control_role     text,
  p_source_type      text,
  p_source_id        uuid,
  p_document_no      text,
  p_document_date    date,
  p_due_date         date,
  p_amount           numeric,
  p_description      text default null
)
returns public.fin_open_items
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row fin_open_items%rowtype;
begin
  if p_tenant_id is null then
    raise exception 'tenant id is required';
  end if;
  if auth.uid() is not null and p_tenant_id is distinct from public.get_my_tenant_id() then
    raise exception 'not authorized to create open items for this tenant' using errcode = '42501';
  end if;

  insert into fin_open_items (
    tenant_id, party_account_id, side, control_role, source_type, source_id,
    document_no, document_date, due_date, currency, amount, description
  ) values (
    p_tenant_id, p_party_account_id,
    case when p_control_role in ('ar_control', 'commission_receivable') then 'receivable' else 'payable' end,
    p_control_role, p_source_type, p_source_id,
    p_document_no, p_document_date, p_due_date, fin_ledger_currency(p_tenant_id), p_amount, p_description
  )
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.fin_create_open_item(uuid, uuid, text, text, uuid, text, date, date, numeric, text)
  from public, anon, authenticated;

create or replace function public.platform_fin_record_settlement_impl(
  p_tenant_id       uuid,
  p_bank_account_id uuid,
  p_direction       text,
  p_party_account_id uuid,
  p_amount          numeric,
  p_settlement_date date,
  p_allocations     jsonb,
  p_reference       text default null,
  p_notes           text default null
)
returns public.fin_settlements
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_bank     fin_bank_accounts%rowtype;
  v_gl       gl_accounts%rowtype;
  v_allowed  text[];
  v_ids      uuid[];
  v_sum      numeric;
  v_item     fin_open_items%rowtype;
  v_role     record;
  v_ctl_gl   uuid;
  v_ctl_row  gl_accounts%rowtype;
  v_lines    jsonb := '[]'::jsonb;
  v_no       text;
  v_set      fin_settlements%rowtype;
  v_je       journal_entries%rowtype;
  v_elem     jsonb;
  v_desc     text;
begin
  if p_tenant_id is null then raise exception 'tenant id is required'; end if;
  if p_direction not in ('in', 'out') then
    raise exception 'SETTLEMENT_INPUT: direction must be in or out';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'SETTLEMENT_INPUT: amount must be positive';
  end if;
  if p_settlement_date is null or p_settlement_date > current_date + 1 then
    raise exception 'SETTLEMENT_INPUT: settlement date is required and cannot be in the future';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' or jsonb_array_length(p_allocations) = 0 then
    raise exception 'SETTLEMENT_INPUT: allocations must be a non-empty array of {open_item_id, amount}';
  end if;

  v_ids := '{}';
  v_sum := 0;
  for v_elem in select * from jsonb_array_elements(p_allocations) loop
    if jsonb_typeof(v_elem) <> 'object'
       or jsonb_typeof(v_elem -> 'open_item_id') <> 'string'
       or jsonb_typeof(v_elem -> 'amount') <> 'number' then
      raise exception 'SETTLEMENT_INPUT: each allocation needs an open_item_id (string) and an amount (number)';
    end if;
    if (v_elem ->> 'amount')::numeric <= 0 then
      raise exception 'SETTLEMENT_INPUT: allocation amounts must be positive';
    end if;
    if (v_elem ->> 'open_item_id')::uuid = any (v_ids) then
      raise exception 'SETTLEMENT_INPUT: an open item appears twice in the allocations';
    end if;
    v_ids := v_ids || (v_elem ->> 'open_item_id')::uuid;
    v_sum := v_sum + (v_elem ->> 'amount')::numeric;
  end loop;
  if v_sum <> p_amount then
    raise exception 'SETTLEMENT_NOT_FULLY_ALLOCATED: allocations total % but the settlement is %', v_sum, p_amount;
  end if;

  select * into v_bank from fin_bank_accounts where id = p_bank_account_id and tenant_id = p_tenant_id for share;
  if not found then raise exception 'SETTLEMENT_BANK: bank account not found in this company'; end if;
  if not v_bank.is_active then raise exception 'SETTLEMENT_BANK: bank account % is inactive', v_bank.name; end if;
  if v_bank.gl_account_id is null then
    raise exception 'SETTLEMENT_BANK: bank account % has no GL account mapped', v_bank.name;
  end if;
  if v_bank.currency <> fin_ledger_currency(p_tenant_id) then
    raise exception 'SETTLEMENT_CURRENCY: bank account % is in %, only % is supported until multi-currency is designed',
      v_bank.name, v_bank.currency, fin_ledger_currency(p_tenant_id);
  end if;

  select * into v_gl from gl_accounts where id = v_bank.gl_account_id and tenant_id = p_tenant_id;
  if not found or v_gl.account_type <> 'asset' or not v_gl.is_active then
    raise exception 'SETTLEMENT_BANK: the GL account of bank account % is missing, inactive or not an asset account', v_bank.name;
  end if;

  if exists (
    select 1 from fin_bank_accounts b
    where b.tenant_id = p_tenant_id and b.gl_account_id = v_bank.gl_account_id and b.kind <> v_bank.kind
  ) then
    raise exception 'SETTLEMENT_SEGREGATION: GL account % is shared between client money and operating bank accounts', v_gl.account_code;
  end if;
  if v_bank.kind = 'client_money' and exists (
    select 1 from gl_posting_rules r
    where r.tenant_id = p_tenant_id and r.gl_account_id = v_bank.gl_account_id and r.account_role in ('bank', 'cash')
  ) then
    raise exception 'SETTLEMENT_SEGREGATION: GL account % is now the operating bank/cash posting account and cannot hold client money', v_gl.account_code;
  end if;
  if v_bank.kind = 'operating' and exists (
    select 1 from gl_posting_rules r
    where r.tenant_id = p_tenant_id and r.gl_account_id = v_bank.gl_account_id and r.account_role = 'client_money_bank'
  ) then
    raise exception 'SETTLEMENT_SEGREGATION: GL account % is now the client-money posting account and cannot be used by an operating bank account', v_gl.account_code;
  end if;

  v_allowed := case
    when v_bank.kind = 'client_money' and p_direction = 'in'  then array['ar_control']
    when v_bank.kind = 'client_money'                         then array['insurer_payable']
    when p_direction = 'in'                                   then array['ar_control', 'commission_receivable']
    else array['ap_control'] end;

  for v_item in
    select * from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids) order by id for update
  loop
    if v_item.control_role <> all (v_allowed) then
      raise exception 'SETTLEMENT_ROLE_NOT_ALLOWED: a % bank account taking money % cannot settle % items (%)',
        replace(v_bank.kind, '_', ' '), p_direction, v_item.control_role, v_item.document_no;
    end if;
  end loop;
  if (select count(*) from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids)) <> cardinality(v_ids) then
    raise exception 'ALLOCATION_ITEM: an open item was not found in this company';
  end if;

  v_no := next_doc_number(p_tenant_id, 'fin_settlement', 'STL');
  v_desc := case p_direction when 'in' then 'Receipt ' else 'Payment ' end || v_no;

  if p_direction = 'in' then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_bank.gl_account_id, 'debit', p_amount, 'description', v_desc);
  end if;

  for v_role in
    select i.control_role, sum((e ->> 'amount')::numeric) as amt
    from jsonb_array_elements(p_allocations) e
    join fin_open_items i on i.id = (e ->> 'open_item_id')::uuid and i.tenant_id = p_tenant_id
    group by i.control_role
    order by i.control_role
  loop
    v_ctl_gl := get_posting_account(p_tenant_id, v_role.control_role);
    if v_ctl_gl is null then
      raise exception 'SETTLEMENT_UNMAPPED_ROLE: the posting role % is not mapped to a GL account', v_role.control_role;
    end if;
    select * into v_ctl_row from gl_accounts where id = v_ctl_gl and tenant_id = p_tenant_id;
    if not found or not v_ctl_row.is_active then
      raise exception 'SETTLEMENT_UNMAPPED_ROLE: the GL account for posting role % is missing or inactive', v_role.control_role;
    end if;
    v_lines := v_lines || jsonb_build_object(
      'gl_account_id', v_ctl_gl,
      case p_direction when 'in' then 'credit' else 'debit' end, v_role.amt,
      'description', v_desc);
  end loop;

  if p_direction = 'out' then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_bank.gl_account_id, 'credit', p_amount, 'description', v_desc);
  end if;

  insert into fin_settlements (
    tenant_id, settlement_no, direction, bank_account_id, party_account_id,
    amount, currency, settlement_date, reference, notes
  ) values (
    p_tenant_id, v_no, p_direction, p_bank_account_id, p_party_account_id,
    p_amount, v_bank.currency, p_settlement_date, nullif(btrim(p_reference), ''), nullif(btrim(p_notes), '')
  )
  returning * into v_set;

  for v_elem in select * from jsonb_array_elements(p_allocations) loop
    insert into fin_allocations (tenant_id, settlement_id, open_item_id, amount)
    values (p_tenant_id, v_set.id, (v_elem ->> 'open_item_id')::uuid, (v_elem ->> 'amount')::numeric);
  end loop;

  v_je := post_journal_entry(p_tenant_id, 'fin_settlement', v_set.id, p_settlement_date, v_desc, v_lines);

  update fin_settlements set journal_entry_id = v_je.id where id = v_set.id returning * into v_set;
  return v_set;
end;
$$;

revoke all on function public.platform_fin_record_settlement_impl(uuid, uuid, text, uuid, numeric, date, jsonb, text, text)
  from public, anon, authenticated;

create or replace function public.fin_record_settlement(
  p_bank_account_id  uuid,
  p_direction        text,
  p_party_account_id uuid,
  p_amount           numeric,
  p_settlement_date  date,
  p_allocations      jsonb,
  p_reference        text default null,
  p_notes            text default null
)
returns public.fin_settlements
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_finance_team_member('finance'::text) then
    raise exception 'not authorized: recording a settlement requires the finance role' using errcode = '42501';
  end if;
  return platform_fin_record_settlement_impl(
    get_my_tenant_id(), p_bank_account_id, p_direction, p_party_account_id,
    p_amount, p_settlement_date, p_allocations, p_reference, p_notes);
end;
$$;

revoke all on function public.fin_record_settlement(uuid, text, uuid, numeric, date, jsonb, text, text)
  from public, anon;
grant execute on function public.fin_record_settlement(uuid, text, uuid, numeric, date, jsonb, text, text)
  to authenticated;

create or replace function public.platform_fin_void_settlement_impl(
  p_tenant_id     uuid,
  p_settlement_id uuid,
  p_reason        text,
  p_void_date     date default current_date
)
returns public.fin_settlements
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_set   fin_settlements%rowtype;
  v_lines jsonb;
  v_je    journal_entries%rowtype;
begin
  if p_tenant_id is null then raise exception 'tenant id is required'; end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'SETTLEMENT_VOID: a reason of at least 5 characters is required';
  end if;

  select * into v_set from fin_settlements where id = p_settlement_id and tenant_id = p_tenant_id for update;
  if not found then raise exception 'SETTLEMENT_VOID: settlement not found in this company'; end if;
  if v_set.status <> 'posted' then raise exception 'SETTLEMENT_VOID: settlement % is already void', v_set.settlement_no; end if;
  if v_set.journal_entry_id is null then raise exception 'SETTLEMENT_VOID: settlement % has no posted journal', v_set.settlement_no; end if;
  if p_void_date is null or p_void_date < v_set.settlement_date or p_void_date > current_date + 1 then
    raise exception 'SETTLEMENT_VOID: the void date must be between the settlement date and today';
  end if;

  select jsonb_agg(jsonb_build_object(
           'gl_account_id', l.gl_account_id,
           'debit', l.credit,
           'credit', l.debit,
           'description', 'Reversal of ' || v_set.settlement_no))
    into v_lines
    from journal_entry_lines l
   where l.journal_entry_id = v_set.journal_entry_id;

  v_je := post_journal_entry(p_tenant_id, 'fin_settlement_void', v_set.id, p_void_date,
                             'Void of settlement ' || v_set.settlement_no || ': ' || btrim(p_reason), v_lines);

  update fin_settlements
     set status = 'void', void_journal_entry_id = v_je.id, voided_at = now(),
         voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = v_set.id
   returning * into v_set;

  return v_set;
end;
$$;

revoke all on function public.platform_fin_void_settlement_impl(uuid, uuid, text, date)
  from public, anon, authenticated;

create or replace function public.fin_void_settlement(
  p_settlement_id uuid,
  p_reason        text,
  p_void_date     date default current_date
)
returns public.fin_settlements
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_finance_team_member('finance'::text) then
    raise exception 'not authorized: voiding a settlement requires the finance role' using errcode = '42501';
  end if;
  return platform_fin_void_settlement_impl(get_my_tenant_id(), p_settlement_id, p_reason, p_void_date);
end;
$$;

revoke all on function public.fin_void_settlement(uuid, text, date) from public, anon;
grant execute on function public.fin_void_settlement(uuid, text, date) to authenticated;

select public.apply_tenant_read_only_guard();