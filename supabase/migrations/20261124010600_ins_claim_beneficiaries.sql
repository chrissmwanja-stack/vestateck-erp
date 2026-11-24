-- =====================================================================
-- Beneficiaries, death claims and instalment settlements
-- Accountant pack v2, decision 3 (B10); pack section 7.4-7.6
-- =====================================================================
-- The pack asks for four things:
--
--   * authorised representatives may report a claim after the policyholder dies;
--   * multiple beneficiaries on percentage OR fixed allocations, percentages
--     totalling 100%;
--   * a disputed share is HELD while undisputed shares proceed, and disputed shares
--     are never redistributed automatically;
--   * instalments each carry their own expected date, actual date, amount and
--     evidence, and a later receipt settles the existing approved balance rather
--     than creating fresh recognition.
--
-- Two design points worth review.
--
-- 1. THE HELD SHARE IS ENFORCED BY A DEFERRED CONSTRAINT TRIGGER, not only in the
--    payout function. The claim has ONE open item (source_type 'ins_claim_client'),
--    so allotments are not separate payable balances to be paid individually --
--    they are a claim on the single balance owed to the estate. What must be true
--    is that cumulative payouts never exceed the sum of the shares that are
--    actually payable (not held, not disputed). A CHECK cannot see the payment
--    table, and a statement-level AFTER check would fire before the payments rows
--    inserted later in the same function are visible, so this is a CONSTRAINT
--    TRIGGER DEFERRABLE INITIALLY DEFERRED: it sees the whole transaction and
--    raises if the rule is broken by the time it commits.
--
-- 2. THE AMOUNT PAYABLE IS RECOMPUTED FROM LIVE SHARES on every change to the
--    allotment, because a percentage change moves the payable total without
--    touching the payment table. So changing a percentage re-runs the same check
--    and refuses if past payouts have already gone beyond the new payable figure.
--    That is what stops a "disputed share" being quietly nullified by editing the
--    percentages after the money went out.
--
-- Why 100%: pack 7.5 says percentages must total 100. A death benefit that does not
-- allocate in full would leave an amount nobody is entitled to. Percentages and
-- fixed amounts may be mixed; the total must equal the resolved claim amount either
-- way, which is checked when the claim is approved and when an allotment changes.

-- ---------------------------------------------------------------------
-- 1. Death claim record
-- ---------------------------------------------------------------------
alter table ins_claims
  add column if not exists claim_type text not null default 'standard',
  add column if not exists deceased_on date,
  add column if not exists representative_name text,
  add column if not exists representative_relationship text,
  add column if not exists representative_contact text,
  add column if not exists representative_authority text;

alter table ins_claims drop constraint if exists ins_claims_claim_type_check;
alter table ins_claims add constraint ins_claims_claim_type_check
  check (claim_type in ('standard', 'death'));

-- A death claim without a representative is a claim nobody has authority to make.
alter table ins_claims drop constraint if exists ins_claims_death_check;
alter table ins_claims add constraint ins_claims_death_check
  check (claim_type <> 'death'
         or (deceased_on is not null
             and representative_name is not null
             and length(btrim(representative_name)) >= 2
             and representative_authority is not null
             and length(btrim(representative_authority)) >= 5));

comment on column ins_claims.claim_type is
  'standard or death. A death claim must name the authorised representative and the authority relied on (pack v2 section 7.4).';
comment on column ins_claims.representative_authority is
  'What makes the representative authorised: grant of probate, letters of administration, written mandate. Free text, kept because it is evidence.';

-- ---------------------------------------------------------------------
-- 2. Beneficiary allotments
-- ---------------------------------------------------------------------
create table if not exists ins_claim_beneficiaries (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references tenants(id) on delete cascade,
  claim_id       uuid not null references ins_claims(id) on delete cascade,
  beneficiary_no integer not null,
  name           text not null,
  relationship   text,
  contact        text,
  share_pct      numeric check (share_pct is null or (share_pct > 0 and share_pct <= 100)),
  fixed_amount   numeric check (fixed_amount is null or fixed_amount > 0),
  currency       char(3),
  -- held: the share is disputed or awaiting legal determination, and is NOT payable
  status         text not null default 'payable' check (status in ('payable', 'held', 'paid')),
  held_reason    text,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint ins_claim_beneficiaries_no_check unique (tenant_id, claim_id, beneficiary_no),
  constraint ins_claim_beneficiaries_name_check check (length(btrim(name)) >= 2),
  -- exactly one way of stating the share
  constraint ins_claim_beneficiaries_share_check
    check ((share_pct is null) <> (fixed_amount is null)),
  constraint ins_claim_beneficiaries_currency_check
    check ((fixed_amount is null) = (currency is null)),
  -- a held share must say why
  constraint ins_claim_beneficiaries_held_check
    check (status <> 'held' or (held_reason is not null and length(btrim(held_reason)) >= 5))
);

