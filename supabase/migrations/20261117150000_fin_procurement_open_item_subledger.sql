-- =====================================================================
-- Finance E1: wire procurement into the open-item subledger
-- =====================================================================
--
-- Finding E1 (recorded in docs/handoffs/FINANCE_E_END_TO_END_TRACE.md):
-- procurement money flow and the open-item subledger were two parallel
-- mechanisms that never met.
--
--   (a) Procurement payments are cash_bank_transactions with
--       reference_type = 'supplier_invoice'. trg_post_cash_bank_transaction
--       posts Dr AP / Cr bank (+ realised FX) and never creates a
--       fin_open_items row, so there was nothing to settle.
--   (b) fin_open_items / fin_settlements / fin_allocations are used by the
--       insurance module and the Finance settlement screens. Each settlement
--       posts its OWN journal (Dr AP / Cr bank).
--
-- Consequence: a procurement payment had no open item, so the trace stopped
-- at the bank match; and if the same payment were also booked as a
-- settlement the same economic event would be journaled TWICE (once by
-- trg_post_cash_bank_transaction, once by fin_record_settlement), leaving AP
-- control double-debited.
--
-- What this migration does
-- ---------------------------------------------------------------------
-- 1. trg_post_supplier_invoice creates the AP open item, in the INVOICE's
--    currency, at the rate the invoice's own journal booked it at, linked to
--    that journal (fin_open_items.journal_entry_id). The amount is the AP
--    credit actually posted (net of withholding tax), so the subledger and
--    the control account cannot disagree.
--
-- 2. A procurement payment now also settles that open item -- but through a
--    settlement row with NO journal of its own. The payment's journal
--    (Dr AP / Cr bank + realised FX) is already the correct double entry, so
--    the settlement is created with journal_entry_id null and flagged as
--    subledger-only. The allocation is what links the payment to the item;
--    the GL is left to the cash/bank trigger, unchanged.
--
--    This is the resolution of the double-journal defect: exactly ONE
--    mechanism posts the GL for a procurement payment (the cash/bank
--    transaction), and exactly ONE mechanism owns the open-item balance (the
--    settlement/allocation). They are joined by bank_reconciliations, which
--    already carries both cash_bank_transaction_id and settlement_id.
--
-- 3. fin_settlements.funding_transaction_id records which cash/bank
--    transaction carried out the settlement, so the trace can walk from the
--    item back to the money without re-deriving it from the reference.
--
-- Deliberately NOT done here
-- ---------------------------------------------------------------------
-- * The payment path is untouched for the AR side (receivable_invoice) -- a
--   receipt already lands on ar_control and the AR subledger is fed by its
--   own module. Only the AP side is wired.
-- * Procurement payments are NOT rerouted through fin_record_settlement:
--   that RPC takes a fin_bank_accounts id, and cash_bank_transactions only
--   carries a free-text bank_account, so there is no reliable FK to pass.
--   Forcing the reroute would either invent a bank mapping or break every
--   existing payment screen. The subledger wiring therefore rides ON the
--   existing payment insert.
-- * An invoice with no vendor_account_id (the column is nullable, though
--   both supplier invoice screens require it) cannot be settled in the
--   subledger, because fin_allocations_guard requires item party = settlement
--   party. Such invoices keep working exactly as before -- GL only, no
--   subledger -- and fin_trace_gaps() reports them as an explicit gap rather
--   than leaving the omission silent.
--
-- Backfill
-- ---------------------------------------------------------------------
-- None. As with item D, existing invoices are not given open items: a
-- backfilled item would have to invent an outstanding balance for money that
-- may already have been paid, and there is no reliable way to pair the
-- historical payments to the historical invoices after the fact. The gap
-- report makes the omission visible instead of guessing.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Schema: link an open item to the payment that settled it, and mark
--    settlements that exist for the subledger only.
-- ---------------------------------------------------------------------

-- A settlement with a null journal is a subledger-only record: the GL entry
-- was posted by the funding transaction, which is named on the settlement
-- itself. Constrain both so the flag cannot drift into "settlement with no
-- journal and no explanation".
alter table fin_settlements
  add column if not exists subledger_only boolean not null default false;

alter table fin_settlements
  add column if not exists funding_transaction_id uuid
    references cash_bank_transactions (id) on delete set null;

