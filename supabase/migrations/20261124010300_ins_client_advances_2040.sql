-- =====================================================================
-- 2040 Unallocated Client Advances
-- Accountant pack v2, decision 4 (B2)
-- =====================================================================
-- The acceptance criteria in the pack, verbatim:
--
--   "A receipt with no policy creates a 2040 credit and no receivable; binding a
--    policy allocates it and clears 2040; an unallocated advance is visible on the
--    client statement as a liability and is refundable."
--
-- The problem this solves. platform_fin_record_settlement_impl lets a client-money
-- receipt settle only ar_control or insurer_claim_receivable. Premium taken before
-- the policy exists therefore has nowhere to land except a receivable no document
-- supports -- overstating AR and understating liabilities by exactly the advance.
--
-- WHAT IS BUILT, AND WHAT IS NOT (read this before approving B2)
--
--   BUILT   account 2040, the posting role, the advance subledger, taking an
--           advance, refunding it, and the client statement.
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
--   NOT BUILT   releasing an advance to a policy. ins_apply_client_advance exists
--           and deliberately raises: the schema has no way to do it correctly.
--           The reason is set out below and registered as blocking work (B11).
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
--   BUILT (from 20261124010500)   releasing an advance to a policy, once the
--           subledger gained a non-cash movement (fin_open_item_dispositions).
--           The first cut of this migration refused it, correctly, because no such
--           mechanism existed; the reasoning is kept at the end of this header
--           because it explains why the release is posted the way it is.
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
--
-- I did not discover this by assuming: I checked every mechanism against the live
-- guards, and the design that looks obvious does not work.
--
-- Apparent design: "apply the advance to the premium debt". Impossible.
-- fin_credit_applications_guard requires a credit note and the open item it is
-- applied to to have the SAME side and control_role. An advance is a payable on
-- 2040; a premium is a receivable on AR. A credit note cannot move value between
-- two different control accounts, so it cannot settle AR from 2040.
--
-- Apparent design 2: "post a reclass journal Dr 2040 / Cr AR and allocate". A
-- journal alone does not move the subledger: fin_open_item_consumed() counts only
-- fin_allocations (through a posted settlement) and fin_credit_applications
-- (through a posted credit note). A settlement is the only vessel for an
-- allocation, and every settlement names a bank account and posts Dr bank / Cr
-- control -- so using one would move cash that did not move, double-counting the
-- client money bank. subledger_only settlements are not an escape either: they
-- require funding_transaction_id, a real cash_bank_transactions row.
--
-- So the open-item model supports exactly two ways for a party balance to fall:
-- cash (a settlement) or a same-role credit note. Releasing an advance is a
-- CROSS-ROLE reclass, and the model has no source for one. The fix is a schema
-- decision, not a workaround:
--
--   either (a) extend fin_open_item_consumed with a reclass source and add a
--             fin_open_item_reclasses table (a journal + two open items, no bank),
--   or     (b) let a credit note name an offset open item on the other side.
--
-- (a) is the smaller change and keeps every existing invariant. It needs its own
-- signed-off decision because it adds a third consumption source to the subledger
-- -- which is precisely the kind of change the accountant pack exists to gate.
--
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
-- Until then an advance can be taken and refunded but not applied, which still
-- removes the AR overstatement for money taken before a policy exists. Calling
-- ins_apply_client_advance raises INS_ADVANCE_RELEASE_NOT_AVAILABLE rather than
-- posting something that cannot reconcile.
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
-- That was the state at this migration. 20261124010500 supplies the reclass source
-- (fin_open_item_dispositions), so the release in section 7 is now a real posting
-- and the earlier refusal has been replaced. The analysis above is kept because it
-- explains why the release is posted Dr 2040 / Cr AR rather than as a credit note.
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs

-- ---------------------------------------------------------------------
-- 1. Platform reference data: the account and the role
-- ---------------------------------------------------------------------

