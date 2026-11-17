-- =====================================================================
-- Insurance: withholding tax on agent commission (item 6b)
-- =====================================================================
--
-- What this finishes
-- ------------------
-- 20261117240000 built the agent commission subledger and deliberately left
-- withholding out, refusing it by name (INS_AGENT_WHT_NOT_BUILT) because the
-- brokerage's obligation was an open question. The accountant has now answered:
--
--   * Income Tax Act s.134 withholds 10% of GROSS commission paid to an
--     insurance agent.
--   * From 1 July 2026 the withheld tax is a FINAL tax (s.139(aa), inserted by
--     the Income Tax (Amendment) Act 2026, which commenced 1 July 2026 and was
--     assented on 20 August 2026).
--
-- On the accountant's own example: gross 300,000, WHT 30,000, net to the agent
-- 270,000, and 30,000 owed to URA. Those exact figures are asserted below.
--
-- One detail that matters and is easy to get wrong
-- ------------------------------------------------
-- The RATE did not change on 1 July 2026 -- it was 10% before and after. What
-- changed is the CHARACTER: before that date the tax was not final, so the
-- agent's other income and a possible annual return could affect the final
-- position; from that date the withholding settles the liability outright.
--
-- So the repo now holds TWO parameter keys, not one edited value:
--
--   tax.wht_agent_commission_percent      the rate, effective-dated
--                                         (seeded 10% from 1 July 2020)
--   tax.wht_agent_commission_is_final     'true' or 'false', effective-dated
--                                         (seeded 'false' from 2020, with the
--                                          'true' row starting 1 July 2026)
--
-- Editing one row's rate would have lost the distinction entirely, and splitting
-- a rate row across a boundary it does not have would have implied a rate change
-- that never happened. Two keys, each with its own window, is what the law
-- actually looks like.
--
-- Why "final" is recorded rather than assumed
-- -------------------------------------------
-- The difference is not cosmetic. A final withholding tax needs no further
-- return from the agent and cannot be recovered by them, so the brokerage's bill
-- to URA is a settlement. A non-final withholding leaves the agent to declare
-- the income and settle the balance, and the same 30,000 is only a payment on
-- account. Reporting them the same way would misstate the agent's position to
-- the agent.
--
-- Refusing rather than guessing
-- -----------------------------
-- Withholding is computed from approved parameters only. If the rate or the
-- character is not approved for the payment date, the accrual is refused by name
-- rather than falling back to 0% or to a default. A missing rate that silently
-- becomes zero would under-withhold, and an under-withholding error is one the
-- brokerage pays for later, with interest.
--
-- Idempotent: add-columns are `if not exists`, functions are create-or-replace,
-- definition rows use on-conflict-do-nothing, and the seed rows are only added
-- when absent.

-- ---------------------------------------------------------------------
-- 1. Two parameter keys, because rate and character are two facts
-- ---------------------------------------------------------------------
insert into public.regulatory_parameter_definitions (key, category, description, value_type, class_scoped)
values
  ('tax.wht_agent_commission_percent', 'tax',
   'Withholding tax rate on commission paid to an agent, as a percentage of the GROSS commission (Income Tax Act s.134).',
   'percent', false),
  ('tax.wht_agent_commission_is_final', 'tax',
   'Whether the withholding tax on agent commission is a FINAL tax on the payment date. It became final on 1 July 2026 (s.139(aa), Income Tax (Amendment) Act 2026); before that it was not final.',
   'text', false)
on conflict (key) do nothing;

-- The character key predates nothing here, so there is no edit to make: both the
-- "not final" window and the "final" window are seeded in the harness seed file
-- alongside the rate, for the same reason every other regulatory value is -- a
-- value nobody approved must not post.

-- ---------------------------------------------------------------------
-- 2. The accrual carries the tax and the character it was computed under
-- ---------------------------------------------------------------------
alter table public.ins_agent_commission_accruals
  add column if not exists wht_rate_pct      numeric(7,4),
  add column if not exists wht_is_final      boolean,
  add column if not exists wht_parameter_ref uuid,
  add column if not exists net_amount        numeric(14,2);

comment on column public.ins_agent_commission_accruals.wht_rate_pct is
  'The rate applied, copied from the approved parameter in force on the accrual date. Copied, not joined: a later rate change must not rewrite what was withheld last year.';
