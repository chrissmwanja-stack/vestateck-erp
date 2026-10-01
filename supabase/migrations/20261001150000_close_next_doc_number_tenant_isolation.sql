-- Close tenant isolation on the document-numbering functions.
--
-- Problem
--   next_doc_number(p_tenant_id, ...) is SECURITY DEFINER, EXECUTE is granted to
--   `authenticated`, and it never checks p_tenant_id. Any signed-in user can bump
--   another tenant's doc_sequences counter by passing that tenant's UUID. It was
--   tracked as KNOWN-OPEN in supabase/scripts/audit_security_definer.sql.
--
--   next_asset_tag, next_mr_number, next_ticket_number, next_problem_number and
--   next_material_catalog_code have the same shape (definer, tenant id argument,
--   granted to `authenticated`, no check). They only read, so the exposure is
--   leaking another tenant's highest record number rather than a write.
--
-- Why not REVOKE
--   The generate_*/set_* numbering triggers are SECURITY INVOKER and call these
--   functions as the inserting user, so `authenticated` must keep EXECUTE. The fix
--   is an in-function tenant check. Grants are left unchanged.
--
-- Rule enforced (same convention as 20260929120000_harden_post_journal_entry):
--   * No auth.uid() (service_role, cron, owner/migration connections): allowed.
--   * Otherwise p_tenant_id must equal get_my_tenant_id(), which already honours
--     active impersonation, OR the caller must be a platform admin who is not
--     impersonating (platform_admin_bypass()).
--   * A NULL get_my_tenant_id() (no app_users row, or suspended tenant) is denied.
--
-- The check lives in one internal helper so the six functions cannot drift apart.
-- The helper is not client-executable; the definer functions call it as their owner.

begin;

-- 1. Internal helper -------------------------------------------------------

create or replace function public.assert_tenant_access(p_tenant_id uuid)
returns void
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $function$
begin
  -- Trusted contexts (service_role, cron, owner connections) have no user session.
  -- An anonymous API session also has no auth.uid(), so refuse it explicitly rather
  -- than relying only on the EXECUTE grants (defence in depth).
  if auth.uid() is null then
    if current_setting('role', true) = 'anon' then
      raise exception 'not authorized to generate numbers'
        using errcode = '42501';
    end if;
    return;
  end if;

  if p_tenant_id is not null
     and p_tenant_id is not distinct from public.get_my_tenant_id() then
    return;
  end if;

  -- Platform admin acting as themselves (not impersonating a user).
  if public.platform_admin_bypass() then
    return;
  end if;

  raise exception 'not authorized to generate numbers for this tenant'
    using errcode = '42501';
end;
$function$;

revoke execute on function public.assert_tenant_access(uuid) from public, anon, authenticated;

comment on function public.assert_tenant_access(uuid) is
  'Internal guard for tenant-id-taking SECURITY DEFINER functions. Raises 42501 unless the caller has no user session (service role/owner), the tenant is the caller''s effective tenant (impersonation-aware), or the caller is a non-impersonating platform admin. Not client-executable.';

-- 2. next_doc_number: guard added, body otherwise unchanged ----------------

create or replace function public.next_doc_number(
  p_tenant_id uuid,
  p_doc_type text,
  p_prefix text,
  p_pad integer default 4
)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  yr text := to_char(now(), 'YYYY');
  n int;
begin
  perform public.assert_tenant_access(p_tenant_id);

  insert into public.doc_sequences (tenant_id, doc_type, year, last_number)
  values (p_tenant_id, p_doc_type, yr, 1)
  on conflict (tenant_id, doc_type, year)
  do update set last_number = public.doc_sequences.last_number + 1
  returning last_number into n;

  return p_prefix || '-' || yr || '-' || lpad(n::text, p_pad, '0');
end;
$function$;

-- 3. Sibling numbering functions: guard added, bodies otherwise unchanged --

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

  select coalesce(max(nullif(regexp_replace(code, '^MAT-', ''), code)::int), 0) + 1
  into v_next_num
  from material_catalog
  where tenant_id = p_tenant_id and code like 'MAT-%';

  return 'MAT-' || lpad(v_next_num::text, 5, '0');
end;
$function$;

commit;
