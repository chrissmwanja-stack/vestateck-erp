-- Phase 1, step 5 of the Insurance Brokerage vertical work (decision D2 in
-- PHASE0_COUPLING_AUDIT.md): let a tenant with the 'insurance' module use the
-- client master without owning the BD module.
--
-- Scope: ONLY the client-master set -- bd_clients, bd_contacts and
-- bd_client_categories. Leads, opportunities, proposals, tenders and activities
-- stay BD-only, so an insurance tenant never sees tender or pipeline data.
--
-- Two helpers keep the later move to a neutral core `clients` table a swap, not
-- a rewrite:
--   can_access_client_master()  = BD member tier  OR insurance member tier
--   can_manage_client_master()  = BD admin tier   OR insurance admin tier
-- Tiers mirror the live BD helpers: is_business_dev() = bd admin/manager/member,
-- is_business_dev_admin() = bd admin/manager.
--
-- The live policies were read from pg_policies (not the baseline): clients and
-- contacts gate all four commands on is_business_dev(); categories gate SELECT
-- on is_business_dev() but INSERT/UPDATE/DELETE on is_business_dev_admin().
-- Those exact shapes are preserved, only the helper changes, so existing BD
-- behaviour is identical (the new helpers are a superset: BD OR insurance).
--
-- Requires the 'insurance' key in platform_modules (20261008085228).

-- =====================================================================
-- A. Helpers (same conventions as is_business_dev*)
-- =====================================================================
create or replace function public.can_access_client_master()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.is_business_dev()
      or public.has_module_role('insurance', array['admin','manager','member']);
$$;

create or replace function public.can_manage_client_master()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.is_business_dev_admin()
      or public.has_module_role('insurance', array['admin','manager']);
$$;

comment on function public.can_access_client_master() is
  'Read/write access to the client master (bd_clients, bd_contacts, client categories read): BD member tier or insurance member tier. D2.';
comment on function public.can_manage_client_master() is
  'Admin-tier writes to client master lookup tables (bd_client_categories): BD admin tier or insurance admin tier. D2.';

revoke all on function public.can_access_client_master() from public, anon;
revoke all on function public.can_manage_client_master() from public, anon;
grant execute on function public.can_access_client_master() to authenticated;
grant execute on function public.can_manage_client_master() to authenticated;

-- =====================================================================
-- B. bd_clients and bd_contacts: all four commands -> can_access_client_master()
-- =====================================================================
drop policy if exists bd_clients_select on public.bd_clients;
create policy bd_clients_select on public.bd_clients
  for select using (tenant_id = get_my_tenant_id() and can_access_client_master());
drop policy if exists bd_clients_write_insert on public.bd_clients;
create policy bd_clients_write_insert on public.bd_clients
  for insert with check (tenant_id = get_my_tenant_id() and can_access_client_master());
drop policy if exists bd_clients_write_update on public.bd_clients;
create policy bd_clients_write_update on public.bd_clients
  for update using (tenant_id = get_my_tenant_id() and can_access_client_master())
  with check (tenant_id = get_my_tenant_id() and can_access_client_master());
drop policy if exists bd_clients_write_delete on public.bd_clients;
create policy bd_clients_write_delete on public.bd_clients
  for delete using (tenant_id = get_my_tenant_id() and can_access_client_master());

drop policy if exists bd_contacts_select on public.bd_contacts;
create policy bd_contacts_select on public.bd_contacts
  for select using (tenant_id = get_my_tenant_id() and can_access_client_master());
drop policy if exists bd_contacts_write_insert on public.bd_contacts;
create policy bd_contacts_write_insert on public.bd_contacts
  for insert with check (tenant_id = get_my_tenant_id() and can_access_client_master());
drop policy if exists bd_contacts_write_update on public.bd_contacts;
create policy bd_contacts_write_update on public.bd_contacts
  for update using (tenant_id = get_my_tenant_id() and can_access_client_master())
  with check (tenant_id = get_my_tenant_id() and can_access_client_master());
drop policy if exists bd_contacts_write_delete on public.bd_contacts;
create policy bd_contacts_write_delete on public.bd_contacts
  for delete using (tenant_id = get_my_tenant_id() and can_access_client_master());

-- =====================================================================
-- C. bd_client_categories: SELECT -> access helper; writes -> admin-tier helper
-- =====================================================================
drop policy if exists bd_client_categories_select on public.bd_client_categories;
create policy bd_client_categories_select on public.bd_client_categories
  for select using (tenant_id = get_my_tenant_id() and can_access_client_master());
drop policy if exists bd_client_categories_write_insert on public.bd_client_categories;
create policy bd_client_categories_write_insert on public.bd_client_categories
  for insert with check (tenant_id = get_my_tenant_id() and can_manage_client_master());
drop policy if exists bd_client_categories_write_update on public.bd_client_categories;
create policy bd_client_categories_write_update on public.bd_client_categories
  for update using (tenant_id = get_my_tenant_id() and can_manage_client_master())
  with check (tenant_id = get_my_tenant_id() and can_manage_client_master());
drop policy if exists bd_client_categories_write_delete on public.bd_client_categories;
create policy bd_client_categories_write_delete on public.bd_client_categories
  for delete using (tenant_id = get_my_tenant_id() and can_manage_client_master());
