-- Insurance Brokerage: claim payments, in two modes chosen per insurer.
--
-- Decisions (confirmed 2026-10-13)
--   * Insurer-direct is the default. The insurer pays the client; the brokerage
--     never holds the money. The broker records the payment as evidence (amount,
--     date, insurer reference). Nothing is posted to the ledger.
--   * Brokerage-managed is the alternative, set per insurer. The insurer pays
--     the brokerage, the brokerage pays the client, both through a client-money
--     bank account, and both legs are posted and can be reconciled to the bank.
--   * The mode is copied onto the claim when it is approved, so changing an
--     insurer's setting never changes a claim already in flight.
--
-- What this migration does
--   1. Two posting roles (21 in total): insurer_claim_receivable (asset, 1120)
--      and client_claim_payable (liability, 2030). The insurance template gains
--      both accounts and rules; existing insurance tenants are backfilled.
--   2. Open items may carry the two new roles. Credit notes are NOT extended:
--      a claim item cannot take a credit note.
--   3. ins_insurers.claim_payment_mode and ins_claims.payment_mode. Claims that
--      were already approved, settled or closed are backfilled to insurer_direct.
--   4. ins_claim_payments: one row per recorded payment or receipt. Written by
--      the RPCs only.
--   5. ins_transition_claim: approving a brokerage-managed claim posts
--      Dr insurer_claim_receivable / Cr client_claim_payable and opens one item on
--      each side. "settled" can no longer be set by hand; it follows the payments.
--   6. ins_record_claim_payment (insurer-direct), ins_record_claim_receipt and
--      ins_record_claim_payout (brokerage-managed), ins_void_claim_payment.
--   7. The settlement engine accepts the new roles on client-money accounts, and
--      only when called from the claim RPCs, so Finance cannot settle a claim
--      item from the generic screen and skip the controls.
--   8. Control: the brokerage cannot pay a client more than it has received from
--      the insurer for that claim. Voiding a receipt that has been paid out is
--      refused.
--   9. View ins_claim_cash_position.
--
-- Not covered (deliberately)
--   * Un-approving a brokerage-managed claim. Approval posts the accrual; there
--     is no reversal yet, so a wrong approval needs a manual journal.
--   * Insurer payments to a client for part of a claim are supported (partial
--     payments), but there is no overpayment or recovery handling.
--   * Claim receipts and payouts are matched to the bank in D4d like any other
--     settlement. Insurer-direct payments never reach a bank statement.
--
-- Re-runnable: create or replace, if not exists, on conflict do nothing.

-- =====================================================================
-- 1. Posting roles
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
    'unearned_commission',
    'insurer_claim_receivable', 'client_claim_payable'
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
    'unearned_commission',
    'insurer_claim_receivable', 'client_claim_payable'
  ]::text[];
$$;

revoke all on function public.platform_gl_posting_roles() from public, anon;
grant execute on function public.platform_gl_posting_roles() to authenticated;

insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
select 'insurance', v.kind, v.sort_order, v.name, v.payload
from (values
  ('gl_account', 20, '1120',
     '{"name": "Claims Receivable from Insurers", "account_type": "asset", "is_control_account": true}'::jsonb),
  ('gl_account', 21, '2030',
     '{"name": "Claims Payable to Clients", "account_type": "liability", "is_control_account": true}'::jsonb),
  ('posting_rule', 20, 'insurer_claim_receivable', '{"account_code": "1120"}'::jsonb),
  ('posting_rule', 21, 'client_claim_payable', '{"account_code": "2030"}'::jsonb)
) as v(kind, sort_order, name, payload)
where exists (select 1 from public.industry_templates t where t.key = 'insurance')
on conflict (template_key, kind, name) do nothing;

-- Existing insurance tenants: add each account and rule. If the code is already
-- used for something else, leave the tenant alone; approving a brokerage-managed
-- claim then stops with INS_POSTING_RULE_MISSING and says what to map.
do $$
declare
  t    record;
  s    record;
  v_gl uuid;