comment on column fin_settlements.subledger_only is
  'True when this settlement records an allocation only: the bank movement and its GL entry belong to a cash_bank_transactions row (procurement payments).';

comment on column fin_settlements.funding_transaction_id is
  'The cash/bank transaction that carried out this settlement when subledger_only; that transaction posted the GL entry.';

create index if not exists fin_settlements_funding_transaction_idx
  on fin_settlements (funding_transaction_id)
  where funding_transaction_id is not null;

-- No CHECK constraint on the shape: fin_record_settlement deliberately
-- inserts a settlement posted with journal_entry_id null and attaches the
-- journal on the next statement, so a table-level check would reject the
-- normal flow. The state machine lives in fin_settlements_guard() below,
-- which sees both the insert and the later update.

-- One open item per source document. Without this, a retried or duplicated
-- invoice trigger would silently double the subledger against a single GL
-- posting -- the exact class of defect this work is closing.
create unique index if not exists fin_open_items_source_unique
  on fin_open_items (tenant_id, source_type, source_id)
  where source_type in ('supplier_invoice', 'receivable_invoice');

-- ---------------------------------------------------------------------
-- 2. The settlement guard must allow the subledger-only shape
-- ---------------------------------------------------------------------
-- fin_settlements_guard requires INSERT to appear "posted, with its journal
-- attached afterwards". A subledger-only settlement never gets a journal, so
-- it is created in its final form. Allow that one shape and nothing else.
create or replace function fin_settlements_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  -- subledger_only and funding_transaction_id are included so their specific
  -- rules below fire instead of the blanket "cannot be edited" check.
  v_keys constant text[] := array['journal_entry_id', 'status', 'void_journal_entry_id', 'voided_at',
                                 'voided_by', 'void_reason', 'base_amount', 'subledger_only',
                                 'funding_transaction_id'];
  v_functional text;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'posted' or new.void_journal_entry_id is not null then
      raise exception 'SETTLEMENT_STATE: a settlement is created posted, with its journal attached afterwards';
    end if;
    -- A subledger-only settlement is complete on insert: it must NOT name a
    -- journal (the funding transaction posted it) and must not be flagged for
    -- one later.
    if new.subledger_only and new.journal_entry_id is not null then
      raise exception 'SETTLEMENT_STATE: a subledger-only settlement must not name a journal -- its bank transaction posted the entry';
    end if;
    if not new.subledger_only and new.journal_entry_id is not null then
      raise exception 'SETTLEMENT_STATE: a settlement is created posted, with its journal attached afterwards';
    end if;
    if new.subledger_only and new.funding_transaction_id is null then
      raise exception 'SETTLEMENT_STATE: a subledger-only settlement must name the bank transaction that posted its GL entry';
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
  -- A subledger-only settlement never acquires a journal, and a journalled
  -- settlement cannot be turned into one.
  if new.subledger_only <> old.subledger_only then
    raise exception 'SETTLEMENT_IMMUTABLE: whether a settlement carries its own journal cannot be changed';
  end if;
  if new.funding_transaction_id is distinct from old.funding_transaction_id then
    raise exception 'SETTLEMENT_IMMUTABLE: the funding bank transaction cannot be changed';
  end if;
  if new.journal_entry_id is not null and old.journal_entry_id is null and not old.subledger_only then
    -- normal path: fin_record_settlement attaches the journal it just posted
    null;
  elsif old.subledger_only and new.journal_entry_id is not null then
    raise exception 'SETTLEMENT_IMMUTABLE: a subledger-only settlement cannot acquire a journal';
  end if;
  if old.status = 'void' then
    raise exception 'SETTLEMENT_VOID: a void settlement cannot change';
  end if;
  if new.status = 'void' and (new.void_journal_entry_id is null or new.void_reason is null or new.voided_at is null) then
    raise exception 'SETTLEMENT_VOID: voiding a settlement needs the void journal, a reason and the void time';
  end if;
  return new;
end;
$function$;

