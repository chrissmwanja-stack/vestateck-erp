-- =====================================================================
-- The charge catalogue becomes extensible: new charges need rows, not DDL
-- =====================================================================
-- 20261120002000 built the catalogue correctly but froze its vocabulary:
--
--   * `basis` was a CHECK enumeration (percent_of_gross_premium, fixed_per_policy,
--     ...), so a levy on sum insured -- or on anything the policy does not happen
--     to expose as one of five names -- needed a constraint change;
--   * `charge_class` was a CHECK of four values, so a fifth class of statutory
--     charge needed a constraint change;
--   * the resolver had a `case` per basis, so a new shape needed a new function
--     body as well;
--   * "verified charges only" keyed off the literal class name 'commercial_fee',
--     which means a new non-statutory class would silently start being filtered
--     out.
--
-- Adding a charge should be a matter of inserting rows. Adding a *kind of* charge
-- should be a matter of inserting a row in a registry. Only a genuinely new
-- algebraic shape should need code -- and then one branch, not a redesign.
--
-- Fix forward: 20261120002000 may already be applied by anyone holding v10, so it
-- is not edited. Its columns stay (rule 8: no drops) and stop being authoritative;
-- `formula` becomes the definition and the old columns are kept in step as a
-- summary for reports.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The two vocabularies become tables
-- ---------------------------------------------------------------------
-- Classes carry semantics, not just labels: whether the charge is statutory is
-- what decides whether a rate must be verified against an instrument. Putting
-- that in a registry means a new statutory class inherits the rule instead of
-- having to be added to a hard-coded list (which is how 'commercial_fee' would
-- have rotted).
create table if not exists public.ins_charge_class (
  code text primary key,
  label text not null,
  is_statutory boolean not null,
  sort_order integer not null default 100,
  created_at timestamptz not null default now()
);

comment on table public.ins_charge_class is
  'Vocabulary of charge classes. is_statutory decides whether a rate must be verified against an instrument. Insert a row to add a class; no DDL.';

insert into public.ins_charge_class (code, label, is_statutory, sort_order) values
  ('statutory_tax', 'Statutory tax', true, 10),
  ('statutory_levy', 'Statutory levy', true, 20),
  ('regulatory_contribution', 'Regulatory contribution', true, 30),
  ('commercial_fee', 'Commercial fee', false, 40)
on conflict (code) do nothing;

-- The quantities a formula may price against. The resolver refuses to guess: a
-- charge whose base is absent from the caller's parameters raises, because a levy
-- silently not charged is under-billing that nobody notices until an audit.
create table if not exists public.ins_charge_param (
  code text primary key,
  label text not null,
  is_money boolean not null,
  created_at timestamptz not null default now()
);

comment on table public.ins_charge_param is
  'Base quantities a charge formula may reference. A caller supplies the ones it has; ins_price_charges raises if a charge needs one that is missing.';

insert into public.ins_charge_param (code, label, is_money) values
  ('gross_premium', 'Gross premium', true),
  ('net_premium', 'Net premium to insurer', true),
  ('commission', 'Brokerage commission', true),
  ('sum_insured', 'Sum insured', true),
  ('policy_count', 'Number of policies', false),
  ('vehicle_count', 'Number of vehicles', false),
  ('item_count', 'Number of chargeable items', false)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- 2. The formula replaces the enumerated basis
-- ---------------------------------------------------------------------
alter table public.ins_charge_catalogue
  add column if not exists formula jsonb;

comment on column public.ins_charge_catalogue.formula is
  'How the amount is computed. {"kind":"rate","base":"gross_premium","rate_pct":0.5,"min":null,"max":null} | {"kind":"fixed","amount":35000,"per":"policy_count"} | {"kind":"banded","base":"gross_premium","bands":[{"up_to":10000000,"rate_pct":0.5},{"up_to":null,"rate_pct":0.25}]}. Any kind accepts min/max/round_to.';

-- Structural validation rather than an enumeration. A new kind is a new branch in
-- this one function; the table, the columns and every call site stay as they are.
create or replace function public.ins_charge_formula_valid(p_formula jsonb)
returns boolean
language plpgsql
immutable
set search_path to 'pg_catalog', 'pg_temp'
as $$
declare
  b jsonb;
  last_up_to numeric := -1;
  seen_open_end boolean := false;