-- Future tenants. 2040 sits after client_claim_payable (2030): it is the other
-- liability a client balance can sit in.
insert into industry_template_items (id, template_key, kind, sort_order, name, payload)
values
  (gen_random_uuid(), 'insurance', 'gl_account', 36, '2040',
   jsonb_build_object('name', 'Unallocated Client Advances',
                      'account_type', 'liability',
                      'is_control_account', true)),
  (gen_random_uuid(), 'insurance', 'posting_rule', 39, 'client_advance_payable',
   jsonb_build_object('account_code', '2040'))
on conflict (template_key, kind, name) do nothing;

-- platform_gl_posting_roles() is IMMUTABLE and the template validator checks every
-- posting rule against it. Without this, the row added above fails validation.
create or replace function public.platform_gl_posting_roles() returns text[]
    language sql immutable
    set search_path to 'public', 'pg_temp'
    as $$
  select array[
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable',
    'unearned_commission',
    'insurer_claim_receivable', 'client_claim_payable',
    'client_advance_payable',
    'fx_rounding',
    'fx_gain_realised', 'fx_loss_realised',
    'fx_gain_unrealised', 'fx_loss_unrealised'
  ]::text[];
$$;

-- Existing tenants: their chart is a copy of the template, so the template row
-- alone reaches only future tenants. Inserted only where 2040 is free; anchored on
-- the tenant already having 2030 so this cannot add a stray account to a tenant
-- that never ran the insurance template.
insert into gl_accounts (tenant_id, account_code, name, account_type, is_control_account)
select t.tenant_id, '2040', 'Unallocated Client Advances', 'liability', true
  from (select distinct tenant_id from tenant_modules where module = 'insurance') t
 where not exists (select 1 from gl_accounts a
                    where a.tenant_id = t.tenant_id and a.account_code = '2040')
   and exists (select 1 from gl_accounts a
                where a.tenant_id = t.tenant_id and a.account_code = '2030');

insert into gl_posting_rules (tenant_id, account_role, gl_account_id)
select a.tenant_id, 'client_advance_payable', a.id
  from gl_accounts a
 where a.account_code = '2040'
   and a.account_type = 'liability'
   and not exists (select 1 from gl_posting_rules r
                    where r.tenant_id = a.tenant_id and r.account_role = 'client_advance_payable');

-- "No invented account codes": if a tenant cannot be mapped, stop and say which.
-- A tenant with a 2040 of the wrong type, or with no 2030 to anchor on, needs an
-- administrator to decide. Failing here is better than an advance that cannot post.
do $$
declare v_missing text;
begin
  select string_agg(t.tenant_id::text, ', ') into v_missing
    from (select distinct tenant_id from tenant_modules where module = 'insurance') t
   where not exists (select 1 from gl_posting_rules r
                      where r.tenant_id = t.tenant_id and r.account_role = 'client_advance_payable');
  if v_missing is not null then
    raise exception 'INS_ADVANCE_ACCOUNT_MISSING: these insurance tenants have no client_advance_payable rule on a liability account 2040 (%) -- add the account and re-run; this migration will not choose an account for you', v_missing;
  end if;
  raise notice 'PASS: every insurance tenant can post to client_advance_payable (2040)';
end $$;

-- ---------------------------------------------------------------------
-- 2. The control role is legal on open items
-- ---------------------------------------------------------------------
-- fin_open_items_role_check and fin_open_items_side_role_check both enumerate the
-- roles. Widened in one place each so they cannot disagree: an advance is a
-- payable, and the side_role CHECK is what stops it being created on the wrong side.
alter table fin_open_items drop constraint if exists fin_open_items_role_check;
alter table fin_open_items add constraint fin_open_items_role_check
  check (control_role = any (array['ar_control','commission_receivable','ap_control',
                                   'insurer_payable','insurer_claim_receivable',
                                   'client_claim_payable','client_advance_payable']::text[]));

alter table fin_open_items drop constraint if exists fin_open_items_side_role_check;
alter table fin_open_items add constraint fin_open_items_side_role_check
  check ((side = 'receivable' and control_role = any (array['ar_control','commission_receivable','insurer_claim_receivable']::text[]))
      or (side = 'payable'    and control_role = any (array['ap_control','insurer_payable','client_claim_payable','client_advance_payable']::text[])));

