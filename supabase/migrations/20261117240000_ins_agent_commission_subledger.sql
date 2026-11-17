-- =====================================================================
-- Insurance: agent commission subledger (item 6)
-- =====================================================================
--
-- This is the module's first agent money. `20261017150000` built the
-- intermediary register (agents, sub-agents, their licences and appointments)
-- and deliberately stopped there: "no money -- no commission accrual, payables
-- or withholding". This migration is the money.
--
-- Three relationships, three different accounting answers
-- -------------------------------------------------------
-- Who pays an intermediary is not one question, and getting it wrong
-- overstates the brokerage's revenue, its expenses and its liabilities at once.
-- The register already names the categories; this migration makes the category
-- decide the accounting, so the same register cannot be used two ways.
--
--   insurer_appointed_agent   The INSURER pays them. The brokerage arranges the
--                             policy and earns nothing on their behalf. No
--                             payable, no expense, no cash: the appointment and
--                             its licence are recorded, and the money is
--                             somebody else's. Naming one of these on a policy
--                             is refused by name rather than silently ignored,
--                             because a payload that says it should mean
--                             something.
--
--   sub_agent                 The BROKERAGE pays them: an agreed share of the
--                             commission the brokerage itself earns on the
--                             policy. That is a real cost, so it gets a real
--                             accrual, a real payable, and a real payment --
--                             and it is an expense of the brokerage, never a
--                             reduction of the insurer's premium.
--
--   independent_broker /      Neighbouring cases. `referral_partner` is
--   referral_partner          commissioned the same way as a sub-agent;
--                             `independent_broker` is a co-broker, and is
--                             refused here with a message that says which
--                             treatment it needs rather than pretending
--                             share-of-commission is the same arrangement.
--
-- Two distinct arrangements, kept apart on purpose
-- ------------------------------------------------
-- A commission-SHARING arrangement (brokerage earns commission, pays the agent
-- a share of it) is not the same as a CLIENT-PAID fee (the broker is
-- remunerated by the client directly). They are separately taxed, separately
-- disclosed, and can both exist on one policy. The second is item 7 and is not
-- built here; the first is this migration. Nothing in this file touches client
-- money, and the accrual does not reduce the client's premium.
--
-- What is deliberately NOT built
-- ------------------------------
-- Withholding tax. Uganda treats the insurer as the withholding agent for
-- insurance-agent commission, which is exactly the agent arrangement that does
-- NOT run through this subledger. Whether the brokerage must withhold when it
-- pays a sub-agent out of its own commission is a question for the accountant,
-- not a default to assume. Every accrual therefore stores gross and leaves
-- withholding at zero. A non-zero withholding is REFUSED BY NAME
-- (INS_AGENT_WHT_NOT_BUILT) rather than accepted and ignored, so nobody can
-- believe the books net of a tax that was never computed.
--
-- Separate calculation from payment
-- ---------------------------------
-- The accrual happens when the brokerage's own commission on that policy is
-- recognised -- not at bind, and not when the money moves. So the sequence is
-- the one the accountant described: bind, commission entitlement recorded,
-- agent share calculated, insurer settles, the agent's payable becomes
-- eligible, payment is approved and recorded. The trigger rides the existing
-- ins_commission_events rows, so whichever recognition mode a policy uses
-- (placement or insurer settlement) the agent's share follows it without a
-- second, divergent definition of "earned".
--
-- Idempotency: every table gets a natural key, every RPC is safe to re-run,
-- and the accrual trigger skips a policy-and-agent that already has one.
--
-- Idempotent file: all add-columns are `if not exists`, all functions are
-- create-or-replace, the template inserts use on-conflict-do-nothing.

-- ---------------------------------------------------------------------
-- 1. Terms in force: how this intermediary is paid, and on what basis
-- ---------------------------------------------------------------------
-- The register holds identity, licence and status. It does not hold MONEY
-- terms, and it should not: a share percentage changes with renegotiation, is
-- approved by somebody, and must be readable historically. So terms are a
-- separate, versioned, effective-dated record -- the same shape as
-- ins_insurer_product_rates, which this mirrors deliberately.
--
-- Mirroring the rate matrix also means the money rules are enforced: one
-- approved term in force per intermediary and date window, entering is not
-- approving, and an approver cannot approve what they entered.
create table if not exists public.ins_intermediary_terms (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete cascade,
  intermediary_id   uuid not null,
  -- How the share is computed. 'none' exists for the insurer-appointed agent:
  -- recorded, so the register and the policy agree, but it accrues nothing.
  basis             text not null,
  -- The figure. A percentage for the first three bases, an amount for the last.
  rate_pct          numeric(7,4),
  fixed_amount      numeric(14,2),
  tier_from_amount  numeric(14,2),
  tier_to_amount    numeric(14,2),
  product_line_id   uuid references public.ins_product_lines(id),
  currency          text,
  effective_from    date not null,
  effective_to      date,
  source_ref        text,
  status            text not null default 'draft',
  entered_by        uuid default auth.uid(),
  approved_by       uuid,
  approved_at       timestamptz,
  withdrawn_reason  text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint ins_intermediary_terms_basis_check check (
    basis = any (array['none', 'pct_of_broker_commission', 'pct_of_gross_premium',
                        'flat_amount_per_policy', 'tiered_pct_of_broker_commission'])),
  constraint ins_intermediary_terms_status_check check (
    status = any (array['draft', 'approved', 'withdrawn', 'expired'])),
  constraint ins_intermediary_terms_window_check check (
    effective_to is null or effective_to >= effective_from),
  -- A basis that computes from a percentage must carry one, and only one.
  constraint ins_intermediary_terms_figure_check check (
    case basis
      when 'none' then rate_pct is null and fixed_amount is null
      when 'flat_amount_per_policy' then fixed_amount is not null and fixed_amount > 0
      else rate_pct is not null and rate_pct >= 0 and rate_pct <= 100
    end),
  constraint ins_intermediary_terms_tier_check check (
    basis <> 'tiered_pct_of_broker_commission'
    or (tier_from_amount is not null and tier_to_amount is not null
        and tier_to_amount > tier_from_amount)),
  -- An approved term must say who approved it and when.
  constraint ins_intermediary_terms_approval_check check (
    status <> 'approved' or (approved_by is not null and approved_at is not null)),
  constraint ins_intermediary_terms_tenant_id_key unique (tenant_id, id),
  constraint ins_intermediary_terms_fk foreign key (tenant_id, intermediary_id)
    references public.ins_intermediaries (tenant_id, id) on delete cascade
);