-- ---------------------------------------------------------------------
-- 3. The invoice trigger creates the AP open item
-- ---------------------------------------------------------------------
-- Amount: the AP credit actually posted, i.e. amount_incl_vat - wht_amount.
-- Withholding tax is not owed to the supplier, so it is not part of the
-- supplier's open item -- and including it would make the subledger
-- outstanding total disagree with AP control for every WHT invoice.
--
-- Currency and rate: the invoice's own, taken from the journal line the
-- trigger just posted, so a foreign-currency item settles at the rate it was
-- booked at rather than today's rate.
create or replace function trg_post_supplier_invoice()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_expense uuid; v_vat_in uuid; v_wht uuid; v_ap uuid;
  v_net numeric;
  v_ap_amount numeric;
  v_lines jsonb;
  v_je journal_entries%rowtype;
  v_ccy text;
begin
  v_expense := get_posting_account(new.tenant_id, 'default_expense');
  v_ap := get_posting_account(new.tenant_id, 'ap_control');
  if v_expense is null or v_ap is null then
    -- Tenant hasn't set up (or hasn't finished setting up) their
    -- posting rules yet -- skip posting rather than fail the insert.
    return new;
  end if;

  if new.wht_amount > 0 then
    v_wht := get_posting_account(new.tenant_id, 'wht_payable');
    if v_wht is null then
      -- Can't post correctly without knowing where the withheld
      -- amount goes -- skip the whole entry.
      return new;
    end if;
  end if;

  v_net := new.amount_incl_vat - new.vat_amount;
  v_ap_amount := new.amount_incl_vat - new.wht_amount;
  v_ccy := coalesce(nullif(btrim(new.currency), ''), fin_ledger_currency(new.tenant_id));

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_expense, 'debit', v_net, 'currency', new.currency)
  );
  if new.vat_amount > 0 then
    v_vat_in := get_posting_account(new.tenant_id, 'vat_input');
    if v_vat_in is null then
      return new;
    end if;
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_vat_in, 'debit', new.vat_amount, 'currency', new.currency);
  end if;
  if new.wht_amount > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_wht, 'credit', new.wht_amount, 'currency', new.currency);
  end if;
  if v_ap_amount > 0 then
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_ap, 'credit', v_ap_amount, 'currency', new.currency);
  end if;

  v_je := post_journal_entry(new.tenant_id, 'supplier_invoice', new.id, new.invoice_date,
    'Supplier invoice ' || new.invoice_number, v_lines);

  -- The AP side of the subledger. Only when there is something to owe and a
  -- supplier to owe it to: an invoice with no vendor_account_id cannot be
  -- allocated later (fin_allocations_guard matches party to party), so it
  -- stays GL-only and fin_trace_gaps() reports it.
  if v_ap_amount > 0 and new.vendor_account_id is not null and v_je.id is not null then
    perform fin_create_open_item_fx(
      new.tenant_id,
      new.vendor_account_id,
      'ap_control',
      'supplier_invoice',
      new.id,
      new.invoice_number,
      new.invoice_date,
      new.due_date,
      v_ap_amount,
      'Supplier invoice ' || new.invoice_number,
      v_ccy,
      v_je.id
    );
  end if;

  return new;
end;
$function$;

-- ---------------------------------------------------------------------
-- 4. A procurement payment settles the item, without a second journal
-- ---------------------------------------------------------------------
-- Runs after trg_post_cash_bank_transaction (same event, trigger name sorts
-- later so it sees the posted journal). It reads the payment's own journal to
-- learn the functional-currency amount that actually hit AP, so a
-- foreign-currency payment allocates exactly what was relieved -- no
-- rounding drift, no invented rate.
create or replace function trg_settle_supplier_invoice_open_item()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_item     fin_open_items%rowtype;
  v_bank     fin_bank_accounts%rowtype;
  v_ap       uuid;
  v_amount   numeric;
  v_consumed numeric;
  v_settle   fin_settlements%rowtype;
  v_no       text;
