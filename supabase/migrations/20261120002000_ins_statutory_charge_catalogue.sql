-- =====================================================================
-- Statutory charge catalogue (owner item 4)
-- =====================================================================
-- Charges are currently free text on the policy: a description, an amount and
-- a "pass-through or broker fee" flag. That is enough to bill a client and not
-- enough to account for a levy, because nothing records what class of charge it
-- is, who collects it, who receives it, which account it is payable to, what it
-- is exempt from, or which version of the law set the rate. The owner's five
-- rules are implemented here:
--
--   1. statutory taxes, statutory levies, regulatory contributions and
--      commercial fees are separate classes, not one "fee" bucket;
--   2. verified Uganda charges are seeded; unverified ones are seeded INACTIVE
--      so they are visible for review and cannot be billed;
--   3. basis, class, exemptions, collector, recipient and payable account are
--      NOT NULL: a charge that cannot say all six is not a chargeable charge;
--   4. every charge is versioned and immutable once used, and each policy charge
--      keeps a snapshot of the version it was billed under;
--   5. the resolver is the single place issuance, endorsements, cancellations,
--      receipts, remittances and reports price a statutory charge from.
--
-- Rule 5 is only partly delivered: see the integration note at the foot of this
-- file. The catalogue and the resolver are the parts everything else needs.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The catalogue
-- ---------------------------------------------------------------------
create table if not exists public.ins_charge_catalogue (
  id uuid primary key default gen_random_uuid(),
  -- A null tenant means the statutory default that every company inherits; a
  -- company may add its own commercial fees, and may not override a statute.
  tenant_id uuid references public.tenants(id) on delete cascade,
  code text not null,
  name text not null,
  charge_class text not null,
  -- How the amount is computed. Percentages are held separately from the base
  -- so a rate change is a new version, never an edit.
  basis text not null,
  rate_pct numeric(9, 6),
  fixed_amount numeric(18, 2),
  currency text,
  -- Rule 3: who collects it and who receives it are different questions. The
  -- collector takes the money from the client; the recipient is entitled to it.
  collector text not null,
  recipient_name text not null,
  recipient_kind text not null,
  -- Rule 3: the account it is payable to, by posting role. Checked against the
  -- company's posting rules when a charge is resolved, not when this row is
  -- written, because a company configures its ledger after its first policy.
  payable_role text not null,
  -- Rule 3: exemptions are part of the charge, not an annotation.
  exemptions jsonb not null default '[]'::jsonb,
  applies_to_product_lines text[],
  -- Rule 2: what makes a charge billable is that its rate was verified against
  -- an instrument, not that someone entered it.
  verification_status text not null default 'unverified',
  source_reference text,
  verified_by uuid references public.app_users(id),
  verified_at timestamptz,
  effective_from date not null,
  effective_to date,
  -- Rule 4: one version per rate, linked backwards. A change is a new row.
  version integer not null default 1,
  supersedes_id uuid references public.ins_charge_catalogue(id),
  is_active boolean not null default true,
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  constraint ins_charge_catalogue_class_check
    check (charge_class in ('statutory_tax', 'statutory_levy', 'regulatory_contribution', 'commercial_fee')),
  constraint ins_charge_catalogue_basis_check
    check (basis in ('percent_of_gross_premium', 'percent_of_net_premium',
                     'percent_of_commission', 'fixed_per_policy', 'fixed_per_vehicle')),
  constraint ins_charge_catalogue_amount_check
    check ((basis like 'percent%' and rate_pct is not null and rate_pct >= 0 and rate_pct <= 100
            and fixed_amount is null)
        or (basis like 'fixed%' and fixed_amount is not null and fixed_amount >= 0 and currency is not null
            and rate_pct is null)),
  constraint ins_charge_catalogue_collector_check
    check (collector in ('insurer', 'broker', 'intermediary')),
  constraint ins_charge_catalogue_recipient_check
    check (recipient_kind in ('government', 'regulator', 'statutory_body', 'insurer', 'broker')),
  constraint ins_charge_catalogue_verified_check
    check (verification_status in ('verified', 'unverified', 'withdrawn')),
  -- A verified rate must say what verified it. This is the integrity rule that
  -- stops "verified" becoming an opinion.
  constraint ins_charge_catalogue_provenance_check
    check (verification_status <> 'verified'
           or (source_reference is not null and length(btrim(source_reference)) >= 10
               and verified_at is not null)),
  constraint ins_charge_catalogue_window_check
    check (effective_to is null or effective_to >= effective_from),
  constraint ins_charge_catalogue_code_unique unique (tenant_id, code, version)
);

