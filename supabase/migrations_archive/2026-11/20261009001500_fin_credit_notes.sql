-- Phase 2, step D4b-2 (decision D4 in PHASE0_COUPLING_AUDIT.md): credit notes.
--
-- Adds fin_credit_notes and fin_credit_applications, and the finance-role
-- functions fin_raise_credit_note and fin_void_credit_note. A credit note
-- reduces what is owed on one or more open items of the same party, side and
-- control role.
--
-- Design (confirmed):
--   * A credit note is a separate document. fin_open_items stays immutable and
--     positive-only.
--   * It is fully applied to open items when it is raised (same rule as a
--     settlement), so the GL control account always equals the sum of
--     outstanding open items. There is no unapplied credit and no cash refund
--     in this version.
--   * One credit note can be split across several open items.
--   * Raising posts one journal: receivable side Dr offset / Cr control,
--     payable side Dr control / Cr offset. Voiding posts the reversal and the
--     applications stop counting.
--   * The offset account (revenue, expense, ...) is chosen by the caller and
--     must not be a bank, client-money or control account.
--
-- fin_allocations_guard is replaced so a settlement cannot allocate more than
-- what is left after credit applications, and fin_open_item_balances gains a
-- credited_amount column (appended, existing columns keep their names/types).
--
-- Re-runnable: create ... if not exists, create or replace, drop trigger/policy
-- if exists.

-- Journal source types: the live list from 20261008202213 plus two values.
alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries add constraint journal_entries_source_type_check
  check (source_type = any (array[
    'supplier_invoice', 'receivable_invoice', 'cash_bank_transaction', 'opening_balance', 'manual',
    'payroll_run', 'machine_fuel_log', 'machine_maintenance_request',
    'fin_settlement', 'fin_settlement_void',
    'fin_credit_note', 'fin_credit_note_void'
  ]));

create table if not exists public.fin_credit_notes (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenants(id) on delete cascade,
  credit_note_no        text not null,
  side                  text not null,
  control_role          text not null,
  party_account_id      uuid not null references public.accounts(id),
  offset_gl_account_id  uuid not null references public.gl_accounts(id),
  amount                numeric not null,
  currency              text not null,
  credit_date           date not null,
  reason                text not null,
  reference             text,
  status                text not null default 'posted',
  journal_entry_id      uuid references public.journal_entries(id),
  void_journal_entry_id uuid references public.journal_entries(id),
  voided_at             timestamptz,
  voided_by             uuid,
  void_reason           text,
  created_by            uuid default auth.uid(),
  created_at            timestamptz not null default now(),
  constraint fin_credit_notes_tenant_id_id_key unique (tenant_id, id),
  constraint fin_credit_notes_tenant_no_key unique (tenant_id, credit_note_no),
  constraint fin_credit_notes_side_check check (side in ('receivable', 'payable')),
  constraint fin_credit_notes_role_check check (control_role in ('ar_control', 'commission_receivable', 'ap_control', 'insurer_payable')),
  constraint fin_credit_notes_side_role_check check (
    (side = 'receivable' and control_role in ('ar_control', 'commission_receivable'))
    or (side = 'payable' and control_role in ('ap_control', 'insurer_payable'))
  ),
  constraint fin_credit_notes_amount_check check (amount > 0),
  constraint fin_credit_notes_currency_check check (currency ~ '^[A-Z]{3}$'),
  constraint fin_credit_notes_reason_check check (length(btrim(reason)) >= 5),
  constraint fin_credit_notes_status_check check (status in ('posted', 'void')),
  constraint fin_credit_notes_void_fields_check check (
    (status = 'posted' and voided_at is null and void_reason is null and void_journal_entry_id is null)
    or (status = 'void' and voided_at is not null and void_reason is not null and void_journal_entry_id is not null)
  )
);

create index if not exists fin_credit_notes_party_idx on public.fin_credit_notes (tenant_id, party_account_id);
create index if not exists fin_credit_notes_party_account_fk_idx on public.fin_credit_notes (party_account_id);
create index if not exists fin_credit_notes_offset_fk_idx on public.fin_credit_notes (offset_gl_account_id);
create index if not exists fin_credit_notes_journal_idx on public.fin_credit_notes (journal_entry_id) where journal_entry_id is not null;
create index if not exists fin_credit_notes_void_journal_idx on public.fin_credit_notes (void_journal_entry_id) where void_journal_entry_id is not null;

