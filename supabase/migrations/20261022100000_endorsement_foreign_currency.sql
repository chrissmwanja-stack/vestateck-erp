-- =============================================================================
-- Endorsements slice E3: foreign-currency posting.
-- =============================================================================
-- E2 refused to post an endorsement in any currency but the tenant's ledger
-- (INS_ENDORSEMENT_CURRENCY). This slice lifts the gate on the patterns the
-- 3d slices already proved:
--
--   * the additional-premium journal and its items post in the policy's
--     currency at the posting-date rate -- the journal line guard prices the
--     foreign lines from the approved rate table, and the items carry their
--     booking entry, so their booked rate flows from the journal;
--   * return-premium credit notes go through the 3d-1 credit-note machinery
--     (platform_fin_raise_credit_note_impl): the note takes the original
--     item's currency, the control line rides that item's booked rate, the
--     clearing offset prices at the credit-date rate, and the difference
--     books as realised gain or loss. A functional-currency note is unchanged
--     (rate 1, no realised result), so the E2 paths post byte-for-byte the
--     same amounts;
--   * the clawback legs stay at the posting-date rate. A small base residue
--     on unearned commission (clawback at today's rate against a bind at the
--     bound rate) is the documented 3d-3 convention; period-end revaluation
--     (slice 3e) is what clears residues like that;
--   * recognition is untouched -- the earned-when trigger already prices its
--     foreign legs from each entry's own booking journal.
--
-- No table changes; one function is rewritten.
-- =============================================================================

-- E3: the currency gate is gone. A foreign-currency endorsement posts in the
-- policy's own currency on the 3d patterns: the additional-side journal and
-- items at the posting-date rate (the line guard prices them from the approved
-- table), credit notes through the 3d-1 machinery -- control lines at each
-- original item's booked rate, the clearing offset at the credit-date rate,
-- the difference as realised gain or loss -- and the clawback legs at the
-- posting-date rate (a small base residue on unearned commission is the
-- documented 3d-3 convention; period-end revaluation clears it).
CREATE OR REPLACE FUNCTION public.ins_decide_policy_endorsement(p_endorsement_id uuid, p_decision text, p_review_note text, p_accept_manual_exception boolean DEFAULT false)
 RETURNS ins_policy_endorsements
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c ins_policy_endorsements%rowtype;
  p ins_policies%rowtype;
  fresh jsonb; mappings jsonb; share jsonb;
  insurer uuid; v_share_id uuid;
  delta numeric; v_claw numeric; net numeric;
  v_ar uuid; v_payable uuid; v_unearned uuid; v_income uuid; v_clearing uuid;
  v_client_acc uuid; v_ins_acc uuid;
  item fin_open_items%rowtype; created_item fin_open_items%rowtype; note fin_credit_notes%rowtype;
  ce record;
  v_claw_left numeric; v_take numeric; v_claw_lines jsonb := '[]'::jsonb; v_debit_total numeric := 0;
  v_add_lines jsonb := '[]'::jsonb; v_add_items jsonb := '[]'::jsonb;
  v_recos jsonb := '[]'::jsonb; v_todo jsonb;
  v_credit_notes jsonb := '[]'::jsonb; v_new_entries jsonb := '[]'::jsonb;
  v_outstanding numeric; v_applied numeric; v_recovered numeric;
  note_id uuid;
  je journal_entries%rowtype; je_adj uuid := null; je_add uuid := null;
  v_first_premium_item uuid := null;
  v_desc text;