begin
  for s in
    select * from (values
      ('insurer_claim_receivable', '1120', 'Claims Receivable from Insurers', 'asset',     '%claims receivable%'),
      ('client_claim_payable',     '2030', 'Claims Payable to Clients',       'liability', '%claims payable%')
    ) as x(role, code, name, account_type, name_pattern)
  loop
    for t in
      select distinct r.tenant_id
      from public.gl_posting_rules r
      where r.account_role = 'insurer_payable'
        and not exists (
          select 1 from public.gl_posting_rules x
          where x.tenant_id = r.tenant_id and x.account_role = s.role)
    loop
      select id into v_gl from public.gl_accounts
       where tenant_id = t.tenant_id and account_code = s.code;
      if v_gl is null then
        insert into public.gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
        values (t.tenant_id, s.code, s.name, s.account_type, true)
        returning id into v_gl;
      elsif not exists (
        select 1 from public.gl_accounts
         where id = v_gl and account_type = s.account_type and is_active
           and name ilike s.name_pattern
      ) then
        raise notice 'ins_claim_payments: tenant % already uses account code % for something else; map % by hand', t.tenant_id, s.code, s.role;
        continue;
      end if;
      insert into public.gl_posting_rules (tenant_id, account_role, gl_account_id)
      values (t.tenant_id, s.role, v_gl)
      on conflict (tenant_id, account_role) do nothing;
    end loop;
  end loop;
end
$$;

-- =====================================================================
-- 2. Journal source type and open-item roles
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
    'ins_commission_transfer', 'ins_commission_transfer_void',
    'ins_claim_accrual'
  ]));

alter table public.fin_open_items drop constraint if exists fin_open_items_role_check;
alter table public.fin_open_items add constraint fin_open_items_role_check
  check (control_role in (
    'ar_control', 'commission_receivable', 'ap_control', 'insurer_payable',
    'insurer_claim_receivable', 'client_claim_payable'));

alter table public.fin_open_items drop constraint if exists fin_open_items_side_role_check;
alter table public.fin_open_items add constraint fin_open_items_side_role_check
  check (
    (side = 'receivable' and control_role in ('ar_control', 'commission_receivable', 'insurer_claim_receivable'))
    or (side = 'payable' and control_role in ('ap_control', 'insurer_payable', 'client_claim_payable'))
  );

-- =====================================================================
-- 3. Settings and claim columns
-- =====================================================================
alter table public.ins_insurers
  add column if not exists claim_payment_mode text not null default 'insurer_direct';
alter table public.ins_insurers drop constraint if exists ins_insurers_claim_payment_mode_check;
alter table public.ins_insurers add constraint ins_insurers_claim_payment_mode_check
  check (claim_payment_mode in ('insurer_direct', 'via_broker'));

alter table public.ins_claims add column if not exists payment_mode text;
alter table public.ins_claims drop constraint if exists ins_claims_payment_mode_check;
alter table public.ins_claims add constraint ins_claims_payment_mode_check
  check (payment_mode is null or payment_mode in ('insurer_direct', 'via_broker'));

-- Claims approved before this migration were paid outside the system. Treat them
-- as insurer-direct so an approved claim can still record its payments.
do $$
begin
  perform set_config('ins.via_rpc', 'on', true);
  update public.ins_claims
     set payment_mode = 'insurer_direct'
   where payment_mode is null
     and approved_amount is not null;
end
$$;

