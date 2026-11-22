-- =====================================================================
-- Endorsement-item settlement workflow
-- =====================================================================
-- The app could post an endorsement and it would leave real items behind
-- (an AR item to collect, insurer payables to pay, recovery items). Nothing
-- exposed a way to settle or reverse those items, so a posted endorsement
-- was effectively un-cancelable: the cancellation refuses to move money it
-- cannot understand, and there was no supported path to free the items
-- except dropping to raw SQL.
--
-- This migration makes the supported path:
--
--   1. ins_endorsement_settlement_position(uuid) -- what is open on an
--      endorsement, and what settlements are already against it. Read-only,
--      for the screen that lists the items and offers the settle/void actions.
--   2. ins_endorsement_unwind_position(uuid) -- reports, per settled item,
--      WHICH settlement moved the money, so the cancellation refusal says
--      "void settlement STL-0007 first" instead of a vague "reverse that
--      movement".
--   3. ins_commission_on_settlement_voided() -- recognition reversal for the
--      additional-side insurer item. Settling such an item earns commission
--      (ins_commission_on_settlement_posted covers it), but the void trigger
--      never matched that item type, so voiding a settlement of an endorsed
--      insurer share would leave the commission earned forever.
--
-- The settlement and void actions themselves are the existing finance-gated
-- RPCs (fin_record_settlement / fin_void_settlement), driven by the screen.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Read model: what a posted endorsement still owes, and what has
--    settled it.
-- ---------------------------------------------------------------------
create or replace function public.ins_endorsement_settlement_position(p_endorsement_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  c           public.ins_policy_endorsements%rowtype;
  p           public.ins_policies%rowtype;
  v_item_ids  uuid[];
  v_items     jsonb;
  v_settlements jsonb;
begin
  if auth.uid() is null or not (public.can_manage_insurance() or public.is_finance_team_member('finance')) then
    raise exception 'INS_FORBIDDEN' using errcode = '42501';
  end if;
  select * into c from public.ins_policy_endorsements
   where id = p_endorsement_id and tenant_id = public.get_my_tenant_id();
  if not found then raise exception 'INS_NOT_FOUND: endorsement'; end if;
  select * into p from public.ins_policies where id = c.policy_id and tenant_id = c.tenant_id;

  -- The same item set the cancellation engine is willing to reverse.
  select coalesce(array_agg(i.id), '{}')
    into v_item_ids
    from public.fin_open_items i
   where i.tenant_id = c.tenant_id
     and ( (i.source_type = 'ins_policy_endorsement' and i.source_id = c.id)
        -- Insurer items are keyed by their commission entry (E2), so the
        -- endorsement's commission entry ids find them.
        or (i.source_type = 'ins_policy_endorsement_insurer'
            and i.source_id = any (coalesce((select array_agg((x #>> '{}')::uuid)
                                                 from jsonb_array_elements(coalesce(c.commission_entry_ids,'[]'::jsonb)) x), '{}')))
        or (i.source_type in ('ins_policy_endorsement_recovery','ins_policy_endorsement_recovery_insurer')
            and i.source_id = c.id) );

  -- Open items, with what remains and who the counterparty is.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id,
           'source_type', i.source_type,
           'document_no', i.document_no,
           'control_role', i.control_role,
           'side', i.side,
           'amount', i.amount,
           'outstanding', coalesce(b.outstanding_amount, i.amount),
           'currency', i.currency,
           'party_account_id', i.party_account_id,
           'party_name', coalesce(a.name, 'Unknown counterparty'),
           'settlement_status', coalesce(b.settlement_status, 'open')
         ) order by i.id), '[]'::jsonb)
    into v_items
    from public.fin_open_items i
    left join public.fin_open_item_balances b on b.id = i.id
    left join public.accounts a on a.id = i.party_account_id and a.tenant_id = i.tenant_id
   where i.id = any (v_item_ids);

  -- Posted settlements touching any of those items.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id,
           'settlement_no', s.settlement_no,
           'direction', s.direction,
           'amount', s.amount,
           'currency', s.currency,
           'settlement_date', s.settlement_date,
           'reference', s.reference,
           'status', s.status,
           'party_account_id', s.party_account_id,
           'party_name', coalesce(s.party_name, 'Unknown counterparty'),
           'reconciled', exists (select 1 from public.bank_reconciliations r
                                  where r.settlement_id = s.id and r.tenant_id = s.tenant_id)
         ) order by s.settlement_date, s.settlement_no), '[]'::jsonb)
    into v_settlements
    from (select distinct s.id, s.settlement_no, s.direction, s.amount, s.currency, s.settlement_date,
                 s.reference, s.status, s.party_account_id, a.name as party_name
            from public.fin_settlements s
            join public.fin_allocations al on al.settlement_id = s.id and al.tenant_id = s.tenant_id
            left join public.accounts a on a.id = s.party_account_id and a.tenant_id = s.tenant_id
           where s.tenant_id = c.tenant_id
             and s.status = 'posted'
             and al.open_item_id = any (v_item_ids)) s;

  return jsonb_build_object(
    'endorsement_id', c.id,
    'endorsement_no', c.endorsement_no,
    'policy_id', p.id,
    'policy_no', p.policy_no,
    'currency', p.currency,
    'status', c.status,
    'items', v_items,
    'settlements', v_settlements);
