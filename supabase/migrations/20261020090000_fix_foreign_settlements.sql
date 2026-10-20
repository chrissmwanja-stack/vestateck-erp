-- Follow-up to 20261019130000_foreign_settlements.sql (already applied to the remote).
--
-- 1. fin_settlements_guard: exclude the generated base_amount column from the
--    immutability comparison. A stored generated column is computed after BEFORE
--    triggers, so it differed between OLD and NEW and the guard refused the update
--    that attaches journal_entry_id to a new settlement.
-- 2. platform_fin_record_settlement_impl: merge the bank line's currency into the
--    line object. Previously the CASE result was appended to the lines array as a
--    separate element ('{}' for the functional currency), which post_journal_entry
--    rejected as a line with no GL account.
--
-- The original migration file carries the same corrections, so a fresh database built
-- from the migrations ends in the same state. These are CREATE OR REPLACE only: no
-- signature, grant or data changes.

create or replace function public.fin_settlements_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_keys constant text[] := array['journal_entry_id', 'status', 'void_journal_entry_id', 'voided_at', 'voided_by', 'void_reason', 'base_amount'];
  v_functional text;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'posted' or new.journal_entry_id is not null or new.void_journal_entry_id is not null then
      raise exception 'SETTLEMENT_STATE: a settlement is created posted, with its journal attached afterwards';
    end if;
    if not exists (select 1 from accounts a where a.id = new.party_account_id and a.tenant_id = new.tenant_id) then
      raise exception 'SETTLEMENT_PARTY_INVALID: the party must be an account of the same company';
    end if;
    if not exists (
      select 1 from fin_bank_accounts b
       where b.id = new.bank_account_id and b.tenant_id = new.tenant_id and b.currency = new.currency
    ) then
      raise exception 'SETTLEMENT_CURRENCY: a settlement is in its bank account''s currency (got %)', new.currency;
    end if;

    v_functional := fin_ledger_currency(new.tenant_id);
    if new.currency = v_functional then
      if new.fx_rate <> 1 or new.realised_result <> 0 then
        raise exception 'SETTLEMENT_RATE: a settlement in the functional currency (%) is at rate 1 with no realised result', v_functional;
      end if;
    elsif new.fx_rate is distinct from round((platform_fx_rate(new.tenant_id, new.currency, new.settlement_date)).rate, 8) then
      raise exception 'SETTLEMENT_RATE: the settlement rate must be the approved % rate for %', new.currency, new.settlement_date;
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
$function$;

create or replace function public.platform_fin_record_settlement_impl(
  p_tenant_id uuid,
  p_bank_account_id uuid,
  p_direction text,
  p_party_account_id uuid,
  p_amount numeric,
  p_settlement_date date,
  p_allocations jsonb,
  p_reference text default null,
  p_notes text default null
)
returns public.fin_settlements
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
    -- Functional currency: control lines grouped by role, exactly as before.
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
    -- Foreign currency: one control line per booking entry, at the rate that entry used,
    -- naming the entry as the rate source.
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
    -- Bank line at the settlement-date rate; the difference to what the items were booked
    -- at is the realised result (a gain when more functional currency comes in than was
    -- booked, or less goes out; a loss the other way round).
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

  v_je := post_journal_entry(p_tenant_id, 'fin_settlement', v_set.id, p_settlement_date, v_desc, v_lines);

  update fin_settlements set journal_entry_id = v_je.id where id = v_set.id returning * into v_set;
  return v_set;
end;
$function$;