-- Endorsements, slice E1: durable mid-term adjustment proposals (no posting).
--
-- An endorsement is a mid-term change to an active policy: a coverage or
-- exposure change that adjusts premium (additional or return, or both across
-- insurers), with the commission adjusting at the policy's immutable bound
-- rate. This slice ships the proposal machinery, mirroring the cancellation
-- pipeline's process (durable proposals keyed by request_key, a read-only
-- calculation under lock, withdraw, Finance/insurance-manager access) and the
-- cancellation money philosophy (the insurer's agreed delta takes priority;
-- pro-rata by remaining days is the fallback; every amount is reviewable
-- before anything posts).
--
-- Deliberately NOT in this slice: any posting (prepare/approve land in E2,
-- foreign legs in E3), commission-entry schema changes (E2), and the pack
-- document (waits on the accountant).
--
-- Guards shipped here: an endorsement and a cancellation cannot be live on
-- the same policy at the same time (cross-guard triggers, so neither legacy
-- function body needs rewriting), only one live endorsement per policy (a
-- partial unique index for race safety), and a policy with a live endorsement
-- cannot start a renewal.
--
-- The policy row is never mutated (owner decision D2): "current" values are
-- the bind snapshot plus the posted endorsements, computed by
-- ins_endorsement_review_position.
--
-- Test: supabase/tests/test_endorsement_proposals.sql.

-- =============================================================================
-- A. The proposal table and its events
-- =============================================================================
create table public.ins_policy_endorsements (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id),
  policy_id uuid not null,
  request_key uuid not null,
  reason text not null check(length(btrim(reason)) between 5 and 2000),
  effective_date date not null,
  insurer_terms jsonb not null check(jsonb_typeof(insurer_terms) = 'array'),
  changes jsonb not null default '{}'::jsonb check(jsonb_typeof(changes) = 'object'),
  proposed_by uuid not null,
  proposed_at timestamptz not null default now(),
  status text not null default 'proposed'
    check(status in ('proposed','prepared','posting','posted','rejected','withdrawn')),
  prepared_by uuid, prepared_at timestamptz,
  calculation jsonb not null,
  checked_by uuid, checked_at timestamptz, review_note text,
  manual_exception_accepted boolean not null default false,
  endorsement_no text,
  posting_date date,
  journal_entry_id uuid references public.journal_entries(id),
  premium_item_id uuid,
  credit_note_ids jsonb not null default '[]'::jsonb,
  commission_entry_ids jsonb not null default '[]'::jsonb,
  accounting_mappings jsonb,
  operation_txid bigint,
  unique(tenant_id, id),
  unique(tenant_id, request_key),
  unique(tenant_id, endorsement_no),
  foreign key(tenant_id, policy_id) references public.ins_policies(tenant_id, id)
);
create index ins_policy_endorsements_tenant_idx on public.ins_policy_endorsements(tenant_id);
create index ins_policy_endorsements_policy_idx on public.ins_policy_endorsements(policy_id);
-- Only one LIVE endorsement per policy, enforced against concurrent proposals.
create unique index ins_policy_endorsements_live_unique
  on public.ins_policy_endorsements(policy_id)
  where status in ('proposed','prepared','posting');

create table public.ins_policy_endorsement_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  endorsement_id uuid not null references public.ins_policy_endorsements(id) on delete cascade,
  event text not null check(event in ('proposed','withdrawn','prepared','approved','rejected')),
  actor_id uuid,
  detail jsonb,
  created_at timestamptz not null default now()
);
create index ins_policy_endorsement_events_idx on public.ins_policy_endorsement_events(endorsement_id);

alter table public.ins_policy_endorsements enable row level security;
alter table public.ins_policy_endorsement_events enable row level security;

drop policy if exists "ins_policy_endorsements_select" on public.ins_policy_endorsements;
create policy "ins_policy_endorsements_select" on public.ins_policy_endorsements
  for select to authenticated
  using (tenant_id = get_my_tenant_id() and (can_access_insurance() or is_finance_team_member('finance')));

