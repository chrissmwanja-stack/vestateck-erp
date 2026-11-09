-- Insurance Brokerage: deferred commission, recognition and transfer.
--
-- Decisions (confirmed 2026-10-11):
--   * Commission is credited to an unearned-commission liability when the policy
--     is bound, not to income.
--   * It is recognised as income when the insurer's net item for that policy is
--     fully settled (the broker has paid the insurer).
--   * Earned commission still sits in the client-money bank account. A manager
--     moves it to an operating bank account with a transfer batch.
--   * No VAT or WHT lines on commission.
--   * Bound-policy corrections stay "reverse and re-issue" for v1.
--
-- What this migration does
--   1. Posting role `unearned_commission` (19 roles). The insurance template gains
--      account 2020 and its rule; existing insurance tenants are backfilled.
--   2. Journal source types for recognition, its reversal, transfer, and its void.
--   3. ins_commission_entries (one per policy bound from now on),
--      ins_commission_events (append-only history) and ins_commission_transfers.
--   4. ins_bind_policy credits unearned_commission instead of commission_income
--      and records the entry. It also requires the commission_income rule at bind,
--      so recognition cannot fail later and block an insurer settlement.
--   5. Triggers on fin_settlements: recognise when a posted settlement fully pays
--      an insurer item; reverse when voiding it leaves the item unpaid; refuse
--      that void while the commission has been transferred out.
--   6. ins_transfer_earned_commission / ins_void_commission_transfer (manager
--      only) and two read views.
--
-- Not covered (deliberately)
--   * Policies bound BEFORE this migration keep the old treatment (commission to
--     income at bind). They get no entry and are not touched.
--   * Transfers are not yet matchable to bank statement lines in the D4d
--     reconciliation, so both statement lines of a transfer show as unmatched
--     until that is built.
--   * Recognition counts payments only. A credit note on an insurer item does not
--     make the item "fully settled"; the commission stays unearned until the
--     payments themselves cover it.
--
-- Re-runnable: create or replace, if not exists, on conflict do nothing.

-- =====================================================================
-- 1. Posting role
-- =====================================================================
alter table public.gl_posting_rules drop constraint if exists gl_posting_rules_account_role_check;
alter table public.gl_posting_rules
  add constraint gl_posting_rules_account_role_check
  check (account_role in (
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable',
    'unearned_commission'
  ));

create or replace function public.platform_gl_posting_roles()
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select array[
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable',
    'unearned_commission'
  ]::text[];
$$;

revoke all on function public.platform_gl_posting_roles() from public, anon;
grant execute on function public.platform_gl_posting_roles() to authenticated;

-- Template: new tenants get the account and the rule. Data only, never overwrites
-- later edits made through the template editor.
insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
select 'insurance', v.kind, v.sort_order, v.name, v.payload
from (values
  ('gl_account', 19, '2020',
     '{"name": "Unearned Commission", "account_type": "liability", "is_control_account": true}'::jsonb),
  ('posting_rule', 19, 'unearned_commission', '{"account_code": "2020"}'::jsonb)
) as v(kind, sort_order, name, payload)
where exists (select 1 from public.industry_templates t where t.key = 'insurance')
on conflict (template_key, kind, name) do nothing;

-- Existing insurance tenants (those with an insurer_payable rule): add the account
-- and rule. If code 2020 is already used for something else, leave the tenant
-- alone; binding then stops with INS_POSTING_RULE_MISSING and says what to map.
do $$
declare
  t    record;
  v_gl uuid;
begin
  for t in
    select distinct r.tenant_id
    from public.gl_posting_rules r
    where r.account_role = 'insurer_payable'
      and not exists (
        select 1 from public.gl_posting_rules x
        where x.tenant_id = r.tenant_id and x.account_role = 'unearned_commission')
  loop
    select id into v_gl from public.gl_accounts
     where tenant_id = t.tenant_id and account_code = '2020';
    if v_gl is null then
      insert into public.gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
      values (t.tenant_id, '2020', 'Unearned Commission', 'liability', true)
      returning id into v_gl;
    elsif not exists (
      select 1 from public.gl_accounts
       where id = v_gl and account_type = 'liability' and is_active
         and name ilike '%unearned commission%'
    ) then
      raise notice 'ins_commission_deferral: tenant % already uses account code 2020 for something else; map unearned_commission by hand', t.tenant_id;
      continue;
    end if;
    insert into public.gl_posting_rules (tenant_id, account_role, gl_account_id)
    values (t.tenant_id, 'unearned_commission', v_gl)
    on conflict (tenant_id, account_role) do nothing;
  end loop;