-- payment_mode is set by ins_transition_claim only.
create or replace function public.ins_claims_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if not public.ins_via_rpc() then
      raise exception 'INS_RPC_ONLY: create claims with ins_create_claim()' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.claim_no is distinct from old.claim_no or new.policy_id is distinct from old.policy_id then
    raise exception 'INS_IMMUTABLE: a claim number and its policy cannot be changed';
  end if;
  if not public.ins_via_rpc() and (
    new.status is distinct from old.status
    or new.approved_amount is distinct from old.approved_amount
    or new.paid_amount is distinct from old.paid_amount
    or new.settled_at is distinct from old.settled_at
    or new.payment_mode is distinct from old.payment_mode
  ) then
    raise exception 'INS_CLAIM_RPC_ONLY: status, amounts and payment mode change through the claim functions' using errcode = '42501';
  end if;

  if new.loss_date is distinct from old.loss_date and not exists (
    select 1 from ins_policies p
     where p.id = new.policy_id and p.tenant_id = new.tenant_id
       and new.loss_date between p.inception_date and p.expiry_date
  ) then
    raise exception 'INS_LOSS_OUTSIDE_POLICY: loss date % is outside the policy period', new.loss_date;
  end if;
  return new;
end;
$$;

-- =====================================================================
-- 4. Payments table
-- =====================================================================
create table if not exists public.ins_claim_payments (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  claim_id      uuid not null,
  kind          text not null,
  amount        numeric(18,2) not null,
  payment_date  date not null,
  reference     text,
  notes         text,
  settlement_id uuid,
  status        text not null default 'posted',
  voided_at     timestamptz,
  voided_by     uuid,
  void_reason   text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  constraint ins_claim_payments_tenant_id_id_key unique (tenant_id, id),
  constraint ins_claim_payments_claim_fk foreign key (tenant_id, claim_id)
    references public.ins_claims (tenant_id, id) on delete restrict,
  constraint ins_claim_payments_settlement_fk foreign key (tenant_id, settlement_id)
    references public.fin_settlements (tenant_id, id) on delete restrict,
  constraint ins_claim_payments_kind_check check (kind in ('insurer_direct', 'insurer_receipt', 'client_payout')),
  constraint ins_claim_payments_amount_check check (amount > 0),
  constraint ins_claim_payments_status_check check (status in ('posted', 'void')),
  constraint ins_claim_payments_settlement_kind_check check ((kind = 'insurer_direct') = (settlement_id is null)),
  constraint ins_claim_payments_void_check check (
    (status = 'posted' and voided_at is null and void_reason is null)
    or (status = 'void' and voided_at is not null and void_reason is not null)
  )
);

create unique index if not exists ins_claim_payments_settlement_key
  on public.ins_claim_payments (settlement_id) where settlement_id is not null;
create index if not exists ins_claim_payments_claim_idx on public.ins_claim_payments (claim_id, created_at);

alter table public.ins_claim_payments enable row level security;

drop policy if exists ins_claim_payments_select on public.ins_claim_payments;
create policy ins_claim_payments_select on public.ins_claim_payments
  for select to authenticated using (tenant_id = get_my_tenant_id() and can_access_insurance());

revoke all on public.ins_claim_payments from anon, authenticated, public;
grant select on public.ins_claim_payments to authenticated;

-- fin_create_open_item derives the side from the role, so it needs the new
-- receivable role too.
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
    case when p_control_role in ('ar_control', 'commission_receivable', 'insurer_claim_receivable') then 'receivable' else 'payable' end,
    p_control_role, p_source_type, p_source_id,
    p_document_no, p_document_date, p_due_date, fin_ledger_currency(p_tenant_id), p_amount, p_description
  )
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.fin_create_open_item(uuid, uuid, text, text, uuid, text, date, date, numeric, text)
  from public, anon, authenticated;

-- =====================================================================
-- 5. Settlement engine: accept the claim roles, from the claim RPCs only
-- =====================================================================
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
    when v_bank.kind = 'client_money' and p_direction = 'in'  then array['ar_control', 'insurer_claim_receivable']
    when v_bank.kind = 'client_money'                         then array['insurer_payable', 'client_claim_payable']
    when p_direction = 'in'                                   then array['ar_control', 'commission_receivable']
    else array['ap_control'] end;

  for v_item in
    select * from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids) order by id for update
  loop
    if v_item.control_role <> all (v_allowed) then
      raise exception 'SETTLEMENT_ROLE_NOT_ALLOWED: a % bank account taking money % cannot settle % items (%)',
        replace(v_bank.kind, '_', ' '), p_direction, v_item.control_role, v_item.document_no;
    end if;
    if v_item.control_role in ('insurer_claim_receivable', 'client_claim_payable') and not public.ins_via_rpc() then
      raise exception 'SETTLEMENT_ROLE_NOT_ALLOWED: claim item % is settled from the claim in the Insurance module', v_item.document_no;
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