create table if not exists public.fin_credit_applications (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  credit_note_id uuid not null,
  open_item_id   uuid not null,
  amount         numeric not null,
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now(),
  constraint fin_credit_applications_note_item_key unique (credit_note_id, open_item_id),
  constraint fin_credit_applications_note_fk foreign key (tenant_id, credit_note_id)
    references public.fin_credit_notes (tenant_id, id),
  constraint fin_credit_applications_item_fk foreign key (tenant_id, open_item_id)
    references public.fin_open_items (tenant_id, id),
  constraint fin_credit_applications_amount_check check (amount > 0)
);

create index if not exists fin_credit_applications_item_idx on public.fin_credit_applications (open_item_id);
create index if not exists fin_credit_applications_tenant_note_idx on public.fin_credit_applications (tenant_id, credit_note_id);
create index if not exists fin_credit_applications_tenant_item_idx on public.fin_credit_applications (tenant_id, open_item_id);

comment on table public.fin_credit_notes is
  'Reduction of amounts owed to or by the company, fully applied to open items of one party when raised. Posted via fin_raise_credit_note(); voided by reversal via fin_void_credit_note(). Never deleted.';
comment on table public.fin_credit_applications is
  'Portion of a credit note applied to an open item. Insert-only; a void credit note stops counting.';

-- Amount of an open item already consumed by posted settlement allocations and
-- posted credit applications. Internal helper for the guards.
create or replace function public.fin_open_item_consumed(p_open_item_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
           select sum(a.amount) from fin_allocations a
             join fin_settlements s on s.id = a.settlement_id
            where a.open_item_id = p_open_item_id and s.status = 'posted'), 0)
       + coalesce((
           select sum(ca.amount) from fin_credit_applications ca
             join fin_credit_notes c on c.id = ca.credit_note_id
            where ca.open_item_id = p_open_item_id and c.status = 'posted'), 0)
$$;

revoke all on function public.fin_open_item_consumed(uuid) from public, anon, authenticated;

create or replace function public.fin_credit_notes_guard()
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
      raise exception 'CREDIT_NOTE_STATE: a credit note is created posted, with its journal attached afterwards';
    end if;
    if not exists (select 1 from accounts a where a.id = new.party_account_id and a.tenant_id = new.tenant_id) then
      raise exception 'CREDIT_NOTE_PARTY_INVALID: the party must be an account of the same company';
    end if;
    if not exists (select 1 from gl_accounts g where g.id = new.offset_gl_account_id and g.tenant_id = new.tenant_id) then
      raise exception 'CREDIT_NOTE_OFFSET: the offset account must be a GL account of the same company';
    end if;
    if new.currency is distinct from fin_ledger_currency(new.tenant_id) then
      raise exception 'CREDIT_NOTE_CURRENCY: only % credit notes are supported until multi-currency is designed (got %)',
        fin_ledger_currency(new.tenant_id), new.currency;
    end if;
    return new;
  end if;

  if (to_jsonb(new) - v_keys) is distinct from (to_jsonb(old) - v_keys) then
    raise exception 'CREDIT_NOTE_IMMUTABLE: a raised credit note cannot be edited; void it and raise a new one';
  end if;
  if old.journal_entry_id is not null and new.journal_entry_id is distinct from old.journal_entry_id then
    raise exception 'CREDIT_NOTE_IMMUTABLE: the posted journal cannot be changed';
  end if;
  if old.status = 'void' then
    raise exception 'CREDIT_NOTE_VOID: a void credit note cannot change';
  end if;
  if new.status = 'void' and (new.void_journal_entry_id is null or new.void_reason is null or new.voided_at is null) then
    raise exception 'CREDIT_NOTE_VOID: a void needs its reversing journal, reason and time';
  end if;
  return new;
end;
$$;

create or replace function public.fin_credit_applications_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_c fin_credit_notes%rowtype;
  v_i fin_open_items%rowtype;
  v_consumed numeric;
  v_note_applied numeric;
