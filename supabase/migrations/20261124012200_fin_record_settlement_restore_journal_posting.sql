-- =====================================================================
-- Restore journal posting in platform_fin_record_settlement_impl
-- =====================================================================
-- 20261124010300 recreated this function to let a client-money receipt settle an
-- advance item. Its header says the only change against 20261121150000 is the
-- v_allowed line, but the copy also lost the last two statements of the function:
--
--     v_je := post_journal_entry(p_tenant_id, 'fin_settlement', ...);
--     update fin_settlements set journal_entry_id = v_je.id ...;
--
-- Every settlement recorded through this function since then is stored with
-- journal_entry_id NULL and NO general-ledger posting: the bank and control
-- accounts are not touched, and fin_void_settlement refuses the row with
-- "SETTLEMENT_VOID: ... has no posted journal". The policy-cash concurrency
-- script caught it (both the premium receipt and the insurer remittance had a
-- null journal_entry_id).
--
-- The same copy also reverted the Africa/Kampala business-date rule: the future-date
-- check used current_date again instead of public.ins_local_today() (restored here).
--
-- Fix forward (rule 9): 20261124010300 is already applied and is not edited. This
-- recreates the function exactly as 010300 defined it, plus the two statements
-- above and the business-date check, so the only difference against 20261121150000 is again the v_allowed line.
--
-- It does NOT repair rows already written without a journal. On any database where
-- 20261124010300 has run and settlements were recorded afterwards, find them with:
--     select id, settlement_no, settlement_date, direction, amount
--       from fin_settlements where status = 'posted' and journal_entry_id is null;
-- and decide per row how to post them before the next period close.

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
  if p_settlement_date is null or p_settlement_date > public.ins_local_today() + 1 then
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

  v_je := post_journal_entry(p_tenant_id, 'fin_settlement', v_set.id, p_settlement_date, v_desc, v_lines);

  update fin_settlements set journal_entry_id = v_je.id where id = v_set.id returning * into v_set;
  return v_set;
end;
$$;
