-- Phase A1 follow-up: approval by assignment, not by system role.
--
-- Decision (owner, 16 Oct 2026): the Insurance Admin prepares and manages regulatory
-- drafts, but holds no approval authority by virtue of the role. Approval belongs to
-- the person made responsible for the regulatory submission in question. That
-- responsibility is recorded here, per parameter key or per category, with a date
-- range and a stated responsibility. Company administrators are not approvers by
-- role either. They assign approvers and withdraw assignments, and they still
-- end-date and retire approved values.
--
-- What this adds:
--   * regulatory_approval_assignments: user, scope (one key or one category), the
--     responsibility, effective dates, and who assigned it. Withdrawn rows are kept.
--     No client can write it. Changes go through reg_assign_approver and
--     reg_withdraw_approver, which only a company admin may call.
--   * reg_approve_parameter now requires an assignment in force today, covering the
--     draft's key or category. Proposer self-approval is still refused.
--   * regulatory_parameters: the Insurance Admin (module admin) can create and edit
--     drafts. Insert and update rights for finance and company admins are unchanged.
--     No approval right is added to any role.

create table if not exists public.regulatory_approval_assignments (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  user_id         uuid not null,
  scope           text not null check (scope in ('key', 'category')),
  scope_value     text not null,
  responsibility  text not null check (length(btrim(responsibility)) > 0),
  effective_from  date not null,
  effective_to    date,
  assigned_by     uuid not null default auth.uid(),
  assigned_at     timestamptz not null default now(),
  withdrawn_at    timestamptz,
  withdrawn_by    uuid,
  withdrawn_reason text,
  constraint reg_approval_assignment_dates check (effective_to is null or effective_to >= effective_from),
  constraint reg_approval_assignment_user foreign key (user_id)
    references public.app_users(id) on delete cascade,
  constraint reg_approval_assignment_withdrawn check (
    (withdrawn_at is null and withdrawn_by is null and withdrawn_reason is null)
    or (withdrawn_at is not null and withdrawn_by is not null
        and length(btrim(coalesce(withdrawn_reason, ''))) > 0))
);

create index if not exists regulatory_approval_assignments_lookup_idx
  on public.regulatory_approval_assignments (tenant_id, user_id, scope, scope_value);

alter table public.regulatory_approval_assignments enable row level security;

drop policy if exists regulatory_approval_assignments_select on public.regulatory_approval_assignments;
create policy regulatory_approval_assignments_select on public.regulatory_approval_assignments
  for select using (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or user_id = auth.uid() or is_finance_team_member(null::text)
         or has_module_role('insurance', array['admin', 'manager']))
  );

revoke all on public.regulatory_approval_assignments from public, anon, authenticated;
grant select on public.regulatory_approval_assignments to authenticated;

-- Scope must name a real key or category, and the approver must belong to the company.
create or replace function public.regulatory_approval_assignments_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' then
    if new.tenant_id is distinct from old.tenant_id or new.user_id is distinct from old.user_id
       or new.scope is distinct from old.scope or new.scope_value is distinct from old.scope_value
       or new.responsibility is distinct from old.responsibility
       or new.effective_from is distinct from old.effective_from
       or new.effective_to is distinct from old.effective_to
       or new.assigned_by is distinct from old.assigned_by or new.assigned_at is distinct from old.assigned_at then
      raise exception 'REG_ASSIGNMENT_IMMUTABLE: only a withdrawal can be recorded on an approval assignment';
    end if;
    return new;
  end if;

  if not exists (select 1 from app_users where id = new.user_id and tenant_id = new.tenant_id) then
    raise exception 'REG_NOT_FOUND: approver is not a user of this company';
  end if;

  if new.scope = 'key' then
    if not exists (select 1 from regulatory_parameter_definitions where key = new.scope_value) then
      raise exception 'REG_NOT_FOUND: % is not a known parameter key', new.scope_value;
    end if;
  elsif not exists (select 1 from regulatory_parameter_definitions where category = new.scope_value) then
    raise exception 'REG_NOT_FOUND: % is not a known parameter category', new.scope_value;
  end if;
  return new;
end;
$$;

revoke all on function public.regulatory_approval_assignments_guard() from public, anon, authenticated;

drop trigger if exists regulatory_approval_assignments_guard on public.regulatory_approval_assignments;
create trigger regulatory_approval_assignments_guard
  before insert or update on public.regulatory_approval_assignments
  for each row execute function public.regulatory_approval_assignments_guard();

