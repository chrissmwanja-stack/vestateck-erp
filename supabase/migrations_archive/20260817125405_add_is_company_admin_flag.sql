-- Explicit, persistent marker for "the overall company admin" per tenant,
-- distinct from per-module staff_roles admin rows.
--
-- Until now there was no durable record of who accepted a company_admin
-- invite -- accept-invite just fanned that role_bundle out into staff_roles
-- admin rows for all 8 modules, so a company_admin was indistinguishable
-- from "someone who happens to be admin in every module" after the fact.
-- invite-user's member-invite authorization exploited that ambiguity by
-- checking for *any* staff_roles admin row, which meant a single-module
-- admin (e.g. HR-only) could invite members into any module, including
-- finance. This column lets us gate member-invite authorization on
-- "the actual company admin" specifically.
alter table public.app_users
  add column is_company_admin boolean not null default false;

comment on column public.app_users.is_company_admin is
  'True for the tenant''s overall company admin (accepted a company_admin-bundle invite). '
  'Distinct from staff_roles admin rows, which are per-module. Used to gate who may invite '
  'new members (see invite-user edge function) -- module admins may no longer invite; only '
  'the company admin (or a platform admin) can.';

-- Backfill: anyone who currently holds an 'admin' staff_roles row in ALL
-- 8 modules got there via the company_admin accept-invite path (that's
-- the only place that pattern is produced), so treat them as the
-- existing company admin(s) for their tenant.
with all_module_admins as (
  select user_id, tenant_id
  from public.staff_roles
  where role = 'admin'
  group by user_id, tenant_id
  having count(distinct module) = 8
)
update public.app_users au
set is_company_admin = true
from all_module_admins ama
where au.id = ama.user_id
  and au.tenant_id = ama.tenant_id;