begin
  perform ins_policy_cash_require_finance();
  if p_decision not in ('approve','reject') or p_decision is null
     or p_review_note is null or length(btrim(p_review_note)) not between 5 and 2000 then
    raise exception 'INS_ENDORSEMENT_INPUT: decision and detailed Finance review note required';
  end if;
  select policy_id into p.id from ins_policy_endorsements
   where id = p_endorsement_id and tenant_id = get_my_tenant_id();
  if not found then raise exception 'INS_NOT_FOUND: endorsement'; end if;
  select * into p from ins_policies where id = p.id and tenant_id = get_my_tenant_id() for update;
  select * into c from ins_policy_endorsements where id = p_endorsement_id for update;
  if p.status not in ('active','renewed') then
    raise exception 'INS_ENDORSEMENT_STATE: the policy is %; only a bound policy endorses', p.status;
  end if;
  if c.prepared_by = auth.uid() or c.proposed_by = auth.uid() then
    raise exception 'INS_ENDORSEMENT_SELF_APPROVAL: an independent Finance checker is required';
  end if;
  -- An approve retry on a posted case is idempotent only with the same payload.
  if c.status = 'posted' and p_decision = 'approve' and c.checked_by = auth.uid() then
    if c.review_note is distinct from btrim(p_review_note)
       or c.manual_exception_accepted is distinct from coalesce(p_accept_manual_exception, false) then
      raise exception 'INS_ENDORSEMENT_RETRY_CONFLICT: different approval payload';
    end if;
    return c;
  end if;
  if p_decision = 'reject' then
    if c.status not in ('proposed','prepared') then
      raise exception 'INS_ENDORSEMENT_STATE: open proposal required';
    end if;
    update ins_policy_endorsements
       set status = 'rejected', checked_by = auth.uid(), checked_at = now(),
           review_note = btrim(p_review_note)
     where id = c.id
     returning * into c;
    insert into ins_policy_endorsement_events(tenant_id, endorsement_id, event, actor_id, detail)
    values (c.tenant_id, c.id, 'rejected', auth.uid(), jsonb_build_object('note', p_review_note));
    return c;
  end if;
  if c.status <> 'prepared' then
    raise exception 'INS_ENDORSEMENT_STATE: Finance preparation required before approval';
  end if;
  -- Serialize with cash approvals, claims, credits and commission transfers.
  perform m.id from fin_open_items m join ins_policy_cash_items k on k.id = m.id
   where k.source_id = p.id and k.tenant_id = p.tenant_id order by m.id for update of m;
  perform e.id from ins_commission_entries e where e.policy_id = p.id order by e.id for update;
  fresh := ins_preview_policy_endorsement(p.id, c.effective_date, c.insurer_terms, c.changes)
           || ins_endorsement_review_position(p.id);
  if exists(select 1 from accounting_periods
             where tenant_id = p.tenant_id and status = 'closed'
               and current_date between period_start and period_end) then
    raise exception 'INS_ENDORSEMENT_PERIOD: current accounting period closed';
  end if;
  -- live_endorsements carries the case's own lifecycle state (proposed ->
  -- prepared between maker and checker), not amounts; the one-live rule means
  -- it cannot hide a competitor. Everything else in the recompute must match.
  if (fresh - 'generated_at' - 'live_endorsements') is distinct from (c.calculation - 'generated_at' - 'live_endorsements') then
    raise exception 'INS_ENDORSEMENT_STALE: amounts or collection position changed; Finance maker must refresh preparation';
  end if;
  -- requires_review lives per share (a share delta bigger than that share's
  -- whole premium); any share flagging demands the checker's explicit nod.
  if exists (select 1 from jsonb_array_elements(fresh -> 'shares') sh
              where (sh ->> 'requires_review')::boolean)
     and not coalesce(p_accept_manual_exception, false) then
    raise exception 'INS_ENDORSEMENT_EXCEPTION: explicit independent Finance acceptance of the reviewed calculation required';
  end if;
  mappings := ins_endorsement_mappings(p.id, (c.accounting_mappings ->> 'clearing')::uuid);
  if mappings is distinct from c.accounting_mappings then
    raise exception 'INS_ENDORSEMENT_STALE: accounting mappings changed';
  end if;
  update ins_policy_endorsements
     set status = 'posting', checked_by = auth.uid(), checked_at = now(),
         review_note = btrim(p_review_note),
         manual_exception_accepted = coalesce(p_accept_manual_exception, false),
         posting_date = current_date,
         endorsement_no = next_doc_number(c.tenant_id, 'ins_policy_endorsement', 'END'),
         operation_txid = txid_current()
   where id = c.id
   returning * into c;

  v_ar       := (mappings ->> 'ar')::uuid;
  v_payable  := (mappings ->> 'payable')::uuid;
  v_unearned := (mappings ->> 'unearned')::uuid;
  v_income   := (mappings ->> 'income')::uuid;
  v_clearing := (mappings ->> 'clearing')::uuid;
  v_client_acc := ins_ensure_client_account(p.client_id);
  v_desc := 'Endorsement ' || c.endorsement_no || ' on ' || p.policy_no;

  for share in select value from jsonb_array_elements(fresh -> 'shares') loop
    insurer := (share ->> 'insurer_id')::uuid;
    delta   := (share ->> 'premium_delta')::numeric;
    continue when delta = 0;
    v_claw  := (share ->> 'commission_delta')::numeric;
    select id into v_share_id from ins_policy_insurer_shares
     where policy_id = p.id and tenant_id = p.tenant_id and insurer_id = insurer
     order by id limit 1;
    v_ins_acc := ins_ensure_insurer_account(insurer);

    if delta > 0 then
      ---------------------------------------------------------------
      -- Additional premium: AR item + insurer-share item + a new
      -- deferred commission entry tied to the endorsement's own item.
      ---------------------------------------------------------------
      net := delta - v_claw;
      if net <= 0 then
        raise exception 'INS_ENDORSEMENT_COMMISSION: commission would leave nothing to remit to the insurer';
      end if;
      v_add_lines := v_add_lines || jsonb_build_array(
        jsonb_build_object('gl_account_id', v_ar, 'debit', delta, 'currency', p.currency, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_payable, 'credit', net, 'currency', p.currency, 'description', v_desc)
      );
      if v_claw > 0 then
        v_add_lines := v_add_lines || jsonb_build_object(
          'gl_account_id', v_unearned, 'credit', v_claw, 'currency', p.currency,
          'description', v_desc || ' - unearned commission');
      end if;
      v_add_items := v_add_items || jsonb_build_object(
        'insurer_id', insurer, 'share_id', v_share_id, 'premium', delta,
        'net', net, 'commission', v_claw);
    else
      ---------------------------------------------------------------
      -- Return premium: credit notes at the booked rates, capped at
      -- each original item's outstanding; honest clawback of the
      -- commission (deferred pool first, then what is earned).
      ---------------------------------------------------------------
      v_claw := -v_claw;  -- the claw is a positive amount on a return
      -- Client side: the original premium item is policy-level.
      select * into item from fin_open_items
       where tenant_id = p.tenant_id and source_type = 'ins_policy_premium' and source_id = p.id;
      if not found then raise exception 'INS_ENDORSEMENT_HISTORY: original premium item missing'; end if;
      select outstanding_amount into v_outstanding from fin_open_item_balances where id = item.id;
      v_applied := least(v_outstanding, -delta);
      if v_applied > 0 then
        -- The 3d-1 note machinery: the note takes the item's currency; in a
        -- foreign currency the control line rides the item's booked rate, the
        -- clearing offset prices at the credit-date rate, and the difference
        -- books as realised result. A functional note is unchanged (rate 1).
        note := platform_fin_raise_credit_note_impl(c.tenant_id, item.control_role, item.party_account_id,
          v_applied, current_date, v_clearing,
          jsonb_build_array(jsonb_build_object('open_item_id', item.id, 'amount', v_applied)),
          c.reason, c.endorsement_no);
        note_id := note.id;
        v_credit_notes := v_credit_notes || jsonb_build_object(
          'note_id', note_id, 'open_item_id', item.id, 'amount', v_applied, 'side', item.side);
      end if;
      v_recovered := (-delta) - v_applied;
      if v_recovered > 0 then
        -- The return exceeds the billed premium still outstanding: the client
        -- owes the difference back (the cancellation engine's recovery item).
        v_recos := v_recos || jsonb_build_object(
          'party', item.party_account_id, 'role', 'ar_control', 'source_type',
          'ins_policy_endorsement_recovery', 'source_id', c.id, 'amount', v_recovered);
      end if;
      -- Insurer side: mirror the share's net reduction against its item.
      net := (-delta) - v_claw;
      -- The ORIGINAL bind items: pinned by their booking journal (the policy's
      -- bind entry), so a prior additional endorsement's items never match.
      if v_share_id is not null then
        select i.* into item from fin_open_items i join ins_policy_cash_items k on k.id = i.id
         where k.source_id = p.id and k.source_type = 'ins_policy_insurer'
           and k.insurer_share_id = v_share_id and k.tenant_id = p.tenant_id
           and i.journal_entry_id = p.journal_entry_id;
      else
        select i.* into item from fin_open_items i join ins_policy_cash_items k on k.id = i.id
         where k.source_id = p.id and k.source_type = 'ins_policy_insurer'
           and k.insurer_share_id is null and i.party_account_id = v_ins_acc
           and i.journal_entry_id = p.journal_entry_id and k.tenant_id = p.tenant_id;
      end if;
      if not found then raise exception 'INS_ENDORSEMENT_HISTORY: original insurer item missing'; end if;
      select outstanding_amount into v_outstanding from fin_open_item_balances where id = item.id;
      v_applied := least(v_outstanding, net);
      if v_applied > 0 then
        note := platform_fin_raise_credit_note_impl(c.tenant_id, item.control_role, item.party_account_id,
          v_applied, current_date, v_clearing,
          jsonb_build_array(jsonb_build_object('open_item_id', item.id, 'amount', v_applied)),
          c.reason, c.endorsement_no);
        note_id := note.id;
        v_credit_notes := v_credit_notes || jsonb_build_object(
          'note_id', note_id, 'open_item_id', item.id, 'amount', v_applied, 'side', item.side);
      end if;
      v_recovered := net - v_applied;
      if v_recovered > 0 then
        v_recos := v_recos || jsonb_build_object(
          'party', item.party_account_id, 'role', 'ar_control', 'source_type',
          'ins_policy_endorsement_recovery_insurer', 'source_id', c.id, 'amount', v_recovered);
      end if;
      -- Commission clawback: the deferred pool first, then earned, then
      -- transferred; the rows are never mutated, the ledger records the take.
      v_claw_left := v_claw;
      for ce in
        select e.id, e.amount, e.status,
               (e.amount - coalesce((select sum(x.amount) from ins_endorsement_clawbacks x
                                      where x.commission_entry_id = e.id and x.tenant_id = e.tenant_id), 0)) as available
          from ins_commission_entries e
         where e.policy_id = p.id and e.tenant_id = p.tenant_id
           and case when v_share_id is not null
                    then e.insurer_share_id = v_share_id
                    else e.insurer_share_id is null end
         order by case e.status when 'deferred' then 0 when 'earned' then 1 else 2 end,
                  e.created_at, e.id
      loop
        exit when v_claw_left <= 0;
        v_take := least(v_claw_left, greatest(ce.available, 0));
        continue when v_take <= 0;
        v_claw_lines := v_claw_lines || jsonb_build_object(
          'gl_account_id', case when ce.status = 'deferred' then v_unearned else v_income end,
          'debit', v_take, 'currency', p.currency,
          'description', v_desc || ' - commission clawback');
        insert into ins_endorsement_clawbacks(id, tenant_id, endorsement_id, commission_entry_id, amount)
        values (gen_random_uuid(), c.tenant_id, c.id, ce.id, v_take);
        v_claw_left := v_claw_left - v_take;
      end loop;
      if v_claw_left > 0 then
        raise exception 'INS_ENDORSEMENT_HISTORY: the policy''s commission cannot cover this clawback';
      end if;
    end if;
  end loop;

  -- The return-side adjustments journal: clawback debits, clearing balance.
  if jsonb_array_length(v_claw_lines) > 0 then
    v_debit_total := (select coalesce(sum((l ->> 'debit')::numeric), 0) from jsonb_array_elements(v_claw_lines) l);
    -- The balancing clearing line joins the array FIRST so the E3 mapping
    -- below stamps it too.
    v_claw_lines := v_claw_lines || jsonb_build_object('gl_account_id', v_clearing, 'credit', v_debit_total);
    if p.currency is distinct from fin_ledger_currency(c.tenant_id) then
      -- E3/3d-3 convention: every adjustment leg rides the policy's currency at
      -- the posting-date rate, so the clearing account nets to zero in the
      -- currency and in base (the balancing line must not fall back to the
      -- ledger currency).
      v_claw_lines := (select jsonb_agg(value || jsonb_build_object('currency', p.currency))
                         from jsonb_array_elements(v_claw_lines) value);
    end if;
    je := post_journal_entry(c.tenant_id, 'ins_policy_endorsement', c.id, current_date,
      v_desc || ': commission clawback', v_claw_lines);
    je_adj := je.id;
  end if;
  -- Recovery items name the adjustments journal (created after posting, the
  -- cancellation pattern).
  for v_todo in select * from jsonb_array_elements(v_recos) loop
    created_item := fin_create_open_item_fx(c.tenant_id, (v_todo ->> 'party')::uuid,
      (v_todo ->> 'role'), (v_todo ->> 'source_type'), (v_todo ->> 'source_id')::uuid,
      c.endorsement_no, current_date, current_date, (v_todo ->> 'amount')::numeric,
      'Endorsement recovery: ' || p.policy_no, p.currency, je_adj);
  end loop;
  -- The additional-side journal, then one client item for the whole
  -- endorsement, and per-insurer payable items. Each insurer item is keyed by
  -- its deferred commission entry (created first, naming the item once it
  -- exists): when that item is fully paid, the recognition trigger earns
  -- exactly that entry.
  if jsonb_array_length(v_add_lines) > 0 then
    je := post_journal_entry(c.tenant_id, 'ins_policy_endorsement', c.id, current_date, v_desc, v_add_lines);
    je_add := je.id;
    created_item := fin_create_open_item_fx(c.tenant_id, v_client_acc, 'ar_control',
      'ins_policy_endorsement', c.id, c.endorsement_no, current_date, current_date,
      (select sum((v ->> 'premium')::numeric) from jsonb_array_elements(v_add_items) v),
      'Endorsement premium due: ' || p.policy_no, p.currency, je_add);
    v_first_premium_item := created_item.id;
  end if;
  for v_todo in select * from jsonb_array_elements(v_add_items) loop
    -- The commission entry is born first (open items are immutable, so the
    -- item must carry its final source at birth); the item then carries the
    -- entry's id as its source, and the entry names the item whose full
    -- payment earns it.
    if (v_todo ->> 'commission')::numeric > 0 then
      insert into ins_commission_entries(id, tenant_id, policy_id, amount, status, insurer_share_id)
      values (gen_random_uuid(), c.tenant_id, p.id, (v_todo ->> 'commission')::numeric, 'deferred',
              (v_todo ->> 'share_id')::uuid)
      returning id into note_id;
      v_new_entries := v_new_entries || to_jsonb(note_id);
    else
      note_id := null;
    end if;
    created_item := fin_create_open_item_fx(c.tenant_id,
      ins_ensure_insurer_account((v_todo ->> 'insurer_id')::uuid), 'insurer_payable',
      'ins_policy_endorsement_insurer', note_id, c.endorsement_no, current_date, current_date,
      (v_todo ->> 'net')::numeric, 'Net premium payable to insurer: ' || p.policy_no, p.currency, je_add);
    if note_id is not null then
      update ins_commission_entries set source_open_item_id = created_item.id where id = note_id;
    end if;
  end loop;

  update ins_policy_endorsements
     set status = 'posted',
         journal_entry_id = coalesce(je_adj, je_add),
         premium_item_id = v_first_premium_item,
         credit_note_ids = v_credit_notes,
         commission_entry_ids = v_new_entries,
         operation_txid = null
   where id = c.id
   returning * into c;
  insert into ins_policy_endorsement_events(tenant_id, endorsement_id, event, actor_id, detail)
  values (c.tenant_id, c.id, 'posted', auth.uid(), jsonb_build_object(
    'review_note', p_review_note,
    'manual_exception_accepted', coalesce(p_accept_manual_exception, false),
    'adjustment_journal', je_adj, 'additional_journal', je_add,
    'credit_notes', v_credit_notes));
  return c;
end $function$;


revoke all on function public.ins_decide_policy_endorsement(uuid, text, text, boolean) from public, anon;
grant execute on function public.ins_decide_policy_endorsement(uuid, text, text, boolean) to authenticated;