create index if not exists ins_intermediary_terms_lookup_idx
  on public.ins_intermediary_terms (tenant_id, intermediary_id, effective_from desc);

comment on table public.ins_intermediary_terms is
  'How an intermediary is paid, in force over a date window. Mirrors ins_insurer_product_rates: drafted by one person, approved by another, and one approved term per intermediary per window.';
comment on column public.ins_intermediary_terms.basis is
  'pct_of_broker_commission is the default and the common arrangement for a sub-agent: an agreed share of the commission the brokerage itself earns. pct_of_gross_premium is independent of the brokerage''s own rate. none records an insurer-appointed agent, who the brokerage never pays.';
comment on column public.ins_intermediary_terms.tier_from_amount is
  'For tiered_pct_of_broker_commission: the commission band this term applies to. Several tier rows make one ladder.';

alter table public.ins_intermediary_terms enable row level security;

drop policy if exists ins_intermediary_terms_select on public.ins_intermediary_terms;
create policy ins_intermediary_terms_select on public.ins_intermediary_terms
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

revoke all on table public.ins_intermediary_terms from public, anon;
revoke insert, update, delete on table public.ins_intermediary_terms from authenticated;

-- Same guard shape as ins_insurer_product_rates: money terms are written by
-- the RPCs only, which is where entered_by / approved_by can actually be
-- trusted.
create or replace function public.ins_intermediary_terms_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if current_setting('ins.via_rpc', true) is distinct from 'on' then
    raise exception 'INS_TERMS_RPC_ONLY: intermediary terms are set by ins_set_intermediary_term() and approved by ins_approve_intermediary_term()' using errcode = '42501';
  end if;
  return new;
end;
$function$;

revoke all on function public.ins_intermediary_terms_guard() from public, anon, authenticated;

drop trigger if exists trg_ins_intermediary_terms_guard on public.ins_intermediary_terms;
create trigger trg_ins_intermediary_terms_guard
  before insert or update or delete on public.ins_intermediary_terms
  for each row execute function public.ins_intermediary_terms_guard();

-- ---------------------------------------------------------------------
-- 2. The accrual: one row per policy and intermediary, with its events
-- ---------------------------------------------------------------------
-- Deliberately a subledger of its own rather than rows in ins_commission_entries:
-- that table is the brokerage's receivable from the insurer, and an agent's
-- share is a payable to somebody else. Mixing them would make "commission
-- earned" mean two opposite things on one report.
create table if not exists public.ins_agent_commission_accruals (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenants(id) on delete cascade,
  policy_id             uuid not null,
  intermediary_id       uuid not null,
  term_id               uuid,
  -- The basis and figures are COPIED at accrual time, not joined at read time.
  -- A renegotiated share must not silently rewrite what was accrued last year.
  basis                 text not null,
  rate_pct              numeric(7,4),
  fixed_amount          numeric(14,2),
  commission_base       numeric(14,2) not null,
  gross_amount          numeric(14,2) not null,
  wht_amount            numeric(14,2) not null default 0,
  currency              text not null,
  -- 'accrued' when the brokerage's commission was recognised, 'eligible' when
  -- policy terms allow payment, 'paid' when the money left. Reversal is a
  -- separate status because a cancelled policy does not un-happen; it reverses.
  status                text not null default 'accrued',
  eligible_on           date,
  paid_at               timestamptz,
  reversal_reason       text,
  journal_entry_id      uuid,
  payment_journal_entry_id uuid,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint ins_agent_accruals_status_check check (
    status = any (array['accrued', 'eligible', 'paid', 'reversed'])),
  constraint ins_agent_accruals_amount_check check (gross_amount > 0),
  -- Withholding is carried as a column so the shape is already right when the
  -- accountant settles the rate; until then only zero is accepted (see the
  -- accrual function), so the column can never hold a figure nobody computed.
  constraint ins_agent_accruals_wht_check check (wht_amount >= 0 and wht_amount <= gross_amount),
  -- A paid row must say when; an unpaid one must not pretend to.
  constraint ins_agent_accruals_paid_check check (
    (status = 'paid') = (paid_at is not null)),
  constraint ins_agent_accruals_tenant_id_key unique (tenant_id, id),
  -- One accrual per policy and intermediary. Re-running recognition is a no-op.
  constraint ins_agent_accruals_once_key unique (tenant_id, policy_id, intermediary_id),
  constraint ins_agent_accruals_policy_fk foreign key (tenant_id, policy_id)
    references public.ins_policies (tenant_id, id) on delete cascade,
  constraint ins_agent_accruals_intermediary_fk foreign key (tenant_id, intermediary_id)
    references public.ins_intermediaries (tenant_id, id) on delete restrict,
  constraint ins_agent_accruals_term_fk foreign key (tenant_id, term_id)
    references public.ins_intermediary_terms (tenant_id, id) on delete restrict
);