comment on column public.ins_agent_commission_accruals.wht_is_final is
  'Whether the tax was final on this accrual''s date. The rate did not change on 1 July 2026; this did. Copied for the same reason as the rate.';
comment on column public.ins_agent_commission_accruals.net_amount is
  'gross_amount less wht_amount: what the intermediary is actually paid. Stored rather than derived so a payment cannot disagree with the accrual.';

-- The identity that must hold for every row, enforced by the database rather
-- than trusted: gross = withheld + net.
alter table public.ins_agent_commission_accruals
  drop constraint if exists ins_agent_accruals_net_identity_chk;
alter table public.ins_agent_commission_accruals
  add constraint ins_agent_accruals_net_identity_chk
  check (net_amount is null or net_amount = gross_amount - wht_amount);

-- A row with withholding must say what rate produced it, and whether it was
-- final. Otherwise the tax is an unexplained number.
alter table public.ins_agent_commission_accruals
  drop constraint if exists ins_agent_accruals_wht_explained_chk;
alter table public.ins_agent_commission_accruals
  add constraint ins_agent_accruals_wht_explained_chk
  check (coalesce(wht_amount, 0) = 0
         or (wht_rate_pct is not null and wht_is_final is not null));

-- Backfill only what is unambiguous: every existing accrual withheld nothing
-- (it could not, the guard refused it), so its net is its gross. Leaving the
-- rate and character null on those rows is honest -- nothing was withheld, so
-- there is no rate to explain.
update public.ins_agent_commission_accruals
   set net_amount = gross_amount
 where net_amount is null;

-- ---------------------------------------------------------------------
-- 3. The guard becomes an invariant instead of a wall
-- ---------------------------------------------------------------------
-- It used to refuse any non-zero withholding because the tax was not built.
-- Now the tax is built and computed, so the guard's job changes: it stops a
-- caller from writing a withholding figure that the calculation did not
-- produce. The accrual sets ins.via_wht_calc inside its own transaction.
create or replace function public.ins_agent_commission_wht_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_via boolean := coalesce(current_setting('ins.via_wht_calc', true), '') = 'on';
begin
  -- Police the FIGURE, not the row. An earlier draft of this guard refused any
  -- write to a row carrying withholding, which broke marking it eligible and
  -- paying it -- ordinary lifecycle steps that have nothing to do with the tax.
  -- What must be refused is a withholding amount that the calculation did not
  -- produce, so only a change to the amount is checked.
  if tg_op = 'INSERT' then
    if coalesce(new.wht_amount, 0) <> 0 and not v_via then
      raise exception 'INS_AGENT_WHT_RPC_ONLY: withholding is computed from the approved regulatory parameters by ins_agent_commission_accrue. It cannot be written by hand, because a hand-written figure is one nobody can tie back to a rate and a date'
        using errcode = '42501';
    end if;
  else
    if (new.wht_amount is distinct from old.wht_amount
        or new.net_amount is distinct from old.net_amount
        or new.wht_rate_pct is distinct from old.wht_rate_pct
        or new.wht_is_final is distinct from old.wht_is_final) and not v_via then
      raise exception 'INS_AGENT_WHT_RPC_ONLY: withholding and its net cannot be edited after the fact. They are computed from the approved rate and character on the accrual date; a later change of rate must not rewrite what was withheld last year'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$function$;

revoke all on function public.ins_agent_commission_wht_guard() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. The bill to URA: one remittance per tenant, period and currency
-- ---------------------------------------------------------------------
-- Withheld tax is not the brokerage's money and it is not the agent's: it is
-- URA's from the moment it is withheld. Until it is paid over it is a liability
-- with a deadline, so it gets its own subledger rather than being left inside
-- the ap_control balance where nobody can age it.
create table if not exists public.ins_wht_remittances (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete cascade,
  remittance_no     text not null,
  -- The period the tax relates to, not the date it is paid. A July return may
  -- be filed and paid in August.
  period_start      date not null,
  period_end        date not null,
  currency          text not null,
  amount            numeric(14,2) not null,
  status            text not null default 'prepared',
  paid_on           date,
  payment_reference text,
  journal_entry_id  uuid,
  prepared_by       uuid default auth.uid(),
  approved_by       uuid,
  approved_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint ins_wht_remittances_status_check check (
    status = any (array['prepared', 'approved', 'paid', 'void'])),
  constraint ins_wht_remittances_amount_check check (amount > 0),
  constraint ins_wht_remittances_period_check check (period_end >= period_start),
  constraint ins_wht_remittances_paid_check check ((status = 'paid') = (paid_on is not null)),
  constraint ins_wht_remittances_approved_check check (
    status in ('prepared', 'void') or (approved_by is not null and approved_at is not null)),
  constraint ins_wht_remittances_tenant_id_key unique (tenant_id, id),
  constraint ins_wht_remittances_no_key unique (tenant_id, remittance_no)
);

