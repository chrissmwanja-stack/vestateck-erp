-- =====================================================================
-- Policy creation prices statutory charges from the catalogue
-- =====================================================================
-- Until now the catalogue was a library: the client supplied charge lines, and
-- ins_price_charges existed but nobody called it. A company could therefore bind a
-- policy carrying no training levy at all, and nothing in the system noticed.
-- This is the integration half of the owner's rule 5.
--
-- The shape is DELIBERATELY not "silently add whatever the catalogue prices":
--
--   ins_apply_statutory_charges(policy, params)  prices now, replaces the
--                                                catalogue-sourced lines, and
--                                                records the exact prices it saw
--   ins_acknowledge_statutory_charges(policy)    the manager says "these are the
--                                                statutory amounts for this policy"
--   bind                                          refuses if the catalogue now
--                                                prices something different from
--                                                what was acknowledged
--
-- Why the record rather than a straight insert: a levy is money the brokerage
-- collects on behalf of somebody else. If a rate is verified between drafting and
-- binding, a policy priced last week would bind under the old rate and nobody
-- would know. The acknowledgement makes that impossible, and the parameters are
-- stored so it is checked again at bind.
--
-- Manual charges are untouched. Applying statutory charges replaces only rows this
-- mechanism wrote, so a broker fee or a negotiated pass-through line survives, and
-- running it twice is safe.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The policy remembers which lines came from the catalogue
-- ---------------------------------------------------------------------
-- ins_policy_charges already has catalogue_id / catalogue_version /
-- catalogue_snapshot from 20261120002000. What is missing is the acknowledgement
-- itself: the figures the manager signed off, and when.
alter table public.ins_policies
  add column if not exists statutory_charges_ack jsonb;

comment on column public.ins_policies.statutory_charges_ack is
  'The catalogue prices the manager acknowledged (lines + parameters + total), and when. Bind refuses if the catalogue has moved since.';

-- ---------------------------------------------------------------------
-- 2. Price from the catalogue, and record what was priced
-- ---------------------------------------------------------------------
create or replace function public.ins_apply_statutory_charges(
  p_policy_id uuid,
  p_params jsonb default '{}'::jsonb,
  p_add_missing_params boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  p ins_policies%rowtype;
  v_params jsonb;
  v_line record;
  v_lines jsonb := '[]'::jsonb;
  v_amount numeric := 0;
  v_vat_gl uuid;
  v_income_gl uuid;
  v_del text[] := '{}';
  v_unknown text[];
begin
  if not public.can_manage_insurance()
     or public.effective_user_id() is distinct from auth.uid() then
    raise exception 'INS_FORBIDDEN: an Insurance manager acting as themselves is required' using errcode = '42501';
  end if;

  select * into p from public.ins_policies
   where id = p_policy_id and tenant_id = public.get_my_tenant_id()
   for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  if p.status <> 'draft' then
    raise exception 'INS_FINANCIAL_IMMUTABLE: statutory charges are priced on drafts; % is %', p.policy_no, p.status;
  end if;
  if jsonb_typeof(coalesce(p_params, '{}'::jsonb)) is distinct from 'object' then
    raise exception 'INS_CHARGE_INPUT: parameters must be a JSON object';
  end if;

  -- Callers may pass only what they know. Everything the policy itself carries is
  -- filled in here, and a charge needing anything else then fails loudly with
  -- INS_CHARGE_PARAM_MISSING rather than being quietly skipped.
  v_params := jsonb_strip_nulls(jsonb_build_object(
                'gross_premium', p.gross_premium,
                'net_premium', p.gross_premium - coalesce(p.commission_amount, 0),
                'commission', p.commission_amount,
                'sum_insured', p.sum_insured,
                'policy_count', 1
              )) || coalesce(p_params, '{}'::jsonb);

  -- Reject parameters we do not use, in case someone is asking for a charge the
  -- catalogue cannot price yet and would otherwise be billed nothing.
  select array_agg(k) into v_unknown
    from jsonb_object_keys(coalesce(p_params, '{}'::jsonb)) k
   where k not in (select code from public.ins_charge_param)
     and k <> 'vehicle_count'::text
     and k <> 'item_count'::text;
  if v_unknown is not null then
    raise exception 'INS_CHARGE_PARAM_UNKNOWN: % not a registered base quantity', v_unknown;
  end if;

  -- Replace only the lines this mechanism wrote.
  delete from public.ins_policy_charges
   where policy_id = p.id and catalogue_id is not null;

  -- VAT is not part of a statutory levy and a levy is not the brokerage's income:
  -- both accounts are left null so nothing downstream can mistake a levy for a fee.
  for v_line in
    select * from public.ins_price_charges_for(
      p.tenant_id, v_params,
      (select code from public.ins_product_lines where id = p.product_line_id),
      p.currency, p.inception_date)
  loop
    if v_line.amount is null or v_line.amount <= 0 then
      continue;
    end if;
    if v_line.payable_account_id is null then
      raise exception 'INS_CHARGE_PAYABLE_UNCONFIGURED: % is payable to role %, which this company has not mapped to an account. Map it before pricing the policy, or the charge cannot be remitted.', v_line.code, v_line.payable_role;
    end if;

    insert into public.ins_policy_charges
      (tenant_id, policy_id, kind, description, amount, recipient_mode, vat_mode,
       reviewed, catalogue_id, charge_class, catalogue_version, collector,
       recipient_name, payable_role, catalogue_snapshot)
    values
      (p.tenant_id, p.id,
       -- A statutory charge is money the client pays that passes through to a
       -- third party. insurer_pass_through is that shape: it contributes to the
       -- invoice total without being income. It is deliberately not broker_fee,
       -- which would make the brokerage the recipient and the money its revenue.
       'insurer_pass_through',
       v_line.name, v_line.amount,
       'all_insurers', 'not_calculated',
       -- Reviewed by being acknowledged: the manager does that in the next call,
       -- and bind refuses without it. Left false here so the two steps stay
       -- distinguishable and the acknowledgement is a real event.
       false,
       v_line.catalogue_id, v_line.charge_class, v_line.catalogue_version,
       v_line.collector, v_line.recipient_name, v_line.payable_role,
       v_line.snapshot);

    v_amount := v_amount + v_line.amount;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'catalogue_id', v_line.catalogue_id,
      'code', v_line.code,
      'name', v_line.name,
      'charge_class', v_line.charge_class,
      'amount', v_line.amount,
      'catalogue_version', v_line.catalogue_version,
      'payable_role', v_line.payable_role));
  end loop;

  -- Any previous acknowledgement is now stale by definition: the figures changed.
  update public.ins_policies
     set statutory_charges_ack = null
   where id = p.id;

  return jsonb_build_object(
    'policy_id', p.id,
    'currency', p.currency,
    'lines', v_lines,
    'total', v_amount,
    'parameters', v_params,
    'acknowledged', false,
    'note', 'Statutory charges priced. Acknowledging them is a separate step, and bind requires it.');
