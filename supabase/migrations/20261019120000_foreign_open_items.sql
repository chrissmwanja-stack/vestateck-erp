-- Phase A, A3 slice 3c-1 (see docs/insurance-brokerage/CURRENCY_REVIEW.md): open items
-- may be in a foreign currency, carrying the rate they were booked at.
--
-- Until now fin_open_items_guard refused any currency other than the ledger currency
-- ("until multi-currency is designed") and fin_create_open_item hard-wired it.
--
-- What changes:
--   1. fin_open_items gains fx_rate (the rate the item was booked at, 1 for the
--      functional currency), base_amount (amount at that rate, rounded as the ledger
--      rounds line base amounts) and journal_entry_id (the entry that booked the item).
--      Existing rows keep rate 1 and a null entry; nothing is rewritten.
--   2. The guard no longer refuses a foreign currency. It now requires, for a foreign
--      item, that the named journal entry has a line on the item's control account, in
--      the item's currency, at exactly the item's rate (OPEN_ITEM_RATE otherwise). An
--      item in the functional currency must be at rate 1.
--   3. fin_create_open_item_fx creates an open item in a stated currency. For a foreign
--      currency it takes the rate from the booking entry's control line, so the caller
--      cannot choose a rate. The existing fin_create_open_item is unchanged and still
--      creates functional-currency items only; no existing caller changes.
--   4. fin_open_item_balances exposes fx_rate and base_outstanding_amount (the
--      outstanding amount at the booked rate, which a period-end revaluation needs),
--      appended at the end so existing readers are unaffected.
--
-- No caller passes a foreign currency yet (that is slice 3d), so no existing company's
-- behaviour changes. Settling a foreign item is slice 3c-2.

-- =====================================================================
-- A. Columns
-- =====================================================================
alter table public.fin_open_items
  add column if not exists fx_rate numeric(20,8) not null default 1,
  add column if not exists journal_entry_id uuid references public.journal_entries(id);

alter table public.fin_open_items
  drop constraint if exists fin_open_items_fx_rate_check;
alter table public.fin_open_items
  add constraint fin_open_items_fx_rate_check check (fx_rate > 0);

alter table public.fin_open_items
  add column if not exists base_amount numeric generated always as (round(amount * fx_rate, 2)) stored;

comment on column public.fin_open_items.fx_rate is
  'Rate the item was booked at: functional-currency units per 1 unit of the item currency. 1 for the functional currency.';
comment on column public.fin_open_items.base_amount is
  'Amount at the booked rate in the functional currency, rounded like journal line base amounts.';
comment on column public.fin_open_items.journal_entry_id is
  'The journal entry that booked the item. Required for a foreign-currency item; null on items created before this column existed.';

create index if not exists fin_open_items_journal_entry_idx
  on public.fin_open_items (journal_entry_id) where journal_entry_id is not null;

-- =====================================================================
-- B. Guard
-- =====================================================================
create or replace function public.fin_open_items_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_functional text;
  v_control    uuid;
begin
  if tg_op = 'UPDATE' then
    raise exception 'OPEN_ITEM_IMMUTABLE: an open item cannot be changed; settle it, or use a credit note';
  end if;
  if not exists (select 1 from accounts a where a.id = new.party_account_id and a.tenant_id = new.tenant_id) then
    raise exception 'OPEN_ITEM_PARTY_INVALID: the party must be an account of the same company';
  end if;

  v_functional := fin_ledger_currency(new.tenant_id);
  if new.currency = v_functional then
    if new.fx_rate <> 1 then
      raise exception 'OPEN_ITEM_RATE: an item in the functional currency (%) is at rate 1, not %', v_functional, new.fx_rate;
    end if;
  else
    if new.journal_entry_id is null then
      raise exception 'OPEN_ITEM_RATE: a % item must name the journal entry that booked it', new.currency;
    end if;
    v_control := get_posting_account(new.tenant_id, new.control_role);
    if v_control is null
       or not exists (
         select 1 from journal_entry_lines l
          where l.journal_entry_id = new.journal_entry_id
            and l.tenant_id = new.tenant_id
            and l.gl_account_id = v_control
            and l.currency = new.currency
            and l.fx_rate = new.fx_rate
       ) then
      raise exception 'OPEN_ITEM_RATE: the booking entry has no % line on the % account at rate %',
        new.currency, new.control_role, new.fx_rate;
    end if;
  end if;
  return new;
end;
$function$;