begin
  if tg_op = 'UPDATE' then
    raise exception 'CREDIT_APPLICATION_IMMUTABLE: applications cannot be changed; void the credit note instead';
  end if;

  select * into v_c from fin_credit_notes where id = new.credit_note_id and tenant_id = new.tenant_id;
  if not found then
    raise exception 'CREDIT_APPLICATION_NOTE: credit note not found in this company';
  end if;
  if v_c.status <> 'posted' then
    raise exception 'CREDIT_APPLICATION_NOTE: cannot apply a void credit note';
  end if;

  select * into v_i from fin_open_items where id = new.open_item_id and tenant_id = new.tenant_id for update;
  if not found then
    raise exception 'CREDIT_APPLICATION_ITEM: open item not found in this company';
  end if;

  if v_i.party_account_id <> v_c.party_account_id then
    raise exception 'CREDIT_APPLICATION_PARTY: item % belongs to a different party than the credit note', v_i.document_no;
  end if;
  if v_i.side <> v_c.side or v_i.control_role <> v_c.control_role then
    raise exception 'CREDIT_APPLICATION_ROLE: a % credit note cannot be applied to a % item (%)',
      v_c.control_role, v_i.control_role, v_i.document_no;
  end if;
  if v_i.currency <> v_c.currency then
    raise exception 'CREDIT_APPLICATION_CURRENCY: item % is in %, credit note is in %', v_i.document_no, v_i.currency, v_c.currency;
  end if;

  v_consumed := fin_open_item_consumed(v_i.id);
  if v_consumed + new.amount > v_i.amount then
    raise exception 'CREDIT_EXCEEDS_ITEM: % has % outstanding, % cannot be applied',
      v_i.document_no, v_i.amount - v_consumed, new.amount;
  end if;

  select coalesce(sum(amount), 0) into v_note_applied from fin_credit_applications where credit_note_id = v_c.id;
  if v_note_applied + new.amount > v_c.amount then
    raise exception 'CREDIT_EXCEEDS_NOTE: applications would exceed the credit note amount of %', v_c.amount;
  end if;

  return new;
end;
$$;

-- Replaces the guard from 20261008202213: the outstanding amount of an item now
-- also counts posted credit applications. Everything else is unchanged.
create or replace function public.fin_allocations_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_s fin_settlements%rowtype;
  v_i fin_open_items%rowtype;
  v_item_consumed numeric;
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

  v_item_consumed := fin_open_item_consumed(v_i.id);
  if v_item_consumed + new.amount > v_i.amount then
    raise exception 'ALLOCATION_EXCEEDS_ITEM: % has % outstanding, % cannot be applied',
      v_i.document_no, v_i.amount - v_item_consumed, new.amount;
  end if;

  select coalesce(sum(amount), 0) into v_settle_alloc from fin_allocations where settlement_id = v_s.id;
  if v_settle_alloc + new.amount > v_s.amount then
    raise exception 'ALLOCATION_EXCEEDS_SETTLEMENT: allocations would exceed the settlement amount of %', v_s.amount;
  end if;

  return new;
end;
$$;

revoke all on function public.fin_credit_notes_guard() from public, anon, authenticated;
revoke all on function public.fin_credit_applications_guard() from public, anon, authenticated;
revoke all on function public.fin_allocations_guard() from public, anon, authenticated;

drop trigger if exists trg_fin_credit_notes_guard on public.fin_credit_notes;
create trigger trg_fin_credit_notes_guard before insert or update on public.fin_credit_notes
  for each row execute function public.fin_credit_notes_guard();
drop trigger if exists trg_fin_credit_applications_guard on public.fin_credit_applications;
create trigger trg_fin_credit_applications_guard before insert or update on public.fin_credit_applications
  for each row execute function public.fin_credit_applications_guard();

alter table public.fin_credit_notes enable row level security;
alter table public.fin_credit_applications enable row level security;

drop policy if exists fin_credit_notes_select on public.fin_credit_notes;
create policy fin_credit_notes_select on public.fin_credit_notes
  for select using (tenant_id = get_my_tenant_id() and is_finance_team_member(null::text));
drop policy if exists fin_credit_applications_select on public.fin_credit_applications;
create policy fin_credit_applications_select on public.fin_credit_applications
  for select using (tenant_id = get_my_tenant_id() and is_finance_team_member(null::text));

revoke all on public.fin_credit_notes from anon, authenticated;
revoke all on public.fin_credit_applications from anon, authenticated;
grant select on public.fin_credit_notes, public.fin_credit_applications to authenticated;