begin
  if new.reference_type <> 'supplier_invoice' or new.transaction_type <> 'payment' then
    return new;
  end if;

  select * into v_item
    from fin_open_items
   where tenant_id = new.tenant_id
     and source_type = 'supplier_invoice'
     and source_id = new.reference_id
   for update;
  if not found then
    return new;   -- e.g. the invoice predates this migration, or has no vendor
  end if;
  -- Already settled (by this or another payment)? Nothing to allocate.
  if fin_open_item_consumed(v_item.id) > 0 then
    return new;
  end if;

  -- What this payment actually relieved on AP, in the functional currency.
  v_ap := get_posting_account(new.tenant_id, 'ap_control');
  select coalesce(sum(l.debit - l.credit), 0) into v_amount
    from journal_entries je
    join journal_entry_lines l on l.journal_entry_id = je.id
   where je.tenant_id = new.tenant_id
     and je.source_type = 'cash_bank_transaction'
     and je.source_id = new.id
     and l.gl_account_id = v_ap;
  if v_amount is null or v_amount <= 0 then
    return new;   -- nothing reached AP; leave the item open rather than guess
  end if;

  v_consumed := fin_open_item_consumed(v_item.id);
  if v_consumed + v_amount > v_item.amount + 0.01 then
    -- An overpayment: the subledger cannot hold it against this invoice. The
    -- GL already posted, and refusing the insert here would strand a payment
    -- that the bank made, so the item is left open and the excess is visible
    -- as outstanding. SupplierInvoice screens cap the amount up front.
    return new;
  end if;

  -- The bank account behind a cash/bank transaction is free text (the screen
  -- offers a plain text field), so resolve it by name or account number,
  -- trimmed and case-insensitively. If nothing matches, the allocation is
  -- skipped rather than guessed -- the GL is correct either way, and
  -- fin_trace_gaps() reports the unallocated payment.
  select * into v_bank
    from fin_bank_accounts b
   where b.tenant_id = new.tenant_id
     and b.kind = 'operating'
     and coalesce(btrim(new.bank_account), '') <> ''
     and (lower(b.name) = lower(btrim(new.bank_account))
          or lower(coalesce(b.account_number, '')) = lower(btrim(new.bank_account)))
   order by b.created_at
   limit 1;

  if not found or v_bank.currency <> v_item.currency then
    -- Cannot express the currency or the bank; the item stays open and the
    -- gap report says so. Silently allocating against the wrong account
    -- would be worse than a visible gap.
    return new;
  end if;

  v_no := next_doc_number(new.tenant_id, 'fin_settlement', 'STL');
  insert into fin_settlements (
    tenant_id, settlement_no, direction, bank_account_id, party_account_id,
    amount, currency, settlement_date, reference, notes,
    fx_rate, realised_result, subledger_only, funding_transaction_id
  ) values (
    new.tenant_id, v_no, 'out', v_bank.id, v_item.party_account_id,
    v_amount, v_item.currency, new.transaction_date,
    coalesce(nullif(btrim(new.description), ''), v_item.document_no),
    'Settled by cash/bank transaction ' || new.id::text,
    v_item.fx_rate, 0, true, new.id
  )
  returning * into v_settle;

  insert into fin_allocations (tenant_id, settlement_id, open_item_id, amount)
  values (new.tenant_id, v_settle.id, v_item.id, v_amount);

  -- The settlement records the funding transaction; the open item stays
  -- immutable and its balance is derived from the allocation.
  return new;
end;
$function$;

drop trigger if exists trg_settle_supplier_invoice_open_item on cash_bank_transactions;
create trigger trg_settle_supplier_invoice_open_item
  after insert on cash_bank_transactions
  for each row execute function trg_settle_supplier_invoice_open_item();

-- ---------------------------------------------------------------------
-- 5. fin_trace: procurement now has open_item and settlement hops
-- ---------------------------------------------------------------------
-- The function body is the migration 20261117140000 text with three surgical
-- changes, so nothing else about the trace shifts:
--   (a) the cash/bank hop set also includes the transaction that funded a
--       settlement, so a procurement payment is always on the trace;
--   (b) the cash/bank journal join names its source type;
--   (c) the open-item hop reads fin_open_item_balances.settlement_status and
--       .outstanding_amount. It previously read a non-existent column
--       (b.amount_open), which never fired because no procurement document
--       had an open item to reach that branch -- the same finding E1.
-- The settlement hop already reports journal_id, which is now null for a
-- procurement settlement and says so in its detail line.
create or replace function fin_trace(
  p_entity_type text,
  p_entity_id uuid
)
returns table (
  hop            integer,
  hop_kind       text,
  entity_table   text,
  entity_id      uuid,
  reference      text,
  status         text,
  amount         numeric,
  currency       text,
  journal_id     uuid,
  journal_date   date,
  journal_status text,
  actor          uuid,
  happened_at    timestamptz,
  detail         text
)
language plpgsql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_doc    record;
  v_hop    integer := 0;
  -- Collected along the way so later hops can look backwards.
  v_journal_ids uuid[] := '{}';
  v_open_item_ids uuid[] := '{}';
  v_settlement_ids uuid[] := '{}';
  v_cash_txn_ids uuid[] := '{}';