create index if not exists ins_wht_remittances_period_idx
  on public.ins_wht_remittances (tenant_id, period_start desc);

comment on table public.ins_wht_remittances is
  'A period return of withheld agent commission tax to URA. Prepared from the accruals, approved by a second person, then paid; the amount is fixed when it is prepared so an approval cannot silently cover a different figure.';
comment on column public.ins_wht_remittances.period_start is
  'The period the tax was withheld in, not the month it is paid. A July liability paid in August belongs to July.';

-- Which accruals a remittance includes. A link table, so a return can be
-- re-derived and audited line by line, and so no accrual is taxed twice.
create table if not exists public.ins_wht_remittance_lines (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  remittance_id  uuid not null,
  accrual_id     uuid not null,
  amount         numeric(14,2) not null,
  created_at     timestamptz not null default now(),
  constraint ins_wht_remittance_lines_amount_check check (amount > 0),
  constraint ins_wht_remittance_lines_once_key unique (tenant_id, accrual_id),
  constraint ins_wht_remittance_lines_fk foreign key (tenant_id, remittance_id)
    references public.ins_wht_remittances (tenant_id, id) on delete cascade,
  constraint ins_wht_remittance_lines_accrual_fk foreign key (tenant_id, accrual_id)
    references public.ins_agent_commission_accruals (tenant_id, id) on delete restrict
);

create index if not exists ins_wht_remittance_lines_remit_idx
  on public.ins_wht_remittance_lines (tenant_id, remittance_id);

alter table public.ins_wht_remittances enable row level security;
alter table public.ins_wht_remittance_lines enable row level security;

drop policy if exists ins_wht_remittances_select on public.ins_wht_remittances;
create policy ins_wht_remittances_select on public.ins_wht_remittances
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

drop policy if exists ins_wht_remittance_lines_select on public.ins_wht_remittance_lines;
create policy ins_wht_remittance_lines_select on public.ins_wht_remittance_lines
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

revoke all on table public.ins_wht_remittances from public, anon;
revoke all on table public.ins_wht_remittance_lines from public, anon;
revoke insert, update, delete on table public.ins_wht_remittances from authenticated;
revoke insert, update, delete on table public.ins_wht_remittance_lines from authenticated;

