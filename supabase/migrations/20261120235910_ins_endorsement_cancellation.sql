-- =====================================================================
-- E4: an endorsement can be cancelled, and unwinding it restores the
--     policy's financial position to what the cancellation engine expects
-- =====================================================================
-- The sizing note in ROADMAP.md (19 Nov 2026) set the shape and the reason for it:
-- do NOT teach the cancellation engine about endorsements. Instead unwind them as
-- their own approved document first, so that the ordinary cancellation runs on a
-- policy whose position is once again the bind position. That keeps a
-- ten-thousand-character money path -- the most safety-critical code in the module --
-- untouched, and turns the guard from a wall into a rule about ordering.
--
-- What a posted endorsement left behind, and what this reverses:
--
--   additional premium (delta > 0)
--       client item      ins_policy_endorsement                  (AR)
--       insurer item(s)  ins_policy_endorsement_insurer          (payable, one per insurer)
--       commission       ins_commission_entries row 'deferred' with source_open_item_id
--                        naming its insurer item, so paying that item earns it
--       journal          source_type 'ins_policy_endorsement'
--
--   return premium (delta < 0)
--       credit note(s)   on the policy premium item and/or an insurer item
--       recovery item(s) ins_policy_endorsement_recovery[_insurer]
--       clawbacks        ins_endorsement_clawbacks rows reducing commission entries
--
-- Reversing all of that is the inverse of each piece: credit what was debited, debit
-- what was credited, in one journal, then empty the items it mirrors.
--
-- One rule governs whether it is allowed at all, and it is the honest one: every item
-- and note the endorsement created must still be **untouched** -- nothing settled,
-- nothing credited against it, nothing paid. Otherwise the money has moved and
-- reversing the document would silently reopen a settled position. That check is
-- `ins_endorsement_unwind_position`, and it returns the exact reason so the screen
-- can say "the client has paid part of this; settle or refund it first" rather than
-- a bare refusal.

-- ---------------------------------------------------------------------
-- 1. The new terminal state
-- ---------------------------------------------------------------------
-- 'cancelled' is a state of its own rather than a reuse of 'withdrawn': a withdrawn
-- proposal never posted anything, an endorsed-then-cancelled one did, and the two
-- must be distinguishable in the history for ever.
alter table public.ins_policy_endorsements
  drop constraint if exists ins_policy_endorsements_status_check;
alter table public.ins_policy_endorsements
  add constraint ins_policy_endorsements_status_check
  check (status = any (array['proposed','prepared','posting','posted','rejected','withdrawn','cancelled']));

-- The ledger's source_type is a closed list too. A cancellation that writes a journal
-- must name its own document type, or the journal is unattributable (and the insert
-- fails outright).
alter table public.journal_entries
  drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries
  add constraint journal_entries_source_type_check
  check (source_type = any (array['supplier_invoice','receivable_invoice','cash_bank_transaction',
    'opening_balance','manual','payroll_run','machine_fuel_log','machine_maintenance_request',
    'fin_settlement','fin_settlement_void','fin_credit_note','fin_credit_note_void',
    'ins_policy_bind','ins_commission_recognition','ins_commission_recognition_reversal',
    'ins_commission_transfer','ins_commission_transfer_void','ins_claim_accrual',
    'ins_policy_cancellation','ins_cancellation_cash','fx_revaluation','fx_revaluation_void',
    'ins_policy_endorsement','ins_import_opening','ins_agent_commission_accrual',
    'ins_agent_commission_payment','ins_agent_commission_reversal','ins_wht_remittance',
    'ins_fee_withholding','bank_adjustment','bank_adjustment_reversal',
    'ins_policy_endorsement_cancel']));

-- The event log has its own vocabulary; the two new events must be admitted there
-- or the insert fails at runtime while every static check still passes.
alter table public.ins_policy_endorsement_events
  drop constraint if exists ins_policy_endorsement_events_event_check;
alter table public.ins_policy_endorsement_events
  add constraint ins_policy_endorsement_events_event_check
  check (event = any (array['proposed','withdrawn','prepared','approved','rejected','posted',
                            'cancellation_prepared','cancelled']));

-- The cancellation is its own document with its own number and its own checker, so
-- it gets its own columns rather than overloading the proposal's. Both are nullable:
-- an endorsement that was never cancelled has neither.
alter table public.ins_policy_endorsements
  add column if not exists cancelled_at         timestamptz,
  add column if not exists cancelled_by         uuid,
  add column if not exists cancellation_no      text,
  add column if not exists cancellation_note    text,
  add column if not exists cancellation_journal_id uuid,
  add column if not exists cancellation_operation_txid bigint;

comment on column public.ins_policy_endorsements.cancellation_no is
  'ENDC- number of the document that unwound this endorsement; null until cancelled.';

