-- Catalog invariant: every write policy on a tenant-scoped table must tie the row
-- to a tenant, to the caller's own identity, or to the platform admin.
--
-- Why: RLS decides cross-tenant writes. A policy that only checks a role helper
-- (for example has_po_access()) with no tenant condition lets a privileged user of
-- one tenant write rows for another when something else supplies the tenant, such
-- as a BEFORE INSERT trigger that derives tenant_id from a parent row. That was
-- sap_payments_insert_finance until migration 20261106150000.
--
-- Checked, for every public table that has a tenant_id column:
--   INSERT / ALL policies : WITH CHECK (or USING when there is no WITH CHECK)
--   UPDATE policies       : USING AND, when present, WITH CHECK
-- must each mention tenant_id or get_my_tenant_id(), is_platform_admin(), or
-- auth.uid() (own-row policies). Tables whose rows are tied through a parent are
-- listed in v_allow with the reason. Read-only; safe on production and on a replay.
--
-- Run: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/test_policy_tenant_scope.sql

do $$
declare
  -- policy name -> why it is allowed to have no tenant or identity condition
  v_allow text[] := '{}';
  v_fail  text[] := '{}';
  r record;
  v_expr  text;
  v_ok    constant text := '(tenant_id|get_my_tenant_id|is_platform_admin|auth\.uid|platform_admin_bypass)';
begin
  for r in
    select p.polrelid::regclass::text as tbl,
           p.polname,
           p.polcmd,
           pg_get_expr(p.polqual, p.polrelid)      as using_expr,
           pg_get_expr(p.polwithcheck, p.polrelid) as check_expr
      from pg_policy p
      join pg_class c on c.oid = p.polrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and p.polcmd in ('a', 'w', '*')
       and exists (select 1 from pg_attribute a
                    where a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped)
     order by 1, 2
  loop
    if r.polname = any (v_allow) then
      continue;
    end if;

    -- INSERT: WITH CHECK is the operative expression. UPDATE: both USING and
    -- WITH CHECK are, so each present expression must carry a scope.
    if r.polcmd = 'a' then
      v_expr := coalesce(r.check_expr, r.using_expr, '');
      if v_expr !~* v_ok then
        v_fail := v_fail || format('%s.%s (INSERT) has no tenant, identity or platform-admin condition: %s',
                                   r.tbl, r.polname, left(v_expr, 80));
      end if;
    elsif r.polcmd = 'w' then
      if coalesce(r.using_expr, '') !~* v_ok then
        v_fail := v_fail || format('%s.%s (UPDATE USING) has no tenant, identity or platform-admin condition: %s',
                                   r.tbl, r.polname, left(coalesce(r.using_expr, ''), 80));
      end if;
      if r.check_expr is not null and r.check_expr !~* v_ok then
        v_fail := v_fail || format('%s.%s (UPDATE WITH CHECK) has no tenant, identity or platform-admin condition: %s',
                                   r.tbl, r.polname, left(r.check_expr, 80));
      end if;
    else
      v_expr := coalesce(r.check_expr, r.using_expr, '');
      if v_expr !~* v_ok then
        v_fail := v_fail || format('%s.%s (ALL) has no tenant, identity or platform-admin condition: %s',
                                   r.tbl, r.polname, left(v_expr, 80));
      end if;
    end if;
  end loop;

  if cardinality(v_fail) > 0 then
    raise exception E'FAIL: write policies without a tenant scope:\n  - %', array_to_string(v_fail, E'\n  - ');
  end if;

  raise notice 'OK: every write policy on a tenant-scoped table carries a tenant, identity or platform-admin condition';
end $$;
