-- Phase A, A3 slice 3d-3 (see docs/insurance-brokerage/CURRENCY_REVIEW.md): the
-- cancellation pipeline may run on a foreign policy. The explicit guard from 3d-2
-- (INS_CANCELLATION_CURRENCY) comes off.
--
-- What changes:
--   1. platform_ins_cancellation_credit (the credit note against an original premium or
--      insurer item) is foreign-aware: the note takes the item's currency; the control
--      side returns the item at the rate it was booked at (naming the booking entry as
--      its rate source), the clearing side takes the cancellation-date rate, and the
--      difference books as realised gain or loss -- the receivable side signs like a
--      receipt, the payable side mirrors a payment. Functional policies post exactly as
--      before.
--   2. ins_decide_policy_cancellation posts the adjustment journal in the policy's
--      currency (every line at the cancellation-date rate), and creates the refund and
--      insurer-recovery items with the booking entry (fin_create_open_item_fx) once the
--      journal is posted -- for functional policies this only adds the entry link. The
--      retained-commission recognition posts at the rate the policy was bound at (the
--      bind entry is its rate source), matching the settlement-triggered recognition.
--   3. Because the credit-note control sides sit at the booked rate while everything
--      else sits at the cancellation-date rate, the clearing account still nets to zero
--      in the policy currency AND in base (every clearing leg is at one rate), and the
--      control accounts return to zero. The unearned-commission account can keep a small
--      base residue (clawback at the cancellation rate against a bind at the bound rate);
--      period-end revaluation (slice 3e) is what clears residues like that.
--   4. The 3d-2 guard trigger is dropped. The cash side already demanded a bank account
--      in the policy's currency, so nothing else changes.
--
-- What remains of slice 3: period-end revaluation (3e), then the UGX column defaults
-- and the 8-versus-10-decimal rate question before any non-UGX company is enabled.

-- =====================================================================
-- A. The credit note against an original item
-- =====================================================================
create or replace function public.platform_ins_cancellation_credit(p_cancellation_id uuid, p_item_id uuid, p_amount numeric)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare c ins_policy_cancellations%rowtype; i fin_open_items%rowtype; nid uuid:=gen_random_uuid(); no text; je journal_entries%rowtype; lines jsonb; control uuid;
 v_functional text; v_ccy text; v_foreign boolean; v_nr numeric:=1; v_rate numeric:=1; v_booked numeric; v_base numeric; v_result numeric:=0; v_fx jsonb;