-- ---------------------------------------------------------------------
-- 3. The advance subledger
-- ---------------------------------------------------------------------
create table if not exists ins_client_advances (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references tenants(id) on delete cascade,
  client_id          uuid not null references ins_clients(id) on delete restrict,
  receipt_settlement_id uuid not null,
  open_item_id       uuid not null,
  amount             numeric not null check (amount > 0),
  currency           char(3) not null,
  received_on        date not null,
  reference          text,
  notes              text,
  status             text not null default 'unallocated'
                     check (status in ('unallocated','partly_applied','applied','refunded')),
  applied_amount     numeric not null default 0 check (applied_amount >= 0),
  refunded_amount    numeric not null default 0 check (refunded_amount >= 0),
  applied_policy_id  uuid references ins_policies(id),
  applied_at         timestamptz,
  refunded_at        timestamptz,
  journal_entry_id   uuid,
  refund_journal_id  uuid,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  constraint ins_client_advances_not_over check (applied_amount + refunded_amount <= amount),
  constraint ins_client_advances_one_per_item unique (tenant_id, open_item_id),
  constraint ins_client_advances_one_per_receipt unique (tenant_id, receipt_settlement_id)
);

create index if not exists ins_client_advances_client_idx
  on ins_client_advances (tenant_id, client_id, status);
create index if not exists ins_client_advances_policy_idx
  on ins_client_advances (tenant_id, applied_policy_id) where applied_policy_id is not null;

alter table ins_client_advances enable row level security;

drop policy if exists ins_client_advances_read on ins_client_advances;
create policy ins_client_advances_read on ins_client_advances
  for select to authenticated using (tenant_id = get_my_tenant_id());

-- A financial record: written only through the RPCs below.
revoke insert, update, delete on ins_client_advances from authenticated, anon;

comment on table ins_client_advances is
  'Client money received before a policy exists. 2040 must never be posted to without a row here. Written only by ins_record_client_advance / ins_apply_client_advance / ins_refund_client_advance.';