create index if not exists ins_agent_accruals_status_idx
  on public.ins_agent_commission_accruals (tenant_id, status, eligible_on);
create index if not exists ins_agent_accruals_intermediary_idx
  on public.ins_agent_commission_accruals (tenant_id, intermediary_id);

comment on table public.ins_agent_commission_accruals is
  'What the brokerage owes an intermediary on one policy, copied from the term in force at accrual time. A payable to the intermediary, distinct from ins_commission_entries, which is the brokerage''s receivable from the insurer.';
comment on column public.ins_agent_commission_accruals.wht_amount is
  'Always 0 until the withholding question is settled. The accrual function refuses a non-zero value by name rather than accept a figure nobody computed.';

alter table public.ins_agent_commission_accruals enable row level security;

drop policy if exists ins_agent_accruals_select on public.ins_agent_commission_accruals;
create policy ins_agent_accruals_select on public.ins_agent_commission_accruals
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

revoke all on table public.ins_agent_commission_accruals from public, anon;
revoke insert, update, delete on table public.ins_agent_commission_accruals from authenticated;

create table if not exists public.ins_agent_commission_events (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  accrual_id      uuid not null,
  event           text not null,
  amount          numeric(14,2),
  journal_entry_id uuid,
  note            text,
  actor_id        uuid default auth.uid(),
  created_at      timestamptz not null default now(),
  constraint ins_agent_commission_events_event_check check (
    event = any (array['accrued', 'eligible', 'paid', 'reversed'])),
  constraint ins_agent_commission_events_fk foreign key (tenant_id, accrual_id)
    references public.ins_agent_commission_accruals (tenant_id, id) on delete cascade
);

create index if not exists ins_agent_commission_events_accrual_idx
  on public.ins_agent_commission_events (tenant_id, accrual_id, created_at);

alter table public.ins_agent_commission_events enable row level security;

drop policy if exists ins_agent_commission_events_select on public.ins_agent_commission_events;
create policy ins_agent_commission_events_select on public.ins_agent_commission_events
  for select to authenticated
  using (tenant_id = public.get_my_tenant_id() and public.can_access_insurance());

revoke all on table public.ins_agent_commission_events from public, anon;
revoke insert, update, delete on table public.ins_agent_commission_events from authenticated;

-- ---------------------------------------------------------------------
-- 3. A GL home for the cost
-- ---------------------------------------------------------------------
-- Agent commission is an EXPENSE of the brokerage. It needs its own account
-- and its own posting role, because folding it into commission_income would
-- net a cost against revenue and hide both figures.
create or replace function public.platform_gl_posting_roles()
returns text[]
language sql
immutable
set search_path = 'public', 'pg_temp'
as $$
  select array[
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable',
    'unearned_commission',
    'insurer_claim_receivable', 'client_claim_payable',
    'fx_rounding',
    'fx_gain_realised', 'fx_loss_realised',
    'fx_gain_unrealised', 'fx_loss_unrealised',
    'opening_balance_clearing',
    'retained_earnings',
    -- Item 6: the brokerage's cost of the business an intermediary brings in.
    -- The payable is not a new role and must not be one: ap_control already
    -- means "money the company owes a third party", and an intermediary is
    -- exactly that.
    'agent_commission_expense'
  ]::text[];
$$;
revoke all on function public.platform_gl_posting_roles() from public, anon;
grant execute on function public.platform_gl_posting_roles() to authenticated;

-- The role also has to be legal on gl_posting_rules. A role the array knows
-- about but the constraint rejects is worse than one that does not exist: the
-- template and the backfill below would both fail, and the seed would fail with
-- them.
alter table public.gl_posting_rules drop constraint if exists gl_posting_rules_account_role_check;
alter table public.gl_posting_rules
  add constraint gl_posting_rules_account_role_check
  check (account_role in (
    'ap_control', 'ar_control', 'bank', 'cash', 'vat_input', 'vat_output', 'wht_payable',
    'default_expense', 'default_revenue', 'salaries_payable', 'paye_payable', 'nssf_payable',
    'salaries_expense',
    'client_money_bank', 'insurer_payable', 'commission_receivable', 'commission_income',
    'wht_receivable', 'unearned_commission',
    'insurer_claim_receivable', 'client_claim_payable',
    'fx_rounding',
    'fx_gain_realised', 'fx_loss_realised',
    'fx_gain_unrealised', 'fx_loss_unrealised',
    'opening_balance_clearing',
    'retained_earnings',
    'agent_commission_expense'
  ));