begin
 c:=platform_ins_cancellation_context(p_cancellation_id);
 select * into i from fin_open_items where id=p_item_id and tenant_id=c.tenant_id for update;
 if not found or i.control_role not in('ar_control','insurer_payable') or p_amount<=0 or p_amount<>round(p_amount,2) then raise exception 'INS_CANCELLATION_CONTEXT: invalid original credit target'; end if;
 if not exists(select 1 from ins_policy_cash_items m where m.id=i.id and m.source_id=c.policy_id and m.source_type in('ins_policy_premium','ins_policy_insurer')) then raise exception 'INS_CANCELLATION_CONTEXT: target outside original policy'; end if;
 no:=next_doc_number(c.tenant_id,'fin_credit_note','CRN'); control:=(c.accounting_mappings->>case i.control_role when 'ar_control' then 'ar' else 'payable' end)::uuid;
 v_functional:=fin_ledger_currency(c.tenant_id);
 v_ccy:=i.currency; v_foreign:=v_ccy is distinct from v_functional;
 if v_foreign then
  -- The original item must carry the rate it was booked at; the note-date rate prices
  -- the clearing side, and the difference is realised.
  if i.journal_entry_id is null or i.fx_rate is null or i.fx_rate<=0 then
   raise exception 'INS_CANCELLATION_RATE: the original item has no booked rate, so it cannot be credited in %', v_ccy;
  end if;
  v_rate:=i.fx_rate;
  v_nr:=round((platform_fx_rate(c.tenant_id,v_ccy,current_date)).rate,8);
  v_booked:=round(p_amount*v_rate,2);
  v_base:=round(p_amount*v_nr,2);
  v_result:=case i.side when 'receivable' then v_base-v_booked else v_booked-v_base end;
 end if;
 insert into ins_cancellation_credit_links(tenant_id,cancellation_id,credit_note_id,open_item_id,amount) values(c.tenant_id,c.id,nid,i.id,p_amount);
 insert into fin_credit_notes(id,tenant_id,credit_note_no,side,control_role,party_account_id,offset_gl_account_id,amount,currency,fx_rate,realised_result,credit_date,reason,reference)
 values(nid,c.tenant_id,no,i.side,i.control_role,i.party_account_id,c.clearing_gl_account_id,p_amount,v_ccy,v_nr,v_result,current_date,c.reason,c.cancellation_no);
 insert into fin_credit_applications(tenant_id,credit_note_id,open_item_id,amount) values(c.tenant_id,nid,i.id,p_amount);
 lines:=case i.side when 'receivable' then jsonb_build_array(jsonb_build_object('gl_account_id',c.clearing_gl_account_id,'debit',p_amount),jsonb_build_object('gl_account_id',control,'credit',p_amount))
 else jsonb_build_array(jsonb_build_object('gl_account_id',control,'debit',p_amount),jsonb_build_object('gl_account_id',c.clearing_gl_account_id,'credit',p_amount)) end;
 if v_foreign then
  -- Control side at the booked rate (naming the booking entry); clearing side at today's rate.
  lines:=(select jsonb_agg(case when (x->>'gl_account_id')::uuid=control
           then x||jsonb_build_object('currency',v_ccy,'rate_from_entry',i.journal_entry_id,'fx_rate',v_rate)
           else x||jsonb_build_object('currency',v_ccy) end)
          from jsonb_array_elements(lines) x);
  v_fx:=platform_fx_realised_line(c.tenant_id,v_result,'Realised exchange result on '||no);
  if v_fx is not null then lines:=lines||v_fx; end if;
 end if;
 je:=post_journal_entry(c.tenant_id,'fin_credit_note',nid,current_date,'Cancellation credit '||c.cancellation_no,lines);
 update fin_credit_notes set journal_entry_id=je.id where id=nid;
 insert into ins_cancellation_journals values(c.tenant_id,c.id,je.id,'original_item_credit');
 return nid;
end $function$;

-- =====================================================================
-- B. The Finance decision: posting in the policy's currency
-- =====================================================================
create or replace function public.ins_decide_policy_cancellation(p_cancellation_id uuid, p_decision text, p_review_note text, p_accept_manual_exception boolean DEFAULT false)
 returns ins_policy_cancellations
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare c ins_policy_cancellations%rowtype; p ins_policies%rowtype; pid uuid; fresh jsonb; mappings jsonb; cash jsonb;
 client_item fin_open_items%rowtype; item fin_open_items%rowtype; created_item fin_open_items%rowtype; ce ins_commission_entries%rowtype;
 line jsonb; charge jsonb; outstanding numeric; amount numeric; applied numeric; recovered numeric; remaining numeric; claw numeric;
 target_status text; adjustment_id uuid; insurer uuid; share_id uuid; lines jsonb:='[]'; debit_total numeric:=0; recognition_lines jsonb:='[]'; recognized numeric:=0;
 je journal_entries%rowtype; transfer_due numeric; client_credit numeric; refund numeric;
 v_functional text; v_foreign boolean; v_items jsonb:='[]'::jsonb; v_todo jsonb; v_bound_rate numeric;