begin
  if p_formula is null or jsonb_typeof(p_formula) is distinct from 'object' then
    return false;
  end if;
  if coalesce(p_formula ->> 'kind', '') not in ('rate', 'fixed', 'banded') then
    return false;
  end if;

  -- Applies to every kind.
  if p_formula ? 'min' and jsonb_typeof(p_formula -> 'min') not in ('number') then
    return false;
  end if;
  if p_formula ? 'max' and jsonb_typeof(p_formula -> 'max') not in ('number') then
    return false;
  end if;
  if p_formula ? 'min' and p_formula ? 'max'
     and (p_formula ->> 'max')::numeric < (p_formula ->> 'min')::numeric then
    return false;
  end if;
  if p_formula ? 'round_to' and jsonb_typeof(p_formula -> 'round_to') not in ('number') then
    return false;
  end if;

  if p_formula ->> 'kind' = 'rate' then
    if not (p_formula ? 'base') or jsonb_typeof(p_formula -> 'base') is distinct from 'string' then
      return false;
    end if;
    if jsonb_typeof(p_formula -> 'rate_pct') not in ('number') then
      return false;
    end if;
    if (p_formula ->> 'rate_pct')::numeric < 0 or (p_formula ->> 'rate_pct')::numeric > 100 then
      return false;
    end if;
    return true;
  end if;

  if p_formula ->> 'kind' = 'fixed' then
    if jsonb_typeof(p_formula -> 'amount') not in ('number')
       or (p_formula ->> 'amount')::numeric < 0 then
      return false;
    end if;
    -- `per` names a count parameter; "policy" is a shorthand for one.
    if p_formula ? 'per'
       and p_formula ->> 'per' <> 'policy'
       and jsonb_typeof(p_formula -> 'per') is distinct from 'string' then
      return false;
    end if;
    return true;
  end if;

  -- banded: marginal bands over one base, last band open-ended.
  if not (p_formula ? 'base') or jsonb_typeof(p_formula -> 'base') is distinct from 'string' then
    return false;
  end if;
  if jsonb_typeof(p_formula -> 'bands') is distinct from 'array'
     or jsonb_array_length(p_formula -> 'bands') = 0 then
    return false;
  end if;
  for b in select value from jsonb_array_elements(p_formula -> 'bands') loop
    if jsonb_typeof(b -> 'rate_pct') not in ('number') then
      return false;
    end if;
    if (b ->> 'rate_pct')::numeric < 0 or (b ->> 'rate_pct')::numeric > 100 then
      return false;
    end if;
    if b ? 'up_to' and jsonb_typeof(b -> 'up_to') is distinct from 'null' then
      if jsonb_typeof(b -> 'up_to') is distinct from 'number' then
        return false;
      end if;
      if (b ->> 'up_to')::numeric <= last_up_to then
        return false;  -- bands must ascend
      end if;
      last_up_to := (b ->> 'up_to')::numeric;
    else
      -- Only the final band may be open-ended.
      seen_open_end := true;
    end if;
    if seen_open_end and b <> (p_formula -> 'bands' -> (jsonb_array_length(p_formula -> 'bands') - 1)) then
      return false;
    end if;
  end loop;
  return true;
end $$;

revoke all on function public.ins_charge_formula_valid(jsonb) from public;

-- The old enumerations go. Dropping a constraint is not a data change; dropping
-- the columns would be (rule 8), so they stay and become a report summary.
alter table public.ins_charge_catalogue
  drop constraint if exists ins_charge_catalogue_basis_check;
alter table public.ins_charge_catalogue
  drop constraint if exists ins_charge_catalogue_amount_check;
alter table public.ins_charge_catalogue
  drop constraint if exists ins_charge_catalogue_class_check;

alter table public.ins_charge_catalogue
  alter column basis drop not null,
  alter column rate_pct drop not null;

-- Backfill a formula for every row written by 20261120002000, so nothing depends
-- on the old columns from here on.
update public.ins_charge_catalogue
   set formula = case
         when basis like 'percent%' then jsonb_build_object(
           'kind', 'rate',
           'base', case basis
                     when 'percent_of_gross_premium' then 'gross_premium'
                     when 'percent_of_net_premium'   then 'net_premium'
                     when 'percent_of_commission'    then 'commission'
                   end,
           'rate_pct', rate_pct)
         when basis = 'fixed_per_policy' then jsonb_build_object(
           'kind', 'fixed', 'amount', fixed_amount, 'per', 'policy')
         when basis = 'fixed_per_vehicle' then jsonb_build_object(
           'kind', 'fixed', 'amount', fixed_amount, 'per', 'vehicle_count')
         else null
       end
 where formula is null;

-- Every row must now be describable. The one thing this migration refuses to do
-- is invent a formula for a row it cannot interpret.
do $$
begin
  if exists (select 1 from public.ins_charge_catalogue where formula is null) then
    raise exception 'INS_CHARGE_FORMULA_BACKFILL: % catalogue row(s) could not be expressed as a formula; set formula by hand before continuing',
      (select count(*) from public.ins_charge_catalogue where formula is null);
  end if;
end $$;

alter table public.ins_charge_catalogue alter column formula set not null;

alter table public.ins_charge_catalogue
  drop constraint if exists ins_charge_catalogue_formula_check;
alter table public.ins_charge_catalogue
  add constraint ins_charge_catalogue_formula_check
  check (public.ins_charge_formula_valid(formula));

-- Class membership is now a foreign key to the registry, so a new class is a row.
alter table public.ins_charge_catalogue
  drop constraint if exists ins_charge_catalogue_class_fk;
alter table public.ins_charge_catalogue
  add constraint ins_charge_catalogue_class_fk
  foreign key (charge_class) references public.ins_charge_class(code);

