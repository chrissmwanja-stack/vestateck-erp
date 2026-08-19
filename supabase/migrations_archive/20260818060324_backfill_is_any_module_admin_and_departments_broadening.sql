-- Backfill migration: is_any_module_admin() and the departments write-policy
-- broadening it backs were already live in the database with no migration
-- file behind them (found during the am_i_finance audit -- referenced by a
-- comment in DepartmentsAdmin.tsx pointing at a
-- "broaden_departments_write_to_any_module_admin" migration that doesn't
-- exist in this repo). This migration is purely a backfill: it recreates
-- the exact function and policy definitions already active in production,
-- so `supabase db reset` / a fresh pull stays reproducible from
-- migrations. It changes no live behavior.
--
-- Intent: departments_select_tenant is open to every tenant member (any
-- requester needs to see the list to pick their department on a
-- request). Write access (insert/update/delete) is open to Finance team
-- members OR any module admin -- i.e. any staff_roles admin in any
-- module can manage departments, not just Finance. This mirrors
-- can_access_finance()'s "OR" pattern but for a broader admin population.

create or replace function public.is_any_module_admin()
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select
    exists (
      select 1 from public.app_users
      where id = auth.uid() and is_platform_admin
    )
    or exists (
      select 1 from public.staff_roles
      where user_id = auth.uid()
        and role = 'admin'
        and tenant_id = public.get_my_tenant_id()
    );
$function$;

grant execute on function public.is_any_module_admin() to authenticated, service_role;
revoke execute on function public.is_any_module_admin() from anon, public;

drop policy if exists "departments_delete" on "public"."departments";
create policy "departments_delete"
  on "public"."departments"
  as permissive
  for delete
  to public
  using ((public.is_finance_team_member('finance'::text) OR public.is_any_module_admin()) AND (tenant_id = public.get_my_tenant_id()));

drop policy if exists "departments_insert" on "public"."departments";
create policy "departments_insert"
  on "public"."departments"
  as permissive
  for insert
  to public
  with check ((public.is_finance_team_member('finance'::text) OR public.is_any_module_admin()) AND (tenant_id = public.get_my_tenant_id()));

drop policy if exists "departments_update" on "public"."departments";
create policy "departments_update"
  on "public"."departments"
  as permissive
  for update
  to public
  using ((public.is_finance_team_member('finance'::text) OR public.is_any_module_admin()) AND (tenant_id = public.get_my_tenant_id()))
  with check ((public.is_finance_team_member('finance'::text) OR public.is_any_module_admin()) AND (tenant_id = public.get_my_tenant_id()));