end
$$;

-- =====================================================================
-- 2. Journal source types
-- =====================================================================
alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries add constraint journal_entries_source_type_check
  check (source_type = any (array[
    'supplier_invoice', 'receivable_invoice', 'cash_bank_transaction', 'opening_balance', 'manual',
    'payroll_run', 'machine_fuel_log', 'machine_maintenance_request',
    'fin_settlement', 'fin_settlement_void',
    'fin_credit_note', 'fin_credit_note_void',
    'ins_policy_bind',
    'ins_commission_recognition', 'ins_commission_recognition_reversal',
    'ins_commission_transfer', 'ins_commission_transfer_void'
  ]));

-- =====================================================================
-- 3. Tables
-- =====================================================================
create table if not exists public.ins_commission_transfers (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenants(id) on delete cascade,
  transfer_no           text not null,
  from_bank_account_id  uuid not null,
  to_bank_account_id    uuid not null,
  transfer_date         date not null,
  amount                numeric(18,2) not null check (amount > 0),
  currency              text not null,
  status                text not null default 'posted' check (status in ('posted', 'void')),
  notes                 text,
  journal_entry_id      uuid references public.journal_entries(id),
  void_journal_entry_id uuid references public.journal_entries(id),
  voided_at             timestamptz,
  voided_by             uuid,
  void_reason           text,
  created_by            uuid default auth.uid(),
  created_at            timestamptz not null default now(),
  constraint ins_commission_transfers_no_key unique (tenant_id, transfer_no),
  constraint ins_commission_transfers_tenant_id_id_key unique (tenant_id, id),
  constraint ins_commission_transfers_banks_differ check (from_bank_account_id <> to_bank_account_id),
  constraint ins_commission_transfers_from_fk foreign key (tenant_id, from_bank_account_id)
    references public.fin_bank_accounts (tenant_id, id),
  constraint ins_commission_transfers_to_fk foreign key (tenant_id, to_bank_account_id)
    references public.fin_bank_accounts (tenant_id, id),
  constraint ins_commission_transfers_void_check check (
    (status = 'posted' and void_journal_entry_id is null and voided_at is null)
    or (status = 'void' and void_journal_entry_id is not null and voided_at is not null)
  )
);

create table if not exists public.ins_commission_entries (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  policy_id   uuid not null references public.ins_policies(id),
  amount      numeric(18,2) not null check (amount > 0),
  status      text not null default 'deferred' check (status in ('deferred', 'earned', 'transferred')),
  earned_on   date,
  transfer_id uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint ins_commission_entries_policy_key unique (policy_id),
  constraint ins_commission_entries_transfer_fk foreign key (tenant_id, transfer_id)
    references public.ins_commission_transfers (tenant_id, id),
  constraint ins_commission_entries_state_check check (
    (status = 'deferred'    and earned_on is null     and transfer_id is null)
    or (status = 'earned'   and earned_on is not null and transfer_id is null)
    or (status = 'transferred' and earned_on is not null and transfer_id is not null)
  )
);
create index if not exists ins_commission_entries_tenant_status_idx
  on public.ins_commission_entries (tenant_id, status);
create index if not exists ins_commission_entries_transfer_idx
  on public.ins_commission_entries (transfer_id) where transfer_id is not null;

create table if not exists public.ins_commission_events (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  entry_id         uuid not null references public.ins_commission_entries(id),
  event            text not null check (event in ('recognised', 'recognition_reversed', 'transferred', 'transfer_voided')),
  amount           numeric(18,2) not null check (amount > 0),
  journal_entry_id uuid references public.journal_entries(id),
  settlement_id    uuid references public.fin_settlements(id),
  transfer_id      uuid,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now()
);
create index if not exists ins_commission_events_entry_idx on public.ins_commission_events (entry_id, created_at);