end $$;

revoke all on function public.ins_endorsement_settlement_position(uuid) from public, anon;
grant execute on function public.ins_endorsement_settlement_position(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Unwind position: the refusal must name the settlement, not just
--    "settle or refund it first".
-- ---------------------------------------------------------------------
create or replace function public.ins_endorsement_unwind_position(p_endorsement_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  c public.ins_policy_endorsements%rowtype;
  p public.ins_policies%rowtype;
  v_reasons text[] := '{}';
  v_item record;
  v_total numeric := 0;
  v_own_credit numeric := 0;
  v_settlements text[];
begin
  if auth.uid() is null or not (public.can_manage_insurance() or public.is_finance_team_member('finance')) then
    raise exception 'INS_FORBIDDEN' using errcode = '42501';
  end if;
  select * into c from public.ins_policy_endorsements
   where id = p_endorsement_id and tenant_id = public.get_my_tenant_id();
  if not found then raise exception 'INS_NOT_FOUND: endorsement'; end if;
  select * into p from public.ins_policies where id = c.policy_id and tenant_id = c.tenant_id;

  if c.status = 'cancelled' then
    return jsonb_build_object('eligible', false, 'already_cancelled', true,
      'reasons', to_jsonb(array['this endorsement has already been cancelled']));
  end if;
  if c.status <> 'posted' then
    return jsonb_build_object('eligible', false, 'already_cancelled', false,
      'reasons', to_jsonb(array[
        'only a posted endorsement can be cancelled; this one is ' || c.status ||
        case when c.status in ('proposed','prepared') then ' -- withdraw it instead, which posts nothing'
             when c.status = 'posting' then ' -- it is mid-posting, which must finish or fail first'
             else '' end]));
  end if;

  -- A cancellation already in flight owns the policy's position; unwinding an
  -- endorsement underneath it would change what the cancellation is calculating.
  if exists (select 1 from public.ins_policy_cancellations x
              where x.policy_id = c.policy_id and x.tenant_id = c.tenant_id
                and x.status in ('proposed','prepared','posting')) then
    v_reasons := v_reasons || array['this policy has a cancellation in flight; finish or withdraw it before unwinding endorsements'];
  end if;

  -- Only the newest *financial* endorsement may be unwound. A later posting may have
  -- been calculated against this one's position, and unspooling the middle of the
  -- sequence would leave the later documents describing a policy that no longer
  -- exists. Newest-first is LIFO, and it is the only order that keeps every
  -- intermediate state real.
  if exists (select 1 from public.ins_policy_endorsements x
              where x.policy_id = c.policy_id and x.tenant_id = c.tenant_id
                and x.status = 'posted' and x.id <> c.id
                and coalesce((x.calculation ->> 'premium_delta')::numeric, 0) <> 0
                and x.endorsement_no collate "C" > c.endorsement_no collate "C") then
    v_reasons := v_reasons || array['a later posted endorsement carries a premium change; cancel the newest one first'];
  end if;

  -- The money must not have moved. Every item this endorsement created has to be
  -- untouched: unconsumed by any settlement, uncredited by any live note.
  for v_item in
    select i.id, i.amount, i.control_role, b.outstanding_amount,
           coalesce(b.allocated_amount, 0) + coalesce(b.credited_amount, 0) as consumed_amount,
           coalesce((select array_agg(s.settlement_no order by s.settlement_date, s.settlement_no)
                      from public.fin_allocations al
                      join public.fin_settlements s on s.id = al.settlement_id
                     where al.open_item_id = i.id and s.status = 'posted'), '{}') as settlements
      from public.fin_open_items i
      left join public.fin_open_item_balances b on b.id = i.id
     where i.tenant_id = c.tenant_id
       and ( (i.source_type = 'ins_policy_endorsement' and i.source_id = c.id)
          -- Insurer items are keyed by their commission entry (see E2)
          or (i.source_type = 'ins_policy_endorsement_insurer'
              and i.source_id = any (coalesce((select array_agg((x #>> '{}')::uuid)
                                                 from jsonb_array_elements(coalesce(c.commission_entry_ids,'[]'::jsonb)) x), '{}')))
          or (i.source_type in ('ins_policy_endorsement_recovery','ins_policy_endorsement_recovery_insurer')
              and i.source_id = c.id) )
     order by i.id
  loop
    v_total := v_total + coalesce(v_item.outstanding_amount, 0);
    -- Credit applied by THIS endorsement's own notes does not count as movement: the
    -- cancellation voids those notes, and that is how the items are freed. Only
    -- settlement, or somebody else's credit note, locks the item.
    select coalesce(sum(ca.amount), 0) into v_own_credit
      from public.fin_credit_applications ca
      join public.fin_credit_notes n on n.id = ca.credit_note_id
     where ca.open_item_id = v_item.id and n.status = 'posted'
       and n.id in (select (x ->> 'note_id')::uuid
                      from jsonb_array_elements(coalesce(c.credit_note_ids, '[]'::jsonb)) x);
    if coalesce(v_item.consumed_amount, 0) - v_own_credit <> 0 then
      v_settlements := v_item.settlements;
      if cardinality(coalesce(v_settlements, '{}')) > 0 then
        v_reasons := v_reasons || format(
          'the endorsement''s %s item has been settled by %s; void that settlement first, then cancel this endorsement',
          v_item.control_role, array_to_string(v_settlements, ', '))::text;
      else
        v_reasons := v_reasons || format(
          'the endorsement''s %s item has already been credited by something other than this endorsement (%s outstanding); reverse that movement first',
          v_item.control_role, v_item.outstanding_amount)::text;
      end if;
    end if;
  end loop;

  -- The endorsement's own credit notes are deliberately NOT a blocker: voiding them is
  -- what this cancellation does, and refusing because they exist would make every
  -- return endorsement permanently un-cancellable. A note belonging to anything else
  -- still blocks, through the item check above.

  -- Commission: a transfer to the agent means the commission left the company's
  -- books, and clawing it back is a different conversation (a recovery, not a
  -- reversal). Any commission entry created by this endorsement that has been
  -- transferred blocks the unwind.
  if exists (select 1
               from public.ins_commission_entries e
              where e.tenant_id = c.tenant_id
                and e.id in (select (x #>> '{}')::uuid from jsonb_array_elements(coalesce(c.commission_entry_ids,'[]'::jsonb)) x)
                and e.transfer_id is not null) then
    v_reasons := v_reasons || array['commission from this endorsement has been transferred to the operating account; void that commission transfer first'];
  end if;

  -- A closed period cannot take a new journal (same rule every posting path applies).
  if exists (select 1 from public.accounting_periods
              where tenant_id = c.tenant_id and status = 'closed'
                and current_date between period_start and period_end) then
    v_reasons := v_reasons || array['the current accounting period is closed'];
  end if;

  -- Report the amount that would be cleared, so the approver sees it before deciding.
  return jsonb_build_object(
    'eligible', cardinality(v_reasons) = 0,
    'already_cancelled', false,
    'endorsement_id', c.id,
    'endorsement_no', c.endorsement_no,
    'policy_id', p.id,
    'policy_no', p.policy_no,
    'currency', p.currency,
    'premium_delta', coalesce((c.calculation ->> 'premium_delta')::numeric, 0),
    'commission_delta', coalesce((c.calculation ->> 'commission_delta')::numeric, 0),
    'commission_deferred_at_posting', coalesce((select sum(e.amount) from public.ins_commission_entries e
                                                 where e.tenant_id = c.tenant_id
                                                   and e.id = any (coalesce((select array_agg((x #>> '{}')::uuid)
                                                       from jsonb_array_elements(coalesce(c.commission_entry_ids,'[]'::jsonb)) x), '{}'))), 0),
    'open_amount_to_clear', v_total,
    'reasons', to_jsonb(v_reasons));
end $$;

revoke all on function public.ins_endorsement_unwind_position(uuid) from public, anon;
grant execute on function public.ins_endorsement_unwind_position(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Voiding a settlement must reverse the commission an endorsed
--    insurer share earned. The posted trigger covers the endorsement
--    insurer item; the void trigger only knew the two bind-level item
--    types, so a settlement voided after earned recognition left the
--    commission earned forever.
-- ---------------------------------------------------------------------
create or replace function public.ins_commission_on_settlement_voided()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  r          record;
  v_unearned uuid;
  v_income   uuid;
  v_ev       uuid;
  v_je       journal_entries;
  v_date     date;
  v_rec_je   uuid;
  v_lines    jsonb;
begin
  if exists(select 1 from ins_cancellation_cash_requests where new.id in(settlement_id,to_settlement_id)) then return new; end if;
  if new.direction <> 'out' or old.status <> 'posted' or new.status <> 'void' then
    return new;
  end if;

  select entry_date into v_date from journal_entries where id = new.void_journal_entry_id;
  v_date := coalesce(v_date, current_date);

  for r in
    select e.id as entry_id, e.amount, e.status as entry_status, e.earned_by,
           p.policy_no, i.currency as item_currency
    from fin_allocations al
    join fin_open_items i  on i.id = al.open_item_id and i.source_type in ('ins_policy_insurer','ins_policy_share_insurer','ins_policy_endorsement_insurer')
    join ins_commission_entries e on ((e.id = i.source_id and i.source_type = 'ins_policy_endorsement_insurer')
          or (e.insurer_share_id = i.source_id and i.source_type = 'ins_policy_share_insurer')
          or (e.policy_id = i.source_id and e.insurer_share_id is null and i.source_type = 'ins_policy_insurer'))
           and e.tenant_id = i.tenant_id
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

    -- Earned at placement: this payment did not earn it, so voiding the payment
    -- does not un-earn it. Skip it entirely -- no journal, no event, no status
    -- change. (Rows that predate earned_by cannot be at_placement, so null here
    -- means a legacy settlement recognition and falls through.)
    if r.earned_by = 'placement' then
      continue;
    end if;

    v_unearned := get_posting_account(new.tenant_id, 'unearned_commission');
    v_income   := get_posting_account(new.tenant_id, 'commission_income');
    if v_unearned is null or v_income is null then
      raise exception 'INS_POSTING_RULE_MISSING: reversing commission on % needs the unearned_commission and commission_income posting rules', r.policy_no;
    end if;

    v_ev := gen_random_uuid();
    if r.item_currency is distinct from fin_ledger_currency(new.tenant_id) then
      select journal_entry_id into v_rec_je
        from ins_commission_events
       where entry_id = r.entry_id and event = 'recognised' and journal_entry_id is not null
       order by created_at desc
       limit 1;
      if v_rec_je is null then
        raise exception 'INS_COMMISSION_RATE: reversing commission on % needs its recognition journal', r.policy_no;
      end if;
      select jsonb_agg(jsonb_build_object(
               'gl_account_id', l.gl_account_id, 'debit', l.credit, 'credit', l.debit,
               'currency', l.currency, 'fx_rate', l.fx_rate, 'is_rounding', l.is_rounding,
               'description', 'Reversal of commission earned on ' || r.policy_no))
        into v_lines
        from journal_entry_lines l
       where l.journal_entry_id = v_rec_je;
      perform set_config('fin.reversal_of', v_rec_je::text, true);
      v_je := post_journal_entry(new.tenant_id, 'ins_commission_recognition_reversal', v_ev, v_date,
        'Commission no longer earned on ' || r.policy_no || ' (settlement voided)', v_lines);
      perform set_config('fin.reversal_of', '', true);
    else
      v_je := post_journal_entry(new.tenant_id, 'ins_commission_recognition_reversal', v_ev, v_date,
        'Commission no longer earned on ' || r.policy_no || ' (settlement voided)',
        jsonb_build_array(
          jsonb_build_object('gl_account_id', v_income,   'debit',  r.amount, 'description', 'Reversal of commission earned on ' || r.policy_no),
          jsonb_build_object('gl_account_id', v_unearned, 'credit', r.amount, 'description', 'Reversal of commission earned on ' || r.policy_no)));
    end if;

    insert into ins_commission_events (id, tenant_id, entry_id, event, amount, journal_entry_id, settlement_id)
    values (v_ev, new.tenant_id, r.entry_id, 'recognition_reversed', r.amount, v_je.id, new.id);

    update ins_commission_entries
       set status = 'deferred', earned_on = null, earned_by = null, updated_at = now()
     where id = r.entry_id;
  end loop;

  return new;
end;
$function$;

revoke all on function public.ins_commission_on_settlement_voided() from public;

select 'Endorsement-item settlement workflow is available: items can be settled and reversed through the app' as status;