-- ---------------------------------------------------------------------
-- 5. Resolving the tax for a date, from approved parameters only
-- ---------------------------------------------------------------------
-- One function answers "what tax applies to a payment on this date", and it
-- refuses when the answer is not on file. Both the calculation and the accrual
-- use it, so the preview a user sees and the figure that posts cannot differ.
create or replace function public.ins_agent_wht_for(p_on date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  v_rate    numeric;
  v_final   text;
  v_ref     uuid;
begin
  select r.value_num, r.id into v_rate, v_ref
    from public.regulatory_parameters r
   where r.tenant_id = v_tenant
     and r.parameter_key = 'tax.wht_agent_commission_percent'
     and r.status = 'approved'
     and r.effective_from <= p_on
     and coalesce(r.effective_to, 'infinity'::date) >= p_on
   order by r.effective_from desc
   limit 1;

  if v_rate is null then
    raise exception 'INS_AGENT_WHT_RATE_MISSING: no approved withholding rate for agent commission covers %. Withholding cannot be assumed to be zero: an under-withholding error is one the brokerage pays for later, with interest. Approve tax.wht_agent_commission_percent for this date',
      p_on;
  end if;

  select r.value_text into v_final
    from public.regulatory_parameters r
   where r.tenant_id = v_tenant
     and r.parameter_key = 'tax.wht_agent_commission_is_final'
     and r.status = 'approved'
     and r.effective_from <= p_on
     and coalesce(r.effective_to, 'infinity'::date) >= p_on
   order by r.effective_from desc
   limit 1;

  if v_final is null then
    raise exception 'INS_AGENT_WHT_CHARACTER_MISSING: no approved value for tax.wht_agent_commission_is_final covers %. The rate alone does not say whether the tax settles the agent''s liability (final) or is only a payment on account, and the two must not be reported the same way',
      p_on;
  end if;

  return jsonb_build_object(
    'rate_pct', v_rate,
    'is_final', lower(btrim(v_final)) = 'true',
    'parameter_id', v_ref,
    'on', p_on);
end
$function$;

revoke all on function public.ins_agent_wht_for(date) from public, anon;
grant execute on function public.ins_agent_wht_for(date) to authenticated;

-- ---------------------------------------------------------------------
-- 6. The calculation shows the tax before anything is accrued
-- ---------------------------------------------------------------------
-- Re-implemented on the same rules as 20261117240000, with the withholding
-- resolved and reported. The share itself is unchanged; the new part is that the
-- preview states gross, withheld and net, so nobody signs off a number without
-- seeing what the agent actually receives.
create or replace function public.ins_agent_commission_calculate(
  p_policy_id       uuid,
  p_intermediary_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
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

  -- Withholding is resolved against the date the share is earned, which is the
  -- policy's inception date: that is the taxable event, not the day the clerk
  -- happens to press the button.
  v_wht := public.ins_agent_wht_for(p.inception_date);
  v_wht_amt := round(v_gross * (v_wht ->> 'rate_pct')::numeric / 100.0, 2);

  return v_base || jsonb_build_object(
    'wht_rate_pct',  (v_wht ->> 'rate_pct')::numeric,
    'wht_is_final',  (v_wht ->> 'is_final')::boolean,
    'wht_amount',    v_wht_amt,
    'net_amount',    round(v_gross - v_wht_amt, 2),
    'wht_parameter_id', (v_wht ->> 'parameter_id')::uuid);
end
$function$;

revoke all on function public.ins_agent_commission_calculate(uuid, uuid) from public, anon;
grant execute on function public.ins_agent_commission_calculate(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 7. The accrual posts the tax
-- ---------------------------------------------------------------------
-- Three legs instead of two, and the credit to the intermediary is the NET:
--
--   Dr agent commission expense      gross
--     Cr ap_control                   net      (what the agent is paid)
--     Cr wht_payable                  tax      (what URA is owed)
--
-- The expense is the gross because the gross is the cost of the business; the
-- tax is money the brokerage never had, only held.
create or replace function public.ins_agent_commission_accrue(
  p_policy_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
  v_tax     numeric;
  v_net     numeric;
  v_lines   jsonb;
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

  -- Idempotent: one accrual per policy and intermediary, ever.
  select * into v_row from public.ins_agent_commission_accruals
   where tenant_id = v_tenant and policy_id = p_policy_id and intermediary_id = p.agent_id;
  if found then
    return jsonb_build_object('accrued', false, 'already_accrued', true,
                              'accrual_id', v_row.id, 'gross_amount', v_row.gross_amount,
                              'status', v_row.status);
  end if;

  v_amt := (v_calc ->> 'gross_amount')::numeric;
  v_tax := coalesce((v_calc ->> 'wht_amount')::numeric, 0);
  v_net := round(v_amt - v_tax, 2);

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
                       'description', 'Net payable to agent for ' || p.policy_no));

  if v_tax > 0 then
    v_wht_gl := public.get_posting_account(v_tenant, 'wht_payable');
    if v_wht_gl is null then
      -- Refused, not silently withheld without a home: a tax taken from the
      -- agent with nowhere to sit is the worst of the three answers.
      raise exception 'INS_POSTING_RULE_MISSING: withholding tax on agent commission needs the wht_payable posting rule. It cannot be withheld without an account to hold it, or the agent is short and URA is unrecorded';
    end if;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'gl_account_id', v_wht_gl, 'credit', v_tax,
      'currency', p.currency,
      'description', 'WHT withheld on ' || p.policy_no || ' for remittance to URA'));
  end if;

  v_je := public.post_journal_entry(
    v_tenant, 'ins_agent_commission_accrual', p_policy_id, p.bound_at::date,
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
     v_tax, p.currency, 'accrued', v_je.id,
     (v_calc ->> 'wht_rate_pct')::numeric, (v_calc ->> 'wht_is_final')::boolean,
     (v_calc ->> 'wht_parameter_id')::uuid, v_net)
  returning * into v_row;
  perform set_config('ins.via_wht_calc', 'off', true);

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, journal_entry_id, note)
  values (v_tenant, v_row.id, 'accrued', v_amt, v_je.id,
          'share of the brokerage''s commission, basis ' || v_row.basis
          || case when v_tax > 0
                  then format('; %s withheld%s', v_tax,
                              case when v_row.wht_is_final then ' as a final tax' else ' on account' end)
                  else '' end);

  return jsonb_build_object('accrued', true, 'accrual_id', v_row.id,
                            'gross_amount', v_amt, 'wht_amount', v_tax,
                            'net_amount', v_net, 'status', 'accrued',
                            'journal_entry_id', v_je.id);