alter table public.ins_commission_transfers enable row level security;
alter table public.ins_commission_entries   enable row level security;
alter table public.ins_commission_events    enable row level security;

drop policy if exists ins_commission_transfers_select on public.ins_commission_transfers;
create policy ins_commission_transfers_select on public.ins_commission_transfers
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_commission_entries_select on public.ins_commission_entries;
create policy ins_commission_entries_select on public.ins_commission_entries
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());
drop policy if exists ins_commission_events_select on public.ins_commission_events;
create policy ins_commission_events_select on public.ins_commission_events
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());

-- Written only by the functions below (security definer). No direct writes.
revoke all on public.ins_commission_transfers from anon, authenticated, public;
revoke all on public.ins_commission_entries   from anon, authenticated, public;
revoke all on public.ins_commission_events    from anon, authenticated, public;
grant select on public.ins_commission_transfers, public.ins_commission_entries,
                public.ins_commission_events to authenticated;

-- =====================================================================
-- 4. Bind: commission goes to the unearned liability
-- =====================================================================
-- Body identical to 20261010130000 except: the commission line credits
-- unearned_commission, commission_income is still required (recognition needs
-- it), and an ins_commission_entries row is recorded.
create or replace function public.ins_bind_policy(p_policy_id uuid)
returns public.ins_policies
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pol        ins_policies%rowtype;
  v_client     ins_clients%rowtype;
  v_client_nm  text;
  v_comm       numeric(18,2);
  v_net        numeric(18,2);
  v_ar_acc     uuid;
  v_ins_acc    uuid;
  v_ar_gl      uuid;
  v_payable_gl uuid;
  v_unearned_gl uuid;
  v_income_gl  uuid;
  v_lines      jsonb;
  v_je         journal_entries;
  v_desc       text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can bind policies' using errcode = '42501';
  end if;

  select * into v_pol from ins_policies where id = p_policy_id for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  perform assert_tenant_access(v_pol.tenant_id);

  if v_pol.status <> 'draft' then
    raise exception 'INS_NOT_DRAFT: policy % is already %', v_pol.policy_no, v_pol.status;
  end if;
  if v_pol.gross_premium <= 0 then
    raise exception 'INS_PREMIUM_REQUIRED: enter the gross premium before binding';
  end if;
  if v_pol.currency is distinct from fin_ledger_currency(v_pol.tenant_id) then
    raise exception 'INS_CURRENCY_UNSUPPORTED: policies bind in the ledger currency (%) only until multi-currency is designed (policy is %)',
      fin_ledger_currency(v_pol.tenant_id), v_pol.currency;
  end if;

  v_comm := round(v_pol.gross_premium * v_pol.commission_rate_pct / 100, 2);
  v_net  := v_pol.gross_premium - v_comm;
  if v_net <= 0 then
    raise exception 'INS_COMMISSION_TOO_HIGH: commission would leave nothing to remit to the insurer';
  end if;

  -- Posting roles from the tenant's chart. Missing roles stop the bind.
  v_ar_gl       := get_posting_account(v_pol.tenant_id, 'ar_control');
  v_payable_gl  := get_posting_account(v_pol.tenant_id, 'insurer_payable');
  v_unearned_gl := get_posting_account(v_pol.tenant_id, 'unearned_commission');
  v_income_gl   := get_posting_account(v_pol.tenant_id, 'commission_income');
  if v_ar_gl is null or v_payable_gl is null
     or (v_comm > 0 and (v_unearned_gl is null or v_income_gl is null)) then
    raise exception 'INS_POSTING_RULE_MISSING: the chart of accounts needs ar_control, insurer_payable, unearned_commission and commission_income';
  end if;

  select * into v_client from ins_clients where id = v_pol.client_id;
  select name into v_client_nm from bd_clients where id = v_client.client_id;
  v_ar_acc  := ins_ensure_client_account(v_pol.client_id);
  v_ins_acc := ins_ensure_insurer_account(v_pol.insurer_id);

  v_desc := 'Bind ' || v_pol.policy_no || ' (' || coalesce(v_client_nm, 'client') || ')';
  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ar_gl, 'debit', v_pol.gross_premium, 'description', v_desc),
    jsonb_build_object('gl_account_id', v_payable_gl, 'credit', v_net, 'description', v_desc)
  );
  if v_comm > 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('gl_account_id', v_unearned_gl, 'credit', v_comm,
                         'description', v_desc || ' - unearned commission')
    );
  end if;

  -- Booked on the inception date, so the period-close check applies to it.
  v_je := post_journal_entry(v_pol.tenant_id, 'ins_policy_bind', v_pol.id, v_pol.inception_date, v_desc, v_lines);

  perform fin_create_open_item(
    v_pol.tenant_id, v_ar_acc, 'ar_control', 'ins_policy_premium', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_pol.gross_premium,
    'Premium due: ' || v_pol.policy_no
  );
  perform fin_create_open_item(
    v_pol.tenant_id, v_ins_acc, 'insurer_payable', 'ins_policy_insurer', v_pol.id,
    v_pol.policy_no, v_pol.inception_date, v_pol.inception_date, v_net,
    'Net premium payable to insurer: ' || v_pol.policy_no
  );

  if v_comm > 0 then
    insert into ins_commission_entries (tenant_id, policy_id, amount)
    values (v_pol.tenant_id, v_pol.id, v_comm);
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update ins_policies
     set status = 'active',
         commission_amount = v_comm,
         net_premium_to_insurer = v_net,
         bound_at = now(),
         bound_by = auth.uid(),
         journal_entry_id = v_je.id
   where id = v_pol.id
  returning * into v_pol;

  if v_pol.renewal_of_id is not null then
    update ins_policies set status = 'renewed'
     where id = v_pol.renewal_of_id and tenant_id = v_pol.tenant_id and status = 'active';
  end if;

  return v_pol;