begin
  ------------------------------------------------------------------
  -- Hop 0: the document itself
  ------------------------------------------------------------------
  if p_entity_type = 'supplier_invoice' then
    select i.id, i.invoice_number as reference, i.invoice_date as doc_date,
           i.amount_incl_vat as amount, i.currency, i.created_at, i.recorded_by as actor,
           i.purchase_order_id as parent_id
      into v_doc
    from supplier_invoices i
    where i.id = p_entity_id
      and i.tenant_id = get_my_tenant_id();

  elsif p_entity_type = 'receivable_invoice' then
    select i.id, i.invoice_number, i.invoice_date,
           i.amount_incl_vat, i.currency, i.created_at, null::uuid, null::uuid
      into v_doc
    from receivable_invoices i
    where i.id = p_entity_id
      and i.tenant_id = get_my_tenant_id();

  elsif p_entity_type = 'fin_settlement' then
    select s.id, s.settlement_no, s.settlement_date,
           s.amount, s.currency, s.created_at, s.created_by, null::uuid
      into v_doc
    from fin_settlements s
    where s.id = p_entity_id
      and s.tenant_id = get_my_tenant_id();

  elsif p_entity_type = 'cash_bank_transaction' then
    select t.id, coalesce(t.reference_type, 'cash_bank_transaction'), t.transaction_date,
           t.amount, t.currency, t.created_at, t.recorded_by, t.reference_id
      into v_doc
    from cash_bank_transactions t
    where t.id = p_entity_id
      and t.tenant_id = get_my_tenant_id();

  elsif p_entity_type = 'ins_policy' then
    select p.id, p.policy_no, p.created_at::date,
           null::numeric, null::text, p.created_at, null::uuid, null::uuid
      into v_doc
    from ins_policies p
    where p.id = p_entity_id
      and p.tenant_id = get_my_tenant_id();

  else
    raise exception 'fin_trace: unsupported entity type % (supported: supplier_invoice, receivable_invoice, fin_settlement, cash_bank_transaction, ins_policy)', p_entity_type;
  end if;

  if v_doc.id is null then
    raise exception 'fin_trace: % % not found for your company', p_entity_type, p_entity_id;
  end if;

  v_hop := v_hop + 1;
  hop := v_hop; hop_kind := 'document'; entity_table := p_entity_type; entity_id := v_doc.id;
  reference := v_doc.reference; status := 'recorded'; amount := v_doc.amount; currency := v_doc.currency;
  journal_id := null; journal_date := null; journal_status := null;
  actor := v_doc.actor; happened_at := v_doc.created_at;
  detail := format('document dated %s', v_doc.doc_date);
  return next;

  -- The purchase order behind a supplier invoice, when there is one.
  if v_doc.parent_id is not null and p_entity_type = 'supplier_invoice' then
    v_hop := v_hop + 1;
    select po.id, po.po_number, po.amount, po.currency, po.generated_at, po.generated_by
      into v_doc
    -- purchase_orders carries no tenant_id; it is scoped through its request.
    from purchase_orders po
    join requests rq on rq.id = po.request_id
    where po.id = v_doc.parent_id
      and rq.tenant_id = get_my_tenant_id();
    if found then
      hop := v_hop; hop_kind := 'purchase_order'; entity_table := 'purchase_orders'; entity_id := v_doc.id;
      reference := v_doc.reference; status := 'issued'; amount := v_doc.amount; currency := v_doc.currency;
      journal_id := null; journal_date := null; journal_status := null;
      actor := v_doc.generated_by; happened_at := v_doc.generated_at;
      detail := 'purchase order the invoice was raised against';
      return next;
    end if;
  end if;

  ------------------------------------------------------------------
  -- Hops: journal entries for the document (original + reversal)
  ------------------------------------------------------------------
  v_journal_ids := array(
    select je.id from journal_entries je
    where je.tenant_id = get_my_tenant_id()
      and je.source_id = p_entity_id
    union
    select je.id from journal_entries je
    where je.tenant_id = get_my_tenant_id()
      and je.source_type = 'manual'
      and je.description like 'Reversal of %'
      and je.source_id is null
      and exists (
        select 1 from journal_entries o
        where o.tenant_id = je.tenant_id
          and o.source_id = p_entity_id
          and je.description like '%' || o.id::text || '%'
      )
  );

  if array_length(v_journal_ids, 1) > 0 then
    return query
      select (v_hop + row_number() over (order by je.created_at, je.id))::integer,
             'journal'::text,
             'journal_entries'::text,
             je.id,
             coalesce(je.description, je.source_type),
             je.status,
             (select coalesce(sum(l.debit), 0) from journal_entry_lines l where l.journal_entry_id = je.id),
             (select min(l.currency) from journal_entry_lines l where l.journal_entry_id = je.id),
             je.id,
             je.entry_date,
             je.status,
             je.posted_by,
             je.created_at,
             case when je.status = 'void'
                  then format('reversed %s%s', coalesce(je.voided_at::text, '(void time not recorded)'),
                              coalesce(' — ' || je.void_reason, ''))
                  else format('source_type=%s', je.source_type) end
      from journal_entries je
      where je.id = any (v_journal_ids);
    v_hop := v_hop + array_length(v_journal_ids, 1);
  end if;

  ------------------------------------------------------------------
  -- Hops: cash/bank transactions paying or receiving against the document
  ------------------------------------------------------------------
  v_cash_txn_ids := array(
    select t.id from cash_bank_transactions t
    where t.tenant_id = get_my_tenant_id()
      and t.reference_id = p_entity_id
      and t.reference_type = p_entity_type
  );

  -- Settlements allocated to this document (through its open items).
  v_open_item_ids := array(
    select oi.id from fin_open_items oi
    where oi.tenant_id = get_my_tenant_id()
      and oi.source_type = p_entity_type
      and oi.source_id = p_entity_id
  );

  v_settlement_ids := array(
    select distinct a.settlement_id from fin_allocations a
    where a.open_item_id = any (v_open_item_ids)
  );

  -- A settlement can name the cash/bank transaction that carried it out
  -- (procurement payments settle through a subledger-only allocation). Fold
  -- those payments into the cash/bank hops so the money leg is on the trace
  -- even when the transaction does not carry the document as its reference.
  v_cash_txn_ids := v_cash_txn_ids || coalesce(array(
    select s.funding_transaction_id from fin_settlements s
    where s.id = any (v_settlement_ids) and s.funding_transaction_id is not null
  ), '{}');

  if array_length(v_cash_txn_ids, 1) > 0 then
    return query
      select (v_hop + row_number() over (order by t.created_at, t.id))::integer,
             'cash_bank'::text,
             'cash_bank_transactions'::text,
             t.id,
             coalesce(t.description, t.id::text),
             t.transaction_type,
             t.amount,
             t.currency,
             je.id,
             je.entry_date,
             je.status,
             t.recorded_by,
             t.created_at,
             format('payment_method=%s, bank_account=%s', t.payment_method, coalesce(t.bank_account, '—'))
      from cash_bank_transactions t
      left join journal_entries je
        on je.tenant_id = t.tenant_id
       and je.source_type = 'cash_bank_transaction'
       and je.source_id = t.id
      where t.id = any (v_cash_txn_ids);
    v_hop := v_hop + array_length(v_cash_txn_ids, 1);
  end if;

  ------------------------------------------------------------------
  -- Hops: open items (null for procurement -- see the header note)
  ------------------------------------------------------------------
  if array_length(v_open_item_ids, 1) > 0 then
    return query
      select (v_hop + row_number() over (order by oi.created_at, oi.id))::integer,
             'open_item'::text,
             'fin_open_items'::text,
             oi.id,
             oi.document_no,
             coalesce(b.settlement_status, 'open'),
             oi.amount,
             oi.currency,
             je.id,
             je.entry_date,
             je.status,
             oi.created_by,
             oi.created_at,
             format('control_role=%s, side=%s, outstanding=%s of %s', oi.control_role, oi.side,
                    coalesce(b.outstanding_amount, oi.amount), oi.amount)
      from fin_open_items oi
      left join journal_entries je
        on je.tenant_id = oi.tenant_id and je.id = oi.journal_entry_id
      left join fin_open_item_balances b
        on b.id = oi.id
      where oi.id = any (v_open_item_ids);
    v_hop := v_hop + array_length(v_open_item_ids, 1);
  end if;

  ------------------------------------------------------------------
  -- Hops: settlements
  ------------------------------------------------------------------
  if array_length(v_settlement_ids, 1) > 0 then
    return query
      select (v_hop + row_number() over (order by s.created_at, s.id))::integer,
             'settlement'::text,
             'fin_settlements'::text,
             s.id,
             s.settlement_no,
             s.status,
             s.amount,
             s.currency,
             je.id,
             je.entry_date,
             je.status,
             s.created_by,
             s.created_at,
             format('direction=%s, reference=%s%s', s.direction, coalesce(s.reference, '—'),
                    case when s.subledger_only
                         then ', allocation only: the funding bank transaction posted the GL entry'
                         else ', settled through fin_record_settlement, which posted its own journal' end)
      from fin_settlements s
      left join journal_entries je
        on je.tenant_id = s.tenant_id and je.id = s.journal_entry_id
      where s.id = any (v_settlement_ids);
    v_hop := v_hop + array_length(v_settlement_ids, 1);
  end if;

  ------------------------------------------------------------------
  -- Hops: bank statement match (there or not -- the absence is the point)
  ------------------------------------------------------------------
  return query
    select (v_hop + row_number() over (order by r.matched_at, r.id))::integer,
           'bank_match'::text,
           'bank_reconciliations'::text,
           r.id,
           sl.reference,
           case when r.variance = 0 then 'matched' else 'matched_with_variance' end,
           sl.amount,
           sl.currency,
           null::uuid,
           sl.statement_date,
           null::text,
           r.matched_by,
           r.matched_at,
           format('match_type=%s, variance=%s, bank_account=%s',
                  r.match_type, r.variance, coalesce(sl.bank_account, '—'))
    from bank_reconciliations r
    join bank_statement_lines sl on sl.id = r.bank_statement_line_id
    where r.tenant_id = get_my_tenant_id()
      and (r.cash_bank_transaction_id = any (v_cash_txn_ids)
           or r.settlement_id = any (v_settlement_ids));
  v_hop := v_hop + coalesce((
    select count(*) from bank_reconciliations r
    where r.tenant_id = get_my_tenant_id()
      and (r.cash_bank_transaction_id = any (v_cash_txn_ids)
           or r.settlement_id = any (v_settlement_ids))
  ), 0);

  ------------------------------------------------------------------
  -- Final hop: which accounting period the postings landed in, and its state
  ------------------------------------------------------------------
  return query
    select (v_hop + row_number() over (order by ap.period_start))::integer,
           'accounting_period'::text,
           'accounting_periods'::text,
           ap.id,
           ap.period_start::text || ' to ' || ap.period_end::text,
           ap.status,
           null::numeric,
           v_doc.currency,
           null::uuid,
           ap.period_end,
           ap.status,
           ap.closed_by,
           ap.closed_at,
           format('%s journal entr%s in this period', count(je.id),
                  case when count(je.id) = 1 then 'y' else 'ies' end)
    from accounting_periods ap
    join journal_entries je
      on je.tenant_id = ap.tenant_id
     and je.entry_date between ap.period_start and ap.period_end
    where ap.tenant_id = get_my_tenant_id()
      and je.id = any (v_journal_ids)
    group by ap.id, ap.period_start, ap.period_end, ap.status, ap.closed_by, ap.closed_at;

  return;