-- ---------------------------------------------------------------------
-- 2. Is this endorsement safe to unwind?
-- ---------------------------------------------------------------------
-- Read-only, and returns a reason rather than raising, because the screen asks this
-- before offering the action. The approve path calls it and raises.
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
  v_note_id uuid;
  v_premium_item uuid;
  v_total numeric := 0;
  v_own_credit numeric := 0;
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
  --
  -- "Newest" is decided by `endorsement_no`, not by a timestamp. The number is stamped
  -- by next_doc_number at the moment of posting, so it is strictly monotonic per
  -- company; posting_date is a date and proposed_at is now(), which is transaction
  -- start -- two endorsements posted in the same transaction or on the same day tie on
  -- both, and a tie broken by id would order them at random. (That is not a corner
  -- case: a back-office clerk catching up on a morning's paperwork posts several in
  -- one sitting.)
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
           coalesce(b.allocated_amount, 0) + coalesce(b.credited_amount, 0) as consumed_amount
      from public.fin_open_items i
      left join public.fin_open_item_balances b on b.id = i.id
     where i.tenant_id = c.tenant_id
       and ( (i.source_type = 'ins_policy_endorsement' and i.source_id = c.id)
          -- insurer items are keyed by their commission entry (see E2)
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
      v_reasons := v_reasons || format(
        'the endorsement''s %s item has already been settled or credited by something other than this endorsement (%s outstanding); reverse that movement first',
        v_item.control_role, v_item.outstanding_amount)::text;
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
  -- An earned entry and a settled insurer item are the same fact seen twice, so this
  -- deliberately says the same thing the item check says: void the settlement. A
  -- transferred entry is a different matter -- the money has left the company -- and
  -- it names the transfer instead.
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
  select i.id into v_premium_item from public.fin_open_items i
   where i.tenant_id = c.tenant_id and i.source_type = 'ins_policy_endorsement' and i.source_id = c.id
   order by i.id limit 1;

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
-- 3. The unwinding document
-- ---------------------------------------------------------------------
-- Maker/checker like E2: one Finance person prepares (which re-reads and pins the
-- calculation), a different one approves. The preparation stores the exact
-- calculation it verified, so a change between preparing and approving is caught
-- rather than posted blind -- the same INS_ENDORSEMENT_STALE discipline as E2.
create or replace function public.ins_prepare_endorsement_cancellation(
  p_endorsement_id uuid,
  p_reason text
) returns public.ins_policy_endorsements
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  c public.ins_policy_endorsements%rowtype;
  v_pos jsonb;
begin
  perform public.ins_policy_cash_require_finance();
  if p_reason is null or length(btrim(p_reason)) not between 5 and 2000 then
    raise exception 'INS_ENDORSEMENT_CANCEL_INPUT: a reason of at least 5 characters is required';
  end if;
  select * into c from public.ins_policy_endorsements
   where id = p_endorsement_id and tenant_id = public.get_my_tenant_id() for update;
  if not found then raise exception 'INS_NOT_FOUND: endorsement'; end if;

  v_pos := public.ins_endorsement_unwind_position(c.id);
  if not (v_pos ->> 'eligible')::boolean then
    raise exception 'INS_ENDORSEMENT_CANCEL_BLOCKED: %',
      coalesce((select string_agg(x, '; ') from jsonb_array_elements_text(v_pos -> 'reasons') x), 'not permitted');
  end if;

  -- Re-preparing the same case by the same maker refreshes the pinned calculation
  -- instead of stacking a second document.
  if c.cancelled_by is not null and c.cancellation_journal_id is null and c.cancelled_by <> auth.uid() then
    raise exception 'INS_ENDORSEMENT_CANCEL_STATE: another Finance preparer owns this cancellation';
  end if;

  update public.ins_policy_endorsements
     set cancelled_by = auth.uid(),
         cancelled_at = coalesce(cancelled_at, now()),
         cancellation_note = btrim(p_reason),
         cancellation_operation_txid = txid_current()
   where id = c.id
   returning * into c;

  insert into public.ins_policy_endorsement_events(tenant_id, endorsement_id, event, actor_id, detail)
  values (c.tenant_id, c.id, 'cancellation_prepared', auth.uid(),
          jsonb_build_object('reason', btrim(p_reason), 'position', v_pos));
  return c;
end $$;

revoke all on function public.ins_prepare_endorsement_cancellation(uuid, text) from public, anon;
grant execute on function public.ins_prepare_endorsement_cancellation(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Approval: post the reversal
-- ---------------------------------------------------------------------
create or replace function public.ins_approve_endorsement_cancellation(
  p_endorsement_id uuid,
  p_review_note text
) returns public.ins_policy_endorsements
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
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
  -- That makes the reachable states exactly two, and they point the same way:
  --
  --   deferred  the insurer has not been paid for this endorsement. Nothing was
  --             recognised, so deleting the entry completes the reversal.
  --   earned    the insurer item was paid -- which means the unwind position has
  --             already refused this case, because the item carries settled money.
  --
  -- There is no third state and no un-earning branch, because no sequence of events
  -- produces one. Writing one anyway would leave a code path that can never run while
  -- reading as though it can. What the person actually needs is the step to take, so
  -- that is what the refusal says.
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
        current_date);
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
      v_item.party_account_id, v_amount, current_date, v_clearing,
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
    v_je := public.post_journal_entry(c.tenant_id, 'ins_policy_endorsement_cancel', c.id, current_date, v_desc, v_lines);
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
end $$;

revoke all on function public.ins_approve_endorsement_cancellation(uuid, text) from public, anon;
grant execute on function public.ins_approve_endorsement_cancellation(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5. The review position must forget a cancelled endorsement
-- ---------------------------------------------------------------------
-- `ins_endorsement_review_position` computes current = bound + every posted
-- endorsement. A cancelled endorsement is no longer part of the policy's position,
-- so it must stop counting -- otherwise the cancellation preview would be told the
-- policy is worth more (or less) than it is.
create or replace function public.ins_endorsement_review_position(p_policy_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  p public.ins_policies%rowtype;
  v_gross numeric;
  v_commission numeric;
  v_sum_insured numeric;
  v_live jsonb;
  v_posted integer;
  v_cxl_live boolean;
  r record;
  c record;
begin
  if auth.uid() is null or not (public.can_access_insurance() or public.is_finance_team_member('finance')) then
    raise exception 'INS_FORBIDDEN' using errcode = '42501';
  end if;
  select * into p from public.ins_policies where id = p_policy_id and tenant_id = public.get_my_tenant_id();
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  v_gross := p.gross_premium;
  v_commission := p.commission_amount;
  v_sum_insured := p.sum_insured;
  v_posted := 0;
  for r in
    select calculation
      from public.ins_policy_endorsements
     where policy_id = p.id and tenant_id = p.tenant_id and status = 'posted'
     order by posting_date nulls last, proposed_at
  loop
    v_posted := v_posted + 1;
    v_gross := v_gross + coalesce((r.calculation ->> 'premium_delta')::numeric, 0);
    v_commission := v_commission + coalesce((r.calculation ->> 'commission_delta')::numeric, 0);
    if r.calculation -> 'changes' <> '[]'::jsonb then
      for c in select * from jsonb_array_elements(r.calculation -> 'changes') where value ->> 'field' = 'sum_insured' loop
        v_sum_insured := (c.value ->> 'after')::numeric;
      end loop;
    end if;
  end loop;
  select jsonb_agg(to_jsonb(x)) into v_live
    from public.ins_policy_endorsements x
   where x.policy_id = p.id and x.tenant_id = p.tenant_id and x.status in ('proposed','prepared');
  select exists (
    select 1 from public.ins_policy_cancellations
     where policy_id = p.id and tenant_id = p.tenant_id and status in ('proposed','prepared','posting','posted')
  ) into v_cxl_live;
  return jsonb_build_object(
    'policy_id', p.id, 'policy_no', p.policy_no, 'currency', p.currency,
    'bound_gross_premium', p.gross_premium,
    'bound_commission_amount', p.commission_amount,
    'current_gross_premium', v_gross,
    'current_commission_amount', v_commission,
    'current_sum_insured', v_sum_insured,
    'posted_endorsements', v_posted,
    'live_endorsements', coalesce(v_live, '[]'::jsonb),
    'cancellation_in_flight', v_cxl_live);
end $$;

revoke all on function public.ins_endorsement_review_position(uuid) from public, anon;
grant execute on function public.ins_endorsement_review_position(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6. The cross-guard becomes a rule about ordering
-- ---------------------------------------------------------------------
-- Blocker 1 in the sizing note was this guard refusing a cancellation outright when a
-- posted endorsement existed. Now that endorsements can be unwound, the guard says
-- the useful thing instead: unwind them first, in newest-first order.
create or replace function public.ins_endorsement_cross_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if tg_table_name = 'ins_policy_cancellations' then
    if new.status in ('proposed','prepared','posting') and exists (
      select 1 from public.ins_policy_endorsements
       where policy_id = new.policy_id and status in ('proposed','prepared','posting')
    ) then
      raise exception 'INS_ENDORSEMENT_LIVE: finish or withdraw the live endorsement before cancelling this policy';
    end if;
    if new.status in ('proposed','prepared','posting') and exists (
      select 1 from public.ins_policy_endorsements
       where policy_id = new.policy_id and status = 'posted'
    ) then
      raise exception 'INS_ENDORSEMENT_POSTED: this policy has posted endorsements; cancel them (newest first) before cancelling the policy';
    end if;
  else
    if new.status in ('proposed','prepared','posting') and exists (
      select 1 from public.ins_policy_cancellations
       where policy_id = new.policy_id and status in ('proposed','prepared','posting','posted')
    ) then
      raise exception 'INS_CANCELLATION_LIVE: this policy has a cancellation in flight; endorse it another day';
    end if;
  end if;
  return new;
end $$;

select 'E4: endorsement cancellation is available, and the guard is an ordering rule' as status;