-- =====================================================================
-- 6. Internal helper: recompute what has been paid and move the claim
-- =====================================================================
create or replace function public.ins_claim_apply_payment_totals(p_claim_id uuid, p_note text)
returns public.ins_claims
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_claim ins_claims%rowtype;
  v_paid  numeric;
  v_from  text;
begin
  select * into v_claim from ins_claims where id = p_claim_id for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  select coalesce(sum(amount), 0) into v_paid
    from ins_claim_payments
   where claim_id = p_claim_id and status = 'posted' and kind in ('insurer_direct', 'client_payout');

  perform set_config('ins.via_rpc', 'on', true);
  v_from := v_claim.status;

  if v_claim.status = 'approved' and v_paid >= coalesce(v_claim.approved_amount, 0) then
    update ins_claims set paid_amount = v_paid, status = 'settled', settled_at = now()
     where id = v_claim.id returning * into v_claim;
    insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
    values (v_claim.tenant_id, v_claim.id, v_from, 'settled', p_note);
  elsif v_claim.status = 'settled' and v_paid < coalesce(v_claim.approved_amount, 0) then
    update ins_claims set paid_amount = v_paid, status = 'approved', settled_at = null
     where id = v_claim.id returning * into v_claim;
    insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
    values (v_claim.tenant_id, v_claim.id, v_from, 'approved', p_note);
  else
    update ins_claims set paid_amount = v_paid
     where id = v_claim.id returning * into v_claim;
  end if;
  return v_claim;
end;
$$;

revoke all on function public.ins_claim_apply_payment_totals(uuid, text) from public, anon, authenticated;