end
$function$;

revoke all on function public.ins_agent_commission_accrue(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. Payment pays the NET
-- ---------------------------------------------------------------------
-- A re-implementation of 20261117240000's payment with the amount changed from
-- gross to net and one extra refusal. Everything else -- eligibility, the active
-- check, the licence check, the void/paid handling -- is the same logic.
create or replace function public.ins_agent_commission_pay(
  p_accrual_id       uuid,
  p_bank_account_id  uuid,
  p_paid_on          date,
  p_note             text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant  uuid := public.get_my_tenant_id();
  x         public.ins_agent_commission_accruals;
  p         public.ins_policies;
  a         public.ins_intermediaries;
  v_ap      uuid;
  v_bank    uuid;
  v_je      public.journal_entries;
  v_net     numeric;
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

  v_net := coalesce(x.net_amount, x.gross_amount - x.wht_amount);

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

  v_je := public.post_journal_entry(
    v_tenant, 'ins_agent_commission_payment', x.id, p_paid_on,
    'Agent commission paid to ' || a.name || ' for ' || p.policy_no,
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_ap,   'debit',  v_net,
                         'currency', x.currency,
                         'description', 'Clear agent payable for ' || p.policy_no),
      jsonb_build_object('gl_account_id', v_bank, 'credit', v_net,
                         'currency', x.currency,
                         'description', 'Paid to ' || a.name)));

  update public.ins_agent_commission_accruals
     set status = 'paid', paid_at = now(), payment_journal_entry_id = v_je.id, updated_at = now()
   where id = x.id;

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, journal_entry_id, note)
  values (v_tenant, x.id, 'paid', v_net, v_je.id,
          nullif(btrim(coalesce(p_note, '')), ''));

  return jsonb_build_object('paid', true, 'accrual_id', x.id,
                            'amount', v_net, 'wht_amount', x.wht_amount,
                            'journal_entry_id', v_je.id);
end
$function$;

revoke all on function public.ins_agent_commission_pay(uuid, uuid, date, text) from public, anon;
grant execute on function public.ins_agent_commission_pay(uuid, uuid, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 9. The agent's statement: what they earned and what was held back
-- ---------------------------------------------------------------------
-- The point of recording the character is that the statement can say it. A
-- sub-agent reading this needs to know whether the 30,000 is gone for good or
-- will be trued up on their return.
create or replace function public.ins_agent_commission_statement(
  p_intermediary_id uuid,
  p_from            date default null,
  p_to              date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  a        public.ins_intermediaries;
  v_rows   jsonb;
  v_gross  numeric := 0;
  v_wht    numeric := 0;
  v_net    numeric := 0;
  v_paid   numeric := 0;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  select * into a from public.ins_intermediaries
   where id = p_intermediary_id and tenant_id = v_tenant;
  if not found then raise exception 'INS_INTERMEDIARY_NOT_FOUND'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'accrual_id', x.id,
           'policy_no', p.policy_no,
           'accrued_on', x.created_at::date,
           'basis', x.basis,
           'gross_amount', x.gross_amount,
           'wht_rate_pct', x.wht_rate_pct,
           'wht_amount', x.wht_amount,
           'wht_is_final', x.wht_is_final,
           'net_amount', x.net_amount,
           'status', x.status,
           'paid_at', x.paid_at) order by x.created_at), '[]'::jsonb)
    into v_rows
    from public.ins_agent_commission_accruals x
    join public.ins_policies p on p.id = x.policy_id
   where x.tenant_id = v_tenant and x.intermediary_id = p_intermediary_id
     and (p_from is null or x.created_at::date >= p_from)
     and (p_to   is null or x.created_at::date <= p_to);

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
     and (p_from is null or x.created_at::date >= p_from)
     and (p_to   is null or x.created_at::date <= p_to);

  return jsonb_build_object(
    'intermediary_id', a.id,
    'name', a.name,
    'category', a.category,
    'gross_commission', v_gross,
    'wht_withheld',     v_wht,
    'net_commission',   v_net,
    'paid',             v_paid,
    'outstanding',      round(v_net - v_paid, 2),
    'lines',            v_rows);