comment on table public.ins_charge_catalogue is
  'Versioned statutory and commercial charges. A statutory rate is a fact about the law, so a row is never edited once used: end-date it and add a version.';
comment on column public.ins_charge_catalogue.tenant_id is
  'Null for a statutory charge every company inherits; set for a company commercial fee.';
comment on column public.ins_charge_catalogue.verification_status is
  'unverified: entered from an unconfirmed source, cannot be billed. verified: rate checked against source_reference.';

create index if not exists ins_charge_catalogue_lookup
  on public.ins_charge_catalogue (code, effective_from desc, version desc);
create index if not exists ins_charge_catalogue_tenant
  on public.ins_charge_catalogue (tenant_id) where tenant_id is not null;

-- Rule 4: immutable once used. "Used" means a policy charge points at the row.
create or replace function public.ins_charge_catalogue_guard()
returns trigger language plpgsql
set search_path to 'public', 'pg_temp'
as $$
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from public.ins_policy_charges c where c.catalogue_id = old.id) then
      raise exception 'INS_CHARGE_CATALOGUE_USED: this charge has been billed; end-date it instead of deleting it'
        using errcode = '23514';
    end if;
    return old;
  end if;

  if exists (select 1 from public.ins_policy_charges c where c.catalogue_id = old.id) then
    -- Versioning fields and the retirement fields may still move: that is how a
    -- charge is withdrawn without rewriting history.
    if new.code is distinct from old.code
       or new.charge_class is distinct from old.charge_class
       or new.basis is distinct from old.basis
       or new.rate_pct is distinct from old.rate_pct
       or new.fixed_amount is distinct from old.fixed_amount
       or new.currency is distinct from old.currency
       or new.collector is distinct from old.collector
       or new.recipient_name is distinct from old.recipient_name
       or new.recipient_kind is distinct from old.recipient_kind
       or new.payable_role is distinct from old.payable_role
       or new.exemptions is distinct from old.exemptions
       or new.effective_from is distinct from old.effective_from then
      raise exception 'INS_CHARGE_CATALOGUE_IMMUTABLE: charge % v% has been billed; add a new version rather than changing the rate, class, basis, recipient, payable account, exemptions or start date', old.code, old.version
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

-- The hardening tests require trigger functions to be locked down like any
-- other: a trigger firing under the table owner must not also be an RPC anon
-- can call.
revoke all on function public.ins_charge_catalogue_guard() from public, anon, authenticated;

drop trigger if exists ins_charge_catalogue_guard on public.ins_charge_catalogue;
create trigger ins_charge_catalogue_guard
  before update or delete on public.ins_charge_catalogue
  for each row execute function public.ins_charge_catalogue_guard();

-- ---------------------------------------------------------------------
-- 1b. Access, following the rest of the insurance module
-- ---------------------------------------------------------------------
alter table public.ins_charge_catalogue enable row level security;

-- A statutory row (tenant_id null) is readable by every insurance user, because
-- every company inherits it; a company's own fee only by that company.
drop policy if exists ins_charge_catalogue_select on public.ins_charge_catalogue;
create policy ins_charge_catalogue_select on public.ins_charge_catalogue
  for select to authenticated using (
    can_access_insurance()
    and (tenant_id is null or tenant_id = get_my_tenant_id())
  );

drop policy if exists ins_charge_catalogue_insert on public.ins_charge_catalogue;
create policy ins_charge_catalogue_insert on public.ins_charge_catalogue
  for insert to authenticated with check (
    can_manage_insurance() and tenant_id = get_my_tenant_id()
  );

drop policy if exists ins_charge_catalogue_update on public.ins_charge_catalogue;
create policy ins_charge_catalogue_update on public.ins_charge_catalogue
  for update to authenticated using (
    can_manage_insurance() and tenant_id = get_my_tenant_id()
  ) with check (
    can_manage_insurance() and tenant_id = get_my_tenant_id()
  );

-- No delete policy: retirement is is_active = false or an end date. The guard
-- trigger refuses a delete once a charge has been billed; this refuses it
-- always, so the two agree rather than one being a backstop for the other.

-- The tenant read-only lock every insurance table carries.
select public.apply_tenant_read_only_guard();

