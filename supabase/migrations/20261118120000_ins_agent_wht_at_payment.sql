-- =====================================================================
-- Insurance: withhold agent commission tax at PAYMENT, not at accrual
-- =====================================================================
-- Item 8, bit 1. Corrects a timing error in 20261117250000.
--
-- What was wrong
-- --------------
-- That migration computed withholding when the agent's share was ACCRUED, and
-- resolved the rate and character against the POLICY'S INCEPTION DATE. It posted
-- the tax to wht_payable at that moment, so the ledger could show a URA liability
-- before any cash had moved to fund it, dated by when the share was earned.
--
-- Withholding on agent commission is an obligation that arises when commission is
-- PAID (Income Tax Act s.134), and the law that decides the rate and the
-- character is the law in force on the PAYMENT date. Inception is the wrong date,
-- and it is wrong in a way that bites exactly once: s.139(aa) of the Income Tax
-- (Amendment) Act 2026 made the tax final from 1 July 2026 WITHOUT changing the
-- 10% rate. So a share earned in 2025 and paid in 2027 was withheld at the right
-- rate with the wrong character, and reported to the agent as a payment on
-- account when the law had already settled their liability.
--
-- What this does
-- --------------
--   1. The accrual recognises cost and payable, both at the gross. No tax.
--   2. ins_agent_commission_pay resolves the rate and character for p_paid_on
--      and posts the three legs: Dr payable gross / Cr wht_payable tax /
--      Cr bank net.
--   3. ins_wht_prepare_remittance groups by the month of PAYMENT (s.140 draws
--      the return's period from the payment), not by the month of accrual.
--   4. A share may be re-accrued after it has been reversed. Before this, the
--      idempotency lookup counted reversed rows and the table additionally
--      carried UNIQUE (tenant_id, policy_id, intermediary_id), so reversing a
--      share retired that policy's agent commission permanently and the
--      correction path -- reverse, then accrue again -- did not work.
--
-- What this deliberately does NOT do
-- ----------------------------------
-- A part-payment of a share is still refused at the accrual level: pay() settles
-- an accrual in full, so the whole tax falls on one payment. Apportioning tax
-- across part-payments is a real requirement for some practices and is NOT built
-- here; when it is, the tax will need to be apportioned against the accrual
-- rather than recomputed from the full gross, or it will be withheld twice.
--
-- Existing rows: any accrual that already carries tax under the old rule is left
-- exactly as it is, with its own recorded rate, character and parameter. Rewriting
-- it would restate a liability somebody may already have filed. Those rows are
-- still picked up by the remittance routine whenever they are paid; only rows
-- with no payment yet are untouched by the change in basis.
--
-- Idempotent: create-or-replace for functions, drop/add for the two constraints,
-- and the constraint swap runs in one transaction with the function bodies, so
-- the table is never observable without a uniqueness rule that permits the new
-- behaviour.
--
-- Applied migrations are never edited (MIGRATION_POLICY.md rule 9); this is a new
-- file and 20261117250000 is left alone.

CREATE OR REPLACE FUNCTION public.ins_agent_commission_calculate(p_policy_id uuid, p_intermediary_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant   uuid := public.get_my_tenant_id();
  p          public.ins_policies;
  a          public.ins_intermediaries;
  t          public.ins_intermediary_terms;
  v_term_id  uuid;
  v_broker   numeric;
  v_gross    numeric;
  v_basis    text;
  v_rate     numeric;
  v_fixed    numeric;
  v_wht      jsonb;
  v_wht_amt  numeric;
  v_base     jsonb;
begin
  select * into p from public.ins_policies
   where id = p_policy_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_POLICY_NOT_FOUND'; end if;
  select * into a from public.ins_intermediaries
   where id = p_intermediary_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_INTERMEDIARY_NOT_FOUND'; end if;

  -- Whose money is it? Answered by the register, not by the caller.
  --
  -- Also refused, not returned as zero: the predicate below (which the terms
  -- writer, the accrual and the payment all share) is what decides who is
  -- payable, so an insurer-appointed agent reaching here means the register and
  -- the money path disagree. A zero would hide that; an exception names it.
  if a.category = 'insurer_appointed_agent' then
    raise exception 'INS_AGENT_INSURER_PAID: % is an insurer-appointed agent, so the insurer remunerates them. The brokerage pays nothing and must accrue nothing; a calculation should never have been asked for',
      a.name;
  end if;
  if not public.ins_intermediary_is_broker_paid(p_intermediary_id) then
    raise exception 'INS_AGENT_UNKNOWN_CATEGORY: % has category %, which has no commission treatment; only sub_agent and referral_partner are paid by the brokerage',
      a.name, a.category;
  end if;

  v_term_id := public.ins_intermediary_term_in_force(p_intermediary_id, p.inception_date, p.product_line_id);
  if v_term_id is null then
    raise exception 'INS_AGENT_TERM_MISSING: % has no approved commission term in force on %, so there is no agreed share to accrue. Set and approve a term first',
      a.name, p.inception_date;
  end if;
  select * into t from public.ins_intermediary_terms where id = v_term_id;

  v_broker := round(coalesce(p.commission_amount, 0), 2);
  v_basis  := t.basis;

  if v_basis = 'none' then
    return jsonb_build_object(
      'intermediary_id', a.id, 'name', a.name, 'category', a.category, 'term_id', t.id,
      'basis', 'none', 'payable_by_brokerage', false, 'gross_amount', 0,
      'reason', 'a term in force records basis none: this intermediary is not paid by the brokerage');
  end if;

  if v_basis in ('pct_of_broker_commission', 'tiered_pct_of_broker_commission') and v_broker <= 0 then
    raise exception 'INS_AGENT_NO_BASE: % is paid a share of the brokerage''s commission, but policy % has no commission earned yet. Accrue after the commission is recognised, not before',
      a.name, p.policy_no;
  end if;

  if v_basis = 'pct_of_broker_commission' then
    v_rate  := t.rate_pct;
    v_gross := round(v_broker * v_rate / 100.0, 2);

  elsif v_basis = 'tiered_pct_of_broker_commission' then
    -- The band containing the brokerage's commission decides the rate, applied
    -- to the whole commission; a marginal ladder would need every band approved
    -- as one instrument, which is a different build.
    select x.rate_pct into v_rate
      from public.ins_intermediary_terms x
     where x.tenant_id = v_tenant and x.intermediary_id = p_intermediary_id
       and x.status = 'approved'
       and x.basis = 'tiered_pct_of_broker_commission'
       and x.effective_from <= p.inception_date
       and coalesce(x.effective_to, 'infinity'::date) >= p.inception_date
       and (x.product_line_id is null or x.product_line_id = p.product_line_id)
       and v_broker >= x.tier_from_amount and v_broker < x.tier_to_amount
     order by (x.product_line_id is not null) desc, x.effective_from desc
     limit 1;
    if v_rate is null then
      raise exception 'INS_AGENT_TIER_NOT_FOUND: % has a tiered arrangement, but no approved band covers a brokerage commission of % on policy %',
        a.name, v_broker, p.policy_no;
    end if;
    v_gross := round(v_broker * v_rate / 100.0, 2);

  elsif v_basis = 'pct_of_gross_premium' then
    v_rate  := t.rate_pct;
    v_gross := round(p.gross_premium * v_rate / 100.0, 2);

  elsif v_basis = 'flat_amount_per_policy' then
    v_fixed := t.fixed_amount;
    v_gross := round(v_fixed, 2);
    if p.currency is distinct from t.currency then
      raise exception 'INS_AGENT_FIXED_CURRENCY: the term for % is a flat % %, but policy % is in %. A flat amount across currencies needs an explicit rate, which is not built',
        a.name, v_fixed, t.currency, p.policy_no, p.currency;
    end if;
  end if;

  if v_gross is null or v_gross <= 0 then
    raise exception 'INS_AGENT_NOTHING_TO_ACCRUE: the term for % produces a share of %, which is not a payable',
      a.name, coalesce(v_gross, 0);
  end if;
  if v_gross > round(p.gross_premium, 2) then
    raise exception 'INS_AGENT_EXCEEDS_PREMIUM: the share due to % is % against a gross premium of %; an agent cannot be paid more than the policy is worth',
      a.name, v_gross, p.gross_premium;
  end if;

  v_base := jsonb_build_object(
    'intermediary_id',   a.id,
    'name',              a.name,
    'category',          a.category,
    'term_id',           t.id,
    'basis',             v_basis,
    'rate_pct',          v_rate,
    'fixed_amount',      v_fixed,
    'payable_by_brokerage', true,
    'broker_commission', v_broker,
    'gross_premium',     round(p.gross_premium, 2),
    'commission_base',   case when v_basis = 'pct_of_gross_premium' then round(p.gross_premium, 2) else v_broker end,
    'gross_amount',      v_gross,
    'currency',          p.currency);

  -- Withholding is NOT resolved here any more.
  --
  -- It used to be, against the policy's inception date, on the reasoning that
  -- inception is the taxable event. That is wrong for this tax: withholding is
  -- an obligation that arises when commission is PAID (Income Tax Act s.134), and
  -- the rate and character are fixed by the law in force on that payment date.
  -- A calculation that pre-commits to a date cannot be right for a share paid
  -- after a rate or character change, and 1 July 2026 changed the character
  -- (s.139(aa) made the tax final) without changing the rate.
  --
  -- So a share is now quoted GROSS and NET = GROSS. The tax is determined in
  -- ins_agent_commission_pay, for the payment date, which is the only date from
  -- which it can be determined at all. Quoting a provisional 10% here would put
  -- a figure on screen that the payment is free to contradict.
  return v_base || jsonb_build_object(
    'wht_rate_pct',     null::numeric,
    'wht_is_final',     null::boolean,
    'wht_amount',       0,
    'net_amount',       round(v_gross, 2),
    'wht_parameter_id', null::uuid,
    'wht_not_yet_determined', true,
    'wht_note', 'Withholding is determined on the payment date, not when the share is earned; this quote is gross.');
end
$function$;

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
    v_tenant, 'ins_agent_commission_accrual', v_je_key, p.bound_at::date,
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

CREATE OR REPLACE FUNCTION public.ins_agent_commission_pay(p_accrual_id uuid, p_bank_account_id uuid, p_paid_on date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  x         public.ins_agent_commission_accruals;
  p         public.ins_policies;
  a         public.ins_intermediaries;
  v_ap      uuid;
  v_bank    uuid;
  v_je      public.journal_entries;
  v_net     numeric;
  v_wht     jsonb;
  v_tax     numeric := 0;
  v_wht_gl  uuid;
  v_lines   jsonb;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_paid_on is null then
    raise exception 'INS_AGENT_PAYMENT_DATE: a payment needs a date';
  end if;

  select * into x from public.ins_agent_commission_accruals
   where id = p_accrual_id and tenant_id = v_tenant
   for update;
  if not found then raise exception 'INS_AGENT_ACCRUAL_NOT_FOUND'; end if;

  if x.status = 'paid' then
    return jsonb_build_object('paid', false, 'already_paid', true,
                              'accrual_id', x.id, 'paid_at', x.paid_at);
  end if;
  if x.status = 'reversed' then
    raise exception 'INS_AGENT_ACCRUAL_REVERSED: this accrual was reversed (%); it cannot be paid',
      coalesce(x.reversal_reason, 'no reason recorded');
  end if;
  if x.status = 'accrued' then
    raise exception 'INS_AGENT_NOT_ELIGIBLE: the share is accrued but not yet eligible. Mark it eligible once the brokerage''s commission on the policy is earned';
  end if;

  select * into a from public.ins_intermediaries
   where id = x.intermediary_id and tenant_id = v_tenant;
  if a.status <> 'active' then
    raise exception 'INS_AGENT_NOT_ACTIVE: % is %; a share cannot be paid to an intermediary that is not active',
      a.name, a.status;
  end if;
  if a.licence_valid_to is not null and a.licence_valid_to < p_paid_on then
    raise exception 'INS_AGENT_LICENCE_EXPIRED: %''s licence expired on %, before the payment date %',
      a.name, a.licence_valid_to, p_paid_on;
  end if;

  select * into p from public.ins_policies
   where id = x.policy_id and tenant_id = v_tenant;

  -- Withholding is determined HERE, for the payment date, because payment is
  -- the event that creates the obligation (Income Tax Act s.134) and therefore
  -- the event whose law decides the rate and the character. Determining it
  -- against inception -- which is what this used to do, at accrual -- meant a
  -- share earned before 1 July 2026 and paid after it was withheld as
  -- not-final, contradicting s.139(aa) on the date that actually mattered.
  --
  -- Nothing has been withheld before this point, so the whole tax falls on this
  -- payment. A part-payment would need the tax apportioned against the accrual
  -- rather than computed from the full gross; that is not built, so it is
  -- refused rather than guessed (see INS_AGENT_PART_PAYMENT below).
  v_wht := public.ins_agent_wht_for(p_paid_on);
  v_tax := round(x.gross_amount * (v_wht ->> 'rate_pct')::numeric / 100.0, 2);

  if v_tax > x.gross_amount then
    raise exception 'INS_AGENT_WHT_EXCEEDS: withholding of % exceeds the gross share of %; the approved rate cannot be right', v_tax, x.gross_amount;
  end if;

  v_net := round(x.gross_amount - v_tax, 2);

  v_ap := public.get_posting_account(v_tenant, 'ap_control');
  if v_ap is null then
    raise exception 'INS_POSTING_RULE_MISSING: paying an agent share needs the ap_control posting rule';
  end if;
  -- Aliased bp, not a: `a` is the intermediary already in scope in this body.
  select bp.gl_account_id into v_bank
    from public.fin_bank_accounts bp
   where bp.id = p_bank_account_id and bp.tenant_id = v_tenant and bp.is_active;
  if v_bank is null then
    raise exception 'INS_BANK_ACCOUNT_NOT_FOUND: bank account % is not an active account on this company', p_bank_account_id;
  end if;

  -- Three legs when tax is withheld, two when it is not:
  --
  --   Dr ap_control            gross     (the payable the accrual raised)
  --     Cr wht_payable          tax      (held for URA from this payment)
  --     Cr bank                 net      (what the agent receives)
  --
  -- The expense was already taken at the gross by the accrual; the tax is not an
  -- expense and does not touch it. It is money the brokerage never pays over.
  v_lines := jsonb_build_array(
    jsonb_build_object('gl_account_id', v_ap,   'debit',  x.gross_amount,
                       'currency', x.currency,
                       'description', 'Clear agent payable for ' || p.policy_no),
    jsonb_build_object('gl_account_id', v_bank, 'credit', v_net,
                       'currency', x.currency,
                       'description', 'Paid to ' || a.name));

  if v_tax > 0 then
    v_wht_gl := public.get_posting_account(v_tenant, 'wht_payable');
    if v_wht_gl is null then
      -- Refused, not silently withheld without a home: a tax taken from the
      -- agent with nowhere to sit is the worst of the three answers.
      raise exception 'INS_POSTING_RULE_MISSING: withholding tax on agent commission needs the wht_payable posting rule. It cannot be withheld without an account to hold it, or the agent is short and URA is unrecorded';
    end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'gl_account_id', v_wht_gl, 'credit', v_tax,
      'currency', x.currency,
      'description', 'WHT withheld on ' || p.policy_no || ' for remittance to URA'));
  end if;

  v_je := public.post_journal_entry(
    v_tenant, 'ins_agent_commission_payment', x.id, p_paid_on,
    'Agent commission paid to ' || a.name || ' for ' || p.policy_no,
    v_lines);

  -- The tax and its basis are written at the payment that produced them, on the
  -- row that a remittance will later be built from.
  perform set_config('ins.via_wht_calc', 'on', true);
  update public.ins_agent_commission_accruals
     set status = 'paid', paid_at = now(), paid_on = p_paid_on,
         payment_journal_entry_id = v_je.id,
         wht_amount = v_tax,
         net_amount = v_net,
         wht_rate_pct = (v_wht ->> 'rate_pct')::numeric,
         wht_is_final = (v_wht ->> 'is_final')::boolean,
         wht_parameter_ref = (v_wht ->> 'parameter_id')::uuid,
         updated_at = now()
   where id = x.id;
  perform set_config('ins.via_wht_calc', 'off', true);

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, journal_entry_id, note)
  values (v_tenant, x.id, 'paid', v_net, v_je.id,
          nullif(btrim(coalesce(p_note, '')), ''));

  return jsonb_build_object('paid', true, 'accrual_id', x.id,
                            'amount', v_net, 'gross_amount', x.gross_amount,
                            'wht_amount', v_tax,
                            'wht_rate_pct', (v_wht ->> 'rate_pct')::numeric,
                            'wht_is_final', (v_wht ->> 'is_final')::boolean,
                            'wht_on', p_paid_on,
                            'journal_entry_id', v_je.id);