end;
$$;

-- =====================================================================
-- 5. Recognition and reversal, driven by settlements
-- =====================================================================
-- A posted allocation total on an open item, ignoring void settlements.
create or replace function public.ins_item_paid_amount(p_open_item_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(al.amount), 0)
  from fin_allocations al
  join fin_settlements s on s.id = al.settlement_id
  where al.open_item_id = p_open_item_id and s.status = 'posted';
$$;

revoke all on function public.ins_item_paid_amount(uuid) from public, anon, authenticated;

-- AFTER the settlement's journal is attached: recognise commission on every
-- policy whose insurer item this settlement has just paid in full.
create or replace function public.ins_commission_on_settlement_posted()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r          record;
  v_unearned uuid;
  v_income   uuid;
  v_ev       uuid;
  v_je       journal_entries;
begin
  if new.direction <> 'out' or new.status <> 'posted' or new.journal_entry_id is null then
    return new;
  end if;

  for r in
    select e.id as entry_id, e.amount, p.policy_no
    from fin_allocations al
    join fin_open_items i  on i.id = al.open_item_id and i.source_type = 'ins_policy_insurer'
    join ins_commission_entries e on e.policy_id = i.source_id and e.tenant_id = i.tenant_id
    join ins_policies p on p.id = e.policy_id
    where al.settlement_id = new.id
      and e.status = 'deferred'
      and ins_item_paid_amount(i.id) >= i.amount
    order by p.policy_no
    for update of e
  loop
    v_unearned := get_posting_account(new.tenant_id, 'unearned_commission');
    v_income   := get_posting_account(new.tenant_id, 'commission_income');
    if v_unearned is null or v_income is null then
      raise exception 'INS_POSTING_RULE_MISSING: paying the insurer for % earns commission, which needs the unearned_commission and commission_income posting rules', r.policy_no;
    end if;

    v_ev := gen_random_uuid();
    v_je := post_journal_entry(new.tenant_id, 'ins_commission_recognition', v_ev, new.settlement_date,
      'Commission earned on ' || r.policy_no,
      jsonb_build_array(
        jsonb_build_object('gl_account_id', v_unearned, 'debit',  r.amount, 'description', 'Commission earned on ' || r.policy_no),
        jsonb_build_object('gl_account_id', v_income,   'credit', r.amount, 'description', 'Commission earned on ' || r.policy_no)));

    insert into ins_commission_events (id, tenant_id, entry_id, event, amount, journal_entry_id, settlement_id)
    values (v_ev, new.tenant_id, r.entry_id, 'recognised', r.amount, v_je.id, new.id);

    update ins_commission_entries
       set status = 'earned', earned_on = new.settlement_date, updated_at = now()
     where id = r.entry_id;
  end loop;

  return new;
