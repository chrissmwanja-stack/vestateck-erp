-- =====================================================================
-- Finance E: end-to-end finance trace
-- =====================================================================
--
-- WHAT THIS IS FOR
--
-- Items A and D each closed a control gap, but nothing could answer the
-- question an auditor actually asks: "show me one payment, all the way
-- down". Every hop existed and was tested in isolation; the chain between
-- them was not queryable in one place.
--
-- fin_trace(p_entity_type, p_entity_id) walks a document's whole financial
-- life and returns one row per hop:
--
--   document -> journal entries (and their reversals) -> open items ->
--   settlements / allocations -> bank statement match -> period state
--
-- It is a read-only, SECURITY INVOKER function: RLS on each underlying
-- table still applies to the caller, so it cannot become a way to see
-- another tenant's rows.
--
-- HONEST LIMITATION, FOUND WHILE BUILDING THIS
--
-- There are two parallel payment mechanisms in the platform and they do
-- NOT meet for procurement:
--
--   (a) Procurement payments are `cash_bank_transactions` rows with
--       reference_type = 'supplier_invoice'. trg_post_cash_bank_transaction
--       posts the journal (Dr AP / Cr Bank, plus realised FX) but does
--       NOT create a fin_open_items row, and nothing in the repository
--       calls fin_create_open_item for procurement.
--
--   (b) The open-item subledger (fin_open_items / fin_settlements /
--       fin_allocations), which is used by insurance and by the Finance
--       "settlements" screens, also posts its own journal per settlement.
--
-- So for a procurement document the trace stops at the bank match, and
-- `open_item_id` is null. For an insurance document (bound via
-- platform_ins_bind_policy_*) the trace runs the full length. That gap is
-- a design question, not something a helper should paper over -- it is
-- reported in the hop output rather than hidden, and recorded as finding
-- E1 in docs/handoffs/FINANCE_E_END_TO_END_TRACE.md.
--
-- A second, related consequence: when the payment is also booked as a
-- settlement, the same economic event is journaled twice. The trace makes
-- that visible (two journal entries against one document), which is how I
-- found it.
--
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. The trace
-- ---------------------------------------------------------------------
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
        on je.tenant_id = t.tenant_id and je.source_id = t.id
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
             case when b.amount_open <= 0 then 'settled' else 'open' end,
             oi.amount,
             oi.currency,
             je.id,
             je.entry_date,
             je.status,
             oi.created_by,
             oi.created_at,
             format('control_role=%s, side=%s, open=%s', oi.control_role, oi.side, coalesce(b.amount_open, oi.amount))
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
             format('direction=%s, reference=%s', s.direction, coalesce(s.reference, '—'))
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

revoke all on function fin_trace(text, uuid) from public;
grant execute on function fin_trace(text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. A completeness check, for the integration test to assert on
-- ---------------------------------------------------------------------
-- fin_trace_gaps() lists documents whose money flow is not fully accounted
-- for. Cheap enough to run in CI on the seeded stack; useful later as an
-- operator report.
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

commit;