-- Balances now subtract credit applications as well. allocated_amount keeps its
-- meaning (settlements only); credited_amount is new and appended last, which
-- CREATE OR REPLACE VIEW allows.
create or replace view public.fin_open_item_balances
with (security_invoker = true) as
select i.id, i.tenant_id, i.party_account_id, i.side, i.control_role, i.source_type, i.source_id,
       i.document_no, i.document_date, i.due_date, i.currency, i.amount, i.description,
       coalesce(a.allocated, 0) as allocated_amount,
       i.amount - coalesce(a.allocated, 0) - coalesce(c.credited, 0) as outstanding_amount,
       case when coalesce(a.allocated, 0) + coalesce(c.credited, 0) = 0 then 'open'
            when coalesce(a.allocated, 0) + coalesce(c.credited, 0) < i.amount then 'partly_settled'
            else 'settled' end as settlement_status,
       coalesce(c.credited, 0) as credited_amount
from public.fin_open_items i
left join lateral (
  select sum(al.amount) as allocated
  from public.fin_allocations al
  join public.fin_settlements s on s.id = al.settlement_id
  where al.open_item_id = i.id and s.status = 'posted'
) a on true
left join lateral (
  select sum(ca.amount) as credited
  from public.fin_credit_applications ca
  join public.fin_credit_notes cn on cn.id = ca.credit_note_id
  where ca.open_item_id = i.id and cn.status = 'posted'
) c on true;

comment on view public.fin_open_item_balances is
  'Open items with allocated (settlements), credited (credit notes) and outstanding amounts. Void settlements and void credit notes do not count. Runs with the caller''s RLS.';

revoke all on public.fin_open_item_balances from anon, authenticated;
grant select on public.fin_open_item_balances to authenticated;

create or replace function public.platform_fin_raise_credit_note_impl(
  p_tenant_id            uuid,
  p_control_role         text,
  p_party_account_id     uuid,
  p_amount               numeric,
  p_credit_date          date,
  p_offset_gl_account_id uuid,
  p_applications         jsonb,
  p_reason               text,
  p_reference            text default null
)
returns public.fin_credit_notes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_side    text;
  v_ids     uuid[];
  v_sum     numeric;
  v_elem    jsonb;
  v_item    fin_open_items%rowtype;
  v_ctl_gl  uuid;
  v_ctl_row gl_accounts%rowtype;
  v_off_row gl_accounts%rowtype;
  v_no      text;
  v_desc    text;
  v_lines   jsonb;
  v_note    fin_credit_notes%rowtype;
  v_je      journal_entries%rowtype;
