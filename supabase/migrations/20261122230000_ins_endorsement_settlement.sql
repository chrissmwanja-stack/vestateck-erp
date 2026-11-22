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
    from (select distinct s.id, s.tenant_id, s.settlement_no, s.direction, s.amount, s.currency, s.settlement_date,
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
                and public.business_today() between period_start and period_end) then
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
  v_date := coalesce(v_date, public.business_today());

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

-- ---------------------------------------------------------------------
-- 4. Cancelling an endorsement whose settlement was voided.
-- ---------------------------------------------------------------------
-- The cancellation deletes the endorsement's deferred commission entries, and its
-- header argued the earned-then-voided state could not occur. Section 3 makes it
-- occur: settle the insurer item, void the settlement, and the entry is deferred
-- again with 'recognised' and 'recognition_reversed' events behind it. Those events
-- reference the entry, so the delete failed with a foreign key violation
-- (ins_commission_events_entry_id_fkey) and the endorsement could not be cancelled
-- even though the screen had freed it. This is the cancellation function unchanged
-- except that it removes the entries' netted-out events first.
CREATE OR REPLACE FUNCTION public.ins_approve_endorsement_cancellation(p_endorsement_id uuid, p_review_note text)
 RETURNS ins_policy_endorsements
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c public.ins_policy_endorsements%rowtype;
  p public.ins_policies%rowtype;
  v_pos jsonb;
  v_note jsonb;
  v_item public.fin_open_items%rowtype;
  v_bal record;
  v_lines jsonb := '[]'::jsonb;
  v_je public.journal_entries%rowtype;
  je_cancel uuid;
  v_ar uuid; v_payable uuid; v_unearned uuid; v_clearing uuid;
  v_note_id uuid;
  v_entries uuid[];
  v_line record;
  v_new_note public.fin_credit_notes%rowtype;
  v_amount numeric;
  v_cleared numeric := 0;
  v_debit numeric; v_credit numeric;
  v_clearing_net numeric := 0;
  v_end_commission numeric := 0;
  v_desc text;
