-- =====================================================================
-- Insurance: application dates follow the Africa/Kampala business day
-- =====================================================================
--
-- 20261121140000 moved the reports to the Kampala business day through
-- public.ins_local_date() and public.ins_local_today(). The functions that
-- post and validate business records still compared dates with current_date,
-- which is the UTC date on Supabase. Between 00:00 and 03:00 Kampala time that
-- is still "yesterday", so those functions refused today's date ("must not be
-- in the future"), stamped posting dates a day early, refused to void a receipt
-- posted minutes earlier, and disagreed with the reports.
--
-- This migration redefines 52 functions so they use the same two helpers
-- (107 expressions replaced). Each body is the live definition with only
-- "current_date" and "<timestamp column>_at::date" replaced; logic, security
-- settings and search_path are unchanged, and grants are kept because the
-- functions are replaced in place. Argument defaults of the form
-- "p_as_of date default current_date" are replaced the same way.
--
-- Three groups:
--   1. 37 ins_* functions (policy, cancellation, endorsement, claim, quote,
--      intermediary and commission functions, charge pricing, and the remittance,
--      unremitted premium and statutory enforcement reports).
--   2. 8 insurance-path functions without the ins_ prefix (cancellation
--      cash and credit, policy cash validation, reversal, policy versioning).
--   3. 7 SHARED finance functions on the receipt and credit-note path:
--      the void and raise functions for settlements and credit notes. A receipt
--      posted on the Kampala date has to be voidable on that same date, so these
--      cannot stay on UTC while the insurance side moves. They are shared with
--      other modules, which now date these actions by the Kampala day too.
--
-- Also: the three insurance column defaults that used CURRENT_DATE
-- (ins_claims.notified_date, ins_insurer_statements.received_date,
-- ins_policy_reversals.reversal_date) now default to ins_local_today(), and the
-- helpers are granted to service_role as well, because defaults are evaluated as
-- the calling role.
--
-- NOT changed (not insurance, need their own decision): 14 other public
-- functions that use current_date, among them the generic finance reports
-- (fin_trial_balance, fin_account_ledger, fin_bank_reconciliation_position),
-- void_journal_entry, FX revaluation and rate lookup, accounting settings and
-- the regulatory parameter functions, maintenance, sustainability and payroll;
-- and the CURRENT_DATE column defaults of goods_issues, pmo_cost_entries,
-- pmo_time_entries and sustainability_metrics.
--
-- Group 1:
--   ins_price_charges
--   ins_agent_commission_accrue
--   ins_agent_commission_mark_eligible
--   ins_agent_commission_reverse
--   ins_agent_commission_statement
--   ins_approve_endorsement_cancellation
--   ins_cancelled_policy_guard
--   ins_commission_on_settlement_voided
--   ins_create_claim
--   ins_decide_cancellation_cash
--   ins_decide_policy_cancellation
--   ins_decide_policy_endorsement
--   ins_endorsement_unwind_position
--   ins_fee_withholding_position
--   ins_generate_renewal_notices
--   ins_import_create_batch
--   ins_place_quote
--   ins_policy_cash_validate
--   ins_preview_policy_cancellation
--   ins_preview_policy_endorsement
--   ins_recognise_claim_receivable
--   ins_record_claim_payment
--   ins_renewal_notification_sweep
--   ins_reverse_policy
--   ins_save_intermediary
--   ins_set_intermediary_status
--   ins_share_basis
--   ins_submit_cancellation_cash_void
--   ins_submit_quote
--   ins_verify_intermediary
--   ins_void_claim_payment
--   ins_void_commission_transfer
--   ins_wht_prepare_remittance
--   ins_insurer_remittance_position
--   ins_price_charges_for
--   ins_statutory_enforcement
--   ins_unremitted_premium_report
-- Group 2:
--   fin_trace
--   platform_ins_cancellation_cash_recognize
--   platform_ins_cancellation_cash_validate
--   platform_ins_cancellation_credit
--   platform_ins_policy_cash_legacy_validate
--   platform_ins_policy_reversal_legacy_context
--   platform_ins_transfer_before_cancellation_impl
--   platform_stamp_policy_version
-- Group 3:
--   platform_fin_raise_policy_credit_note_impl
--   platform_fin_record_settlement_impl
--   platform_fin_raise_credit_note_impl
--   platform_fin_void_credit_note_impl
--   platform_fin_void_settlement_impl
--   fin_void_credit_note
--   fin_void_settlement
-- =====================================================================

grant execute on function public.ins_local_date(timestamptz) to service_role;
grant execute on function public.ins_local_today() to service_role;

CREATE OR REPLACE FUNCTION public.ins_agent_commission_accrue(p_policy_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  p        public.ins_policies;
  v_calc   jsonb;
  v_row    public.ins_agent_commission_accruals;
  v_expense uuid;
  v_ap      uuid;
  v_wht_gl  uuid;
  v_je      public.journal_entries;
  v_amt     numeric;
  v_net     numeric;
  v_lines   jsonb;
  v_je_key  uuid := gen_random_uuid();
begin
  select * into p from public.ins_policies
   where id = p_policy_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_POLICY_NOT_FOUND'; end if;

  if p.agent_id is null then
    return jsonb_build_object('accrued', false, 'reason', 'the policy names no agent');
  end if;

  v_calc := public.ins_agent_commission_calculate(p_policy_id, p.agent_id);

  if not coalesce((v_calc ->> 'payable_by_brokerage')::boolean, false) then
    -- The insurer-appointed case, or a term whose basis is none. Not an error:
    -- this is the correct answer, and it must not put anything on the books.
    return jsonb_build_object('accrued', false, 'reason', v_calc ->> 'reason',
                              'intermediary_id', p.agent_id, 'category', v_calc ->> 'category');
  end if;

  -- Idempotent: one LIVE accrual per policy and intermediary, ever.
  --
  -- Reversed accruals are excluded rather than counted. They used to count, and
  -- because the table also carries a UNIQUE (tenant_id, policy_id,
  -- intermediary_id) key, the effect was that reversing a share retired that
  -- policy's agent commission permanently: a corrected re-accrual was refused
  -- first by this lookup and then by the constraint. The repair path for a
  -- wrongly-accrued share is reverse-then-re-accrue, so that path has to exist.
  select * into v_row from public.ins_agent_commission_accruals
   where tenant_id = v_tenant and policy_id = p_policy_id
     and intermediary_id = p.agent_id
     and status <> 'reversed';
  if found then
    return jsonb_build_object('accrued', false, 'already_accrued', true,
                              'accrual_id', v_row.id, 'gross_amount', v_row.gross_amount,
                              'status', v_row.status);
  end if;

  v_amt := (v_calc ->> 'gross_amount')::numeric;
  -- The accrual carries no withholding. It recognises the cost and a payable of
  -- the same size; tax is taken out of that payable when it is paid, not before,
  -- because until then nothing has been paid and s.134 has nothing to bite on.
  v_net := round(v_amt, 2);

  v_expense := public.get_posting_account(v_tenant, 'agent_commission_expense');
  v_ap      := public.get_posting_account(v_tenant, 'ap_control');
  if v_expense is null or v_ap is null then
    raise exception 'INS_POSTING_RULE_MISSING: agent commission needs the agent_commission_expense and ap_control posting rules before a share can be accrued';
  end if;

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_expense, 'debit', v_amt,
                       'currency', p.currency,
                       'description', 'Agent share of commission on ' || p.policy_no),
    jsonb_build_object('gl_account_id', v_ap, 'credit', v_net,
                       'currency', p.currency,
                       'description', 'Payable to agent for ' || p.policy_no));

  v_je := public.post_journal_entry(
    v_tenant, 'ins_agent_commission_accrual', v_je_key, public.ins_local_date(p.bound_at),
    'Agent commission accrued on ' || p.policy_no, v_lines);

  perform set_config('ins.via_wht_calc', 'on', true);
  insert into public.ins_agent_commission_accruals
    (tenant_id, policy_id, intermediary_id, term_id, basis, rate_pct, fixed_amount,
     commission_base, gross_amount, wht_amount, currency, status, journal_entry_id,
     wht_rate_pct, wht_is_final, wht_parameter_ref, net_amount)
  values
    (v_tenant, p_policy_id, p.agent_id, (v_calc ->> 'term_id')::uuid, v_calc ->> 'basis',
     (v_calc ->> 'rate_pct')::numeric, (v_calc ->> 'fixed_amount')::numeric,
     (v_calc ->> 'commission_base')::numeric, v_amt,
     0, p.currency, 'accrued', v_je.id,
     null::numeric, null::boolean,
     null::uuid, v_net)
  returning * into v_row;
  perform set_config('ins.via_wht_calc', 'off', true);

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, journal_entry_id, note)
  values (v_tenant, v_row.id, 'accrued', v_amt, v_je.id,
          'share of the brokerage''s commission, basis ' || v_row.basis
          || '; withholding is determined when the share is paid');

  return jsonb_build_object('accrued', true, 'accrual_id', v_row.id,
                            'gross_amount', v_amt, 'wht_amount', 0,
                            'net_amount', v_net, 'status', 'accrued',
                            'journal_entry_id', v_je.id,
                            'wht_not_yet_determined', true);
end
$function$;

CREATE OR REPLACE FUNCTION public.ins_agent_commission_mark_eligible(p_policy_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  r        record;
  v_n      integer := 0;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  for r in
    select x.*
      from public.ins_agent_commission_accruals x
     where x.tenant_id = v_tenant
       and x.status = 'accrued'
       and (p_policy_id is null or x.policy_id = p_policy_id)
       and exists (
         -- The brokerage's own commission on this policy has actually been
         -- earned, which is the condition that makes the share fundable.
         select 1 from public.ins_commission_entries e
          where e.policy_id = x.policy_id and e.tenant_id = v_tenant
            and e.status in ('earned', 'transferred'))
     order by x.created_at
     for update of x
  loop
    update public.ins_agent_commission_accruals
       set status = 'eligible', eligible_on = public.ins_local_today(), updated_at = now()
     where id = r.id;
    insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, note)
    values (v_tenant, r.id, 'eligible', r.gross_amount,
            'the brokerage''s commission on this policy is earned, so the share is payable');
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('marked_eligible', v_n);
end
$function$;

CREATE OR REPLACE FUNCTION public.ins_agent_commission_reverse(p_accrual_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  x        public.ins_agent_commission_accruals;
  v_expense uuid;
  v_ap      uuid;
  v_wht_gl  uuid;
  v_je      public.journal_entries;
  v_tax     numeric;
  v_net     numeric;
  v_lines   jsonb;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'INS_AGENT_REVERSAL_REASON: a reversal needs a reason of at least 10 characters; it is what somebody reads when the intermediary asks why they were not paid';
  end if;

  select * into x from public.ins_agent_commission_accruals
   where id = p_accrual_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_AGENT_ACCRUAL_NOT_FOUND'; end if;
  if x.status = 'reversed' then
    return jsonb_build_object('reversed', false, 'already_reversed', true, 'accrual_id', x.id);
  end if;
  if x.status = 'paid' then
    raise exception 'INS_AGENT_ALREADY_PAID: % has already been paid to the intermediary. Recovering it is a decision about the intermediary, not a journal the system should make on its own; raise a recovery and reverse this by hand once it is agreed',
      x.gross_amount;
  end if;

  -- Once the tax has gone to URA it cannot be un-withheld by a journal: the
  -- brokerage has paid somebody else's money over and recovering it is a
  -- conversation with the revenue authority.
  if coalesce(x.wht_amount, 0) > 0 and exists (
    select 1 from public.ins_wht_remittance_lines l
      join public.ins_wht_remittances r on r.id = l.remittance_id
     where l.tenant_id = v_tenant and l.accrual_id = x.id and r.status = 'paid'
  ) then
    raise exception 'INS_WHT_ALREADY_REMITTED: the % withheld on this share has already been paid to URA. Reverse it here only after the revenue authority has been dealt with; the tax cannot be un-withheld by a journal',
      x.wht_amount;
  end if;

  v_expense := public.get_posting_account(v_tenant, 'agent_commission_expense');
  v_ap      := public.get_posting_account(v_tenant, 'ap_control');
  if v_expense is null or v_ap is null then
    raise exception 'INS_POSTING_RULE_MISSING: reversing an agent share needs the agent_commission_expense and ap_control posting rules';
  end if;

  v_tax := coalesce(x.wht_amount, 0);
  v_net := coalesce(x.net_amount, x.gross_amount - v_tax);

  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_expense, 'credit', x.gross_amount,
                       'currency', x.currency,
                       'description', 'Reverse agent share: ' || btrim(p_reason)),
    jsonb_build_object('gl_account_id', v_ap, 'debit', v_net,
                       'currency', x.currency,
                       'description', 'Reverse agent payable: ' || btrim(p_reason)));

  if v_tax > 0 then
    v_wht_gl := public.get_posting_account(v_tenant, 'wht_payable');
    if v_wht_gl is null then
      raise exception 'INS_POSTING_RULE_MISSING: reversing a share that carried withholding needs the wht_payable posting rule';
    end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'gl_account_id', v_wht_gl, 'debit', v_tax,
      'currency', x.currency,
      'description', 'Reverse WHT withheld: ' || btrim(p_reason)));
  end if;

  v_je := public.post_journal_entry(
    v_tenant, 'ins_agent_commission_reversal', x.id, public.ins_local_today(),
    'Agent commission reversed: ' || btrim(p_reason), v_lines);

  update public.ins_agent_commission_accruals
     set status = 'reversed', reversal_reason = btrim(p_reason), updated_at = now()
   where id = x.id;

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, journal_entry_id, note)
  values (v_tenant, x.id, 'reversed', x.gross_amount, v_je.id, btrim(p_reason));

  return jsonb_build_object('reversed', true, 'accrual_id', x.id,
                            'amount', x.gross_amount, 'wht_reversed', v_tax,
                            'journal_entry_id', v_je.id);
end
$function$;

CREATE OR REPLACE FUNCTION public.ins_agent_commission_statement(p_intermediary_id uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  a        public.ins_intermediaries;
  v_rows   jsonb;
  v_gross  numeric := 0;
  v_wht    numeric := 0;
  v_net    numeric := 0;
  v_paid   numeric := 0;
  v_by_ccy jsonb;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  select * into a from public.ins_intermediaries
   where id = p_intermediary_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_INTERMEDIARY_NOT_FOUND'; end if;

  -- The window is the PAYMENT date. `coalesce(paid_on, created_at::date)` so an
  -- unpaid share still has a date to fall on: an agent asking "what is owed to me
  -- as at today" must see the shares that have not been paid yet, and they have no
  -- payment date. Reversed shares appear on neither side.
  select coalesce(jsonb_agg(jsonb_build_object(
           'accrual_id', x.id,
           'policy_no', p.policy_no,
           'currency', x.currency,
           'accrued_on', public.ins_local_date(x.created_at),
           'paid_on', x.paid_on,
           'statement_date', coalesce(x.paid_on, public.ins_local_date(x.created_at)),
           'basis', x.basis,
           'gross_amount', x.gross_amount,
           'wht_rate_pct', x.wht_rate_pct,
           'wht_amount', x.wht_amount,
           'wht_is_final', x.wht_is_final,
           'net_amount', x.net_amount,
           'status', x.status) order by coalesce(x.paid_on, public.ins_local_date(x.created_at)), x.created_at, x.id), '[]'::jsonb)
    into v_rows
    from public.ins_agent_commission_accruals x
    join public.ins_policies p on p.id = x.policy_id
   where x.tenant_id = v_tenant and x.intermediary_id = p_intermediary_id
     and x.status <> 'reversed'
     and (p_from is null or coalesce(x.paid_on, public.ins_local_date(x.created_at)) >= p_from)
     and (p_to   is null or coalesce(x.paid_on, public.ins_local_date(x.created_at)) <= p_to);

  -- The same filter the lines use, deliberately: two WHERE clauses that are meant
  -- to agree should be written as one expression, because the version that drifts
  -- is the version nobody reads twice.
  select coalesce(sum(x.gross_amount), 0),
         coalesce(sum(x.wht_amount), 0),
         coalesce(sum(coalesce(x.net_amount, x.gross_amount - x.wht_amount)), 0),
         coalesce(sum(case when x.status = 'paid'
                           then coalesce(x.net_amount, x.gross_amount - x.wht_amount)
                           else 0 end), 0)
    into v_gross, v_wht, v_net, v_paid
    from public.ins_agent_commission_accruals x
   where x.tenant_id = v_tenant and x.intermediary_id = p_intermediary_id
     and x.status <> 'reversed'
     and (p_from is null or coalesce(x.paid_on, public.ins_local_date(x.created_at)) >= p_from)
     and (p_to   is null or coalesce(x.paid_on, public.ins_local_date(x.created_at)) <= p_to);

  select coalesce(jsonb_agg(jsonb_build_object(
           'currency',         c.currency,
           'gross_commission', round(c.gross, 2),
           'wht_withheld',     round(c.wht, 2),
           'net_commission',   round(c.net, 2),
           'paid',             round(c.paid, 2),
           'outstanding',      round(c.net - c.paid, 2),
           'lines',            c.n) order by c.currency), '[]'::jsonb)
    into v_by_ccy
    from (
      select x.currency,
             count(*) as n,
             sum(x.gross_amount) as gross,
             sum(x.wht_amount) as wht,
             sum(coalesce(x.net_amount, x.gross_amount - x.wht_amount)) as net,
             sum(case when x.status = 'paid'
                      then coalesce(x.net_amount, x.gross_amount - x.wht_amount)
                      else 0 end) as paid
        from public.ins_agent_commission_accruals x
       where x.tenant_id = v_tenant and x.intermediary_id = p_intermediary_id
         and x.status <> 'reversed'
         and (p_from is null or coalesce(x.paid_on, public.ins_local_date(x.created_at)) >= p_from)
         and (p_to   is null or coalesce(x.paid_on, public.ins_local_date(x.created_at)) <= p_to)
       group by x.currency
    ) c;

  return jsonb_build_object(
    'intermediary_id', a.id,
    'name', a.name,
    'category', a.category,
    'from', p_from,
    'to', p_to,
    'gross_commission', v_gross,
    'wht_withheld',     v_wht,
    'net_commission',   v_net,
    'paid',             v_paid,
    'outstanding',      round(v_net - v_paid, 2),
    'by_currency',      v_by_ccy,
    'lines',            v_rows);
end
$function$;

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

CREATE OR REPLACE FUNCTION public.ins_cancelled_policy_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
 if old.status='cancelled' and new.status is distinct from old.status then raise exception 'INS_CANCELLATION_LOCKED: cancelled policies cannot reactivate'; end if;
 if new.status='cancelled' and old.status<>'cancelled' and not exists(select 1 from ins_policy_cancellations c where c.policy_id=new.id and c.tenant_id=new.tenant_id and c.status='posted' and c.checked_by=auth.uid() and c.posting_date=public.ins_local_today()) then
  raise exception 'INS_CANCELLATION_CONTEXT: use the independently approved cancellation workflow'; end if;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION public.ins_commission_on_settlement_voided()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_date := coalesce(v_date, public.ins_local_today());

  for r in
    select e.id as entry_id, e.amount, e.status as entry_status, e.earned_by,
           p.policy_no, i.currency as item_currency
    from fin_allocations al
    join fin_open_items i  on i.id = al.open_item_id and i.source_type in ('ins_policy_insurer','ins_policy_share_insurer')
    join ins_commission_entries e on ((e.insurer_share_id=i.source_id and i.source_type='ins_policy_share_insurer') or (e.policy_id=i.source_id and e.insurer_share_id is null and i.source_type='ins_policy_insurer')) and e.tenant_id=i.tenant_id
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

CREATE OR REPLACE FUNCTION public.ins_create_claim(p_policy_id uuid, p_loss_date date, p_notified_date date, p_loss_description text, p_insurer_claim_ref text DEFAULT NULL::text, p_reserve_amount numeric DEFAULT 0)
 RETURNS ins_claims
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := get_my_tenant_id();
  v_pol    ins_policies%rowtype;
  v_row    ins_claims%rowtype;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  select * into v_pol from ins_policies where id = p_policy_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  if v_pol.status = 'draft' then
    raise exception 'INS_CLAIM_STATE: a claim needs a bound policy';
  end if;
  if p_loss_date < v_pol.inception_date or p_loss_date > v_pol.expiry_date then
    raise exception 'INS_LOSS_OUTSIDE_POLICY: loss date % is outside the policy period % to %',
      p_loss_date, v_pol.inception_date, v_pol.expiry_date;
  end if;
  if nullif(btrim(p_loss_description), '') is null then
    raise exception 'INS_REQUIRED: describe the loss';
  end if;
  if coalesce(p_reserve_amount, 0) < 0 then
    raise exception 'INS_AMOUNT: reserve cannot be negative';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  insert into ins_claims (
    tenant_id, claim_no, policy_id, status, loss_date, notified_date,
    loss_description, insurer_claim_ref, reserve_amount
  ) values (
    v_tenant, next_doc_number(v_tenant, 'INS_CLAIM', 'CLM', 5), v_pol.id, 'notified', p_loss_date,
    coalesce(p_notified_date, public.ins_local_today()), btrim(p_loss_description),
    nullif(btrim(p_insurer_claim_ref), ''), coalesce(p_reserve_amount, 0)
  )
  returning * into v_row;

  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_tenant, v_row.id, null, 'notified', 'Claim notified');
  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_decide_cancellation_cash(p_request_id uuid, p_decision text, p_reason text)
 RETURNS ins_cancellation_cash_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare q ins_cancellation_cash_requests%rowtype; target ins_cancellation_cash_requests%rowtype; c ins_policy_cancellations%rowtype; s fin_settlements%rowtype; item uuid; v jsonb;