-- ---------------------------------------------------------------------
-- 4. Let a client-money receipt settle an advance item
-- ---------------------------------------------------------------------
-- Recreated whole: the allowed-role case expression sits inside a 220-line function
-- and there is no narrower hook. Only v_allowed changes. Everything else is
-- identical to 20261121150000_ins_app_dates_kampala.sql, so diffing this function
-- against that one should show exactly one changed line.
create or replace function public.platform_fin_record_settlement_impl(
  p_tenant_id uuid, p_bank_account_id uuid, p_direction text, p_party_account_id uuid,
  p_amount numeric, p_settlement_date date, p_allocations jsonb,
  p_reference text default null::text, p_notes text default null::text
) returns fin_settlements
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
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
  v_functional text;
  v_ccy        text;
  v_foreign    boolean;
  v_sr         numeric := 1;
  v_bank_base  numeric;
  v_total_orig numeric := 0;
  v_result     numeric := 0;
  v_fx_line    jsonb;
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

  v_functional := fin_ledger_currency(p_tenant_id);
  v_ccy := v_bank.currency;
  v_foreign := v_ccy <> v_functional;

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

  -- B2 (decision 4): a client-money account may also settle client_advance_payable,
  -- in (taking an advance) and out (refunding one). ins_advance_allocation_guard
  -- restricts both to an advance that this module registered.
  v_allowed := case
    when v_bank.kind = 'client_money' and p_direction = 'in'  then array['ar_control', 'insurer_claim_receivable', 'client_advance_payable']
    when v_bank.kind = 'client_money'                         then array['insurer_payable', 'client_claim_payable', 'client_advance_payable']
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
    if v_item.currency <> v_ccy then
      raise exception 'SETTLEMENT_CURRENCY: item % is in %, but bank account % is in %',
        v_item.document_no, v_item.currency, v_bank.name, v_ccy;
    end if;
    if v_foreign and v_item.journal_entry_id is null then
      raise exception 'SETTLEMENT_ITEM_RATE: item % has no booking entry, so its rate is unknown', v_item.document_no;
    end if;
  end loop;
  if (select count(*) from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids)) <> cardinality(v_ids) then
    raise exception 'ALLOCATION_ITEM: an open item was not found in this company';
  end if;

  v_no := next_doc_number(p_tenant_id, 'fin_settlement', 'STL');
  v_desc := case p_direction when 'in' then 'Receipt ' else 'Payment ' end || v_no;

  if p_direction = 'in' then
    v_lines := v_lines || (jsonb_build_object('gl_account_id', v_bank.gl_account_id, 'debit', p_amount, 'description', v_desc)
                       || case when v_foreign then jsonb_build_object('currency', v_ccy) else '{}'::jsonb end);
  end if;

  if not v_foreign then
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
  else
    for v_role in
      select i.control_role, i.journal_entry_id, i.fx_rate, sum((e ->> 'amount')::numeric) as amt
      from jsonb_array_elements(p_allocations) e
      join fin_open_items i on i.id = (e ->> 'open_item_id')::uuid and i.tenant_id = p_tenant_id
      group by i.control_role, i.journal_entry_id, i.fx_rate
      order by i.control_role, i.journal_entry_id
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
        'currency', v_ccy,
        'rate_from_entry', v_role.journal_entry_id,
        'fx_rate', v_role.fx_rate,
        'description', v_desc);
      v_total_orig := v_total_orig + round(v_role.amt * v_role.fx_rate, 2);
    end loop;
  end if;

  if p_direction = 'out' then
    v_lines := v_lines || (jsonb_build_object('gl_account_id', v_bank.gl_account_id, 'credit', p_amount, 'description', v_desc)
                       || case when v_foreign then jsonb_build_object('currency', v_ccy) else '{}'::jsonb end);
  end if;

  if v_foreign then
    v_sr := round((platform_fx_rate(p_tenant_id, v_ccy, p_settlement_date)).rate, 8);
    v_bank_base := round(p_amount * v_sr, 2);
    v_result := case p_direction when 'out' then v_total_orig - v_bank_base else v_bank_base - v_total_orig end;
    v_fx_line := platform_fx_realised_line(p_tenant_id, v_result, 'Realised exchange result on ' || v_no);
    if v_fx_line is not null then
      v_lines := v_lines || v_fx_line;
    end if;
  end if;

  insert into fin_settlements (
    tenant_id, settlement_no, direction, bank_account_id, party_account_id,
    amount, currency, settlement_date, reference, notes, fx_rate, realised_result
  ) values (
    p_tenant_id, v_no, p_direction, p_bank_account_id, p_party_account_id,
    p_amount, v_bank.currency, p_settlement_date, nullif(btrim(p_reference), ''), nullif(btrim(p_notes), ''),
    v_sr, v_result
  )
  returning * into v_set;

  for v_elem in select * from jsonb_array_elements(p_allocations) loop
    insert into fin_allocations (tenant_id, settlement_id, open_item_id, amount)
    values (p_tenant_id, v_set.id, (v_elem ->> 'open_item_id')::uuid, (v_elem ->> 'amount')::numeric);
  end loop;

  return v_set;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. A guard the advance really needs: nothing else may settle it