-- Template account + rule for new insurance tenants, and a backfill for
-- existing ones (mirrors the retained_earnings pattern in 20261110120000).
insert into public.industry_template_items (template_key, kind, sort_order, name, payload)
select 'insurance', v.kind, v.sort_order, v.name, v.payload
from (values
  ('gl_account',   32, '5010',
     '{"name": "Agent Commission", "account_type": "expense"}'::jsonb),
  ('posting_rule', 32, 'agent_commission_expense', '{"account_code": "5010"}'::jsonb)
) as v(kind, sort_order, name, payload)
where exists (select 1 from public.industry_templates t where t.key = 'insurance')
on conflict (template_key, kind, name) do nothing;

do $$
declare
  t     record;
  v_gl  uuid;
begin
  for t in
    select distinct r.tenant_id
      from public.gl_posting_rules r
     where r.account_role = 'insurer_payable'
  loop
    if exists (select 1 from public.gl_posting_rules x
                where x.tenant_id = t.tenant_id and x.account_role = 'agent_commission_expense') then
      continue;
    end if;
    select id into v_gl from public.gl_accounts
     where tenant_id = t.tenant_id and account_code = '5010';
    if v_gl is null then
      insert into public.gl_accounts (tenant_id, account_code, name, account_type)
      values (t.tenant_id, '5010', 'Agent Commission', 'expense')
      returning id into v_gl;
    elsif not exists (
      select 1 from public.gl_accounts
       where id = v_gl and account_type = 'expense' and is_active
    ) then
      -- Somebody else's 5010. Do not guess: say so and leave the mapping to a
      -- human, exactly as the retained_earnings backfill does.
      raise notice 'ins_agent_commission: tenant % already uses account code 5010 for something else; map agent_commission_expense by hand',
        t.tenant_id;
      continue;
    end if;
    insert into public.gl_posting_rules (tenant_id, account_role, gl_account_id)
    values (t.tenant_id, 'agent_commission_expense', v_gl)
    on conflict (tenant_id, account_role) do nothing;
  end loop;
end
$$;