end;
$$;

revoke all on function public.ins_commission_on_settlement_posted() from public, anon, authenticated;

drop trigger if exists trg_ins_commission_on_settlement_posted on public.fin_settlements;
create trigger trg_ins_commission_on_settlement_posted
  after update of journal_entry_id on public.fin_settlements
  for each row
  when (old.journal_entry_id is null and new.journal_entry_id is not null)
  execute function public.ins_commission_on_settlement_posted();

-- AFTER a settlement is voided: where that leaves an insurer item unpaid, the
-- commission is no longer earned. Refuse if it has already been transferred out.
create or replace function public.ins_commission_on_settlement_voided()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r          record;
  v_unearned uuid;
  v_income   uuid;
  v_ev       uuid;
  v_je       journal_entries;
  v_date     date;
begin
  if new.direction <> 'out' or old.status <> 'posted' or new.status <> 'void' then
    return new;
  end if;

  select entry_date into v_date from journal_entries where id = new.void_journal_entry_id;
  v_date := coalesce(v_date, current_date);

  for r in
    select e.id as entry_id, e.amount, e.status as entry_status, p.policy_no
    from fin_allocations al
    join fin_open_items i  on i.id = al.open_item_id and i.source_type = 'ins_policy_insurer'
    join ins_commission_entries e on e.policy_id = i.source_id and e.tenant_id = i.tenant_id
    join ins_policies p on p.id = e.policy_id
    where al.settlement_id = new.id
      and e.status in ('earned', 'transferred')
      and ins_item_paid_amount(i.id) < i.amount
    order by p.policy_no
    for update of e
  loop
    if r.entry_status = 'transferred' then
      raise exception 'INS_COMMISSION_TRANSFERRED: commission on % has already been transferred to the operating account; void that commission transfer first', r.policy_no;
    end if;

    v_unearned := get_posting_account(new.tenant_id, 'unearned_commission');
    v_income   := get_posting_account(new.tenant_id, 'commission_income');
    if v_unearned is null or v_income is null then
      raise exception 'INS_POSTING_RULE_MISSING: reversing commission on % needs the unearned_commission and commission_income posting rules', r.policy_no;
    end if;

    v_ev := gen_random_uuid();
    v_je := post_journal_entry(new.tenant_id, 'ins_commission_recognition_reversal', v_ev, v_date,
      'Commission no longer earned on ' || r.policy_no || ' (settlement voided)',
      jsonb_build_array(
        jsonb_build_object('gl_account_id', v_income,   'debit',  r.amount, 'description', 'Reversal of commission earned on ' || r.policy_no),
        jsonb_build_object('gl_account_id', v_unearned, 'credit', r.amount, 'description', 'Reversal of commission earned on ' || r.policy_no)));

    insert into ins_commission_events (id, tenant_id, entry_id, event, amount, journal_entry_id, settlement_id)
    values (v_ev, new.tenant_id, r.entry_id, 'recognition_reversed', r.amount, v_je.id, new.id);

    update ins_commission_entries
       set status = 'deferred', earned_on = null, updated_at = now()
     where id = r.entry_id;
  end loop;

  return new;
end;
$$;

revoke all on function public.ins_commission_on_settlement_voided() from public, anon, authenticated;

drop trigger if exists trg_ins_commission_on_settlement_voided on public.fin_settlements;
create trigger trg_ins_commission_on_settlement_voided
  after update of status on public.fin_settlements
  for each row
  when (old.status = 'posted' and new.status = 'void')
  execute function public.ins_commission_on_settlement_voided();