-- ---------------------------------------------------------------------
-- The settlement path is not the only way an allocation is written -- claim and
-- cancellation flows write their own. Unless an allocation against an advance item
-- comes from this module's receipt or refund path, refuse it. Without this an
-- advance could be consumed by a generic settlement and 2040 would clear with no
-- advance row to explain it.
create or replace function public.ins_advance_allocation_guard() returns trigger
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare v_item fin_open_items%rowtype;
begin
  select * into v_item from fin_open_items
   where id = new.open_item_id and tenant_id = new.tenant_id;
  if not found then return new; end if;
  if v_item.control_role is distinct from 'client_advance_payable' then return new; end if;

  -- Authorised when the allocation settles exactly the advance item of a live
  -- advance row, in the same company, through the receipt RPC (in) or the refund
  -- RPC (out). The receipt creates the advance row after the money lands, so the
  -- check accepts the creating transaction for an 'in' settlement with no row yet.
  if exists (
    select 1 from fin_settlements s
     where s.id = new.settlement_id and s.tenant_id = new.tenant_id
       and s.direction = 'out'
       and exists (select 1 from ins_client_advances a
                    where a.tenant_id = new.tenant_id and a.open_item_id = new.open_item_id)
  ) then
    return new;
  end if;
  if exists (
    select 1 from fin_settlements s
     where s.id = new.settlement_id and s.tenant_id = new.tenant_id
       and s.direction = 'in'
       and (exists (select 1 from ins_client_advances a
                     where a.tenant_id = new.tenant_id and a.open_item_id = new.open_item_id)
            or public.ins_via_rpc())
  ) then
    return new;
  end if;

  raise exception 'INS_ADVANCE_ALLOCATION: client advance item % can only be settled by an advance receipt or refund from the Insurance module', v_item.document_no;
end;
$$;

drop trigger if exists trg_ins_advance_allocation on fin_allocations;
create trigger trg_ins_advance_allocation
  before insert on fin_allocations
  for each row execute function ins_advance_allocation_guard();

-- ---------------------------------------------------------------------
-- 6. ins_record_client_advance: take the money
-- ---------------------------------------------------------------------
create or replace function public.ins_record_client_advance(
  p_client_id uuid,
  p_bank_account_id uuid,
  p_amount numeric,
  p_received_on date,
  p_reference text default null::text,
  p_notes text default null::text
) returns ins_client_advances
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant  uuid := get_my_tenant_id();
  v_client  uuid;
  v_gl      uuid;
  v_party   uuid;
  v_bank_gl uuid;
  v_ccy     text;
  v_no      text;
  v_item    fin_open_items%rowtype;
  v_set     fin_settlements%rowtype;
  v_adv     ins_client_advances%rowtype;
  v_je      journal_entries%rowtype;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if not is_finance_team_member('finance') then
    raise exception 'INS_ADVANCE_FINANCE: taking client money requires the finance role' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_ADVANCE_AMOUNT: the advance must be greater than zero';
  end if;
  if p_received_on is null or p_received_on > current_date + 1 then
    raise exception 'INS_ADVANCE_DATE: a receipt date is required and cannot be in the future';
  end if;

  -- ins_policies.client_id references ins_clients(id), not the party account, and
  -- fin_open_items.party_account_id references accounts(id). Both are needed.
  select i.client_id, i.party_account_id into v_client, v_party
    from ins_clients i where i.id = p_client_id and i.tenant_id = v_tenant;
  if v_client is null then
    raise exception 'INS_ADVANCE_CLIENT: client % is not a client of this company', p_client_id;
  end if;

  v_ccy := fin_ledger_currency(v_tenant);
  v_gl := get_posting_account(v_tenant, 'client_advance_payable');
  v_bank_gl := get_posting_account(v_tenant, 'client_money_bank');
  if v_gl is null then
    raise exception 'INS_ADVANCE_ACCOUNT: this company has no client_advance_payable posting rule. Map account 2040 before taking unallocated client money.';
  end if;
  if v_bank_gl is null then
    raise exception 'INS_ADVANCE_BANK: this company has no client_money_bank posting rule';
  end if;

  v_no := next_doc_number(v_tenant, 'ins_client_advance', 'ADV');

  -- The liability is recognised when the money is taken: Dr client money, Cr 2040.
  -- No receivable: that is what makes it an advance.
  v_je := public.post_journal_entry(
    v_tenant, 'ins_client_advance_receipt', gen_random_uuid(), p_received_on,
    'Unallocated client advance ' || v_no,
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_bank_gl, 'debit', p_amount, 'currency', v_ccy,
                         'description', 'Client advance received ' || v_no),
      jsonb_build_object('gl_account_id', v_gl, 'credit', p_amount, 'currency', v_ccy,
                         'description', 'Client advance received ' || v_no)));

  -- The open item is the client's credit balance: a payable on 2040 that the
  -- release and the refund both work from.
  insert into fin_open_items (
    tenant_id, party_account_id, side, control_role, source_type, source_id,
    document_no, document_date, due_date, currency, amount, description, created_by, journal_entry_id
  ) values (
    v_tenant, v_party, 'payable',
    'client_advance_payable', 'ins_client_advance', v_je.id,
    v_no, p_received_on, null, v_ccy, p_amount,
    coalesce(nullif(btrim(p_notes), ''), 'Unallocated client advance'), auth.uid(), v_je.id
  )
  returning * into v_item;

  -- Register the money through the ordinary settlement path, so the client-money
  -- controls (bank kind, segregation, approval, voiding) apply to it exactly as
  -- they do to any other client receipt.
  v_set := platform_fin_record_settlement_impl(
    v_tenant, p_bank_account_id, 'in', v_party, p_amount, p_received_on,
    jsonb_build_array(jsonb_build_object('open_item_id', v_item.id, 'amount', p_amount)),
    p_reference, p_notes);

  insert into ins_client_advances (
    tenant_id, client_id, receipt_settlement_id, open_item_id, amount, currency,
    received_on, reference, notes, status, journal_entry_id, created_by
  ) values (
    v_tenant, p_client_id, v_set.id, v_item.id, p_amount, v_ccy,
    p_received_on, nullif(btrim(p_reference), ''), nullif(btrim(p_notes), ''),
    'unallocated', v_je.id, auth.uid()
  )
  returning * into v_adv;

  return v_adv;