create index if not exists ins_claim_beneficiaries_claim_idx
  on ins_claim_beneficiaries (tenant_id, claim_id);

alter table ins_claim_beneficiaries enable row level security;

drop policy if exists ins_claim_beneficiaries_read on ins_claim_beneficiaries;
create policy ins_claim_beneficiaries_read on ins_claim_beneficiaries
  for select to authenticated using (tenant_id = get_my_tenant_id());

revoke insert, update, delete on ins_claim_beneficiaries from authenticated, anon;

comment on table ins_claim_beneficiaries is
  'Pack v2 section 7.5. Percentage or fixed allotments, totalling the resolved claim amount. status = held means disputed, and a held share is never payable and never redistributed.';

-- ---------------------------------------------------------------------
-- 3. Instalment schedule
-- ---------------------------------------------------------------------
create table if not exists ins_claim_instalments (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references tenants(id) on delete cascade,
  claim_id          uuid not null references ins_claims(id) on delete cascade,
  instalment_no     integer not null,
  expected_on       date not null,
  amount            numeric not null check (amount > 0),
  currency          char(3),
  status            text not null default 'expected'
                    check (status in ('expected', 'paid', 'missed')),
  paid_on           date,
  paid_amount       numeric check (paid_amount is null or paid_amount > 0),
  evidence_ref      text,
  claim_payment_id  uuid references ins_claim_payments(id),
  notes             text,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  constraint ins_claim_instalments_no_check unique (tenant_id, claim_id, instalment_no),
  -- a paid instalment carries its date, its evidence and the payment that made it
  constraint ins_claim_instalments_paid_check
    check (status <> 'paid'
           or (paid_on is not null and paid_amount is not null
               and evidence_ref is not null and length(btrim(evidence_ref)) >= 2
               and claim_payment_id is not null))
);

create index if not exists ins_claim_instalments_claim_idx
  on ins_claim_instalments (tenant_id, claim_id, expected_on);

alter table ins_claim_instalments enable row level security;

drop policy if exists ins_claim_instalments_read on ins_claim_instalments;
create policy ins_claim_instalments_read on ins_claim_instalments
  for select to authenticated using (tenant_id = get_my_tenant_id());

revoke insert, update, delete on ins_claim_instalments from authenticated, anon;

comment on table ins_claim_instalments is
  'Pack v2 section 7.6. Each instalment carries its own expected date, actual date, amount and evidence. A later instalment reduces the existing approved balance; it never creates fresh claim recognition.';

-- ---------------------------------------------------------------------
-- 4. The payable total, from live allotments
-- ---------------------------------------------------------------------
-- Percentage shares are resolved against the claim's approved amount at the time of
-- asking, so changing the approval re-prices them. Fixed shares are taken as stated.
-- Held shares contribute nothing, which is what makes a disputed share genuinely
-- unavailable rather than merely flagged.
-- The core takes the tenant explicitly. A deferred constraint trigger can fire on a
-- connection with no session tenant (a migration, a service-role job), so deriving
-- the tenant from the session there would silently return no rows and make the
-- guard compare against zero. The public wrapper keeps the session-scoped form for
-- application callers.
create or replace function public.platform_ins_claim_beneficiary_payable(p_tenant_id uuid, p_claim_id uuid)
returns table (currency char(3), payable numeric, held numeric, total numeric)
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  with c as (
    select cl.id, cl.tenant_id, cl.approved_amount,
           -- ins_claims has no currency of its own: a claim belongs to a policy and the
           -- policy holds the currency. This read cl.currency, a column that was never
           -- created; because the body is validated at CREATE time, that typo stopped
           -- the whole migration from applying rather than failing quietly at call time.
           -- Source of truth is the same one ins_claim_beneficiary_instalments uses.
           p.currency
      from ins_claims cl
      join ins_policies p on p.id = cl.policy_id
     where cl.id = p_claim_id and cl.tenant_id = p_tenant_id
  ), b as (
    select bn.*,
           case when bn.share_pct is not null
                then round(coalesce(c.approved_amount, 0) * bn.share_pct / 100.0, 2)
                else bn.fixed_amount end as resolved
      from ins_claim_beneficiaries bn
      join c on c.id = bn.claim_id
     where bn.tenant_id = c.tenant_id
  )
  select c.currency,
         coalesce(sum(case when b.status = 'payable' then b.resolved else 0 end), 0) as payable,
         coalesce(sum(case when b.status = 'held' then b.resolved else 0 end), 0) as held,
         coalesce(sum(b.resolved), 0) as total
    from c left join b on true
   group by c.currency
