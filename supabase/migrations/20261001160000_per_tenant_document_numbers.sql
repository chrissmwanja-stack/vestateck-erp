-- Make asset tags, problem numbers and material-request numbers unique per tenant.
--
-- Problem
--   The numbering functions (next_asset_tag, next_problem_number, next_mr_number)
--   count per tenant: every tenant's sequence starts at -00001. But the baseline
--   enforces GLOBAL uniqueness on assets.asset_tag, problems.problem_number and
--   requests.mr_number, so the second tenant's first asset, problem or MR would
--   collide with the first tenant's and the insert would fail. it_tickets and
--   material_catalog are already scoped correctly, as (tenant_id, ticket_number)
--   and (tenant_id, code).
--
-- Fix
--   Replace each global unique constraint/index with a (tenant_id, <number>) one.
--   This only loosens uniqueness across tenants, so existing data cannot violate
--   it. (Production had 0 rows in all three tables when this was written.)
--
-- Not covered here
--   The next_* functions still compute max()+1 without a lock, so two concurrent
--   inserts in the SAME tenant can pick the same number. With per-tenant
--   uniqueness that surfaces as a unique_violation on the loser, not a silent
--   duplicate. Serialising the functions is a separate change.

begin;

-- assets.asset_tag
alter table public.assets drop constraint if exists assets_asset_tag_key;
alter table public.assets
  add constraint assets_tenant_id_asset_tag_key unique (tenant_id, asset_tag);

-- problems.problem_number
alter table public.problems drop constraint if exists problems_problem_number_key;
alter table public.problems
  add constraint problems_tenant_id_problem_number_key unique (tenant_id, problem_number);

-- requests.mr_number (was a partial unique index, not a constraint)
drop index if exists public.requests_mr_number_key;
create unique index requests_tenant_id_mr_number_key
  on public.requests using btree (tenant_id, mr_number)
  where mr_number is not null;

commit;