-- =====================================================================
-- 6. Transfer of earned commission out of client money
-- =====================================================================
create or replace function public.ins_transfer_earned_commission(
  p_from_bank_account_id uuid,
  p_to_bank_account_id   uuid,
  p_transfer_date        date,
  p_entry_ids            uuid[] default null,
  p_notes                text default null
)
returns public.ins_commission_transfers
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant   uuid := get_my_tenant_id();
  v_from     fin_bank_accounts%rowtype;
  v_to       fin_bank_accounts%rowtype;
  v_ids      uuid[];
  v_total    numeric(18,2);
  v_max_date date;
  v_trust    numeric;
  v_id       uuid := gen_random_uuid();
  v_no       text;
  v_je       journal_entries;
  v_tr       ins_commission_transfers%rowtype;
  v_desc     text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can transfer commission' using errcode = '42501';
  end if;
  if v_tenant is null then
    raise exception 'INS_FORBIDDEN: no company context' using errcode = '42501';
  end if;
  if p_transfer_date is null or p_transfer_date > current_date + 1 then
    raise exception 'INS_TRANSFER_INPUT: the transfer date is required and cannot be in the future';
  end if;
  if p_from_bank_account_id is null or p_to_bank_account_id is null
     or p_from_bank_account_id = p_to_bank_account_id then
    raise exception 'INS_TRANSFER_INPUT: choose a client-money bank account and a different operating bank account';
  end if;

  select * into v_from from fin_bank_accounts where id = p_from_bank_account_id and tenant_id = v_tenant for share;
  select * into v_to   from fin_bank_accounts where id = p_to_bank_account_id   and tenant_id = v_tenant for share;
  if v_from.id is null or v_to.id is null then
    raise exception 'INS_TRANSFER_BANK: bank account not found in this company';
  end if;
  if v_from.kind <> 'client_money' or v_to.kind <> 'operating' then
    raise exception 'INS_TRANSFER_BANK: commission moves from a client-money account to an operating account';
  end if;
  if not v_from.is_active or not v_to.is_active then
    raise exception 'INS_TRANSFER_BANK: both bank accounts must be active';
  end if;
  if v_from.gl_account_id is null or v_to.gl_account_id is null or v_from.gl_account_id = v_to.gl_account_id then
    raise exception 'INS_TRANSFER_BANK: each bank account needs its own mapped GL account';
  end if;
  if v_from.currency <> fin_ledger_currency(v_tenant) or v_to.currency <> fin_ledger_currency(v_tenant) then
    raise exception 'INS_TRANSFER_BANK: only % bank accounts are supported until multi-currency is designed',
      fin_ledger_currency(v_tenant);
  end if;

  select array_agg(e.id order by e.id), sum(e.amount), max(e.earned_on)
    into v_ids, v_total, v_max_date
    from ins_commission_entries e
   where e.tenant_id = v_tenant and e.status = 'earned'
     and (p_entry_ids is null or e.id = any (p_entry_ids));
  if v_ids is null then
    raise exception 'INS_TRANSFER_NOTHING: there is no earned commission to transfer';
  end if;
  if p_entry_ids is not null and cardinality(v_ids) <> cardinality(
       (select array_agg(distinct x) from unnest(p_entry_ids) x)) then
    raise exception 'INS_TRANSFER_ENTRIES: every selected entry must be earned and not yet transferred';
  end if;
  perform 1 from ins_commission_entries where id = any (v_ids) order by id for update;

  if p_transfer_date < v_max_date then
    raise exception 'INS_TRANSFER_DATE: the transfer date cannot be before commission was earned (%)', v_max_date;
  end if;

  select coalesce(sum(l.debit - l.credit), 0) into v_trust
    from journal_entry_lines l
   where l.tenant_id = v_tenant and l.gl_account_id = v_from.gl_account_id;
  if v_trust < v_total then
    raise exception 'INS_TRANSFER_TRUST_SHORT: client-money account % holds % in the ledger, less than the % to transfer',
      v_from.name, v_trust, v_total;
  end if;

  v_no   := next_doc_number(v_tenant, 'ins_commission_transfer', 'CTR');
  v_desc := 'Commission transfer ' || v_no;

  v_je := post_journal_entry(v_tenant, 'ins_commission_transfer', v_id, p_transfer_date, v_desc,
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_to.gl_account_id,   'debit',  v_total, 'description', v_desc),
      jsonb_build_object('gl_account_id', v_from.gl_account_id, 'credit', v_total, 'description', v_desc)));

  insert into ins_commission_transfers (
    id, tenant_id, transfer_no, from_bank_account_id, to_bank_account_id,
    transfer_date, amount, currency, notes, journal_entry_id
  ) values (
    v_id, v_tenant, v_no, v_from.id, v_to.id,
    p_transfer_date, v_total, v_from.currency, nullif(btrim(p_notes), ''), v_je.id
  ) returning * into v_tr;

  update ins_commission_entries
     set status = 'transferred', transfer_id = v_id, updated_at = now()
   where id = any (v_ids);

  insert into ins_commission_events (tenant_id, entry_id, event, amount, journal_entry_id, transfer_id)
  select v_tenant, e.id, 'transferred', e.amount, v_je.id, v_id
    from ins_commission_entries e where e.id = any (v_ids);

  return v_tr;