$$;

create or replace function public.ins_claim_beneficiary_payable(p_claim_id uuid)
returns table (currency char(3), payable numeric, held numeric, total numeric)
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select * from public.platform_ins_claim_beneficiary_payable(get_my_tenant_id(), p_claim_id)
$$;

-- Percentage total: must be exactly 100 when any percentage share is used.
create or replace function public.ins_claim_beneficiary_percentage_total(p_claim_id uuid)
returns numeric
    language sql stable security definer
    set search_path to 'public', 'pg_temp'
    as $$
  select coalesce(sum(bn.share_pct), 0)
    from ins_claim_beneficiaries bn
    join ins_claims cl on cl.id = bn.claim_id and cl.tenant_id = bn.tenant_id
   where bn.claim_id = p_claim_id
     and cl.tenant_id = get_my_tenant_id()
     and bn.share_pct is not null
$$;

-- ---------------------------------------------------------------------
-- 5. Setting the allotments
-- ---------------------------------------------------------------------
-- Replaces the whole set in one go, because "percentages must total 100" is a
-- property of the set, not of a row. Any edit to a single row could break the total.
create or replace function public.ins_set_claim_beneficiaries(
  p_claim_id uuid,
  p_beneficiaries jsonb
) returns setof ins_claim_beneficiaries
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant  uuid := get_my_tenant_id();
  v_claim   ins_claims%rowtype;
  -- ins_claims carries no currency of its own: a claim belongs to a policy, and the
  -- policy holds the currency. Read from there rather than from a column that does
  -- not exist, which is how this was first written.
  v_ccy     text;
  v_elem    jsonb;
  v_no      integer := 0;
  v_pct_total numeric := 0;
  v_resolved numeric := 0;
  v_payroll numeric;
  v_paid    numeric;
  v_payable numeric;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: setting beneficiaries needs insurance manager authority' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims
   where id = p_claim_id and tenant_id = v_tenant for update;
  select p.currency into v_ccy from ins_policies p where p.id = v_claim.policy_id;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  if v_claim.status in ('settled', 'closed', 'repudiated') then
    raise exception 'INS_CLAIM_STATE: the beneficiaries of a % claim cannot be changed', v_claim.status;
  end if;
  if p_beneficiaries is null or jsonb_typeof(p_beneficiaries) <> 'array'
     or jsonb_array_length(p_beneficiaries) = 0 then
    raise exception 'INS_REQUIRED: give at least one beneficiary as a JSON array';
  end if;

  -- Money already paid out cannot be reallocated by editing shares.
  select coalesce(sum(amount), 0) into v_paid
    from ins_claim_payments
   where claim_id = v_claim.id and tenant_id = v_tenant
     and status = 'posted' and kind in ('client_payout', 'insurer_direct');

  perform set_config('ins.via_rpc', 'on', true);
  delete from ins_claim_beneficiaries where claim_id = v_claim.id and tenant_id = v_tenant;

  for v_elem in select * from jsonb_array_elements(p_beneficiaries) loop
    v_no := v_no + 1;
    if jsonb_typeof(v_elem) <> 'object' then
      raise exception 'INS_BENEFICIARY_SHAPE: each beneficiary must be an object';
    end if;
    insert into ins_claim_beneficiaries (
      tenant_id, claim_id, beneficiary_no, name, relationship, contact,
      share_pct, fixed_amount, currency, status, held_reason, created_by
    ) values (
      v_tenant, v_claim.id, v_no,
      btrim(coalesce(v_elem ->> 'name', '')),
      nullif(btrim(coalesce(v_elem ->> 'relationship', '')), ''),
      nullif(btrim(coalesce(v_elem ->> 'contact', '')), ''),
      nullif(v_elem ->> 'share_pct', '')::numeric,
      nullif(v_elem ->> 'fixed_amount', '')::numeric,
      case when nullif(v_elem ->> 'fixed_amount', '') is not null
           then coalesce(nullif(v_elem ->> 'currency', ''), v_ccy) end,
      coalesce(nullif(v_elem ->> 'status', ''), 'payable'),
      nullif(btrim(coalesce(v_elem ->> 'held_reason', '')), ''),
      auth.uid()
    );
  end loop;

  select coalesce(sum(share_pct), 0) into v_pct_total
    from ins_claim_beneficiaries
   where claim_id = v_claim.id and tenant_id = v_tenant and share_pct is not null;

  if v_pct_total > 0 and v_pct_total <> 100 then
    raise exception 'INS_BENEFICIARY_TOTAL: percentage shares must total 100%%, they total %', v_pct_total;
  end if;

  -- The allotments must dispose of the whole approved amount: a death benefit that
  -- allocates only part of itself leaves an amount nobody is entitled to.
  select coalesce(sum(case when share_pct is not null
                           then round(coalesce(v_claim.approved_amount, 0) * share_pct / 100.0, 2)
                           else fixed_amount end), 0)
    into v_resolved
    from ins_claim_beneficiaries
   where claim_id = v_claim.id and tenant_id = v_tenant;

  if coalesce(v_claim.approved_amount, 0) > 0 and v_resolved <> v_claim.approved_amount then
    raise exception 'INS_BENEFICIARY_TOTAL: the allotments total % but the approved claim is %; they must be equal',
      v_resolved, v_claim.approved_amount;
  end if;

  -- Editing shares must not retrospectively make past payments exceed what is now
  -- payable -- that is how a disputed share gets quietly nullified after the money
  -- has gone out.
  select payable into v_payable from public.platform_ins_claim_beneficiary_payable(v_tenant, v_claim.id);
  if v_paid > coalesce(v_payable, 0) then
    raise exception 'INS_BENEFICIARY_HELD: % has already been paid out, but only % is payable after this change; a held or disputed share cannot be reduced below what has been paid',
      v_paid, coalesce(v_payable, 0);
  end if;

  return query select * from ins_claim_beneficiaries
                where claim_id = v_claim.id and tenant_id = v_tenant
                order by beneficiary_no;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. The held-share guarantee