-- =====================================================================
-- C. Creating a foreign-currency open item
-- =====================================================================
create or replace function public.fin_create_open_item_fx(
  p_tenant_id        uuid,
  p_party_account_id uuid,
  p_control_role     text,
  p_source_type      text,
  p_source_id        uuid,
  p_document_no      text,
  p_document_date    date,
  p_due_date         date,
  p_amount           numeric,
  p_description      text,
  p_currency         text,
  p_journal_entry_id uuid
)
returns public.fin_open_items
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_row        fin_open_items%rowtype;
  v_functional text;
  v_ccy        text;
  v_rate       numeric := 1;
  v_control    uuid;
begin
  if p_tenant_id is null then
    raise exception 'tenant id is required';
  end if;
  if auth.uid() is not null and p_tenant_id is distinct from public.get_my_tenant_id() then
    raise exception 'not authorized to create open items for this tenant' using errcode = '42501';
  end if;

  v_functional := fin_ledger_currency(p_tenant_id);
  v_ccy := coalesce(nullif(btrim(p_currency), ''), v_functional);

  if v_ccy <> v_functional then
    if p_journal_entry_id is null then
      raise exception 'OPEN_ITEM_RATE: a % item must name the journal entry that booked it', v_ccy;
    end if;
    v_control := get_posting_account(p_tenant_id, p_control_role);
    select l.fx_rate into v_rate
      from journal_entry_lines l
     where l.journal_entry_id = p_journal_entry_id
       and l.tenant_id = p_tenant_id
       and l.gl_account_id = v_control
       and l.currency = v_ccy
     order by l.id
     limit 1;
    if v_rate is null then
      raise exception 'OPEN_ITEM_RATE: the booking entry has no % line on the % account', v_ccy, p_control_role;
    end if;
  end if;

  insert into fin_open_items (
    tenant_id, party_account_id, side, control_role, source_type, source_id,
    document_no, document_date, due_date, currency, amount, description, fx_rate, journal_entry_id
  ) values (
    p_tenant_id, p_party_account_id,
    case when p_control_role in ('ar_control', 'commission_receivable', 'insurer_claim_receivable') then 'receivable' else 'payable' end,
    p_control_role, p_source_type, p_source_id,
    p_document_no, p_document_date, p_due_date, v_ccy, p_amount, p_description, v_rate, p_journal_entry_id
  )
  returning * into v_row;

  return v_row;
end;
$function$;

revoke all on function public.fin_create_open_item_fx(uuid, uuid, text, text, uuid, text, date, date, numeric, text, text, uuid)
  from public, anon, authenticated;

-- =====================================================================
-- D. Balances view: booked rate and base outstanding, appended at the end
-- =====================================================================
create or replace view public.fin_open_item_balances as
 SELECT i.id,
    i.tenant_id,
    i.party_account_id,
    i.side,
    i.control_role,
    i.source_type,
    i.source_id,
    i.document_no,
    i.document_date,
    i.due_date,
    i.currency,
    i.amount,
    i.description,
    COALESCE(a.allocated, 0::numeric) AS allocated_amount,
    i.amount - COALESCE(a.allocated, 0::numeric) - COALESCE(c.credited, 0::numeric) AS outstanding_amount,
        CASE
            WHEN (COALESCE(a.allocated, 0::numeric) + COALESCE(c.credited, 0::numeric)) = 0::numeric THEN 'open'::text
            WHEN (COALESCE(a.allocated, 0::numeric) + COALESCE(c.credited, 0::numeric)) < i.amount THEN 'partly_settled'::text
            ELSE 'settled'::text
        END AS settlement_status,
    COALESCE(c.credited, 0::numeric) AS credited_amount,
    i.fx_rate,
    round((i.amount - COALESCE(a.allocated, 0::numeric) - COALESCE(c.credited, 0::numeric)) * i.fx_rate, 2) AS base_outstanding_amount
   FROM fin_open_items i
     LEFT JOIN LATERAL ( SELECT sum(al.amount) AS allocated
           FROM fin_allocations al
             JOIN fin_settlements s ON s.id = al.settlement_id
          WHERE al.open_item_id = i.id AND s.status = 'posted'::text) a ON true
     LEFT JOIN LATERAL ( SELECT sum(ca.amount) AS credited
           FROM fin_credit_applications ca
             JOIN fin_credit_notes cn ON cn.id = ca.credit_note_id
          WHERE ca.open_item_id = i.id AND cn.status = 'posted'::text) c ON true;

alter view public.fin_open_item_balances set (security_invoker = true);