end;
$function$;

comment on function fin_trace(text, uuid) is
  'One row per hop of a document''s financial life: document -> purchase order -> '
  'journal entries (incl. reversals) -> cash/bank payments -> open items -> '
  'settlements -> bank statement match -> accounting period state. Security '
  'invoker, so RLS applies to the caller. Note: procurement payments do not '
  'create fin_open_items, so their trace stops at the bank match (finding E1).';

-- ---------------------------------------------------------------------
-- 6. fin_trace_gaps: report the subledger gaps that remain
-- ---------------------------------------------------------------------
create or replace function fin_trace_gaps(p_tenant_id uuid default null)
returns table (
  entity_type text,
  entity_id   uuid,
  reference   text,
  gap         text
)
language sql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
  with t as (
    select coalesce(p_tenant_id, get_my_tenant_id()) as tenant_id
  )
  -- Supplier invoices with no journal at all: nothing reached the GL.
  select 'supplier_invoice'::text, i.id, i.invoice_number,
         'no journal entry posted'::text
  from supplier_invoices i, t
  where i.tenant_id = t.tenant_id
    and not exists (
      select 1 from journal_entries je
      where je.tenant_id = i.tenant_id and je.source_id = i.id
    )

  union all
  -- Posted invoices that have no open item: their AP balance is invisible to
  -- the subledger. Includes invoices with no vendor, which cannot be settled.
  select 'supplier_invoice'::text, i.id, i.invoice_number,
         case when i.vendor_account_id is null
              then 'posted but has no supplier account, so it has no open item'
              else 'posted but has no open item' end
  from supplier_invoices i, t
  where i.tenant_id = t.tenant_id
    and exists (
      select 1 from journal_entries je
      where je.tenant_id = i.tenant_id and je.source_id = i.id
    )
    and not exists (
      select 1 from fin_open_items oi
      where oi.tenant_id = i.tenant_id
        and oi.source_type = 'supplier_invoice'
        and oi.source_id = i.id
    )

  union all
  -- Payments against a supplier invoice that no statement line matches.
  select 'cash_bank_transaction'::text, c.id, coalesce(c.description, c.id::text),
         'payment not matched to a bank statement line'::text
  from cash_bank_transactions c, t
  where c.tenant_id = t.tenant_id
    and c.reference_type = 'supplier_invoice'
    and c.payment_method = 'bank'
    and not exists (
      select 1 from bank_reconciliations r
      where r.tenant_id = c.tenant_id and r.cash_bank_transaction_id = c.id
    )

  union all
  -- Payments that relieved AP but were not recorded against the open item.
  select 'cash_bank_transaction'::text, c.id, coalesce(c.description, c.id::text),
         'payment is not allocated to its open item'::text
  from cash_bank_transactions c, t
  where c.tenant_id = t.tenant_id
    and c.reference_type = 'supplier_invoice'
    and c.transaction_type = 'payment'
    and exists (
      select 1 from fin_open_items oi
      where oi.tenant_id = c.tenant_id
        and oi.source_type = 'supplier_invoice'
        and oi.source_id = c.reference_id
    )
    and not exists (
      select 1 from fin_allocations a
      join fin_settlements s on s.id = a.settlement_id
      join fin_open_items oi on oi.id = a.open_item_id
      where oi.tenant_id = c.tenant_id
        and oi.source_type = 'supplier_invoice'
        and oi.source_id = c.reference_id
        and s.funding_transaction_id = c.id
    )

  union all
  -- Bank movements matched but still showing a variance.
  select 'cash_bank_transaction'::text, c.id, coalesce(c.description, c.id::text),
         format('matched with variance %s', r.variance)
  from bank_reconciliations r
  join cash_bank_transactions c on c.id = r.cash_bank_transaction_id, t
  where r.tenant_id = t.tenant_id
    and r.variance <> 0

  union all
  -- Postings dated inside a closed period: should be impossible, so any row
  -- here means the guard was bypassed.
  select 'journal_entry'::text, je.id, coalesce(je.description, je.id::text),
         'posted inside a closed accounting period'::text
  from journal_entries je
  join accounting_periods ap
    on ap.tenant_id = je.tenant_id
   and je.entry_date between ap.period_start and ap.period_end
   and ap.status = 'closed', t
  where je.tenant_id = t.tenant_id;
$function$;

revoke all on function fin_trace_gaps(uuid) from public;
grant execute on function fin_trace_gaps(uuid) to authenticated, service_role;

comment on function fin_trace(text, uuid) is
  'One row per hop of a document''s financial life: document -> purchase order -> '
  'journals (with reversals) -> cash/bank -> open items -> settlements -> bank '
  'statement match -> accounting period state. Security invoker, so RLS applies '
  'to the caller. Procurement is wired into the subledger as of '
  '20261117150000 (finding E1): its payments settle an AP open item through a '
  'subledger-only settlement, and the payment''s own journal is the only GL entry.';
