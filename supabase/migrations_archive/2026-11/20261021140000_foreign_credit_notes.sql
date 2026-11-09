-- Phase A, A3 slice 3d-1 (see docs/insurance-brokerage/CURRENCY_REVIEW.md): credit notes
-- may be in a foreign currency, with realised gain or loss against the booked rates.
--
-- Until now fin_credit_notes_guard refused any currency other than the ledger currency
-- ("until multi-currency is designed"), both raise functions hard-wired the ledger
-- currency onto the note and posted ledger-currency lines, and the void rebuilt its
-- reversal without currency, so a foreign credit note could not have been voided
-- correctly.
--
-- What changes:
--   1. fin_credit_notes gains fx_rate (the note-date rate used for the offset line, 1
--      for the functional currency), base_amount (generated) and realised_result (the
--      gain or loss booked with the note, positive a gain, 0 for the functional
--      currency). Existing rows keep rate 1 and result 0; nothing is rewritten.
--   2. The guard no longer refuses a foreign currency. It requires, for a foreign note,
--      its rate to be the approved rate for the credit date at the precision the ledger
--      stores (8 decimals). A functional note must be at rate 1 with no realised result.
--   3. platform_fin_raise_credit_note_impl takes the note's currency from the open items
--      it applies to (they must all be in one currency). Each control line is booked at
--      the rate its item was booked at (one line per booking entry, each naming that
--      entry as its rate source), the offset line at the credit-date rate, and the
--      difference as realised gain or loss through the 3b functions. The path for the
--      functional currency is unchanged line for line.
--   4. platform_fin_raise_policy_credit_note_impl (the policy-reversal exemption) gets
--      the same treatment; its items are the policy's own premium and insurer items.
--   5. platform_fin_void_credit_note_impl reverses in reversal mode, so each line keeps
--      its currency, original rate and rounding flag and the reversal negates the note
--      exactly, realised line included. For a functional note this changes nothing.
--
-- Callers that insert a credit note directly (the cancellation flow's original-item
-- credit) keep working unchanged for functional-currency policies: their notes take the
-- column defaults (rate 1, result 0), which is exactly what the guard now requires. A
-- foreign policy reaches that flow only when slice 3d-2 lets policies bind in a foreign
-- currency, and the flow must be converted then.
--
-- Not covered here, and still guarded: transfers between bank accounts, policy bind and
-- the insurance posting functions (the rest of slice 3d), then period-end revaluation
-- (3e).

-- =====================================================================
-- A. Columns
-- =====================================================================
alter table public.fin_credit_notes
  add column if not exists fx_rate numeric(20,8) not null default 1,
  add column if not exists realised_result numeric(20,2) not null default 0;

alter table public.fin_credit_notes drop constraint if exists fin_credit_notes_fx_rate_check;
alter table public.fin_credit_notes
  add constraint fin_credit_notes_fx_rate_check check (fx_rate > 0);

alter table public.fin_credit_notes
  add column if not exists base_amount numeric generated always as (round(amount * fx_rate, 2)) stored;

comment on column public.fin_credit_notes.fx_rate is
  'Credit-date rate of the note currency for the offset line: functional-currency units per 1 unit. 1 for the functional currency.';
comment on column public.fin_credit_notes.base_amount is
  'Amount at the note rate in the functional currency, rounded like journal line base amounts.';
comment on column public.fin_credit_notes.realised_result is
  'Realised exchange gain (positive) or loss (negative) booked with this note, in the functional currency.';

-- =====================================================================
-- B. Guard
-- =====================================================================
create or replace function public.fin_credit_notes_guard()
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
      raise exception 'CREDIT_NOTE_STATE: a credit note is created posted, with its journal attached afterwards';
    end if;
    if not exists (select 1 from accounts a where a.id = new.party_account_id and a.tenant_id = new.tenant_id) then
      raise exception 'CREDIT_NOTE_PARTY_INVALID: the party must be an account of the same company';
    end if;
    if not exists (select 1 from gl_accounts g where g.id = new.offset_gl_account_id and g.tenant_id = new.tenant_id) then
      raise exception 'CREDIT_NOTE_OFFSET: the offset account must be a GL account of the same company';
    end if;

    v_functional := fin_ledger_currency(new.tenant_id);
    if new.currency = v_functional then
      if new.fx_rate <> 1 or new.realised_result <> 0 then
        raise exception 'CREDIT_NOTE_RATE: a credit note in the functional currency (%) is at rate 1 with no realised result', v_functional;
      end if;
    elsif new.fx_rate is distinct from round((platform_fx_rate(new.tenant_id, new.currency, new.credit_date)).rate, 8) then
      raise exception 'CREDIT_NOTE_RATE: the credit note rate must be the approved % rate for %', new.currency, new.credit_date;
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
$function$;