-- ---------------------------------------------------------------------
-- 2. Policy charges remember which version they were billed under
-- ---------------------------------------------------------------------
alter table public.ins_policy_charges
  add column if not exists catalogue_id uuid references public.ins_charge_catalogue(id),
  add column if not exists charge_class text,
  add column if not exists catalogue_version integer,
  add column if not exists collector text,
  add column if not exists recipient_name text,
  add column if not exists payable_role text,
  -- Rule 4's second half: the historical policy keeps the figures it was billed
  -- at, so a later rate change cannot restate an old policy.
  add column if not exists catalogue_snapshot jsonb;

comment on column public.ins_policy_charges.catalogue_snapshot is
  'The catalogue row as it stood when this charge was billed. Rule 4: a policy snapshot is never re-derived from the live catalogue.';

create index if not exists ins_policy_charges_catalogue
  on public.ins_policy_charges (catalogue_id) where catalogue_id is not null;

-- A charge stamped with a catalogue version must carry the snapshot too, and
-- its class must agree with the catalogue row it came from. Free-text legacy
-- charges remain legal (catalogue_id null) so existing policies stay valid.
alter table public.ins_policy_charges
  drop constraint if exists ins_policy_charges_catalogue_consistency_check;
alter table public.ins_policy_charges
  add constraint ins_policy_charges_catalogue_consistency_check
  check (catalogue_id is null
         or (charge_class is not null and catalogue_version is not null
             and catalogue_snapshot is not null
             and payable_role is not null and collector is not null
             and recipient_name is not null));

-- ---------------------------------------------------------------------
-- 3. Seed the Uganda charges
-- ---------------------------------------------------------------------
-- Rule 2. The training levy is verified against a statutory instrument that
-- states the rate in words. The IRA levy and the fixed stamp duty are widely
-- described in the press at 1.5% and UGX 35,000 and neither figure could be
-- confirmed against an instrument in this pass, so both are seeded with
-- verification_status unverified and is_active false: visible to the accountant,
-- impossible to bill until someone confirms them.
insert into public.ins_charge_catalogue
  (tenant_id, code, name, charge_class, basis, rate_pct, fixed_amount, currency,
   collector, recipient_name, recipient_kind, payable_role, exemptions,
   verification_status, source_reference, verified_at, effective_from, is_active, notes)
values
  (null, 'UG_INSURANCE_TRAINING_LEVY',
   'Insurance Training Levy', 'statutory_levy', 'percent_of_gross_premium', 0.5, null, null,
   'insurer', 'Insurance Training College', 'statutory_body', 'insurance_training_levy_payable',
   '[{"exemption":"none known","note":"charged on the insuring client"}]'::jsonb,
   'verified',
   'Insurance Act 2017 s.141(3); Insurance Training College Regulations 2020 (SI No. 100 of 2020), reg. 17(2): "the rate of the insurance training levy shall be 0.5 percent of gross direct premium written by persons licensed under the Act"',
   now(), '2020-08-14', true,
   'Seed-verified. 0.5% of gross direct premium, charged to the client and remitted quarterly to the College.'),

  (null, 'UG_IRA_LEVY',
   'IRA regulatory levy', 'regulatory_contribution', 'percent_of_gross_premium', 1.5, null, null,
   'insurer', 'Insurance Regulatory Authority of Uganda', 'regulator', 'ira_levy_payable',
   '[]'::jsonb,
   'unverified', null, null, '2020-08-14', false,
   'Press reports quote 1.5% of gross premium; not confirmed against an instrument in this pass. Inactive until verified.'),

  (null, 'UG_STAMP_DUTY_GENERAL',
   'Stamp duty (general insurance policy)', 'statutory_tax', 'fixed_per_policy', null, 35000, 'UGX',
   'insurer', 'Uganda Revenue Authority', 'government', 'stamp_duty_payable',
   '[]'::jsonb,
   'unverified', null, null, '2013-07-01', false,
   'Press reports quote UGX 35,000 per general policy since the 2013 increase from UGX 5,000. Not confirmed against an instrument in this pass, and the rate may differ for life policies. Inactive until verified.')
on conflict do nothing;