-- Collector and recipient kind stay short text, but validated against the pairing
-- the ledger needs. Deliberately not enumerated: a new kind of recipient (a county
-- authority, a parafiscal body) is a new value, not a new column.
alter table public.ins_charge_catalogue
  drop constraint if exists ins_charge_catalogue_recipient_check;
alter table public.ins_charge_catalogue
  add constraint ins_charge_catalogue_recipient_check
  check (length(btrim(recipient_kind)) between 3 and 40
         and recipient_kind ~ '^[a-z_]+$');

-- ---------------------------------------------------------------------
-- 2b. The immutability guard watches the formula, not the frozen columns
-- ---------------------------------------------------------------------
-- 20261120002000 froze rate_pct and fixed_amount once a charge was billed. Those
-- columns are no longer authoritative, so a guard that watched only them would let
-- a billed charge's rate change freely through `formula` -- the rule would still
-- exist and would no longer bite. Redefined here to watch whichever column is
-- actually the definition, in both shapes.
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
    if new.code is distinct from old.code
       or new.charge_class is distinct from old.charge_class
       or new.formula is distinct from old.formula
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
      raise exception 'INS_CHARGE_CATALOGUE_IMMUTABLE: charge % v% has been billed; add a new version rather than changing the rate, formula, class, recipient, payable account, exemptions or start date', old.code, old.version
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

revoke all on function public.ins_charge_catalogue_guard() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. The resolver prices a formula, not a case statement
-- ---------------------------------------------------------------------
-- Parameterised by a jsonb map, so a charge can price against any registered
-- quantity without a signature change. The typed wrapper below keeps every
-- existing call site working.
create or replace function public.ins_price_charges_for(
  p_tenant_id uuid,
  p_params jsonb,
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
end $$;

revoke all on function public.ins_price_charges_for(uuid, jsonb, text, text, date) from public, anon;
grant execute on function public.ins_price_charges_for(uuid, jsonb, text, text, date) to authenticated;

-- The typed signature every existing caller uses, kept as a thin wrapper so no
-- call site changes when the parameters grow.
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
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select * from public.ins_price_charges_for(
    p_tenant_id,
    jsonb_strip_nulls(jsonb_build_object(
      'gross_premium', p_gross_premium,
      'net_premium', p_net_premium,
      'commission', p_commission_amount,
      'policy_count', 1)),
    p_product_line_code, p_currency, p_on)
$$;

revoke all on function public.ins_price_charges(uuid, numeric, numeric, numeric, text, text, date) from public, anon;
grant execute on function public.ins_price_charges(uuid, numeric, numeric, numeric, text, text, date) to authenticated;

-- ---------------------------------------------------------------------
-- 4. The seeds say what they mean as formulas
-- ---------------------------------------------------------------------
update public.ins_charge_catalogue
   set formula = jsonb_build_object('kind', 'rate', 'base', 'gross_premium', 'rate_pct', 0.5)
 where code = 'UG_INSURANCE_TRAINING_LEVY';

update public.ins_charge_catalogue
   set formula = jsonb_build_object('kind', 'rate', 'base', 'gross_premium', 'rate_pct', 1.5)
 where code = 'UG_IRA_LEVY';

update public.ins_charge_catalogue
   set formula = jsonb_build_object('kind', 'fixed', 'amount', 35000, 'per', 'policy')
 where code = 'UG_STAMP_DUTY_GENERAL';

-- ---------------------------------------------------------------------
-- 5. Access for the two registries
-- ---------------------------------------------------------------------
alter table public.ins_charge_class enable row level security;
alter table public.ins_charge_param enable row level security;

drop policy if exists ins_charge_class_select on public.ins_charge_class;
create policy ins_charge_class_select on public.ins_charge_class
  for select to authenticated using (can_access_insurance());

drop policy if exists ins_charge_param_select on public.ins_charge_param;
create policy ins_charge_param_select on public.ins_charge_param
  for select to authenticated using (can_access_insurance());

-- No write policies: the vocabularies are maintained by migration, in the same
-- review as the charges that use them.

-- ---------------------------------------------------------------------
-- 6. What is extensible without DDL, and what is not
-- ---------------------------------------------------------------------
-- Rows only, no migration:
--   * a new charge of an existing kind (rate / fixed / banded);
--   * a new rate on any registered base quantity, including sum insured;
--   * a new class of charge -- insert into ins_charge_class with is_statutory set;
--   * a new base quantity -- insert into ins_charge_param, and pass it in
--     p_params. Adding the row alone is not enough; a caller must supply it.
--   * a cap, a floor or a different rounding on any charge.
--
-- One branch of one function, no schema change:
--   * a new formula kind (e.g. a table lookup, which is how IRA minimum premium
--     rates actually work -- those are a rate TABLE by vehicle class, not a levy,
--     and they belong with the pricing engine rather than here).
--
-- Still a design change, and named so it is not mistaken for free:
--   * a charge computed from OTHER charges (VAT on a fee already exists and has
--     its own pathway; a levy on the total of other levies does not);
--   * anything needing a value the policy does not carry.

select 'charge catalogue extensible' as status;