begin
 perform ins_policy_cash_require_finance();
 if p_decision not in('approve','reject') or p_decision is null or p_review_note is null or length(btrim(p_review_note)) not between 5 and 2000 then
  raise exception 'INS_CANCELLATION_INPUT: decision and detailed Finance review note required'; end if;
 select policy_id into pid from ins_policy_cancellations where id=p_cancellation_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: cancellation'; end if;
 select * into p from ins_policies where id=pid and tenant_id=get_my_tenant_id() for update;
 select * into c from ins_policy_cancellations where id=p_cancellation_id for update;
 if c.prepared_by=auth.uid() or c.proposed_by=auth.uid() then raise exception 'INS_CANCELLATION_SELF_APPROVAL: an independent Finance checker is required'; end if;
 if c.status='posted' and p_decision='approve' and c.checked_by=auth.uid() then
  if c.review_note is distinct from btrim(p_review_note) or c.manual_exception_accepted is distinct from coalesce(p_accept_manual_exception,false) then raise exception 'INS_CANCELLATION_RETRY_CONFLICT: different approval payload'; end if;
  return c;
 end if;
 if p_decision='reject' then
  if c.status not in('proposed','prepared') then raise exception 'INS_CANCELLATION_STATE: open proposal required'; end if;
  update ins_policy_cancellations set status='rejected',checked_by=auth.uid(),checked_at=now(),review_note=btrim(p_review_note) where id=c.id returning * into c;
  insert into ins_cancellation_events(tenant_id,cancellation_id,event,actor_id,detail) values(c.tenant_id,c.id,'rejected',auth.uid(),jsonb_build_object('note',p_review_note));
  return c;
 end if;
 if c.status<>'prepared' then raise exception 'INS_CANCELLATION_STATE: Finance preparation required before approval'; end if;
 -- Serialize with cash approvals, claims, credits and commission transfers.
 perform m.id from fin_open_items m join ins_policy_cash_items k on k.id=m.id where k.source_id=p.id and k.tenant_id=p.tenant_id order by m.id for update of m;
 perform e.id from ins_commission_entries e where e.policy_id=p.id order by e.id for update;
 fresh:=ins_preview_policy_cancellation(p.id,c.effective_date,c.insurer_terms,c.charge_refunds)||platform_ins_cancellation_review_position(p.id);
 if exists(select 1 from accounting_periods where tenant_id=p.tenant_id and status='closed' and current_date between period_start and period_end) then raise exception 'INS_CANCELLATION_PERIOD: current accounting period closed'; end if;
 if (fresh-'generated_at') is distinct from (c.calculation-'generated_at') then raise exception 'INS_CANCELLATION_STALE: amounts or collection position changed; Finance maker must refresh preparation'; end if;
 if (fresh->>'requires_finance_exception')::boolean and not coalesce(p_accept_manual_exception,false) then raise exception 'INS_CANCELLATION_EXCEPTION: explicit independent Finance acceptance of the documented manual exception required'; end if;
 mappings:=platform_ins_cancellation_mappings(p.id,c.clearing_gl_account_id);
 if mappings is distinct from c.accounting_mappings then raise exception 'INS_CANCELLATION_STALE: accounting mappings changed'; end if;
 cash:=ins_policy_cash_totals(p.id);
 v_functional:=fin_ledger_currency(p.tenant_id);
 v_foreign:=p.currency is distinct from v_functional;
 -- Existing credits to any insurer payable would otherwise double-adjust its
 -- original bound obligations. Treat them as an exception, not as cash paid.
 if exists(select 1 from fin_credit_applications a join fin_credit_notes n on n.id=a.credit_note_id and n.status='posted'
   join ins_policy_cash_items k on k.id=a.open_item_id where k.source_id=p.id and k.source_type='ins_policy_insurer') then
  raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: original insurer credits need separate Finance review'; end if;
 update ins_policy_cancellations set status='posting',checked_by=auth.uid(),checked_at=now(),review_note=btrim(p_review_note),manual_exception_accepted=coalesce(p_accept_manual_exception,false),
  posting_date=current_date,cancellation_no=next_doc_number(c.tenant_id,'ins_policy_cancellation','CXL'),cash_at_posting=cash,operation_txid=txid_current() where id=c.id returning * into c;
 select * into client_item from fin_open_items where tenant_id=p.tenant_id and source_type='ins_policy_premium' and source_id=p.id;
 client_credit:=(fresh->>'receivable_credit')::numeric; refund:=(fresh->>'client_refund_due')::numeric;
 if client_credit>0 then perform platform_ins_cancellation_credit(c.id,client_item.id,client_credit); end if;
 if refund>0 then
  -- The refund item is created after the journal posts, so it can name its booking entry.
  v_items:=v_items||jsonb_build_object('kind','refund','party',client_item.party_account_id,'amount',refund);
  lines:=lines||jsonb_build_array(jsonb_build_object('gl_account_id',c.clearing_gl_account_id,'debit',refund),jsonb_build_object('gl_account_id',(mappings->>'refund_payable')::uuid,'credit',refund));
 end if;
 for line in select value from jsonb_array_elements(fresh->'insurers') loop
  insurer:=(line->>'insurer_id')::uuid; amount:=(line->>'total_insurer_credit')::numeric; claw:=(line->>'commission_clawback')::numeric;
  select id into share_id from ins_policy_insurer_shares where policy_id=p.id and insurer_id=insurer;
  select i.* into item from fin_open_items i join ins_policy_cash_items k on k.id=i.id
   where k.source_id=p.id and k.source_type='ins_policy_insurer' and k.tenant_id=p.tenant_id
    and (k.insurer_share_id=share_id or (k.insurer_share_id is null and insurer=p.insurer_id));
  if not found then raise exception 'INS_CANCELLATION_HISTORY: original insurer item missing'; end if;
  select outstanding_amount into outstanding from fin_open_item_balances where id=item.id;
  applied:=least(outstanding,amount); recovered:=amount-applied;
  select * into ce from ins_commission_entries where policy_id=p.id and insurer_share_id is not distinct from
   (case when exists(select 1 from ins_policy_financial_snapshots where policy_id=p.id and extended) then share_id else null end);
  if (line->>'original_commission')::numeric>0 and (mappings->>'commission_treatment')='deferred' and ce.id is null then raise exception 'INS_CANCELLATION_HISTORY: original commission entry missing'; end if;
  if ce.id is not null and ce.amount<>(line->>'original_commission')::numeric then raise exception 'INS_CANCELLATION_HISTORY: original commission amount differs'; end if;
  remaining:=(line->>'original_commission')::numeric-claw;
  target_status:=case when ce.id is null then 'legacy' when ce.status='transferred' then 'transferred' when ce.status='earned' then 'earned'
   when outstanding-applied=0 and remaining>0 then 'earned' else 'deferred' end;
  transfer_due:=case when ce.status='transferred' then claw else 0 end;
  adjustment_id:=gen_random_uuid();
  insert into ins_cancellation_insurer_adjustments(id,tenant_id,cancellation_id,insurer_id,insurer_share_id,original_item_id,original_commission_entry_id,original_commission_state,
   return_premium,commission_clawback,pass_through_refund,total_insurer_credit,payable_credit,recovery_due,retained_commission,retained_commission_status,transferred_clawback_due)
  values(adjustment_id,c.tenant_id,c.id,insurer,share_id,item.id,ce.id,case when ce.id is not null then to_jsonb(ce) else null end,
   (line->>'return_premium')::numeric,claw,(line->>'pass_through_refund')::numeric,amount,applied,recovered,remaining,target_status,transfer_due);
  if applied>0 then perform platform_ins_cancellation_credit(c.id,item.id,applied); end if;
  if recovered>0 then
   v_items:=v_items||jsonb_build_object('kind','recovery','party',item.party_account_id,'adjustment',adjustment_id,'amount',recovered);
   lines:=lines||jsonb_build_array(jsonb_build_object('gl_account_id',(mappings->>'ar')::uuid,'debit',recovered),jsonb_build_object('gl_account_id',c.clearing_gl_account_id,'credit',recovered));
  end if;
  if claw>0 then
   lines:=lines||jsonb_build_object('gl_account_id',(mappings->>case when ce.id is not null and ce.status='deferred' then 'unearned' else 'income' end)::uuid,'debit',claw);
   debit_total:=debit_total+claw;
  end if;
  if ce.status='deferred' and target_status='earned' and remaining>0 then
   if v_foreign then
    -- Recognition releases the unearned commission at the rate the policy was bound at,
    -- the same convention as the settlement-triggered recognition.
    if v_bound_rate is null then
     if p.journal_entry_id is null then raise exception 'INS_CANCELLATION_RATE: the policy has no bind journal, so its commission rate is unknown'; end if;
     select l.fx_rate into v_bound_rate from journal_entry_lines l
      where l.journal_entry_id=p.journal_entry_id and l.tenant_id=p.tenant_id and l.currency=p.currency
        and l.gl_account_id=(mappings->>'unearned')::uuid
      order by l.id limit 1;
     if v_bound_rate is null then raise exception 'INS_CANCELLATION_RATE: the bind journal has no % line on unearned commission, so the booked rate is unknown', p.currency; end if;
    end if;
    recognition_lines:=recognition_lines||jsonb_build_array(
     jsonb_build_object('gl_account_id',(mappings->>'unearned')::uuid,'debit',remaining)||jsonb_build_object('currency',p.currency,'rate_from_entry',p.journal_entry_id,'fx_rate',v_bound_rate),
     jsonb_build_object('gl_account_id',(mappings->>'income')::uuid,'credit',remaining)||jsonb_build_object('currency',p.currency,'rate_from_entry',p.journal_entry_id,'fx_rate',v_bound_rate));
   else
    recognition_lines:=recognition_lines||jsonb_build_array(jsonb_build_object('gl_account_id',(mappings->>'unearned')::uuid,'debit',remaining),jsonb_build_object('gl_account_id',(mappings->>'income')::uuid,'credit',remaining));
   end if;
   recognized:=recognized+remaining;
  end if;
 end loop;
 for charge in select value from jsonb_array_elements(fresh->'charges') where value->>'kind'='broker_fee' loop
  if (charge->>'refund_base')::numeric>0 then
   lines:=lines||jsonb_build_object('gl_account_id',(charge->>'income_gl_account_id')::uuid,'debit',(charge->>'refund_base')::numeric);
   debit_total:=debit_total+(charge->>'refund_base')::numeric;
  end if;
  if (charge->>'refund_vat')::numeric>0 then
   lines:=lines||jsonb_build_object('gl_account_id',(mappings->>'vat')::uuid,'debit',(charge->>'refund_vat')::numeric);
   debit_total:=debit_total+(charge->>'refund_vat')::numeric;
  end if;
 end loop;
 if debit_total>0 then lines:=lines||jsonb_build_object('gl_account_id',c.clearing_gl_account_id,'credit',debit_total); end if;
 if jsonb_array_length(lines)>0 then
  if v_foreign then
   -- Every adjustment leg posts in the policy's currency at the cancellation-date rate,
   -- so the clearing account nets to zero in the currency and in base.
   lines:=(select jsonb_agg(value || jsonb_build_object('currency',p.currency)) from jsonb_array_elements(lines));
  end if;
  je:=post_journal_entry(c.tenant_id,'ins_policy_cancellation',c.id,current_date,'Cancellation '||c.cancellation_no||': '||c.reason,lines);
  insert into ins_cancellation_journals values(c.tenant_id,c.id,je.id,'cancellation_adjustments');
  for v_todo in select * from jsonb_array_elements(v_items) loop
   if v_todo->>'kind'='refund' then
    created_item:=fin_create_open_item_fx(c.tenant_id,(v_todo->>'party')::uuid,'ap_control','ins_cancellation_client_refund',c.id,c.cancellation_no,current_date,current_date,(v_todo->>'amount')::numeric,'Client refund due: '||p.policy_no,p.currency,je.id);
    update ins_policy_cancellations set refund_item_id=created_item.id where id=c.id;
   else
    created_item:=fin_create_open_item_fx(c.tenant_id,(v_todo->>'party')::uuid,'ar_control','ins_cancellation_insurer_recovery',(v_todo->>'adjustment')::uuid,c.cancellation_no,current_date,current_date,(v_todo->>'amount')::numeric,'Insurer recovery: '||p.policy_no,p.currency,je.id);
    update ins_cancellation_insurer_adjustments set recovery_item_id=created_item.id where id=(v_todo->>'adjustment')::uuid;
   end if;
  end loop;
 end if;
 if recognized>0 then
  declare recognition journal_entries%rowtype; begin
   recognition:=post_journal_entry(c.tenant_id,'ins_policy_cancellation',gen_random_uuid(),current_date,'Retained commission earned: '||c.cancellation_no,recognition_lines);
   insert into ins_cancellation_journals values(c.tenant_id,c.id,recognition.id,'retained_commission_recognition');
  end;
 end if;
 update ins_policy_cancellations set status='posted',journal_entry_id=je.id,operation_txid=null where id=c.id returning * into c;
 perform set_config('ins.via_rpc','on',true);
 update ins_policies set status='cancelled' where id=p.id;
 update ins_policy_cash_requests set status='cancelled',checker_id=null,checked_at=now(),decision_reason='Policy cancellation posted: '||c.cancellation_no
  where policy_id=p.id and status='pending';
 insert into ins_cancellation_events(tenant_id,cancellation_id,event,actor_id,detail) values(c.tenant_id,c.id,'posted',auth.uid(),jsonb_build_object('review_note',p_review_note,'manual_exception_accepted',p_accept_manual_exception,'cash_authorized',false));
 return c;
end $function$;

-- =====================================================================
-- C. The 3d-2 guard comes off
-- =====================================================================
drop trigger if exists trg_ins_cancellation_currency on public.ins_policy_cancellations;
drop function if exists public.ins_cancellation_currency_guard();