-- ---------------------------------------------------------------------
-- 4. The resolver
-- ---------------------------------------------------------------------
-- Rule 5's single pricing point. Takes a premium and a set of facts, returns the
-- charge lines the catalogue produces. It prices; it does not post. Every flow
-- that bills a statutory charge calls this, so a rate change lands in one place.
create or replace function public.ins_price_charges(
  p_tenant_id uuid,
  p_gross_premium numeric,
  p_net_premium numeric,
  p_commission_amount numeric,
  p_product_line_code text default null,
  p_currency text default 'UGX',
  p_on date default current_date
)
returns table (
  catalogue_id uuid,
  code text,
  name text,
  charge_class text,
  basis text,
  amount numeric,
  collector text,
  recipient_name text,
  recipient_kind text,
  payable_role text,
  payable_account_id uuid,
  catalogue_version integer,
  snapshot jsonb,
  warnings text[]
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  c record;
  v_amount numeric;
  v_warn text[];
  v_acct uuid;
begin
  if p_gross_premium is null or p_gross_premium < 0 then
    raise exception 'INS_CHARGE_INPUT: a non-negative gross premium is required';
  end if;

  for c in
    select * from public.ins_charge_catalogue k
     where k.is_active
       -- A company's own fee shadows nothing: statutory rows are global, and a
       -- tenant row only ever adds to them.
       and (k.tenant_id is null or k.tenant_id = p_tenant_id)
       -- Verification is a claim about a STATUTE: someone checked the rate
       -- against the instrument. A company's own commercial fee has no
       -- instrument to check it against, and requiring a source reference for
       -- it would either be a lie or block the company from billing its own fee.
       -- So the rule is per class, not per row.
       and (k.charge_class = 'commercial_fee' or k.verification_status = 'verified')
       and k.effective_from <= p_on
       and (k.effective_to is null or k.effective_to >= p_on)
       and (k.applies_to_product_lines is null
            or p_product_line_code is null
            or p_product_line_code = any (k.applies_to_product_lines))
     order by k.charge_class, k.code
  loop
    v_amount := case c.basis
      when 'percent_of_gross_premium' then round(p_gross_premium * c.rate_pct / 100, 2)
      when 'percent_of_net_premium'   then round(coalesce(p_net_premium, 0) * c.rate_pct / 100, 2)
      when 'percent_of_commission'    then round(coalesce(p_commission_amount, 0) * c.rate_pct / 100, 2)
      when 'fixed_per_policy'         then c.fixed_amount
      -- A per-vehicle rate needs the vehicle count, which no caller passes yet.
      -- Refusing is better than silently charging one vehicle's rate.
      when 'fixed_per_vehicle'        then null
    end;

    if v_amount is null then
      v_warn := array['INS_CHARGE_BASIS_UNSUPPORTED: ' || c.code || ' is priced per vehicle and the policy does not supply a vehicle count; not charged'];
      v_amount := 0;
    end if;

    -- Rule 3: the payable account must exist for this company. A charge whose
    -- destination ledger is unconfigured is not billable, and saying so here
    -- beats failing at posting time with a null account.
    select r.gl_account_id into v_acct
      from public.gl_posting_rules r
     where r.tenant_id = p_tenant_id and r.account_role = c.payable_role;

    if v_acct is null and v_amount > 0 then
      v_warn := coalesce(v_warn, '{}') || (('INS_CHARGE_PAYABLE_UNCONFIGURED: ' || c.code
        || ' is payable to role ' || c.payable_role || ', which this company has not mapped to an account'));
    end if;

    catalogue_id := c.id;
    code := c.code;
    name := c.name;
    charge_class := c.charge_class;
    basis := c.basis;
    amount := v_amount;
    collector := c.collector;
    recipient_name := c.recipient_name;
    recipient_kind := c.recipient_kind;
    payable_role := c.payable_role;
    payable_account_id := v_acct;
    catalogue_version := c.version;
    snapshot := to_jsonb(c) - 'created_by';
    warnings := coalesce(v_warn, '{}');
    v_warn := null;
    return next;
  end loop;
end $$;

revoke all on function public.ins_price_charges(uuid, numeric, numeric, numeric, text, text, date) from public, anon;
grant execute on function public.ins_price_charges(uuid, numeric, numeric, numeric, text, text, date) to authenticated;

-- ---------------------------------------------------------------------
-- 5. What still has to be wired in
-- ---------------------------------------------------------------------
-- Delivered here: the catalogue, the versioning, the immutability rule, the
-- snapshot columns, the seeds and the resolver.
--
-- Not delivered, and named so it is not mistaken for done: policy creation does
-- not yet call ins_price_charges (the client still supplies charge lines), and
-- the posting roles insurance_training_levy_payable, ira_levy_payable and
-- stamp_duty_payable have no template accounts yet. Until both are in place the
-- resolver is a library every flow can call, not a flow that charges by itself.
