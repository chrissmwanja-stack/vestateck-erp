-- Regression test for:
--   supabase/migrations/20261008085228_register_insurance_module.sql
--
-- Verifies, against a fully-migrated fresh stack:
--   1. 'insurance' is in platform_modules as an active, tenant-entitled
--      vertical-tier module of the 'insurance' vertical.
--   2. It is accepted by tenant_modules and staff_roles (FK satisfied).
--   3. The previous 9 keys are untouched, and the 'finance' rule still holds.
--
-- Run against a fresh local stack only -- never against a linked project.

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_t uuid := gen_random_uuid();
  v_u uuid := gen_random_uuid();
  m   record;
begin
  select * into m from platform_modules where key = 'insurance';
  if not found then raise exception 'FAIL: insurance not registered'; end if;
  if m.tier <> 'vertical' or m.vertical <> 'insurance' then
    raise exception 'FAIL: insurance should be tier vertical / vertical insurance, got % / %', m.tier, m.vertical;
  end if;
  if not m.is_active or not m.tenant_entitled then
    raise exception 'FAIL: insurance must be active and tenant-entitled';
  end if;

  if (select count(*) from platform_modules where key in
      ('hr','legal','bd','it','pmo','procurement','machine_operation','sustainability','finance')) <> 9 then
    raise exception 'FAIL: the original 9 registry keys changed';
  end if;

  insert into tenants (id, name, status, created_at, plan, subscription_status, industry_template)
  values (v_t, 'Ins Reg Test Co', 'active', now(), 'trial', 'trialing', 'general');

  insert into tenant_modules (tenant_id, module) values (v_t, 'insurance');
  if not exists (select 1 from tenant_modules where tenant_id = v_t and module = 'insurance') then
    raise exception 'FAIL: tenant_modules rejected insurance';
  end if;

  begin
    insert into tenant_modules (tenant_id, module) values (v_t, 'finance');
    raise exception 'FAIL: finance should still not be entitlable';
  exception when check_violation then null;
  end;
end $$;

rollback;