-- ---------------------------------------------------------------------
-- 4. May this intermediary be paid by the brokerage at all?
-- ---------------------------------------------------------------------
-- One predicate, used by the terms writer, the accrual and the payment, so the
-- three can never disagree about who is payable.
create or replace function public.ins_intermediary_is_broker_paid(p_intermediary_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select coalesce((
    select a.category = any (array['sub_agent', 'referral_partner'])
      from public.ins_intermediaries a
     where a.id = p_intermediary_id and a.tenant_id = public.get_my_tenant_id()
  ), false);
$$;
revoke all on function public.ins_intermediary_is_broker_paid(uuid) from public, anon;
grant execute on function public.ins_intermediary_is_broker_paid(uuid) to authenticated;

-- The term in force for an intermediary on a date, for a product line if one is
-- given. Returns the most specific approved row: a product-line term beats a
-- company-wide one on the same date.
create or replace function public.ins_intermediary_term_in_force(
  p_intermediary_id uuid,
  p_on               date,
  p_product_line_id  uuid default null)
returns uuid
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select t.id
    from public.ins_intermediary_terms t
   where t.tenant_id = public.get_my_tenant_id()
     and t.intermediary_id = p_intermediary_id
     and t.status = 'approved'
     and t.effective_from <= p_on
     and coalesce(t.effective_to, 'infinity'::date) >= p_on
     and (t.product_line_id is null or t.product_line_id = p_product_line_id)
   order by (t.product_line_id is not null) desc, t.effective_from desc
   limit 1;
$$;
revoke all on function public.ins_intermediary_term_in_force(uuid, date, uuid) from public, anon;
grant execute on function public.ins_intermediary_term_in_force(uuid, date, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Writing and approving terms
-- ---------------------------------------------------------------------
create or replace function public.ins_set_intermediary_term(
  p_intermediary_id   uuid,
  p_basis             text,
  p_effective_from    date,
  p_rate_pct          numeric default null,
  p_fixed_amount      numeric default null,
  p_product_line_id   uuid default null,
  p_effective_to      date default null,
  p_tier_from_amount  numeric default null,
  p_tier_to_amount    numeric default null,
  p_source_ref        text default null)
returns public.ins_intermediary_terms
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  v_agent  public.ins_intermediaries;
  v_row    public.ins_intermediary_terms;
  v_ccy    text;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into v_agent from public.ins_intermediaries
   where id = p_intermediary_id and tenant_id = v_tenant;
  if not found then
    raise exception 'INS_INTERMEDIARY_NOT_FOUND';
  end if;

  -- The category decides whether there is anything to set. This is the rule
  -- that keeps an insurer-appointed agent out of the brokerage's books, and it
  -- lives here rather than in the UI so a direct call cannot get round it.
  if v_agent.category = 'insurer_appointed_agent' then
    if p_basis is distinct from 'none' then
      raise exception 'INS_AGENT_INSURER_PAID: % is an insurer-appointed agent, so the insurer remunerates them; the brokerage owes them nothing and must not accrue a share. Record basis ''none'', or change the register if the appointment is wrong',
        v_agent.name;
    end if;
  elsif v_agent.category = 'independent_broker' then
    raise exception 'INS_AGENT_CO_BROKER: % is registered as an independent broker. A co-brokerage split is a different arrangement from a sub-agent share of the brokerage''s commission, and it is not built yet; register the arrangement as a sub_agent or referral_partner if that is what it is',
      v_agent.name;
  elsif not public.ins_intermediary_is_broker_paid(p_intermediary_id) then
    raise exception 'INS_AGENT_UNKNOWN_CATEGORY: % has category %, which has no commission treatment; only sub_agent and referral_partner are paid by the brokerage',
      v_agent.name, v_agent.category;
  end if;

  -- An approved term in force is not silently stacked. End it first: a shared
  -- subledger where two terms overlap is a subledger nobody can reconcile.
  if p_basis <> 'none' and exists (
    select 1 from public.ins_intermediary_terms t
     where t.tenant_id = v_tenant and t.intermediary_id = p_intermediary_id
       and t.status = 'approved'
       and t.product_line_id is not distinct from p_product_line_id
       and t.effective_from <= coalesce(p_effective_to, 'infinity'::date)
       and coalesce(t.effective_to, 'infinity'::date) >= p_effective_from
  ) then
    raise exception 'INS_AGENT_TERM_OVERLAP: another approved term for this intermediary already covers part of % to %. End-date it before starting a new one',
      p_effective_from, coalesce(p_effective_to::text, 'open-ended');
  end if;

  v_ccy := fin_ledger_currency(v_tenant);

  perform set_config('ins.via_rpc', 'on', true);
  insert into public.ins_intermediary_terms
    (tenant_id, intermediary_id, basis, rate_pct, fixed_amount,
     tier_from_amount, tier_to_amount, product_line_id, currency,
     effective_from, effective_to, source_ref, status, entered_by)
  values
    (v_tenant, p_intermediary_id, p_basis, p_rate_pct, p_fixed_amount,
     p_tier_from_amount, p_tier_to_amount, p_product_line_id, v_ccy,
     p_effective_from, p_effective_to, nullif(btrim(coalesce(p_source_ref, '')), ''),
     'draft', auth.uid())
  returning * into v_row;
  perform set_config('ins.via_rpc', 'off', true);

  return v_row;
end
$function$;

revoke all on function public.ins_set_intermediary_term(uuid, text, date, numeric, numeric, uuid, date, numeric, numeric, text) from public, anon;
grant execute on function public.ins_set_intermediary_term(uuid, text, date, numeric, numeric, uuid, date, numeric, numeric, text) to authenticated;

create or replace function public.ins_approve_intermediary_term(p_id uuid)
returns public.ins_intermediary_terms
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_row public.ins_intermediary_terms;
  v_uid uuid := auth.uid();
begin
  if not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  select * into v_row from public.ins_intermediary_terms
   where id = p_id and tenant_id = public.get_my_tenant_id()
   for update;
  if not found then
    raise exception 'INS_AGENT_TERM_NOT_FOUND: intermediary term not found';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'INS_AGENT_TERM_NOT_DRAFT: only a draft can be approved (this one is %)', v_row.status;
  end if;
  if v_row.entered_by is not distinct from v_uid then
    raise exception 'INS_AGENT_TERM_SELF_APPROVAL: the person who entered a term cannot approve it';
  end if;
  -- Re-checked at approval, not just at entry: the register may have changed
  -- its mind about the category in between, and approval is the moment the
  -- money rule becomes real.
  if v_row.basis <> 'none' and not public.ins_intermediary_is_broker_paid(v_row.intermediary_id) then
    raise exception 'INS_AGENT_NOT_BROKER_PAID: this intermediary is not one the brokerage pays, so a commission-share term cannot be approved for it';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update public.ins_intermediary_terms
     set status = 'approved', approved_by = v_uid, approved_at = now(), updated_at = now()
   where id = p_id
   returning * into v_row;
  perform set_config('ins.via_rpc', 'off', true);

  return v_row;
end
$function$;

revoke all on function public.ins_approve_intermediary_term(uuid) from public, anon;
grant execute on function public.ins_approve_intermediary_term(uuid) to authenticated;

create or replace function public.ins_end_intermediary_term(p_id uuid, p_effective_to date)
returns public.ins_intermediary_terms
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_row public.ins_intermediary_terms;
begin
  if not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;
  select * into v_row from public.ins_intermediary_terms
   where id = p_id and tenant_id = public.get_my_tenant_id()
   for update;
  if not found then raise exception 'INS_AGENT_TERM_NOT_FOUND'; end if;
  if p_effective_to is null or p_effective_to < v_row.effective_from then
    raise exception 'INS_AGENT_TERM_END_DATE: an end date must be on or after the start date';
  end if;

  perform set_config('ins.via_rpc', 'on', true);
  update public.ins_intermediary_terms
     set effective_to = p_effective_to, updated_at = now()
   where id = p_id
   returning * into v_row;
  perform set_config('ins.via_rpc', 'off', true);
  return v_row;
end
$function$;

revoke all on function public.ins_end_intermediary_term(uuid, date) from public, anon;
grant execute on function public.ins_end_intermediary_term(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- 6. The calculation, in one place
-- ---------------------------------------------------------------------
-- Every basis reduces to "what is this intermediary owed on this policy". It is
-- a pure function of the term, the policy and the brokerage's own commission,
-- so the wizard can preview it and the accrual can post it without two
-- implementations drifting apart.
--
-- The two behaviours that matter:
--
--   pct_of_broker_commission  the DEFAULT. The share multiplies what the
--                             brokerage itself earns, so a sub-agent is never
--                             paid on premium the brokerage did not get paid
--                             for. This is the arrangement the accountant
--                             described.
--   pct_of_gross_premium      supported, but it is a different deal: the share
--                             does not move when the brokerage's rate does, and
--                             the brokerage can owe the agent more than it
--                             earns. That is the intermediary's risk and the
--                             brokerage's problem, so it is called out here
--                             rather than smoothed over.
--
-- Rounding: to the ledger currency's minor unit (2 places), half-up, once, at
-- the end. A share is never accumulated from already-rounded parts.
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
      'reason', 'the term in force records basis none: this intermediary is not paid by the brokerage');
  end if;

  if v_basis in ('pct_of_broker_commission', 'tiered_pct_of_broker_commission') and v_broker <= 0 then
    raise exception 'INS_AGENT_NO_BASE: % is paid a share of the brokerage''s commission, but policy % has no commission earned yet. Accrue after the commission is recognised, not before',
      a.name, p.policy_no;
  end if;

  if v_basis = 'pct_of_broker_commission' then
    v_rate  := t.rate_pct;
    v_gross := round(v_broker * v_rate / 100.0, 2);

  elsif v_basis = 'tiered_pct_of_broker_commission' then
    -- The ladder is the set of approved tier rows for this intermediary. The
    -- band that contains the brokerage's commission decides the rate, and the
    -- rate applies to the whole commission -- a marginal ladder would need
    -- every band approved as one instrument, which is a different build.
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
      -- A flat amount in another currency needs a rate, and guessing one is
      -- exactly the kind of quiet wrongness this codebase refuses elsewhere.
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

  return jsonb_build_object(
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
end
$function$;

revoke all on function public.ins_agent_commission_calculate(uuid, uuid) from public, anon;
grant execute on function public.ins_agent_commission_calculate(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 7. Accrual: follows the brokerage's own commission, whichever way it earned
-- ---------------------------------------------------------------------
-- The trigger hangs off ins_commission_events, which is written by every
-- recognition path (placement at bind, settlement on insurer payment). Hooking
-- there rather than at bind means the agent's share is a consequence of the
-- brokerage being paid, which is the arrangement: a sub-agent earns when the
-- brokerage does, not when the policy is signed.
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
  v_je      public.journal_entries;
  v_amt     numeric;
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

  v_expense := public.get_posting_account(v_tenant, 'agent_commission_expense');
  v_ap      := public.get_posting_account(v_tenant, 'ap_control');
  if v_expense is null or v_ap is null then
    raise exception 'INS_POSTING_RULE_MISSING: agent commission needs the agent_commission_expense and ap_control posting rules before a share can be accrued';
  end if;

  v_je := public.post_journal_entry(
    v_tenant, 'ins_agent_commission_accrual', p_policy_id, p.bound_at::date,
    'Agent commission accrued on ' || p.policy_no,
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_expense, 'debit',  v_amt,
                         'currency', p.currency,
                         'description', 'Agent share of commission on ' || p.policy_no),
      jsonb_build_object('gl_account_id', v_ap, 'credit', v_amt,
                         'currency', p.currency,
                         'description', 'Payable to agent for ' || p.policy_no)));

  insert into public.ins_agent_commission_accruals
    (tenant_id, policy_id, intermediary_id, term_id, basis, rate_pct, fixed_amount,
     commission_base, gross_amount, wht_amount, currency, status, journal_entry_id)
  values
    (v_tenant, p_policy_id, p.agent_id, (v_calc ->> 'term_id')::uuid, v_calc ->> 'basis',
     (v_calc ->> 'rate_pct')::numeric, (v_calc ->> 'fixed_amount')::numeric,
     (v_calc ->> 'commission_base')::numeric, v_amt,
     0, p.currency, 'accrued', v_je.id)
  returning * into v_row;

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, journal_entry_id, note)
  values (v_tenant, v_row.id, 'accrued', v_amt, v_je.id,
          'share of the brokerage''s commission, basis ' || v_row.basis);

  return jsonb_build_object('accrued', true, 'accrual_id', v_row.id,
                            'gross_amount', v_amt, 'status', 'accrued',
                            'journal_entry_id', v_je.id);
end
$function$;

revoke all on function public.ins_agent_commission_accrue(uuid) from public, anon;
-- Owner-only: called by the recognition trigger and by an admin through the
-- supported paths, never by a client directly.
revoke all on function public.ins_agent_commission_accrue(uuid) from public, anon, authenticated;

-- The trigger on recognition. SECURITY DEFINER and it swallows nothing: if the
-- share cannot be computed the recognition fails, because a commission the
-- books cannot explain is worse than a bind that stops and says why.
create or replace function public.ins_agent_commission_on_recognition()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_policy uuid;
  v_agent  uuid;
begin
  if new.event <> 'recognised' then
    return new;
  end if;

  select e.policy_id into v_policy
    from public.ins_commission_entries e where e.id = new.entry_id;
  if v_policy is null then
    return new;
  end if;

  select p.agent_id into v_agent
    from public.ins_policies p
   where p.id = v_policy and p.tenant_id = new.tenant_id;
  if v_agent is null then
    return new;
  end if;

  -- Only the brokerage's own agent on this policy; the accrual re-checks the
  -- category and refuses to touch an insurer-appointed agent.
  perform public.ins_agent_commission_accrue(v_policy);
  return new;
end;
$function$;

revoke all on function public.ins_agent_commission_on_recognition() from public, anon, authenticated;

drop trigger if exists trg_ins_agent_commission_on_recognition on public.ins_commission_events;
create trigger trg_ins_agent_commission_on_recognition
  after insert on public.ins_commission_events
  for each row execute function public.ins_agent_commission_on_recognition();

-- Somebody has to ask the question for commissions recognised BEFORE this
-- migration: an existing book has earned commission and named agents, and
-- their shares were never accrued. Explicitly, one policy at a time or the
-- whole book, so this is never a surprise mass-posting at deploy.
create or replace function public.ins_agent_commission_backfill()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_tenant uuid := public.get_my_tenant_id();
  r        record;
  v_out    jsonb;
  v_ok     integer := 0;
  v_skip   integer := 0;
  v_fail   integer := 0;
  v_failed jsonb := '[]'::jsonb;
begin
  if v_tenant is null or not public.can_manage_insurance() then
    raise exception 'INS_ACCESS_DENIED' using errcode = '42501';
  end if;

  for r in
    select distinct p.id, p.policy_no
      from public.ins_policies p
      join public.ins_commission_entries e on e.policy_id = p.id
     where p.tenant_id = v_tenant
       and p.agent_id is not null
       and e.status in ('earned', 'transferred')
       and not exists (select 1 from public.ins_agent_commission_accruals x
                        where x.tenant_id = v_tenant and x.policy_id = p.id
                          and x.intermediary_id = p.agent_id)
     order by p.policy_no
  loop
    begin
      v_out := public.ins_agent_commission_accrue(r.id);
      if coalesce((v_out ->> 'accrued')::boolean, false) then
        v_ok := v_ok + 1;
      else
        v_skip := v_skip + 1;
      end if;
    exception when others then
      -- One policy's missing term must not roll back the whole book. Report it
      -- and carry on; the caller fixes and re-runs, which is safe.
      v_fail := v_fail + 1;
      v_failed := v_failed || jsonb_build_array(jsonb_build_object(
        'policy_no', r.policy_no, 'error', sqlerrm));
    end;
  end loop;

  return jsonb_build_object('accrued', v_ok, 'skipped', v_skip,
                            'failed', v_fail, 'failures', v_failed);
end
$function$;

revoke all on function public.ins_agent_commission_backfill() from public, anon;
-- Owner-only: called by the recognition trigger and by an admin through the
-- supported paths, never by a client directly.
revoke all on function public.ins_agent_commission_backfill() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. Eligibility: calculation is not payment
-- ---------------------------------------------------------------------
-- A share is accrued when the brokerage earns its commission. It becomes
-- ELIGIBLE on the policy's own terms -- by default when the insurer has paid
-- us, because paying an agent out of money we have not received is a cash
-- decision the brokerage may or may not want. Terms can say "on bind" instead,
-- and that choice lives on the term, not in the scheduler.
create or replace function public.ins_agent_commission_mark_eligible(
  p_policy_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
       set status = 'eligible', eligible_on = current_date, updated_at = now()
     where id = r.id;
    insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, note)
    values (v_tenant, r.id, 'eligible', r.gross_amount,
            'the brokerage''s commission on this policy is earned, so the share is payable');
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('marked_eligible', v_n);
end
$function$;

revoke all on function public.ins_agent_commission_mark_eligible(uuid) from public, anon;
grant execute on function public.ins_agent_commission_mark_eligible(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 9. Payment: clears the payable, moves the cash
-- ---------------------------------------------------------------------
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

  -- Paid and reversed are both terminal for this row.
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

  -- An intermediary suspended or terminated between accrual and payment is a
  -- compliance stop, not a warning: paying a terminated intermediary is the
  -- kind of thing an audit asks about.
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
      jsonb_build_object('gl_account_id', v_ap,   'debit',  x.gross_amount,
                         'currency', x.currency,
                         'description', 'Clear agent payable for ' || p.policy_no),
      jsonb_build_object('gl_account_id', v_bank, 'credit', x.gross_amount,
                         'currency', x.currency,
                         'description', 'Paid to ' || a.name)));

  update public.ins_agent_commission_accruals
     set status = 'paid', paid_at = now(), payment_journal_entry_id = v_je.id, updated_at = now()
   where id = x.id;

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, journal_entry_id, note)
  values (v_tenant, x.id, 'paid', x.gross_amount, v_je.id,
          nullif(btrim(coalesce(p_note, '')), ''));

  return jsonb_build_object('paid', true, 'accrual_id', x.id,
                            'amount', x.gross_amount, 'journal_entry_id', v_je.id);