-- =====================================================================
-- 7. ins_transition_claim: snapshot the mode, accrue brokerage-managed claims,
--    and stop "settled" being set by hand
-- =====================================================================
create or replace function public.ins_transition_claim(
  p_claim_id uuid,
  p_to       text,
  p_note     text default null,
  p_amount   numeric default null
)
returns public.ins_claims
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant     uuid := get_my_tenant_id();
  v_claim      ins_claims%rowtype;
  v_from       text;
  v_sum        numeric;
  v_insurer    uuid;
  v_client     uuid;
  v_mode       text;
  v_legal      boolean;
  v_recv_gl    uuid;
  v_pay_gl     uuid;
  v_ins_acc    uuid;
  v_cli_acc    uuid;
  v_desc       text;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  v_from := v_claim.status;

  if p_to in ('approved', 'settled', 'repudiated', 'closed') and not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers decide claims' using errcode = '42501';
  end if;

  v_legal := (v_from, p_to) in (
    ('notified', 'assessing'), ('notified', 'repudiated'),
    ('assessing', 'approved'), ('assessing', 'repudiated'),
    ('approved', 'settled'),
    ('settled', 'closed'), ('repudiated', 'closed')
  );
  if not v_legal then
    raise exception 'INS_CLAIM_TRANSITION: a claim cannot move from % to %', v_from, p_to;
  end if;

  if p_to = 'repudiated' and nullif(btrim(p_note), '') is null then
    raise exception 'INS_NOTE_REQUIRED: give the reason for repudiating the claim';
  end if;

  perform set_config('ins.via_rpc', 'on', true);

  if p_to = 'approved' then
    if p_amount is null or p_amount <= 0 then
      raise exception 'INS_AMOUNT: approved amount must be greater than zero';
    end if;
    select p.sum_insured, p.insurer_id, p.client_id into v_sum, v_insurer, v_client
      from ins_policies p where p.id = v_claim.policy_id;
    if v_sum > 0 and p_amount > v_sum then
      raise exception 'INS_AMOUNT: approved amount exceeds the policy sum insured';
    end if;
    select i.claim_payment_mode into v_mode from ins_insurers i where i.id = v_insurer and i.tenant_id = v_tenant;
    v_mode := coalesce(v_mode, 'insurer_direct');

    if v_mode = 'via_broker' then
      v_recv_gl := get_posting_account(v_tenant, 'insurer_claim_receivable');
      v_pay_gl  := get_posting_account(v_tenant, 'client_claim_payable');
      if v_recv_gl is null or v_pay_gl is null then
        raise exception 'INS_POSTING_RULE_MISSING: this insurer pays claims through the brokerage, so the chart of accounts needs insurer_claim_receivable and client_claim_payable';
      end if;
    end if;

    update ins_claims set status = 'approved', approved_amount = p_amount, payment_mode = v_mode
     where id = v_claim.id returning * into v_claim;

    if v_mode = 'via_broker' then
      v_ins_acc := ins_ensure_insurer_account(v_insurer);
      v_cli_acc := ins_ensure_client_account(v_client);
      v_desc := 'Claim ' || v_claim.claim_no || ' approved: paid through the brokerage';
      perform post_journal_entry(v_tenant, 'ins_claim_accrual', v_claim.id, current_date, v_desc, jsonb_build_array(
        jsonb_build_object('gl_account_id', v_recv_gl, 'debit',  p_amount, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_pay_gl,  'credit', p_amount, 'description', v_desc)));
      perform fin_create_open_item(v_tenant, v_ins_acc, 'insurer_claim_receivable', 'ins_claim_insurer', v_claim.id,
        v_claim.claim_no, current_date, current_date, p_amount, 'Claim funds due from the insurer');
      perform fin_create_open_item(v_tenant, v_cli_acc, 'client_claim_payable', 'ins_claim_client', v_claim.id,
        v_claim.claim_no, current_date, current_date, p_amount, 'Claim proceeds due to the client');
    end if;
  elsif p_to = 'settled' then
    if v_claim.paid_amount < coalesce(v_claim.approved_amount, 0) then
      raise exception 'INS_CLAIM_PAYMENT_REQUIRED: a claim settles when its payments cover the approved amount; record the payments instead';
    end if;
    update ins_claims set status = 'settled', settled_at = coalesce(settled_at, now())
     where id = v_claim.id returning * into v_claim;
  else
    update ins_claims set status = p_to
     where id = v_claim.id returning * into v_claim;
  end if;

  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_tenant, v_claim.id, v_from, p_to, nullif(btrim(p_note), ''));
  return v_claim;
end;
$$;

-- =====================================================================
-- 8. Insurer-direct: record that the insurer paid the client
-- =====================================================================
create or replace function public.ins_record_claim_payment(
  p_claim_id     uuid,
  p_amount       numeric,
  p_payment_date date,
  p_reference    text,
  p_notes        text default null
)
returns public.ins_claim_payments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_pay    ins_claim_payments%rowtype;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers record claim payments' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_NOT_FOUND: claim'; end if;
  if v_claim.status <> 'approved' then
    raise exception 'INS_CLAIM_STATE: payments are recorded on an approved claim (this one is %)', v_claim.status;
  end if;
  if v_claim.payment_mode <> 'insurer_direct' then
    raise exception 'INS_CLAIM_MODE: this claim is paid through the brokerage; record the insurer receipt and the client payout instead';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_AMOUNT: the payment amount must be greater than zero';
  end if;
  if p_amount > v_claim.approved_amount - v_claim.paid_amount then
    raise exception 'INS_AMOUNT: only % is still unpaid on this claim', v_claim.approved_amount - v_claim.paid_amount;
  end if;
  if p_payment_date is null or p_payment_date > current_date or p_payment_date < v_claim.notified_date then
    raise exception 'INS_DATE: the payment date must be between the notified date and today';
  end if;
  if nullif(btrim(p_reference), '') is null then
    raise exception 'INS_REFERENCE_REQUIRED: give the insurer payment reference, because nothing else in the system evidences this payment';
  end if;

  insert into ins_claim_payments (tenant_id, claim_id, kind, amount, payment_date, reference, notes)
  values (v_tenant, v_claim.id, 'insurer_direct', p_amount, p_payment_date, btrim(p_reference), nullif(btrim(p_notes), ''))
  returning * into v_pay;

  perform ins_claim_apply_payment_totals(v_claim.id, 'Paid in full by the insurer');
  return v_pay;
