-- =====================================================================
-- One bind-snapshot function, authored once, adding the statutory key
-- =====================================================================
-- 20261120005000 tried to extend ins_snapshot_bind_config() by renaming the original
-- and calling it from a wrapper. Two hard PostgreSQL facts killed that, and both
-- were measured rather than assumed:
--
--   1. `alter function ... rename to` does not repoint the trigger: the trigger keeps
--      its dependency on the original function, so the wrapper never ran and the
--      statutory key never reached the snapshot.
--   2. A trigger function cannot be called from another function at all
--      ("trigger functions can only be called as triggers"), so the wrapper could not
--      have worked even once repointed.
--
-- 20261120008000 repointed the trigger at the wrapper, which turned every bind into
-- that second error and broke 43 tests.
--
-- The only correct shape is one function holding both responsibilities. Its body is
-- the original commission-resolution logic verbatim -- every key, every guard, every
-- message -- plus the statutory acknowledgement. Nothing about the commission rules
-- changes; test_ins_commission_recognition_mode.sql section 7 and
-- test_bind_config_snapshot.sql both fail if any of it is lost.
--
-- The renamed copy is left in place, unused, rather than dropped: MIGRATION_POLICY
-- rule 8 forbids drops in a fix, and an unreferenced function is harmless. It has no
-- execution grants.
create or replace function public.ins_snapshot_bind_config()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_recognition text;
  v_effective   text;
  v_source      text;
begin
  if new.status = 'active' and old.status is distinct from new.status then
    v_recognition := public.acct_assert_reviewed('ins.commission_recognition', new.inception_date);

    if new.commission_recognition_override is not null then
      v_source := 'policy_override';
    else
      v_source := 'tenant_setting';
    end if;

    -- Gross settlement means the premium crosses in full and the commission is
    -- a receivable from the insurer: there is nothing left to defer, so it is
    -- earned at placement whatever the setting says.
    if public.ins_share_basis(new.id) = 'gross_premium'
       and coalesce(new.commission_amount, 0) > 0 then
      v_effective := 'at_placement';
      v_source    := 'remittance_basis_gross';
    elsif new.commission_recognition_override is not null then
      v_effective := new.commission_recognition_override;
      v_source    := 'policy_override';
    else
      v_effective := v_recognition;
      v_source    := 'tenant_setting';
    end if;

    if v_effective not in ('on_insurer_settlement', 'at_placement', 'on_premium_collection') then
      raise exception 'INS_COMMISSION_RECOGNITION_UNIMPLEMENTED: % has no reader in this release (implemented: on_insurer_settlement, at_placement, on_premium_collection). Configure one of those before binding %', v_effective, new.policy_no;
    end if;

    if v_effective = 'at_placement' and coalesce(new.commission_amount, 0) <= 0 then
      raise exception 'INS_COMMISSION_RECOGNITION_MODE: % is set to recognise commission at placement but has no commission; correct the rate or choose on_insurer_settlement', new.policy_no;
    end if;

    -- Conditional-on-collection and gross settlement cannot both be true: under
    -- gross the premium is remitted in full at placement, so there is no
    -- outstanding premium whose collection could be the trigger.
    if v_effective = 'on_premium_collection'
       and public.ins_share_basis(new.id) = 'gross_premium'
       and coalesce(new.commission_amount, 0) > 0 then
      raise exception 'INS_COMMISSION_RECOGNITION_BASIS: % is set to recognise commission when the premium is collected, but its settlement basis is gross_premium, where the premium crosses in full at bind and there is nothing left to collect. Choose at_placement for a gross basis', new.policy_no;
    end if;

    new.accounting_config_snapshot := coalesce(new.accounting_config_snapshot, '{}'::jsonb)
      || jsonb_build_object(
           'ins.commission_recognition', v_recognition,
           'commission_recognition_effective', v_effective,
           'commission_recognition_source', v_source,
           'resolved_at', now()
         );
  end if;

  -- The statutory acknowledgement, on any transition into active: the approval
  -- workflow means the real path is ... -> approved -> active, not draft -> active.
  -- Distinct from the commission block above, which keeps its own condition so its
  -- behaviour is unchanged.
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

-- The trigger must call this function. Recreating it is not a data change.
drop trigger if exists ins_bind_config_snapshot on public.ins_policies;
create trigger ins_bind_config_snapshot
  before update on public.ins_policies
  for each row execute function public.ins_snapshot_bind_config();

select 'bind snapshot is one function again' as status;