end
$function$;

revoke all on function public.ins_agent_commission_statement(uuid, date, date) from public, anon;
grant execute on function public.ins_agent_commission_statement(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------
-- 10. Preparing the return: whose tax is in it
-- ---------------------------------------------------------------------
-- The bill is built from the accruals, one line each, so it can be re-derived
-- and audited. An accrual already on an earlier return is never picked up
-- again -- that is enforced by ins_wht_remittance_lines' unique key, but the
-- selection excludes them too, so a second call returns a clean zero rather
-- than tripping a constraint.
create or replace function public.ins_wht_prepare_remittance(
  p_period_start date,
  p_period_end   date,
  p_currency     text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
     and x.created_at::date between p_period_start and p_period_end
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
       and x.created_at::date between p_period_start and p_period_end
       and not exists (select 1 from public.ins_wht_remittance_lines l
                        where l.tenant_id = v_tenant and l.accrual_id = x.id)
     order by x.created_at
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

revoke all on function public.ins_wht_prepare_remittance(date, date, text) from public, anon;
grant execute on function public.ins_wht_prepare_remittance(date, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 11. Approval, payment, void
-- ---------------------------------------------------------------------
create or replace function public.ins_wht_approve_remittance(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_uid    uuid := auth.uid();
  x        public.ins_wht_remittances;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  select * into x from public.ins_wht_remittances
   where id = p_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_WHT_REMITTANCE_NOT_FOUND'; end if;
  if x.status <> 'prepared' then
    raise exception 'INS_WHT_NOT_PREPARED: only a prepared return can be approved (this one is %)', x.status;
  end if;
  if x.prepared_by is not distinct from v_uid then
    raise exception 'INS_WHT_SELF_APPROVAL: the person who prepared a return cannot approve it; it is a payment to the revenue authority';
  end if;

  -- The stored total must still match its lines. If an accrual was reversed
  -- between preparing and approving, the bill is stale and must be rebuilt
  -- rather than approved at a figure nobody checked.
  if exists (
    select 1 from public.ins_wht_remittance_lines l
      join public.ins_agent_commission_accruals a on a.id = l.accrual_id
     where l.tenant_id = v_tenant and l.remittance_id = x.id
       and a.status = 'reversed'
  ) then
    raise exception 'INS_WHT_STALE: an accrual inside this return has since been reversed. Void this return and prepare a fresh one rather than approving a figure the lines no longer support';
  end if;

  update public.ins_wht_remittances
     set status = 'approved', approved_by = v_uid, approved_at = now(), updated_at = now()
   where id = x.id;

  return jsonb_build_object('approved', true, 'remittance_id', x.id, 'amount', x.amount);
end
$function$;

revoke all on function public.ins_wht_approve_remittance(uuid) from public, anon;
grant execute on function public.ins_wht_approve_remittance(uuid) to authenticated;

create or replace function public.ins_wht_pay_remittance(
  p_id               uuid,
  p_bank_account_id  uuid,
  p_paid_on          date,
  p_payment_reference text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  x        public.ins_wht_remittances;
  v_wht_gl uuid;
  v_bank   uuid;
  v_je     public.journal_entries;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_paid_on is null then
    raise exception 'INS_WHT_PAYMENT_DATE: paying a return needs a date';
  end if;
  if p_payment_reference is null or length(btrim(p_payment_reference)) < 3 then
    raise exception 'INS_WHT_PAYMENT_REF: paying a return needs the URA payment reference; it is what the next reconciliation is matched against';
  end if;

  select * into x from public.ins_wht_remittances
   where id = p_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_WHT_REMITTANCE_NOT_FOUND'; end if;
  if x.status = 'paid' then
    return jsonb_build_object('paid', false, 'already_paid', true,
                              'remittance_id', x.id, 'paid_on', x.paid_on);
  end if;
  if x.status <> 'approved' then
    raise exception 'INS_WHT_NOT_APPROVED: a return must be approved by a second person before it is paid (this one is %)', x.status;
  end if;

  v_wht_gl := public.get_posting_account(v_tenant, 'wht_payable');
  if v_wht_gl is null then
    raise exception 'INS_POSTING_RULE_MISSING: paying a withholding return needs the wht_payable posting rule';
  end if;
  select bp.gl_account_id into v_bank
    from public.fin_bank_accounts bp
   where bp.id = p_bank_account_id and bp.tenant_id = v_tenant and bp.is_active;
  if v_bank is null then
    raise exception 'INS_BANK_ACCOUNT_NOT_FOUND: bank account % is not an active account on this company', p_bank_account_id;
  end if;

  v_je := public.post_journal_entry(
    v_tenant, 'ins_wht_remittance', x.id, p_paid_on,
    'WHT paid to URA for ' || x.remittance_no || ' (' || btrim(p_payment_reference) || ')',
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_wht_gl, 'debit',  x.amount,
                         'currency', x.currency,
                         'description', 'Clear WHT payable for ' || x.remittance_no),
      jsonb_build_object('gl_account_id', v_bank,   'credit', x.amount,
                         'currency', x.currency,
                         'description', 'Paid to URA, ref ' || btrim(p_payment_reference))));

  update public.ins_wht_remittances
     set status = 'paid', paid_on = p_paid_on,
         payment_reference = btrim(p_payment_reference),
         journal_entry_id = v_je.id, updated_at = now()
   where id = x.id;

  return jsonb_build_object('paid', true, 'remittance_id', x.id,
                            'amount', x.amount, 'journal_entry_id', v_je.id);
end
$function$;

revoke all on function public.ins_wht_pay_remittance(uuid, uuid, date, text) from public, anon;
grant execute on function public.ins_wht_pay_remittance(uuid, uuid, date, text) to authenticated;

-- A voided return releases its lines, so the tax can be reported again. Nothing
-- is deleted: the return stands as a record that it was abandoned, and why.
create or replace function public.ins_wht_void_remittance(p_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  x        public.ins_wht_remittances;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'INS_WHT_VOID_REASON: voiding a return needs a reason of at least 10 characters';
  end if;
  select * into x from public.ins_wht_remittances
   where id = p_id and tenant_id = v_tenant for update;
  if not found then raise exception 'INS_WHT_REMITTANCE_NOT_FOUND'; end if;
  if x.status = 'paid' then
    raise exception 'INS_WHT_ALREADY_PAID: this return has been paid to URA. A refund or an adjustment is a conversation with the revenue authority, not a journal';
  end if;
  if x.status = 'void' then
    return jsonb_build_object('void', false, 'already_void', true, 'remittance_id', x.id);
  end if;

  -- Releasing the lines is what lets the same tax be reported on a fresh return.
  delete from public.ins_wht_remittance_lines
   where tenant_id = v_tenant and remittance_id = x.id;

  update public.ins_wht_remittances
     set status = 'void', updated_at = now()
   where id = x.id;

  return jsonb_build_object('void', true, 'remittance_id', x.id, 'reason', btrim(p_reason));
end
$function$;

revoke all on function public.ins_wht_void_remittance(uuid, text) from public, anon;
grant execute on function public.ins_wht_void_remittance(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 12. The position: what is still owed to URA, aged
-- ---------------------------------------------------------------------
create or replace function public.ins_wht_position()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_withheld numeric := 0;
  v_reported   numeric := 0;
  v_paid       numeric := 0;
  v_rows       jsonb;
begin
  if v_tenant is null or not public.can_access_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select coalesce(sum(x.wht_amount), 0) into v_withheld
    from public.ins_agent_commission_accruals x
   where x.tenant_id = v_tenant and x.wht_amount > 0 and x.status <> 'reversed';

  select coalesce(sum(r.amount), 0) into v_paid
    from public.ins_wht_remittances r
   where r.tenant_id = v_tenant and r.status = 'paid';

  select coalesce(sum(r.amount), 0) into v_reported
    from public.ins_wht_remittances r
   where r.tenant_id = v_tenant and r.status in ('prepared', 'approved', 'paid');

  select coalesce(jsonb_agg(jsonb_build_object(
           'remittance_no', r.remittance_no,
           'period_start', r.period_start,
           'period_end', r.period_end,
           'currency', r.currency,
           'amount', r.amount,
           'status', r.status,
           'paid_on', r.paid_on) order by r.period_start desc), '[]'::jsonb)
    into v_rows
    from public.ins_wht_remittances r
   where r.tenant_id = v_tenant and r.status <> 'void';

  return jsonb_build_object(
    'withheld_total',   v_withheld,
    'reported_total',   v_reported,
    'paid_total',       v_paid,
    -- The number the accountant actually wants: tax taken from agents that is
    -- not yet on a return at all, never mind paid.
    'unreported',       round(v_withheld - v_reported, 2),
    'awaiting_payment', round(v_reported - v_paid, 2),
    'remittances',      v_rows);
end
$function$;

revoke all on function public.ins_wht_position() from public, anon;
grant execute on function public.ins_wht_position() to authenticated;


-- ---------------------------------------------------------------------
-- 15. Reversal mirrors the whole entry, not just two of its legs
-- ---------------------------------------------------------------------
-- 20261117240000's reversal was right when the accrual had two legs: credit the
-- expense, debit ap_control, both for the gross. Once the accrual has three legs
-- that entry stops being a mirror image -- it debits ap_control for 300,000 when
-- only 270,000 was ever credited there, and it leaves the 30,000 of withheld tax
-- standing as a liability to URA for a commission the brokerage no longer earned.
--
-- The unwithheld version would have shown up as a wht_payable balance that never
-- clears: money owed to the revenue authority for a share that was cancelled.
create or replace function public.ins_agent_commission_reverse(
  p_accrual_id uuid,
  p_reason     text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
    v_tenant, 'ins_agent_commission_reversal', x.id, current_date,
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

revoke all on function public.ins_agent_commission_reverse(uuid, text) from public, anon;
grant execute on function public.ins_agent_commission_reverse(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 13. Journal source types
-- ---------------------------------------------------------------------
-- The full list is repeated verbatim, as in 20261117240000: this constraint has
-- no incremental form, and a partial list silently breaks every other module.
alter table public.journal_entries drop constraint if exists journal_entries_source_type_check;
alter table public.journal_entries
  add constraint journal_entries_source_type_check check (
    source_type = any (array[
      'supplier_invoice'::text, 'receivable_invoice'::text, 'cash_bank_transaction'::text,
      'opening_balance'::text, 'manual'::text, 'payroll_run'::text,
      'machine_fuel_log'::text, 'machine_maintenance_request'::text,
      'fin_settlement'::text, 'fin_settlement_void'::text,
      'fin_credit_note'::text, 'fin_credit_note_void'::text,
      'ins_policy_bind'::text, 'ins_commission_recognition'::text,
      'ins_commission_recognition_reversal'::text, 'ins_commission_transfer'::text,
      'ins_commission_transfer_void'::text, 'ins_claim_accrual'::text,
      'ins_policy_cancellation'::text, 'ins_cancellation_cash'::text,
      'fx_revaluation'::text, 'fx_revaluation_void'::text,
      'ins_policy_endorsement'::text, 'ins_import_opening'::text,
      'ins_agent_commission_accrual'::text,
      'ins_agent_commission_payment'::text,
      'ins_agent_commission_reversal'::text,
      -- Item 6b: paying the withheld tax over to URA
      'ins_wht_remittance'::text
    ]));

-- ---------------------------------------------------------------------
-- 14. Tenant read-only guard for the two new tables
-- ---------------------------------------------------------------------
select public.apply_tenant_read_only_guard();