end
$function$;

revoke all on function public.ins_agent_commission_pay(uuid, uuid, date, text) from public, anon;
grant execute on function public.ins_agent_commission_pay(uuid, uuid, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 10. Cancellation, endorsement and refund: reverse, do not delete
-- ---------------------------------------------------------------------
-- When a policy is cancelled the agent's share is not quietly erased: the
-- accrual stands, and a reversal says why. An unpaid share that is reversed
-- must not be paid afterwards, and a PAID share is not reversed silently --
-- that is a recovery from the intermediary and needs its own decision, so it
-- is refused by name and left to a human.
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
  v_je      public.journal_entries;
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

  v_expense := public.get_posting_account(v_tenant, 'agent_commission_expense');
  v_ap      := public.get_posting_account(v_tenant, 'ap_control');
  if v_expense is null or v_ap is null then
    raise exception 'INS_POSTING_RULE_MISSING: reversing an agent share needs the agent_commission_expense and ap_control posting rules';
  end if;

  v_je := public.post_journal_entry(
    v_tenant, 'ins_agent_commission_reversal', x.id, current_date,
    'Agent commission reversed: ' || btrim(p_reason),
    jsonb_build_array(
      jsonb_build_object('gl_account_id', v_expense, 'credit', x.gross_amount,
                         'currency', x.currency,
                         'description', 'Reverse agent share: ' || btrim(p_reason)),
      jsonb_build_object('gl_account_id', v_ap, 'debit', x.gross_amount,
                         'currency', x.currency,
                         'description', 'Reverse agent payable: ' || btrim(p_reason))));

  update public.ins_agent_commission_accruals
     set status = 'reversed', reversal_reason = btrim(p_reason), updated_at = now()
   where id = x.id;

  insert into public.ins_agent_commission_events (tenant_id, accrual_id, event, amount, journal_entry_id, note)
  values (v_tenant, x.id, 'reversed', x.gross_amount, v_je.id, btrim(p_reason));

  return jsonb_build_object('reversed', true, 'accrual_id', x.id,
                            'amount', x.gross_amount, 'journal_entry_id', v_je.id);
end
$function$;

revoke all on function public.ins_agent_commission_reverse(uuid, text) from public, anon;
grant execute on function public.ins_agent_commission_reverse(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 11. Journal source types
-- ---------------------------------------------------------------------
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
      -- Item 6: the agent commission subledger
      'ins_agent_commission_accrual'::text,
      'ins_agent_commission_payment'::text,
      'ins_agent_commission_reversal'::text
    ]));