end $$;

revoke all on function public.ins_apply_statutory_charges(uuid, jsonb, boolean) from public, anon;
grant execute on function public.ins_apply_statutory_charges(uuid, jsonb, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Acknowledge: the manager accepts these statutory amounts
-- ---------------------------------------------------------------------
create or replace function public.ins_acknowledge_statutory_charges(p_policy_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  p ins_policies%rowtype;
  v_lines jsonb;
  v_total numeric;
  v_ack jsonb;
begin
  if not public.can_manage_insurance()
     or public.effective_user_id() is distinct from auth.uid() then
    raise exception 'INS_FORBIDDEN: an Insurance manager acting as themselves is required' using errcode = '42501';
  end if;

  select * into p from public.ins_policies
   where id = p_policy_id and tenant_id = public.get_my_tenant_id()
   for update;
  if not found then raise exception 'INS_NOT_FOUND: policy'; end if;
  if p.status <> 'draft' then
    raise exception 'INS_FINANCIAL_IMMUTABLE: only a draft can acknowledge its statutory charges';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'catalogue_id', c.catalogue_id, 'code', c.catalogue_snapshot ->> 'code',
           'amount', c.amount, 'catalogue_version', c.catalogue_version,
           'payable_role', c.payable_role) order by c.id), '[]'::jsonb),
         coalesce(sum(c.amount), 0)
    into v_lines, v_total
    from public.ins_policy_charges c
   where c.policy_id = p.id and c.catalogue_id is not null;

  if v_total <= 0 then
    -- Nothing to acknowledge is not the same as everything acknowledged. Saying so
    -- stops a silent "all clear" on a policy where pricing was never run.
    raise exception 'INS_CHARGE_NOTHING_PRICED: no statutory charges have been priced for %; call ins_apply_statutory_charges first, even if you expect the total to be zero', p.policy_no;
  end if;

  v_ack := jsonb_build_object(
    'acknowledged_at', now(),
    'acknowledged_by', auth.uid(),
    'lines', v_lines,
    'total', v_total,
    -- The inputs the prices were derived from, so bind can re-price and compare
    -- rather than trusting that nothing moved.
    'parameters', jsonb_strip_nulls(jsonb_build_object(
                    'gross_premium', p.gross_premium,
                    'net_premium', p.gross_premium - coalesce(p.commission_amount, 0),
                    'commission', p.commission_amount,
                    'sum_insured', p.sum_insured,
                    'policy_count', 1)));

  update public.ins_policies set statutory_charges_ack = v_ack where id = p.id;
  -- Now the lines may be marked reviewed, which is what the bind checks for.
  update public.ins_policy_charges set reviewed = true
   where policy_id = p.id and catalogue_id is not null;

  return v_ack;
end $$;