end;
$$;

-- =====================================================================
-- 9. Brokerage-managed: receipt from the insurer, payout to the client
-- =====================================================================
create or replace function public.ins_record_claim_receipt(
  p_claim_id        uuid,
  p_bank_account_id uuid,
  p_amount          numeric,
  p_receipt_date    date,
  p_reference       text default null,
  p_notes           text default null
)
returns public.ins_claim_payments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_kind   text;
  v_item   record;
  v_set    fin_settlements%rowtype;
  v_pay    ins_claim_payments%rowtype;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers record claim receipts' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_NOT_FOUND: claim'; end if;
  if v_claim.status <> 'approved' then
    raise exception 'INS_CLAIM_STATE: receipts are recorded on an approved claim (this one is %)', v_claim.status;
  end if;
  if v_claim.payment_mode <> 'via_broker' then
    raise exception 'INS_CLAIM_MODE: this insurer pays the client directly; record the insurer payment instead';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_AMOUNT: the receipt amount must be greater than zero';
  end if;
  select kind into v_kind from fin_bank_accounts where id = p_bank_account_id and tenant_id = v_tenant;
  if v_kind is distinct from 'client_money' then
    raise exception 'INS_BANK_KIND: claim money is received into a client-money bank account';
  end if;

  select b.id, b.party_account_id, b.outstanding_amount into v_item
    from fin_open_item_balances b
   where b.tenant_id = v_tenant and b.source_type = 'ins_claim_insurer' and b.source_id = v_claim.id;
  if not found then raise exception 'INS_NOT_FOUND: the insurer item for this claim'; end if;
  if p_amount > v_item.outstanding_amount then
    raise exception 'INS_AMOUNT: the insurer still owes only % on this claim', v_item.outstanding_amount;
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  v_set := platform_fin_record_settlement_impl(
    v_tenant, p_bank_account_id, 'in', v_item.party_account_id, p_amount, p_receipt_date,
    jsonb_build_array(jsonb_build_object('open_item_id', v_item.id, 'amount', p_amount)),
    coalesce(nullif(btrim(p_reference), ''), v_claim.claim_no), nullif(btrim(p_notes), ''));

  insert into ins_claim_payments (tenant_id, claim_id, kind, amount, payment_date, reference, notes, settlement_id)
  values (v_tenant, v_claim.id, 'insurer_receipt', p_amount, p_receipt_date, nullif(btrim(p_reference), ''), nullif(btrim(p_notes), ''), v_set.id)
  returning * into v_pay;
  return v_pay;
end;
$$;