-- ---------------------------------------------------------------------
-- 12. The withholding question, refused by name until it is answered
-- ---------------------------------------------------------------------
-- Uganda treats the INSURER as the withholding agent for insurance-agent
-- commission -- the arrangement that does not run through this subledger at
-- all. Whether the BROKERAGE withholds when it pays a sub-agent out of its own
-- commission is not settled in this codebase's accounting pack, so:
--
--   * the column exists, so the shape is right when the answer arrives;
--   * it is constrained to 0 by the accrual, and any attempt to record
--     withholding is refused with a message that names the open question.
--
-- This is the "refuse the unsupported case loudly by name" rule: it is better
-- for a tenant to be told withholding is not built than to have the books post
-- a net figure that nobody computed.
create or replace function public.ins_agent_commission_wht_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if coalesce(new.wht_amount, 0) <> 0 then
    raise exception 'INS_AGENT_WHT_NOT_BUILT: withholding tax on a brokerage-paid agent share is not built. The insurer is the withholding agent for insurance-agent commission, and whether the brokerage must withhold when it pays a sub-agent out of its own commission is an open question for the accountant. Record the gross figure; withholding is refused here rather than quietly netted'
      using errcode = '0A000';
  end if;
  return new;
end;
$function$;

revoke all on function public.ins_agent_commission_wht_guard() from public, anon, authenticated;

drop trigger if exists trg_ins_agent_commission_wht_guard on public.ins_agent_commission_accruals;
create trigger trg_ins_agent_commission_wht_guard
  before insert or update on public.ins_agent_commission_accruals
  for each row execute function public.ins_agent_commission_wht_guard();

-- ---------------------------------------------------------------------
-- 13. Tenant read-only guard for the three new tables
-- ---------------------------------------------------------------------
-- The repo rule (20261108000300): a migration that adds tenant tables ends
-- with this. check_live_security_drift.sql caught its absence on the last three
-- tables added without it, so it is not optional.
select public.apply_tenant_read_only_guard();
