-- =====================================================================
-- The bind-snapshot trigger still points at the renamed function
-- =====================================================================
-- `alter function ... rename to` moves the function, it does NOT repoint the trigger
-- that calls it: the trigger keeps its dependency on the function's OID, so after
-- the rename in 20261120005000 it was still calling the commission-only body and the
-- new wrapper -- which adds the statutory acknowledgement to the snapshot -- never
-- ran.
--
-- Measured: a bound policy's accounting_config_snapshot had the commission keys and
-- `statutory: NULL`. The assertion that caught it is section 5 of
-- test_ins_statutory_charges_on_policy.sql.
--
-- The trigger is recreated against the wrapper. Recreating a trigger is not a data
-- change (no row is touched, nothing is dropped from a table), so this is safe to
-- fix forward.
drop trigger if exists ins_bind_config_snapshot on public.ins_policies;

create trigger ins_bind_config_snapshot
  before update on public.ins_policies
  for each row execute function public.ins_snapshot_bind_config();

select 'bind snapshot trigger repointed at the wrapper' as status;
