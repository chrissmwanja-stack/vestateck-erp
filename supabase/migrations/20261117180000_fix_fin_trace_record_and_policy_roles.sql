-- Fix-forward for the finance-gap-closure branch (2026-11-17).
--
-- 1. MIGRATION_POLICY rule 10: two policies in 20261117130000 and 20261117160000
--    named no role. Those files now say `to authenticated`; this migration
--    re-asserts both policies so a database that already ran the old text ends
--    up identical to a fresh replay.
--
-- 2. fin_trace(text, uuid) (defined in 20261117140000, replaced in 20261117150000)
--    read v_doc.reference / .amount / .actor / .doc_date / .parent_id, but only the
--    supplier_invoice branch aliased those columns. Every other entity type
--    produced a record with the source column names (invoice_number,
--    amount_incl_vat, ...), so the first v_doc.reference raised "record v_doc has
--    no field reference" at runtime. plpgsql_check reported it in CI. All branches
--    now alias the same eight fields. The purchase-order hop also reused v_doc,
--    which overwrote the invoice record (and the later v_doc.currency); it now has
--    its own v_po. Signature, security and grants are unchanged (create or replace).

drop policy if exists accounting_period_events_select on accounting_period_events;
create policy accounting_period_events_select on accounting_period_events
  for select
  to authenticated
  using (is_finance_team_member(null) and tenant_id = get_my_tenant_id());

drop policy if exists fin_transaction_actors_select on fin_transaction_actors;
create policy fin_transaction_actors_select on fin_transaction_actors
  for select to authenticated
  using (tenant_id = get_my_tenant_id() and is_finance_team_member(null));

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
  v_po     record;
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
    select i.id, i.invoice_number as reference, i.invoice_date as doc_date,
           i.amount_incl_vat as amount, i.currency, i.created_at, null::uuid as actor, null::uuid as parent_id
      into v_doc
    from receivable_invoices i
    where i.id = p_entity_id
      and i.tenant_id = get_my_tenant_id();

  elsif p_entity_type = 'fin_settlement' then
    select s.id, s.settlement_no as reference, s.settlement_date as doc_date,
           s.amount, s.currency, s.created_at, s.created_by as actor, null::uuid as parent_id
      into v_doc
    from fin_settlements s
    where s.id = p_entity_id
      and s.tenant_id = get_my_tenant_id();

  elsif p_entity_type = 'cash_bank_transaction' then
    select t.id, coalesce(t.reference_type, 'cash_bank_transaction') as reference, t.transaction_date as doc_date,
           t.amount, t.currency, t.created_at, t.recorded_by as actor, t.reference_id as parent_id
      into v_doc
    from cash_bank_transactions t
    where t.id = p_entity_id
      and t.tenant_id = get_my_tenant_id();

  elsif p_entity_type = 'ins_policy' then
    select p.id, p.policy_no as reference, p.created_at::date as doc_date,
           null::numeric as amount, null::text as currency, p.created_at, null::uuid as actor, null::uuid as parent_id
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
    select po.id, po.po_number as reference, po.amount, po.currency, po.generated_at, po.generated_by
      into v_po
    -- purchase_orders carries no tenant_id; it is scoped through its request.
    from purchase_orders po
    join requests rq on rq.id = po.request_id
    where po.id = v_doc.parent_id
      and rq.tenant_id = get_my_tenant_id();
    if found then
      hop := v_hop; hop_kind := 'purchase_order'; entity_table := 'purchase_orders'; entity_id := v_po.id;
      reference := v_po.reference; status := 'issued'; amount := v_po.amount; currency := v_po.currency;
      journal_id := null; journal_date := null; journal_status := null;
      actor := v_po.generated_by; happened_at := v_po.generated_at;
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