-- ---------------------------------------------------------------------
-- Deferred, so it sees the payments inserted later in the same transaction.
create or replace function public.ins_claim_beneficiary_payout_guard() returns trigger
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_claim  uuid;
  v_tenant uuid;
  v_paid   numeric;
  v_payable numeric;
  v_has    boolean;
begin
  v_claim := coalesce(new.claim_id, old.claim_id);

  -- Tenant from the claim itself: a deferred trigger may run with no session tenant.
  select cl.tenant_id into v_tenant from ins_claims cl where cl.id = v_claim;
  if v_tenant is null then
    return null;
  end if;

  select exists (select 1 from ins_claim_beneficiaries
                  where claim_id = v_claim and tenant_id = v_tenant)
    into v_has;
  if not v_has then
    return null;  -- no allotments set: nothing to police, ordinary claim behaviour
  end if;

  select pp.payable into v_payable
    from public.platform_ins_claim_beneficiary_payable(v_tenant, v_claim) pp;
  select coalesce(sum(p.amount), 0) into v_paid
    from ins_claim_payments p
   where p.claim_id = v_claim
     and p.tenant_id = v_tenant
     and p.status = 'posted'
     and p.kind in ('client_payout', 'insurer_direct');

  if v_paid > coalesce(v_payable, 0) then
    raise exception 'INS_BENEFICIARY_HELD: payouts to this claim total % but only % is payable; % is held or disputed and cannot be paid out',
      v_paid, coalesce(v_payable, 0), round(v_paid - coalesce(v_payable, 0), 2);
  end if;
  return null;
end;
$$;

drop trigger if exists trg_ins_claim_beneficiary_payment on ins_claim_payments;
create constraint trigger trg_ins_claim_beneficiary_payment
  after insert or update on ins_claim_payments
  deferrable initially deferred
  for each row execute function ins_claim_beneficiary_payout_guard();

drop trigger if exists trg_ins_claim_beneficiary_allotment on ins_claim_beneficiaries;
create constraint trigger trg_ins_claim_beneficiary_allotment
  after insert or update or delete on ins_claim_beneficiaries
  deferrable initially deferred
  for each row execute function ins_claim_beneficiary_payout_guard();