begin
 perform ins_policy_cash_require_finance();
 if p_decision is null or p_decision not in('approve','reject','cancel') or p_reason is null or length(btrim(p_reason)) not between 5 and 2000 then raise exception 'INS_CXL_CASH_INPUT: decision and detailed review note required'; end if;
 select cx.* into c from ins_policy_cancellations cx join ins_cancellation_cash_requests r on r.cancellation_id=cx.id where r.id=p_request_id and r.tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: cash request'; end if;
 -- All actors lock policy, banks in UUID order, request, then items/settlements.
 perform id from ins_policies where id=c.policy_id for update;
 perform id from fin_bank_accounts where tenant_id=c.tenant_id order by id for update;
 perform pg_advisory_xact_lock(hashtextextended('ins-cxl-cash-book:'||c.tenant_id::text,0));
 select * into q from ins_cancellation_cash_requests where id=p_request_id for update;
 if(p_decision='cancel' and q.maker_id<>auth.uid()) or(p_decision<>'cancel' and q.maker_id=auth.uid()) then raise exception 'INS_CXL_CASH_SELF_APPROVAL: maker cannot act as checker'; end if;
 if p_decision='approve' and q.status in('posted','voided') and q.checker_id=auth.uid() then return q; end if;
 if q.status<>'pending' then raise exception 'INS_CXL_CASH_STATE: pending request required'; end if;
 if p_decision in('reject','cancel') then
 update ins_cancellation_cash_requests set status=case p_decision when 'reject' then 'rejected' else 'cancelled' end,checker_id=case p_decision when 'reject' then auth.uid() end,checked_at=now(),decision_reason=btrim(p_reason) where id=q.id returning * into q;
 else
 if q.cash_date<>public.ins_local_today() or exists(select 1 from accounting_periods where tenant_id=c.tenant_id and status='closed' and public.ins_local_today() between period_start and period_end) then raise exception 'INS_CXL_CASH_PERIOD: current open posting date required; cancel and recreate stale-date requests'; end if;
 if q.kind<>'void' then item:=platform_ins_cancellation_cash_validate(c.id,q.kind,q.adjustment_id,q.bank_account_id,q.to_bank_account_id,q.amount,q.cash_date); end if;
 update ins_cancellation_cash_requests set status='posting',checker_id=auth.uid(),checked_at=now(),decision_reason=btrim(p_reason),operation_txid=txid_current() where id=q.id returning * into q;
 if q.kind='void' then
 select * into target from ins_cancellation_cash_requests where id=q.voids_request_id and cancellation_id=c.id and status='posted' for update;
 if not found then raise exception 'INS_CXL_CASH_VOID: target is not posted'; end if;
 if exists(select 1 from bank_reconciliations where settlement_id in(target.settlement_id,target.to_settlement_id)) then raise exception 'INS_CXL_CASH_MATCHED: unmatch both legs before requesting a void'; end if;
 if target.kind in('recovery','premium_receipt','commission_return') and exists(select 1 from ins_cancellation_cash_requests where cancellation_id=c.id and status='posted' and kind in('refund','remittance','commission_withdrawal')) then raise exception 'INS_CXL_CASH_FUNDS_IN_USE: reverse downstream cancellation payments first'; end if;
 if target.kind='remittance' and exists(select 1 from ins_cancellation_cash_requests where adjustment_id=target.adjustment_id and kind='commission_withdrawal' and status='posted') then raise exception 'INS_CXL_CASH_FUNDS_IN_USE: return the retained commission withdrawal first'; end if;
 if target.kind in('recovery','premium_receipt','commission_return') then
 v:=platform_ins_cancellation_cash_position(c.id,case target.kind when 'commission_return' then target.to_bank_account_id else target.bank_account_id end);
 if least((v->>'bank_raw_cash')::numeric,(v->>'bank_book_cash')::numeric)<target.amount then raise exception 'INS_CXL_CASH_FUNDS_IN_USE: receipt cash is no longer available at its bank'; end if;
 elsif target.kind='commission_withdrawal' then
 v:=platform_ins_cancellation_cash_position(c.id,target.to_bank_account_id);
 if(v->>'bank_book_cash')::numeric<target.amount then raise exception 'INS_CXL_CASH_FUNDS_IN_USE: operating cash is no longer available'; end if;
 end if;
 s:=platform_fin_void_settlement_impl(c.tenant_id,target.settlement_id,q.notes,public.ins_local_today());
 insert into ins_cancellation_cash_journals values(c.tenant_id,q.id,s.void_journal_entry_id,'cash_void');
 if target.to_settlement_id is not null then
 s:=platform_fin_void_settlement_impl(c.tenant_id,target.to_settlement_id,q.notes,public.ins_local_today());
 insert into ins_cancellation_cash_journals values(c.tenant_id,q.id,s.void_journal_entry_id,'destination_void'); end if;
 update ins_cancellation_cash_requests set status='voided',voided_by_request_id=q.id where id=target.id;
 if target.kind='remittance' then perform platform_ins_cancellation_cash_recognize(q.id,target.adjustment_id); end if;
 else
 perform platform_ins_cancellation_cash_emit(q.id,item);
 if q.kind in('commission_return','commission_withdrawal') then perform platform_ins_cancellation_cash_emit(q.id,null,true); end if;
 if q.kind='remittance' then perform platform_ins_cancellation_cash_recognize(q.id,q.adjustment_id); end if;
 end if;
 update ins_cancellation_cash_requests set status='posted',operation_txid=null where id=q.id returning * into q;
 end if;
 insert into ins_cancellation_cash_events(tenant_id,request_id,event,actor_id,detail) values(c.tenant_id,q.id,q.status,auth.uid(),jsonb_build_object('reason',p_reason));
 return q;
end $function$;