create or replace function public.ins_record_claim_payout(
  p_claim_id        uuid,
  p_bank_account_id uuid,
  p_amount          numeric,
  p_payment_date    date,
  p_reference       text default null,
  p_notes           text default null
)
returns public.ins_claim_payments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant   uuid := get_my_tenant_id();
  v_claim    ins_claims%rowtype;
  v_kind     text;
  v_item     record;
  v_held     numeric;
  v_set      fin_settlements%rowtype;
  v_pay      ins_claim_payments%rowtype;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers pay out claims' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_NOT_FOUND: claim'; end if;
  if v_claim.status <> 'approved' then
    raise exception 'INS_CLAIM_STATE: payouts are made on an approved claim (this one is %)', v_claim.status;
  end if;
  if v_claim.payment_mode <> 'via_broker' then
    raise exception 'INS_CLAIM_MODE: this insurer pays the client directly; there is nothing for the brokerage to pay out';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_AMOUNT: the payout amount must be greater than zero';
  end if;
  select kind into v_kind from fin_bank_accounts where id = p_bank_account_id and tenant_id = v_tenant;
  if v_kind is distinct from 'client_money' then
    raise exception 'INS_BANK_KIND: claim money is paid out of a client-money bank account';
  end if;

  select coalesce(sum(amount) filter (where kind = 'insurer_receipt'), 0)
         - coalesce(sum(amount) filter (where kind = 'client_payout'), 0)
    into v_held
    from ins_claim_payments where claim_id = v_claim.id and status = 'posted';
  if p_amount > v_held then
    raise exception 'INS_CLAIM_FUNDS_NOT_RECEIVED: only % has been received from the insurer and not yet paid out; the brokerage does not pay a client ahead of the insurer', v_held;
  end if;

  select b.id, b.party_account_id, b.outstanding_amount into v_item
    from fin_open_item_balances b
   where b.tenant_id = v_tenant and b.source_type = 'ins_claim_client' and b.source_id = v_claim.id;
  if not found then raise exception 'INS_NOT_FOUND: the client item for this claim'; end if;
  if p_amount > v_item.outstanding_amount then
    raise exception 'INS_AMOUNT: only % is still owed to the client on this claim', v_item.outstanding_amount;
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  v_set := platform_fin_record_settlement_impl(
    v_tenant, p_bank_account_id, 'out', v_item.party_account_id, p_amount, p_payment_date,
    jsonb_build_array(jsonb_build_object('open_item_id', v_item.id, 'amount', p_amount)),
    coalesce(nullif(btrim(p_reference), ''), v_claim.claim_no), nullif(btrim(p_notes), ''));

  insert into ins_claim_payments (tenant_id, claim_id, kind, amount, payment_date, reference, notes, settlement_id)
  values (v_tenant, v_claim.id, 'client_payout', p_amount, p_payment_date, nullif(btrim(p_reference), ''), nullif(btrim(p_notes), ''), v_set.id)
  returning * into v_pay;

  perform ins_claim_apply_payment_totals(v_claim.id, 'Paid in full to the client by the brokerage');
  return v_pay;
end;
$$;

-- =====================================================================
-- 10. Void a payment, receipt or payout
-- =====================================================================
create or replace function public.ins_void_claim_payment(p_payment_id uuid, p_reason text)
returns public.ins_claim_payments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_pay    ins_claim_payments%rowtype;
  v_status text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers void claim payments' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_REASON_REQUIRED: a reason of at least 5 characters is required';
  end if;
  select * into v_pay from ins_claim_payments where id = p_payment_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_NOT_FOUND: payment'; end if;
  if v_pay.status <> 'posted' then raise exception 'INS_ALREADY_VOID: this payment is already void'; end if;
  select status into v_status from ins_claims where id = v_pay.claim_id;
  if v_status = 'closed' then
    raise exception 'INS_CLAIM_CLOSED: payments on a closed claim cannot be voided';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  if v_pay.kind = 'insurer_direct' then
    update ins_claim_payments
       set status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
     where id = v_pay.id returning * into v_pay;
    perform ins_claim_apply_payment_totals(v_pay.claim_id, 'Payment voided: ' || btrim(p_reason));
  else
    -- The settlement void trigger marks this row void and recomputes the claim.
    perform platform_fin_void_settlement_impl(v_tenant, v_pay.settlement_id, btrim(p_reason), current_date);
    select * into v_pay from ins_claim_payments where id = p_payment_id;
  end if;
  return v_pay;
end;
$$;

-- A claim settlement can also be voided from Finance. Keep the claim in step,
-- and refuse to void money the brokerage has already paid on.
create or replace function public.ins_claim_settlement_void_sync()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pay        ins_claim_payments%rowtype;
  v_held_after numeric;
  v_status     text;
