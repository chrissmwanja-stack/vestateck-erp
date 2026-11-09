-- Serialize per-tenant number generation for the five max()+1 numbering functions.
--
-- Problem
--   next_asset_tag, next_mr_number, next_ticket_number, next_problem_number and
--   next_material_catalog_code compute max(<number>)+1 over the tenant's rows with
--   no lock. Two concurrent inserts in the SAME tenant both see the same max, both
--   pick the same number, and the loser fails with unique_violation (the
--   (tenant_id, number) constraints from 20261001160000 turn what used to be a
--   silent duplicate into a hard error). A user sees "duplicate key value" on a
--   perfectly valid submit.
--
--   next_doc_number is NOT affected: it is an atomic upsert on doc_sequences
--   (INSERT ... ON CONFLICT DO UPDATE ... RETURNING), which already serializes
--   per (tenant, doc_type, year) on the row lock. It is left unchanged.
--
-- Fix
--   Take a transaction-scoped advisory lock keyed on (number kind, tenant) before
--   the max() read. The numbering triggers call these functions inside the
--   inserting transaction, so the lock is held until that transaction commits or
--   rolls back; a waiting caller then re-reads max() and sees the committed row.
--   Different tenants and different number kinds never block each other.
--
--   * The lock is taken AFTER assert_tenant_access, so a caller who is not
--     authorized for the tenant is rejected before it can hold (or queue on) a
--     lock for that tenant.
--   * This relies on READ COMMITTED (the Postgres/Supabase default) and on these
--     functions staying VOLATILE: each statement then gets a fresh snapshot after
--     the lock wait. Do not mark them STABLE, and do not call them from a
--     REPEATABLE READ / SERIALIZABLE transaction expecting the wait to be enough.
--   * Hash collisions between two different keys only cause extra waiting, never
--     a wrong number.
--
-- Bodies are otherwise unchanged from 20261001150000. Grants are unchanged
-- (the SECURITY INVOKER numbering triggers need `authenticated` to keep EXECUTE).

begin;

-- 1. Internal helper -------------------------------------------------------

create or replace function public.lock_number_sequence(p_tenant_id uuid, p_kind text)
returns void
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
begin
  perform pg_advisory_xact_lock(
    hashtextextended('number_sequence:' || p_kind || ':' || p_tenant_id::text, 0)
  );
end;
$function$;

revoke execute on function public.lock_number_sequence(uuid, text) from public, anon, authenticated;

comment on function public.lock_number_sequence(uuid, text) is
  'Internal: transaction-scoped advisory lock serializing max()+1 number generation per (kind, tenant). Called by the next_* numbering functions after assert_tenant_access. Not client-executable.';

-- 2. The five max()+1 functions: lock added, bodies otherwise unchanged -----

create or replace function public.next_asset_tag(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_next_num int;
begin
  perform public.assert_tenant_access(p_tenant_id);
  perform public.lock_number_sequence(p_tenant_id, 'asset_tag');

  select coalesce(max(nullif(regexp_replace(asset_tag, '^AST-', ''), asset_tag)::int), 0) + 1
  into v_next_num
  from assets
  where tenant_id = p_tenant_id and asset_tag like 'AST-%';

  return 'AST-' || lpad(v_next_num::text, 5, '0');
end;
$function$;

create or replace function public.next_mr_number(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_next_num int;
begin
  perform public.assert_tenant_access(p_tenant_id);
  perform public.lock_number_sequence(p_tenant_id, 'mr_number');

  select coalesce(max(nullif(regexp_replace(mr_number, '^MR-', ''), mr_number)::int), 0) + 1
  into v_next_num
  from requests
  where tenant_id = p_tenant_id and mr_number like 'MR-%';

  return 'MR-' || lpad(v_next_num::text, 5, '0');
end;
$function$;

create or replace function public.next_ticket_number(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_next_num int;
begin
  perform public.assert_tenant_access(p_tenant_id);
  perform public.lock_number_sequence(p_tenant_id, 'ticket_number');

  select coalesce(max(nullif(regexp_replace(ticket_number, '^TCK-', ''), ticket_number)::int), 0) + 1
  into v_next_num
  from it_tickets
  where tenant_id = p_tenant_id and ticket_number like 'TCK-%';

  return 'TCK-' || lpad(v_next_num::text, 5, '0');
end;
$function$;

create or replace function public.next_problem_number(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_next_num int;
begin
  perform public.assert_tenant_access(p_tenant_id);
  perform public.lock_number_sequence(p_tenant_id, 'problem_number');

  select coalesce(max(nullif(regexp_replace(problem_number, '^PRB-', ''), problem_number)::int), 0) + 1
  into v_next_num
  from problems
  where tenant_id = p_tenant_id and problem_number like 'PRB-%';

  return 'PRB-' || lpad(v_next_num::text, 5, '0');
end;
$function$;

create or replace function public.next_material_catalog_code(p_tenant_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_next_num int;
begin
  perform public.assert_tenant_access(p_tenant_id);
  perform public.lock_number_sequence(p_tenant_id, 'material_catalog_code');

  select coalesce(max(nullif(regexp_replace(code, '^MAT-', ''), code)::int), 0) + 1
  into v_next_num
  from material_catalog
  where tenant_id = p_tenant_id and code like 'MAT-%';

  return 'MAT-' || lpad(v_next_num::text, 5, '0');
end;
$function$;

commit;