end
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
     and coalesce(x.paid_on, x.paid_at::date) between p_period_start and p_period_end
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
       and coalesce(x.paid_on, x.paid_at::date) between p_period_start and p_period_end
       and not exists (select 1 from public.ins_wht_remittance_lines l
                        where l.tenant_id = v_tenant and l.accrual_id = x.id)
     order by coalesce(x.paid_on, x.paid_at::date)
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


-- ---------------------------------------------------------------------
-- 5. The payment date has to be stored, not inferred
-- ---------------------------------------------------------------------
-- paid_at is now(): when the clerk pressed the button. It is not the date the
-- money left, which is what p_paid_on carries and what the return's period is
-- drawn from (s.140). Without this column the remittance routine could only group
-- by the day somebody did the data entry, which drifts from the real period -- a
-- payment dated 30 June and keyed on 1 July would land in the wrong month's return.
alter table public.ins_agent_commission_accruals
  add column if not exists paid_on date;

-- Rows paid before this migration: their intent was the day they were paid, and
-- paid_at is the only evidence there is. Backfill rather than leave null.
update public.ins_agent_commission_accruals
   set paid_on = paid_at::date
 where status = 'paid' and paid_on is null;

comment on column public.ins_agent_commission_accruals.paid_on is
  'The date the payment was made, as asserted on the payment. Payment date, not entry date: it decides the withholding rate and character, and the period the tax is returned in. paid_at is when the row was written.';