CREATE OR REPLACE FUNCTION public.ins_decide_policy_cancellation(p_cancellation_id uuid, p_decision text, p_review_note text, p_accept_manual_exception boolean DEFAULT false)
 RETURNS ins_policy_cancellations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
 if exists(select 1 from accounting_periods where tenant_id=p.tenant_id and status='closed' and public.ins_local_today() between period_start and period_end) then raise exception 'INS_CANCELLATION_PERIOD: current accounting period closed'; end if;
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
  posting_date=public.ins_local_today(),cancellation_no=next_doc_number(c.tenant_id,'ins_policy_cancellation','CXL'),cash_at_posting=cash,operation_txid=txid_current() where id=c.id returning * into c;
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
  je:=post_journal_entry(c.tenant_id,'ins_policy_cancellation',c.id,public.ins_local_today(),'Cancellation '||c.cancellation_no||': '||c.reason,lines);
  insert into ins_cancellation_journals values(c.tenant_id,c.id,je.id,'cancellation_adjustments');
  for v_todo in select * from jsonb_array_elements(v_items) loop
   if v_todo->>'kind'='refund' then
    created_item:=fin_create_open_item_fx(c.tenant_id,(v_todo->>'party')::uuid,'ap_control','ins_cancellation_client_refund',c.id,c.cancellation_no,public.ins_local_today(),public.ins_local_today(),(v_todo->>'amount')::numeric,'Client refund due: '||p.policy_no,p.currency,je.id);
    update ins_policy_cancellations set refund_item_id=created_item.id where id=c.id;
   else
    created_item:=fin_create_open_item_fx(c.tenant_id,(v_todo->>'party')::uuid,'ar_control','ins_cancellation_insurer_recovery',(v_todo->>'adjustment')::uuid,c.cancellation_no,public.ins_local_today(),public.ins_local_today(),(v_todo->>'amount')::numeric,'Insurer recovery: '||p.policy_no,p.currency,je.id);
    update ins_cancellation_insurer_adjustments set recovery_item_id=created_item.id where id=(v_todo->>'adjustment')::uuid;
   end if;
  end loop;
 end if;
 if recognized>0 then
  declare recognition journal_entries%rowtype; begin
   recognition:=post_journal_entry(c.tenant_id,'ins_policy_cancellation',gen_random_uuid(),public.ins_local_today(),'Retained commission earned: '||c.cancellation_no,recognition_lines);
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
               and public.ins_local_today() between period_start and period_end) then
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
         posting_date = public.ins_local_today(),
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
          v_applied, public.ins_local_today(), v_clearing,
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
          v_applied, public.ins_local_today(), v_clearing,
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
    je := post_journal_entry(c.tenant_id, 'ins_policy_endorsement', c.id, public.ins_local_today(),
      v_desc || ': commission clawback', v_claw_lines);
    je_adj := je.id;
  end if;
  -- Recovery items name the adjustments journal (created after posting, the
  -- cancellation pattern).
  for v_todo in select * from jsonb_array_elements(v_recos) loop
    created_item := fin_create_open_item_fx(c.tenant_id, (v_todo ->> 'party')::uuid,
      (v_todo ->> 'role'), (v_todo ->> 'source_type'), (v_todo ->> 'source_id')::uuid,
      c.endorsement_no, public.ins_local_today(), public.ins_local_today(), (v_todo ->> 'amount')::numeric,
      'Endorsement recovery: ' || p.policy_no, p.currency, je_adj);
  end loop;
  -- The additional-side journal, then one client item for the whole
  -- endorsement, and per-insurer payable items. Each insurer item is keyed by
  -- its deferred commission entry (created first, naming the item once it
  -- exists): when that item is fully paid, the recognition trigger earns
  -- exactly that entry.
  if jsonb_array_length(v_add_lines) > 0 then
    je := post_journal_entry(c.tenant_id, 'ins_policy_endorsement', c.id, public.ins_local_today(), v_desc, v_add_lines);
    je_add := je.id;
    created_item := fin_create_open_item_fx(c.tenant_id, v_client_acc, 'ar_control',
      'ins_policy_endorsement', c.id, c.endorsement_no, public.ins_local_today(), public.ins_local_today(),
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
      'ins_policy_endorsement_insurer', note_id, c.endorsement_no, public.ins_local_today(), public.ins_local_today(),
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

CREATE OR REPLACE FUNCTION public.ins_endorsement_unwind_position(p_endorsement_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
                and public.ins_local_today() between period_start and period_end) then
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
end $function$;

CREATE OR REPLACE FUNCTION public.ins_fee_withholding_position()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_total numeric := 0;
  v_rows jsonb;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select coalesce(sum(r.wht_amount), 0) into v_total
    from public.ins_fee_wht_records r where r.tenant_id = v_tenant;

  select coalesce(jsonb_agg(jsonb_build_object(
           'client_id', r.client_id,
           'currency', r.currency,
           'basis', r.basis,
           'wht_amount', r.wht_amount,
           'gross_amount', r.gross_amount,
           'recorded_on', public.ins_local_date(r.created_at)) order by r.created_at desc), '[]'::jsonb)
    into v_rows
    from public.ins_fee_wht_records r where r.tenant_id = v_tenant;

  return jsonb_build_object('recoverable_total', v_total, 'records', v_rows);
end
$function$;

CREATE OR REPLACE FUNCTION public.ins_generate_renewal_notices()
 RETURNS TABLE(notice_id uuid, policy_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  p record;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  for p in
    select ip.id as pid
      from public.ins_policies ip
     where ip.tenant_id = v_tenant
       and ip.status in ('active', 'renewed')
       and ip.expiry_date <= public.ins_local_today() + 120
       and not exists (
         select 1 from public.ins_renewal_notices n
         where n.tenant_id = v_tenant and n.policy_id = ip.id
       )
  loop
    set local ins.via_rpc = 'on';
    insert into public.ins_renewal_notices (tenant_id, policy_id, created_by)
    values (v_tenant, p.pid, auth.uid())
    returning id into notice_id;
    reset ins.via_rpc;
    policy_id := p.pid;
    return next;
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_import_create_batch(p_label text, p_cut_over_date date)
 RETURNS ins_import_batches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_row    public.ins_import_batches;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_label is null or btrim(p_label) = '' then
    raise exception 'INS_IMPORT_LABEL_REQUIRED';
  end if;
  if p_cut_over_date is null or p_cut_over_date > public.ins_local_today() then
    raise exception 'INS_IMPORT_CUTOVER_INVALID: the cut-over date is required and cannot be in the future';
  end if;

  insert into public.ins_import_batches (tenant_id, label, cut_over_date, created_by)
  values (v_tenant, btrim(p_label), p_cut_over_date, auth.uid())
  returning * into v_row;
  return v_row;
end $function$;

CREATE OR REPLACE FUNCTION public.ins_place_quote(p_quote_id uuid)
 RETURNS ins_policies
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_quote public.ins_quotes;
  v_policy public.ins_policies;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into v_quote from public.ins_quotes
  where tenant_id = v_tenant and id = p_quote_id;
  if v_quote.id is null then
    raise exception 'INS_QUOTE_NOT_FOUND';
  end if;
  if v_quote.status <> 'accepted' then
    raise exception 'INS_QUOTE_NOT_ACCEPTED';
  end if;

  set local ins.via_rpc = 'on';
  insert into public.ins_policies (
    tenant_id, policy_no, client_id, insurer_id, product_line_id, status,
    inception_date, expiry_date,
    sum_insured, currency, gross_premium, commission_rate_pct,
    notes, created_by
  ) values (
    v_tenant, next_doc_number(v_tenant, 'INS_POLICY', 'POL', 5),
    v_quote.client_id, v_quote.insurer_id, v_quote.product_line_id, 'draft',
    public.ins_local_today(), public.ins_local_today() + interval '1 year',
    v_quote.sum_insured, v_quote.currency, v_quote.gross_premium, v_quote.commission_rate_pct,
    v_quote.notes, auth.uid()
  )
  returning * into v_policy;

  update public.ins_quotes
  set status = 'placed', accepted_policy_id = v_policy.id, updated_at = now()
  where tenant_id = v_tenant and id = p_quote_id;
  reset ins.via_rpc;

  return v_policy;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_policy_cash_validate(p_policy_id uuid, p_kind text, p_bank_id uuid, p_amount numeric, p_date date, p_share_id uuid DEFAULT NULL::uuid)
 RETURNS fin_open_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare p ins_policies%rowtype; b fin_bank_accounts%rowtype; i fin_open_items%rowtype; v jsonb;
begin
 perform ins_policy_cash_require_finance();
 if p_kind is distinct from 'remittance' or not exists(select 1 from ins_policy_financial_snapshots where policy_id=p_policy_id and extended) then
   if p_share_id is not null then raise exception 'INS_SHARE_INPUT: share selection applies only to co-insurance/charge remittances'; end if;
   return platform_ins_policy_cash_legacy_validate(p_policy_id,p_kind,p_bank_id,p_amount,p_date);
 end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount>9999999999999999.99 then raise exception 'INS_CASH_INPUT: invalid amount'; end if;
 if p_date is null or p_date>public.ins_local_today() then raise exception 'INS_CASH_DATE: invalid cash date'; end if;
 select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 if p.status not in('active','renewed') then raise exception 'INS_CASH_STATE: bound, non-reversed policy required'; end if;
 perform f.id from fin_open_items f join ins_policy_cash_items m on m.id=f.id where m.source_id=p.id and f.tenant_id=p.tenant_id
  and m.source_type in('ins_policy_premium','ins_policy_insurer') order by f.id for update of f;
 select * into b from fin_bank_accounts where id=p_bank_id and tenant_id=p.tenant_id for share;
 if not found or b.kind<>'client_money' or not b.is_active or b.gl_account_id is null or b.currency<>p.currency then raise exception 'INS_CASH_BANK: active mapped client-money bank required'; end if;
 if not exists(select 1 from ins_policy_insurer_shares where id=p_share_id and policy_id=p.id and tenant_id=p.tenant_id) then raise exception 'INS_SHARE_INPUT: select a participating insurer'; end if;
 select * into i from fin_open_items where source_id=p_share_id and source_type='ins_policy_share_insurer' and tenant_id=p.tenant_id;
 if not found then raise exception 'INS_CASH_ITEM: insurer payable missing'; end if;
 v:=ins_share_cash_totals(p_share_id);
 if p_amount>(v->>'maximum_remittance')::numeric then raise exception 'INS_CASH_CAP: remittance exceeds this insurer share pro-rata funding or outstanding payable'; end if;
 return i;
end $function$;

CREATE OR REPLACE FUNCTION public.ins_preview_policy_cancellation(p_policy_id uuid, p_effective_date date, p_insurer_terms jsonb, p_charge_refunds jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare p ins_policies%rowtype; snap ins_policy_financial_snapshots%rowtype; shares jsonb; charges jsonb;
 allocation jsonb; term jsonb; charge jsonb; rule jsonb; calc jsonb; insurers jsonb:='[]'; charge_results jsonb:='[]'; pass_rows jsonb:='[]';
 original_parts jsonb; parts jsonb; part jsonb; decision jsonb; recipient_refund numeric; recipient_total numeric; final_insurers jsonb:='[]';
 refund numeric; original_amount numeric; original_vat numeric; vat_refund numeric; premium_return numeric:=0; total_credit numeric:=0;
 invoice numeric; unpaid numeric; pass_refund numeric; requires_exception boolean:=false; item_count integer;
begin
 if auth.uid() is null or effective_user_id() is distinct from auth.uid()
  or not (can_manage_insurance() or is_finance_team_member('finance')) then
  raise exception 'INS_FORBIDDEN: Insurance manager or Finance acting as themselves required' using errcode='42501'; end if;
 select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
 if p.status not in('active','renewed') then raise exception 'INS_CANCELLATION_STATE: bound policy required'; end if;
 if exists(select 1 from ins_claims where policy_id=p.id and tenant_id=p.tenant_id) then
  raise exception 'INS_CANCELLATION_CLAIM: policies with existing claims are not supported in v1'; end if;
 if p_effective_date is null or p_effective_date>public.ins_local_today() then raise exception 'INS_CANCELLATION_INPUT: a non-future effective cancellation date is required'; end if;
 if jsonb_typeof(p_insurer_terms) is distinct from 'array' or jsonb_typeof(p_charge_refunds) is distinct from 'array' then
  raise exception 'INS_CANCELLATION_INPUT: insurer terms and charge decisions must be arrays'; end if;
 if jsonb_array_length(p_insurer_terms)>30 or jsonb_array_length(p_charge_refunds)>100 then raise exception 'INS_CANCELLATION_INPUT: too many input lines'; end if;
 select * into snap from ins_policy_financial_snapshots where policy_id=p.id and tenant_id=p.tenant_id;
 -- Financial data comes only from immutable bind-time records, never from
 -- client-supplied premiums, shares, commission rates, recipients or VAT rates.
 shares:=snap.snapshot->'shares'; charges:=coalesce(snap.snapshot->'charges','[]'::jsonb);
 if shares is null or shares='[]'::jsonb then
  shares:=jsonb_build_array(jsonb_build_object('insurer_id',p.insurer_id,'premium_amount',p.gross_premium,
   'commission_amount',p.commission_amount,'commission_rate_pct',p.commission_rate_pct,'share_pct',100));
 end if;
 invoice:=coalesce(snap.invoice_total,p.gross_premium);
 if jsonb_array_length(p_insurer_terms)<>jsonb_array_length(shares)
  or (select count(*)<>count(distinct x->>'insurer_id') from jsonb_array_elements(p_insurer_terms) x) then
  raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: provide one set of terms for every original insurer'; end if;
 for allocation in select value from jsonb_array_elements(shares) loop
  select x->'terms' into term from jsonb_array_elements(p_insurer_terms) x where x->>'insurer_id'=allocation->>'insurer_id';
  if term is null then raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: missing original insurer terms'; end if;
  calc:=platform_ins_calculate_insurer_cancellation(allocation,term,p.inception_date,p.expiry_date,p_effective_date);
  insurers:=insurers||jsonb_build_array(calc);
  premium_return:=premium_return+(calc->>'return_premium')::numeric;
  requires_exception:=requires_exception or (calc->>'requires_finance_exception')::boolean;
 end loop;
 if jsonb_array_length(p_charge_refunds)<>jsonb_array_length(charges)
  or (select count(*)<>count(distinct x->>'charge_id') from jsonb_array_elements(p_charge_refunds) x) then
  raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: decide every original charge, including zero-valued lines'; end if;
 total_credit:=premium_return;
 for charge in select value from jsonb_array_elements(charges) loop
  select x into rule from jsonb_array_elements(p_charge_refunds) x where x->>'charge_id'=charge->>'id';
  if rule is null or rule->'legal_basis_confirmed' is distinct from 'true'::jsonb or length(btrim(coalesce(rule->>'basis','')))<5 then
   raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: confirm the contractual/legal basis for every refundable or retained charge'; end if;
  original_amount:=platform_ins_cancellation_money(charge->>'amount');
  refund:=platform_ins_cancellation_money(rule->>'refund_amount');
  if refund>original_amount then raise exception 'INS_CANCELLATION_INPUT: charge refund exceeds its original amount'; end if;
  original_vat:=coalesce((charge->>'vat_amount')::numeric,0); vat_refund:=0;
  if charge->>'kind'='broker_fee' then
   if original_amount=0 and original_vat<>0 then raise exception 'INS_CANCELLATION_HISTORY: VAT without broker-fee base'; end if;
   vat_refund:=case when original_amount=0 then 0 when refund=original_amount then original_vat else platform_ins_cancellation_round_ratio(original_vat*refund,original_amount) end;
  else
   if charge->>'recipient_mode'='one_insurer' then
    original_parts:=jsonb_build_array(jsonb_build_object('insurer_id',charge->>'recipient_insurer_id','amount',original_amount::text));
   else
    -- Reconstruct the exact original Hamilton allocation from immutable shares.
    with bases as(select x->>'insurer_id' as insurer_id,trunc(original_amount*(x->>'share_pct')::numeric/100,2) as base,
      original_amount*(x->>'share_pct')::numeric/100-trunc(original_amount*(x->>'share_pct')::numeric/100,2) as fraction from jsonb_array_elements(shares) x),
    ranked as(select *,row_number() over(order by fraction desc,insurer_id collate "C") as rank,round((original_amount-sum(base) over())*100) as cents from bases)
    select jsonb_agg(jsonb_build_object('insurer_id',insurer_id,'amount',(base+case when rank<=cents then .01 else 0 end)::text)) into original_parts from ranked;
   end if;
   if jsonb_typeof(rule->'insurer_refunds') is distinct from 'array' then
    raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: each pass-through recipient needs its own explicit refund decision'; end if;
   if jsonb_array_length(rule->'insurer_refunds')<>jsonb_array_length(original_parts)
     or (select count(*)<>count(distinct x->>'insurer_id') from jsonb_array_elements(rule->'insurer_refunds') x) then
    raise exception 'INS_CANCELLATION_INPUT: exactly one charge decision per original recipient required'; end if;
   recipient_total:=0;
   for part in select value from jsonb_array_elements(original_parts) loop
    select x into decision from jsonb_array_elements(rule->'insurer_refunds') x where x->>'insurer_id'=part->>'insurer_id';
    if decision is null or length(btrim(coalesce(decision->>'basis','')))<5 then
     raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: recipient-specific charge refund/retention basis required'; end if;
    recipient_refund:=platform_ins_cancellation_money(decision->>'refund_amount');
    if recipient_refund>(part->>'amount')::numeric then raise exception 'INS_CANCELLATION_INPUT: refund exceeds recipient original charge allocation'; end if;
    recipient_total:=recipient_total+recipient_refund;
    pass_rows:=pass_rows||jsonb_build_array(jsonb_build_object('insurer_id',part->>'insurer_id','charge_id',charge->>'id',
     'amount',recipient_refund::text,'original_amount',part->>'amount','retained_amount',((part->>'amount')::numeric-recipient_refund)::text,'basis',decision->>'basis'));
   end loop;
   if recipient_total<>refund then raise exception 'INS_CANCELLATION_INPUT: recipient refunds must equal the charge refund'; end if;
  end if;
  total_credit:=total_credit+refund+vat_refund;
  charge_results:=charge_results||jsonb_build_array(jsonb_build_object('charge_id',charge->>'id','kind',charge->>'kind',
   'refund_base',refund::text,'retained_base',(original_amount-refund)::text,'refund_vat',vat_refund::text,'retained_vat',(original_vat-vat_refund)::text,
   'basis',btrim(rule->>'basis'),'recipient_mode',charge->>'recipient_mode','recipient_insurer_id',charge->>'recipient_insurer_id',
   'vat_mode',charge->>'vat_mode','income_gl_account_id',charge->>'income_gl_account_id'));
 end loop;
 for calc in select value from jsonb_array_elements(insurers) loop
  select coalesce(sum((x->>'amount')::numeric),0) into pass_refund from jsonb_array_elements(pass_rows) x where x->>'insurer_id'=calc->>'insurer_id';
  final_insurers:=final_insurers||jsonb_build_array(calc||jsonb_build_object('pass_through_refund',pass_refund::text,
   'total_insurer_credit',((calc->>'net_insurer_credit')::numeric+pass_refund)::text));
 end loop;
 select count(*),sum(outstanding_amount) into item_count,unpaid from fin_open_item_balances where tenant_id=p.tenant_id and source_id=p.id and source_type='ins_policy_premium';
 if item_count<>1 or unpaid<0 or unpaid>invoice or total_credit>invoice then raise exception 'INS_CANCELLATION_HISTORY: policy receivable does not reconcile'; end if;
 if exists(select 1 from fin_credit_applications a join fin_credit_notes n on n.id=a.credit_note_id
   join fin_open_items i on i.id=a.open_item_id where i.tenant_id=p.tenant_id and i.source_type='ins_policy_premium' and i.source_id=p.id and n.status='posted') then
  raise exception 'INS_CANCELLATION_REVIEW_REQUIRED: existing policy credits require Finance review'; end if;
 return jsonb_build_object('stage','calculation_only','approval_status','not_approved','payment_authorized',false,
  'policy_id',p.id,'currency',p.currency,'effective_date',p_effective_date,'generated_at',now(),
  'cover_day_convention','inclusive cover dates; cancellation day is not earned cover',
  'insurers',final_insurers,'charges',charge_results,'pass_through_allocations',pass_rows,
  'invoice_credit',total_credit::text,'receivable_credit',least(total_credit,unpaid)::text,'client_refund_due',greatest(total_credit-unpaid,0)::text,
  'requires_finance_review',true,'requires_finance_exception',requires_exception,
  'funding_status','not_checked','notice','Calculation only. Cancellation approval and separately approved, funded cash payment are still required.');
end $function$;

CREATE OR REPLACE FUNCTION public.ins_preview_policy_endorsement(p_policy_id uuid, p_effective_date date, p_insurer_terms jsonb, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  p ins_policies%rowtype;
  snap ins_policy_financial_snapshots%rowtype;
  shares jsonb;
  term jsonb;
  allocation jsonb;
  matched text := '';
  calc jsonb := '{}'::jsonb;
  rows_out jsonb := '[]'::jsonb;
  changes_out jsonb := '[]'::jsonb;
  field text;
  before_val jsonb;
  after_val jsonb;
  delta numeric;
  total_days integer;
  remaining_days integer;
  premium_delta numeric := 0;
  commission_delta numeric := 0;
  premium_zero boolean := true;
begin
  if auth.uid() is null or effective_user_id() is distinct from auth.uid()
     or not (can_manage_insurance() or is_finance_team_member('finance')) then
    raise exception 'INS_FORBIDDEN: Insurance manager or Finance acting as themselves required' using errcode = '42501';
  end if;
  select * into p from ins_policies where id = p_policy_id and tenant_id = get_my_tenant_id() for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  if p.status not in ('active','renewed') then
    raise exception 'INS_ENDORSEMENT_STATE: a bound policy is required (this one is %)', p.status;
  end if;
  if p_effective_date is null or p_effective_date > public.ins_local_today() then
    raise exception 'INS_ENDORSEMENT_INPUT: a non-future effective date is required';
  end if;
  if jsonb_typeof(p_insurer_terms) is distinct from 'array'
     or jsonb_array_length(p_insurer_terms) > 30 then
    raise exception 'INS_ENDORSEMENT_INPUT: insurer terms must be an array of at most 30 lines';
  end if;
  if p_changes is null or jsonb_typeof(p_changes) is distinct from 'object' then
    raise exception 'INS_ENDORSEMENT_INPUT: changes must be a JSON object';
  end if;

  -- The immutable bind-time shares, with the single-insurer fallback the
  -- cancellation preview uses.
  select * into snap from ins_policy_financial_snapshots where policy_id = p.id and tenant_id = p.tenant_id;
  shares := coalesce(snap.snapshot -> 'shares', '[]'::jsonb);
  if shares is null or shares = '[]'::jsonb then
    shares := jsonb_build_array(jsonb_build_object(
      'insurer_id', p.insurer_id, 'premium_amount', p.gross_premium,
      'commission_amount', p.commission_amount, 'commission_rate_pct', p.commission_rate_pct, 'share_pct', 100));
  end if;

  total_days := (p.expiry_date - p.inception_date);
  remaining_days := (p.expiry_date - p_effective_date);
  if remaining_days < 0 then
    raise exception 'INS_ENDORSEMENT_INPUT: the effective date is after the policy expires';
  end if;

  -- Per-insurer premium deltas. The insurer's agreed delta wins; pro-rata by
  -- the remaining days of the policy is the fallback. An insurer without a
  -- term simply takes no delta -- unlike a cancellation, an endorsement may
  -- concern one co-insurer only.
  for term in select value from jsonb_array_elements(p_insurer_terms) loop
    if term ->> 'insurer_id' is null then
      raise exception 'INS_ENDORSEMENT_INPUT: each term names its insurer';
    end if;
    for allocation in select value from jsonb_array_elements(shares) loop
      continue when allocation ->> 'insurer_id' is distinct from term ->> 'insurer_id';
      if matched like '%|' || (term ->> 'insurer_id') || '|%' then
        raise exception 'INS_ENDORSEMENT_INPUT: insurer % appears twice in the terms', term ->> 'insurer_id';
      end if;
      matched := matched || '|' || (term ->> 'insurer_id') || '|';

      if term ? 'agreed_delta' then
        delta := platform_ins_endorsement_money(term ->> 'agreed_delta');
      elsif term ->> 'method' = 'pro_rata' then
        delta := round(
          platform_ins_endorsement_money(term ->> 'annual_delta')
          * remaining_days / greatest(total_days, 1), 2);
      else
        raise exception 'INS_ENDORSEMENT_INPUT: a term is either an agreed_delta or pro_rata with annual_delta';
      end if;

      calc := jsonb_build_object(
        'insurer_id', term ->> 'insurer_id',
        'share_pct', allocation ->> 'share_pct',
        'share_premium', allocation ->> 'premium_amount',
        'basis', case when term ? 'agreed_delta' then 'agreed' else 'pro_rata' end,
        'input', case when term ? 'agreed_delta' then term ->> 'agreed_delta' else term ->> 'annual_delta' end,
        'premium_delta', delta,
        'commission_delta', round(delta * (p.commission_rate_pct / 100.0), 2),
        'rate_pct', p.commission_rate_pct,
        'requires_review', abs(delta) > (allocation ->> 'premium_amount')::numeric);
      rows_out := rows_out || calc;
      premium_delta := premium_delta + delta;
      commission_delta := commission_delta + (calc ->> 'commission_delta')::numeric;
    end loop;
    if not matched like '%|' || (term ->> 'insurer_id') || '|%' then
      raise exception 'INS_ENDORSEMENT_INPUT: insurer % is not on this policy', term ->> 'insurer_id';
    end if;
  end loop;

  premium_zero := premium_delta = 0;

  -- Descriptive changes ride along; only known fields, with before/after
  -- recorded (the policy row itself is never mutated).
  for field in select jsonb_object_keys(p_changes) loop
    if field not in ('sum_insured','risk_description','notes') then
      raise exception 'INS_ENDORSEMENT_INPUT: % is not an endorsable field', field;
    end if;
    after_val := p_changes -> field;
    if field = 'sum_insured' then
      if jsonb_typeof(after_val) is distinct from 'number'
         or (after_val)::numeric is null or (after_val)::numeric <= 0 then
        raise exception 'INS_ENDORSEMENT_INPUT: sum_insured must be a positive number';
      end if;
      before_val := to_jsonb(p.sum_insured);
    else
      if jsonb_typeof(after_val) is distinct from 'string'
         or length(btrim(after_val #>> '{}')) > 2000 then
        raise exception 'INS_ENDORSEMENT_INPUT: % must be text of at most 2000 characters', field;
      end if;
      before_val := to_jsonb(case when field = 'notes' then p.notes else p.risk_description end);
    end if;
    changes_out := changes_out || jsonb_build_object('field', field, 'before', before_val, 'after', after_val);
  end loop;

  if premium_zero and jsonb_array_length(changes_out) = 0 then
    raise exception 'INS_ENDORSEMENT_INPUT: an endorsement changes the premium or the policy record -- this one changes neither';
  end if;

  return jsonb_build_object(
    'policy_id', p.id, 'policy_no', p.policy_no, 'currency', p.currency,
    'inception_date', p.inception_date, 'expiry_date', p.expiry_date,
    'effective_date', p_effective_date,
    'total_days', total_days, 'remaining_days', remaining_days,
    'commission_rate_pct', p.commission_rate_pct,
    'shares', rows_out,
    'premium_delta', premium_delta,
    'commission_delta', commission_delta,
    'premium_zero', premium_zero,
    'changes', changes_out);
end $function$;

CREATE OR REPLACE FUNCTION public.ins_recognise_claim_receivable(p_claim_id uuid, p_insurer_confirmation text)
 RETURNS ins_claims
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_insurer uuid;
  v_client  uuid;
  v_ccy     text;
  v_recv_gl uuid;
  v_pay_gl  uuid;
  v_ins_acc uuid;
  v_cli_acc uuid;
  v_desc    text;
  v_je      journal_entries%rowtype;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers recognise claim receivables' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  if v_claim.status <> 'approved' then
    raise exception 'INS_CLAIM_STATE: only an approved claim can be recognised (this one is %)', v_claim.status;
  end if;
  if v_claim.payment_mode <> 'via_broker' then
    raise exception 'INS_CLAIM_MODE: only a claim paid through the brokerage is recognised here';
  end if;
  if v_claim.recognised_at is not null then
    raise exception 'INS_CLAIM_RECOGNISED: this claim is already recognised';
  end if;
  if nullif(btrim(p_insurer_confirmation), '') is null then
    raise exception 'INS_NOTE_REQUIRED: give the insurer''s written confirmation reference before recognising the receivable';
  end if;

  select p.insurer_id, p.client_id, p.currency into v_insurer, v_client, v_ccy from ins_policies p where p.id = v_claim.policy_id;
  v_recv_gl := get_posting_account(v_tenant, 'insurer_claim_receivable');
  v_pay_gl  := get_posting_account(v_tenant, 'client_claim_payable');
  if v_recv_gl is null or v_pay_gl is null then
    raise exception 'INS_POSTING_RULE_MISSING: this insurer pays claims through the brokerage, so the chart of accounts needs insurer_claim_receivable and client_claim_payable';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  v_ins_acc := ins_ensure_insurer_account(v_insurer);
  v_cli_acc := ins_ensure_client_account(v_client);
  v_desc := 'Claim ' || v_claim.claim_no || ' recognised: insurer confirmed payment through the brokerage';
  v_je := post_journal_entry(v_tenant, 'ins_claim_accrual', v_claim.id, public.ins_local_today(), v_desc, jsonb_build_array(
    jsonb_build_object('gl_account_id', v_recv_gl, 'debit',  v_claim.approved_amount, 'currency', v_ccy, 'description', v_desc),
    jsonb_build_object('gl_account_id', v_pay_gl,  'credit', v_claim.approved_amount, 'currency', v_ccy, 'description', v_desc)));
  -- The claim items hold the rate the accrual was booked at.
  perform fin_create_open_item_fx(v_tenant, v_ins_acc, 'insurer_claim_receivable', 'ins_claim_insurer', v_claim.id,
    v_claim.claim_no, public.ins_local_today(), public.ins_local_today(), v_claim.approved_amount, 'Claim funds due from the insurer', v_ccy, v_je.id);
  perform fin_create_open_item_fx(v_tenant, v_cli_acc, 'client_claim_payable', 'ins_claim_client', v_claim.id,
    v_claim.claim_no, public.ins_local_today(), public.ins_local_today(), v_claim.approved_amount, 'Claim proceeds due to the client', v_ccy, v_je.id);

  update ins_claims set recognised_at = now(), recognised_by = auth.uid()
   where id = v_claim.id returning * into v_claim;
  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_tenant, v_claim.id, 'approved', 'approved', 'Receivable recognised. Insurer confirmation: ' || btrim(p_insurer_confirmation));
  return v_claim;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_record_claim_payment(p_claim_id uuid, p_amount numeric, p_payment_date date, p_reference text, p_notes text DEFAULT NULL::text)
 RETURNS ins_claim_payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_pay    ins_claim_payments%rowtype;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers record claim payments' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_NOT_FOUND: claim'; end if;
  if v_claim.status <> 'approved' then
    raise exception 'INS_CLAIM_STATE: payments are recorded on an approved claim (this one is %)', v_claim.status;
  end if;
  if v_claim.payment_mode <> 'insurer_direct' then
    raise exception 'INS_CLAIM_MODE: this claim is paid through the brokerage; record the insurer receipt and the client payout instead';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'INS_AMOUNT: the payment amount must be greater than zero';
  end if;
  if p_amount > v_claim.approved_amount - v_claim.paid_amount then
    raise exception 'INS_AMOUNT: only % is still unpaid on this claim', v_claim.approved_amount - v_claim.paid_amount;
  end if;
  if p_payment_date is null or p_payment_date > public.ins_local_today() or p_payment_date < v_claim.notified_date then
    raise exception 'INS_DATE: the payment date must be between the notified date and today';
  end if;
  if nullif(btrim(p_reference), '') is null then
    raise exception 'INS_REFERENCE_REQUIRED: give the insurer payment reference, because nothing else in the system evidences this payment';
  end if;

  insert into ins_claim_payments (tenant_id, claim_id, kind, amount, payment_date, reference, notes)
  values (v_tenant, v_claim.id, 'insurer_direct', p_amount, p_payment_date, btrim(p_reference), nullif(btrim(p_notes), ''))
  returning * into v_pay;

  perform ins_claim_apply_payment_totals(v_claim.id, 'Paid in full by the insurer');
  return v_pay;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_renewal_notification_sweep()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant  uuid := get_my_tenant_id();
  v_recips  uuid[];
  v_kinds   text[] := '{}';
  v_nos     text[] := '{}';
  v_ins     integer;
  v_total   integer := 0;
  r         record;
  k         text;
  v_list    text[];
  v_count   integer;
  v_shown   text;
begin
  if auth.uid() is null or v_tenant is null
     or not has_module_role('insurance', array['admin', 'manager', 'member']) then
    return 0;
  end if;

  -- Nobody to tell: leave the markers alone so the policies are picked up
  -- once a manager exists, rather than marking them as sent.
  v_recips := ins_notify_insurance_users(v_tenant, array['admin', 'manager']);
  if coalesce(array_length(v_recips, 1), 0) = 0 then
    return 0;
  end if;

  for r in
    select p.id, p.policy_no,
      case
        when p.expiry_date < public.ins_local_today()              then 'lapsed'
        when p.expiry_date - public.ins_local_today() <= 7         then 'renewal_7'
        when p.expiry_date - public.ins_local_today() <= 30        then 'renewal_30'
        else 'renewal_60'
      end as kind
    from ins_policies p
    where p.tenant_id = v_tenant
      and p.status = 'active'
      and p.expiry_date >= public.ins_local_today() - 30
      and p.expiry_date <= public.ins_local_today() + 60
      and not exists (select 1 from ins_policies d
                      where d.tenant_id = p.tenant_id and d.renewal_of_id = p.id and d.status = 'draft')
      and not exists (select 1 from ins_renewal_outcomes o
                      where o.tenant_id = p.tenant_id and o.policy_id = p.id)
      and not exists (select 1 from ins_policy_cancellations c
                      where c.tenant_id = p.tenant_id and c.policy_id = p.id
                        and c.status in ('proposed', 'prepared', 'posting', 'posted'))
    order by p.expiry_date, p.policy_no
  loop
    -- A policy first seen inside a tighter window skips the looser notices.
    if r.kind = 'renewal_7' then
      insert into ins_notification_marks (tenant_id, policy_id, kind)
      values (v_tenant, r.id, 'renewal_30'), (v_tenant, r.id, 'renewal_60')
      on conflict do nothing;
    elsif r.kind = 'renewal_30' then
      insert into ins_notification_marks (tenant_id, policy_id, kind)
      values (v_tenant, r.id, 'renewal_60')
      on conflict do nothing;
    end if;

    insert into ins_notification_marks (tenant_id, policy_id, kind)
    values (v_tenant, r.id, r.kind)
    on conflict do nothing;
    get diagnostics v_ins = row_count;

    if v_ins = 1 then
      v_kinds := v_kinds || r.kind;
      v_nos   := v_nos || r.policy_no;
    end if;
  end loop;

  foreach k in array array['renewal_7', 'renewal_30', 'renewal_60', 'lapsed'] loop
    select coalesce(array_agg(t.n order by t.ord), '{}') into v_list
    from unnest(v_kinds, v_nos) with ordinality as t(kind, n, ord)
    where t.kind = k;

    v_count := coalesce(array_length(v_list, 1), 0);
    continue when v_count = 0;

    v_total := v_total + v_count;
    v_shown := array_to_string(v_list[1:5], ', ')
               || case when v_count > 5 then format(' and %s more', v_count - 5) else '' end;

    perform ins_notify(
      v_tenant, v_recips, '{}'::uuid[],
      case when k = 'lapsed' then 'ins_policy_lapsed' else 'ins_renewal_due' end,
      case k
        when 'renewal_7'  then 'Renewals due within 7 days'
        when 'renewal_30' then 'Renewals due within 30 days'
        when 'renewal_60' then 'Renewals due within 60 days'
        else 'Policies lapsed without renewal'
      end,
      case when k = 'lapsed'
           then format('%s %s expired in the last 30 days with no renewal, outcome or cancellation: %s.',
                       v_count, case when v_count = 1 then 'policy' else 'policies' end, v_shown)
           else format('%s %s expire%s %s: %s.',
                       v_count, case when v_count = 1 then 'policy' else 'policies' end,
                       case when v_count = 1 then 's' else '' end,
                       case k when 'renewal_7' then 'within 7 days'
                              when 'renewal_30' then 'within 30 days'
                              else 'within 60 days' end,
                       v_shown)
      end,
      '/insurance/renewals');
  end loop;

  return v_total;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_reverse_policy(p_policy_id uuid, p_reason text, p_reissue boolean, p_request_key uuid)
 RETURNS ins_policy_reversals
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  p ins_policies%rowtype; r ins_policy_reversals%rowtype; c jsonb;
  cn fin_credit_notes%rowtype; draft ins_policies%rowtype;
  old_flag text := coalesce(current_setting('ins.via_rpc',true),'');
begin
  if not can_manage_insurance() or effective_user_id() is distinct from auth.uid() then
    raise exception 'INS_FORBIDDEN: insurance manager required; user-level impersonation cannot reverse policies' using errcode='42501';
  end if;
  if p_request_key is null or p_reissue is null or p_reason is null or length(btrim(p_reason))<5 then
    raise exception 'INS_REVERSAL_INPUT: request key, reissue choice and a reason of at least 5 characters are required';
  end if;
  select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  select * into r from ins_policy_reversals where original_policy_id=p.id;
  if found then
    if r.request_key=p_request_key and r.reason=btrim(p_reason) and r.reissue_requested=p_reissue and r.outcome='posted' then
      return r;
    end if;
    raise exception 'INS_REVERSAL_DUPLICATE: policy already reversed with a different request';
  end if;
  if exists(select 1 from ins_policy_reversals where tenant_id=p.tenant_id and request_key=p_request_key) then
    raise exception 'INS_REVERSAL_DUPLICATE: request key already used for another policy';
  end if;
  c:=ins_policy_reversal_context(p.id);
  insert into ins_policy_reversals(tenant_id,original_policy_id,request_key,reason,reissue_requested,
    accounting_treatment,original_journal_entry_id)
  values(p.tenant_id,p.id,p_request_key,btrim(p_reason),p_reissue,c->>'treatment',p.journal_entry_id)
  returning * into r;

  cn:=platform_fin_raise_policy_credit_note_impl(p.tenant_id,'ar_control',(c->>'client_party_id')::uuid,
    p.gross_premium,public.ins_local_today(),(c->>'offset_id')::uuid,
    jsonb_build_array(jsonb_build_object('open_item_id',c->>'premium_item_id','amount',p.gross_premium)),
    btrim(p_reason),p.policy_no,p.id);
  update ins_policy_reversals set premium_credit_note_id=cn.id,premium_journal_entry_id=cn.journal_entry_id where id=r.id;
  cn:=platform_fin_raise_policy_credit_note_impl(p.tenant_id,'insurer_payable',(c->>'insurer_party_id')::uuid,
    p.net_premium_to_insurer,public.ins_local_today(),(c->>'offset_id')::uuid,
    jsonb_build_array(jsonb_build_object('open_item_id',c->>'insurer_item_id','amount',p.net_premium_to_insurer)),
    btrim(p_reason),p.policy_no,p.id);
  update ins_policy_reversals set insurer_credit_note_id=cn.id,insurer_journal_entry_id=cn.journal_entry_id where id=r.id;

  -- Compare the aggregate inverse by actual account, not just total balance.
  if exists(
    select gl_account_id from journal_entry_lines
    where journal_entry_id in (p.journal_entry_id,
      (select premium_journal_entry_id from ins_policy_reversals where id=r.id),cn.journal_entry_id)
    group by gl_account_id having sum(debit-credit)<>0
  ) then raise exception 'INS_REVERSAL_BALANCE: reversal does not negate the original bind'; end if;
  if p_reissue then
    draft:=ins_create_policy(p.client_id,p.insurer_id,p.product_line_id,p.inception_date,p.expiry_date,
      p.sum_insured,p.currency,p.gross_premium,p.commission_rate_pct,p.risk_description,p.notes);
    update ins_policy_reversals set replacement_policy_id=draft.id where id=r.id;
  end if;
  update ins_policy_reversals set outcome='posted' where id=r.id returning * into r;
  perform set_config('ins.via_rpc','on',true);
  update ins_policies set status='reversed' where id=p.id;
  perform set_config('ins.via_rpc',old_flag,true);
  perform log_platform_event('insurance.policy.reverse',p.tenant_id,'ins_policy',p.id::text,btrim(p_reason),
    jsonb_build_object('status','active','journal',p.journal_entry_id),to_jsonb(r));
  return r;
end $function$;

CREATE OR REPLACE FUNCTION public.ins_save_intermediary(p_id uuid DEFAULT NULL::uuid, p_code text DEFAULT NULL::text, p_kind text DEFAULT 'business'::text, p_name text DEFAULT NULL::text, p_category text DEFAULT NULL::text, p_contact_email text DEFAULT NULL::text, p_contact_phone text DEFAULT NULL::text, p_parent_id uuid DEFAULT NULL::uuid, p_licence_ref text DEFAULT NULL::text, p_licence_authority text DEFAULT NULL::text, p_licence_valid_from date DEFAULT NULL::date, p_licence_valid_to date DEFAULT NULL::date, p_appointment_ref text DEFAULT NULL::text, p_authorisation_basis text DEFAULT NULL::text, p_authorisation_reference text DEFAULT NULL::text)
 RETURNS ins_intermediaries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant  uuid := get_my_tenant_id();
  v_row     ins_intermediaries%rowtype;
  v_old     ins_intermediaries%rowtype;
  v_parent  ins_intermediaries%rowtype;
  v_code    text := nullif(btrim(p_code), '');
  v_name    text := nullif(btrim(p_name), '');
  v_ref     text := nullif(btrim(p_licence_ref), '');
  v_auth    text := nullif(btrim(p_licence_authority), '');
  v_appt    text := nullif(btrim(p_appointment_ref), '');
  v_basis   text := nullif(btrim(p_authorisation_basis), '');
  v_aref    text := nullif(btrim(p_authorisation_reference), '');
  v_email   text := nullif(btrim(p_contact_email), '');
  v_phone   text := nullif(btrim(p_contact_phone), '');
  v_changed boolean := false;
  v_status_before text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers maintain intermediaries' using errcode = '42501';
  end if;

  if p_id is not null then
    select * into v_old from ins_intermediaries where id = p_id and tenant_id = v_tenant for update;
    if not found then
      raise exception 'INS_NOT_FOUND: intermediary';
    end if;
    if v_old.status = 'terminated' then
      raise exception 'INS_TERMINATED: a terminated intermediary cannot be changed';
    end if;
  end if;

  if v_code is null then raise exception 'INS_REQUIRED: give the intermediary a reference code'; end if;
  if v_name is null then raise exception 'INS_REQUIRED: give the intermediary a name'; end if;
  if p_kind not in ('individual', 'business') then raise exception 'INS_INVALID: kind must be individual or business'; end if;
  if p_category not in ('insurer_appointed_agent', 'independent_broker', 'sub_agent', 'referral_partner') then
    raise exception 'INS_INVALID: unknown category %', p_category;
  end if;

  -- Credentials. A referral partner needs none. Every other category needs a licence.
  if p_category <> 'referral_partner' then
    if v_ref is null or v_auth is null or p_licence_valid_to is null then
      raise exception 'INS_REQUIRED: a licence needs its reference, issuing authority and expiry date';
    end if;
    if p_licence_valid_to < public.ins_local_today() then
      raise exception 'INS_LICENCE_EXPIRED: the licence has already expired';
    end if;
    if p_licence_valid_from is not null and p_licence_valid_to < p_licence_valid_from then
      raise exception 'INS_INVALID: the licence expiry is before its start date';
    end if;
  end if;

  if p_category = 'insurer_appointed_agent' and v_appt is null then
    raise exception 'INS_REQUIRED: an insurer-appointed agent needs the insurer''s appointment reference';
  end if;

  -- Parent link.
  if p_category = 'sub_agent' then
    if p_parent_id is null then
      raise exception 'INS_PARENT_REQUIRED: a sub-agent must be placed under a parent intermediary';
    end if;
    if v_basis is null or v_aref is null then
      raise exception 'INS_AUTHORISATION_REQUIRED: record the basis on which the parent may appoint this sub-agent, and its reference';
    end if;
  end if;

  if p_parent_id is not null then
    select * into v_parent from ins_intermediaries where id = p_parent_id and tenant_id = v_tenant;
    if not found then
      raise exception 'INS_NOT_FOUND: parent intermediary';
    end if;
    if v_parent.status <> 'active' then
      raise exception 'INS_PARENT_NOT_ACTIVE: the parent must be verified and active before it can be linked (it is %)', v_parent.status;
    end if;
    if v_parent.category = 'referral_partner' then
      raise exception 'INS_PARENT_CATEGORY: a referral partner cannot appoint or be a parent';
    end if;
    if p_id is not null and ins_intermediary_chain_has(v_tenant, p_parent_id, p_id) then
      raise exception 'INS_CYCLE: that parent sits below this intermediary in the chain';
    end if;
  end if;

  if p_id is null then
    insert into ins_intermediaries (
      tenant_id, code, kind, name, category, contact_email, contact_phone, parent_id,
      licence_ref, licence_authority, licence_valid_from, licence_valid_to, appointment_ref,
      authorisation_basis, authorisation_reference, status, last_changed_by, last_changed_at)
    values (
      v_tenant, v_code, p_kind, v_name, p_category, v_email, v_phone, p_parent_id,
      v_ref, v_auth, p_licence_valid_from, p_licence_valid_to, v_appt,
      v_basis, v_aref, 'pending_verification', auth.uid(), now())
    returning * into v_row;

    insert into ins_intermediary_events (tenant_id, intermediary_id, action, to_status, note)
    values (v_tenant, v_row.id, 'created', 'pending_verification', null);
    return v_row;
  end if;

  -- Update. Any change to a credential, category or parent means it must be verified again.
  v_changed := (v_old.category, v_old.parent_id, v_old.licence_ref, v_old.licence_authority,
                v_old.licence_valid_from, v_old.licence_valid_to, v_old.appointment_ref,
                v_old.authorisation_basis, v_old.authorisation_reference)
               is distinct from
               (p_category, p_parent_id, v_ref, v_auth, p_licence_valid_from, p_licence_valid_to, v_appt,
                v_basis, v_aref);
  v_status_before := v_old.status;

  update ins_intermediaries set
    code = v_code, kind = p_kind, name = v_name, category = p_category,
    contact_email = v_email, contact_phone = v_phone, parent_id = p_parent_id,
    licence_ref = v_ref, licence_authority = v_auth,
    licence_valid_from = p_licence_valid_from, licence_valid_to = p_licence_valid_to,
    appointment_ref = v_appt, authorisation_basis = v_basis, authorisation_reference = v_aref,
    status = case when v_changed then 'pending_verification' else status end,
    verified_by = case when v_changed then null else verified_by end,
    verified_at = case when v_changed then null else verified_at end,
    last_changed_by = auth.uid(), last_changed_at = now(), updated_at = now()
  where id = p_id and tenant_id = v_tenant
  returning * into v_row;

  if v_changed then
    insert into ins_intermediary_events (tenant_id, intermediary_id, action, from_status, to_status, note)
    values (v_tenant, v_row.id, 'changed', v_status_before, 'pending_verification',
            'Credentials, category or parent changed: verification required again');
  else
    insert into ins_intermediary_events (tenant_id, intermediary_id, action, from_status, to_status, note)
    values (v_tenant, v_row.id, 'edited', v_status_before, v_status_before, 'Details edited');
  end if;
  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_set_intermediary_status(p_id uuid, p_to text, p_note text DEFAULT NULL::text)
 RETURNS ins_intermediaries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := get_my_tenant_id();
  v_row    ins_intermediaries%rowtype;
  v_from   text;
  v_note   text := nullif(btrim(p_note), '');
  v_active_children integer;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers change intermediary status' using errcode = '42501';
  end if;
  select * into v_row from ins_intermediaries where id = p_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: intermediary';
  end if;
  v_from := v_row.status;

  -- Moves allowed here. Pending to active is verification; expired to active needs re-verification.
  if not (
       (v_from = 'active' and p_to in ('suspended', 'expired', 'terminated'))
    or (v_from = 'suspended' and p_to in ('active', 'terminated'))
    or (v_from = 'expired' and p_to = 'terminated')
    or (v_from = 'pending_verification' and p_to = 'terminated')
  ) then
    raise exception 'INS_STATE: an intermediary cannot move from % to %', v_from, p_to;
  end if;

  if p_to in ('suspended', 'terminated') and v_note is null then
    raise exception 'INS_NOTE_REQUIRED: give the reason for suspending or terminating';
  end if;
  if p_to = 'suspended' and v_from = 'suspended' then
    raise exception 'INS_STATE: already suspended';
  end if;

  if p_to = 'expired' and (v_row.licence_valid_to is null or v_row.licence_valid_to >= public.ins_local_today()) then
    raise exception 'INS_NOT_EXPIRED: the licence has not passed its expiry date';
  end if;

  if p_to = 'active' and v_from = 'suspended' and v_row.licence_valid_to is not null and v_row.licence_valid_to < public.ins_local_today() then
    raise exception 'INS_LICENCE_EXPIRED: the licence has expired; renew it before reinstating';
  end if;

  if p_to = 'terminated' then
    select count(*) into v_active_children from ins_intermediaries
     where tenant_id = v_tenant and parent_id = v_row.id and status in ('active', 'suspended', 'pending_verification');
    if v_active_children > 0 then
      raise exception 'INS_HAS_SUBAGENTS: % sub-agent(s) still sit under this intermediary; end or move them first', v_active_children;
    end if;
  end if;

  update ins_intermediaries set status = p_to, updated_at = now() where id = v_row.id returning * into v_row;
  insert into ins_intermediary_events (tenant_id, intermediary_id, action, from_status, to_status, note)
  values (v_tenant, v_row.id, 'status', v_from, p_to, v_note);
  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_share_basis(p_policy_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_basis text;
  v_on    date;
  v_res   jsonb;
begin
  -- Prefer the basis recorded at bind, so a later change of setting cannot
  -- rewrite the treatment of a policy already placed.
  select sh.settlement_basis into v_basis
    from public.ins_policy_insurer_shares sh
   where sh.policy_id = p_policy_id and sh.settlement_basis is not null
   limit 1;
  if v_basis is not null then
    return v_basis;
  end if;

  v_on := coalesce((select p.inception_date from public.ins_policies p where p.id = p_policy_id), public.ins_local_today());
  v_res := public.acct_get_setting('ins.insurer_remittance_basis', v_on);

  -- Nothing approved for this tenant: keep the behaviour every existing book
  -- was built on (commission withheld, remitted net). Refusing here would stop
  -- every bind in every tenant that has not visited the settings screen, which
  -- is not a migration -- it is an outage.
  if v_res ->> 'source' <> 'configured' then
    return 'net_of_commission';
  end if;

  -- A tenant that HAS chosen is held to the legal-review gate.
  return public.acct_assert_reviewed('ins.insurer_remittance_basis', v_on);
end $function$;

CREATE OR REPLACE FUNCTION public.ins_submit_cancellation_cash_void(p_request_id uuid, p_reason text, p_request_key uuid)
 RETURNS ins_cancellation_cash_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare target ins_cancellation_cash_requests%rowtype; q ins_cancellation_cash_requests%rowtype;
begin
 perform ins_policy_cash_require_finance();
 select * into target from ins_cancellation_cash_requests where id=p_request_id and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_NOT_FOUND: cash request'; end if;
 perform p.id from ins_policies p join ins_policy_cancellations c on c.policy_id=p.id where c.id=target.cancellation_id for update of p;
 select * into q from ins_cancellation_cash_requests where tenant_id=target.tenant_id and request_key=p_request_key;
 if found then if q.maker_id<>auth.uid() or q.voids_request_id is distinct from target.id or q.notes is distinct from btrim(p_reason) then raise exception 'INS_CXL_CASH_RETRY: different void inputs'; end if; return q; end if;
 if target.kind='void' or target.status<>'posted' or p_request_key is null or p_reason is null or length(btrim(p_reason)) not between 5 and 2000 then raise exception 'INS_CXL_CASH_VOID: posted cash and detailed reason required'; end if;
 insert into ins_cancellation_cash_requests(tenant_id,cancellation_id,kind,adjustment_id,bank_account_id,to_bank_account_id,amount,cash_date,reference,notes,request_key,maker_id,voids_request_id)
 values(target.tenant_id,target.cancellation_id,'void',target.adjustment_id,target.bank_account_id,target.to_bank_account_id,target.amount,public.ins_local_today(),'Void '||target.id,btrim(p_reason),p_request_key,auth.uid(),target.id) returning * into q;
 insert into ins_cancellation_cash_events(tenant_id,request_id,event,actor_id) values(q.tenant_id,q.id,'void_requested',auth.uid()); return q;
end $function$;

CREATE OR REPLACE FUNCTION public.ins_submit_quote(p_quote_id uuid)
 RETURNS ins_quotes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_quote public.ins_quotes;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into v_quote from public.ins_quotes
  where tenant_id = v_tenant and id = p_quote_id;
  if v_quote.id is null then
    raise exception 'INS_QUOTE_NOT_FOUND';
  end if;
  if v_quote.status <> 'draft' then
    raise exception 'INS_QUOTE_NOT_DRAFT';
  end if;
  if v_quote.valid_until is not null and v_quote.valid_until < public.ins_local_today() then
    raise exception 'INS_QUOTE_EXPIRED';
  end if;

  set local ins.via_rpc = 'on';
  update public.ins_quotes
  set status = 'submitted', submitted_at = now(), submitted_by = auth.uid(), updated_at = now()
  where tenant_id = v_tenant and id = p_quote_id
  returning * into v_quote;
  reset ins.via_rpc;

  return v_quote;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_verify_intermediary(p_id uuid, p_note text DEFAULT NULL::text)
 RETURNS ins_intermediaries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := get_my_tenant_id();
  v_row    ins_intermediaries%rowtype;
  v_parent_status text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers verify intermediaries' using errcode = '42501';
  end if;
  select * into v_row from ins_intermediaries where id = p_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: intermediary';
  end if;
  if v_row.status <> 'pending_verification' then
    raise exception 'INS_STATE: only a pending intermediary can be verified (this one is %)', v_row.status;
  end if;
  if v_row.last_changed_by is not null and v_row.last_changed_by = auth.uid() then
    raise exception 'INS_SEGREGATION: the person who last changed this record cannot verify it; another manager must';
  end if;
  if v_row.licence_valid_to is not null and v_row.licence_valid_to < public.ins_local_today() then
    raise exception 'INS_LICENCE_EXPIRED: the licence has expired, so the intermediary cannot be verified';
  end if;
  if v_row.parent_id is not null then
    select status into v_parent_status from ins_intermediaries where id = v_row.parent_id and tenant_id = v_tenant;
    if v_parent_status is distinct from 'active' then
      raise exception 'INS_PARENT_NOT_ACTIVE: the parent must be active before this sub-agent can be verified';
    end if;
  end if;

  update ins_intermediaries set status = 'active', verified_by = auth.uid(), verified_at = now(), updated_at = now()
   where id = v_row.id returning * into v_row;
  insert into ins_intermediary_events (tenant_id, intermediary_id, action, from_status, to_status, note)
  values (v_tenant, v_row.id, 'verified', 'pending_verification', 'active', nullif(btrim(p_note), ''));
  return v_row;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_void_claim_payment(p_payment_id uuid, p_reason text)
 RETURNS ins_claim_payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := get_my_tenant_id();
  v_pay    ins_claim_payments%rowtype;
  v_status text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers void claim payments' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_REASON_REQUIRED: a reason of at least 5 characters is required';
  end if;
  select * into v_pay from ins_claim_payments where id = p_payment_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_NOT_FOUND: payment'; end if;
  if v_pay.status <> 'posted' then raise exception 'INS_ALREADY_VOID: this payment is already void'; end if;
  select status into v_status from ins_claims where id = v_pay.claim_id;
  if v_status = 'closed' then
    raise exception 'INS_CLAIM_CLOSED: payments on a closed claim cannot be voided';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  if v_pay.kind = 'insurer_direct' then
    update ins_claim_payments
       set status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
     where id = v_pay.id returning * into v_pay;
    perform ins_claim_apply_payment_totals(v_pay.claim_id, 'Payment voided: ' || btrim(p_reason));
  else
    -- The settlement void trigger marks this row void and recomputes the claim.
    perform platform_fin_void_settlement_impl(v_tenant, v_pay.settlement_id, btrim(p_reason), public.ins_local_today());
    select * into v_pay from ins_claim_payments where id = p_payment_id;
  end if;
  return v_pay;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_void_commission_transfer(p_transfer_id uuid, p_reason text, p_void_date date DEFAULT public.ins_local_today())
 RETURNS ins_commission_transfers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := get_my_tenant_id();
  v_tr     ins_commission_transfers%rowtype;
  v_lines  jsonb;
  v_je     journal_entries;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can void a commission transfer' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'INS_TRANSFER_VOID: a reason of at least 5 characters is required';
  end if;

  select * into v_tr from ins_commission_transfers where id = p_transfer_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_TRANSFER_VOID: transfer not found in this company'; end if;
  if v_tr.status <> 'posted' then raise exception 'INS_TRANSFER_VOID: transfer % is already void', v_tr.transfer_no; end if;
  if exists (select 1 from bank_reconciliations r where r.commission_transfer_id = v_tr.id) then
    raise exception 'INS_TRANSFER_RECONCILED: transfer % is matched to a bank statement line; unmatch it in bank reconciliation first', v_tr.transfer_no;
  end if;
  if p_void_date is null or p_void_date < v_tr.transfer_date or p_void_date > public.ins_local_today() + 1 then
    raise exception 'INS_TRANSFER_VOID: the void date must be between the transfer date and today';
  end if;

  -- Swap debit and credit, keeping each line's currency, original rate and rounding flag.
  select jsonb_agg(jsonb_build_object(
           'gl_account_id', l.gl_account_id, 'debit', l.credit, 'credit', l.debit,
           'currency', l.currency, 'fx_rate', l.fx_rate, 'is_rounding', l.is_rounding,
           'description', 'Reversal of ' || v_tr.transfer_no))
    into v_lines
    from journal_entry_lines l where l.journal_entry_id = v_tr.journal_entry_id;

  -- Reversal mode: the line guard keeps the original rates, but only rates that the entry
  -- being reversed already used.
  perform set_config('fin.reversal_of', v_tr.journal_entry_id::text, true);
  v_je := post_journal_entry(v_tenant, 'ins_commission_transfer_void', v_tr.id, p_void_date,
    'Void of commission transfer ' || v_tr.transfer_no || ': ' || btrim(p_reason), v_lines);
  perform set_config('fin.reversal_of', '', true);

  insert into ins_commission_events (tenant_id, entry_id, event, amount, journal_entry_id, transfer_id)
  select v_tenant, e.id, 'transfer_voided', e.amount, v_je.id, v_tr.id
    from ins_commission_entries e where e.transfer_id = v_tr.id and e.tenant_id = v_tenant;

  update ins_commission_entries
     set status = 'earned', transfer_id = null, updated_at = now()
   where transfer_id = v_tr.id and tenant_id = v_tenant;

  update ins_commission_transfers
     set status = 'void', void_journal_entry_id = v_je.id, voided_at = now(),
         voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = v_tr.id
  returning * into v_tr;

  return v_tr;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_wht_prepare_remittance(p_period_start date, p_period_end date, p_currency text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_ccy    text;
  v_total  numeric := 0;
  v_id     uuid;
  v_no     text;
  v_n      integer := 0;
  r        record;
  v_exists uuid;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_period_start is null or p_period_end is null or p_period_end < p_period_start then
    raise exception 'INS_WHT_PERIOD: a return needs a period, and the end cannot precede the start';
  end if;

  v_ccy := coalesce(nullif(btrim(coalesce(p_currency, '')), ''), public.fin_ledger_currency(v_tenant));

  -- An open return for the same period and currency is reused rather than
  -- duplicated: the point is one bill per period, not one per click.
  select id into v_exists from public.ins_wht_remittances
   where tenant_id = v_tenant and period_start = p_period_start
     and period_end = p_period_end and currency = v_ccy
     and status in ('prepared', 'approved');
  if v_exists is not null then
    return jsonb_build_object('remittance_id', v_exists, 'already_prepared', true);
  end if;

  select coalesce(sum(x.wht_amount), 0) into v_total
    from public.ins_agent_commission_accruals x
   where x.tenant_id = v_tenant
     and x.currency = v_ccy
     and x.wht_amount > 0
     and x.status <> 'reversed'
     -- The period a withholding belongs to is the one it was withheld IN, which
     -- is the month of payment -- not the month the share happened to be
     -- accrued. s.140 makes the return follow the payment, so a share accrued in
     -- March and paid in July is July's withholding.
     and coalesce(x.paid_on, public.ins_local_date(x.paid_at)) between p_period_start and p_period_end
     and not exists (select 1 from public.ins_wht_remittance_lines l
                      where l.tenant_id = v_tenant and l.accrual_id = x.id);

  if v_total <= 0 then
    return jsonb_build_object('prepared', false,
      'reason', format('no unreported withholding in %s between %s and %s',
                       v_ccy, p_period_start, p_period_end));
  end if;

  -- Numbered per tenant per year, like CXL- and END- elsewhere in insurance.
  select 'WHT-' || extract(year from p_period_start)::int
         || '-' || lpad((count(*) + 1)::text, 4, '0')
    into v_no
    from public.ins_wht_remittances
   where tenant_id = v_tenant
     and extract(year from period_start) = extract(year from p_period_start);

  insert into public.ins_wht_remittances
    (tenant_id, remittance_no, period_start, period_end, currency, amount, status, prepared_by)
  values
    (v_tenant, v_no, p_period_start, p_period_end, v_ccy, v_total, 'prepared', auth.uid())
  returning id into v_id;

  for r in
    select x.id, x.wht_amount
      from public.ins_agent_commission_accruals x
     where x.tenant_id = v_tenant
       and x.currency = v_ccy
       and x.wht_amount > 0
       and x.status <> 'reversed'
       and coalesce(x.paid_on, public.ins_local_date(x.paid_at)) between p_period_start and p_period_end
       and not exists (select 1 from public.ins_wht_remittance_lines l
                        where l.tenant_id = v_tenant and l.accrual_id = x.id)
     order by coalesce(x.paid_on, public.ins_local_date(x.paid_at))
  loop
    insert into public.ins_wht_remittance_lines (tenant_id, remittance_id, accrual_id, amount)
    values (v_tenant, v_id, r.id, r.wht_amount);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('prepared', true, 'remittance_id', v_id,
                            'remittance_no', v_no, 'amount', v_total,
                            'lines', v_n, 'currency', v_ccy);
end
$function$;

-- Insurance-path functions outside the ins_ prefix (cancellation cash and credit, policy cash,
-- settlement, policy credit notes, policy versioning):

CREATE OR REPLACE FUNCTION public.fin_trace(p_entity_type text, p_entity_id uuid)
 RETURNS TABLE(hop integer, hop_kind text, entity_table text, entity_id uuid, reference text, status text, amount numeric, currency text, journal_id uuid, journal_date date, journal_status text, actor uuid, happened_at timestamp with time zone, detail text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    select p.id, p.policy_no as reference, public.ins_local_date(p.created_at) as doc_date,
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

CREATE OR REPLACE FUNCTION public.platform_fin_raise_policy_credit_note_impl(p_tenant_id uuid, p_control_role text, p_party_account_id uuid, p_amount numeric, p_credit_date date, p_offset_gl_account_id uuid, p_applications jsonb, p_reason text, p_reference text, p_policy_id uuid)
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
  if p_credit_date is null or p_credit_date > public.ins_local_today() + 1 then
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

CREATE OR REPLACE FUNCTION public.platform_fin_record_settlement_impl(p_tenant_id uuid, p_bank_account_id uuid, p_direction text, p_party_account_id uuid, p_amount numeric, p_settlement_date date, p_allocations jsonb, p_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS fin_settlements
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_bank     fin_bank_accounts%rowtype;
  v_gl       gl_accounts%rowtype;
  v_allowed  text[];
  v_ids      uuid[];
  v_sum      numeric;
  v_item     fin_open_items%rowtype;
  v_role     record;
  v_ctl_gl   uuid;
  v_ctl_row  gl_accounts%rowtype;
  v_lines    jsonb := '[]'::jsonb;
  v_no       text;
  v_set      fin_settlements%rowtype;
  v_je       journal_entries%rowtype;
  v_elem     jsonb;
  v_desc     text;
  v_functional text;
  v_ccy        text;
  v_foreign    boolean;
  v_sr         numeric := 1;
  v_bank_base  numeric;
  v_total_orig numeric := 0;
  v_result     numeric := 0;
  v_fx_line    jsonb;
begin
  if p_tenant_id is null then raise exception 'tenant id is required'; end if;
  if p_direction not in ('in', 'out') then
    raise exception 'SETTLEMENT_INPUT: direction must be in or out';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'SETTLEMENT_INPUT: amount must be positive';
  end if;
  if p_settlement_date is null or p_settlement_date > public.ins_local_today() + 1 then
    raise exception 'SETTLEMENT_INPUT: settlement date is required and cannot be in the future';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' or jsonb_array_length(p_allocations) = 0 then
    raise exception 'SETTLEMENT_INPUT: allocations must be a non-empty array of {open_item_id, amount}';
  end if;

  v_ids := '{}';
  v_sum := 0;
  for v_elem in select * from jsonb_array_elements(p_allocations) loop
    if jsonb_typeof(v_elem) <> 'object'
       or jsonb_typeof(v_elem -> 'open_item_id') <> 'string'
       or jsonb_typeof(v_elem -> 'amount') <> 'number' then
      raise exception 'SETTLEMENT_INPUT: each allocation needs an open_item_id (string) and an amount (number)';
    end if;
    if (v_elem ->> 'amount')::numeric <= 0 then
      raise exception 'SETTLEMENT_INPUT: allocation amounts must be positive';
    end if;
    if (v_elem ->> 'open_item_id')::uuid = any (v_ids) then
      raise exception 'SETTLEMENT_INPUT: an open item appears twice in the allocations';
    end if;
    v_ids := v_ids || (v_elem ->> 'open_item_id')::uuid;
    v_sum := v_sum + (v_elem ->> 'amount')::numeric;
  end loop;
  if v_sum <> p_amount then
    raise exception 'SETTLEMENT_NOT_FULLY_ALLOCATED: allocations total % but the settlement is %', v_sum, p_amount;
  end if;

  select * into v_bank from fin_bank_accounts where id = p_bank_account_id and tenant_id = p_tenant_id for share;
  if not found then raise exception 'SETTLEMENT_BANK: bank account not found in this company'; end if;
  if not v_bank.is_active then raise exception 'SETTLEMENT_BANK: bank account % is inactive', v_bank.name; end if;
  if v_bank.gl_account_id is null then
    raise exception 'SETTLEMENT_BANK: bank account % has no GL account mapped', v_bank.name;
  end if;

  v_functional := fin_ledger_currency(p_tenant_id);
  v_ccy := v_bank.currency;
  v_foreign := v_ccy <> v_functional;

  select * into v_gl from gl_accounts where id = v_bank.gl_account_id and tenant_id = p_tenant_id;
  if not found or v_gl.account_type <> 'asset' or not v_gl.is_active then
    raise exception 'SETTLEMENT_BANK: the GL account of bank account % is missing, inactive or not an asset account', v_bank.name;
  end if;

  if exists (
    select 1 from fin_bank_accounts b
    where b.tenant_id = p_tenant_id and b.gl_account_id = v_bank.gl_account_id and b.kind <> v_bank.kind
  ) then
    raise exception 'SETTLEMENT_SEGREGATION: GL account % is shared between client money and operating bank accounts', v_gl.account_code;
  end if;
  if v_bank.kind = 'client_money' and exists (
    select 1 from gl_posting_rules r
    where r.tenant_id = p_tenant_id and r.gl_account_id = v_bank.gl_account_id and r.account_role in ('bank', 'cash')
  ) then
    raise exception 'SETTLEMENT_SEGREGATION: GL account % is now the operating bank/cash posting account and cannot hold client money', v_gl.account_code;
  end if;
  if v_bank.kind = 'operating' and exists (
    select 1 from gl_posting_rules r
    where r.tenant_id = p_tenant_id and r.gl_account_id = v_bank.gl_account_id and r.account_role = 'client_money_bank'
  ) then
    raise exception 'SETTLEMENT_SEGREGATION: GL account % is now the client-money posting account and cannot be used by an operating bank account', v_gl.account_code;
  end if;

  v_allowed := case
    when v_bank.kind = 'client_money' and p_direction = 'in'  then array['ar_control', 'insurer_claim_receivable']
    when v_bank.kind = 'client_money'                         then array['insurer_payable', 'client_claim_payable']
    when p_direction = 'in'                                   then array['ar_control', 'commission_receivable']
    else array['ap_control'] end;

  for v_item in
    select * from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids) order by id for update
  loop
    if v_item.control_role <> all (v_allowed) then
      raise exception 'SETTLEMENT_ROLE_NOT_ALLOWED: a % bank account taking money % cannot settle % items (%)',
        replace(v_bank.kind, '_', ' '), p_direction, v_item.control_role, v_item.document_no;
    end if;
    if v_item.control_role in ('insurer_claim_receivable', 'client_claim_payable') and not public.ins_via_rpc() then
      raise exception 'SETTLEMENT_ROLE_NOT_ALLOWED: claim item % is settled from the claim in the Insurance module', v_item.document_no;
    end if;
    if v_item.currency <> v_ccy then
      raise exception 'SETTLEMENT_CURRENCY: item % is in %, but bank account % is in %',
        v_item.document_no, v_item.currency, v_bank.name, v_ccy;
    end if;
    if v_foreign and v_item.journal_entry_id is null then
      raise exception 'SETTLEMENT_ITEM_RATE: item % has no booking entry, so its rate is unknown', v_item.document_no;
    end if;
  end loop;
  if (select count(*) from fin_open_items where tenant_id = p_tenant_id and id = any (v_ids)) <> cardinality(v_ids) then
    raise exception 'ALLOCATION_ITEM: an open item was not found in this company';
  end if;

  v_no := next_doc_number(p_tenant_id, 'fin_settlement', 'STL');
  v_desc := case p_direction when 'in' then 'Receipt ' else 'Payment ' end || v_no;

  if p_direction = 'in' then
    v_lines := v_lines || (jsonb_build_object('gl_account_id', v_bank.gl_account_id, 'debit', p_amount, 'description', v_desc)
                       || case when v_foreign then jsonb_build_object('currency', v_ccy) else '{}'::jsonb end);
  end if;

  if not v_foreign then
    -- Functional currency: control lines grouped by role, exactly as before.
    for v_role in
      select i.control_role, sum((e ->> 'amount')::numeric) as amt
      from jsonb_array_elements(p_allocations) e
      join fin_open_items i on i.id = (e ->> 'open_item_id')::uuid and i.tenant_id = p_tenant_id
      group by i.control_role
      order by i.control_role
    loop
      v_ctl_gl := get_posting_account(p_tenant_id, v_role.control_role);
      if v_ctl_gl is null then
        raise exception 'SETTLEMENT_UNMAPPED_ROLE: the posting role % is not mapped to a GL account', v_role.control_role;
      end if;
      select * into v_ctl_row from gl_accounts where id = v_ctl_gl and tenant_id = p_tenant_id;
      if not found or not v_ctl_row.is_active then
        raise exception 'SETTLEMENT_UNMAPPED_ROLE: the GL account for posting role % is missing or inactive', v_role.control_role;
      end if;
      v_lines := v_lines || jsonb_build_object(
        'gl_account_id', v_ctl_gl,
        case p_direction when 'in' then 'credit' else 'debit' end, v_role.amt,
        'description', v_desc);
    end loop;
  else
    -- Foreign currency: one control line per booking entry, at the rate that entry used,
    -- naming the entry as the rate source.
    for v_role in
      select i.control_role, i.journal_entry_id, i.fx_rate, sum((e ->> 'amount')::numeric) as amt
      from jsonb_array_elements(p_allocations) e
      join fin_open_items i on i.id = (e ->> 'open_item_id')::uuid and i.tenant_id = p_tenant_id
      group by i.control_role, i.journal_entry_id, i.fx_rate
      order by i.control_role, i.journal_entry_id
    loop
      v_ctl_gl := get_posting_account(p_tenant_id, v_role.control_role);
      if v_ctl_gl is null then
        raise exception 'SETTLEMENT_UNMAPPED_ROLE: the posting role % is not mapped to a GL account', v_role.control_role;
      end if;
      select * into v_ctl_row from gl_accounts where id = v_ctl_gl and tenant_id = p_tenant_id;
      if not found or not v_ctl_row.is_active then
        raise exception 'SETTLEMENT_UNMAPPED_ROLE: the GL account for posting role % is missing or inactive', v_role.control_role;
      end if;
      v_lines := v_lines || jsonb_build_object(
        'gl_account_id', v_ctl_gl,
        case p_direction when 'in' then 'credit' else 'debit' end, v_role.amt,
        'currency', v_ccy,
        'rate_from_entry', v_role.journal_entry_id,
        'fx_rate', v_role.fx_rate,
        'description', v_desc);
      v_total_orig := v_total_orig + round(v_role.amt * v_role.fx_rate, 2);
    end loop;
  end if;

  if p_direction = 'out' then
    v_lines := v_lines || (jsonb_build_object('gl_account_id', v_bank.gl_account_id, 'credit', p_amount, 'description', v_desc)
                       || case when v_foreign then jsonb_build_object('currency', v_ccy) else '{}'::jsonb end);
  end if;

  if v_foreign then
    -- Bank line at the settlement-date rate; the difference to what the items were booked
    -- at is the realised result (a gain when more functional currency comes in than was
    -- booked, or less goes out; a loss the other way round).
    v_sr := round((platform_fx_rate(p_tenant_id, v_ccy, p_settlement_date)).rate, 8);
    v_bank_base := round(p_amount * v_sr, 2);
    v_result := case p_direction when 'out' then v_total_orig - v_bank_base else v_bank_base - v_total_orig end;
    v_fx_line := platform_fx_realised_line(p_tenant_id, v_result, 'Realised exchange result on ' || v_no);
    if v_fx_line is not null then
      v_lines := v_lines || v_fx_line;
    end if;
  end if;

  insert into fin_settlements (
    tenant_id, settlement_no, direction, bank_account_id, party_account_id,
    amount, currency, settlement_date, reference, notes, fx_rate, realised_result
  ) values (
    p_tenant_id, v_no, p_direction, p_bank_account_id, p_party_account_id,
    p_amount, v_bank.currency, p_settlement_date, nullif(btrim(p_reference), ''), nullif(btrim(p_notes), ''),
    v_sr, v_result
  )
  returning * into v_set;

  for v_elem in select * from jsonb_array_elements(p_allocations) loop
    insert into fin_allocations (tenant_id, settlement_id, open_item_id, amount)
    values (p_tenant_id, v_set.id, (v_elem ->> 'open_item_id')::uuid, (v_elem ->> 'amount')::numeric);
  end loop;

  v_je := post_journal_entry(p_tenant_id, 'fin_settlement', v_set.id, p_settlement_date, v_desc, v_lines);

  update fin_settlements set journal_entry_id = v_je.id where id = v_set.id returning * into v_set;
  return v_set;
end;
$function$;

CREATE OR REPLACE FUNCTION public.platform_ins_cancellation_cash_recognize(p_request uuid, p_adjustment uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare q ins_cancellation_cash_requests%rowtype; c ins_policy_cancellations%rowtype; a ins_cancellation_insurer_adjustments%rowtype; outstanding numeric; recognized numeric; delta numeric; je journal_entries%rowtype;
begin
 select * into q from ins_cancellation_cash_requests where id=p_request and status='posting' and operation_txid=txid_current() and checker_id=auth.uid() and tenant_id=get_my_tenant_id();
 if not found then raise exception 'INS_CXL_CASH_CONTEXT: recognition requires current checker'; end if;
 select * into a from ins_cancellation_insurer_adjustments where id=p_adjustment and cancellation_id=q.cancellation_id;
 if not found or a.retained_commission_status<>'deferred' or a.retained_commission=0 then return; end if;
 select * into c from ins_policy_cancellations where id=q.cancellation_id;
 select outstanding_amount into outstanding from fin_open_item_balances where id=a.original_item_id;
 select coalesce(sum(amount),0) into recognized from ins_cancellation_commission_events where adjustment_id=a.id;
 delta:=case when outstanding=0 then a.retained_commission else 0 end-recognized;
 if delta=0 then return; end if;
 je:=post_journal_entry(q.tenant_id,'ins_cancellation_cash',q.id,public.ins_local_today(),'Retained commission recognition: '||q.reference,
 jsonb_build_array(jsonb_build_object('gl_account_id',(c.accounting_mappings->>'unearned')::uuid,'debit',greatest(delta,0),'credit',greatest(-delta,0)),jsonb_build_object('gl_account_id',(c.accounting_mappings->>'income')::uuid,'credit',greatest(delta,0),'debit',greatest(-delta,0))));
 insert into ins_cancellation_cash_journals values(q.tenant_id,q.id,je.id,'retained_commission_recognition');
 insert into ins_cancellation_commission_events(tenant_id,request_id,adjustment_id,amount,journal_entry_id) values(q.tenant_id,q.id,a.id,delta,je.id);
end $function$;

CREATE OR REPLACE FUNCTION public.platform_ins_cancellation_cash_validate(p_case uuid, p_kind text, p_adjustment uuid, p_bank uuid, p_to_bank uuid, p_amount numeric, p_date date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare c ins_policy_cancellations%rowtype; a ins_cancellation_insurer_adjustments%rowtype; v jsonb; sh jsonb; b fin_bank_accounts%rowtype; dest fin_bank_accounts%rowtype;
 cap numeric:=0; item uuid; original_transfer ins_commission_transfers%rowtype;
begin
 perform ins_policy_cash_require_finance();
 select * into c from ins_policy_cancellations where id=p_case and tenant_id=get_my_tenant_id();
 if not found or c.status<>'posted' or not exists(select 1 from ins_policies where id=c.policy_id and status='cancelled') then raise exception 'INS_CXL_CASH_STATE: posted cancellation and cancelled policy required'; end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount>9999999999999999.99 or p_date is distinct from public.ins_local_today() then raise exception 'INS_CXL_CASH_INPUT: positive exact-cent amount and current accounting date required'; end if;
 if p_kind is null or p_kind not in('recovery','premium_receipt','refund','remittance','commission_return','commission_withdrawal') then raise exception 'INS_CXL_CASH_INPUT: unsupported cash kind'; end if;
 if exists(select 1 from accounting_periods where tenant_id=c.tenant_id and status='closed' and public.ins_local_today() between period_start and period_end) then raise exception 'INS_CXL_CASH_PERIOD: current period closed'; end if;
 if p_kind in('recovery','remittance','commission_return','commission_withdrawal') then
 select * into a from ins_cancellation_insurer_adjustments where id=p_adjustment and cancellation_id=c.id;
 if not found then raise exception 'INS_CXL_CASH_INSURER: select an adjustment from this cancellation'; end if;
 elsif p_adjustment is not null then raise exception 'INS_CXL_CASH_INPUT: this action has no insurer adjustment'; end if;
 b:=platform_ins_cancellation_cash_bank(p_bank,c.tenant_id,case when p_kind='commission_return' then 'operating' else 'client_money' end);
 if p_kind in('commission_return','commission_withdrawal') then
 dest:=platform_ins_cancellation_cash_bank(p_to_bank,c.tenant_id,case p_kind when 'commission_return' then 'client_money' else 'operating' end);
 if b.id=dest.id or b.gl_account_id=c.clearing_gl_account_id or dest.gl_account_id=c.clearing_gl_account_id then raise exception 'INS_CXL_CASH_BANK: distinct banks and clearing GL required'; end if;
 elsif p_to_bank is not null then raise exception 'INS_CXL_CASH_INPUT: no destination bank for an external settlement'; end if;
 v:=platform_ins_cancellation_cash_position(c.id,b.id);
 if a.id is not null then select x into sh from jsonb_array_elements(v->'insurers') x where x->>'adjustment_id'=a.id::text; end if;
 case p_kind
 when 'recovery' then item:=a.recovery_item_id; cap:=(sh->>'recovery_due')::numeric;
 when 'premium_receipt' then select id into item from fin_open_items where source_type='ins_policy_premium' and source_id=c.policy_id; cap:=(v->>'client_premium_outstanding')::numeric;
 when 'refund' then
 item:=c.refund_item_id;
 cap:=least((v->>'client_refund_outstanding')::numeric,greatest((v->>'proven_cash')::numeric-(v->>'insurer_payable_reserve')::numeric-(v->>'commission_reserve')::numeric-(v->>'retained_fee_vat_reserve')::numeric,0));
 when 'remittance' then
 item:=a.original_item_id;
 cap:=least((sh->>'outstanding')::numeric,(sh->>'funding_cap')::numeric,greatest((v->>'proven_cash')::numeric-(v->>'client_refund_outstanding')::numeric-trunc((v->>'retained_fee_vat_reserve')::numeric*(v->>'funding_ratio')::numeric,2)-(v->>'earned_commission_reserve')::numeric,0));
 when 'commission_return' then
 select * into original_transfer from ins_commission_transfers where id=(a.original_commission_state->>'transfer_id')::uuid and status='posted';
 if original_transfer.id is null or original_transfer.to_bank_account_id<>b.id then raise exception 'INS_CXL_CASH_BANK: return commission from its original operating bank'; end if;
 cap:=least((sh->>'commission_return_due')::numeric,greatest((v->>'bank_book_cash')::numeric,0));
 when 'commission_withdrawal' then
 cap:=least((sh->>'commission_withdrawal_due')::numeric,(sh->>'funding_cap')::numeric,
 greatest((v->>'proven_cash')::numeric-(v->>'client_refund_outstanding')::numeric-(v->>'insurer_payable_reserve')::numeric-(v->>'retained_fee_vat_reserve')::numeric-((v->>'commission_reserve')::numeric-(sh->>'commission_withdrawal_due')::numeric),0));
 end case;
 if p_kind in('refund','remittance','commission_withdrawal') then
 if not(v->>'bank_funding_sound')::boolean then raise exception 'INS_CXL_CASH_FUNDS: unattributed client-bank shortfall; protect other policies and claims, Finance review required'; end if;
 cap:=least(cap,greatest((v->>'bank_proven_cash')::numeric,0),greatest((v->>'bank_book_cash')::numeric,0)); end if;
 if cap is null or p_amount>cap then raise exception 'INS_CXL_CASH_FUNDS: maximum % is %, requested %; refresh balances and reconcile actual funds first',p_kind,coalesce(cap,0),p_amount; end if;
 if item is not null then
  perform id from fin_open_items where id=item for update;
  if get_posting_account(c.tenant_id,(select control_role from fin_open_items where id=item)) is distinct from
   (c.accounting_mappings->>case p_kind when 'refund' then 'refund_payable' when 'remittance' then 'payable' else 'ar' end)::uuid then raise exception 'INS_CXL_CASH_MAPPING: original control mapping changed'; end if;
 end if;
 return item;
end $function$;

CREATE OR REPLACE FUNCTION public.platform_ins_cancellation_credit(p_cancellation_id uuid, p_item_id uuid, p_amount numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_nr:=round((platform_fx_rate(c.tenant_id,v_ccy,public.ins_local_today())).rate,8);
  v_booked:=round(p_amount*v_rate,2);
  v_base:=round(p_amount*v_nr,2);
  v_result:=case i.side when 'receivable' then v_base-v_booked else v_booked-v_base end;
 end if;
 insert into ins_cancellation_credit_links(tenant_id,cancellation_id,credit_note_id,open_item_id,amount) values(c.tenant_id,c.id,nid,i.id,p_amount);
 insert into fin_credit_notes(id,tenant_id,credit_note_no,side,control_role,party_account_id,offset_gl_account_id,amount,currency,fx_rate,realised_result,credit_date,reason,reference)
 values(nid,c.tenant_id,no,i.side,i.control_role,i.party_account_id,c.clearing_gl_account_id,p_amount,v_ccy,v_nr,v_result,public.ins_local_today(),c.reason,c.cancellation_no);
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
 je:=post_journal_entry(c.tenant_id,'fin_credit_note',nid,public.ins_local_today(),'Cancellation credit '||c.cancellation_no,lines);
 update fin_credit_notes set journal_entry_id=je.id where id=nid;
 insert into ins_cancellation_journals values(c.tenant_id,c.id,je.id,'original_item_credit');
 return nid;
end $function$;

CREATE OR REPLACE FUNCTION public.platform_ins_policy_cash_legacy_validate(p_policy_id uuid, p_kind text, p_bank_id uuid, p_amount numeric, p_date date)
 RETURNS fin_open_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare p ins_policies%rowtype; b fin_bank_accounts%rowtype; i fin_open_items%rowtype; v jsonb; cap numeric;
begin
  perform ins_policy_cash_require_finance();
  if p_kind is null or p_kind not in ('receipt','remittance') or p_amount is null or p_amount<=0
     or p_amount<>round(p_amount,2) or p_amount>9999999999999999.99 then
    raise exception 'INS_CASH_INPUT: choose receipt/remittance and a positive amount with at most two decimals';
  end if;
  if p_date is null or p_date>public.ins_local_today() then raise exception 'INS_CASH_DATE: cash date must not be in the future'; end if;
  select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  if p.status not in ('active','renewed') then raise exception 'INS_CASH_STATE: only bound, non-reversed policies accept cash'; end if;
  -- Same policy/item lock order as reversal. Serializes receipts, remittances,
  -- voids and commission withdrawals for this policy across different banks.
  perform id from fin_open_items where tenant_id=p.tenant_id and source_id=p.id
    and source_type in ('ins_policy_premium','ins_policy_insurer') order by id for update;
  select * into b from fin_bank_accounts where id=p_bank_id and tenant_id=p.tenant_id for share;
  if not found or b.kind<>'client_money' or not b.is_active or b.gl_account_id is null or b.currency<>p.currency then
    raise exception 'INS_CASH_BANK: an active mapped client-money bank in the policy currency is required';
  end if;
  select * into i from fin_open_items where tenant_id=p.tenant_id and source_id=p.id
    and source_type=case p_kind when 'receipt' then 'ins_policy_premium' else 'ins_policy_insurer' end;
  if not found then raise exception 'INS_CASH_ITEM: policy open item missing'; end if;
  v := ins_policy_cash_totals(p.id);
  cap := case p_kind when 'receipt' then (v->>'client_outstanding')::numeric else (v->>'maximum_remittance')::numeric end;
  if p_amount>cap then
    raise exception 'INS_CASH_CAP: requested % exceeds available %; remittances are capped by allocated collections and outstanding insurer liability',p_amount,cap;
  end if;
  return i;
end $function$;

CREATE OR REPLACE FUNCTION public.platform_ins_policy_reversal_legacy_context(p_policy_id uuid, p_in_progress boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  p ins_policies%rowtype; r ins_policy_reversals%rowtype;
  a fin_open_items%rowtype; b fin_open_items%rowtype;
  ar uuid; payable uuid; offset_id uuid; treatment text := 'none';
  je journal_entries%rowtype; n integer; ce ins_commission_entries%rowtype;
begin
  if not can_manage_insurance() or effective_user_id() is distinct from auth.uid() then
    raise exception 'INS_FORBIDDEN: insurance manager required; user-level impersonation cannot reverse policies' using errcode='42501';
  end if;
  select * into p from ins_policies where id=p_policy_id and tenant_id=get_my_tenant_id() for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  if p.status <> 'active' then raise exception 'INS_REVERSAL_STATE: only active policies can be reversed'; end if;
  if p.renewal_of_id is not null or exists(select 1 from ins_policies where renewal_of_id=p.id) then
    raise exception 'INS_REVERSAL_RENEWAL: renewal chains require finance review';
  end if;
  if exists(select 1 from ins_claims where policy_id=p.id) then
    raise exception 'INS_REVERSAL_CLAIM: this policy has a claim; use the future cancellation/refunds workflow';
  end if;
  if exists(select 1 from accounting_periods where tenant_id=p.tenant_id and status='closed'
            and public.ins_local_today() between period_start and period_end) then
    raise exception 'INS_REVERSAL_PERIOD: the current accounting period is closed';
  end if;
  -- Same deterministic item order as the shared settlement/credit machinery.
  perform id from fin_open_items where tenant_id=p.tenant_id and source_id=p.id
    and source_type in ('ins_policy_premium','ins_policy_insurer') order by id for update;
  select * into a from fin_open_items where tenant_id=p.tenant_id and source_id=p.id and source_type='ins_policy_premium';
  select * into b from fin_open_items where tenant_id=p.tenant_id and source_id=p.id and source_type='ins_policy_insurer';
  select count(*) into n from fin_open_items where tenant_id=p.tenant_id and source_id=p.id
    and source_type in ('ins_policy_premium','ins_policy_insurer');
  if n<>2 or a.control_role<>'ar_control' or b.control_role<>'insurer_payable'
     or a.amount is distinct from p.gross_premium or b.amount is distinct from p.net_premium_to_insurer
     or a.currency is distinct from p.currency or b.currency is distinct from p.currency then
    raise exception 'INS_REVERSAL_HISTORY: original open items do not reconcile; finance review required';
  end if;
  select * into r from ins_policy_reversals where original_policy_id=p.id;
  if p_in_progress and (r.id is null or r.outcome<>'building' or r.operation_txid<>txid_current()
     or r.reversed_by is distinct from auth.uid()) then
    raise exception 'INS_REVERSAL_INTERNAL: no authorized reversal transaction';
  end if;
  if exists(select 1 from fin_allocations x join fin_settlements s on s.id=x.settlement_id
       where x.open_item_id in (a.id,b.id) and s.status='posted')
     or exists(select 1 from fin_credit_applications x join fin_credit_notes c on c.id=x.credit_note_id
       where x.open_item_id in (a.id,b.id) and c.status='posted'
       and (not p_in_progress or c.id is distinct from r.premium_credit_note_id
            and c.id is distinct from r.insurer_credit_note_id)) then
    raise exception 'INS_REVERSAL_MOVEMENT: effective payment or credit remains; use cancellation/refunds';
  end if;
  select * into ce from ins_commission_entries where policy_id=p.id for update;
  if ce.id is not null and (ce.status<>'deferred' or ce.earned_on is not null or ce.transfer_id is not null) then
    raise exception 'INS_REVERSAL_COMMISSION: effective recognition or commission transfer remains';
  end if;
  select * into je from journal_entries where id=p.journal_entry_id and tenant_id=p.tenant_id for update;
  if not found or je.status<>'posted' or je.source_type<>'ins_policy_bind' or je.source_id is distinct from p.id then
    raise exception 'INS_REVERSAL_HISTORY: original bind journal is missing or void; finance review required';
  end if;
  ar:=get_posting_account(p.tenant_id,'ar_control');
  payable:=get_posting_account(p.tenant_id,'insurer_payable');
  select count(*) into n from journal_entry_lines where journal_entry_id=je.id;
  if n <> (case when p.commission_amount>0 then 3 else 2 end)
    or not exists(select 1 from journal_entry_lines where journal_entry_id=je.id and gl_account_id=ar and debit=p.gross_premium and credit=0)
    or not exists(select 1 from journal_entry_lines where journal_entry_id=je.id and gl_account_id=payable and credit=p.net_premium_to_insurer and debit=0) then
    raise exception 'INS_REVERSAL_HISTORY: bind amounts or historical control mappings do not reconcile';
  end if;
  if p.commission_amount>0 then
    select gl_account_id into offset_id from journal_entry_lines where journal_entry_id=je.id
      and credit=p.commission_amount and debit=0 and gl_account_id not in (ar,payable);
    if offset_id=get_posting_account(p.tenant_id,'unearned_commission') then treatment:='deferred';
    elsif offset_id=get_posting_account(p.tenant_id,'commission_income') then treatment:='legacy';
    else raise exception 'INS_REVERSAL_HISTORY: historical commission mapping cannot be identified'; end if;
    if treatment='legacy' and ce.id is not null then
      raise exception 'INS_REVERSAL_HISTORY: legacy journal has an inconsistent deferred commission record';
    end if;
    if treatment='deferred' and (ce.id is null or ce.amount<>p.commission_amount) then
      raise exception 'INS_REVERSAL_HISTORY: deferred commission record does not reconcile';
    end if;
  else
    -- Zero commission: equal opposite gross offset legs cancel. Explicitly use
    -- the mapped commission-income account; missing mapping needs finance review.
    offset_id:=get_posting_account(p.tenant_id,'commission_income');
  end if;
  if offset_id is null or offset_id in (ar,payable) then
    raise exception 'INS_REVERSAL_HISTORY: a distinct commission offset mapping is required';
  end if;
  return jsonb_build_object('premium_item_id',a.id,'insurer_item_id',b.id,
    'client_party_id',a.party_account_id,'insurer_party_id',b.party_account_id,
    'offset_id',offset_id,'gross',p.gross_premium,'net',p.net_premium_to_insurer,'treatment',treatment);
end $function$;

CREATE OR REPLACE FUNCTION public.platform_ins_transfer_before_cancellation_impl(p_from_bank_account_id uuid, p_to_bank_account_id uuid, p_transfer_date date, p_entry_ids uuid[] DEFAULT NULL::uuid[], p_notes text DEFAULT NULL::text)
 RETURNS ins_commission_transfers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant   uuid := get_my_tenant_id();
  v_from     fin_bank_accounts%rowtype;
  v_to       fin_bank_accounts%rowtype;
  v_ids      uuid[];
  v_total    numeric(18,2);
  v_max_date date;
  v_trust    numeric;
  v_id       uuid := gen_random_uuid();
  v_no       text;
  v_je       journal_entries;
  v_tr       ins_commission_transfers%rowtype;
  v_desc     text;
  v_ccy      text;
  v_foreign  boolean;
  v_grp      record;
  v_rate     numeric;
  v_nr       numeric;
  v_lines    jsonb;
  v_booked   numeric := 0;
  v_result   numeric;
  v_fx_line  jsonb;
  v_unearned_gl uuid;
  v_other       text;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: only insurance admins and managers can transfer commission' using errcode = '42501';
  end if;
  if v_tenant is null then
    raise exception 'INS_FORBIDDEN: no company context' using errcode = '42501';
  end if;
  if p_transfer_date is null or p_transfer_date > public.ins_local_today() + 1 then
    raise exception 'INS_TRANSFER_INPUT: the transfer date is required and cannot be in the future';
  end if;
  if p_from_bank_account_id is null or p_to_bank_account_id is null
     or p_from_bank_account_id = p_to_bank_account_id then
    raise exception 'INS_TRANSFER_INPUT: choose a client-money bank account and a different operating bank account';
  end if;

  select * into v_from from fin_bank_accounts where id = p_from_bank_account_id and tenant_id = v_tenant for share;
  select * into v_to   from fin_bank_accounts where id = p_to_bank_account_id   and tenant_id = v_tenant for share;
  if v_from.id is null or v_to.id is null then
    raise exception 'INS_TRANSFER_BANK: bank account not found in this company';
  end if;
  if v_from.kind <> 'client_money' or v_to.kind <> 'operating' then
    raise exception 'INS_TRANSFER_BANK: commission moves from a client-money account to an operating account';
  end if;
  if not v_from.is_active or not v_to.is_active then
    raise exception 'INS_TRANSFER_BANK: both bank accounts must be active';
  end if;
  if v_from.gl_account_id is null or v_to.gl_account_id is null or v_from.gl_account_id = v_to.gl_account_id then
    raise exception 'INS_TRANSFER_BANK: each bank account needs its own mapped GL account';
  end if;
  -- A transfer moves money between accounts that hold the same currency; converting is a
  -- bank payment and a realised result, not a transfer.
  if v_from.currency <> v_to.currency then
    raise exception 'INS_TRANSFER_CURRENCY: a transfer moves money in one currency (% vs %); convert through a bank payment instead',
      v_from.currency, v_to.currency;
  end if;
  v_ccy     := v_from.currency;
  v_foreign := v_ccy <> fin_ledger_currency(v_tenant);

  select array_agg(e.id order by e.id), sum(e.amount), max(e.earned_on)
    into v_ids, v_total, v_max_date
    from ins_commission_entries e
   where e.tenant_id = v_tenant and e.status = 'earned'
     and not exists(select 1 from ins_policy_cancellations c where c.policy_id=e.policy_id and c.status='posted')
     and (p_entry_ids is null or e.id = any (p_entry_ids));
  if v_ids is null then
    raise exception 'INS_TRANSFER_NOTHING: there is no earned commission to transfer';
  end if;
  if p_entry_ids is not null and cardinality(v_ids) <> cardinality(
       (select array_agg(distinct x) from unnest(p_entry_ids) x)) then
    raise exception 'INS_TRANSFER_ENTRIES: every selected entry must be earned and not yet transferred';
  end if;
  -- The trust account holds the commission in the policies' currency; transferring it
  -- through accounts of another currency would not net it.
  select min(p.currency) into v_other
    from ins_commission_entries e join ins_policies p on p.id = e.policy_id
   where e.tenant_id = v_tenant and e.id = any (v_ids) and p.currency is distinct from v_ccy;
  if v_other is not null then
    raise exception 'INS_TRANSFER_CURRENCY: selected commission was earned on % policies; transfer it through % accounts of its own', v_other, v_ccy;
  end if;
  perform 1 from ins_commission_entries where id = any (v_ids) order by id for update;

  if p_transfer_date < v_max_date then
    raise exception 'INS_TRANSFER_DATE: the transfer date cannot be before commission was earned (%)', v_max_date;
  end if;

  -- Client money actually held, in the accounts' currency.
  select coalesce(sum(l.debit - l.credit), 0) into v_trust
    from journal_entry_lines l
   where l.tenant_id = v_tenant and l.gl_account_id = v_from.gl_account_id and l.currency = v_ccy;
  if v_trust < v_total then
    raise exception 'INS_TRANSFER_TRUST_SHORT: client-money account % holds % in the ledger, less than the % to transfer',
      v_from.name, v_trust, v_total;
  end if;

  v_no   := next_doc_number(v_tenant, 'ins_commission_transfer', 'CTR');
  v_desc := 'Commission transfer ' || v_no;

  if not v_foreign then
    v_je := post_journal_entry(v_tenant, 'ins_commission_transfer', v_id, p_transfer_date, v_desc,
      jsonb_build_array(
        jsonb_build_object('gl_account_id', v_to.gl_account_id,   'debit',  v_total, 'description', v_desc),
        jsonb_build_object('gl_account_id', v_from.gl_account_id, 'credit', v_total, 'description', v_desc)));
  else
    -- The trust side is credited at the rate each policy was bound at (naming the bind
    -- entry as the rate source), the operating side debited at the transfer-date rate,
    -- and the difference is the realised result. The trust nets to zero in the currency
    -- and in base.
    v_unearned_gl := get_posting_account(v_tenant, 'unearned_commission');
    v_nr     := round((platform_fx_rate(v_tenant, v_ccy, p_transfer_date)).rate, 8);
    v_lines  := jsonb_build_array();
    for v_grp in
      select p.journal_entry_id as bind_entry, sum(e.amount) as amt
        from ins_commission_entries e join ins_policies p on p.id = e.policy_id
       where e.tenant_id = v_tenant and e.id = any (v_ids)
       group by p.journal_entry_id
       order by p.journal_entry_id
    loop
      select l.fx_rate into v_rate
        from journal_entry_lines l
       where l.journal_entry_id = v_grp.bind_entry and l.tenant_id = v_tenant and l.currency = v_ccy
         and (v_unearned_gl is null or l.gl_account_id = v_unearned_gl)
       order by l.id
       limit 1;
      if v_rate is null then
        select l.fx_rate into v_rate
          from journal_entry_lines l
         where l.journal_entry_id = v_grp.bind_entry and l.tenant_id = v_tenant and l.currency = v_ccy
         order by l.id
         limit 1;
      end if;
      if v_rate is null then
        raise exception 'INS_TRANSFER_HISTORY: the bind journal of entry % has no % line, so the booked rate is unknown', v_grp.bind_entry, v_ccy;
      end if;
      v_lines := v_lines || jsonb_build_object('gl_account_id', v_from.gl_account_id, 'credit', v_grp.amt,
        'currency', v_ccy, 'rate_from_entry', v_grp.bind_entry, 'fx_rate', v_rate, 'description', v_desc);
      v_booked := v_booked + round(v_grp.amt * v_rate, 2);
    end loop;
    v_lines := v_lines || jsonb_build_object('gl_account_id', v_to.gl_account_id, 'debit', v_total,
      'currency', v_ccy, 'description', v_desc);
    v_result  := round(v_total * v_nr, 2) - v_booked;
    v_fx_line := platform_fx_realised_line(v_tenant, v_result, 'Realised exchange result on ' || v_no);
    if v_fx_line is not null then
      v_lines := v_lines || v_fx_line;
    end if;
    v_je := post_journal_entry(v_tenant, 'ins_commission_transfer', v_id, p_transfer_date, v_desc, v_lines);
  end if;

  insert into ins_commission_transfers (
    id, tenant_id, transfer_no, from_bank_account_id, to_bank_account_id,
    transfer_date, amount, currency, notes, journal_entry_id
  ) values (
    v_id, v_tenant, v_no, v_from.id, v_to.id,
    p_transfer_date, v_total, v_from.currency, nullif(btrim(p_notes), ''), v_je.id
  ) returning * into v_tr;

  update ins_commission_entries
     set status = 'transferred', transfer_id = v_id, updated_at = now()
   where id = any (v_ids);

  insert into ins_commission_events (tenant_id, entry_id, event, amount, journal_entry_id, transfer_id)
  select v_tenant, e.id, 'transferred', e.amount, v_je.id, v_id
    from ins_commission_entries e where e.id = any (v_ids);

  return v_tr;
end;
$function$;

CREATE OR REPLACE FUNCTION public.platform_stamp_policy_version()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_raw    text := to_jsonb(new) ->> tg_argv[0];
  v_date   date := coalesce(left(v_raw, 10)::date, public.ins_local_today());
  v_batch  uuid;
begin
  begin
    v_batch := nullif(current_setting('acct.import_batch', true), '')::uuid;
  exception when others then
    v_batch := null;
  end;

  if v_batch is not null and exists (
       select 1 from ins_import_batches b
        where b.id = v_batch and b.tenant_id = new.tenant_id and b.status in ('validated', 'committed')) then
    new.accounting_policy_version := 1;
  else
    new.accounting_policy_version := platform_accounting_policy_version(new.tenant_id, v_date);
  end if;
  return new;
end;
$function$;


-- Shared finance functions on the receipt and credit-note path (the insurance flows above call them; a receipt
-- posted on the Kampala date must be voidable on the same Kampala date). These are shared with other modules.

CREATE OR REPLACE FUNCTION public.platform_fin_raise_credit_note_impl(p_tenant_id uuid, p_control_role text, p_party_account_id uuid, p_amount numeric, p_credit_date date, p_offset_gl_account_id uuid, p_applications jsonb, p_reason text, p_reference text DEFAULT NULL::text)
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
  if p_credit_date is null or p_credit_date > public.ins_local_today() + 1 then
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

CREATE OR REPLACE FUNCTION public.platform_fin_void_credit_note_impl(p_tenant_id uuid, p_credit_note_id uuid, p_reason text, p_void_date date DEFAULT public.ins_local_today())
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
  if p_void_date is null or p_void_date < v_note.credit_date or p_void_date > public.ins_local_today() + 1 then
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

CREATE OR REPLACE FUNCTION public.platform_fin_void_settlement_impl(p_tenant_id uuid, p_settlement_id uuid, p_reason text, p_void_date date DEFAULT public.ins_local_today())
 RETURNS fin_settlements
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_set   fin_settlements%rowtype;
  v_lines jsonb;
  v_je    journal_entries%rowtype;
begin
  if p_tenant_id is null then raise exception 'tenant id is required'; end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'SETTLEMENT_VOID: a reason of at least 5 characters is required';
  end if;

  select * into v_set from fin_settlements where id = p_settlement_id and tenant_id = p_tenant_id for update;
  if not found then raise exception 'SETTLEMENT_VOID: settlement not found in this company'; end if;

  if exists (
    select 1 from bank_reconciliations r
     where r.settlement_id = v_set.id and r.tenant_id = p_tenant_id
  ) then
    raise exception 'SETTLEMENT_VOID: settlement % is reconciled to a bank statement line; unmatch it first', v_set.settlement_no;
  end if;

  if v_set.status <> 'posted' then raise exception 'SETTLEMENT_VOID: settlement % is already void', v_set.settlement_no; end if;
  if v_set.journal_entry_id is null then raise exception 'SETTLEMENT_VOID: settlement % has no posted journal', v_set.settlement_no; end if;
  if p_void_date is null or p_void_date < v_set.settlement_date or p_void_date > public.ins_local_today() + 1 then
    raise exception 'SETTLEMENT_VOID: the void date must be between the settlement date and today';
  end if;

  -- Swap debit and credit, keeping each line's currency, original rate and rounding flag.
  select jsonb_agg(jsonb_build_object(
           'gl_account_id', l.gl_account_id,
           'debit', l.credit,
           'credit', l.debit,
           'currency', l.currency,
           'fx_rate', l.fx_rate,
           'is_rounding', l.is_rounding,
           'description', 'Reversal of ' || v_set.settlement_no))
    into v_lines
    from journal_entry_lines l
   where l.journal_entry_id = v_set.journal_entry_id;

  -- Reversal mode: the line guard keeps the original rates, but only rates that the entry
  -- being reversed already used.
  perform set_config('fin.reversal_of', v_set.journal_entry_id::text, true);
  v_je := post_journal_entry(p_tenant_id, 'fin_settlement_void', v_set.id, p_void_date,
                             'Void of settlement ' || v_set.settlement_no || ': ' || btrim(p_reason), v_lines);
  perform set_config('fin.reversal_of', '', true);

  update fin_settlements
     set status = 'void', void_journal_entry_id = v_je.id, voided_at = now(),
         voided_by = auth.uid(), void_reason = btrim(p_reason)
   where id = v_set.id
   returning * into v_set;

  return v_set;
end;
$function$;


-- Shared finance functions on the receipt and credit-note path (the insurance flows above call them; a receipt
-- posted on the Kampala date must be voidable on the same Kampala date). These are shared with other modules.

CREATE OR REPLACE FUNCTION public.fin_void_credit_note(p_credit_note_id uuid, p_reason text, p_void_date date DEFAULT public.ins_local_today())
 RETURNS fin_credit_notes
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not is_finance_team_member('finance'::text) then
    raise exception 'not authorized: voiding a credit note requires the finance role' using errcode = '42501';
  end if;
  return platform_fin_void_credit_note_impl(get_my_tenant_id(), p_credit_note_id, p_reason, p_void_date);
end;
$function$;

CREATE OR REPLACE FUNCTION public.fin_void_settlement(p_settlement_id uuid, p_reason text, p_void_date date DEFAULT public.ins_local_today())
 RETURNS fin_settlements
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not is_finance_team_member('finance'::text) then
    raise exception 'not authorized: voiding a settlement requires the finance role' using errcode = '42501';
  end if;
  return platform_fin_void_settlement_impl(get_my_tenant_id(), p_settlement_id, p_reason, p_void_date);
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_insurer_remittance_position(p_as_of date DEFAULT public.ins_local_today())
 RETURNS TABLE(insurer_id uuid, insurer_name text, currency text, unremitted_amount numeric, earliest_receipt date, earliest_deadline date, status text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  r record;
begin
  if not public.has_module_role('insurance', array['admin', 'manager', 'member']) then
    raise exception 'INS_FORBIDDEN: insurance access is required' using errcode = '42501';
  end if;

  for r in
    select ip.insurer_id,
           coalesce(ins.name, '?') as insurer_name,
           ip.currency,
           sum(r2.unremitted_amount) as unremitted_amount,
           min(r2.receipt_date) as earliest_receipt,
           min(r2.deadline_date) as earliest_deadline
      from public.ins_policies ip
      join public.ins_insurers ins on ins.tenant_id = ip.tenant_id and ins.id = ip.insurer_id
      cross join lateral public.ins_unremitted_premium_report(p_as_of) r2
     where ip.tenant_id = v_tenant
       and r2.policy_id = ip.id
     group by ip.insurer_id, ins.name, ip.currency
  loop
    insurer_id := r.insurer_id;
    insurer_name := r.insurer_name;
    currency := r.currency;
    unremitted_amount := r.unremitted_amount;
    earliest_receipt := r.earliest_receipt;
    earliest_deadline := r.earliest_deadline;
    status := case
      when r.earliest_receipt is null then 'receipt_date_missing'
      when r.earliest_deadline is null then 'deadline_not_set'
      when r.earliest_deadline < p_as_of then 'overdue'
      when r.earliest_deadline = p_as_of then 'due_today'
      else 'within_deadline'
    end;
    return next;
  end loop;
end;
$function$;

CREATE OR REPLACE FUNCTION public.ins_price_charges_for(p_tenant_id uuid, p_params jsonb, p_product_line_code text DEFAULT NULL::text, p_currency text DEFAULT 'UGX'::text, p_on date DEFAULT public.ins_local_today())
 RETURNS TABLE(catalogue_id uuid, code text, name text, charge_class text, basis text, amount numeric, collector text, recipient_name text, recipient_kind text, payable_role text, payable_account_id uuid, catalogue_version integer, snapshot jsonb, warnings text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c record;
  v_formula jsonb;
  v_base text;
  v_base_value numeric;
  v_per text;
  v_per_value numeric;
  v_amount numeric;
  v_warn text[] := '{}';
  v_acct uuid;
  b jsonb;
  v_band_total numeric;
  v_lower numeric;
  v_upper numeric;
  v_remaining numeric;
begin
  if p_params is null or jsonb_typeof(p_params) is distinct from 'object' then
    raise exception 'INS_CHARGE_INPUT: parameters must be a JSON object of base quantities';
  end if;
  if p_params ? 'gross_premium' and (p_params ->> 'gross_premium')::numeric < 0 then
    raise exception 'INS_CHARGE_INPUT: gross premium cannot be negative';
  end if;

  for c in
    select k.*, cl.is_statutory
      from public.ins_charge_catalogue k
      join public.ins_charge_class cl on cl.code = k.charge_class
     where k.is_active
       and (k.tenant_id is null or k.tenant_id = p_tenant_id)
       -- A statutory rate is a claim about an instrument and must be verified
       -- against one. A commercial fee has no instrument, so the requirement is
       -- a property of the CLASS (the registry), not a name checked in this body.
       and (not cl.is_statutory or k.verification_status = 'verified')
       and k.effective_from <= p_on
       and (k.effective_to is null or k.effective_to >= p_on)
       and (k.applies_to_product_lines is null
            or p_product_line_code is null
            or p_product_line_code = any (k.applies_to_product_lines))
     order by cl.sort_order, k.code
  loop
    v_formula := c.formula;
    v_warn := '{}';
    v_amount := null;

    ------------------------------------------------------------------
    -- rate: base x rate, with optional floor and cap
    ------------------------------------------------------------------
    if v_formula ->> 'kind' = 'rate' then
      v_base := v_formula ->> 'base';
      if not (p_params ? v_base) then
        raise exception 'INS_CHARGE_PARAM_MISSING: % prices against "%", which the caller did not supply. Refusing rather than charging zero, because a levy silently not charged is under-billing nobody notices.', c.code, v_base;
      end if;
      v_base_value := (p_params ->> v_base)::numeric;
      v_amount := v_base_value * (v_formula ->> 'rate_pct')::numeric / 100;

    ------------------------------------------------------------------
    -- fixed: amount x a count (default one per policy)
    ------------------------------------------------------------------
    elsif v_formula ->> 'kind' = 'fixed' then
      v_per := coalesce(v_formula ->> 'per', 'policy');
      if v_per = 'policy' then
        v_per_value := coalesce((p_params ->> 'policy_count')::numeric, 1);
      else
        if not (p_params ? v_per) then
          raise exception 'INS_CHARGE_PARAM_MISSING: % is charged per "%", which the caller did not supply. Refusing rather than charging one unit.', c.code, v_per;
        end if;
        v_per_value := (p_params ->> v_per)::numeric;
      end if;
      v_amount := (v_formula ->> 'amount')::numeric * v_per_value;

    ------------------------------------------------------------------
    -- banded: marginal rates over ascending bands
    ------------------------------------------------------------------
    elsif v_formula ->> 'kind' = 'banded' then
      v_base := v_formula ->> 'base';
      if not (p_params ? v_base) then
        raise exception 'INS_CHARGE_PARAM_MISSING: % is banded on "%", which the caller did not supply.', c.code, v_base;
      end if;
      v_base_value := (p_params ->> v_base)::numeric;
      v_band_total := 0;
      v_lower := 0;
      v_remaining := v_base_value;
      for b in select value from jsonb_array_elements(v_formula -> 'bands') loop
        exit when v_remaining <= 0;
        v_upper := case when b ? 'up_to' and jsonb_typeof(b -> 'up_to') is distinct from 'null'
                        then (b ->> 'up_to')::numeric
                        else v_base_value end;
        v_band_total := v_band_total
          + greatest(least(v_base_value, v_upper) - v_lower, 0)
            * (b ->> 'rate_pct')::numeric / 100;
        v_remaining := v_base_value - v_upper;
        v_lower := v_upper;
      end loop;
      v_amount := v_band_total;
    end if;

    if v_amount is null then
      raise exception 'INS_CHARGE_FORMULA_UNKNOWN: % has formula kind "%", which this build cannot price', c.code, v_formula ->> 'kind';
    end if;

    -- Floors, caps and rounding, common to every kind.
    if v_formula ? 'min' then
      v_amount := greatest(v_amount, (v_formula ->> 'min')::numeric);
    end if;
    if v_formula ? 'max' then
      v_amount := least(v_amount, (v_formula ->> 'max')::numeric);
    end if;
    v_amount := round(v_amount, coalesce((v_formula ->> 'round_to')::integer, 2));

    select r.gl_account_id into v_acct
      from public.gl_posting_rules r
     where r.tenant_id = p_tenant_id and r.account_role = c.payable_role;

    if v_acct is null and v_amount > 0 then
      v_warn := v_warn || (('INS_CHARGE_PAYABLE_UNCONFIGURED: ' || c.code
        || ' is payable to role ' || c.payable_role || ', which this company has not mapped to an account'));
    end if;

    catalogue_id := c.id;
    code := c.code;
    name := c.name;
    charge_class := c.charge_class;
    -- `basis` survives as a human summary for reports, derived from the formula.
    basis := case v_formula ->> 'kind'
               when 'rate' then 'rate on ' || (v_formula ->> 'base')
               when 'fixed' then 'fixed per ' || coalesce(v_formula ->> 'per', 'policy')
               when 'banded' then 'banded on ' || (v_formula ->> 'base')
             end;
    amount := v_amount;
    collector := c.collector;
    recipient_name := c.recipient_name;
    recipient_kind := c.recipient_kind;
    payable_role := c.payable_role;
    payable_account_id := v_acct;
    catalogue_version := c.version;
    snapshot := to_jsonb(c) - 'created_by';
    warnings := v_warn;
    return next;
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION public.ins_statutory_enforcement(p_tenant_id uuid, p_on date DEFAULT public.ins_local_today())
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select coalesce(
    (select s.value from public.company_accounting_settings s
      where s.tenant_id = p_tenant_id
        and s.setting_key = 'ins.statutory_charge_enforcement'
        and s.status = 'approved'
        and s.effective_from <= p_on
      order by s.effective_from desc
      limit 1),
    'advisory')
$function$;

CREATE OR REPLACE FUNCTION public.ins_unremitted_premium_report(p_as_of date DEFAULT public.ins_local_today())
 RETURNS TABLE(policy_id uuid, policy_no text, insurer_id uuid, unremitted_amount numeric, receipt_date date, deadline_date date, status text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant  uuid := get_my_tenant_id();
  p         record;
  v_avail   numeric;
  v_receipt date;
  v_due     date;
  v_status  text;
begin
  if not has_module_role('insurance', array['admin', 'manager', 'member']) then
    raise exception 'INS_FORBIDDEN: insurance access is required' using errcode = '42501';
  end if;

  for p in
    select ip.id, ip.policy_no, ip.insurer_id
      from public.ins_policies ip
     where ip.tenant_id = v_tenant
       and ip.status in ('active', 'renewed')
  loop
    v_avail := coalesce((public.ins_policy_cash_totals(p.id) ->> 'available_allocated_funds')::numeric, 0);
    continue when v_avail <= 0;

    select min(s.settlement_date) into v_receipt
      from public.fin_open_items i
      join public.fin_allocations a on a.open_item_id = i.id
      join public.fin_settlements s on s.id = a.settlement_id
       and s.status = 'posted' and s.direction = 'in'
     where i.tenant_id = v_tenant
       and i.source_type = 'ins_policy_premium'
       and i.source_id = p.id;

    v_due := public.ins_remittance_due_date(v_tenant, v_receipt);

    v_status := case
      when v_receipt is null then 'receipt_date_missing'
      when v_due is null then 'deadline_not_set'
      when v_due < p_as_of then 'overdue'
      when v_due = p_as_of then 'due_today'
      else 'within_deadline'
    end;

    policy_id := p.id;
    policy_no := p.policy_no;
    insurer_id := p.insurer_id;
    unremitted_amount := v_avail;
    receipt_date := v_receipt;
    deadline_date := v_due;
    status := v_status;
    return next;
  end loop;
end;
$function$;


-- Shared finance functions on the receipt and credit-note path (the insurance flows above call them; a receipt
-- posted on the Kampala date must be voidable on the same Kampala date). These are shared with other modules.

CREATE OR REPLACE FUNCTION public.ins_price_charges(p_tenant_id uuid, p_gross_premium numeric, p_net_premium numeric, p_commission_amount numeric, p_product_line_code text DEFAULT NULL::text, p_currency text DEFAULT 'UGX'::text, p_on date DEFAULT public.ins_local_today())
 RETURNS TABLE(catalogue_id uuid, code text, name text, charge_class text, basis text, amount numeric, collector text, recipient_name text, recipient_kind text, payable_role text, payable_account_id uuid, catalogue_version integer, snapshot jsonb, warnings text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select * from public.ins_price_charges_for(
    p_tenant_id,
    jsonb_strip_nulls(jsonb_build_object(
      'gross_premium', p_gross_premium,
      'net_premium', p_net_premium,
      'commission', p_commission_amount,
      'policy_count', 1)),
    p_product_line_code, p_currency, p_on)
$function$;


alter table public.ins_claims alter column notified_date set default public.ins_local_today();
alter table public.ins_insurer_statements alter column received_date set default public.ins_local_today();
alter table public.ins_policy_reversals alter column reversal_date set default public.ins_local_today();
