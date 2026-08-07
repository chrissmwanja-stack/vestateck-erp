
-- Auto-set tenant_id on insert, same pattern as trg_set_cost_center_defaults,
-- so the UI never has to know or send it.
create or replace function public.set_organization_defaults()
returns trigger
language plpgsql
as $$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_set_organization_defaults on public.organizations;
create trigger trg_set_organization_defaults
  before insert on public.organizations
  for each row execute function public.set_organization_defaults();

create or replace function public.set_account_category_defaults()
returns trigger
language plpgsql
as $$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_set_account_category_defaults on public.account_categories;
create trigger trg_set_account_category_defaults
  before insert on public.account_categories
  for each row execute function public.set_account_category_defaults();

create or replace function public.set_department_defaults()
returns trigger
language plpgsql
as $$
begin
  NEW.tenant_id := get_my_tenant_id();
  if NEW.tenant_id is null then
    raise exception 'could not determine tenant_id for current user';
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_set_department_defaults on public.departments;
create trigger trg_set_department_defaults
  before insert on public.departments
  for each row execute function public.set_department_defaults();

-- departments had SELECT only -- add the missing write policies. Kept
-- consistent with organizations/account_categories: write access gated to
-- Finance, read access stays open to every tenant member (requests already
-- lets any requester pick their department in a dropdown).
create policy departments_insert on public.departments
  for insert
  with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());

create policy departments_update on public.departments
  for update
  using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id())
  with check (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());

create policy departments_delete on public.departments
  for delete
  using (is_finance_team_member('finance') and tenant_id = get_my_tenant_id());