end;
$$;

create or replace function public.ins_void_commission_transfer(
  p_transfer_id uuid,
  p_reason      text,
  p_void_date   date default current_date
)
returns public.ins_commission_transfers
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_tr     ins_commission_transfers%rowtype;
  v_lines  jsonb;
  v_je     journal_entries;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can void a commission transfer' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_TRANSFER_VOID: a reason of at least 5 characters is required';
  end if;

  select * into v_tr from ins_commission_transfers where id = p_transfer_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_TRANSFER_VOID: transfer not found in this company'; end if;
  if v_tr.status <> 'posted' then raise exception 'INS_TRANSFER_VOID: transfer % is already void', v_tr.transfer_no; end if;
  if p_void_date is null or p_void_date < v_tr.transfer_date or p_void_date > current_date + 1 then
    raise exception 'INS_TRANSFER_VOID: the void date must be between the transfer date and today';
  end if;

  select jsonb_agg(jsonb_build_object(
           'gl_account_id', l.gl_account_id, 'debit', l.credit, 'credit', l.debit,
           'description', 'Reversal of ' || v_tr.transfer_no))
    into v_lines
    from journal_entry_lines l where l.journal_entry_id = v_tr.journal_entry_id;

  v_je := post_journal_entry(v_tenant, 'ins_commission_transfer_void', v_tr.id, p_void_date,
    'Void of commission transfer ' || v_tr.transfer_no || ': ' || btrim(p_reason), v_lines);

  insert into ins_commission_events (tenant_id, entry_id, event, amount, journal_entry_id, transfer_id)
  select v_tenant, e.id, 'transfer_voided', e.amount, v_je.id, v_tr.id
    from ins_commission_entries e where e.transfer_id = v_tr.id and e.tenant_id = v_tenant;

  update ins_commission_entries
     set status = 'earned', transfer_id = null, updated_at = now()
   where transfer_id = v_tr.id and tenant_id = v_tenant;

  update ins_commission_transfers
     set status = 'void', void_journal_entry_id = v_je.id, voided_at = now(),
         voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = v_tr.id
   returning * into v_tr;

  return v_tr;
end;
$$;

revoke all on function public.ins_transfer_earned_commission(uuid, uuid, date, uuid[], text) from public, anon;
revoke all on function public.ins_void_commission_transfer(uuid, text, date) from public, anon;
grant execute on function public.ins_transfer_earned_commission(uuid, uuid, date, uuid[], text) to authenticated;
grant execute on function public.ins_void_commission_transfer(uuid, text, date) to authenticated;

-- =====================================================================
-- 7. Read views (the caller's RLS applies)
-- =====================================================================
create or replace view public.ins_commission_ledger
with (security_invoker = true) as
select e.id, e.tenant_id, e.policy_id, p.policy_no, p.insurer_id, p.client_id,
       e.amount, e.status, e.earned_on, e.transfer_id, t.transfer_no, t.transfer_date,
       e.created_at, e.updated_at
from public.ins_commission_entries e
join public.ins_policies p on p.id = e.policy_id
left join public.ins_commission_transfers t on t.id = e.transfer_id;

create or replace view public.ins_commission_position
with (security_invoker = true) as
select tenant_id,
       coalesce(sum(amount) filter (where status = 'deferred'), 0)    as unearned_amount,
       coalesce(sum(amount) filter (where status = 'earned'), 0)      as earned_in_client_money,
       coalesce(sum(amount) filter (where status = 'transferred'), 0) as transferred_amount
from public.ins_commission_entries
group by tenant_id;

revoke all on public.ins_commission_ledger, public.ins_commission_position from anon, authenticated, public;
grant select on public.ins_commission_ledger, public.ins_commission_position to authenticated;

select public.apply_tenant_read_only_guard();