revoke all on function public.ins_acknowledge_statutory_charges(uuid) from public, anon;
grant execute on function public.ins_acknowledge_statutory_charges(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Bind refuses a stale acknowledgement
-- ---------------------------------------------------------------------
-- The guard is a trigger rather than an edit to the bind body, for the same reason
-- the commission trigger reads the snapshot instead of calling a resolver: the bind
-- path is the most safety-critical code in the module and is also invoked by
-- imports and seeds that have no session. A trigger can test the one condition and
-- change nothing else.
create or replace function public.ins_statutory_charges_bind_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_ack jsonb;
  v_now jsonb;
  v_now_total numeric := 0;
  v_ack_total numeric;
  v_snapshot jsonb;
begin
  -- Any transition INTO active, not just draft -> active. The approval workflow
  -- means the real path is draft -> pending_approval -> approved -> active, and a
  -- guard written for draft -> active would never fire on the path the app takes.
  -- (Found by a probe that bound a policy already at 'approved': it succeeded.)
  if new.status = 'active' and old.status is distinct from 'active' then
    v_ack := new.statutory_charges_ack;

    if v_ack is null then
      -- No acknowledgement at all. Silence is only allowed when the catalogue
      -- genuinely prices nothing for this policy, which is a real case: a company
      -- with no verified statutory charge has nothing to price.
      select coalesce(jsonb_agg(jsonb_build_object(
               'catalogue_id', l.catalogue_id, 'code', l.code, 'amount', l.amount,
               'catalogue_version', l.catalogue_version) order by l.code), '[]'::jsonb),
             coalesce(sum(l.amount), 0)
        into v_now, v_now_total
        from public.ins_price_charges_for(
               new.tenant_id,
               jsonb_strip_nulls(jsonb_build_object(
                 'gross_premium', new.gross_premium,
                 'net_premium', new.gross_premium - coalesce(new.commission_amount, 0),
                 'commission', new.commission_amount,
                 'sum_insured', new.sum_insured,
                 'policy_count', 1)),
               (select code from public.ins_product_lines where id = new.product_line_id),
               new.currency, new.inception_date) l
       where l.amount > 0;

      if v_now_total > 0 then
        raise exception 'INS_CHARGE_NOT_ACKNOWLEDGED: the catalogue prices % for this policy but no statutory charges were acknowledged. Call ins_apply_statutory_charges then ins_acknowledge_statutory_charges before binding.', v_now_total
          using errcode = '23514';
      end if;
      return new;
    end if;

    -- Acknowledged: re-price with the acknowledged inputs and compare. A verified
    -- rate that changed between drafting and binding lands here.
    v_ack_total := coalesce((v_ack ->> 'total')::numeric, 0);
    select coalesce(sum(l.amount), 0)
      into v_now_total
      from public.ins_price_charges_for(
             new.tenant_id, coalesce(v_ack -> 'parameters', '{}'::jsonb),
             (select code from public.ins_product_lines where id = new.product_line_id),
             new.currency, new.inception_date) l
     where l.amount > 0;

    if v_now_total is distinct from v_ack_total then
      raise exception 'INS_CHARGE_ACK_STALE: the acknowledged statutory charges total % but the catalogue now prices %. Re-price and acknowledge again.', v_ack_total, v_now_total
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;

revoke all on function public.ins_statutory_charges_bind_guard() from public, anon, authenticated;

drop trigger if exists trg_ins_statutory_charges_bind_guard on public.ins_policies;
create trigger trg_ins_statutory_charges_bind_guard
  before update on public.ins_policies
  for each row execute function public.ins_statutory_charges_bind_guard();

-- ---------------------------------------------------------------------
-- 5. The bind snapshot keeps the acknowledgement
-- ---------------------------------------------------------------------
-- ins_snapshot_bind_config() already freezes the accounting configuration and its
-- body is NOT retyped here: it carries the commission-recognition resolution, and
-- rewriting 45 lines to add one key is how a working rule gets quietly dropped.
-- It is renamed to keep its code exactly as authored, and a thin wrapper takes the
-- name the trigger already points at (a rename leaves the trigger's dependency
-- intact, so nothing is dropped and rebuilt).
--
-- If this wrapper ever loses the commission key, section 7 of
-- test_ins_commission_recognition_mode.sql fails -- the existing test is the
-- guarantee, not this comment.
alter function public.ins_snapshot_bind_config() rename to ins_snapshot_bind_config_commission_only;
revoke all on function public.ins_snapshot_bind_config_commission_only() from public, anon, authenticated;

create function public.ins_snapshot_bind_config()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  new := public.ins_snapshot_bind_config_commission_only();

  if new.status = 'active' and old.status = 'draft' then
    new.accounting_config_snapshot := coalesce(new.accounting_config_snapshot, '{}'::jsonb)
      || jsonb_build_object('statutory_charges', to_jsonb(new.statutory_charges_ack));
  end if;
  return new;
end $$;

revoke all on function public.ins_snapshot_bind_config() from public, anon, authenticated;

select 'statutory charges integrated with the policy' as status;