begin
  if p_tenant_id is null then raise exception 'tenant id is required'; end if;
  if p_control_role is null or p_control_role not in ('ar_control', 'commission_receivable', 'ap_control', 'insurer_payable') then
    raise exception 'CREDIT_NOTE_INPUT: control role must be ar_control, commission_receivable, ap_control or insurer_payable';
  end if;
  v_side := case when p_control_role in ('ar_control', 'commission_receivable') then 'receivable' else 'payable' end;
  if p_amount is null or p_amount <= 0 then
    raise exception 'CREDIT_NOTE_INPUT: amount must be positive';
  end if;
  if p_credit_date is null or p_credit_date > current_date + 1 then
    raise exception 'CREDIT_NOTE_INPUT: credit date is required and cannot be in the future';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'CREDIT_NOTE_INPUT: a reason of at least 5 characters is required';
  end if;
  if p_applications is null or jsonb_typeof(p_applications) <> 'array' or jsonb_array_length(p_applications) = 0 then
    raise exception 'CREDIT_NOTE_INPUT: applications must be a non-empty array of {open_item_id, amount}';
  end if;

  v_ids := '{}';
  v_sum := 0;
  for v_elem in select * from jsonb_array_elements(p_applications) loop
    if jsonb_typeof(v_elem) <> 'object'
       or jsonb_typeof(v_elem -> 'open_item_id') <> 'string'
       or jsonb_typeof(v_elem -> 'amount') <> 'number' then
      raise exception 'CREDIT_NOTE_INPUT: each application needs an open_item_id (string) and an amount (number)';
    end if;
    if (v_elem ->> 'amount')::numeric <= 0 then
      raise exception 'CREDIT_NOTE_INPUT: application amounts must be positive';
    end if;
    if (v_elem ->> 'open_item_id')::uuid = any (v_ids) then
      raise exception 'CREDIT_NOTE_INPUT: an open item appears twice in the applications';
    end if;
    v_ids := v_ids || (v_elem ->> 'open_item_id')::uuid;
    v_sum := v_sum + (v_elem ->> 'amount')::numeric;
  end loop;
  if v_sum <> p_amount then
    raise exception 'CREDIT_NOTE_NOT_FULLY_APPLIED: applications total % but the credit note is %', v_sum, p_amount;
  end if;

  -- Lock the items in a fixed order, then check each one.
  for v_item in
    select * from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids) order by id for update
  loop
    if v_item.control_role <> p_control_role then
      raise exception 'CREDIT_NOTE_ROLE: a % credit note cannot be applied to % items (%)',
        p_control_role, v_item.control_role, v_item.document_no;
    end if;
  end loop;
  if (select count(*) from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids)) <> cardinality(v_ids) then
    raise exception 'CREDIT_APPLICATION_ITEM: an open item was not found in this company';
  end if;

  -- Control account for the role.
  v_ctl_gl := get_posting_account(p_tenant_id, p_control_role);
  if v_ctl_gl is null then
    raise exception 'CREDIT_NOTE_UNMAPPED_ROLE: the posting role % is not mapped to a GL account', p_control_role;
  end if;
  select * into v_ctl_row from gl_accounts where id = v_ctl_gl and tenant_id = p_tenant_id;
  if not found or not v_ctl_row.is_active then
    raise exception 'CREDIT_NOTE_UNMAPPED_ROLE: the GL account for posting role % is missing or inactive', p_control_role;
  end if;

  -- Offset account: same company, active, and not a bank, client-money or control account.
  select * into v_off_row from gl_accounts where id = p_offset_gl_account_id and tenant_id = p_tenant_id;
  if not found then
    raise exception 'CREDIT_NOTE_OFFSET: the offset account was not found in this company';
  end if;
  if not v_off_row.is_active then
    raise exception 'CREDIT_NOTE_OFFSET: the offset account % is inactive', v_off_row.account_code;
  end if;
  if v_off_row.id = v_ctl_gl or v_off_row.is_control_account
     or exists (
       select 1 from gl_posting_rules r
        where r.tenant_id = p_tenant_id and r.gl_account_id = v_off_row.id
          and r.account_role in ('ar_control', 'ap_control', 'commission_receivable', 'insurer_payable',
                                 'bank', 'cash', 'client_money_bank')
     )
     or exists (
       select 1 from fin_bank_accounts b where b.tenant_id = p_tenant_id and b.gl_account_id = v_off_row.id
     ) then
    raise exception 'CREDIT_NOTE_OFFSET: account % is a control, bank or client-money account and cannot be the offset', v_off_row.account_code;
  end if;

  v_no := next_doc_number(p_tenant_id, 'fin_credit_note', 'CRN');
  v_desc := 'Credit note ' || v_no;

  v_lines := case v_side
    when 'receivable' then jsonb_build_array(
      jsonb_build_object('gl_account_id', v_off_row.id, 'debit', p_amount, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_ctl_gl, 'credit', p_amount, 'description', v_desc))
    else jsonb_build_array(
      jsonb_build_object('gl_account_id', v_ctl_gl, 'debit', p_amount, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_off_row.id, 'credit', p_amount, 'description', v_desc))
  end;

  insert into fin_credit_notes (
    tenant_id, credit_note_no, side, control_role, party_account_id, offset_gl_account_id,
    amount, currency, credit_date, reason, reference
  ) values (
    p_tenant_id, v_no, v_side, p_control_role, p_party_account_id, v_off_row.id,
    p_amount, fin_ledger_currency(p_tenant_id), p_credit_date, btrim(p_reason), nullif(btrim(p_reference), '')
  )
  returning * into v_note;

  for v_elem in select * from jsonb_array_elements(p_applications) loop
    insert into fin_credit_applications (tenant_id, credit_note_id, open_item_id, amount)
    values (p_tenant_id, v_note.id, (v_elem ->> 'open_item_id')::uuid, (v_elem ->> 'amount')::numeric);
  end loop;

  v_je := post_journal_entry(p_tenant_id, 'fin_credit_note', v_note.id, p_credit_date, v_desc || ': ' || btrim(p_reason), v_lines);

  update fin_credit_notes set journal_entry_id = v_je.id where id = v_note.id returning * into v_note;
  return v_note;