create or replace function public.reg_assign_approver(
  p_user_id        uuid,
  p_scope          text,
  p_scope_value    text,
  p_responsibility text,
  p_effective_from date default current_date,
  p_effective_to   date default null
)
returns public.regulatory_approval_assignments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row regulatory_approval_assignments%rowtype;
begin
  if not is_tenant_admin() then
    raise exception 'REG_FORBIDDEN: only a company admin can assign an approver' using errcode = '42501';
  end if;
  if p_scope not in ('key', 'category') then
    raise exception 'REG_INPUT: scope must be key or category';
  end if;
  if nullif(btrim(p_responsibility), '') is null then
    raise exception 'REG_INPUT: state the responsibility this approval covers (for example, the submission it supports)';
  end if;
  if not exists (select 1 from app_users where id = p_user_id and tenant_id = get_my_tenant_id()) then
    raise exception 'REG_NOT_FOUND: approver is not a user of this company';
  end if;

  insert into regulatory_approval_assignments
    (tenant_id, user_id, scope, scope_value, responsibility, effective_from, effective_to, assigned_by)
  values
    (get_my_tenant_id(), p_user_id, p_scope, btrim(p_scope_value), btrim(p_responsibility),
     p_effective_from, p_effective_to, auth.uid())
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.reg_withdraw_approver(p_assignment_id uuid, p_reason text)
returns public.regulatory_approval_assignments
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row regulatory_approval_assignments%rowtype;
begin
  if not is_tenant_admin() then
    raise exception 'REG_FORBIDDEN: only a company admin can withdraw an approver' using errcode = '42501';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'REG_INPUT: a reason is required to withdraw an approver';
  end if;
  select * into v_row from regulatory_approval_assignments
   where id = p_assignment_id and tenant_id = get_my_tenant_id()
   for update;
  if not found then
    raise exception 'REG_NOT_FOUND: approval assignment not found';
  end if;
  if v_row.withdrawn_at is not null then
    raise exception 'REG_NOT_FOUND: this approval assignment is already withdrawn';
  end if;

  update regulatory_approval_assignments
     set withdrawn_at = now(), withdrawn_by = auth.uid(), withdrawn_reason = btrim(p_reason)
   where id = p_assignment_id
   returning * into v_row;
  return v_row;
end;
$$;

revoke all on function public.reg_assign_approver(uuid, text, text, text, date, date) from public, anon;
grant execute on function public.reg_assign_approver(uuid, text, text, text, date, date) to authenticated;
revoke all on function public.reg_withdraw_approver(uuid, text) from public, anon;
grant execute on function public.reg_withdraw_approver(uuid, text) to authenticated;

-- Approval: a draft is approved only by a user with an assignment in force today that
-- covers its key or its category. The proposer can never approve their own draft.
create or replace function public.reg_approve_parameter(p_id uuid)
returns public.regulatory_parameters
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row      regulatory_parameters%rowtype;
  v_uid      uuid := auth.uid();
  v_category text;
begin
  select * into v_row from regulatory_parameters
  where id = p_id and tenant_id = get_my_tenant_id()
  for update;
  if not found then
    raise exception 'REG_NOT_FOUND: parameter not found';
  end if;
  if v_row.status <> 'draft' then
    raise exception 'REG_NOT_DRAFT: only a draft can be approved (this one is %)', v_row.status;
  end if;
  if v_row.created_by is not distinct from v_uid then
    raise exception 'REG_SELF_APPROVAL: the person who proposed a value cannot approve it';
  end if;

  select category into v_category from regulatory_parameter_definitions where key = v_row.parameter_key;
  if not exists (
    select 1 from regulatory_approval_assignments a
     where a.tenant_id = v_row.tenant_id
       and a.user_id = v_uid
       and a.withdrawn_at is null
       and current_date between a.effective_from and coalesce(a.effective_to, date 'infinity')
       and ((a.scope = 'key' and a.scope_value = v_row.parameter_key)
            or (a.scope = 'category' and a.scope_value = v_category))
  ) then
    raise exception 'REG_NOT_APPROVER: you are not assigned to approve % (approval follows the responsibility for the submission, not the role)', v_row.parameter_key
      using errcode = '42501';
  end if;

  perform set_config('reg.via_rpc', 'on', true);
  update regulatory_parameters
     set status = 'approved', approved_by = v_uid, approved_at = now()
   where id = p_id
   returning * into v_row;
  perform set_config('reg.via_rpc', 'off', true);

  insert into regulatory_parameter_events (tenant_id, parameter_id, event, actor, detail)
  values (v_row.tenant_id, v_row.id, 'approved', v_uid, v_row.source_ref);
  return v_row;
end;
$$;

-- The Insurance Admin prepares and manages drafts. Approval rights are not added here.
drop policy if exists regulatory_parameters_insert on public.regulatory_parameters;
create policy regulatory_parameters_insert on public.regulatory_parameters
  for insert with check (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member('finance'::text)
         or has_module_role('insurance', array['admin']))
  );

drop policy if exists regulatory_parameters_update on public.regulatory_parameters;
create policy regulatory_parameters_update on public.regulatory_parameters
  for update using (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member('finance'::text)
         or has_module_role('insurance', array['admin']))
  )
  with check (
    tenant_id = get_my_tenant_id()
    and (is_tenant_admin() or is_finance_team_member('finance'::text)
         or has_module_role('insurance', array['admin']))
  );

-- =====================================================================
-- Suspended and read-only tenants
-- =====================================================================
select public.apply_tenant_read_only_guard();