end;
$$;

-- ---------------------------------------------------------------------
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
-- 7. ins_apply_client_advance: not available yet, and says so
-- ---------------------------------------------------------------------
-- Registered as B11 (blocking production go-live). Deliberately a hard refusal:
-- a stub that silently returned would let the UI report an advance as released
-- while 2040 still carried it, which is worse than a missing feature. The reason
-- it cannot be implemented on the current schema is in the header.
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
-- 7. ins_apply_client_advance: release the advance to a policy
-- ---------------------------------------------------------------------
-- Pack criterion: "binding a policy allocates it and clears 2040".
--
-- This was refused in the first cut of B2 because the subledger had no way to move
-- a party balance without cash. 20261124010500 supplies it (fin_open_item_dispositions),
-- so the release is now a real posting:
--
--     Dr 2040 unallocated client advances   (the advance item falls)
--     Cr 1100 accounts receivable control   (the premium it paid stops being owed)
--
-- Cash does not move: it arrived at receipt and moving it again would double-count
-- client money. The premium item itself is NOT swept in on its own: if the advance
-- is the whole payment, the premium item is cleared by the normal receipt path as
-- before. What this guarantees is the liability side -- 2040 falls by exactly the
-- amount released, and the subledger agrees because the disposition counts as
-- consumption.
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
create or replace function public.ins_apply_client_advance(
  p_advance_id uuid,
  p_policy_id uuid,
  p_amount numeric,
  p_notes text default null::text
) returns ins_client_advances
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
declare v_adv ins_client_advances%rowtype;
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
declare
  v_tenant   uuid := get_my_tenant_id();
  v_adv      ins_client_advances%rowtype;
  v_policy   ins_policies%rowtype;
  v_adv_item fin_open_items%rowtype;
  v_premium  fin_open_items%rowtype;
  v_ar_gl    uuid;
  v_open     numeric;
  v_disp     fin_open_item_dispositions%rowtype;
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours

  select * into v_adv from ins_client_advances
   where id = p_advance_id and tenant_id = get_my_tenant_id();
  if not found then
    raise exception 'INS_ADVANCE_NOT_FOUND: advance % is not on this company', p_advance_id;
  end if;

  raise exception 'INS_ADVANCE_RELEASE_NOT_AVAILABLE: advance % is recorded on 2040 and cannot yet be released to a policy. Releasing it is a cross-control-account reclass, and the subledger has no source for one (fin_open_item_consumed counts settlements and same-role credit notes only). Refund the advance, or register the receipt against the premium directly once the policy exists. Tracked as B11.',
    v_adv.id;
