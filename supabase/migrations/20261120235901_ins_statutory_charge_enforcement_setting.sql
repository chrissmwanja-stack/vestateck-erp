-- =====================================================================
-- Statutory charge enforcement is a company decision, not a global default
-- =====================================================================
-- 20261120235900 made the bind guard fire on the real approval path. Measured:
-- 39 SQL tests failed, because enforcing acknowledgement for every policy changes
-- the invoice of every policy that already exists, and every fixture that binds one.
--
-- That is not a bug in the tests. It is the correct signal that turning enforcement
-- on is a business decision with a visible consequence -- a client's premium goes up
-- by the levy -- and a migration has no business making it silently for every
-- company on the platform.
--
-- So enforcement is an approved accounting setting, `ins.statutory_charge_enforcement`:
--
--   advisory (the default for a company that has not chosen) -- statutory charges are
--            priced and recorded when the manager asks, but bind does not require it.
--            Nothing about an existing policy's premium changes.
--   required -- bind refuses unless the catalogue's charges for the policy were
--            priced and acknowledged, and refuses if the catalogue moved since.
--
-- This is a rollout control, not a switch to accommodate an inconvenience: the
-- machinery is the same in both modes, and the mode changes only whether the bind
-- stops. A company that owes a statutory levy should be on `required`, and
-- ACCOUNTANT_PACK.md says so.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------
insert into public.accounting_setting_definitions
  (key, label, description, allowed_values, default_value, implemented_values)
values (
  'ins.statutory_charge_enforcement',
  'Statutory charge enforcement (insurance brokerage)',
  'Whether binding a policy requires the statutory charges on the catalogue to be priced and acknowledged. '
  || 'advisory -- charges can be priced and recorded, but a policy binds without them, and no existing premium changes. '
  || 'required -- bind refuses unless every catalogue charge for the policy was priced (ins_apply_statutory_charges) and acknowledged (ins_acknowledge_statutory_charges), '
  || 'and refuses if a verified rate changed after the acknowledgement. '
  || 'A company that collects a statutory levy on behalf of a regulator, a training body or URA should be on required.',
  array['advisory', 'required'],
  'advisory',
  -- Both values are read by ins_statutory_enforcement from this migration onwards;
  -- implemented_values is the registry's statement of that, and drift between it and
  -- the code is what test_ins_commission_recognition_mode pins elsewhere.
  array['advisory', 'required']
)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 2. Reading it without a session
-- ---------------------------------------------------------------------
-- The guard fires during seed.sql and the in-force import, where there is no
-- session user, so it must NOT go through acct_assert_reviewed / acct_get_setting --
-- those assert tenant access and would break every import path (measured earlier in
-- this project: the identical mistake in the commission trigger broke 24 tests).
-- This reads the approved row directly and falls back to the conservative default.
create or replace function public.ins_statutory_enforcement(p_tenant_id uuid, p_on date default current_date)
returns text
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select coalesce(
    (select s.value from public.company_accounting_settings s
      where s.tenant_id = p_tenant_id
        and s.setting_key = 'ins.statutory_charge_enforcement'
        and s.status = 'approved'
        and s.effective_from <= p_on
      order by s.effective_from desc
      limit 1),
    'advisory')
$$;

revoke all on function public.ins_statutory_enforcement(uuid, date) from public, anon;
grant execute on function public.ins_statutory_enforcement(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- 3. The guard respects it
-- ---------------------------------------------------------------------
create or replace function public.ins_statutory_charges_bind_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_ack jsonb;
  v_now_total numeric := 0;
  v_ack_total numeric;
begin
  if new.status = 'active' and old.status is distinct from 'active' then

    -- Advisory: price and record if asked, but never stop a bind. This keeps the
    -- behaviour every existing policy was bound under.
    if public.ins_statutory_enforcement(new.tenant_id, new.inception_date) <> 'required' then
      return new;
    end if;

    v_ack := new.statutory_charges_ack;

    if v_ack is null then
      select coalesce(sum(l.amount), 0)
        into v_now_total
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
        raise exception 'INS_CHARGE_NOT_ACKNOWLEDGED: the catalogue prices % for this policy but no statutory charges were acknowledged. Call ins_apply_statutory_charges then ins_acknowledge_statutory_charges before binding, or set ins.statutory_charge_enforcement to advisory if this company does not collect statutory charges.', v_now_total
          using errcode = '23514';
      end if;
      return new;
    end if;

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

-- The snapshot wrapper records the acknowledgement either way: the record is
-- useful in advisory mode too, and "which version was this policy priced under"
-- should be answerable whether or not enforcement was on.
create or replace function public.ins_snapshot_bind_config()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  new := public.ins_snapshot_bind_config_commission_only();

  if new.status = 'active' and old.status is distinct from 'active' then
    new.accounting_config_snapshot := coalesce(new.accounting_config_snapshot, '{}'::jsonb)
      || jsonb_build_object(
           'statutory_charges', to_jsonb(new.statutory_charges_ack),
           'statutory_charge_enforcement',
             public.ins_statutory_enforcement(new.tenant_id, new.inception_date));
  end if;
  return new;
end $$;

revoke all on function public.ins_snapshot_bind_config() from public, anon, authenticated;

select 'statutory charge enforcement is opt-in per company' as status;