-- =====================================================================
-- C. Raising a credit note
-- =====================================================================
create or replace function public.platform_fin_raise_credit_note_impl(p_tenant_id uuid, p_control_role text, p_party_account_id uuid, p_amount numeric, p_credit_date date, p_offset_gl_account_id uuid, p_applications jsonb, p_reason text, p_reference text DEFAULT NULL::text)
 RETURNS fin_credit_notes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_side       text;
  v_ids        uuid[] := '{}';
  v_sum        numeric := 0;
  v_elem       jsonb;
  v_item       fin_open_items%rowtype;
  v_role       record;
  v_ctl_gl     uuid;
  v_ctl_row    gl_accounts%rowtype;
  v_off_row    gl_accounts%rowtype;
  v_no         text;
  v_desc       text;
  v_lines      jsonb;
  v_note       fin_credit_notes%rowtype;
  v_je         journal_entries%rowtype;
  v_functional text;
  v_ccy        text := null;
  v_foreign    boolean;
  v_nr         numeric := 1;
  v_base_note  numeric;
  v_total_orig numeric := 0;
  v_result     numeric := 0;
  v_fx_line    jsonb;
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

  -- Lock the items in a fixed order, then check each one. The note's currency is the
  -- items' currency: they must all agree.
  for v_item in
    select * from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids) order by id for update
  loop
    if v_item.control_role <> p_control_role then
      raise exception 'CREDIT_NOTE_ROLE: a % credit note cannot be applied to % items (%)',
        p_control_role, v_item.control_role, v_item.document_no;
    end if;
    if v_ccy is null then
      v_ccy := v_item.currency;
    elsif v_item.currency is distinct from v_ccy then
      raise exception 'CREDIT_NOTE_CURRENCY: a credit note is in one currency; item % is in %, not %',
        v_item.document_no, v_item.currency, v_ccy;
    end if;
  end loop;
  if (select count(*) from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids)) <> cardinality(v_ids) then
    raise exception 'CREDIT_APPLICATION_ITEM: an open item was not found in this company';
  end if;

  v_functional := fin_ledger_currency(p_tenant_id);
  v_foreign    := v_ccy is not null and v_ccy <> v_functional;
  if v_foreign then
    if exists (
      select 1 from fin_open_items
       where tenant_id = p_tenant_id and id = any (v_ids)
         and (journal_entry_id is null or fx_rate is null or fx_rate <= 0)
    ) then
      raise exception 'CREDIT_NOTE_ITEM_RATE: a % credit note needs items that name the entry that booked them, at a positive rate', v_ccy;
    end if;
    v_nr := round((platform_fx_rate(p_tenant_id, v_ccy, p_credit_date)).rate, 8);
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

  v_no   := next_doc_number(p_tenant_id, 'fin_credit_note', 'CRN');
  v_desc := 'Credit note ' || v_no;

  if not v_foreign then
    v_lines := case v_side
      when 'receivable' then jsonb_build_array(
        jsonb_build_object('gl_account_id', v_off_row.id, 'debit', p_amount, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_ctl_gl, 'credit', p_amount, 'description', v_desc))
      else jsonb_build_array(
        jsonb_build_object('gl_account_id', v_ctl_gl, 'debit', p_amount, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_off_row.id, 'credit', p_amount, 'description', v_desc))
    end;
  else
    -- Foreign currency: one control line per booking entry, at the rate that entry used,
    -- naming the entry as the rate source; the offset line at the credit-date rate.
    v_lines := '[]'::jsonb;
    for v_role in
      select i.journal_entry_id, i.fx_rate, sum((e ->> 'amount')::numeric) as amt
      from jsonb_array_elements(p_applications) e
      join fin_open_items i on i.id = (e ->> 'open_item_id')::uuid and i.tenant_id = p_tenant_id
      group by i.journal_entry_id, i.fx_rate
      order by i.journal_entry_id
    loop
      v_lines := v_lines || jsonb_build_object(
        'gl_account_id', v_ctl_gl,
        case v_side when 'receivable' then 'credit' else 'debit' end, v_role.amt,
        'currency', v_ccy,
        'rate_from_entry', v_role.journal_entry_id,
        'fx_rate', v_role.fx_rate,
        'description', v_desc);
      v_total_orig := v_total_orig + round(v_role.amt * v_role.fx_rate, 2);
    end loop;
    v_lines := v_lines || jsonb_build_object(
      'gl_account_id', v_off_row.id,
      case v_side when 'receivable' then 'debit' else 'credit' end, p_amount,
      'currency', v_ccy,
      'description', v_desc);
    v_base_note := round(p_amount * v_nr, 2);
    -- Cancelling a receivable booked at the original rate with a note at today's rate:
    -- what the offset takes minus what was booked is a gain when positive (the same sign
    -- as a receipt against the item). A payable note is the mirror of a payment.
    v_result  := case v_side when 'receivable' then v_base_note - v_total_orig
                             else v_total_orig - v_base_note end;
    v_fx_line := platform_fx_realised_line(p_tenant_id, v_result, 'Realised exchange result on ' || v_no);
    if v_fx_line is not null then
      v_lines := v_lines || v_fx_line;
    end if;
  end if;

  insert into fin_credit_notes (
    tenant_id, credit_note_no, side, control_role, party_account_id, offset_gl_account_id,
    amount, currency, fx_rate, realised_result, credit_date, reason, reference
  ) values (
    p_tenant_id, v_no, v_side, p_control_role, p_party_account_id, v_off_row.id,
    p_amount, v_ccy, v_nr, v_result, p_credit_date, btrim(p_reason), nullif(btrim(p_reference), '')
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
$function$;

-- =====================================================================
-- D. The policy-reversal exemption: same currency treatment
-- =====================================================================
create or replace function public.platform_fin_raise_policy_credit_note_impl(p_tenant_id uuid, p_control_role text, p_party_account_id uuid, p_amount numeric, p_credit_date date, p_offset_gl_account_id uuid, p_applications jsonb, p_reason text, p_reference text, p_policy_id uuid)
 RETURNS fin_credit_notes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_context    jsonb;
  v_side       text;
  v_ids        uuid[] := '{}';
  v_sum        numeric := 0;
  v_elem       jsonb;
  v_item       fin_open_items%rowtype;
  v_role       record;
  v_ctl_gl     uuid;
  v_ctl_row    gl_accounts%rowtype;
  v_off_row    gl_accounts%rowtype;
  v_no         text;
  v_desc       text;
  v_lines      jsonb;
  v_note       fin_credit_notes%rowtype;
  v_je         journal_entries%rowtype;
  v_functional text;
  v_ccy        text := null;
  v_foreign    boolean;
  v_nr         numeric := 1;
  v_base_note  numeric;
  v_total_orig numeric := 0;
  v_result     numeric := 0;
  v_fx_line    jsonb;
begin
  if p_tenant_id is distinct from get_my_tenant_id() or not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: insurance manager access required' using errcode = '42501';
  end if;
  v_context := ins_policy_reversal_context(p_policy_id, true);
  if (v_context->>'offset_id')::uuid is distinct from p_offset_gl_account_id
     or p_control_role not in ('ar_control','insurer_payable')
     or p_applications is distinct from jsonb_build_array(jsonb_build_object(
       'open_item_id', case when p_control_role = 'ar_control' then v_context->>'premium_item_id' else v_context->>'insurer_item_id' end,
       'amount', p_amount)) then
    raise exception 'INS_REVERSAL_OFFSET: exemption is limited to this policy and its complete open items';
  end if;
  if p_amount <> (v_context->>(case when p_control_role = 'ar_control' then 'gross' else 'net' end))::numeric then
    raise exception 'INS_REVERSAL_OFFSET: only full policy amounts are allowed';
  end if;
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

  -- Lock the items in a fixed order, then check each one. The note's currency is the
  -- items' currency: they must all agree.
  for v_item in
    select * from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids) order by id for update
  loop
    if v_item.control_role <> p_control_role then
      raise exception 'CREDIT_NOTE_ROLE: a % credit note cannot be applied to % items (%)',
        p_control_role, v_item.control_role, v_item.document_no;
    end if;
    if v_ccy is null then
      v_ccy := v_item.currency;
    elsif v_item.currency is distinct from v_ccy then
      raise exception 'CREDIT_NOTE_CURRENCY: a credit note is in one currency; item % is in %, not %',
        v_item.document_no, v_item.currency, v_ccy;
    end if;
  end loop;
  if (select count(*) from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids)) <> cardinality(v_ids) then
    raise exception 'CREDIT_APPLICATION_ITEM: an open item was not found in this company';
  end if;

  v_functional := fin_ledger_currency(p_tenant_id);
  v_foreign    := v_ccy is not null and v_ccy <> v_functional;
  if v_foreign then
    if exists (
      select 1 from fin_open_items
       where tenant_id = p_tenant_id and id = any (v_ids)
         and (journal_entry_id is null or fx_rate is null or fx_rate <= 0)
    ) then
      raise exception 'CREDIT_NOTE_ITEM_RATE: a % credit note needs items that name the entry that booked them, at a positive rate', v_ccy;
    end if;
    v_nr := round((platform_fx_rate(p_tenant_id, v_ccy, p_credit_date)).rate, 8);
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
  if v_off_row.id = v_ctl_gl or (v_off_row.is_control_account and (v_context->>'offset_id')::uuid is distinct from v_off_row.id)
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

  v_no   := next_doc_number(p_tenant_id, 'fin_credit_note', 'CRN');
  v_desc := 'Credit note ' || v_no;

  if not v_foreign then
    v_lines := case v_side
      when 'receivable' then jsonb_build_array(
        jsonb_build_object('gl_account_id', v_off_row.id, 'debit', p_amount, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_ctl_gl, 'credit', p_amount, 'description', v_desc))
      else jsonb_build_array(
        jsonb_build_object('gl_account_id', v_ctl_gl, 'debit', p_amount, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_off_row.id, 'credit', p_amount, 'description', v_desc))
    end;
  else
    -- Foreign currency: one control line per booking entry, at the rate that entry used,
    -- naming the entry as the rate source; the offset line at the credit-date rate.
    v_lines := '[]'::jsonb;
    for v_role in
      select i.journal_entry_id, i.fx_rate, sum((e ->> 'amount')::numeric) as amt
      from jsonb_array_elements(p_applications) e
      join fin_open_items i on i.id = (e ->> 'open_item_id')::uuid and i.tenant_id = p_tenant_id
      group by i.journal_entry_id, i.fx_rate
      order by i.journal_entry_id
    loop
      v_lines := v_lines || jsonb_build_object(
        'gl_account_id', v_ctl_gl,
        case v_side when 'receivable' then 'credit' else 'debit' end, v_role.amt,
        'currency', v_ccy,
        'rate_from_entry', v_role.journal_entry_id,
        'fx_rate', v_role.fx_rate,
        'description', v_desc);
      v_total_orig := v_total_orig + round(v_role.amt * v_role.fx_rate, 2);
    end loop;
    v_lines := v_lines || jsonb_build_object(
      'gl_account_id', v_off_row.id,
      case v_side when 'receivable' then 'debit' else 'credit' end, p_amount,
      'currency', v_ccy,
      'description', v_desc);
    v_base_note := round(p_amount * v_nr, 2);
    v_result    := case v_side when 'receivable' then v_base_note - v_total_orig
                               else v_total_orig - v_base_note end;
    v_fx_line   := platform_fx_realised_line(p_tenant_id, v_result, 'Realised exchange result on ' || v_no);
    if v_fx_line is not null then
      v_lines := v_lines || v_fx_line;
    end if;
  end if;

  insert into fin_credit_notes (
    tenant_id, credit_note_no, side, control_role, party_account_id, offset_gl_account_id,
    amount, currency, fx_rate, realised_result, credit_date, reason, reference
  ) values (
    p_tenant_id, v_no, v_side, p_control_role, p_party_account_id, v_off_row.id,
    p_amount, v_ccy, v_nr, v_result, p_credit_date, btrim(p_reason), nullif(btrim(p_reference), '')
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
$function$;

-- =====================================================================
-- E. Voiding: reverse exactly, currency and rates included
-- =====================================================================
create or replace function public.platform_fin_void_credit_note_impl(p_tenant_id uuid, p_credit_note_id uuid, p_reason text, p_void_date date DEFAULT CURRENT_DATE)
 RETURNS fin_credit_notes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  -- Swap debit and credit, keeping each line's currency, original rate and rounding flag.
  select jsonb_agg(jsonb_build_object(
           'gl_account_id', l.gl_account_id,
           'debit', l.credit,
           'credit', l.debit,
           'currency', l.currency,
           'fx_rate', l.fx_rate,
           'is_rounding', l.is_rounding,
           'description', 'Reversal of ' || v_note.credit_note_no))
    into v_lines
    from journal_entry_lines l
   where l.journal_entry_id = v_note.journal_entry_id;

  -- Reversal mode: the line guard keeps the original rates, but only rates that the entry
  -- being reversed already used.
  perform set_config('fin.reversal_of', v_note.journal_entry_id::text, true);
  v_je := post_journal_entry(p_tenant_id, 'fin_credit_note_void', v_note.id, p_void_date,
                             'Void of credit note ' || v_note.credit_note_no || ': ' || btrim(p_reason), v_lines);
  perform set_config('fin.reversal_of', '', true);

  update fin_credit_notes
     set status = 'void', void_journal_entry_id = v_je.id, voided_at = now(),
         voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = v_note.id
  returning * into v_note;

  return v_note;
end;
$function$;