begin
  select * into v_pay from ins_claim_payments where settlement_id = new.id and status = 'posted' for update;
  if not found then
    return new;
  end if;
  select status into v_status from ins_claims where id = v_pay.claim_id;
  if v_status = 'closed' then
    raise exception 'INS_CLAIM_CLOSED: payments on a closed claim cannot be voided';
  end if;
  if v_pay.kind = 'insurer_receipt' then
    select coalesce(sum(amount) filter (where kind = 'insurer_receipt'), 0)
           - coalesce(sum(amount) filter (where kind = 'client_payout'), 0)
      into v_held_after
      from ins_claim_payments
     where claim_id = v_pay.claim_id and status = 'posted' and id <> v_pay.id;
    if v_held_after < 0 then
      raise exception 'INS_CLAIM_FUNDS_PAID_OUT: this receipt has already been paid out to the client; void the payout first';
    end if;
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update ins_claim_payments
     set status = 'void', voided_at = now(), voided_by = auth.uid(),
         void_reason = coalesce(new.void_reason, 'Settlement voided')
   where id = v_pay.id;
  perform ins_claim_apply_payment_totals(v_pay.claim_id, 'Payment voided: ' || coalesce(new.void_reason, 'settlement voided'));
  return new;
end;
$$;

drop trigger if exists ins_claim_settlement_void_sync_trg on public.fin_settlements;
create trigger ins_claim_settlement_void_sync_trg
  after update of status on public.fin_settlements
  for each row when (old.status = 'posted' and new.status = 'void')
  execute function public.ins_claim_settlement_void_sync();

-- =====================================================================
-- 11. Read view
-- =====================================================================
create or replace view public.ins_claim_cash_position
with (security_invoker = true) as
select c.id as claim_id, c.tenant_id, c.claim_no, c.status, c.payment_mode, c.approved_amount, c.paid_amount,
       coalesce(sum(p.amount) filter (where p.kind = 'insurer_receipt'), 0) as received_from_insurer,
       coalesce(sum(p.amount) filter (where p.kind = 'client_payout'), 0)   as paid_to_client,
       coalesce(sum(p.amount) filter (where p.kind = 'insurer_direct'), 0)  as paid_by_insurer_direct,
       coalesce(sum(p.amount) filter (where p.kind = 'insurer_receipt'), 0)
         - coalesce(sum(p.amount) filter (where p.kind = 'client_payout'), 0) as held_for_client,
       case when c.payment_mode = 'via_broker'
            then c.approved_amount - coalesce(sum(p.amount) filter (where p.kind = 'insurer_receipt'), 0)
       end as due_from_insurer
from public.ins_claims c
left join public.ins_claim_payments p on p.claim_id = c.id and p.status = 'posted'
where c.approved_amount is not null
group by c.id;

comment on view public.ins_claim_cash_position is
  'Per approved claim: what the insurer has paid direct, what the brokerage has received and paid on, and what it still holds for the client. Runs with the caller''s RLS.';

revoke all on public.ins_claim_cash_position from anon, public;
grant select on public.ins_claim_cash_position to authenticated;

-- =====================================================================
-- 12. Grants
-- =====================================================================
revoke all on function public.ins_transition_claim(uuid, text, text, numeric) from public, anon;
revoke all on function public.ins_record_claim_payment(uuid, numeric, date, text, text) from public, anon;
revoke all on function public.ins_record_claim_receipt(uuid, uuid, numeric, date, text, text) from public, anon;
revoke all on function public.ins_record_claim_payout(uuid, uuid, numeric, date, text, text) from public, anon;
revoke all on function public.ins_void_claim_payment(uuid, text) from public, anon;
revoke all on function public.ins_claim_settlement_void_sync() from public, anon, authenticated;
grant execute on function public.ins_transition_claim(uuid, text, text, numeric) to authenticated;
grant execute on function public.ins_record_claim_payment(uuid, numeric, date, text, text) to authenticated;
grant execute on function public.ins_record_claim_receipt(uuid, uuid, numeric, date, text, text) to authenticated;
grant execute on function public.ins_record_claim_payout(uuid, uuid, numeric, date, text, text) to authenticated;
grant execute on function public.ins_void_claim_payment(uuid, text) to authenticated;

select public.apply_tenant_read_only_guard();