=======
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
  if not is_finance_team_member('finance') then
    raise exception 'INS_ADVANCE_FINANCE: releasing a client advance requires the finance role' using errcode = '42501';
  end if;

  select * into v_adv from ins_client_advances
   where id = p_advance_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_ADVANCE_NOT_FOUND: advance % is not on this company', p_advance_id;
  end if;
  if v_adv.status = 'refunded' then
    raise exception 'INS_ADVANCE_REFUNDED: advance % has already been refunded', v_adv.id;
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_ADVANCE_AMOUNT: the amount to apply must be greater than zero';
  end if;

  select * into v_policy from ins_policies
   where id = p_policy_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_ADVANCE_POLICY: policy % is not on this company', p_policy_id;
  end if;

  -- Client money is client money: A's advance cannot pay B's premium.
  if v_policy.client_id is distinct from v_adv.client_id then
    raise exception 'INS_ADVANCE_PARTY: advance % belongs to a different client than policy %; client money cannot be applied across clients',
      v_adv.id, v_policy.policy_no;
  end if;
  if v_policy.status not in ('bound','active','endorsed','renewed') then
    raise exception 'INS_ADVANCE_POLICY_STATE: policy % is %; an advance can only be applied to a bound policy',
      v_policy.policy_no, v_policy.status;
  end if;

  v_open := public.fin_open_item_consumed(v_adv.open_item_id);
  if v_open + p_amount > v_adv.amount - v_adv.refunded_amount then
    raise exception 'INS_ADVANCE_EXCEEDS: advance % has % available, % cannot be applied',
      v_adv.id, v_adv.amount - v_adv.refunded_amount - v_open, p_amount;
  end if;

  select * into v_adv_item from fin_open_items
   where id = v_adv.open_item_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_ADVANCE_ITEM: the open item for advance % is missing', v_adv.id;
  end if;

  -- The policy must owe something for the advance to be paying it.
  select * into v_premium from fin_open_items
   where tenant_id = v_tenant and source_type = 'ins_policy_premium'
     and source_id = v_policy.id and side = 'receivable'
   order by created_at limit 1;
  if not found then
    raise exception 'INS_ADVANCE_NO_PREMIUM: policy % has no premium receivable to release the advance against', v_policy.policy_no;
  end if;
  if v_premium.currency <> v_adv.currency then
    raise exception 'INS_ADVANCE_CURRENCY: the advance is in %, the policy premium is in %',
      v_adv.currency, v_premium.currency;
  end if;
  if v_premium.party_account_id is distinct from v_adv_item.party_account_id then
    raise exception 'INS_ADVANCE_PARTY: the advance and the policy premium are held against different client accounts';
  end if;

  v_ar_gl := get_posting_account(v_tenant, 'ar_control');
  if v_ar_gl is null then
    raise exception 'INS_ADVANCE_ACCOUNT: this company has no ar_control posting rule';
  end if;

  v_disp := public.ins_dispose_open_item(
    v_adv.open_item_id,
    'advance_release',
    p_amount,
    v_ar_gl,
    coalesce(nullif(btrim(p_notes), ''),
             'Advance released against ' || v_policy.policy_no),
    current_date);

  update ins_client_advances
     set applied_amount = applied_amount + p_amount,
         applied_policy_id = coalesce(applied_policy_id, p_policy_id),
         applied_at = now(),
         journal_entry_id = coalesce(journal_entry_id, v_disp.journal_entry_id),
         status = case when applied_amount + p_amount + refunded_amount >= amount
                       then 'applied' else 'partly_applied' end
   where id = v_adv.id
  returning * into v_adv;

  return v_adv;
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
<<<<<<< ours
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
=======
>>>>>>> theirs
end;
$$;

