-- Tighten IT Support SELECT and prevent Law direct status bypass — Item 7

-- 1. IT Support lookup tables: tighten SELECT from tenant-only to is_it_support()
-- These were missed in 20260921093000 which tightened Law/PMO/Machine/Sustainability but not IT/BD

drop policy if exists "support_teams_select" on public.support_teams;
create policy "support_teams_select" on public.support_teams
  for select using ((tenant_id = get_my_tenant_id()) and is_it_support());

drop policy if exists "ticket_categories_select" on public.ticket_categories;
create policy "ticket_categories_select" on public.ticket_categories
  for select using ((tenant_id = get_my_tenant_id()) and is_it_support());

drop policy if exists "sla_policies_select" on public.sla_policies;
create policy "sla_policies_select" on public.sla_policies
  for select using ((tenant_id = get_my_tenant_id()) and is_it_support());

drop policy if exists "priority_levels_select" on public.priority_levels;
create policy "priority_levels_select" on public.priority_levels
  for select using ((tenant_id = get_my_tenant_id()) and is_it_support());

drop policy if exists "support_team_members_select" on public.support_team_members;
create policy "support_team_members_select" on public.support_team_members
  for select using ((tenant_id = get_my_tenant_id()) and is_it_support());

-- faqs and kb_articles already allow is_published OR is_it_support() — keep as is (public KB)

-- 2. Law: prevent direct UPDATE of status via table (require RPC for approval decisions)
-- Direct UPDATE stays allowed for expired/terminated lifecycle, but not for approval transitions
create or replace function public.prevent_law_contract_direct_approval()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and old.status is distinct from new.status then
    -- Allow draft -> pending_approval only via submit_contract_for_approval RPC which sets session var?
    -- For now, allow only transitions that are NOT approval decisions via direct UPDATE:
    -- Block draft->pending_approval, pending_approval->active, pending_approval->rejected via direct UPDATE
    -- These must go through RPCs which set app.allow_law_status_change=true
    if (old.status = 'draft' and new.status = 'pending_approval')
       or (old.status = 'pending_approval' and new.status in ('active', 'rejected')) then
      if current_setting('app.allow_law_status_change', true) != 'true' then
        raise exception 'LAW_STATUS_GUARD: contract status change %->% must go through submit_contract_for_approval() or decide_contract() RPC, not direct table UPDATE', old.status, new.status
          using errcode = 'restrict_violation';
      end if;
    end if;
    -- Allow active->expired, active->terminated, expired->terminated etc via direct UPDATE (lifecycle management)
  end if;
  return new;
end;
$$;

revoke execute on function public.prevent_law_contract_direct_approval() from public;

drop trigger if exists trg_prevent_law_contract_direct_approval on public.law_contracts;
create trigger trg_prevent_law_contract_direct_approval
  before update on public.law_contracts
  for each row execute function public.prevent_law_contract_direct_approval();

-- Update RPCs to allow status change via session variable
create or replace function public.submit_contract_for_approval(p_contract_id uuid)
returns public.law_contracts
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_contract public.law_contracts%rowtype;
begin
  if not has_module_role('legal', array['admin', 'manager', 'member']) then
    raise exception 'not authorized: legal module role required';
  end if;

  select * into v_contract from law_contracts
  where id = p_contract_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'contract not found in this tenant';
  end if;
  if v_contract.status <> 'draft' then
    raise exception 'only draft contracts can be submitted for approval (current status: %)', v_contract.status;
  end if;

  perform set_config('app.allow_law_status_change', 'true', true);
  update law_contracts
  set status = 'pending_approval', updated_at = now()
  where id = v_contract.id
  returning * into v_contract;
  perform set_config('app.allow_law_status_change', 'false', true);

  insert into law_contract_decisions (tenant_id, contract_id, decision, decided_by, notes)
  values (v_contract.tenant_id, v_contract.id, 'submitted', effective_user_id(), null);

  return v_contract;
end;
$$;

revoke all on function public.submit_contract_for_approval(uuid) from public;
revoke all on function public.submit_contract_for_approval(uuid) from anon;
grant execute on function public.submit_contract_for_approval(uuid) to authenticated;
grant execute on function public.submit_contract_for_approval(uuid) to service_role;

create or replace function public.decide_contract(p_contract_id uuid, p_decision text, p_notes text default null)
returns public.law_contracts
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_contract public.law_contracts%rowtype;
  v_actor uuid := auth.uid();
  v_effective uuid := effective_user_id();
begin
  if not has_module_role('legal', array['admin', 'manager']) then
    raise exception 'not authorized: contract approval requires a legal admin or manager role';
  end if;

  if p_decision not in ('approved', 'rejected') then
    raise exception 'p_decision must be ''approved'' or ''rejected''';
  end if;

  if p_decision = 'rejected' and (p_notes is null or btrim(p_notes) = '') then
    raise exception 'rejection requires notes explaining why';
  end if;

  select * into v_contract from law_contracts
  where id = p_contract_id and tenant_id = get_my_tenant_id()
  for update;

  if not found then
    raise exception 'contract not found in this tenant';
  end if;
  if v_contract.status <> 'pending_approval' then
    raise exception 'only contracts pending approval can be decided (current status: %)', v_contract.status;
  end if;
  if v_contract.created_by = v_effective then
    raise exception 'you cannot approve your own contract — separation of duties';
  end if;

  perform set_config('app.allow_law_status_change', 'true', true);
  update law_contracts
  set status = case when p_decision='approved' then 'active' else 'rejected' end,
      updated_at = now()
  where id = v_contract.id
  returning * into v_contract;
  perform set_config('app.allow_law_status_change', 'false', true);

  insert into law_contract_decisions (tenant_id, contract_id, decision, decided_by, notes)
  values (v_contract.tenant_id, v_contract.id, p_decision, v_effective, p_notes);

  return v_contract;
end;
$$;

revoke all on function public.decide_contract(uuid, text, text) from public;
revoke all on function public.decide_contract(uuid, text, text) from anon;
grant execute on function public.decide_contract(uuid, text, text) to authenticated;
grant execute on function public.decide_contract(uuid, text, text) to service_role;

-- 3. Extend posted cost immutability to fuel_logs and maintenance_requests (Machine)
drop trigger if exists trg_prevent_posted_fuel_cost_update on public.fuel_logs;
create trigger trg_prevent_posted_fuel_cost_update
  before update on public.fuel_logs
  for each row execute function public.prevent_posted_invoice_update();

-- maintenance_requests actual cost (if column exists, check)
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='maintenance_requests' and column_name='actual_cost') then
    -- create trigger only if column exists
    drop trigger if exists trg_prevent_posted_maintenance_cost_update on public.maintenance_requests;
    create trigger trg_prevent_posted_maintenance_cost_update
      before update on public.maintenance_requests
      for each row execute function public.prevent_posted_invoice_update();
  end if;
end $$;

comment on function public.prevent_law_contract_direct_approval() is
  'Blocks direct table UPDATE of law_contracts status for approval transitions (draft->pending_approval, pending_approval->active/rejected) — must go through RPCs. Allows lifecycle transitions active->expired/terminated via direct UPDATE.';