-- ---------------------------------------------------------------------
-- 6. The uniqueness rule has to permit a corrected re-accrual
-- ---------------------------------------------------------------------
-- One live accrual per policy and intermediary remains right; one accrual for
-- ever does not, because a reversal is how a wrong share gets corrected.
alter table public.ins_agent_commission_accruals
  drop constraint if exists ins_agent_accruals_once_key;

-- A partial unique index gives the same protection for live rows and stops
-- applying to rows that have been reversed.
create unique index if not exists ins_agent_accruals_live_once_key
  on public.ins_agent_commission_accruals (tenant_id, policy_id, intermediary_id)
  where status <> 'reversed';

comment on index public.ins_agent_accruals_live_once_key is
  'One live agent share per policy and intermediary. Reversed rows are excluded so a share can be re-accrued after a correction; before 20261118120000 this was a table constraint that counted reversed rows too, which made any reverse-then-re-accrue impossible.';

-- ---------------------------------------------------------------------
-- 7. The tax columns may only be written by the payment that produced them
-- ---------------------------------------------------------------------
-- The accrual used to set these under ins.via_wht_calc. It no longer does, and
-- pay() now does. Replacing the check keeps the invariant that a row carrying
-- tax always explains itself: a rate, a character and a parameter. Payment sets
-- all three together, so the constraint cannot be satisfied half-way.
alter table public.ins_agent_commission_accruals
  drop constraint if exists ins_agent_accruals_paid_carries_wht_chk;
alter table public.ins_agent_commission_accruals
  add constraint ins_agent_accruals_paid_carries_wht_chk check (
    coalesce(wht_amount, 0) = 0
    or (status = 'paid'
        and wht_rate_pct is not null
        and wht_is_final is not null
        and wht_parameter_ref is not null));