-- ---------------------------------------------------------------------
-- 8. ins_refund_client_advance: give it back
-- ---------------------------------------------------------------------
create or replace function public.ins_refund_client_advance(
  p_advance_id uuid,
  p_bank_account_id uuid,
  p_amount numeric,
  p_refunded_on date,
  p_reason text
) returns ins_client_advances
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant  uuid := get_my_tenant_id();
  v_adv     ins_client_advances%rowtype;
  v_item    fin_open_items%rowtype;
  v_open    numeric;
  v_set     fin_settlements%rowtype;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if not is_finance_team_member('finance') then
    raise exception 'INS_ADVANCE_FINANCE: refunding client money requires the finance role' using errcode = '42501';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'INS_ADVANCE_REASON: a refund needs a reason';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_ADVANCE_AMOUNT: the refund must be greater than zero';
  end if;

  select * into v_adv from ins_client_advances
   where id = p_advance_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_ADVANCE_NOT_FOUND: advance % is not on this company', p_advance_id;
  end if;

  select * into v_item from fin_open_items
   where id = v_adv.open_item_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_ADVANCE_ITEM: the open item for advance % is missing', v_adv.id;
  end if;

  v_open := public.fin_open_item_consumed(v_adv.open_item_id);
  if v_open + v_adv.refunded_amount + p_amount > v_adv.amount then
    raise exception 'INS_ADVANCE_EXCEEDS: advance % has % available to refund, % requested',
      v_adv.id, v_adv.amount - v_adv.refunded_amount - v_open, p_amount;
  end if;

  -- An ordinary client-money payment against the advance item, so the settlement
  -- guards (client-money bank only, approval, voidability) all apply to refunds.
  v_set := platform_fin_record_settlement_impl(
    v_tenant, p_bank_account_id, 'out', v_item.party_account_id, p_amount, p_refunded_on,
    jsonb_build_array(jsonb_build_object('open_item_id', v_adv.open_item_id, 'amount', p_amount)),
    null, p_reason);

  update ins_client_advances
     set refunded_amount = refunded_amount + p_amount,
         refunded_at = now(),
         refund_journal_id = v_set.journal_entry_id,
         status = case when applied_amount + refunded_amount + p_amount >= amount
                       then 'refunded' else status end
   where id = v_adv.id
  returning * into v_adv;

  return v_adv;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. ins_client_advance_statement: what the client sees
-- ---------------------------------------------------------------------
create or replace function public.ins_client_advance_statement(p_client_id uuid)
returns table (
  advance_id uuid,
  received_on date,
  document_no text,
  reference text,
  amount numeric,
  applied numeric,
  refunded numeric,
  available numeric,
  status text,
  applied_to_policy text
)
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select a.id,
         a.received_on,
         i.document_no,
         a.reference,
         a.amount,
         a.applied_amount,
         a.refunded_amount,
         a.amount - a.applied_amount - a.refunded_amount,
         a.status,
         p.policy_no
    from ins_client_advances a
    join fin_open_items i on i.id = a.open_item_id and i.tenant_id = a.tenant_id
    left join ins_policies p on p.id = a.applied_policy_id
   where a.tenant_id = get_my_tenant_id()
     and a.client_id = p_client_id
   order by a.received_on, a.created_at;
$$;

-- ---------------------------------------------------------------------
-- 10. Exposure
-- ---------------------------------------------------------------------
revoke all on function public.ins_record_client_advance(uuid, uuid, numeric, date, text, text) from public;
revoke all on function public.ins_apply_client_advance(uuid, uuid, numeric, text) from public;
revoke all on function public.ins_refund_client_advance(uuid, uuid, numeric, date, text) from public;
revoke all on function public.ins_client_advance_statement(uuid) from public;

grant execute on function public.ins_record_client_advance(uuid, uuid, numeric, date, text, text) to authenticated;
grant execute on function public.ins_apply_client_advance(uuid, uuid, numeric, text) to authenticated;
grant execute on function public.ins_refund_client_advance(uuid, uuid, numeric, date, text) to authenticated;
grant execute on function public.ins_client_advance_statement(uuid) to authenticated;

grant select on ins_client_advances to authenticated;
