-- Make ins_production_book and ins_client_statement security_invoker.
--
-- Why this is more than ALTER VIEW ... SET (security_invoker = true):
--   Run as the caller, these views would read tables an insurance-only user
--   cannot see under RLS:
--     * fin_open_items / fin_allocations / fin_settlements (finance team only)
--       -> ins_client_statement.received_amount would silently lose the
--          endorsement-receipt part and balance_amount would be overstated.
--     * organizations (finance / PO access / tenant admin only)
--       -> ins_production_book.branch_name would silently become NULL.
--   Those two lookups move into narrow SECURITY DEFINER helpers that apply the
--   same tenant + can_access_insurance() guard the views already applied.
--   Every other table the views read is already insurance-readable under RLS
--   (bd_clients via can_access_client_master(), ins_* via can_access_insurance()).
--
-- Policy notes: no DROP. CREATE OR REPLACE VIEW keeps the exact column list,
-- order and types. Idempotent. Production output is unchanged for insurance users.

-- 1. Helpers -----------------------------------------------------------------

create or replace function public.ins_policy_endorsement_receipts(p_policy_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(a.amount), 0::numeric)
  from public.ins_policy_endorsements x
  join public.fin_open_items oi
    on oi.source_id = x.id
   and oi.tenant_id = x.tenant_id
   and oi.source_type = 'ins_policy_endorsement'
  join public.fin_allocations a
    on a.open_item_id = oi.id
   and a.tenant_id = oi.tenant_id
  join public.fin_settlements s
    on s.id = a.settlement_id
   and s.tenant_id = a.tenant_id
  where public.can_access_insurance()
    and x.policy_id = p_policy_id
    and x.tenant_id = public.get_my_tenant_id()
    and s.status = 'posted'
    and s.direction = 'in';
$$;

create or replace function public.ins_branch_name(p_org_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select o.site_name
  from public.organizations o
  where public.can_access_insurance()
    and o.id = p_org_id
    and o.tenant_id = public.get_my_tenant_id();
$$;

revoke all on function public.ins_policy_endorsement_receipts(uuid) from public, anon;
revoke all on function public.ins_branch_name(uuid) from public, anon;
grant execute on function public.ins_policy_endorsement_receipts(uuid) to authenticated, service_role;
grant execute on function public.ins_branch_name(uuid) to authenticated, service_role;

-- 2. Views -------------------------------------------------------------------

create or replace view public.ins_client_statement
with (security_invoker = true) as
select
  p.tenant_id,
  p.id as policy_id,
  p.policy_no,
  p.client_id,
  bd.name as client_name,
  p.currency,
  p.gross_premium + coalesce(e.delta, 0::numeric) as billed_amount,
  coalesce(r.received, 0::numeric) as received_amount,
  p.gross_premium + coalesce(e.delta, 0::numeric) - coalesce(r.received, 0::numeric) as balance_amount,
  p.bound_at::date as bound_date,
  p.expiry_date,
  p.status
from public.ins_policies p
  join public.ins_clients c on c.id = p.client_id
  join public.bd_clients bd on bd.id = c.client_id
  left join lateral (
    select sum((x.calculation ->> 'premium_delta')::numeric) as delta
    from public.ins_policy_endorsements x
    where x.tenant_id = p.tenant_id
      and x.policy_id = p.id
      and x.status = 'posted'
  ) e on true
  left join lateral (
    select (
      (select coalesce(sum(q.amount), 0::numeric)
         from public.ins_policy_cash_requests q
        where q.tenant_id = p.tenant_id
          and q.policy_id = p.id
          and q.kind = 'receipt'
          and q.status = 'posted')
      + public.ins_policy_endorsement_receipts(p.id)
    ) as received
  ) r on true
where p.status = any (array['active', 'renewed'])
  and p.tenant_id = public.get_my_tenant_id()
  and public.can_access_insurance();

create or replace view public.ins_production_book
with (security_invoker = true) as
select
  p.tenant_id,
  p.id as policy_id,
  p.policy_no,
  p.status,
  p.transaction_type,
  p.bound_at::date as bound_date,
  p.client_id,
  bd.name as client_name,
  p.insurer_id,
  i.name as insurer_name,
  p.product_line_id,
  pl.name as product_line_name,
  p.branch_id,
  public.ins_branch_name(p.branch_id) as branch_name,
  p.agent_id,
  m.name as agent_name,
  p.currency,
  p.gross_premium,
  p.commission_amount,
  p.net_premium_to_insurer
from public.ins_policies p
  join public.ins_clients c on c.id = p.client_id
  left join public.bd_clients bd on bd.id = c.client_id
  join public.ins_insurers i on i.id = p.insurer_id
  join public.ins_product_lines pl on pl.id = p.product_line_id
  left join public.ins_intermediaries m on m.id = p.agent_id
where p.status = any (array['active', 'renewed'])
  and p.tenant_id = public.get_my_tenant_id()
  and public.can_access_insurance();

-- 3. Views are read-only reports: drop the default write privileges ----------
revoke insert, update, delete, truncate, references, trigger
  on public.ins_client_statement, public.ins_production_book
  from authenticated, anon;
