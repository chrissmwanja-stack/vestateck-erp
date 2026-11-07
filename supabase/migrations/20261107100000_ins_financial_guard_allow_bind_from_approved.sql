-- =====================================================================
-- Insurance brokerage: let bind write the computed share/charge amounts.
--
-- Same root cause as 20261107090000. ins_financial_configuration_guard
-- locks insurer shares and charge lines whenever the policy status is
-- anything but 'draft'. Since 20261106180000/230000, bind starts from
-- 'approved', and the bind implementation
-- (platform_ins_bind_policy_risk_legacy_impl) writes the computed
-- premium_amount / pass_through_amount / commission_amount /
-- payable_amount / vat_amount on those rows BEFORE flipping the policy to
-- 'active'. The guard therefore refused every co-insurance or charged bind
-- with INS_FINANCIAL_IMMUTABLE.
--
-- Fix: ins_bind_policy sets a transaction-local marker naming the policy
-- it is binding, and the guard honours that marker only while the policy is
-- 'approved'. Once the policy is 'active' (or anything else) the rows are
-- locked exactly as before, and the marker is cleared before returning.
-- Configuring shares/charges is still draft-only
-- (ins_set_policy_financial_configuration checks status itself).
-- =====================================================================

create or replace function public.ins_financial_configuration_guard() returns trigger
language plpgsql security definer set search_path=public,pg_temp as $$
declare pid uuid;
begin
 if tg_table_name='ins_policy_financial_snapshots' then
   if tg_op<>'INSERT' then raise exception 'INS_FINANCIAL_IMMUTABLE: bind snapshot cannot be changed or deleted'; end if;
   return new;
 end if;
 pid:=case when tg_op='DELETE' then old.policy_id else new.policy_id end;
 perform id from ins_policies where id=pid for update;
 if exists(
   select 1 from ins_policies
   where id=pid and status<>'draft'
     -- the bind step of THIS policy may fill in computed amounts while approved
     and not (status='approved' and tg_op='UPDATE'
              and coalesce(current_setting('ins.binding_policy', true), '') = pid::text)
 ) then
   raise exception 'INS_FINANCIAL_IMMUTABLE: insurer shares and charge lines are locked after bind';
 end if;
 if tg_op='UPDATE' and (new.policy_id is distinct from old.policy_id or new.tenant_id is distinct from old.tenant_id) then
   raise exception 'INS_FINANCIAL_IMMUTABLE: configuration cannot move between policies';
 end if;
 if tg_op='DELETE' then return old; else return new; end if;
end $$;

revoke all on function public.ins_financial_configuration_guard() from public,anon,authenticated;

-- Wrapper identical to 20261017160000, plus the marker around the impl call.
create or replace function public.ins_bind_policy(p_policy_id uuid) returns public.ins_policies
language plpgsql security definer set search_path = pg_catalog, public, pg_temp as $$
declare p ins_policies%rowtype; is_motor boolean;
begin
  perform set_config('ins.binding_policy', p_policy_id::text, true);
  p := platform_ins_bind_policy_risk_legacy_impl(p_policy_id);
  perform set_config('ins.binding_policy', '', true);
  is_motor := public.platform_ins_line_needs_certificate(p.tenant_id, p.product_line_id);
  if is_motor then
    if not exists (select 1 from ins_certificate_stock c where c.tenant_id = p.tenant_id and c.policy_id = p.id and c.status = 'issued') then
      raise exception 'INS_MOTOR_CERTIFICATE_REQUIRED: attach an issued motor certificate to this policy before binding';
    end if;
    update ins_certificate_stock set status = 'used' where tenant_id = p.tenant_id and policy_id = p.id and status = 'issued';
  end if;
  return p;
end $$;
