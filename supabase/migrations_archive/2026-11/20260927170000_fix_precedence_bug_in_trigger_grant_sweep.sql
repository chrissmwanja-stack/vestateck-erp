-- Fix operator-precedence bug in 20260925133000_fix_rls_initplan_and_anon_grants.sql
--
-- That migration's DO block intended to scope its grant sweep to:
--   SECURITY DEFINER functions in the public schema whose name matches
--   trg_/notify_/check_/pmo_check_/set_/touch_ prefixes
-- but the WHERE clause was written as:
--   n.nspname = 'public' and p.prosecdef and p.proname like 'trg_%'
--     or p.proname like 'notify_%' or p.proname like 'check_%' or ...
-- Because AND binds tighter than OR in SQL, this actually evaluated as:
--   (n.nspname = 'public' AND p.prosecdef AND p.proname LIKE 'trg_%')
--   OR p.proname LIKE 'notify_%' OR p.proname LIKE 'check_%' OR ...
-- dropping the schema/SECURITY DEFINER restriction from every branch after
-- the first. In practice this reached pg_catalog.set_config (revoke failed
-- silently, no effect -- the migration role doesn't own it) and a handful of
-- our own plain (non-SECURITY DEFINER) trigger helpers matching set_%/touch_%
-- (set_department_defaults, touch_updated_at, set_ticket_number, etc.), which
-- had EXECUTE revoked from public/anon and granted to authenticated instead
-- of their default PUBLIC-executable state. Confirmed no functional impact:
-- Postgres trigger invocation does not check EXECUTE grants, and none of
-- those functions are called directly as RPCs. The result is incidentally
-- *more* restrictive than before, consistent with this project's
-- default-deny posture, so those functions are left as-is rather than
-- reverted.
--
-- This migration just re-runs the sweep with the parentheses the original
-- comment already claimed, so the *documented* scope and the *actual* scope
-- match, and so this pattern doesn't get copy-pasted with the same bug into
-- a future migration where the loop reaches something that isn't harmless
-- (e.g. a helper someone actually wants anon-executable).

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as func
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
      and (
        p.proname like 'trg_%'
        or p.proname like 'notify_%'
        or p.proname like 'check_%'
        or p.proname like 'pmo_check_%'
        or p.proname like 'set_%'
        or p.proname like 'touch_%'
      )
  loop
    begin
      execute format('revoke all on function %s from public', r.func);
      execute format('revoke all on function %s from anon', r.func);
      execute format('grant execute on function %s to authenticated', r.func);
    exception when others then
      -- ignore if function signature mismatch or grant not owned by this role
      null;
    end;
  end loop;
end $$;