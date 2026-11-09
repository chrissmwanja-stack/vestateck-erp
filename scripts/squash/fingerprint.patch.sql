-- ============================================================================
-- fingerprint.patch.sql
--
-- Drop-in replacements / additions for the $fpSql branches in
-- scripts/squash-2026-11.ps1. Four problems this run exposed:
--
--   P1  aclexplode(NULL acl) yields 0 rows -> implicit PUBLIC grants print as
--       '' and a real privilege escalation reads as "grants were dropped".
--       Fix: coalesce(acl, acldefault(kind, owner)).
--   P2  pg_get_functiondef / pg_get_viewdef schema-qualify per the CALLER's
--       search_path -> 517 phantom hash diffs. Fix: pin search_path.
--   P3  pg_default_acl is not fingerprinted at all, yet the baseline mutates
--       it (and it is a SHARED catalog, so it survives db reset).
--   P4  prosecdef / provolatile / proparallel / proconfig are not covered
--       explicitly; a SECURITY DEFINER flip may not change the md5.
--
-- All branches keep the v10 rules: explicit ::text cast, ORDER BY column name,
-- no COLLATE on non-collatable types.
-- ============================================================================


-- ---------------------------------------------------------------- P1 + P2 ----
-- REPLACES the existing fn| branch.
--
-- Changes:
--   * acldefault() so NULL proacl prints as 'public:EXECUTE,postgres:EXECUTE'
--   * search_path pinned to 'public' around pg_get_functiondef via a
--     set_config(..., true) sub-SELECT (transaction-local, no session leak)
--   * proconfig surfaced explicitly as its own field

select ('fn|' || p.oid::regprocedure::text || '|' ||
        md5((select pg_get_functiondef(p.oid)
               from (select set_config('search_path', 'public', true)) s)) || '|' ||
        coalesce((select string_agg(coalesce(r.rolname, 'public') || ':' || a.privilege_type, ','
                                    order by coalesce(r.rolname, 'public'), a.privilege_type)
                    from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                    left join pg_roles r on r.oid = a.grantee), '') || '|' ||
        coalesce(array_to_string(p.proconfig, ','), '') || '|' ||
        p.prosecdef::text)::text as line
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.prokind in ('f', 'p')
   and not exists (select 1 from pg_depend d
                    where d.objid = p.oid and d.deptype = 'e');

-- NOTE: set_config(..., true) is transaction-local. Invoke-Psql runs each call
-- in its own implicit transaction, so this is safe and self-cleaning. If you
-- would rather not rely on that, wrap the whole fingerprint in BEGIN/COMMIT
-- and use `set local search_path = public;` once at the top.
--
-- IMPORTANT: apply the SAME change to both A and B, or you will trade 517
-- phantom diffs for 517 new ones.


-- ---------------------------------------------------------------- P1 --------
-- REPLACES the existing acl| branch (same NULL blindness on relacl).
-- acldefault kind letter: 'r' = relation (tables, views, sequences).

select ('acl|' || c.relkind::text || '|' || c.relname || '|' ||
        coalesce((select string_agg(coalesce(r.rolname, 'public') || ':' || a.privilege_type || ':' || a.is_grantable::text, ','
                                    order by coalesce(r.rolname, 'public'), a.privilege_type)
                    from aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
                    left join pg_roles r on r.oid = a.grantee), ''))::text as line
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relkind in ('r', 'p', 'v', 'm', 'S');

-- WARNING: this will turn a lot of currently-'' acl| lines into
-- 'postgres:ALL:true,...'. That is correct and is exactly the signal you want
-- — but it means the FIRST run after this patch will show a large diff vs the
-- v10 fingerprint. Re-baseline your expectations once, then trust it.


-- ---------------------------------------------------------------- P2 --------
-- REPLACES the existing view| branch.

select ('view|' || c.relname || '|' || coalesce(c.reloptions::text, '') || '|' ||
        md5((select pg_get_viewdef(c.oid, true)
               from (select set_config('search_path', 'public', true)) s)))::text as line
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relkind in ('v', 'm');


-- ---------------------------------------------------------------- P3 (NEW) ---
-- ADD: default privileges. Shared catalog, mutated by your preamble, and the
-- direct cause of the NEW=[postgres:EXECUTE] function groups.

select ('defacl|' || d.defaclrole::regrole::text || '|' ||
        coalesce(d.defaclnamespace::regnamespace::text, '*') || '|' ||
        d.defaclobjtype || '|' ||
        coalesce((select string_agg(coalesce(r.rolname, 'public') || ':' || a.privilege_type, ','
                                    order by coalesce(r.rolname, 'public'), a.privilege_type)
                    from aclexplode(d.defaclacl) a
                    left join pg_roles r on r.oid = a.grantee), ''))::text as line
  from pg_default_acl d;

-- If this branch shows diffs between A and B, your ALTER DEFAULT PRIVILEGES
-- preamble is not reproducing 20260814081409 — read that migration before
-- shipping the baseline to prod.


-- ---------------------------------------------------------------- P3 (NEW) ---
-- ADD: schema ACLs. NULL nspacl on public means PUBLIC has CREATE+USAGE.

select ('nspace|' || n.nspname || '|' || n.nspowner::regrole::text || '|' ||
        coalesce((select string_agg(coalesce(r.rolname, 'public') || ':' || a.privilege_type, ','
                                    order by coalesce(r.rolname, 'public'), a.privilege_type)
                    from aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
                    left join pg_roles r on r.oid = a.grantee), ''))::text as line
  from pg_namespace n
 where n.nspname in ('public', 'storage', 'extensions');


-- ---------------------------------------------------------------- P4 (NEW) ---
-- ADD: function attributes that pg_get_functiondef does not reliably surface.

select ('fnattr|' || p.oid::regprocedure::text || '|' ||
        p.prosecdef::text   || '|' ||
        p.provolatile       || '|' ||
        p.proparallel       || '|' ||
        p.proleakproof::text || '|' ||
        p.procost::text     || '|' ||
        p.prorows::text     || '|' ||
        p.prokind           || '|' ||
        p.proowner::regrole::text)::text as line
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.prokind in ('f', 'p')
   and not exists (select 1 from pg_depend d
                    where d.objid = p.oid and d.deptype = 'e');


-- ---------------------------------------------------------------- NEW -------
-- ADD: extensions with version + schema, so `ext|pg_net` tells you WHICH
-- pg_net and where it lives instead of just that it exists.

select ('ext|' || e.extname || '|' || e.extversion || '|' ||
        n.nspname || '|' || e.extowner::regrole::text)::text as line
  from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace;

-- Your current branch is `select ('ext|' || extname)::text from pg_extension`
-- with no schema filter, so it already covers all schemas. Keep that; just add
-- the version/schema/owner fields so a platform-seeded pg_net is
-- distinguishable from a migration-created one.


-- ============================================================================
-- One-shot test for P2 before you patch anything: run these three and compare.
-- If the md5s differ, search_path is your 517-hash-diff culprit.
-- ============================================================================

-- select md5(pg_get_functiondef('public.acct_get_setting(text,date)'::regprocedure)) as sp_default;
-- begin;
--   select set_config('search_path', 'public', true);
--   select md5(pg_get_functiondef('public.acct_get_setting(text,date)'::regprocedure)) as sp_public;
-- rollback;
-- begin;
--   select set_config('search_path', 'public, extensions, storage', true);
--   select md5(pg_get_functiondef('public.acct_get_setting(text,date)'::regprocedure)) as sp_wide;
-- rollback;