drop policy if exists "ins_policy_endorsement_events_select" on public.ins_policy_endorsement_events;
create policy "ins_policy_endorsement_events_select" on public.ins_policy_endorsement_events
  for select to authenticated
  using (tenant_id = get_my_tenant_id() and (can_access_insurance() or is_finance_team_member('finance')));

revoke all on public.ins_policy_endorsements, public.ins_policy_endorsement_events from public, anon;
grant select on public.ins_policy_endorsements to authenticated;
grant select on public.ins_policy_endorsement_events to authenticated;

-- The tenant tables drift test requires the read-only guard on new tables.
select public.apply_tenant_read_only_guard();

-- =============================================================================
-- B. Input validation (signed money: endorsements add or return premium)
-- =============================================================================
create function public.platform_ins_endorsement_money(p_value text)
returns numeric
language plpgsql
immutable
set search_path = public, pg_temp
as $function$
begin
  if p_value is null or p_value !~ '^[-+]?\d{1,16}(\.\d{1,2})?$' then
    raise exception 'INS_ENDORSEMENT_INPUT: signed decimal money with at most two decimals required';
  end if;
  return p_value::numeric;
end $function$;
revoke all on function public.platform_ins_endorsement_money(text) from public, anon, authenticated;

-- =============================================================================
-- C. The read-only calculation (also used as the proposal's stored quote)
-- =============================================================================
create or replace function public.ins_preview_policy_endorsement(
  p_policy_id uuid,
  p_effective_date date,
  p_insurer_terms jsonb,
  p_changes jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
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
  if p_effective_date is null or p_effective_date > current_date then
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
revoke all on function public.ins_preview_policy_endorsement(uuid, date, jsonb, jsonb) from public, anon;

-- =============================================================================
-- D. Propose / withdraw
-- =============================================================================
create or replace function public.ins_propose_policy_endorsement(
  p_policy_id uuid,
  p_effective_date date,
  p_insurer_terms jsonb,
  p_changes jsonb,
  p_reason text,
  p_request_key uuid
)
returns public.ins_policy_endorsements
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  e ins_policy_endorsements%rowtype;
  quote jsonb;
begin
  if auth.uid() is null or effective_user_id() is distinct from auth.uid()
     or not (can_manage_insurance() or is_finance_team_member('finance')) then
    raise exception 'INS_FORBIDDEN: Insurance manager or Finance acting as themselves required' using errcode = '42501';
  end if;
  if p_request_key is null or p_reason is null or length(btrim(p_reason)) not between 5 and 2000 then
    raise exception 'INS_ENDORSEMENT_INPUT: request key and reason required';
  end if;

  -- Idempotent retry by key, with a payload-conflict refusal.
  select * into e from ins_policy_endorsements
   where tenant_id = get_my_tenant_id() and request_key = p_request_key;
  if found then
    if e.proposed_by <> auth.uid()
       or e.policy_id is distinct from p_policy_id
       or e.effective_date is distinct from p_effective_date
       or e.insurer_terms is distinct from p_insurer_terms
       or e.changes is distinct from coalesce(p_changes, '{}'::jsonb)
       or e.reason is distinct from btrim(p_reason) then
      raise exception 'INS_ENDORSEMENT_RETRY_CONFLICT: different payload';
    end if;
    return e;
  end if;

  perform id from ins_policies where id = p_policy_id and tenant_id = get_my_tenant_id() for update;
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  if exists (select 1 from ins_policy_endorsements
              where policy_id = p_policy_id and status in ('proposed','prepared','posting')) then
    raise exception 'INS_ENDORSEMENT_EXISTS: a live endorsement already exists on this policy';
  end if;
  if exists (select 1 from ins_policy_cancellations
              where policy_id = p_policy_id and status in ('proposed','prepared','posting','posted')) then
    raise exception 'INS_ENDORSEMENT_CXL_LIVE: this policy has a cancellation in flight; endorse it another day';
  end if;

  quote := ins_preview_policy_endorsement(p_policy_id, p_effective_date, p_insurer_terms, p_changes);
  insert into ins_policy_endorsements
    (tenant_id, policy_id, request_key, reason, effective_date, insurer_terms, changes, proposed_by, calculation)
  values
    (get_my_tenant_id(), p_policy_id, p_request_key, btrim(p_reason), p_effective_date,
     p_insurer_terms, coalesce(p_changes, '{}'::jsonb), auth.uid(), quote)
  returning * into e;
  insert into ins_policy_endorsement_events(tenant_id, endorsement_id, event, actor_id)
    values (e.tenant_id, e.id, 'proposed', auth.uid());
  return e;
end $function$;
revoke all on function public.ins_propose_policy_endorsement(uuid, date, jsonb, jsonb, text, uuid) from public, anon;
grant execute on function public.ins_propose_policy_endorsement(uuid, date, jsonb, jsonb, text, uuid) to authenticated;

create or replace function public.ins_withdraw_policy_endorsement(p_endorsement_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  e ins_policy_endorsements%rowtype;
  pid uuid;
begin
  if auth.uid() is null or effective_user_id() is distinct from auth.uid()
     or not (can_manage_insurance() or is_finance_team_member('finance')) then
    raise exception 'INS_FORBIDDEN: acting identity and current role required' using errcode = '42501';
  end if;
  select policy_id into pid from ins_policy_endorsements
   where id = p_endorsement_id and tenant_id = get_my_tenant_id();
  if not found then
    raise exception 'INS_NOT_FOUND: endorsement';
  end if;
  perform id from ins_policies where id = pid for update;
  select * into e from ins_policy_endorsements where id = p_endorsement_id for update;
  if e.proposed_by <> auth.uid() or e.status not in ('proposed','prepared')
     or length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception 'INS_ENDORSEMENT_WITHDRAW: proposer, open case and reason required';
  end if;
  update ins_policy_endorsements set status = 'withdrawn', review_note = btrim(p_reason) where id = e.id;
  insert into ins_policy_endorsement_events(tenant_id, endorsement_id, event, actor_id, detail)
    values (e.tenant_id, e.id, 'withdrawn', auth.uid(), jsonb_build_object('reason', p_reason));
end $function$;
revoke all on function public.ins_withdraw_policy_endorsement(uuid, text) from public, anon;
grant execute on function public.ins_withdraw_policy_endorsement(uuid, text) to authenticated;

-- =============================================================================
-- E. The review position: the policy plus its posted endorsements
--    ("current" values are computed, never written back -- D2)
-- =============================================================================
create or replace function public.ins_endorsement_review_position(p_policy_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  p ins_policies%rowtype;
  v_gross numeric;
  v_commission numeric;
  v_sum_insured numeric;
  v_live jsonb;
  v_posted integer;
  v_cxl_live boolean;
  r record;
  c record;
begin
  if auth.uid() is null or not (can_access_insurance() or is_finance_team_member('finance')) then
    raise exception 'INS_FORBIDDEN' using errcode = '42501';
  end if;
  select * into p from ins_policies where id = p_policy_id and tenant_id = get_my_tenant_id();
  if not found then
    raise exception 'INS_NOT_FOUND: policy';
  end if;
  v_gross := p.gross_premium;
  v_commission := p.commission_amount;
  v_sum_insured := p.sum_insured;
  v_posted := 0;
  for r in
    select calculation
      from ins_policy_endorsements
     where policy_id = p.id and tenant_id = p.tenant_id and status = 'posted'
     order by posting_date nulls last, proposed_at
  loop
    v_posted := v_posted + 1;
    v_gross := v_gross + coalesce((r.calculation ->> 'premium_delta')::numeric, 0);
    v_commission := v_commission + coalesce((r.calculation ->> 'commission_delta')::numeric, 0);
    -- The latest posted change to sum_insured wins.
    if r.calculation -> 'changes' <> '[]'::jsonb then
      for c in select * from jsonb_array_elements(r.calculation -> 'changes') where value ->> 'field' = 'sum_insured' loop
        v_sum_insured := (c.value ->> 'after')::numeric;
      end loop;
    end if;
  end loop;
  select jsonb_agg(to_jsonb(x)) into v_live
    from ins_policy_endorsements x
   where x.policy_id = p.id and x.tenant_id = p.tenant_id and x.status in ('proposed','prepared');
  select exists (
    select 1 from ins_policy_cancellations
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
end $function$;
revoke all on function public.ins_endorsement_review_position(uuid) from public, anon;
grant execute on function public.ins_endorsement_review_position(uuid) to authenticated;

-- =============================================================================
-- F. Cross-pipeline guards: an endorsement and a cancellation cannot be live
--    on the same policy. Triggers, so the legacy function bodies stand.
-- =============================================================================
create or replace function public.ins_endorsement_cross_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if tg_table_name = 'ins_policy_cancellations' then
    if new.status in ('proposed','prepared','posting') and exists (
      select 1 from ins_policy_endorsements
       where policy_id = new.policy_id and status in ('proposed','prepared','posting')
    ) then
      raise exception 'INS_ENDORSEMENT_LIVE: finish or withdraw the live endorsement before cancelling this policy';
    end if;
  else
    if new.status in ('proposed','prepared','posting') and exists (
      select 1 from ins_policy_cancellations
       where policy_id = new.policy_id and status in ('proposed','prepared','posting','posted')
    ) then
      raise exception 'INS_CANCELLATION_LIVE: this policy has a cancellation in flight; endorse it another day';
    end if;
  end if;
  return new;
end $function$;
revoke all on function public.ins_endorsement_cross_guard() from public, anon, authenticated, service_role;

drop trigger if exists ins_endorsement_blocks_cancellation on public.ins_policy_cancellations;
create trigger ins_endorsement_blocks_cancellation
  before insert on public.ins_policy_cancellations
  for each row execute function public.ins_endorsement_cross_guard();

drop trigger if exists ins_cancellation_blocks_endorsement on public.ins_policy_endorsements;
create trigger ins_cancellation_blocks_endorsement
  before insert on public.ins_policy_endorsements
  for each row execute function public.ins_endorsement_cross_guard();

-- A policy with a live endorsement cannot start a renewal.
create or replace function public.ins_create_renewal_draft(p_policy_id uuid)
returns public.ins_policies
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare p ins_policies%rowtype;
begin
  if exists (
    select 1 from ins_policy_endorsements
     where policy_id = p_policy_id and status in ('proposed','prepared','posting')
  ) then
    raise exception 'INS_ENDORSEMENT_LIVE: finish or withdraw the live endorsement before renewing this policy';
  end if;
  p := platform_ins_create_renewal_legacy_impl(p_policy_id);
  insert into ins_policy_insurer_shares(tenant_id,policy_id,insurer_id,is_lead,share_pct,commission_rate_pct,insurer_policy_no,reviewed)
  select tenant_id,p.id,insurer_id,is_lead,share_pct,commission_rate_pct,insurer_policy_no,false from ins_policy_insurer_shares where policy_id=p_policy_id;
  insert into ins_policy_charges(tenant_id,policy_id,kind,description,amount,recipient_mode,recipient_insurer_id,vat_mode,vat_rate_pct,income_gl_account_id,reviewed)
  select tenant_id,p.id,kind,description,null,recipient_mode,recipient_insurer_id,vat_mode,vat_rate_pct,income_gl_account_id,false from ins_policy_charges where policy_id=p_policy_id;
  return p;
end $function$;
revoke all on function public.ins_create_renewal_draft(uuid) from public, anon;
grant execute on function public.ins_create_renewal_draft(uuid) to authenticated;