begin
  perform public.ins_policy_cash_require_finance();
  if p_review_note is null or length(btrim(p_review_note)) not between 5 and 2000 then
    raise exception 'INS_ENDORSEMENT_CANCEL_INPUT: an independent checker''s note of at least 5 characters is required';
  end if;
  select * into c from public.ins_policy_endorsements
   where id = p_endorsement_id and tenant_id = public.get_my_tenant_id();
  if not found then raise exception 'INS_NOT_FOUND: endorsement'; end if;
  select * into p from public.ins_policies
   where id = c.policy_id and tenant_id = c.tenant_id for update;
  select * into c from public.ins_policy_endorsements where id = c.id for update;
  v_desc := 'Cancellation of endorsement ' || coalesce(c.endorsement_no, '') || ' on ' || p.policy_no;

  if c.cancelled_by is null or c.cancellation_journal_id is not null then
    raise exception 'INS_ENDORSEMENT_CANCEL_STATE: Finance preparation is required before approval';
  end if;
  if c.cancelled_by = auth.uid() then
    raise exception 'INS_ENDORSEMENT_CANCEL_SELF_APPROVAL: an independent Finance checker is required';
  end if;

  -- Re-derive everything: nothing pinned by the preparer is trusted, because the
  -- message between two people is not a channel we control.
  v_pos := public.ins_endorsement_unwind_position(c.id);
  if not (v_pos ->> 'eligible')::boolean then
    raise exception 'INS_ENDORSEMENT_CANCEL_BLOCKED: %',
      coalesce((select string_agg(x, '; ') from jsonb_array_elements_text(v_pos -> 'reasons') x), 'not permitted');
  end if;

  v_ar       := public.get_posting_account(c.tenant_id, 'ar_control');
  v_payable  := public.get_posting_account(c.tenant_id, 'insurer_payable');
  v_unearned := public.get_posting_account(c.tenant_id, 'unearned_commission');
  -- The clearing account the endorsement itself used, from its stored mappings: the
  -- reversal must land in the same place, whatever has been reconfigured since.
  v_clearing := (c.accounting_mappings ->> 'clearing')::uuid;
  if v_clearing is null then
    raise exception 'INS_ENDORSEMENT_CANCEL_HISTORY: endorsement % has no stored clearing mapping', coalesce(c.endorsement_no, c.id::text);
  end if;

  -- Serialize with the cash path and the commission subledger in the module's
  -- deterministic order.
  perform i.id from public.fin_open_items i where i.tenant_id = c.tenant_id
     and i.source_id = c.id order by i.id for update;
  perform e.id from public.ins_commission_entries e where e.policy_id = p.id order by e.id for update;

  -- The commission entries this endorsement created (E2 records them on the row).
  select coalesce(array_agg((x #>> '{}')::uuid), '{}')
    into v_entries
    from jsonb_array_elements(coalesce(c.commission_entry_ids, '[]'::jsonb)) x;

  -- ------------------------------------------------------------------
  -- A. The additional side's commission
  -- ------------------------------------------------------------------
  -- E2 created one deferred entry per additional insurer item, and the only thing that
  -- can ever earn it is a settlement of that same item (the settlement trigger matches
  -- on source_open_item_id; the collection trigger matches only policy-level entries).
  --
  -- That makes the states that reach this point:
  --
  --   deferred, never earned    the insurer has not been paid for this endorsement.
  --                             Nothing was recognised, so deleting the entry
  --                             completes the reversal.
  --   deferred, earned then     the insurer item WAS paid and the settlement was then
  --   un-earned                 voided (ins_commission_on_settlement_voided now
  --                             reverses recognition for this item type). The entry is
  --                             back to deferred, but it carries 'recognised' and
  --                             'recognition_reversed' events. Their journals stay in
  --                             the ledger and net to zero; the event rows exist only
  --                             to serve the entry, so they go with it.
  --   earned / transferred      the insurer item is settled right now, which the unwind
  --                             position has already refused. What the person needs is
  --                             the step to take, so that is what the refusal says.
  if exists (select 1 from public.ins_commission_entries e
              where e.id = any (v_entries) and e.tenant_id = c.tenant_id
                and e.status <> 'deferred') then
    raise exception 'INS_ENDORSEMENT_CANCEL_COMMISSION: the commission on this endorsement is already earned, which means its insurer item has been paid; void that settlement before cancelling the endorsement';
  end if;

  -- Recorded before the entries go, so section D can prove the residue it closes is
  -- exactly this commission and not something else.
  select coalesce(sum(e.amount), 0) into v_end_commission
    from public.ins_commission_entries e
   where e.id = any (v_entries) and e.tenant_id = c.tenant_id;

  -- An entry that was earned and then un-earned still has its event history, and the
  -- events reference the entry. Every entry here is deferred (checked above), so that
  -- history nets to zero; remove it with the entry. The journals it points at are
  -- untouched.
  delete from public.ins_commission_events ev
   where ev.entry_id = any (v_entries) and ev.tenant_id = c.tenant_id;

  delete from public.ins_commission_entries e
   where e.id = any (v_entries) and e.tenant_id = c.tenant_id;

  -- ------------------------------------------------------------------
  -- B. The return side's credit notes are voided
  -- ------------------------------------------------------------------
  -- A return endorsement credited the premium item and/or an insurer item. Voiding
  -- those notes is the honest inverse: it restores what the items showed before the
  -- endorsement, and it is what frees the premium item again -- blocker 2 in the
  -- sizing note, the reason a policy with a posted endorsement could not be
  -- cancelled at all.
  for v_note in select value from jsonb_array_elements(coalesce(c.credit_note_ids, '[]'::jsonb)) loop
    v_note_id := (v_note ->> 'note_id')::uuid;
    if exists (select 1 from public.fin_credit_notes x
                where x.id = v_note_id and x.tenant_id = c.tenant_id and x.status = 'posted') then
      perform public.platform_fin_void_credit_note_impl(c.tenant_id, v_note_id,
        'Endorsement ' || coalesce(c.endorsement_no, c.id::text) || ' cancelled: ' || btrim(p_review_note),
        public.ins_local_today());
    end if;
  end loop;

  -- ------------------------------------------------------------------
  -- C. The additional side's items, and the return side's recoveries
  -- ------------------------------------------------------------------
  -- Items are closed the way the module has always closed them: a credit note
  -- applied to the item, with the endorsement clearing account as the offset. That is
  -- the E2/E3 shape, it needs no new machinery, and it keeps the clearing account as
  -- the one place the reversal's balancing act is visible.
  --
  --   AR item (the client was billed)     Cr AR      Dr clearing
  --   payable item (the insurer was owed) Dr payable Cr clearing
  --
  -- Whatever is left in clearing afterwards is the commission the endorsement booked,
  -- and section D closes it. On the additional side that is the commission credited to
  -- unearned at posting: the notes above have already put AR and payable back, and the
  -- balancing Dr clearing is exactly the commission.
  for v_item in
    select i.* from public.fin_open_items i
     where i.tenant_id = c.tenant_id
       and ( (i.source_type = 'ins_policy_endorsement' and i.source_id = c.id)
          -- E2 keys each insurer item by the commission entry that its full payment
          -- earns, not by the endorsement: that is what makes recognition fire for
          -- exactly that entry. The entry ids are on the endorsement, so this finds
          -- them without guessing.
          or (i.source_type = 'ins_policy_endorsement_insurer' and i.source_id = any (v_entries))
          or (i.source_type in ('ins_policy_endorsement_recovery','ins_policy_endorsement_recovery_insurer')
              and i.source_id = c.id) )
     order by i.id
  loop
    select *, coalesce(allocated_amount, 0) + coalesce(credited_amount, 0) as consumed_amount
      into v_bal from public.fin_open_item_balances where id = v_item.id;
    continue when coalesce(v_bal.outstanding_amount, 0) = 0;
    -- The section B voids have already removed this endorsement's own credits, so any
    -- consumption left here belongs to something else.
    if coalesce(v_bal.consumed_amount, 0) <> 0 then
      raise exception 'INS_ENDORSEMENT_CANCEL_BLOCKED: the endorsement''s % item has settled movement; reverse that first', v_item.control_role;
    end if;
    v_amount := v_bal.outstanding_amount;
    v_new_note := public.platform_fin_raise_credit_note_impl(c.tenant_id, v_item.control_role,
      v_item.party_account_id, v_amount, public.ins_local_today(), v_clearing,
      jsonb_build_array(jsonb_build_object('open_item_id', v_item.id, 'amount', v_amount)),
      v_desc, coalesce(c.endorsement_no, c.id::text));
    v_cleared := v_cleared + v_amount;
  end loop;

  -- The return side's clawback journal, mirrored line for line.
  --
  -- Which journal that is needs care. E2 posts two journals under one source type:
  -- the additional journal (Dr AR / Cr payable / Cr unearned) and the adjustment
  -- journal (clawback debits plus a balancing clearing credit), and it stores
  -- `coalesce(adjustment, additional)` in one column -- so the stored id cannot tell
  -- them apart. The clearing line can: only the adjustment journal has one, because
  -- that is the account its balancing leg lands in. That is the discriminator used
  -- here, and it is why the additional journal is NOT mirrored -- the credit notes
  -- raised above already reverse it through the items, and mirroring both would
  -- credit the client twice.
  for v_je in
    select distinct j.id
      from public.journal_entries j
      join public.journal_entry_lines l on l.journal_entry_id = j.id
     where j.tenant_id = c.tenant_id and j.source_type = 'ins_policy_endorsement'
       and j.source_id = c.id and l.gl_account_id = v_clearing
     order by j.id
  loop
    for v_line in
      select l.gl_account_id, l.currency, l.fx_rate, l.is_rounding, l.debit, l.credit
        from public.journal_entry_lines l
       where l.journal_entry_id = v_je.id
       order by l.debit desc, l.gl_account_id
    loop
      if v_line.debit <> 0 then
        v_lines := v_lines || jsonb_build_object('gl_account_id', v_line.gl_account_id, 'credit', v_line.debit,
          'currency', v_line.currency, 'fx_rate', v_line.fx_rate, 'is_rounding', v_line.is_rounding,
          'description', v_desc || ' - reversal');

      end if;
      if v_line.credit <> 0 then
        v_lines := v_lines || jsonb_build_object('gl_account_id', v_line.gl_account_id, 'debit', v_line.credit,
          'currency', v_line.currency, 'fx_rate', v_line.fx_rate, 'is_rounding', v_line.is_rounding,
          'description', v_desc || ' - reversal');

      end if;
    end loop;
  end loop;

  -- ------------------------------------------------------------------
  -- D. Close the clearing residue: the commission the endorsement booked
  -- ------------------------------------------------------------------
  -- On the additional side the residue is the commission credited to unearned at
  -- posting. If it was still deferred, unearned takes it back (Dr unearned). If
  -- recognition had already earned it, section A un-earned it first, so unearned is
  -- whole again and the same debit applies. Either way the effect is that the
  -- endorsement's commission disappears from the ledger.
  --
  -- A residue that is NOT explained by the endorsement's commission means the
  -- position has moved in a way this code does not understand, and it fails closed
  -- rather than inventing an account to absorb the difference.
  -- The clearing effect is read back from the ledger rather than tracked by hand:
  -- every note this cancellation voided or raised has a journal, and the reversal
  -- lines are already in v_lines. Summing the actual lines cannot drift out of step
  -- with what was posted, which hand-kept signs did (they got the note-void direction
  -- backwards on the first run).
  select coalesce(sum(l.debit - l.credit), 0) into v_clearing_net
    from public.journal_entry_lines l
   where l.gl_account_id = v_clearing
     and ( l.journal_entry_id in (
             select n.void_journal_entry_id from public.fin_credit_notes n
              where n.tenant_id = c.tenant_id and n.void_journal_entry_id is not null
                and ( n.reference = coalesce(c.endorsement_no, c.id::text)
                      or n.id in (select (x ->> 'note_id')::uuid
                                    from jsonb_array_elements(coalesce(c.credit_note_ids,'[]'::jsonb)) x) ) )
        or l.journal_entry_id in (
             select n.journal_entry_id from public.fin_credit_notes n
              where n.tenant_id = c.tenant_id and n.journal_entry_id is not null
                and n.reference = coalesce(c.endorsement_no, c.id::text) ) );

  select v_clearing_net + coalesce(sum((l ->> 'debit')::numeric) - sum((l ->> 'credit')::numeric), 0)
    into v_clearing_net
    from jsonb_array_elements(v_lines) l
   where (l ->> 'gl_account_id')::uuid = v_clearing;

  if v_clearing_net <> 0 then
    if v_unearned is null then
      raise exception 'INS_ENDORSEMENT_CANCEL_HISTORY: the unearned commission account is not configured';
    end if;
    if round(abs(v_clearing_net), 2) <> round(coalesce(v_end_commission, 0), 2) then
      raise exception 'INS_ENDORSEMENT_CANCEL_HISTORY: the cancellation leaves % in the clearing account, which the endorsement''s commission of % does not explain',
        v_clearing_net, coalesce(v_end_commission, 0);
    end if;
    if v_clearing_net > 0 then
      v_lines := v_lines || jsonb_build_object('gl_account_id', v_unearned, 'debit', v_clearing_net,
        'currency', p.currency, 'description', v_desc || ' - commission returned to unearned');
      v_lines := v_lines || jsonb_build_object('gl_account_id', v_clearing, 'credit', v_clearing_net,
        'currency', p.currency, 'description', v_desc || ' - clearing');
    else
      v_lines := v_lines || jsonb_build_object('gl_account_id', v_unearned, 'credit', -v_clearing_net,
        'currency', p.currency, 'description', v_desc || ' - commission returned to unearned');
      v_lines := v_lines || jsonb_build_object('gl_account_id', v_clearing, 'debit', -v_clearing_net,
        'currency', p.currency, 'description', v_desc || ' - clearing');
    end if;
  end if;

  if jsonb_array_length(v_lines) > 0 then
    select coalesce(sum((l ->> 'debit')::numeric), 0), coalesce(sum((l ->> 'credit')::numeric), 0)
      into v_debit, v_credit
      from jsonb_array_elements(v_lines) l;
    if v_debit <> v_credit then
      raise exception 'INS_ENDORSEMENT_CANCEL_HISTORY: the reversal does not balance (Dr % vs Cr %)', v_debit, v_credit;
    end if;
    perform set_config('fin.reversal_of', coalesce(c.journal_entry_id::text, ''), true);
    v_je := public.post_journal_entry(c.tenant_id, 'ins_policy_endorsement_cancel', c.id, public.ins_local_today(), v_desc, v_lines);
    perform set_config('fin.reversal_of', '', true);
    je_cancel := v_je.id;
  end if;

  update public.ins_policy_endorsements
     set status = 'cancelled',
         cancellation_no = coalesce(cancellation_no, public.next_doc_number(c.tenant_id, 'ins_policy_endorsement_cancel', 'ENDC')),
         cancellation_journal_id = je_cancel,
         cancellation_operation_txid = null
   where id = c.id
   returning * into c;

  insert into public.ins_policy_endorsement_events(tenant_id, endorsement_id, event, actor_id, detail)
  values (c.tenant_id, c.id, 'cancelled', auth.uid(), jsonb_build_object(
    'review_note', btrim(p_review_note),
    'journal_entry_id', je_cancel,
    'amount_cleared', v_cleared,
    'commission_removed', v_end_commission,
    'prepared_by', c.cancelled_by));
  return c;
end $function$;

select 'Endorsement-item settlement workflow is available: items can be settled and reversed through the app' as status;