-- ---------------------------------------------------------------------
-- 7. Death claims
-- ---------------------------------------------------------------------
create or replace function public.ins_record_death_claim(
  p_policy_id uuid,
  p_loss_date date,
  p_notified_date date,
  p_description text,
  p_deceased_on date,
  p_representative_name text,
  p_representative_relationship text,
  p_representative_contact text,
  p_representative_authority text,
  p_reserve_amount numeric default 0
) returns ins_claims
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_row ins_claims%rowtype;
begin
  if not can_access_insurance() then
    raise exception 'INS_FORBIDDEN: insurance access required' using errcode = '42501';
  end if;
  if p_deceased_on is null then
    raise exception 'INS_REQUIRED: record the date of death';
  end if;
  if p_deceased_on > public.business_today() then
    raise exception 'INS_CLAIM_DATES: the date of death cannot be in the future';
  end if;
  if nullif(btrim(p_representative_authority), '') is null then
    raise exception 'INS_REQUIRED: record what authorises the representative (probate, letters of administration, written mandate)';
  end if;

  -- A death claim is registered through the ordinary path, so every existing rule
  -- (bound policy, loss date, audit trail) still applies, then type and
  -- representative are recorded. The notification date defaults to the date of
  -- death for the loss-date check when the representative reports later.
  v_row := public.ins_create_claim(
    p_policy_id, p_loss_date, p_notified_date, p_description, null, p_reserve_amount);

  perform set_config('ins.via_rpc', 'on', true);
  update ins_claims
     set claim_type = 'death',
         deceased_on = p_deceased_on,
         representative_name = btrim(p_representative_name),
         representative_relationship = nullif(btrim(p_representative_relationship), ''),
         representative_contact = nullif(btrim(p_representative_contact), ''),
         representative_authority = btrim(p_representative_authority)
   where id = v_row.id
  returning * into v_row;

  insert into ins_claim_events (tenant_id, claim_id, from_status, to_status, note)
  values (v_row.tenant_id, v_row.id, 'notified', 'notified',
          'Registered as a death claim. Representative: ' || v_row.representative_name
          || ' (' || v_row.representative_authority || ')');
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. Instalments
-- ---------------------------------------------------------------------
create or replace function public.ins_schedule_claim_instalments(
  p_claim_id uuid,
  p_instalments jsonb
) returns setof ins_claim_instalments
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_claim  ins_claims%rowtype;
  v_ccy    text;
  v_elem   jsonb;
  v_no     integer := 0;
  v_sum    numeric := 0;
  v_paid   numeric;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: scheduling instalments needs insurance manager authority' using errcode = '42501';
  end if;
  select * into v_claim from ins_claims
   where id = p_claim_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: claim';
  end if;
  -- Currency lives on the policy, not on the claim. See the note in ins_set_claim_beneficiaries.
  select p.currency into v_ccy from ins_policies p where p.id = v_claim.policy_id;
  if v_claim.recognised_at is null then
    raise exception 'INS_CLAIM_NOT_RECOGNISED: recognise the claim before scheduling instalments against it';
  end if;
  if p_instalments is null or jsonb_typeof(p_instalments) <> 'array'
     or jsonb_array_length(p_instalments) = 0 then
    raise exception 'INS_REQUIRED: give at least one instalment';
  end if;

  select coalesce(sum(amount), 0) into v_paid
    from ins_claim_payments
   where claim_id = v_claim.id and tenant_id = v_tenant
     and status = 'posted' and kind in ('client_payout', 'insurer_direct');

  perform set_config('ins.via_rpc', 'on', true);
  -- Only unpaid instalments may be replaced; a paid one is evidence.
  delete from ins_claim_instalments
   where claim_id = v_claim.id and tenant_id = v_tenant and status <> 'paid';

  for v_elem in select * from jsonb_array_elements(p_instalments) loop
    v_no := v_no + 1;
    if jsonb_typeof(v_elem) <> 'object'
       or nullif(v_elem ->> 'expected_on', '') is null
       or nullif(v_elem ->> 'amount', '') is null then
      raise exception 'INS_INSTALMENT_SHAPE: each instalment needs an expected_on date and an amount';
    end if;
    v_sum := v_sum + (v_elem ->> 'amount')::numeric;
    insert into ins_claim_instalments (
      tenant_id, claim_id, instalment_no, expected_on, amount, currency, notes, created_by
    ) values (
      v_tenant, v_claim.id, v_no, (v_elem ->> 'expected_on')::date,
      (v_elem ->> 'amount')::numeric, v_ccy,
      nullif(btrim(coalesce(v_elem ->> 'notes', '')), ''), auth.uid()
    );
  end loop;

  -- The schedule must add up to what is still owed, not to the original approval:
  -- instalments settle the existing balance rather than re-recognising it.
  if v_sum <> coalesce(v_claim.approved_amount, 0) - v_paid then
    raise exception 'INS_INSTALMENT_TOTAL: instalments total % but % is still outstanding on this claim',
      v_sum, coalesce(v_claim.approved_amount, 0) - v_paid;
  end if;

  return query select * from ins_claim_instalments
                where claim_id = v_claim.id and tenant_id = v_tenant
                order by instalment_no;