end;
$$;

revoke all on function public.platform_fin_raise_credit_note_impl(uuid, text, uuid, numeric, date, uuid, jsonb, text, text)
  from public, anon, authenticated;

create or replace function public.fin_raise_credit_note(
  p_control_role         text,
  p_party_account_id     uuid,
  p_amount               numeric,
  p_credit_date          date,
  p_offset_gl_account_id uuid,
  p_applications         jsonb,
  p_reason               text,
  p_reference            text default null
)
returns public.fin_credit_notes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_finance_team_member('finance'::text) then
    raise exception 'not authorized: raising a credit note requires the finance role' using errcode = '42501';
  end if;
  return platform_fin_raise_credit_note_impl(
    get_my_tenant_id(), p_control_role, p_party_account_id, p_amount, p_credit_date,
    p_offset_gl_account_id, p_applications, p_reason, p_reference);
end;
$$;

revoke all on function public.fin_raise_credit_note(text, uuid, numeric, date, uuid, jsonb, text, text) from public, anon;
grant execute on function public.fin_raise_credit_note(text, uuid, numeric, date, uuid, jsonb, text, text) to authenticated;

create or replace function public.platform_fin_void_credit_note_impl(
  p_tenant_id      uuid,
  p_credit_note_id uuid,
  p_reason         text,
  p_void_date      date default current_date
)
returns public.fin_credit_notes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_note  fin_credit_notes%rowtype;
  v_lines jsonb;
  v_je    journal_entries%rowtype;
begin
  if p_tenant_id is null then raise exception 'tenant id is required'; end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'CREDIT_NOTE_VOID: a reason of at least 5 characters is required';
  end if;

  select * into v_note from fin_credit_notes where id = p_credit_note_id and tenant_id = p_tenant_id for update;
  if not found then raise exception 'CREDIT_NOTE_VOID: credit note not found in this company'; end if;
  if v_note.status <> 'posted' then raise exception 'CREDIT_NOTE_VOID: credit note % is already void', v_note.credit_note_no; end if;
  if v_note.journal_entry_id is null then raise exception 'CREDIT_NOTE_VOID: credit note % has no posted journal', v_note.credit_note_no; end if;
  if p_void_date is null or p_void_date < v_note.credit_date or p_void_date > current_date + 1 then
    raise exception 'CREDIT_NOTE_VOID: the void date must be between the credit date and today';
  end if;

  select jsonb_agg(jsonb_build_object(
           'gl_account_id', l.gl_account_id,
           'debit', l.credit,
           'credit', l.debit,
           'description', 'Reversal of ' || v_note.credit_note_no))
    into v_lines
    from journal_entry_lines l
   where l.journal_entry_id = v_note.journal_entry_id;

  v_je := post_journal_entry(p_tenant_id, 'fin_credit_note_void', v_note.id, p_void_date,
                             'Void of credit note ' || v_note.credit_note_no || ': ' || btrim(p_reason), v_lines);

  update fin_credit_notes
     set status = 'void', void_journal_entry_id = v_je.id, voided_at = now(),
         voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = v_note.id
   returning * into v_note;

  return v_note;
end;
$$;

revoke all on function public.platform_fin_void_credit_note_impl(uuid, uuid, text, date)
  from public, anon, authenticated;

create or replace function public.fin_void_credit_note(
  p_credit_note_id uuid,
  p_reason         text,
  p_void_date      date default current_date
)
returns public.fin_credit_notes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_finance_team_member('finance'::text) then
    raise exception 'not authorized: voiding a credit note requires the finance role' using errcode = '42501';
  end if;
  return platform_fin_void_credit_note_impl(get_my_tenant_id(), p_credit_note_id, p_reason, p_void_date);
end;
$$;

revoke all on function public.fin_void_credit_note(uuid, text, date) from public, anon;
grant execute on function public.fin_void_credit_note(uuid, text, date) to authenticated;

select public.apply_tenant_read_only_guard();