end;
$$;

-- Paying an instalment: the payment is the ordinary payout, so the anti-fronting
-- check and the held-share check both apply; this only records which instalment it
-- settled and its evidence.
create or replace function public.ins_pay_claim_instalment(
  p_instalment_id uuid,
  p_bank_account_id uuid,
  p_payment_date date,
  p_reference text,
  p_evidence_ref text,
  p_notes text default null::text
) returns ins_claim_instalments
    language plpgsql security definer
    set search_path to 'public', 'pg_temp'
    as $$
declare
  v_tenant uuid := get_my_tenant_id();
  v_inst   ins_claim_instalments%rowtype;
  v_pay    ins_claim_payments%rowtype;
begin
  if not can_manage_insurance() then
    raise exception 'INS_FORBIDDEN: paying an instalment needs insurance manager authority' using errcode = '42501';
  end if;
  if nullif(btrim(p_evidence_ref), '') is null then
    raise exception 'INS_REQUIRED: record the payment evidence for the instalment';
  end if;

  select * into v_inst from ins_claim_instalments
   where id = p_instalment_id and tenant_id = v_tenant for update;
  if not found then
    raise exception 'INS_NOT_FOUND: instalment';
  end if;
  if v_inst.status = 'paid' then
    raise exception 'INS_INSTALMENT_PAID: instalment % has already been paid', v_inst.instalment_no;
  end if;

  -- The payout itself: all its guards (approved, recognised, funded by the insurer,
  -- client-money bank, held shares) apply unchanged.
  v_pay := public.ins_record_claim_payout(
    v_inst.claim_id, p_bank_account_id, v_inst.amount, p_payment_date, p_reference, p_notes);

  perform set_config('ins.via_rpc', 'on', true);
  update ins_claim_instalments
     set status = 'paid',
         paid_on = p_payment_date,
         paid_amount = v_pay.amount,
         evidence_ref = btrim(p_evidence_ref),
         claim_payment_id = v_pay.id
   where id = v_inst.id
  returning * into v_inst;

  return v_inst;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Exposure
-- ---------------------------------------------------------------------
revoke all on function public.ins_claim_beneficiary_payout_guard() from public, anon, authenticated, service_role;
revoke all on function public.platform_ins_claim_beneficiary_payable(uuid, uuid) from public, anon, authenticated;
revoke all on function public.ins_claim_beneficiary_payable(uuid) from public, anon;
revoke all on function public.ins_claim_beneficiary_percentage_total(uuid) from public, anon;
revoke all on function public.ins_set_claim_beneficiaries(uuid, jsonb) from public, anon;
revoke all on function public.ins_record_death_claim(uuid, date, date, text, date, text, text, text, text, numeric) from public, anon;
revoke all on function public.ins_schedule_claim_instalments(uuid, jsonb) from public, anon;
revoke all on function public.ins_pay_claim_instalment(uuid, uuid, date, text, text, text) from public, anon;

grant execute on function public.ins_claim_beneficiary_payable(uuid) to authenticated;
grant execute on function public.ins_claim_beneficiary_percentage_total(uuid) to authenticated;
grant execute on function public.ins_set_claim_beneficiaries(uuid, jsonb) to authenticated;
grant execute on function public.ins_record_death_claim(uuid, date, date, text, date, text, text, text, text, numeric) to authenticated;
grant execute on function public.ins_schedule_claim_instalments(uuid, jsonb) to authenticated;
grant execute on function public.ins_pay_claim_instalment(uuid, uuid, date, text, text, text) to authenticated;

select public.apply_tenant_read_only_guard();

grant select on ins_claim_beneficiaries, ins_claim_instalments to authenticated;
